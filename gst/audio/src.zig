const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const format = @import("format.zig");
const rb = @import("ringbuffer.zig");
const basesrc = @import("basesrc.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Src = c.GstAudioSrc;
const Class = c.GstAudioSrcClass;
const RB = c.GstAudioRingBuffer;

extern fn gst_g_thread_get_type() c.GType;

const SrcRB = extern struct {
    object: RB,
    running: c.gboolean,
    queuedseg: c.gint,
    cond: c.GCond,
};

const SrcRBClass = extern struct { parent_class: c.GstAudioRingBufferClass };

var rb_once: gtype.Once = .{};
var rb_parent: ?*c.GObjectClass = null;
var once: gtype.Once = .{};

fn srcOf(buf: anytype) [*c]Src {
    return @ptrCast(@alignCast(@as([*c]c.GstObject, @ptrCast(@alignCast(buf))).*.parent));
}

fn klassOf(buf: anytype) *Class {
    return gtype.classPeek(Class, srcOf(buf));
}

fn abuf(buf: anytype) *SrcRB {
    return @ptrCast(@alignCast(buf));
}

fn signal(buf: anytype) void {
    c.g_cond_signal(&abuf(buf).cond);
}

fn wait(buf: anytype) void {
    c.g_cond_wait(&abuf(buf).cond, &@as([*c]c.GstObject, @ptrCast(@alignCast(buf))).*.lock);
}

fn postStatus(buf: [*c]RB, src: [*c]Src, t: c.GstStreamStatusType) void {
    const msg = c.gst_message_new_stream_status(@ptrCast(buf), t, @ptrCast(src));
    var val = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&val, gst_g_thread_get_type());
    c.g_value_set_boxed(&val, c.g_thread_self());
    c.gst_message_set_stream_status_object(msg, &val);
    c.g_value_unset(&val);
    _ = c.gst_element_post_message(@ptrCast(src), msg);
}

fn threadFunc(data: c.gpointer) callconv(.c) c.gpointer {
    const buf: [*c]RB = @ptrCast(@alignCast(data));
    const src = srcOf(buf);
    const read = klassOf(buf).read orelse return null;
    postStatus(buf, src, c.GST_STREAM_STATUS_TYPE_ENTER);
    while (true) {
        var seg: c.gint = 0;
        var ptr: [*c]u8 = null;
        var len: c.gint = 0;
        if (rb.gst_audio_ring_buffer_prepare_read(buf, &seg, &ptr, &len) != 0) {
            var ts: c.GstClockTime = c.GST_CLOCK_TIME_NONE;
            var left = len;
            while (true) {
                const got: c.gint = @bitCast(read(src, ptr, @bitCast(left), &ts));
                if (got < 0 or got > left) break;
                left -= got;
                ptr += @as(usize, @intCast(got));
                if (left <= 0 or @atomicLoad(c.gboolean, &abuf(buf).running, .seq_cst) == 0) break;
            }
            rb.gst_audio_ring_buffer_set_timestamp(buf, seg, ts);
            rb.gst_audio_ring_buffer_advance(buf, 1);
            continue;
        }
        el.lock(buf);
        if (abuf(buf).running == 0) break;
        if (@atomicLoad(c.gint, &buf.*.state, .seq_cst) == c.GST_AUDIO_RING_BUFFER_STATE_STARTED) {
            el.unlock(buf);
            continue;
        }
        signal(buf);
        wait(buf);
        if (abuf(buf).running == 0) break;
        el.unlock(buf);
    }
    el.unlock(buf);
    postStatus(buf, src, c.GST_STREAM_STATUS_TYPE_LEAVE);
    return null;
}

fn rbInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a = abuf(inst);
    a.running = 0;
    a.queuedseg = 0;
    c.g_cond_init(&a.cond);
}

fn rbDispose(o: [*c]c.GObject) callconv(.c) void {
    c.g_cond_clear(&abuf(o).cond);
    rb_parent.?.dispose.?(o);
}

fn rbFinalize(o: [*c]c.GObject) callconv(.c) void {
    rb_parent.?.finalize.?(o);
}

fn openDevice(buf: [*c]RB) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    return if (k.open) |f| f(srcOf(buf)) else 1;
}

fn closeDevice(buf: [*c]RB) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    return if (k.close) |f| f(srcOf(buf)) else 1;
}

fn acquire(buf: [*c]RB, spec: [*c]c.GstAudioRingBufferSpec) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    const src = srcOf(buf);
    const prepare = k.prepare orelse return 0;
    if (prepare(src, spec) == 0) return 0;
    buf.*.size = @intCast(spec.*.segtotal * spec.*.segsize);
    const n: usize = @intCast(buf.*.size);
    buf.*.memory = @ptrCast(c.g_malloc(n));
    if (buf.*.spec.type == c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_RAW) format.gst_audio_format_info_fill_silence(buf.*.spec.info.finfo, buf.*.memory, n) else @memset(buf.*.memory[0..n], 0);
    abuf(buf).running = 1;
    src.*.thread = c.g_thread_try_new("audiosrc-ringbuffer", threadFunc, buf, null);
    wait(buf);
    return 1;
}

fn release(buf: [*c]RB) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    const src = srcOf(buf);
    abuf(buf).running = 0;
    signal(buf);
    el.unlock(buf);
    _ = c.g_thread_join(src.*.thread);
    el.lock(buf);
    c.g_free(buf.*.memory);
    buf.*.memory = null;
    return if (k.unprepare) |f| f(src) else 0;
}

fn start(buf: [*c]RB) callconv(.c) c.gboolean {
    signal(buf);
    return 1;
}

fn stop(buf: [*c]RB) callconv(.c) c.gboolean {
    const k = klassOf(buf);
    if (k.reset) |f| f(srcOf(buf));
    return 1;
}

fn delay(buf: [*c]RB) callconv(.c) c.guint {
    const k = klassOf(buf);
    return if (k.delay) |f| f(srcOf(buf)) else 0;
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
    rc.@"resume" = start;
    rc.stop = stop;
    rc.delay = delay;
}

fn ringBufferType() c.GType {
    return rb_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(rb.gst_audio_ring_buffer_get_type(), "GstAudioSrcRingBuffer", @sizeOf(SrcRBClass), rbClassInit, @sizeOf(SrcRB), rbInit, 0);
        }
    }.f);
}

fn createRingbuffer(_: [*c]c.GstAudioBaseSrc) callconv(.c) [*c]RB {
    return @ptrCast(@alignCast(c.g_object_new(ringBufferType(), null)));
}

fn classInit(kl: c.gpointer, _: c.gpointer) callconv(.c) void {
    const bc: *c.GstAudioBaseSrcClass = @ptrCast(@alignCast(kl));
    bc.create_ringbuffer = createRingbuffer;
    _ = c.g_type_class_ref(ringBufferType());
}

fn init(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

pub export fn gst_audio_src_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(basesrc.gst_audio_base_src_get_type, "GstAudioSrc", Class, Src, classInit, init, 0);
            _ = c._gst_debug_category_new("audiosrc", 0, "audiosrc element");
            return t;
        }
    }.f);
}
