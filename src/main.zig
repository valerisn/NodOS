const std = @import("std");
const Io = std.Io;
const nodos = @import("nodos");

const usage =
    \\NodOS - home server management
    \\
    \\Usage: nodos <command>
    \\
    \\Commands:
    \\  serve [--config PATH]   Run the server
    \\  version    Print version and exit
    \\  help       Show this message
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [512]u8 = undefined;
    var out: Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const w = &out.interface;

    const cmd = nodos.cli.parse(args[1..]) catch |err| {
        std.debug.print("nodos: {s}\n\n{s}", .{ @errorName(err), usage });
        std.process.exit(2);
    };

    switch (cmd.command) {
        .help => try w.writeAll(usage),
        .version => try w.print("nodos {s}\n", .{nodos.version}),
        .serve => {
            std.debug.print("nodos: serve is not implemented yet\n", .{});
            std.process.exit(1);
        },
    }
    try w.flush();
}
