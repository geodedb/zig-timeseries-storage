<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright (c) 2024-2026 CodePros -->

# FIPS-140-3 Mode (`-Dfips`)

## Flag semantics

`timeseries-storage` builds with a `-Dfips` flag (default `false`). When **off**,
security crypto routes through `src/std_shim.zig` (pure `std.crypto`) with zero
overhead, no `fips` dependency, and no OpenSSL link. When **on**
(`-Dfips=true -Dopenssl_path=<prefix>`), the same call sites route through the
linked OpenSSL 3.x FIPS-140-3 provider via the lazy `fips` package, and
`crypto_backend.assertActive()` hard-fails if the validated provider is absent.

```sh
zig build test --summary all
OPENSSL_CONF=/usr/local/ssl/ssl/openssl.cnf zig build test -Dfips=true -Dopenssl_path=/usr/local/ssl --summary all
# or:  make test-dual
```

This repo has exactly ONE local `build_options` instance for the `fips` flag
(GAP-0020-safe). The `wal`/`uuid`/`thread_pool` dependencies carry their OWN
private `build_options`, resolved separately as dependency modules.

## Routed (security) call sites

| Site | Primitive | Seam call |
|------|-----------|-----------|
| `src/segment.zig` block nonce | per-block random nonce | `crypto_backend.Csprng.bytes` |
| `src/segment.zig` block encrypt | TSSEG003 block AES-256-GCM seal | `crypto_backend.Aead.seal(.aes_256_gcm, …)` |
| `src/segment.zig` block decrypt | TSSEG003 block AES-256-GCM open | `crypto_backend.Aead.open(.aes_256_gcm, …)` |
| `src/manifest.zig` `wrapEncrypted` nonce | per-manifest random nonce | `crypto_backend.Csprng.bytes` |
| `src/manifest.zig` `wrapEncrypted` | TSMNF002 manifest AES-256-GCM seal | `crypto_backend.Aead.seal(.aes_256_gcm, …)` |
| `src/manifest.zig` `unwrapEncrypted` | TSMNF002 manifest AES-256-GCM open | `crypto_backend.Aead.open(.aes_256_gcm, …)` |
| `src/engine.zig` `opaqueSeriesId` | keyed HMAC-SHA256 PRF | `crypto_backend.Mac.hmac(.sha256, …)` |

## `fips-exempt` (allow-listed non-security) uses

| Site | Reason |
|------|--------|
| `src/segment.zig` `Crc32C` | CRC32C per-block framing checksum for plaintext (TSSEG002); encrypted blocks use the AES-GCM tag |
| `src/segment.zig` / `src/manifest.zig` `Aes256Gcm` aliases | compile-time nonce/tag sizes only; AEAD goes through the seam |
| `src/manifest.zig` `Crc32` framing checksum | CRC32 manifest framing checksum, not adversary-resistant integrity (AES-GCM tag covers that) |

## Behavior changes / removals under `-Dfips=true`

None. Block/manifest framing (`nonce(12) || tag(16) || ciphertext`) is unchanged;
series-id bytes are byte-identical under both modes (HMAC-SHA256 in both backends).
