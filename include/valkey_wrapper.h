#ifndef VALKEY_WRAPPER_H
#define VALKEY_WRAPPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__) || defined(__clang__)
#define VALKEY_WRAPPER_API __attribute__((visibility("default")))
#else
#define VALKEY_WRAPPER_API
#endif

#define VALKEY_WRAPPER_OK 0
#define VALKEY_WRAPPER_ERR -1
#define VALKEY_WRAPPER_NOT_FOUND 1

VALKEY_WRAPPER_API int valkey_wrapper_start(const char *host, uint16_t port, const char *data_dir, uint32_t max_memory_mib);
VALKEY_WRAPPER_API int valkey_wrapper_stop(void);
VALKEY_WRAPPER_API int valkey_wrapper_is_running(void);
VALKEY_WRAPPER_API int valkey_wrapper_ping(void);
VALKEY_WRAPPER_API int valkey_wrapper_used_memory(uint64_t *out_bytes);

VALKEY_WRAPPER_API int valkey_wrapper_put(const uint8_t *key, size_t key_len, const uint8_t *value, size_t value_len);
VALKEY_WRAPPER_API int valkey_wrapper_put_expiring(const uint8_t *key, size_t key_len, const uint8_t *value, size_t value_len, uint32_t ttl_seconds);
VALKEY_WRAPPER_API int valkey_wrapper_get(const uint8_t *key, size_t key_len, uint8_t **out_value, size_t *out_len);
VALKEY_WRAPPER_API int valkey_wrapper_delete(const uint8_t *key, size_t key_len, int64_t *deleted);
VALKEY_WRAPPER_API void valkey_wrapper_free(uint8_t *ptr);

VALKEY_WRAPPER_API const char *valkey_wrapper_last_error(void);

#undef VALKEY_WRAPPER_API

#ifdef __cplusplus
}
#endif

#endif
