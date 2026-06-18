# valkey wrapper

Zig build wrapper for `valkey-server`.

Vendor sources live in `vendor/valkey`.

If `vendor/valkey` is missing after cloning this wrapper, fetch it with:

```sh
mkdir -p vendor
git clone --depth 1 https://github.com/valkey-io/valkey.git vendor/valkey
```

```sh
zig build
zig build -Dall=true
```
