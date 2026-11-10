const std = @import("std");
const Io = std.Io;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

pub const secret_len = 20;
pub const step_s: i64 = 30;
pub const digits = 6;
pub const b32_len = 32;

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

pub fn encodeSecret(secret: [secret_len]u8) [b32_len]u8 {
    var out: [b32_len]u8 = undefined;
    var acc: u32 = 0;
    var bits: u5 = 0;
    var n: usize = 0;
    for (secret) |b| {
        acc = (acc << 8) | b;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            out[n] = alphabet[(acc >> bits) & 31];
            n += 1;
        }
        acc &= (@as(u32, 1) << bits) - 1;
    }
    return out;
}

pub fn decodeSecret(text: []const u8) ?[secret_len]u8 {
    if (text.len != b32_len) return null;
    var out: [secret_len]u8 = undefined;
    var acc: u32 = 0;
    var bits: u5 = 0;
    var n: usize = 0;
    for (text) |c| {
        const v: u32 = if (c >= 'A' and c <= 'Z') c - 'A' else if (c >= '2' and c <= '7') c - '2' + 26 else return null;
        acc = (acc << 5) | v;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            out[n] = @intCast((acc >> bits) & 0xff);
            n += 1;
            acc &= (@as(u32, 1) << bits) - 1;
        }
    }
    return out;
}

pub fn generate(io: Io) [secret_len]u8 {
    var s: [secret_len]u8 = undefined;
    io.random(&s);
    return s;
}

pub fn counterAt(now_s: i64) u64 {
    return @intCast(@divFloor(@max(now_s, 0), step_s));
}

pub fn code(secret: [secret_len]u8, counter: u64) u32 {
    var msg: [8]u8 = undefined;
    std.mem.writeInt(u64, &msg, counter, .big);
    var mac: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&mac, &msg, &secret);
    const off = mac[mac.len - 1] & 0x0f;
    const bin = (@as(u32, mac[off] & 0x7f) << 24) | (@as(u32, mac[off + 1]) << 16) | (@as(u32, mac[off + 2]) << 8) | mac[off + 3];
    return bin % 1_000_000;
}

/// Accepts the code for the current 30 second step and the one on either side
/// (clock drift, a slow typist). `last_used` is the highest counter already
/// accepted for this user; a code at or below it is a replay and is refused.
/// On success it is moved up to the counter that matched.
pub fn verify(secret: [secret_len]u8, now_s: i64, input: []const u8, last_used: *u64) bool {
    if (input.len != digits) return false;
    var typed: u32 = 0;
    for (input) |c| {
        if (c < '0' or c > '9') return false;
        typed = typed * 10 + (c - '0');
    }
    const now = counterAt(now_s);
    var matched: ?u64 = null;
    var delta: i64 = -1;
    while (delta <= 1) : (delta += 1) {
        const ctr_i = @as(i64, @intCast(now)) + delta;
        if (ctr_i < 0) continue;
        const ctr: u64 = @intCast(ctr_i);
        const expected = code(secret, ctr);
        // no early exit, so timing does not say which step matched
        if (expected == typed and ctr > last_used.*) matched = if (matched) |m| @max(m, ctr) else ctr;
    }
    if (matched) |m| {
        last_used.* = m;
        return true;
    }
    return false;
}

pub fn uri(buf: []u8, account: []const u8, secret_b32: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "otpauth://totp/NodOS:{s}?secret={s}&issuer=NodOS&algorithm=SHA1&digits=6&period=30", .{ account, secret_b32 }) catch null;
}

const rfc_secret: [secret_len]u8 = "12345678901234567890".*;

test "RFC 6238 vectors (SHA1, last six digits of the published 8 digit codes)" {
    try std.testing.expectEqual(@as(u32, 287082), code(rfc_secret, counterAt(59)));
    try std.testing.expectEqual(@as(u32, 81804), code(rfc_secret, counterAt(1111111109)));
    try std.testing.expectEqual(@as(u32, 50471), code(rfc_secret, counterAt(1111111111)));
    try std.testing.expectEqual(@as(u32, 5924), code(rfc_secret, counterAt(1234567890)));
    try std.testing.expectEqual(@as(u32, 279037), code(rfc_secret, counterAt(2000000000)));
}

test "base32 round trips and matches the known encoding" {
    const enc = encodeSecret(rfc_secret);
    try std.testing.expectEqualStrings("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", &enc);
    try std.testing.expectEqualSlices(u8, &rfc_secret, &decodeSecret(&enc).?);
    try std.testing.expect(decodeSecret("short") == null);
    try std.testing.expect(decodeSecret("gezdgnbvgy3tqojqgezdgnbvgy3tqojq") == null);
    try std.testing.expect(decodeSecret("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJ1") == null);
    var rnd: [secret_len]u8 = undefined;
    @memset(&rnd, 0xA5);
    try std.testing.expectEqualSlices(u8, &rnd, &decodeSecret(&encodeSecret(rnd)).?);
}

test "verify: current step and neighbours pass, far steps and junk fail" {
    var last: u64 = 0;
    const now: i64 = 1111111109;
    try std.testing.expect(verify(rfc_secret, now, "081804", &last));
    last = 0;
    try std.testing.expect(verify(rfc_secret, now + 30, "081804", &last));
    last = 0;
    try std.testing.expect(verify(rfc_secret, now - 30, "081804", &last));
    last = 0;
    try std.testing.expect(!verify(rfc_secret, now + 90, "081804", &last));
    try std.testing.expect(!verify(rfc_secret, now, "08180", &last));
    try std.testing.expect(!verify(rfc_secret, now, "0818041", &last));
    try std.testing.expect(!verify(rfc_secret, now, "08180a", &last));
    try std.testing.expect(!verify(rfc_secret, now, "", &last));
    try std.testing.expect(!verify(rfc_secret, now, " 81804", &last));
}

test "a code cannot be used twice, and an older code cannot follow a newer one" {
    var last: u64 = 0;
    const now: i64 = 1111111109;
    try std.testing.expect(verify(rfc_secret, now, "081804", &last));
    try std.testing.expect(!verify(rfc_secret, now, "081804", &last));
    try std.testing.expect(verify(rfc_secret, now + 30, "050471", &last));
    try std.testing.expect(!verify(rfc_secret, now + 30, "081804", &last));
}

test "uri carries the secret and issuer" {
    var buf: [200]u8 = undefined;
    const u = uri(&buf, "kea", "ABC").?;
    try std.testing.expect(std.mem.startsWith(u8, u, "otpauth://totp/NodOS:kea?secret=ABC&issuer=NodOS"));
}
