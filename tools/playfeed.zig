const std = @import("std");
const c = @import("c").c;
const proto = @import("mediad");
const S = proto.sys;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn make(path: [*:0]const u8) bool {
    const desc = std.fmt.allocPrintSentinel(std.heap.c_allocator, "videotestsrc num-buffers=150 ! video/x-raw,width=320,height=240,framerate=30/1 ! theoraenc ! oggmux name=m ! filesink location={s} audiotestsrc num-buffers=220 ! audioconvert ! vorbisenc ! m.", .{path}, 0) catch return false;
    var err: [*c]c.GError = null;
    const pipe = c.gst_parse_launch(desc.ptr, &err) orelse return false;
    defer c.gst_object_unref(pipe);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_PLAYING);
    const bus = c.gst_element_get_bus(pipe);
    defer c.gst_object_unref(bus);
    const msg = c.gst_bus_timed_pop_filtered(bus, c.GST_CLOCK_TIME_NONE, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    const ok = msg != null and msg[0].type == c.GST_MESSAGE_EOS;
    if (msg != null) c.gst_message_unref(msg);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_NULL);
    return ok;
}

fn control(fd: c_int, op: proto.Op, value: f64) void {
    var m = proto.Control{ .op = @intFromEnum(op), .value = value };
    _ = proto.send(fd, .control, &.{std.mem.asBytes(&m)}, -1, false);
}

pub fn main(init: std.process.Init) u8 {
    c.gst_init(null, null);
    const args = init.minimal.args.toSlice(std.heap.c_allocator) catch return 1;
    if (args.len < 2) return 2;
    const path = args[1];
    const isolated = args.len > 2 and std.mem.eql(u8, args[2], "--isolated");
    if (S.access(path, S.F_OK) != 0 and !make(path)) {
        out("could not make {s}", .{path});
        return 1;
    }
    const file = S.open(path, S.O_RDONLY | S.O_CLOEXEC);
    if (file < 0) return 1;
    const size: u64 = @intCast(S.lseek(file, 0, S.SEEK_END));
    const map: [*]const u8 = @ptrCast(S.mmap(null, size, S.PROT_READ, S.MAP_PRIVATE, file, 0));
    var pbuf: [512]u8 = undefined;
    const sock = proto.socketPath(&pbuf) orelse return 1;
    const fd = proto.connect(sock);
    if (fd < 0) {
        out("mediad not reachable at {s}", .{sock});
        return 1;
    }
    var play = proto.Play{ .flags = if (isolated) proto.FLAG_ISOLATED else 0, .size = size };
    _ = proto.send(fd, .play, &.{ std.mem.asBytes(&play), "video/x-raw,format=BGRA", &[_]u8{0} }, -1, false);
    var frames: u32 = 0;
    var fed: u64 = 0;
    var seeking = false;
    var seek_pts: u64 = 0;
    var last_pts: u64 = 0;
    var duration: i64 = -1;
    var buf: [proto.MAX]u8 = undefined;
    while (true) {
        const m = proto.recv(fd, &buf) orelse {
            out("connection closed after {d} frames", .{frames});
            return 1;
        };
        if (m.fd >= 0) _ = S.close(m.fd);
        switch (m.kind) {
            .ready => control(fd, .play, 0),
            .need => {
                const n = proto.asStruct(proto.Need, m.body) orelse continue;
                var at = n.offset;
                const end = @min(size, n.offset + @max(n.length, proto.CHUNK));
                var off = at;
                if (at >= size) {
                    _ = proto.send(fd, .data, &.{std.mem.asBytes(&off)}, -1, false);
                    continue;
                }
                while (at < end) {
                    const len = @min(proto.CHUNK, end - at);
                    off = at;
                    _ = proto.send(fd, .data, &.{ std.mem.asBytes(&off), map[at .. at + len] }, -1, false);
                    at += len;
                    fed += len;
                }
            },
            .caps => if (frames == 0) out("caps {s}", .{std.mem.sliceTo(m.body, 0)}),
            .frame => {
                const f = proto.asStruct(proto.Frame, m.body) orelse continue;
                frames += 1;
                last_pts = f.pts;
                _ = proto.send(fd, .release, &.{std.mem.asBytes(&f.id)}, -1, false);
                if (seeking and f.pts >= 2_900_000_000) {
                    seeking = false;
                    seek_pts = f.pts;
                }
                if (frames == 20) {
                    control(fd, .pause, 0);
                    control(fd, .volume, 0.5);
                    control(fd, .seek, 3.0);
                    control(fd, .play, 0);
                    seeking = true;
                }
            },
            .state => {
                const st = proto.asStruct(proto.State, m.body) orelse continue;
                if (duration < 0 and st.duration > 0) {
                    duration = st.duration;
                    out("state duration={d}ms position={d}ms flags={d}", .{ @divTrunc(st.duration, 1_000_000), @divTrunc(st.position, 1_000_000), st.flags });
                }
            },
            .eos => {
                out("eos frames={d} last_pts={d}ms seek_landed={d}ms fed={d}/{d} duration={d}ms", .{ frames, last_pts / 1_000_000, seek_pts / 1_000_000, fed, size, @divTrunc(duration, 1_000_000) });
                return if (frames > 20 and seek_pts >= 2_900_000_000 and duration > 0) 0 else 1;
            },
            .failure => {
                var parts: [4][]const u8 = .{ "", "", "", "" };
                _ = proto.strings(m.body[@sizeOf(proto.Failure)..], &parts);
                out("failure {s}: {s} ({s})", .{ parts[0], parts[1], parts[2] });
                return 1;
            },
            else => {},
        }
    }
}
