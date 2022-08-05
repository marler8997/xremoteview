// xsnoop
// An Xserver that forwards data between another Xserver and its clients along with
// forwarding that data to an instance of xview.
const std = @import("std");

const global = struct {
    pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
};

pub fn main() !void {
    const args = try std.process.argsAlloc(global.arena.allocator());
    std.log.info("todo {s}", .{args});
}
