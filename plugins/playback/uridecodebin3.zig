const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const utils = @import("utils.zig");

const FILE = "../gst/playback/gsturidecodebin3.c";
const N: ?*anyopaque = null;
const A = std.heap.c_allocator;
const GROUP_INVALID: c.guint = 0;

const PROP_URI = 1;
const PROP_CURRENT_URI = 2;
const PROP_SUBURI = 3;
const PROP_CURRENT_SUBURI = 4;
const PROP_CONNECTION_SPEED = 5;
const PROP_BUFFER_SIZE = 6;
const PROP_BUFFER_DURATION = 7;
const PROP_DOWNLOAD = 8;
const PROP_DOWNLOAD_DIR = 9;
const PROP_USE_BUFFERING = 10;
const PROP_RING_BUFFER_MAX_SIZE = 11;
const PROP_CAPS = 12;
const PROP_INSTANT_URI = 13;

const SIG_SELECT_STREAM = 0;
const SIG_SOURCE_SETUP = 1;
const SIG_ABOUT_TO_FINISH = 2;

const PlayItem = struct {
    bin: *Self,
    main: ?*SourceItem = null,
    sub: ?*SourceItem = null,
    group_id: c.guint = GROUP_INVALID,
    active: bool = false,
    posted_atf: bool = false,
    pending_atf: bool = false,
};

const SourceItem = struct {
    play: *PlayItem,
    uri: [*c]u8,
    handler: ?*Handler = null,
};

const Handler = struct {
    bin: *Self,
    play: *PlayItem,
    usb: ?*c.GstElement = null,
    added_id: c.gulong = 0,
    removed_id: c.gulong = 0,
    setup_id: c.gulong = 0,
    atf_id: c.gulong = 0,
    active: bool = false,
    is_main: bool,
    pending_buffering: [*c]c.GstMessage = null,
    upstream_selected: c.gboolean = 0,
    expected_pads: c.guint = 1,
    pads: [*c]c.GList = null,
    saw_redirection: bool = false,
};

const SourcePad = struct {
    handler: *Handler,
    src_pad: ?*c.GstPad,
    stream: ?*c.GstStream = null,
    db3_sink: ?*c.GstPad = null,
    saw_eos: bool = false,
    block_probe: c.gulong = 0,
    event_probe: c.gulong = 0,
};

const OutputPad = struct {
    bin: *Self,
    target: ?*c.GstPad,
    ghost_pad: ?*c.GstPad = null,
    probe: c.gulong = 0,
    group_id: c.guint = GROUP_INVALID,
};

pub const Self = extern struct {
    parent: c.GstBin,
    st: ?*State,
};

const State = struct {
    speed: u64 = 0,
    caps: [*c]c.GstCaps = null,
    buffer_duration: i64 = -1,
    buffer_size: c.gint = -1,
    download: c.gboolean = 0,
    download_dir: [*c]u8 = null,
    use_buffering: c.gboolean = 0,
    ring_max: u64 = 0,
    instant_uri: c.gboolean = 0,
    lock: c.GMutex = undefined,
    drained_cond: c.GCond = undefined,
    items: [*c]c.GList = null,
    input: ?*PlayItem = null,
    output: ?*PlayItem = null,
    decodebin: ?*c.GstElement = null,
    db_added: c.gulong = 0,
    db_removed: c.gulong = 0,
    db_select: c.gulong = 0,
    db_atf: c.gulong = 0,
    shutdown: c.gint = 0,
    outputs: [*c]c.GList = null,
};

const Class = extern struct {
    parent: c.GstBinClass,
    select_stream: ?*const fn (?*Self, ?*c.GstStreamCollection, ?*c.GstStream) callconv(.c) c.gint,
};

var video_t = cm.staticTemplate("video_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var audio_t = cm.staticTemplate("audio_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var text_t = cm.staticTemplate("text_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var signals: [3]c.guint = .{ 0, 0, 0 };
var once: cm.Once = .{};
var parent_class: ?*c.GstBinClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn st(p: anytype) *State {
    return me(p).st.?;
}

fn elem(p: anytype) *c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn binOf(p: anytype) *c.GstBin {
    return @ptrCast(@alignCast(p));
}

fn gobj(p: anytype) *c.GObject {
    return @ptrCast(@alignCast(p));
}

fn lock(s: *Self) void {
    c.g_mutex_lock(&st(s).lock);
}

fn unlock(s: *Self) void {
    c.g_mutex_unlock(&st(s).lock);
}

fn stateLock(s: *Self) void {
    c.g_rec_mutex_lock(&elem(s).state_lock);
}

fn stateUnlock(s: *Self) void {
    c.g_rec_mutex_unlock(&elem(s).state_lock);
}

fn Iter(comptime T: type) type {
    return struct {
        l: [*c]c.GList,
        fn next(it: *@This()) ?*T {
            const cur = it.l;
            if (cur == null) return null;
            it.l = cur.*.next;
            return @ptrCast(@alignCast(cur.*.data));
        }
    };
}

fn iter(comptime T: type, l: [*c]c.GList) Iter(T) {
    return .{ .l = l };
}

fn intAccu(_: [*c]c.GSignalInvocationHint, accu: [*c]c.GValue, ret: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    const v = c.g_value_get_int(ret);
    c.g_value_set_int(accu, v);
    return @intFromBool(v == -1);
}

fn defaultSelect(_: ?*Self, _: ?*c.GstStreamCollection, _: ?*c.GstStream) callconv(.c) c.gint {
    return -1;
}

fn currentUpdated(s: *Self) void {
    c.g_object_notify(gobj(s), "current-uri");
    c.g_object_notify(gobj(s), "current-suburi");
}

fn checkOutputGroup(s: *Self) void {
    const t = st(s);
    var common: c.guint = GROUP_INVALID;
    var notify = false;
    lock(s);
    var it = iter(OutputPad, t.outputs);
    while (it.next()) |o| {
        if (common == GROUP_INVALID) {
            common = o.group_id;
        } else if (common != o.group_id) {
            unlock(s);
            return;
        }
    }
    const out = t.output.?;
    if (out.group_id == common) {} else if (out.group_id == GROUP_INVALID) {
        out.group_id = common;
    } else if (common != GROUP_INVALID) {
        if (c.g_list_length(t.items) > 1) {
            t.items = c.g_list_remove(t.items, out);
            t.output = @ptrCast(@alignCast(t.items.*.data));
            t.output.?.group_id = common;
            freePlayItem(s, out);
        }
        notify = true;
    }
    unlock(s);
    if (notify) currentUpdated(s);
}

fn dbSrcProbe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const o: *OutputPad = @ptrCast(@alignCast(data));
    const s = o.bin;
    const t = st(s);
    const ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
    switch (cm.eventType(ev)) {
        c.GST_EVENT_EOS => {
            lock(s);
            const last: *PlayItem = @ptrCast(@alignCast(c.g_list_last(t.items).*.data));
            const drop = t.input != t.output or t.input != last;
            unlock(s);
            if (drop) return c.GST_PAD_PROBE_DROP;
        },
        c.GST_EVENT_STREAM_START => {
            if (c.gst_event_parse_group_id(ev, &o.group_id) != 0) checkOutputGroup(s);
        },
        else => {},
    }
    return c.GST_PAD_PROBE_OK;
}

fn addOutputPad(s: *Self, target: ?*c.GstPad) *OutputPad {
    const o = A.create(OutputPad) catch @panic("oom");
    o.* = .{ .bin = s, .target = target };
    const name = c.gst_object_get_name(cm.obj(target));
    o.ghost_pad = c.gst_ghost_pad_new(name, target);
    c.g_free(name);
    _ = c.gst_pad_set_active(o.ghost_pad, 1);
    if (c.gst_pad_get_sticky_event(target, c.GST_EVENT_STREAM_START, 0)) |ss| {
        _ = c.gst_pad_store_sticky_event(o.ghost_pad, ss);
        c.gst_event_unref(ss);
    }
    _ = c.gst_element_add_pad(elem(s), o.ghost_pad);
    o.probe = c.gst_pad_add_probe(target, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, dbSrcProbe, o, null);
    st(s).outputs = c.g_list_append(st(s).outputs, o);
    return o;
}

fn dbPadAdded(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    if (c.gst_pad_get_direction(pad) == c.GST_PAD_SRC) _ = addOutputPad(me(data), pad);
}

fn dbPadRemoved(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    if (c.gst_pad_get_direction(pad) != c.GST_PAD_SRC) return;
    const s = me(data);
    const t = st(s);
    var found: ?*OutputPad = null;
    var l = t.outputs;
    while (l != null) : (l = l.*.next) {
        const o: *OutputPad = @ptrCast(@alignCast(l.*.data));
        if (o.target == pad) {
            found = o;
            t.outputs = c.g_list_delete_link(t.outputs, l);
            break;
        }
    }
    const o = found orelse return;
    _ = c.gst_ghost_pad_set_target(@ptrCast(@alignCast(o.ghost_pad)), null);
    _ = c.gst_element_remove_pad(elem(s), o.ghost_pad);
    c.gst_pad_remove_probe(o.target, o.probe);
    A.destroy(o);
    checkOutputGroup(s);
}

fn dbSelectStream(_: ?*c.GstElement, col: ?*c.GstStreamCollection, stream: ?*c.GstStream, data: c.gpointer) callconv(.c) c.gint {
    var r: c.gint = -1;
    c.g_signal_emit(data, signals[SIG_SELECT_STREAM], 0, col, stream, &r);
    return r;
}

fn checkMode(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    const cur = cm.pad(pad).mode;
    const ret: *c.GstPadMode = @ptrCast(@alignCast(data));
    if (cur == c.GST_PAD_MODE_NONE) return 1;
    if (ret.* == c.GST_PAD_MODE_NONE) ret.* = cur;
    return 1;
}

fn isPullBased(item: *PlayItem) bool {
    var mode: c.GstPadMode = c.GST_PAD_MODE_NONE;
    _ = c.gst_element_foreach_src_pad(item.main.?.handler.?.usb, checkMode, &mode);
    return mode == c.GST_PAD_MODE_PULL;
}

fn emitAboutToFinish(s: *Self, item: *PlayItem) void {
    if (item.posted_atf) return;
    if (item != st(s).input) {
        item.pending_atf = true;
        return;
    }
    if (isPullBased(item)) playItemSetEos(item);
    item.posted_atf = true;
    c.g_signal_emit(s, signals[SIG_ABOUT_TO_FINISH], 0);
}

fn dbAboutToFinish(_: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    emitAboutToFinish(s, st(s).output.?);
}

fn activateSourceItem(item: *SourceItem) c.GstStateChangeReturn {
    const h = item.handler orelse return c.GST_STATE_CHANGE_FAILURE;
    c.g_object_set(gobj(h.usb), "uri", item.uri, N);
    if (!h.active) {
        _ = c.gst_bin_add(binOf(h.bin), h.usb);
        h.active = true;
    }
    if (c.gst_element_sync_state_with_parent(h.usb) == 0) return c.GST_STATE_CHANGE_FAILURE;
    return c.GST_STATE_CHANGE_SUCCESS;
}

fn linkToDb3(s: *Self, sp: *SourcePad) void {
    const h = sp.handler;
    const sink = c.gst_element_request_pad_simple(st(s).decodebin, "sink_%u") orelse return;
    const r = c.gst_pad_link(sp.src_pad, sink);
    c.gst_object_unref(sink);
    if (r < 0) return;
    sp.db3_sink = sink;
    if (h.is_main) if (h.play.sub) |sub| if (sub.handler == null) {
        unlock(s);
        stateLock(s);
        sub.handler = newHandler(s, h.play, false);
        if (activateSourceItem(sub) == c.GST_STATE_CHANGE_FAILURE) {
            freeHandler(s, sub.handler.?, false);
            sub.handler = null;
        }
        stateUnlock(s);
        lock(s);
    };
}

fn allPads(item: *PlayItem) [*c]c.GList {
    var r: [*c]c.GList = null;
    if (item.main) |m| if (m.handler) |h| {
        r = c.g_list_copy(h.pads);
    };
    if (item.sub) |m| if (m.handler) |h| {
        r = c.g_list_concat(r, c.g_list_copy(h.pads));
    };
    return r;
}

fn matchingPad(cands: [*c]c.GList, target: *SourcePad) ?*SourcePad {
    var it = iter(SourcePad, cands);
    while (it.next()) |cand| {
        if (cand.db3_sink == null) continue;
        if (target.stream == null) return cand;
        if (c.gst_stream_get_stream_type(cand.stream) == c.gst_stream_get_stream_type(target.stream)) return cand;
    }
    return null;
}

fn switchInputLocked(s: *Self, item: *PlayItem) void {
    const t = st(s);
    const new_pads = allPads(item);
    var old_pads = allPads(t.input.?);
    var to_activate: [*c]c.GList = null;
    const inactive_prev = old_pads == null;
    var it = iter(SourcePad, new_pads);
    while (it.next()) |np| {
        if (matchingPad(old_pads, np)) |op| {
            _ = c.gst_pad_unlink(op.src_pad, op.db3_sink);
            np.db3_sink = op.db3_sink;
            op.db3_sink = null;
            old_pads = c.g_list_remove(old_pads, op);
        } else to_activate = c.g_list_append(to_activate, np);
    }
    it = iter(SourcePad, old_pads);
    while (it.next()) |op| {
        if (op.db3_sink) |p| {
            unlock(s);
            c.gst_element_release_request_pad(t.decodebin, p);
            lock(s);
            op.db3_sink = null;
        }
    }
    it = iter(SourcePad, new_pads);
    while (it.next()) |np| if (np.db3_sink != null) {
        _ = c.gst_pad_link(np.src_pad, np.db3_sink);
    };
    it = iter(SourcePad, to_activate);
    while (it.next()) |np| linkToDb3(s, np);
    it = iter(SourcePad, new_pads);
    while (it.next()) |np| if (np.block_probe != 0) {
        c.gst_pad_remove_probe(np.src_pad, np.block_probe);
        np.block_probe = 0;
    };
    c.g_list_free(new_pads);
    c.g_list_free(old_pads);
    c.g_list_free(to_activate);
    const in = t.input.?;
    if (in.main) |m| {
        freeSourceItem(s, m);
        in.main = null;
    }
    if (in.sub) |m| {
        freeSourceItem(s, m);
        in.sub = null;
    }
    if (inactive_prev) {
        t.items = c.g_list_remove(t.items, in);
        freePlayItem(s, in);
        t.output = item;
    }
    t.input = item;
    const pending_atf = item.pending_atf;
    const h = item.main.?.handler.?;
    const pending_buf = h.pending_buffering;
    h.pending_buffering = null;
    if (pending_buf != null or pending_atf) {
        unlock(s);
        if (pending_atf) emitAboutToFinish(s, item);
        if (pending_buf != null) parent_class.?.handle_message.?(binOf(s), pending_buf);
        lock(s);
    }
}

fn uriSrcProbe(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const sp: *SourcePad = @ptrCast(@alignCast(data));
    const h = sp.handler;
    const s = h.bin;
    var ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
    switch (cm.eventType(ev)) {
        c.GST_EVENT_EOS => {
            if (c.gst_pad_get_peer(pad)) |peer| {
                _ = c.gst_pad_send_event(peer, ev);
                c.gst_object_unref(peer);
            } else c.gst_event_unref(ev);
            lock(s);
            sp.saw_eos = true;
            if (h.play == st(s).input and playItemIsEos(h.play)) c.g_cond_broadcast(&st(s).drained_cond);
            unlock(s);
            return c.GST_PAD_PROBE_HANDLED;
        },
        c.GST_EVENT_STREAM_START => {
            sp.saw_eos = false;
            var gid: c.guint = GROUP_INVALID;
            _ = c.gst_event_parse_group_id(ev, &gid);
            if (h.play.group_id == GROUP_INVALID) {
                h.play.group_id = gid;
            } else if (h.play.group_id != gid) {
                ev = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(ev)));
                info.*.data = ev;
                c.gst_event_set_group_id(ev, h.play.group_id);
            }
            var stream: ?*c.GstStream = null;
            c.gst_event_parse_stream(ev, &stream);
            if (stream) |x| {
                _ = c.gst_object_replace(@ptrCast(&sp.stream), @ptrCast(@alignCast(x)));
                c.gst_object_unref(x);
            }
            const q = c.gst_query_new_selectable();
            if (c.gst_pad_query(pad, q) != 0) {
                lock(s);
                c.gst_query_parse_selectable(q, &h.upstream_selected);
                unlock(s);
            }
            c.gst_query_unref(q);
        },
        c.GST_EVENT_STREAM_COLLECTION => {
            lock(s);
            if (h.upstream_selected == 0) {
                var col: ?*c.GstStreamCollection = null;
                c.gst_event_parse_stream_collection(ev, &col);
                if (col) |x| {
                    if (h.expected_pads == 1) h.expected_pads = c.gst_stream_collection_get_size(x);
                    c.gst_object_unref(x);
                }
            }
            unlock(s);
        },
        c.GST_EVENT_SEGMENT => sp.saw_eos = false,
        else => {},
    }
    return c.GST_PAD_PROBE_OK;
}

fn uriSrcBlockProbe(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const sp: *SourcePad = @ptrCast(@alignCast(data));
    const h = sp.handler;
    const s = h.bin;
    const t = st(s);
    if (cm.isEvent(info.*.data) and cm.eventType(info.*.data) != c.GST_EVENT_GAP) return c.GST_PAD_PROBE_PASS;
    var ret: c.GstPadProbeReturn = c.GST_PAD_PROBE_OK;
    lock(s);
    if (sp.block_probe == 0) {
        ret = c.GST_PAD_PROBE_REMOVE;
    } else if (playItemIsEos(t.input.?)) {
        switchInputLocked(s, h.play);
        ret = c.GST_PAD_PROBE_REMOVE;
    } else if (playItemHasAllPads(h.play)) {
        c.g_cond_wait(&t.drained_cond, &t.lock);
        if (@atomicLoad(c.gint, &t.shutdown, .seq_cst) != 0) {
            if (sp.block_probe != 0) c.gst_pad_remove_probe(pad, sp.block_probe);
            sp.block_probe = 0;
            unlock(s);
            info.*.ABI.abi.flow_ret = c.GST_FLOW_FLUSHING;
            c.gst_mini_object_unref(@ptrCast(@alignCast(info.*.data)));
            return c.GST_PAD_PROBE_HANDLED;
        }
        if (playItemIsEos(t.input.?)) switchInputLocked(s, h.play);
        ret = c.GST_PAD_PROBE_REMOVE;
    }
    unlock(s);
    return ret;
}

fn srcPadAdded(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const h: *Handler = @ptrCast(@alignCast(data));
    const s = h.bin;
    const sp = A.create(SourcePad) catch @panic("oom");
    lock(s);
    sp.* = .{ .handler = h, .src_pad = pad };
    sp.event_probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, uriSrcProbe, sp, null);
    h.pads = c.g_list_append(h.pads, sp);
    if (h.play == st(s).input) {
        linkToDb3(s, sp);
        unlock(s);
        return;
    }
    sp.block_probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, uriSrcBlockProbe, sp, null);
    unlock(s);
}

fn srcPadRemoved(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const h: *Handler = @ptrCast(@alignCast(data));
    var found: ?*SourcePad = null;
    var it = iter(SourcePad, h.pads);
    while (it.next()) |sp| if (sp.src_pad == pad) {
        found = sp;
        break;
    };
    const sp = found orelse return;
    if (sp.db3_sink) |p| c.gst_element_release_request_pad(st(h.bin).decodebin, p);
    if (sp.stream) |x| c.gst_object_unref(x);
    h.pads = c.g_list_remove(h.pads, sp);
    A.destroy(sp);
}

fn srcSourceSetup(_: ?*c.GstElement, source: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    const h: *Handler = @ptrCast(@alignCast(data));
    c.g_signal_emit(h.bin, signals[SIG_SOURCE_SETUP], 0, source, N);
}

fn srcAboutToFinish(_: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    const h: *Handler = @ptrCast(@alignCast(data));
    emitAboutToFinish(h.bin, h.play);
}

fn newHandler(s: *Self, item: *PlayItem, is_main: bool) *Handler {
    const t = st(s);
    const h = A.create(Handler) catch @panic("oom");
    h.* = .{ .bin = s, .play = item, .is_main = is_main };
    h.usb = c.gst_element_factory_make("urisourcebin", null);
    c.g_object_set(gobj(h.usb), "connection-speed", t.speed / 1000, "download", t.download, "download-dir", t.download_dir, "use-buffering", t.use_buffering, "buffer-duration", t.buffer_duration, "buffer-size", t.buffer_size, "ring-buffer-max-size", t.ring_max, "parse-streams", @as(c.gboolean, 1), N);
    h.added_id = c.g_signal_connect_data(h.usb, "pad-added", @ptrCast(&srcPadAdded), h, null, 0);
    h.removed_id = c.g_signal_connect_data(h.usb, "pad-removed", @ptrCast(&srcPadRemoved), h, null, 0);
    h.setup_id = c.g_signal_connect_data(h.usb, "source-setup", @ptrCast(&srcSourceSetup), h, null, 0);
    h.atf_id = c.g_signal_connect_data(h.usb, "about-to-finish", @ptrCast(&srcAboutToFinish), h, null, 0);
    h.expected_pads = 1;
    return h;
}

fn handlerIsEos(h: *Handler) bool {
    var it = iter(SourcePad, h.pads);
    while (it.next()) |sp| if (!sp.saw_eos) return false;
    return true;
}

fn handlerSetEos(h: *Handler) void {
    var it = iter(SourcePad, h.pads);
    while (it.next()) |sp| sp.saw_eos = true;
}

fn freeHandler(s: *Self, h: *Handler, lock_state: bool) void {
    if (h.active) {
        if (lock_state) stateLock(s);
        var it = iter(SourcePad, h.pads);
        while (it.next()) |sp| if (sp.block_probe != 0) c.gst_pad_remove_probe(sp.src_pad, sp.block_probe);
        _ = c.gst_element_set_state(h.usb, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(s), h.usb);
        if (lock_state) stateUnlock(s);
        c.g_list_free(h.pads);
    }
    if (h.pending_buffering != null) c.gst_message_unref(h.pending_buffering);
    A.destroy(h);
}

fn newSourceItem(item: *PlayItem, uri: [*c]u8) *SourceItem {
    const x = A.create(SourceItem) catch @panic("oom");
    x.* = .{ .play = item, .uri = uri };
    return x;
}

fn freeSourceItem(s: *Self, x: *SourceItem) void {
    if (x.handler) |h| freeHandler(s, h, true);
    c.g_free(x.uri);
    A.destroy(x);
}

fn sourceItemSetUri(x: *SourceItem, uri: [*c]const u8) void {
    if (x.uri != null) c.g_free(x.uri);
    x.uri = c.g_strdup(uri);
    if (x.handler) |h| c.g_object_set(gobj(h.usb), "uri", uri, N);
}

fn newPlayItem(s: *Self) *PlayItem {
    const x = A.create(PlayItem) catch @panic("oom");
    x.* = .{ .bin = s };
    return x;
}

fn freePlayItem(s: *Self, x: *PlayItem) void {
    if (x.main) |m| freeSourceItem(s, m);
    if (x.sub) |m| freeSourceItem(s, m);
    A.destroy(x);
}

fn playItemSetUri(x: *PlayItem, uri: [*c]const u8) void {
    if (uri == null) return;
    if (x.main) |m| sourceItemSetUri(m, uri) else x.main = newSourceItem(x, c.g_strdup(uri));
}

fn playItemSetSuburi(x: *PlayItem, uri: [*c]const u8) void {
    if (uri == null) {
        if (x.sub) |m| {
            freeSourceItem(x.bin, m);
            x.sub = null;
        }
        return;
    }
    if (x.sub) |m| sourceItemSetUri(m, uri) else x.sub = newSourceItem(x, c.g_strdup(uri));
}

fn playItemIsEos(x: *PlayItem) bool {
    if (x.main) |m| if (m.handler) |h| if (!handlerIsEos(h)) return false;
    if (x.sub) |m| if (m.handler) |h| if (!handlerIsEos(h)) return false;
    return true;
}

fn playItemSetEos(x: *PlayItem) void {
    if (x.main) |m| if (m.handler) |h| handlerSetEos(h);
    if (x.sub) |m| if (m.handler) |h| handlerSetEos(h);
}

fn playItemHasAllPads(x: *PlayItem) bool {
    if (x.main) |m| if (m.handler) |h| if (h.expected_pads != c.g_list_length(h.pads)) return false;
    if (x.sub) |m| if (m.handler) |h| if (h.expected_pads != c.g_list_length(h.pads)) return false;
    return true;
}

fn nextInactive(s: *Self) *PlayItem {
    const t = st(s);
    var it = iter(PlayItem, t.items);
    while (it.next()) |x| if (!x.active) return x;
    const x = newPlayItem(s);
    t.items = c.g_list_append(t.items, x);
    return x;
}

fn ignoreBlock(_: ?*c.GstPad, _: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    return c.GST_PAD_PROBE_OK;
}

fn setUri(s: *Self, uri: [*c]const u8) void {
    const t = st(s);
    var start = false;
    lock(s);
    const item = nextInactive(s);
    playItemSetUri(item, uri);
    if (t.instant_uri != 0 and item != t.input) {
        const old = allPads(t.input.?);
        var it = iter(SourcePad, old);
        while (it.next()) |sp| {
            if (sp.db3_sink) |p| _ = c.gst_pad_send_event(p, c.gst_event_new_flush_start());
            sp.block_probe = c.gst_pad_add_probe(sp.src_pad, c.GST_PAD_PROBE_TYPE_IDLE, ignoreBlock, sp, null);
            sp.saw_eos = true;
        }
        it = iter(SourcePad, old);
        while (it.next()) |sp| if (sp.db3_sink) |p| {
            _ = c.gst_pad_send_event(p, c.gst_event_new_flush_stop(1));
        };
        c.g_list_free(old);
        start = true;
    } else if (t.input.?.posted_atf) {
        const l = c.g_list_find(t.items, t.input);
        if (l != null and l.*.next != null and l.*.next.*.data == @as(c.gpointer, item)) start = true;
    }
    unlock(s);
    if (start) _ = activatePlayItem(item);
}

fn setSuburi(s: *Self, uri: [*c]const u8) void {
    if (st(s).input.?.posted_atf) {
        cm.elementWarning(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NOT_IMPLEMENTED, c.g_strdup("Setting sub-uri in gapless mode is not handled"), c.g_strdup("Setting sub-uri in gapless mode is not implemented"), FILE, "gst_uri_decode_bin3_set_suburi", 1976);
    } else playItemSetSuburi(nextInactive(s), uri);
}

fn assignHandlers(s: *Self, item: *PlayItem) c.GstStateChangeReturn {
    const m = item.main orelse return c.GST_STATE_CHANGE_FAILURE;
    var ret: c.GstStateChangeReturn = c.GST_STATE_CHANGE_SUCCESS;
    if (m.handler == null) {
        stateLock(s);
        m.handler = newHandler(s, item, true);
        ret = activateSourceItem(m);
        if (ret == c.GST_STATE_CHANGE_FAILURE) {
            freeHandler(s, m.handler.?, false);
            m.handler = null;
        }
        stateUnlock(s);
    }
    return ret;
}

fn activatePlayItem(item: *PlayItem) c.GstStateChangeReturn {
    const ret = assignHandlers(item.bin, item);
    if (ret != c.GST_STATE_CHANGE_FAILURE) item.active = true;
    return ret;
}

fn purge(s: *Self) void {
    const t = st(s);
    lock(s);
    c.g_cond_broadcast(&t.drained_cond);
    while (t.items != null and t.items.*.next != null) {
        const x: *PlayItem = @ptrCast(@alignCast(t.items.*.data));
        t.items = c.g_list_remove(t.items, x);
        freePlayItem(s, x);
    }
    t.input = if (t.items != null) @ptrCast(@alignCast(t.items.*.data)) else null;
    t.output = t.input;
    t.output.?.posted_atf = false;
    unlock(s);
}

fn changeState(e: [*c]c.GstElement, tr: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    const t = st(s);
    switch (tr) {
        c.GST_STATE_CHANGE_NULL_TO_READY => c.g_object_set(gobj(t.decodebin), "caps", t.caps, N),
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            @atomicStore(c.gint, &t.shutdown, 0, .seq_cst);
            const r = activatePlayItem(t.input.?);
            currentUpdated(s);
            if (r == c.GST_STATE_CHANGE_FAILURE) {
                purge(s);
                return r;
            }
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            lock(s);
            @atomicStore(c.gint, &t.shutdown, 1, .seq_cst);
            c.g_cond_broadcast(&t.drained_cond);
            unlock(s);
        },
        else => {},
    }
    const ret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).change_state.?(e, tr);
    if (ret == c.GST_STATE_CHANGE_FAILURE) {
        if (tr == c.GST_STATE_CHANGE_READY_TO_PAUSED) purge(s);
        return ret;
    }
    if (tr == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        purge(s);
        t.input.?.active = false;
    }
    return ret;
}

fn handlerFor(s: *Self, e: ?*c.GstObject) ?*Handler {
    var it = iter(PlayItem, st(s).items);
    while (it.next()) |x| {
        if (x.main) |m| if (m.handler) |h| if (c.gst_object_has_as_ancestor(e, cm.obj(h.usb)) != 0) return h;
        if (x.sub) |m| if (m.handler) |h| if (c.gst_object_has_as_ancestor(e, cm.obj(h.usb)) != 0) return h;
    }
    return null;
}

fn redirection(s: *Self, msg: [*c]c.GstMessage, details: ?*const c.GstStructure) [*c]c.GstMessage {
    const t = st(s);
    var out = msg;
    lock(s);
    defer unlock(s);
    const h = handlerFor(s, msg.*.src) orelse return out;
    const m = h.play.main orelse return out;
    const current = m.uri;
    const location = c.gst_structure_get_string(details, "redirect-location");
    var uri: [*c]u8 = null;
    if (c.gst_uri_is_valid(location) != 0) {
        uri = c.g_strdup(location);
    } else if (current != null) uri = c.gst_uri_join_strings(current, location);
    if (uri == null) return out;
    defer c.g_free(uri);
    if (c.g_strcmp0(current, uri) != 0) {
        c.gst_message_unref(out);
        out = null;
        if (!h.saw_redirection) {
            const was = t.instant_uri;
            h.saw_redirection = true;
            t.instant_uri = 1;
            unlock(s);
            setUri(s, uri);
            lock(s);
            t.instant_uri = was;
        }
    }
    return out;
}

fn withUri(s: *Self, msg_in: [*c]c.GstMessage) [*c]c.GstMessage {
    const t = st(s);
    var msg = msg_in;
    lock(s);
    defer unlock(s);
    var uri: [*c]const u8 = null;
    if (c.gst_object_has_as_ancestor(msg.*.src, cm.obj(t.decodebin)) != 0) {
        if (t.output.?.main) |m| uri = m.uri;
    } else if (handlerFor(s, msg.*.src)) |h| {
        if (h.play.main) |m| uri = m.uri;
    }
    if (uri != null) {
        msg = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(msg)));
        c.gst_structure_set(c.gst_message_writable_details(msg), "uri", c.G_TYPE_STRING, uri, N);
    }
    return msg;
}

fn handleMessage(b: [*c]c.GstBin, msg_in: [*c]c.GstMessage) callconv(.c) void {
    const s = me(b);
    const t = st(s);
    var msg = msg_in;
    switch (msg.*.type) {
        c.GST_MESSAGE_STREAM_COLLECTION => {
            lock(s);
            if (handlerFor(s, msg.*.src) != null) {
                var selectable: c.gboolean = 0;
                const q = c.gst_query_new_selectable();
                if (c.gst_element_query(elem(msg.*.src), q) != 0) c.gst_query_parse_selectable(q, &selectable);
                c.gst_query_unref(q);
                if (selectable == 0) {
                    c.gst_message_unref(msg);
                    msg = null;
                }
            }
            unlock(s);
        },
        c.GST_MESSAGE_STREAMS_SELECTED => {
            lock(s);
            if (handlerFor(s, msg.*.src)) |h| h.expected_pads = c.gst_message_streams_selected_get_size(msg);
            unlock(s);
        },
        c.GST_MESSAGE_BUFFERING => {
            lock(s);
            if (handlerFor(s, msg.*.src)) |h| {
                const in = t.input.?;
                if (in.main == null or h != in.main.?.handler) {
                    if (h.pending_buffering != null) c.gst_message_unref(h.pending_buffering);
                    h.pending_buffering = msg;
                    msg = null;
                }
            } else {
                c.gst_message_unref(msg);
                msg = null;
            }
            unlock(s);
        },
        c.GST_MESSAGE_ERROR => {
            var details: ?*const c.GstStructure = null;
            c.gst_message_parse_error_details(msg, &details);
            if (details != null and c.gst_structure_has_field(details, "redirect-location") != 0) msg = redirection(s, msg, details);
            if (msg != null) msg = withUri(s, msg);
        },
        c.GST_MESSAGE_WARNING, c.GST_MESSAGE_INFO => msg = withUri(s, msg),
        else => {},
    }
    if (msg != null) parent_class.?.handle_message.?(b, msg);
}

fn sendEvent(e: [*c]c.GstElement, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const t = st(e);
    if ((cm.eventType(ev) & c.GST_EVENT_TYPE_UPSTREAM) != 0 and t.decodebin != null) return c.gst_element_send_event(t.decodebin, ev);
    return @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).send_event.?(e, ev);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_URI => setUri(s, c.g_value_get_string(v)),
        PROP_SUBURI => setSuburi(s, c.g_value_get_string(v)),
        PROP_CONNECTION_SPEED => {
            cm.lock(s);
            t.speed = c.g_value_get_uint64(v) *% 1000;
            cm.unlock(s);
        },
        PROP_BUFFER_SIZE => t.buffer_size = c.g_value_get_int(v),
        PROP_BUFFER_DURATION => t.buffer_duration = c.g_value_get_int64(v),
        PROP_DOWNLOAD => t.download = c.g_value_get_boolean(v),
        PROP_DOWNLOAD_DIR => {
            c.g_free(t.download_dir);
            t.download_dir = c.g_value_dup_string(v);
        },
        PROP_USE_BUFFERING => t.use_buffering = c.g_value_get_boolean(v),
        PROP_RING_BUFFER_MAX_SIZE => t.ring_max = c.g_value_get_uint64(v),
        PROP_CAPS => {
            cm.lock(s);
            if (t.caps != null) c.gst_caps_unref(t.caps);
            t.caps = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
            cm.unlock(s);
        },
        PROP_INSTANT_URI => {
            cm.lock(s);
            t.instant_uri = c.g_value_get_boolean(v);
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1615),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        PROP_URI => {
            const x: *PlayItem = @ptrCast(@alignCast(t.items.*.data));
            c.g_value_set_string(v, if (x.main) |m| m.uri else null);
        },
        PROP_CURRENT_URI => c.g_value_set_string(v, if (t.output) |x| (if (x.main) |m| m.uri else null) else null),
        PROP_SUBURI => {
            const x: *PlayItem = @ptrCast(@alignCast(t.items.*.data));
            c.g_value_set_string(v, if (x.sub) |m| m.uri else null);
        },
        PROP_CURRENT_SUBURI => c.g_value_set_string(v, if (t.output) |x| (if (x.sub) |m| m.uri else null) else null),
        PROP_CONNECTION_SPEED => c.g_value_set_uint64(v, t.speed / 1000),
        PROP_BUFFER_SIZE => c.g_value_set_int(v, t.buffer_size),
        PROP_BUFFER_DURATION => c.g_value_set_int64(v, t.buffer_duration),
        PROP_DOWNLOAD => c.g_value_set_boolean(v, t.download),
        PROP_DOWNLOAD_DIR => c.g_value_set_string(v, t.download_dir),
        PROP_USE_BUFFERING => c.g_value_set_boolean(v, t.use_buffering),
        PROP_RING_BUFFER_MAX_SIZE => c.g_value_set_uint64(v, t.ring_max),
        PROP_CAPS => c.g_value_set_boxed(v, t.caps),
        PROP_INSTANT_URI => c.g_value_set_boolean(v, t.instant_uri),
        else => cm.warnInvalid(FILE, o, id, spec, 1711),
    }
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    var it = iter(PlayItem, t.items);
    while (it.next()) |x| freePlayItem(s, x);
    c.g_list_free(t.items);
    t.items = null;
    c.g_free(t.download_dir);
    t.download_dir = null;
    c.g_mutex_clear(&t.lock);
    if (t.caps != null) c.gst_caps_unref(t.caps);
    t.caps = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    A.destroy(st(o));
    me(o).st = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    oc.finalize = finalize;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, PROP_URI, c.g_param_spec_string("uri", "URI", "URI to decode", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_CURRENT_URI, c.g_param_spec_string("current-uri", "Current URI", "The currently playing URI", null, ro));
    c.g_object_class_install_property(oc, PROP_SUBURI, c.g_param_spec_string("suburi", ".sub-URI", "Optional URI of a subtitle", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_CURRENT_SUBURI, c.g_param_spec_string("current-suburi", "Current .sub-URI", "The currently playing URI of a subtitle", null, ro));
    c.g_object_class_install_property(oc, PROP_CONNECTION_SPEED, c.g_param_spec_uint64("connection-speed", "Connection Speed", "Network connection speed in kbps (0 = unknown)", 0, std.math.maxInt(u64) / 1000, 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_BUFFER_SIZE, c.g_param_spec_int("buffer-size", "Buffer size (bytes)", "Buffer size when buffering streams (-1 default value)", -1, std.math.maxInt(c.gint), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_BUFFER_DURATION, c.g_param_spec_int64("buffer-duration", "Buffer duration (ns)", "Buffer duration when buffering streams (-1 default value)", -1, std.math.maxInt(i64), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_DOWNLOAD, c.g_param_spec_boolean("download", "Download", "Attempt download buffering when buffering network streams", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_DOWNLOAD_DIR, c.g_param_spec_string("download-dir", "Download Directory", "The directory where buffers are downloaded to, if 'download' is enabled. If not set (default), the XDG cache directory is used.", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_USE_BUFFERING, c.g_param_spec_boolean("use-buffering", "Use Buffering", "Perform buffering on demuxed/parsed media", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_RING_BUFFER_MAX_SIZE, c.g_param_spec_uint64("ring-buffer-max-size", "Max. ring buffer size (bytes)", "Max. amount of data in the ring buffer (bytes, 0 = ring buffer disabled)", 0, std.math.maxInt(c.guint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_CAPS, c.g_param_spec_boxed("caps", "Caps", "The caps on which to stop decoding. (NULL = default)", c.gst_caps_get_type(), cm.RW));
    c.g_object_class_install_property(oc, PROP_INSTANT_URI, c.g_param_spec_boolean("instant-uri", "Instantaneous URI change", "When enabled, URI changes are applied immediately", 0, cm.RW));
    const t = cm.typeOfClass(k);
    signals[SIG_SELECT_STREAM] = c.g_signal_new("select-stream", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "select_stream"), intAccu, null, null, c.G_TYPE_INT, 2, c.gst_stream_collection_get_type(), c.gst_stream_get_type());
    signals[SIG_SOURCE_SETUP] = c.g_signal_new("source-setup", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 1, c.gst_element_get_type());
    signals[SIG_ABOUT_TO_FINISH] = c.g_signal_new("about-to-finish", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 0, c.G_TYPE_NONE);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &video_t);
    c.gst_element_class_add_static_pad_template(ec, &audio_t);
    c.gst_element_class_add_static_pad_template(ec, &text_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "URI Decoder", "Generic/Bin/Decoder", "Autoplug and decode an URI to raw media", "Edward Hervey <edward@centricular.com>, Jan Schmidt <jan@centricular.com>");
    ec.change_state = changeState;
    ec.send_event = sendEvent;
    const bc: *c.GstBinClass = @ptrCast(@alignCast(k));
    bc.handle_message = handleMessage;
    const kc: *Class = @ptrCast(@alignCast(k));
    kc.select_stream = defaultSelect;
    _ = c._gst_debug_category_new("uridecodebin3", 0, "URI decoder element 3");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const t = A.create(State) catch @panic("oom");
    t.* = .{};
    s.st = t;
    t.caps = utils.rawCaps();
    c.g_mutex_init(&t.lock);
    c.g_cond_init(&t.drained_cond);
    t.decodebin = c.gst_element_factory_make("decodebin3", null);
    _ = c.gst_bin_add(binOf(s), t.decodebin);
    t.db_added = c.g_signal_connect_data(t.decodebin, "pad-added", @ptrCast(&dbPadAdded), s, null, 0);
    t.db_removed = c.g_signal_connect_data(t.decodebin, "pad-removed", @ptrCast(&dbPadRemoved), s, null, 0);
    t.db_select = c.g_signal_connect_data(t.decodebin, "select-stream", @ptrCast(&dbSelectStream), s, null, 0);
    t.db_atf = c.g_signal_connect_data(t.decodebin, "about-to-finish", @ptrCast(&dbAboutToFinish), s, null, 0);
    cm.obj(s).flags |= c.GST_ELEMENT_FLAG_SOURCE;
    c.gst_bin_set_suppressed_flags(binOf(s), c.GST_ELEMENT_FLAG_SOURCE | c.GST_ELEMENT_FLAG_SINK);
    const item = newPlayItem(s);
    t.items = c.g_list_append(t.items, item);
    t.input = item;
    t.output = item;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_bin_get_type(), "GstURIDecodeBin3", Class, Self, classInit, init);
        }
    }.f);
}
