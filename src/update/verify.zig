const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{
    NoSigningKey,
    BadKey,
    BadSignature,
    SignatureMismatch,
    ChecksumMissing,
    ChecksumMismatch,
};

pub fn hexLen(comptime n: usize) usize {
    return n * 2;
}

pub fn verifySignature(message: []const u8, sig_hex: []const u8, pubkey_hex: []const u8) Error!void {
    const key_text = std.mem.trim(u8, pubkey_hex, " \t\r\n");
    if (key_text.len == 0) return error.NoSigningKey;
    var key_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    if (key_text.len != hexLen(key_bytes.len)) return error.BadKey;
    _ = std.fmt.hexToBytes(&key_bytes, key_text) catch return error.BadKey;
    const pk = Ed25519.PublicKey.fromBytes(key_bytes) catch return error.BadKey;

    const sig_text = std.mem.trim(u8, sig_hex, " \t\r\n");
    var sig_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    if (sig_text.len != hexLen(sig_bytes.len)) return error.BadSignature;
    _ = std.fmt.hexToBytes(&sig_bytes, sig_text) catch return error.BadSignature;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);

    sig.verifyStrict(message, pk) catch return error.SignatureMismatch;
}

pub fn hashFor(sums: []const u8, filename: []const u8) Error![Sha256.digest_length]u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 64 + 2) continue;
        var rest = line[64..];
        if (rest[0] != ' ') continue;
        rest = rest[1..];
        if (rest.len > 0 and (rest[0] == ' ' or rest[0] == '*')) rest = rest[1..];
        if (std.mem.startsWith(u8, rest, "./")) rest = rest[2..];
        if (!std.mem.eql(u8, rest, filename)) continue;
        var out: [Sha256.digest_length]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, line[0..64]) catch continue;
        return out;
    }
    return error.ChecksumMissing;
}

pub fn checkHash(data: []const u8, expected: [Sha256.digest_length]u8) Error!void {
    var got: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &got, .{});
    if (!std.crypto.timing_safe.eql([Sha256.digest_length]u8, got, expected)) return error.ChecksumMismatch;
}

// signature first. a checksum sitting next to the file only catches corruption
pub fn verifyDownload(sums: []const u8, sig_hex: []const u8, pubkey_hex: []const u8, filename: []const u8, data: []const u8) Error!void {
    try verifySignature(sums, sig_hex, pubkey_hex);
    const want = try hashFor(sums, filename);
    try checkHash(data, want);
}

fn testKey(seed_byte: u8) !Ed25519.KeyPair {
    const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(seed_byte);
    return Ed25519.KeyPair.generateDeterministic(seed);
}

fn hexOf(bytes: []const u8, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "{x}", .{bytes}) catch unreachable;
}

const sums_fixture =
    "9ec0061952a6f5c0e86e8add47e62ebf69688970f5851d7656fa97c6bbbeb5c8  ./nodos-v1.0.0-aarch64-linux.tar.gz\n" ++
    "49b89824e18d15c2a47432cfc114a66611c46b148549e472301eaefe0202fcd2  ./nodos-v1.0.0-x86_64-linux.tar.gz\n";

test "a good signature verifies, anything else does not" {
    const kp = try testKey(7);
    const sig = try kp.sign(sums_fixture, null);
    var sig_buf: [128]u8 = undefined;
    var key_buf: [64]u8 = undefined;
    const sig_hex = hexOf(&sig.toBytes(), &sig_buf);
    const key_hex = hexOf(&kp.public_key.toBytes(), &key_buf);

    try verifySignature(sums_fixture, sig_hex, key_hex);
    var padded: [140]u8 = undefined;
    const p = try std.fmt.bufPrint(&padded, "  {s}\r\n", .{sig_hex});
    try verifySignature(sums_fixture, p, key_hex);

    var tampered: [sums_fixture.len]u8 = undefined;
    @memcpy(&tampered, sums_fixture);
    tampered[3] ^= 1;
    try std.testing.expectError(error.SignatureMismatch, verifySignature(&tampered, sig_hex, key_hex));

    const other = try testKey(8);
    var other_buf: [64]u8 = undefined;
    try std.testing.expectError(error.SignatureMismatch, verifySignature(sums_fixture, sig_hex, hexOf(&other.public_key.toBytes(), &other_buf)));

    const forged = try other.sign(sums_fixture, null);
    var forged_buf: [128]u8 = undefined;
    try std.testing.expectError(error.SignatureMismatch, verifySignature(sums_fixture, hexOf(&forged.toBytes(), &forged_buf), key_hex));
}

test "malformed keys and signatures are rejected with the right error" {
    const kp = try testKey(1);
    var key_buf: [64]u8 = undefined;
    const key_hex = hexOf(&kp.public_key.toBytes(), &key_buf);
    var sig_buf: [128]u8 = undefined;
    const sig_hex = hexOf(&(try kp.sign("x", null)).toBytes(), &sig_buf);

    const zz_key: [64]u8 = @splat('z');
    const zz_sig: [128]u8 = @splat('z');
    const short_sig: [126]u8 = @splat('0');
    try std.testing.expectError(error.NoSigningKey, verifySignature("x", sig_hex, ""));
    try std.testing.expectError(error.NoSigningKey, verifySignature("x", sig_hex, "  \n"));
    try std.testing.expectError(error.BadKey, verifySignature("x", sig_hex, "abcd"));
    try std.testing.expectError(error.BadKey, verifySignature("x", sig_hex, &zz_key));
    try std.testing.expectError(error.BadSignature, verifySignature("x", "", key_hex));
    try std.testing.expectError(error.BadSignature, verifySignature("x", &short_sig, key_hex));
    try std.testing.expectError(error.BadSignature, verifySignature("x", &zz_sig, key_hex));
}

test "checksum lookup handles sha256sum formats" {
    const x86 = try hashFor(sums_fixture, "nodos-v1.0.0-x86_64-linux.tar.gz");
    try std.testing.expectEqual(@as(u8, 0x49), x86[0]);
    try std.testing.expectEqual(@as(u8, 0xd2), x86[31]);
    _ = try hashFor("49b89824e18d15c2a47432cfc114a66611c46b148549e472301eaefe0202fcd2 *file.tgz\n", "file.tgz");
    _ = try hashFor("49b89824e18d15c2a47432cfc114a66611c46b148549e472301eaefe0202fcd2  file.tgz\r\n", "file.tgz");
    try std.testing.expectError(error.ChecksumMissing, hashFor(sums_fixture, "nodos-v1.0.0-riscv64-linux.tar.gz"));
    try std.testing.expectError(error.ChecksumMissing, hashFor(sums_fixture, "x86_64-linux.tar.gz"));
    try std.testing.expectError(error.ChecksumMissing, hashFor("", "a"));
    try std.testing.expectError(error.ChecksumMissing, hashFor("not a hash line\n\n", "a"));
}

test "hash check catches a single changed byte" {
    var h: [32]u8 = undefined;
    Sha256.hash("release bytes", &h, .{});
    try checkHash("release bytes", h);
    try std.testing.expectError(error.ChecksumMismatch, checkHash("release bytez", h));
    try std.testing.expectError(error.ChecksumMismatch, checkHash("", h));
}

test "full download check: signature first, then hash" {
    const kp = try testKey(3);
    const data = "the tarball";
    var h: [32]u8 = undefined;
    Sha256.hash(data, &h, .{});
    var sums_buf: [128]u8 = undefined;
    const sums = try std.fmt.bufPrint(&sums_buf, "{x}  ./nodos-v2.0.0-x86_64-linux.tar.gz\n", .{&h});
    const sig = try kp.sign(sums, null);
    var sig_buf: [128]u8 = undefined;
    var key_buf: [64]u8 = undefined;
    const sig_hex = hexOf(&sig.toBytes(), &sig_buf);
    const key_hex = hexOf(&kp.public_key.toBytes(), &key_buf);

    try verifyDownload(sums, sig_hex, key_hex, "nodos-v2.0.0-x86_64-linux.tar.gz", data);
    try std.testing.expectError(error.ChecksumMismatch, verifyDownload(sums, sig_hex, key_hex, "nodos-v2.0.0-x86_64-linux.tar.gz", "swapped tarball"));
    var evil_buf: [128]u8 = undefined;
    var eh: [32]u8 = undefined;
    Sha256.hash("swapped tarball", &eh, .{});
    const evil = try std.fmt.bufPrint(&evil_buf, "{x}  ./nodos-v2.0.0-x86_64-linux.tar.gz\n", .{&eh});
    try std.testing.expectError(error.SignatureMismatch, verifyDownload(evil, sig_hex, key_hex, "nodos-v2.0.0-x86_64-linux.tar.gz", "swapped tarball"));
}
