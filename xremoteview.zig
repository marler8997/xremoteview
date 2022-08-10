// NOTE:
// We should be able to process the commands from an X session
// from any source (i.e. saved to a file).  For now we'll start
// with a TCP server mean to accept data from xsnoop.
const std = @import("std");
const os = std.os;

const x = @import("x");

const global = struct {
    pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    pub const window_width = 600;
    pub const window_height = 400;
};

pub fn main() !void {
    var xconn_mut = XConn.Mutable.init();
    const xconn = try xConnect(&xconn_mut);
    defer xconn.shutdown();

    while (true) {
        try onXServerRead(xconn, &xconn_mut);
    }
}

const XConn = struct {
    pub const Mutable = struct {
        buf: x.ContiguousReadBuffer,
        pub fn init() Mutable {
            return .{
                .buf = undefined,
            };
        }
    };
    pub const Const = struct {
        sock: os.socket_t,
        window_id: u32,
        bg_gc_id: u32,
        fg_gc_id: u32,
        font_dims: FontDims,
        pub fn shutdown(self: Const) void {
            std.os.shutdown(self.sock, .both) catch {};
        }
    };
};

fn xConnect(mut: *XConn.Mutable) !XConn.Const {
    const conn = try connect(global.arena.allocator());
    errdefer std.os.shutdown(conn.sock, .both) catch {};

    const screen = blk: {
        const fixed = conn.setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{field.name, @field(fixed, field.name)});
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{format_list_offset, format_list_limit});
        const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
        for (formats) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
        }
        var screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{field.name, @field(screen, field.name)});
        }
        break :blk screen;
    };
    // TODO: maybe need to call conn.setup.verify or something?

    const window_id = conn.setup.fixed().resource_id_base;
    {
        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
            .window_id = window_id,
            .parent_window_id = screen.root,
            .x = 0, .y = 0,
            .width = global.window_width, .height = global.window_height,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
//            .bg_pixmap = .copy_from_parent,
            .bg_pixel = 0xaabbccdd,
//            //.border_pixmap =
//            .border_pixel = 0x01fa8ec9,
//            .bit_gravity = .north_west,
//            .win_gravity = .east,
//            .backing_store = .when_mapped,
//            .backing_planes = 0x1234,
//            .backing_pixel = 0xbbeeeeff,
//            .override_redirect = true,
//            .save_under = true,
            .event_mask =
                  x.event.key_press
                | x.event.key_release
                | x.event.button_press
                | x.event.button_release
                | x.event.enter_window
                | x.event.leave_window
                | x.event.pointer_motion
//                | x.event.pointer_motion_hint WHAT THIS DO?
//                | x.event.button1_motion  WHAT THIS DO?
//                | x.event.button2_motion  WHAT THIS DO?
//                | x.event.button3_motion  WHAT THIS DO?
//                | x.event.button4_motion  WHAT THIS DO?
//                | x.event.button5_motion  WHAT THIS DO?
//                | x.event.button_motion  WHAT THIS DO?
                | x.event.keymap_state
                | x.event.exposure
                ,
//            .dont_propagate = 1,
        });
        try sendAll(conn.sock, msg_buf[0..len]);
    }

    const bg_gc_id = window_id + 1;
    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = bg_gc_id,
            .drawable_id = screen.root,
        }, .{
            .foreground = screen.black_pixel,
        });
        try sendAll(conn.sock, msg_buf[0..len]);
    }
    const fg_gc_id = window_id + 2;
    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = fg_gc_id,
            .drawable_id = screen.root,
        }, .{
            .background = screen.black_pixel,
            .foreground = 0xffaadd,
        });
        try sendAll(conn.sock, msg_buf[0..len]);
    }

    // get some font information
    {
        const text_literal = [_]u16 { 'm' };
        const text = x.Slice(u16, [*]const u16) { .ptr = &text_literal, .len = text_literal.len };
        var msg: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&msg, fg_gc_id, text);
        try sendAll(conn.sock, &msg);
    }

    const buf_memfd = try x.Memfd.init("ZigX11DoubleBuffer");
    // no need to deinit
    const buffer_capacity = std.mem.alignForward(1000, std.mem.page_size);
    std.log.info("buffer capacity is {}", .{buffer_capacity});
    mut.buf = x.ContiguousReadBuffer { .double_buffer_ptr = try buf_memfd.toDoubleBuffer(buffer_capacity), .half_size = buffer_capacity };

    const font_dims: FontDims = blk: {
        _ = try x.readOneMsg(conn.reader(), @alignCast(4, mut.buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(4, mut.buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg = @ptrCast(*x.ServerMsg.QueryTextExtents, msg_reply);
                break :blk .{
                    .width = @intCast(u8, msg.overall_width),
                    .height = @intCast(u8, msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(i16, msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                os.exit(0xff);
            },
        }
    };

    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, window_id);
        try sendAll(conn.sock, &msg);
    }

    return XConn.Const{
        .sock = conn.sock,
        .window_id = window_id,
        .bg_gc_id = bg_gc_id,
        .fg_gc_id = fg_gc_id,
        .font_dims = font_dims,
    };
}

fn onXServerRead(
    conn: XConn.Const,
    mut: *XConn.Mutable,
) !void {
    {
        const recv_buf = mut.buf.nextReadBuffer();
        if (recv_buf.len == 0) {
            std.log.err("buffer size {} not big enough!", .{mut.buf.half_size});
            os.exit(0xff);
        }
        const len = try std.os.recv(conn.sock, recv_buf, 0);
        if (len == 0) {
            std.log.info("X server connection closed", .{});
            os.exit(0);
        }
        mut.buf.reserve(len);
    }
    while (true) {
        const data = mut.buf.nextReservedBuffer();
        const msg_len = x.parseMsgLen(@alignCast(4, data));
        if (msg_len == 0)
            break;
        mut.buf.release(msg_len);
        //mut.buf.resetIfEmpty();
        switch (x.serverMsgTaggedUnion(@alignCast(4, data.ptr))) {
            .err => |msg| {
                std.log.err("{}", .{msg});
                os.exit(0xff);
            },
            .reply => |msg| {
                std.log.info("todo: handle a reply message {}", .{msg});
                return error.TodoHandleReplyMessage;
            },
            .key_press => |msg| {
                std.log.info("key_press: {}", .{msg.detail});
            },
            .key_release => |msg| {
                std.log.info("key_release: {}", .{msg.detail});
            },
            .button_press => |msg| {
                std.log.info("button_press: {}", .{msg});
            },
            .button_release => |msg| {
                std.log.info("button_release: {}", .{msg});
            },
            .enter_notify => |msg| {
                std.log.info("enter_window: {}", .{msg});
            },
            .leave_notify => |msg| {
                std.log.info("leave_window: {}", .{msg});
            },
            .motion_notify => |msg| {
                // too much logging
                _ = msg;
                //std.log.info("pointer_motion: {}", .{msg});
            },
            .keymap_notify => |msg| {
                std.log.info("keymap_state: {}", .{msg});
            },
            .expose => |msg| {
                std.log.info("expose: {}", .{msg});
                try render(conn.sock, conn.window_id, conn.bg_gc_id, conn.fg_gc_id, conn.font_dims);
            },
            .unhandled => |msg| {
                std.log.info("todo: server msg {}", .{msg});
                return error.UnhandledServerMsg;
            },
        }
    }
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};


fn render(sock: std.os.socket_t, drawable_id: u32, bg_gc_id: u32, fg_gc_id: u32, font_dims: FontDims) !void {
    _ = bg_gc_id;
    {
        var msg: [x.clear_area.len]u8 = undefined;
        x.clear_area.serialize(&msg, false, drawable_id, .{
            .x = 150, .y = 150, .width = 100, .height = 100,
        });
        try sendAll(sock, &msg);
    }
    {
        const text_literal: []const u8 = "no clients";
        const text = x.Slice(u8, [*]const u8) { .ptr = text_literal.ptr, .len = text_literal.len };
        var msg: [x.image_text8.getLen(text.len)]u8 = undefined;

        const text_width = font_dims.width * text_literal.len;

        x.image_text8.serialize(&msg, .{
            .drawable_id = drawable_id,
            .gc_id = fg_gc_id,
            .x = @divTrunc((global.window_width - @intCast(i16, text_width)),  2) + font_dims.font_left,
            .y = @divTrunc((global.window_height - @intCast(i16, font_dims.height)), 2) + font_dims.font_ascent,
            .text = text,
        });
        try sendAll(sock, &msg);
    }
}

fn readSocket(sock: std.os.socket_t, buffer: []u8) !usize {
    return std.os.recv(sock, buffer, 0);
}
pub const SocketReader = std.io.Reader(std.os.socket_t, std.os.RecvFromError, readSocket);

pub fn sendAll(sock: std.os.socket_t, data: []const u8) !void {
    const sent = try std.os.send(sock, data, 0);
    if (sent != data.len) {
        std.log.err("send {} only sent {}\n", .{data.len, sent});
        return error.DidNotSendAllData;
    }
}

pub const ConnectResult = struct {
    sock: std.os.socket_t,
    setup: x.ConnectSetup,
    pub fn reader(self: ConnectResult) SocketReader {
        return .{ .context = self.sock };
    }
};

pub fn connect(allocator: std.mem.Allocator) !ConnectResult {
    const display = x.getDisplay();

    const sock = x.connect(display) catch |err| {
        std.log.err("failed to connect to display '{s}': {s}", .{display, @errorName(err)});
        std.os.exit(0xff);
    };

    {
        const len = comptime x.connect_setup.getLen(0, 0);
        var msg: [len]u8 = undefined;
        x.connect_setup.serialize(&msg, 11, 0, .{ .ptr = undefined, .len = 0 }, .{ .ptr = undefined, .len = 0 });
        try sendAll(sock, &msg);
    }

    const reader = SocketReader { .context = sock };
    const connect_setup_header = try x.readConnectSetupHeader(reader, .{});
    switch (connect_setup_header.status) {
        .failed => {
            std.log.err("connect setup failed, version={}.{}, reason='{s}'", .{
                connect_setup_header.proto_major_ver,
                connect_setup_header.proto_minor_ver,
                connect_setup_header.readFailReason(reader),
            });
            return error.ConnectSetupFailed;
        },
        .authenticate => {
            std.log.err("AUTHENTICATE! not implemented", .{});
            return error.NotImplemetned;
        },
        .success => {
            // TODO: check version?
            std.log.debug("SUCCESS! version {}.{}", .{connect_setup_header.proto_major_ver, connect_setup_header.proto_minor_ver});
        },
        else => |status| {
            std.log.err("Error: expected 0, 1 or 2 as first byte of connect setup reply, but got {}", .{status});
            return error.MalformedXReply;
        }
    }

    const connect_setup = x.ConnectSetup {
        .buf = try allocator.allocWithOptions(u8, connect_setup_header.getReplyLen(), 4, null),
    };
    std.log.debug("connect setup reply is {} bytes", .{connect_setup.buf.len});
    try x.readFull(reader, connect_setup.buf);

    return ConnectResult{ .sock = sock, .setup = connect_setup };
}
