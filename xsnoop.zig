// xsnoop
// An Xserver that forwards data between another Xserver and its clients along with
// forwarding that data to an instance of xview.
const std = @import("std");
const os = std.os;

const global = struct {
    pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
};

fn createServer(listen_path: []const u8) !os.socket_t {
    var addr: os.sockaddr.un = .{ .family = os.AF.UNIX, .path = undefined };
    std.debug.assert(listen_path.len + 1 <= addr.path.len);
    std.mem.copy(u8, &addr.path, listen_path);
    addr.path[listen_path.len] = 0;

    const sock = try os.socket(os.AF.UNIX, os.SOCK.STREAM, 0);
    errdefer os.close(sock);

    try os.bind(sock, @ptrCast(*os.sockaddr, &addr), @sizeOf(@TypeOf(addr)));
    try os.listen(sock, 0);
    return sock;
}

pub fn main() !u8 {
    //const args = try std.process.argsAlloc(global.arena.allocator());

    const epoll_fd = os.epoll_create1(os.linux.EPOLL.CLOEXEC) catch |err| {
        std.log.err("epoll_create failed with {s}", .{@errorName(err)});
        return 0xff;
    };

    // just hardcode for now
    const listen_path = "/tmp/.X11-unix/X8";

    if (try fileExistsAbsolute(listen_path)) {
        std.log.info("rm {s}", .{listen_path});
        try std.fs.deleteFileAbsolute(listen_path);
    }

    const listen_sock = try createServer(listen_path);
    std.log.info("listening at '{s}', DISPLAY=:8", .{listen_path});

    try epollAdd(epoll_fd, os.linux.EPOLL.CTL_ADD, listen_sock, os.linux.EPOLL.IN, .listen_sock);

    var data_sock: os.socket_t = -1;

    while (true) {
        var events : [10]os.linux.epoll_event = undefined;
        const count = os.epoll_wait(epoll_fd, &events, 0);
        switch (os.errno(count)) {
            .SUCCESS => {},
            else => |e| std.debug.panic("epoll_wait failed, errno={}", .{e}),
        }
        for (events[0..count]) |*event| {
            switch (@intToEnum(EpollHandler, event.data.@"u32")) {
                .listen_sock => try onListenSock(epoll_fd, listen_sock, &data_sock),
                .data_sock => try onDataSock(&data_sock),
            }
        }
    }
}

const EpollHandler = enum {
    listen_sock,
    data_sock,
};

fn epollAdd(epoll_fd: os.fd_t, op: u32, fd: os.fd_t, events: u32, handler: EpollHandler) !void {
    var event = os.linux.epoll_event{
        .events = events,
        .data = .{ .@"u32" = @enumToInt(handler) },
    };
    return os.epoll_ctl(epoll_fd, op, fd, &event);
}

fn onListenSock(epoll_fd: os.fd_t, sock: os.socket_t, opt_data_sock_ptr: *os.socket_t) !void {
    var from: os.sockaddr.un = undefined;
    var from_len: os.socklen_t = @sizeOf(@TypeOf(from));

    const client = try os.accept(sock, @ptrCast(*os.sockaddr, &from), &from_len, 0);
    //var from_path_len = from_len - @offsetOf(os.sockaddr.un, "path");
    //if (from_path_len > 0) from_path_len -= 1;
    //var from_path = from.path[0 .. from_path_len];
    if (opt_data_sock_ptr.* != -1) {
        std.log.info("dropping client s={}, already have one", .{client});
        // TODO: call shutdown?
        os.close(client);
    } else {
        std.log.info("new client s={}", .{client});
        try epollAdd(epoll_fd, os.linux.EPOLL.CTL_ADD, client, os.linux.EPOLL.IN, .data_sock);
        opt_data_sock_ptr.* = client;
    }
}

fn onDataSock(sock: *os.socket_t) !void {
    std.log.info("todo: recv on s={}", .{sock.*});
    var buf: [std.mem.page_size]u8 = undefined;
    const len = os.read(sock.*, &buf) catch |err| {
        std.log.info("s={} read failed with {s}", .{sock.*, @errorName(err)});
        os.close(sock.*);
        sock.* = -1;
        return;
    };
    if (len == 0) {
        std.log.info("s={} EOF", .{sock.*});
        os.close(sock.*);
        sock.* = -1;
        return;
    }
    std.log.info("s={} read {} bytes: {}", .{sock.*, len, std.zig.fmtEscapes(buf[0..len])});
}

fn fileExistsAbsolute(path: []const u8) !bool {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}
