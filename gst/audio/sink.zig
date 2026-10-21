const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const format = @import("format.zig");
const rb = @import("ringbuffer.zig");
const basesink = @import("basesink.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Sink = c.GstAudioSink;
const Class = c.GstAudioSinkClass;
const RB = c.GstAudioRingBuffer;

extern fn gst_g_thread_get_type() c.GType;

const SinkRB = extern struct {
    object: RB,
    running: c.gboolean,
    queuedseg: c.gint,
    cond: c.GCond,
};

const SinkRBClass = extern struct { parent_class: c.GstAudioRingBufferClass };

var rb_once: gtype.Once = .{};
var rb_parent: ?*c.GstAudioRingBufferClass = null;
var once: gtype.Once = .{};

fn sinkOf(buf: anytype) [*c]Sink {
    return @ptrCast(@alignCast(@as([*c]c.GstObject, @ptrCast(@alignCast(buf))).*.parent));
}

fn klassOf(buf: anytype) *Class {
    return gtype.classPeek(Class, sinkOf(buf));
}

fn abuf(buf: anytype) *SinkRB {
    return @ptrCast(@alignCast(buf));
}

fn lock(buf: anytype) void {
    el.lock(buf);
}

fn unlock(buf: anytype) void {
    el.unlock(buf);
}

fn rbSignal(buf: anytype) void {
    c.g_cond_signal(&abuf(buf).cond);
}

fn rbWait(buf: anytype) void {
    c.g_cond_wait(&abuf(buf).cond, &@as([*c]c.GstObject, @ptrCast(@alignCast(buf))).*.lock);
}

fn postStatus(buf: [*c]RB, sink: [*c]Sink, t: c.GstStreamStatusType) void {
    const msg = c.gst_message_new_stream_status(@ptrCast(buf), t, @ptrCast(sink));
    var val = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&val, gst_g_thread_get_type());
    c.g_value_set_boxed(&val, c.g_thread_self());
    c.gst_message_set_stream_status_object(msg, &val);
    c.g_value_unset(&val);
    _ = c.gst_element_post_message(@ptrCast(sink), msg);
}

fn threadFunc(data: c.gpointer) callconv(.c) c.gpointer {
    const buf: [*c]RB = @ptrCast(@alignCast(data));
    const sink = sinkOf(buf);
    const k = klassOf(buf);
    lock(buf);
    rbSignal(buf);
    unlock(buf);
    const write = k.write orelse return null;
    postStatus(buf, sink, c.GST_STREAM_STATUS_TYPE_ENTER);
    while (true) {
        var readseg: c.gint = 0;
        var readptr: [*c]u8 = null;
        var len: c.gint = 0;
        if (rb.gst_audio_ring_buffer_prepare_read(buf, &readseg, &readptr, &len) != 0) {
            var left = len;
            while (left > 0) {
                const written = write(sink, readptr, @bitCast(left));
                if (written < 0 or written > left) break;
                if (written == 0 and @atomicLoad(c.gint, &buf.*.state, .seq_cst) != c.GST_AUDIO_RING_BUFFER_STATE_STARTED) break;
                left -= written;
                readptr += @as(usize, @intCast(written));
            }
            rb.gst_audio_ring_buffer_clear(buf, readseg);
            rb.gst_audio_ring_buffer_advance(buf, 1);
        } else {
            lock(buf);
            if (abuf(buf).running == 0) break;
            if (@atomicLoad(c.gint, &buf.*.state, .seq_cst) == c.GST_AUDIO_RING_BUFFER_STATE_STARTED) {
                unlock(buf);
                continue;
            }
            rbSignal(buf);
            rbWait(buf);
            if (abuf(buf).running == 0) break;
            unlock(buf);
        }
    }
    unlock(buf);
    postStatus(buf, sink, c.GST_STREAM_STATUS_TYPE_LEAVE);
    return null;
}

fn rbInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a = abuf(inst);
    a.running = 0;
    a.queuedseg = 0;
    c.g_cond_init(&a.cond);
}

fn rbDispose(o: [*c]c.GObject) callconv(.c) void {
    @as(*c.GObjectClass, @ptrCast(rb_parent)).dispose.?(o);
}

fn rbFinalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_cond_clear(&abuf(o).cond);
    @as(*c.GObjectClass, @ptrCast(rb_parent)).finalize.?(o);
}

fn openDevice(buf: [*c]RB) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    return if (k.open) |f| f(sinkOf(buf)) else 1;
}

fn closeDevice(buf: [*c]RB) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    return if (k.close) |f| f(sinkOf(buf)) else 1;
}

fn acquire(buf: [*c]RB, spec: [*c]c.GstAudioRingBufferSpec) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    var result: c.gboolean = 0;
    if (k.prepare) |f| result = f(sinkOf(buf), spec);
    if (result == 0) return 0;
    spec.*.seglatency = spec.*.segtotal + 1;
    buf.*.size = @intCast(spec.*.segtotal * spec.*.segsize);
    const n: usize = @intCast(buf.*.size);
    buf.*.memory = @ptrCast(c.g_malloc(n));
    switch (buf.*.spec.type) {
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_RAW => format.gst_audio_format_info_fill_silence(buf.*.spec.info.finfo, buf.*.memory, n),
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DSD => @memset(buf.*.memory[0..n], 0x69),
        else => @memset(buf.*.memory[0..n], 0),
    }
    return 1;
}

fn activate(buf: [*c]RB, active: c.gboolean) callconv(.c) c.gboolean {
    const sink = sinkOf(buf);
    if (active != 0) {
        abuf(buf).running = 1;
        var err: [*c]c.GError = null;
        sink.*.thread = c.g_thread_try_new("audiosink-ringbuffer", threadFunc, buf, &err);
        if (sink.*.thread == null or err != null) {
            c.g_clear_error(&err);
            return 0;
        }
        rbWait(buf);
    } else {
        abuf(buf).running = 0;
        rbSignal(buf);
        unlock(buf);
        _ = c.g_thread_join(sink.*.thread);
        lock(buf);
    }
    return 1;
}

fn release(buf: [*c]RB) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    c.g_free(buf.*.memory);
    buf.*.memory = null;
    return if (k.unprepare) |f| f(sinkOf(buf)) else 0;
}

fn start(buf: [*c]RB) callconv(.c) c.gboolean {
    rbSignal(buf);
    return 1;
}

fn pause(buf: [*c]RB) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    if (k.pause) |f| f(sinkOf(buf)) else if (k.reset) |f| f(sinkOf(buf));
    return 1;
}

fn @"resume"(buf: [*c]RB) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    if (k.@"resume") |f| f(sinkOf(buf));
    _ = start(buf);
    return 1;
}

fn stop(buf: [*c]RB) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    if (k.stop) |f| f(sinkOf(buf)) else if (k.reset) |f| f(sinkOf(buf));
    return 1;
}

fn delay(buf: [*c]RB) callconv(.c) c.guint {
    const k = klassOf(buf);
    return if (k.delay) |f| f(sinkOf(buf)) else 0;
}

fn clearAll(buf: [*c]RB) callconv(.c) void {
    const k = klassOf(buf);
    if (k.extension.*.clear_all) |f| f(sinkOf(buf));
    rb_parent.?.clear_all.?(buf);
}

fn rbClassInit(kl: c.gpointer, _: c.gpointer) callconv(.c) void {
    rb_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(kl)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(kl));
    const rc: *c.GstAudioRingBufferClass = @ptrCast(@alignCast(kl));
    oc.dispose = rbDispose;
    oc.finalize = rbFinalize;
    rc.open_device = openDevice;
    rc.close_device = closeDevice;
    rc.acquire = acquire;
    rc.release = release;
    rc.start = start;
    rc.pause = pause;
    rc.@"resume" = @"resume";
    rc.stop = stop;
    rc.delay = delay;
    rc.activate = activate;
    rc.clear_all = clearAll;
}

fn ringBufferType() c.GType {
    return rb_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(rb.gst_audio_ring_buffer_get_type(), "GstAudioSinkRingBuffer", @sizeOf(SinkRBClass), rbClassInit, @sizeOf(SinkRB), rbInit, 0);
        }
    }.f);
}

fn createRingbuffer(_: [*c]c.GstAudioBaseSink) callconv(.c) [*c]RB {
    return @ptrCast(@alignCast(c.g_object_new(ringBufferType(), null)));
}

fn classInit(kl: c.gpointer, _: c.gpointer) callconv(.c) void {
    const bc: *c.GstAudioBaseSinkClass = @ptrCast(@alignCast(kl));
    const k: *Class = @ptrCast(@alignCast(kl));
    bc.create_ringbuffer = createRingbuffer;
    _ = c.g_type_class_ref(ringBufferType());
    k.extension = @ptrCast(@alignCast(c.g_type_class_get_private(@ptrCast(@alignCast(kl)), gst_audio_sink_get_type())));
}

fn init(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

pub export fn gst_audio_sink_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(basesink.gst_audio_base_sink_get_type, "GstAudioSink", Class, Sink, classInit, init, 0);
            _ = c._gst_debug_category_new("audiosink", 0, "audiosink element");
            c.g_type_add_class_private(t, @sizeOf(c.GstAudioSinkClassExtension));
            return t;
        }
    }.f);
}
