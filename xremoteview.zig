const std = @import("std");

// NOTE:
// We should be able to process the commands from an X session
// from any source (i.e. saved to a file).  For now we'll start
// with a TCP server mean to accept data from xsnoop.

pub fn main() !void {
    std.log.info("todo", .{});
}
