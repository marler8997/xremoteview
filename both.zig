const std = @import("std");
const os = std.os;

const global = struct {
    pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
};

pub fn main() !u8 {
    const all_args = try std.process.argsAlloc(global.arena.allocator());
    const args = if (all_args.len == 0) all_args else all_args[1..];
    if (args.len != 2) {
        std.log.err("expected 2 cmdline args but got {}", .{args.len});
        return 0xff;
    }

    const remoteview_exe = args[0];
    const snoop_exe = args[1];
    std.log.info("TODO: {s} and {s}", .{remoteview_exe, snoop_exe});

    var sockets: [2]i32 = undefined;
    switch (os.errno(os.linux.socketpair(os.AF.UNIX, os.SOCK.STREAM, 0, &sockets))) {
        .SUCCESS => {},
        else => |e| {
            std.log.err("socketpair failed with E{s}", .{@tagName(e)});
            os.exit(0xff);
        },
    }
    std.log.info("created socket pair {} and {}", .{sockets[0], sockets[1]});

    var socket_str_buf: [30]u8 = undefined;
    const view_socket_str = try std.fmt.bufPrint(&socket_str_buf, "{d}", .{sockets[0]});
    var view_proc = std.ChildProcess.init(
        &[_][]const u8 {
            remoteview_exe,
            "--snoop-sock",
            view_socket_str,
        }, global.arena.allocator());
    std.log.info("[SPAWN] {s}", .{remoteview_exe});
    try view_proc.spawn();

    const snoop_socket_str = try std.fmt.bufPrint(&socket_str_buf, "{d}", .{sockets[1]});
    var snoop_proc = std.ChildProcess.init(
        &[_][]const u8 {
            snoop_exe,
            "--snoop-sock",
            snoop_socket_str,
        }, global.arena.allocator());
    std.log.info("[SPAWN] {s}", .{snoop_exe});
    try snoop_proc.spawn();

    const epoll_fd = try os.epoll_create1(os.linux.EPOLL.CLOEXEC);
    const signal_fd = try createSignalfd();
    try epollAdd(epoll_fd, os.linux.EPOLL.CTL_ADD, signal_fd, os.linux.EPOLL.IN, .signal);

    var view_proc_state = [2]ProcState {
        .{ .name = "xremoteview", .pid = view_proc.pid },
        .{ .name = "xsnoop", .pid = snoop_proc.pid },
    };

    // TODO: how do we tell when xremoteview has opened the socket?

    while (true) {
        var events: [10]os.linux.epoll_event = undefined;
        const event_count = os.epoll_wait(epoll_fd, &events, -1);
        for (events[0..event_count]) |*event| {
            switch (@intToEnum(EpollHandler, event.data.@"u32")) {
                .signal => try onSignal(signal_fd, &view_proc_state),
            }
        }
    }

    return 0;
}

pub const Term = union(enum) {
    Exited: u8,
    Signal: u32,
    Stopped: u32,
};
// NOTE: copied from std
fn statusToTerm(status: u32, pid: os.pid_t) Term {
    return if (os.W.IFEXITED(status))
        Term{ .Exited = os.W.EXITSTATUS(status) }
    else if (os.W.IFSIGNALED(status))
        Term{ .Signal = os.W.TERMSIG(status) }
    else if (os.W.IFSTOPPED(status))
        Term{ .Stopped = os.W.STOPSIG(status) }
    else std.debug.panic("unknown termination status {} (pid={})", .{status, pid});
}

fn createSignalfd() !os.fd_t {
    var set = os.empty_sigset;
    os.linux.sigaddset(&set, os.SIG.CHLD);
    os.sigprocmask(os.SIG.BLOCK, &set, null);
    return os.signalfd(-1, &set, os.linux.SFD.CLOEXEC);
}

const EpollHandler = enum {
    signal,
};
fn epollAdd(epoll_fd: os.fd_t, op: u32, fd: os.fd_t, events: u32, handler: EpollHandler) !void {
    var event = os.linux.epoll_event{
        .events = events,
        .data = .{ .@"u32" = @enumToInt(handler) },
    };
    return os.epoll_ctl(epoll_fd, op, fd, &event);
}

const ProcState = struct {
    name: []const u8,
    pid: os.pid_t,
    exited: bool = false,
};

fn onSignal(
    signal_fd: os.fd_t,
    child_procs: []ProcState,
) !void {
    while (true) {
        var info: os.linux.signalfd_siginfo = undefined;
        const len = try os.read(signal_fd, @ptrCast([*]u8, &info)[0 .. @sizeOf(@TypeOf(info))]);
        std.debug.assert(len == @sizeOf(@TypeOf(info)));
        std.debug.assert(info.signo == os.SIG.CHLD);
        std.log.info("SIGCHLD", .{});

        while (true) {
            const result = os.waitpid(-1, os.W.NOHANG);
            if (result.pid == 0) break;

            const proc = blk: {
                for (child_procs) |*child_proc| {
                    if (child_proc.pid == result.pid) {
                        std.debug.assert(!child_proc.exited);
                        break :blk child_proc;
                    }
                }
                std.log.err("waitpid returned unknown pid {}", .{result.pid});
                os.exit(0xff);
            };

            const term = statusToTerm(result.status, result.pid);
            switch (term) {
                .Exited => |code| {
                    std.log.info("{s} process exited with {}", .{proc.name, code});
                    proc.exited = true;
                },
                .Signal => |sig| {
                    std.log.info("{s} process was killed with signal {}", .{proc.name, sig});
                    proc.exited = true;
                },
                .Stopped => |sig| {
                    std.log.info("{s} process was stopped with signal {}", .{proc.name, sig});
                },
            }
            break;
        }

        var all_exited = true;
        for (child_procs) |child_proc| {
            if (!child_proc.exited) {
                all_exited = false;
                break;
            }
        }
        if (all_exited) {
            std.log.info("all processes have exited", .{});
            os.exit(0);
        }
    }
}
