// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
const std = @import("std");
const crypto_backend = @import("crypto_backend");

test "timeseries crypto_backend seam round-trips AES-256-GCM" {
    const key = [_]u8{0x44} ** 32;
    const nonce = [_]u8{0x55} ** 12;
    const pt = "ts block payload";
    var ct: [pt.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    try crypto_backend.Aead.seal(.aes_256_gcm, &key, &nonce, "aad", pt, &ct, &tag);
    var rt: [pt.len]u8 = undefined;
    try crypto_backend.Aead.open(.aes_256_gcm, &key, &nonce, "aad", &ct, &tag, &rt);
    try std.testing.expectEqualSlices(u8, pt, &rt);
    crypto_backend.assertActive();
}
