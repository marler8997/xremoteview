// xsnoop
// An Xserver that forwards data between another Xserver and its clients along with
// forwarding that data to an instance of xview.
const std = @import("std");
const os = std.os;

const common = @import("common.zig");

const global = struct {
    pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
};

fn connectRemoteView(addr: u32, port: u16) !os.socket_t {
    var sockaddr: os.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, addr),
        .zero = undefined,
    };
    const sock = try os.socket(sockaddr.family, os.SOCK.STREAM, os.IPPROTO.TCP);
    errdefer os.close(sock);

    try os.connect(sock, @ptrCast(*const os.sockaddr, &sockaddr), @sizeOf(@TypeOf(sockaddr)));
    return sock;
}

pub fn main() !u8 {
    //const args = try std.process.argsAlloc(global.arena.allocator());

    const epoll_fd = os.epoll_create1(os.linux.EPOLL.CLOEXEC) catch |err| {
        std.log.err("epoll_create failed with {s}", .{@errorName(err)});
        return 0xff;
    };

    // just hardcode address for now
    const remote_view_addr: u32 = 0x7f000001;
    const remote_view_sock = try connectRemoteView(remote_view_addr, 1234);
    defer {
        os.shutdown(remote_view_sock, .both) catch {};
    }

    // just hardcode for now
    const listen_path = "/tmp/.X11-unix/X8";

    if (try common.fileExistsAbsolute(listen_path)) {
        std.log.info("rm {s}", .{listen_path});
        try std.fs.deleteFileAbsolute(listen_path);
    }

    const listen_sock = try common.createServer(listen_path);
    std.log.info("listening at '{s}', DISPLAY=:8", .{listen_path});

    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    //defer gpa.deinit();

    var listen_sock_handler = ListenSockHandler{
        .remote_view_sock = remote_view_sock,
        .epoll_fd = epoll_fd,
        .allocator = gpa.allocator(),
        .sock = listen_sock,
    };
    try epollAddHandler(epoll_fd, listen_sock, &listen_sock_handler.base);

    while (true) {
        var events : [10]os.linux.epoll_event = undefined;
        const count = os.epoll_wait(epoll_fd, &events, 0);
        switch (os.errno(count)) {
            .SUCCESS => {},
            else => |e| std.debug.panic("epoll_wait failed, errno={}", .{e}),
        }
        for (events[0..count]) |*event| {
            const handler = @intToPtr(*EpollHandler, event.data.ptr);
            handler.handle(handler) catch |err| switch (err) {
                error.Handled => {},
                else => |e| return e,
            };
        }
    }
}

const EpollHandler = struct {
    handle: fn(base: *EpollHandler) anyerror!void,
};
fn epollAddHandler(epoll_fd: os.fd_t, fd: os.fd_t, handler: *EpollHandler) !void {
    var event = os.linux.epoll_event {
        .events = os.linux.EPOLL.IN,
        .data = os.linux.epoll_data { .ptr = @ptrToInt(handler) },
    };
    try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, fd, &event);
}

pub fn sendAll(sock: os.socket_t, data: []const u8) !void {
    const sent = try os.send(sock, data, 0);
    if (sent != data.len) {
        std.log.err("send {} only sent {}\n", .{data.len, sent});
        return error.DidNotSendAllData;
    }
}

const ListenSockHandler = struct {
    base: EpollHandler = .{ .handle = handle },
    remote_view_sock: os.socket_t,
    epoll_fd: os.fd_t,
    allocator: std.mem.Allocator,
    sock: os.socket_t,
    fn handle(base: *EpollHandler) !void {
        const self = @fieldParentPtr(ListenSockHandler, "base", base);

        var addr: os.sockaddr.un = undefined;
        var len: os.socklen_t = @sizeOf(@TypeOf(addr));

        const new_fd = os.accept(self.sock, @ptrCast(*os.sockaddr, &addr), &len, os.SOCK.CLOEXEC) catch |err| switch (err) {
            error.ConnectionAborted,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            error.ProtocolFailure,
            error.BlockedByFirewall,
            error.WouldBlock,
            error.ConnectionResetByPeer,
            error.NetworkSubsystemFailed,
            => |e| {
                std.log.info("accept failed with {s}", .{@errorName(e)});
                return;
            },
            error.FileDescriptorNotASocket,
            error.SocketNotListening,
            error.OperationNotSupported,
            error.Unexpected,
            => unreachable,
        };
        errdefer os.close(new_fd);

        const forward_sock = try common.connectXserver();

        const new_handler = self.allocator.create(DataSockHandler) catch |err| switch (err) {
            error.OutOfMemory => {
                std.log.err("s={}: failed to allocate handler", .{new_fd});
                return error.Handled;
            },
        };
        errdefer self.allocator.destroy(new_handler);
        new_handler.* = .{
            .allocator = self.allocator,
            .client_sock = new_fd,
            .forward_sock = forward_sock,
        };
        epollAddHandler(self.epoll_fd, new_fd, &new_handler.client_sock_handler) catch |err| switch (err) {
            error.SystemResources,
            error.UserResourceLimitReached,
            => |e| {
                std.log.err("s={}: epoll add failed with {s}", .{new_fd, @errorName(e)});
                return error.Handled;
            },
            error.FileDescriptorIncompatibleWithEpoll,
            error.FileDescriptorAlreadyPresentInSet,
            error.OperationCausesCircularLoop,
            error.FileDescriptorNotRegistered,
            error.Unexpected,
            => unreachable,
        };
        epollAddHandler(self.epoll_fd, forward_sock, &new_handler.server_sock_handler) catch |err| switch (err) {
            error.SystemResources,
            error.UserResourceLimitReached,
            => |e| {
                std.log.err("s={}: epoll add failed with {s}", .{new_fd, @errorName(e)});
                return error.Handled;
            },
            error.FileDescriptorIncompatibleWithEpoll,
            error.FileDescriptorAlreadyPresentInSet,
            error.OperationCausesCircularLoop,
            error.FileDescriptorNotRegistered,
            error.Unexpected,
            => unreachable,
        };
        std.log.info("s={}: new connection", .{new_fd});
        try sendAll(self.remote_view_sock, "new client!\n");
    }
};

const DataSockHandler = struct {
    client_sock_handler: EpollHandler = .{ .handle = handleClient },
    server_sock_handler: EpollHandler = .{ .handle = handleServer },
    allocator: std.mem.Allocator,
    client_sock: os.socket_t,
    forward_sock: os.socket_t,
    partial: std.ArrayListAlignedUnmanaged(u8, 8) = .{},
    state: union(enum) {
        auth: struct {
            authenticated: bool = false,
        },
        begun: void,
    } = .{ .auth = .{} },

    fn deinit(self: *DataSockHandler) void {
        os.close(self.forward_sock);
        os.close(self.client_sock);
        self.partial.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn forward(self: *DataSockHandler, src: os.fd_t, dst: os.fd_t) !void {
        var buf: [std.mem.page_size]u8 = undefined;
        const len = os.read(src, &buf) catch |err| {
            std.log.err("{} > {}: read failed with {s}, closing", .{src, dst, @errorName(err)});
            self.deinit();
            return;
        };
        if (len == 0) {
            std.log.info("{} > {}: EOF", .{src, dst});
            self.deinit();
            return;
        }
        const sent = os.write(dst, buf[0..len]) catch |err| {
            std.log.err("{} > {}: write {} bytes failed with {s}", .{src, dst, len, @errorName(err)});
            self.deinit();
            return;
        };
        if (sent != len) {
            std.log.err("{} > {}: write {} bytes returned {}", .{src, dst, len, sent});
            self.deinit();
            return;
        }
        std.log.info("{} > {}: {} bytes", .{src, dst, len});
    }
    fn handleServer(forward_base: *EpollHandler) !void {
        const self = @fieldParentPtr(DataSockHandler, "server_sock_handler", forward_base);
        try self.forward(self.forward_sock, self.client_sock);
    }
    fn handleClient(base: *EpollHandler) !void {
        const self = @fieldParentPtr(DataSockHandler, "client_sock_handler", base);
        try self.forward(self.client_sock, self.forward_sock);
    }
};
