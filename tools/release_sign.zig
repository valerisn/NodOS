const std = @import("std");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;
const verify = @import("verify");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [512]u8 = undefined;
    var out: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &out.interface;

    if (args.len < 2) fail("usage: release-sign keygen | public | sign FILE | verify FILE SIG PUB");

    if (std.mem.eql(u8, args[1], "keygen")) {
        var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
        try io.randomSecure(&seed);
        const kp = Ed25519.KeyPair.generateDeterministic(seed) catch fail("could not derive a key, try again");
        try w.print("secret={x}\npublic={x}\n", .{ &seed, &kp.public_key.toBytes() });
    } else if (std.mem.eql(u8, args[1], "public")) {
        const kp = try keyFromEnv(init);
        try w.print("{x}\n", .{&kp.public_key.toBytes()});
    } else if (std.mem.eql(u8, args[1], "sign")) {
        if (args.len != 3) fail("usage: release-sign sign FILE");
        const kp = try keyFromEnv(init);
        const data = Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(16 * 1024 * 1024)) catch fail("cannot read the file to sign");
        const sig = kp.sign(data, null) catch fail("signing failed");
        try w.print("{x}\n", .{&sig.toBytes()});
    } else if (std.mem.eql(u8, args[1], "verify")) {
        if (args.len != 5) fail("usage: release-sign verify FILE SIGFILE PUBFILE");
        const data = Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(16 * 1024 * 1024)) catch fail("cannot read FILE");
        const sig_hex = Io.Dir.cwd().readFileAlloc(io, args[3], arena, .limited(4096)) catch fail("cannot read SIGFILE");
        const pub_hex = Io.Dir.cwd().readFileAlloc(io, args[4], arena, .limited(4096)) catch fail("cannot read PUBFILE");
        if (std.mem.trim(u8, pub_hex, " \t\r\n").len == 0) fail("PUBFILE is empty: no public key is published yet");
        verify.verifySignature(data, sig_hex, pub_hex) catch |err| {
            std.debug.print("release-sign: signature check FAILED ({s})\n", .{@errorName(err)});
            std.process.exit(1);
        };
        try w.writeAll("signature ok\n");
    } else {
        fail("unknown command");
    }
    try w.flush();
}

fn keyFromEnv(init: std.process.Init) !Ed25519.KeyPair {
    const hex = init.environ_map.get("NODOS_SIGNING_KEY") orelse fail("NODOS_SIGNING_KEY is not set");
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    const trimmed = std.mem.trim(u8, hex, " \t\r\n");
    if (trimmed.len != seed.len * 2) fail("NODOS_SIGNING_KEY must be 64 hex characters");
    _ = std.fmt.hexToBytes(&seed, trimmed) catch fail("NODOS_SIGNING_KEY is not valid hex");
    return Ed25519.KeyPair.generateDeterministic(seed) catch fail("NODOS_SIGNING_KEY is not a usable key");
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("release-sign: {s}\n", .{msg});
    std.process.exit(1);
}

test "a signature made here verifies with the public key printed here" {
    const seed: [32]u8 = @splat(5);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig = try kp.sign("sums", null);
    try sig.verifyStrict("sums", kp.public_key);
}
