#include "valkey_wrapper.h"

#include "ae.h"
#include "server.h"
#include <valkey/valkey.h>

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

extern int valkey_embedded_main(int argc, char **argv);

static pthread_t g_thread;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_started = 0;
static int g_thread_active = 0;
static int g_thread_joinable = 0;
static char g_host[128] = "127.0.0.1";
static int g_port = 6379;
static char g_last_error[512] = "";
typedef struct {
    char host[128];
    char port[16];
} server_args_t;
static server_args_t g_server_args;

static void set_error(const char *msg) {
    pthread_mutex_lock(&g_lock);
    snprintf(g_last_error, sizeof(g_last_error), "%s", msg ? msg : "unknown error");
    pthread_mutex_unlock(&g_lock);
}

static void set_error_fmt(const char *prefix, const char *detail) {
    pthread_mutex_lock(&g_lock);
    snprintf(g_last_error, sizeof(g_last_error), "%s: %s", prefix ? prefix : "error", detail ? detail : "unknown");
    pthread_mutex_unlock(&g_lock);
}

const char *valkey_wrapper_last_error(void) {
    return g_last_error;
}

static void *server_thread_main(void *opaque) {
    server_args_t *cfg = (server_args_t *)opaque;
    char *argv[] = {
        (char *)"valkey-embedded",
        (char *)"--bind",
        cfg->host,
        (char *)"--port",
        cfg->port,
        (char *)"--save",
        (char *)"",
        (char *)"--appendonly",
        (char *)"no",
        (char *)"--protected-mode",
        (char *)"no",
        (char *)"--daemonize",
        (char *)"no",
        (char *)"--supervised",
        (char *)"no",
        (char *)"--logfile",
        (char *)"",
        (char *)"--loglevel",
        (char *)"warning",
        (char *)"--set-proc-title",
        (char *)"no",
        (char *)"--databases",
        (char *)"1",
        NULL,
    };
    int argc = (int)((sizeof(argv) / sizeof(argv[0])) - 1);
    (void)valkey_embedded_main(argc, argv);
    pthread_mutex_lock(&g_lock);
    g_thread_active = 0;
    g_started = 0;
    pthread_mutex_unlock(&g_lock);
    return NULL;
}

static valkeyContext *connect_ctx(void) {
    struct timeval tv;
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    valkeyContext *ctx = valkeyConnectWithTimeout(g_host, g_port, tv);
    if (ctx == NULL) {
        set_error("valkey connection allocation failed");
        return NULL;
    }
    if (ctx->err) {
        set_error_fmt("valkey connection failed", ctx->errstr);
        valkeyFree(ctx);
        return NULL;
    }
    return ctx;
}

int valkey_wrapper_ping(void) {
    valkeyContext *ctx = connect_ctx();
    if (ctx == NULL) return VALKEY_WRAPPER_ERR;
    valkeyReply *reply = (valkeyReply *)valkeyCommand(ctx, "PING");
    if (reply == NULL) {
        set_error_fmt("valkey ping failed", ctx->errstr);
        valkeyFree(ctx);
        return VALKEY_WRAPPER_ERR;
    }
    int ok = (reply->type == VALKEY_REPLY_STATUS && reply->str != NULL && strcmp(reply->str, "PONG") == 0);
    freeReplyObject(reply);
    valkeyFree(ctx);
    if (!ok) {
        set_error("valkey ping returned unexpected reply");
        return VALKEY_WRAPPER_ERR;
    }
    return VALKEY_WRAPPER_OK;
}

int valkey_wrapper_start(const char *host, uint16_t port, const char *data_dir) {
    (void)data_dir;

    const char *requested_host = (host && host[0]) ? host : "127.0.0.1";

    pthread_mutex_lock(&g_lock);
    if (g_started || g_thread_active || g_thread_joinable) {
        int same_config = strcmp(g_host, requested_host) == 0 && g_port == (int)port;
        pthread_mutex_unlock(&g_lock);
        if (same_config && valkey_wrapper_ping() == VALKEY_WRAPPER_OK) {
            return VALKEY_WRAPPER_OK;
        }
        set_error("valkey server is already active or still stopping");
        return VALKEY_WRAPPER_ERR;
    }
    snprintf(g_host, sizeof(g_host), "%s", requested_host);
    g_port = (int)port;
    pthread_mutex_unlock(&g_lock);

    server_args_t *cfg = &g_server_args;
    memset(cfg, 0, sizeof(*cfg));
    snprintf(cfg->host, sizeof(cfg->host), "%s", g_host);
    snprintf(cfg->port, sizeof(cfg->port), "%u", (unsigned int)port);
    int rc = pthread_create(&g_thread, NULL, server_thread_main, cfg);
    if (rc != 0) {
        set_error_fmt("pthread_create failed", strerror(rc));
        return VALKEY_WRAPPER_ERR;
    }

    pthread_mutex_lock(&g_lock);
    g_started = 1;
    g_thread_active = 1;
    g_thread_joinable = 1;
    pthread_mutex_unlock(&g_lock);

    for (int i = 0; i < 200; i++) {
        if (valkey_wrapper_ping() == VALKEY_WRAPPER_OK) return VALKEY_WRAPPER_OK;
        usleep(10000);
    }

    set_error("valkey did not become ready");
    return VALKEY_WRAPPER_ERR;
}

int valkey_wrapper_stop(void) {
    pthread_mutex_lock(&g_lock);
    int active = g_thread_active;
    int joinable = g_thread_joinable;
    pthread_mutex_unlock(&g_lock);
    if (!active && !joinable) return VALKEY_WRAPPER_OK;

    if (active && server.el != NULL) {
        aeStop(server.el);
    }

    for (int i = 0; i < 200; i++) {
        pthread_mutex_lock(&g_lock);
        active = g_thread_active;
        pthread_mutex_unlock(&g_lock);
        if (!active) return VALKEY_WRAPPER_OK;
        usleep(10000);
    }

    if (active) {
        set_error("valkey did not stop before timeout");
        return VALKEY_WRAPPER_ERR;
    }

    if (joinable) {
        int rc = pthread_join(g_thread, NULL);
        if (rc != 0) {
            set_error_fmt("pthread_join failed", strerror(rc));
            return VALKEY_WRAPPER_ERR;
        }
    }

    pthread_mutex_lock(&g_lock);
    g_started = 0;
    g_thread_active = 0;
    g_thread_joinable = 0;
    pthread_mutex_unlock(&g_lock);
    return VALKEY_WRAPPER_OK;
}

int valkey_wrapper_is_running(void) {
    pthread_mutex_lock(&g_lock);
    int active = g_thread_active;
    pthread_mutex_unlock(&g_lock);
    if (!active) return 0;
    return valkey_wrapper_ping() == VALKEY_WRAPPER_OK ? 1 : 0;
}

int valkey_wrapper_put(const uint8_t *key, size_t key_len, const uint8_t *value, size_t value_len) {
    if (key == NULL || key_len == 0 || value == NULL) {
        set_error("invalid put arguments");
        return VALKEY_WRAPPER_ERR;
    }
    valkeyContext *ctx = connect_ctx();
    if (ctx == NULL) return VALKEY_WRAPPER_ERR;
    valkeyReply *reply = (valkeyReply *)valkeyCommand(ctx, "SET %b %b", key, key_len, value, value_len);
    if (reply == NULL) {
        set_error_fmt("valkey set failed", ctx->errstr);
        valkeyFree(ctx);
        return VALKEY_WRAPPER_ERR;
    }
    int ok = (reply->type == VALKEY_REPLY_STATUS && reply->str != NULL && strcmp(reply->str, "OK") == 0);
    freeReplyObject(reply);
    valkeyFree(ctx);
    if (!ok) {
        set_error("valkey set returned unexpected reply");
        return VALKEY_WRAPPER_ERR;
    }
    return VALKEY_WRAPPER_OK;
}

int valkey_wrapper_get(const uint8_t *key, size_t key_len, uint8_t **out_value, size_t *out_len) {
    if (key == NULL || key_len == 0 || out_value == NULL || out_len == NULL) {
        set_error("invalid get arguments");
        return VALKEY_WRAPPER_ERR;
    }
    *out_value = NULL;
    *out_len = 0;

    valkeyContext *ctx = connect_ctx();
    if (ctx == NULL) return VALKEY_WRAPPER_ERR;
    valkeyReply *reply = (valkeyReply *)valkeyCommand(ctx, "GET %b", key, key_len);
    if (reply == NULL) {
        set_error_fmt("valkey get failed", ctx->errstr);
        valkeyFree(ctx);
        return VALKEY_WRAPPER_ERR;
    }
    if (reply->type == VALKEY_REPLY_NIL) {
        freeReplyObject(reply);
        valkeyFree(ctx);
        return VALKEY_WRAPPER_NOT_FOUND;
    }
    if (reply->type != VALKEY_REPLY_STRING) {
        freeReplyObject(reply);
        valkeyFree(ctx);
        set_error("valkey get returned unexpected reply");
        return VALKEY_WRAPPER_ERR;
    }

    uint8_t *copy = (uint8_t *)zmalloc(reply->len);
    if (copy == NULL && reply->len != 0) {
        freeReplyObject(reply);
        valkeyFree(ctx);
        set_error("value allocation failed");
        return VALKEY_WRAPPER_ERR;
    }
    if (reply->len != 0) memcpy(copy, reply->str, reply->len);
    *out_value = copy;
    *out_len = reply->len;
    freeReplyObject(reply);
    valkeyFree(ctx);
    return VALKEY_WRAPPER_OK;
}

int valkey_wrapper_delete(const uint8_t *key, size_t key_len, int64_t *deleted) {
    if (key == NULL || key_len == 0) {
        set_error("invalid delete arguments");
        return VALKEY_WRAPPER_ERR;
    }
    if (deleted) *deleted = 0;
    valkeyContext *ctx = connect_ctx();
    if (ctx == NULL) return VALKEY_WRAPPER_ERR;
    valkeyReply *reply = (valkeyReply *)valkeyCommand(ctx, "DEL %b", key, key_len);
    if (reply == NULL) {
        set_error_fmt("valkey del failed", ctx->errstr);
        valkeyFree(ctx);
        return VALKEY_WRAPPER_ERR;
    }
    if (reply->type != VALKEY_REPLY_INTEGER) {
        freeReplyObject(reply);
        valkeyFree(ctx);
        set_error("valkey del returned unexpected reply");
        return VALKEY_WRAPPER_ERR;
    }
    if (deleted) *deleted = reply->integer;
    freeReplyObject(reply);
    valkeyFree(ctx);
    return VALKEY_WRAPPER_OK;
}

void valkey_wrapper_free(uint8_t *ptr) {
    zfree(ptr);
}
