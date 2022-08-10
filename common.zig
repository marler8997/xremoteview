const std = @import("std");
const os = std.os;

pub fn initUnixAddr(path: []const u8) error{PathTooLong}!os.sockaddr.un {
    var result: os.sockaddr.un = .{ .family = os.AF.UNIX, .path = undefined };
    if (path.len + 1 > result.path.len) return error.PathTooLong;
    std.mem.copy(u8, &result.path, path);
    result.path[path.len] = 0;
    return result;
}

pub fn createServer(listen_path: []const u8) !os.socket_t {
    const addr = try initUnixAddr(listen_path);

    const sock = try os.socket(os.AF.UNIX, os.SOCK.STREAM, 0);
    errdefer os.close(sock);

    try os.bind(sock, @ptrCast(*const os.sockaddr, &addr), @sizeOf(@TypeOf(addr)));
    try os.listen(sock, 0);
    return sock;
}

pub fn connectXserver() !os.socket_t {
    // TODO: hardcoded path for now
    const addr = try initUnixAddr("/tmp/.X11-unix/X0");
    const sock = try os.socket(os.AF.UNIX, os.SOCK.STREAM, 0);
    errdefer os.close(sock);

    try os.connect(sock, @ptrCast(*const os.sockaddr, &addr), @sizeOf(@TypeOf(addr)));
    return sock;
}

pub fn fileExistsAbsolute(path: []const u8) !bool {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}
