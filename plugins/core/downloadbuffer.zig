const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const sparse = @import("sparse.zig");

const FILE = "../plugins/elements/gstdownloadbuffer.c";
const DOMAIN = "gstreamer-1.0";
const NONE = cm.CLOCK_NONE;
const SEC: u64 = 1_000_000_000;
const BLOCK = 4096;
const RATE_INTERVAL = 0.2;
const SEEK_THRESHOLD: u64 = 1024 * 512;

const PROP_MAX_SIZE_BYTES = 1;
const PROP_MAX_SIZE_TIME = 2;
const PROP_LOW_PERCENT = 3;
const PROP_HIGH_PERCENT = 4;
const PROP_TEMP_TEMPLATE = 5;
const PROP_TEMP_LOCATION = 6;
const PROP_TEMP_REMOVE = 7;

const Level = extern struct {
    bytes: c.guint,
    time: u64,
};

const Self = extern struct {
    parent: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    upstream_size: u64,
    srcresult: c.GstFlowReturn,
    sinkresult: c.GstFlowReturn,
    unexpected: c.gboolean,
    file: ?*sparse.File,
    write_pos: u64,
    read_pos: u64,
    filling: c.gboolean,
    cur_level: Level,
    max_level: Level,
    low_percent: c.gint,
    high_percent: c.gint,
    is_buffering: c.gboolean,
    buffering_percent: c.gint,
    in_timer: ?*c.GTimer,
    in_started: c.gboolean,
    last_in: f64,
    bytes_in: u64,
    in_rate: f64,
    in_period: f64,
    out_timer: ?*c.GTimer,
    out_started: c.gboolean,
    last_out: f64,
    bytes_out: u64,
    out_rate: f64,
    qlock: c.GMutex,
    waiting_add: c.gboolean,
    item_add: c.GCond,
    waiting_offset: u64,
    temp_template: [*c]u8,
    temp_location_set: c.gboolean,
    temp_location: [*c]u8,
    temp_remove: c.gboolean,
    temp_fd: c.gint,
    seeking: c.gboolean,
    stream_start: [*c]c.GstEvent,
    segment: [*c]c.GstEvent,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn element(p: anytype) [*c]c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn lockQ(d: *Self) void {
    c.g_mutex_lock(&d.qlock);
}

fn unlockQ(d: *Self) void {
    c.g_mutex_unlock(&d.qlock);
}

fn signalAdd(d: *Self, o: u64) void {
    if (d.waiting_add != 0 and d.waiting_offset <= o) c.g_cond_signal(&d.item_add);
}

fn post(d: *Self, m: [*c]c.GstMessage) void {
    if (m != null) _ = c.gst_element_post_message(element(d), m);
}

fn replace(slot: *[*c]c.GstEvent, ev: [*c]c.GstEvent) void {
    _ = c.gst_mini_object_replace(@ptrCast(slot), @ptrCast(ev));
}

fn resError(d: *Self, code: c.gint, text: [*c]u8, dbg: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(d, c.gst_resource_error_quark(), code, text, dbg, FILE, "gst_download_buffer_" ++ func, line);
}

fn resetPositions(d: *Self) void {
    d.write_pos = 0;
    d.read_pos = 0;
    d.filling = 1;
    d.buffering_percent = 0;
    d.is_buffering = 1;
    d.seeking = 0;
    d.cur_level = .{ .bytes = 0, .time = 0 };
}

fn resetRates(d: *Self) void {
    d.bytes_in = 0;
    d.bytes_out = 0;
    d.in_rate = 0;
    d.in_period = 0;
    d.out_rate = 0;
    d.last_in = 0;
    d.last_out = 0;
    d.in_started = 0;
    d.out_started = 0;
}

fn updateLevels(d: *Self, bytes: c.guint) void {
    d.cur_level.bytes = bytes;
    if (d.in_rate > 0.0) d.cur_level.time = @intFromFloat(@as(f64, @floatFromInt(bytes)) / d.in_rate * @as(f64, @floatFromInt(SEC)));
}

fn levelTo(d: *Self, a: u64, b: u64) void {
    updateLevels(d, if (a > b) @truncate(a - b) else 0);
}

fn tick(timer: ?*c.GTimer, started: *c.gboolean, last: *f64) ?f64 {
    if (started.* == 0) {
        started.* = 1;
        c.g_timer_start(timer);
        return null;
    }
    const now = c.g_timer_elapsed(timer, null);
    if (last.* + RATE_INTERVAL >= now) return null;
    const period = now - last.*;
    last.* = now;
    return period;
}

fn updateRates(d: *Self) void {
    if (tick(d.in_timer, &d.in_started, &d.last_in)) |period| {
        const rate = @as(f64, @floatFromInt(d.bytes_in)) / period;
        d.in_rate = if (d.in_rate == 0.0) rate else (d.in_rate * d.in_period + rate * period) / (d.in_period + period);
        if (d.in_period < 16 * RATE_INTERVAL) d.in_period += period;
        d.bytes_in = 0;
    }
    if (tick(d.out_timer, &d.out_started, &d.last_out)) |period| {
        const rate = @as(f64, @floatFromInt(d.bytes_out)) / period;
        d.out_rate = if (d.out_rate == 0.0) rate else (d.out_rate * 3.0 + rate) / 4.0;
        d.bytes_out = 0;
    }
}

fn percent(d: *Self, buffering: ?*c.gboolean) ?c.gint {
    if (d.high_percent <= 0) {
        if (buffering) |b| b.* = 0;
        return null;
    }
    updateRates(d);
    var p: c.gint = 0;
    if (d.max_level.bytes > 0) p = if (d.cur_level.bytes >= d.max_level.bytes) 100 else @bitCast(d.cur_level.bytes *% 100 / d.max_level.bytes);
    if (d.max_level.time > 0) {
        p = if (d.cur_level.time >= d.max_level.time) 100 else @max(p, @as(c.gint, @intCast(d.cur_level.time *% 100 / d.max_level.time)));
    }
    if (buffering) |b| b.* = d.is_buffering;
    p = @divTrunc(p * 100, d.high_percent);
    return @min(p, 100);
}

const Stats = struct {
    avg_in: c.gint,
    avg_out: c.gint,
    left: i64,
};

fn stats(d: *Self, p: c.gint) Stats {
    var left: i64 = if (p == 100) 0 else -1;
    if (p != 100 and d.max_level.time > d.cur_level.time) left = @intCast((d.max_level.time - d.cur_level.time) / 1_000_000);
    return .{ .avg_in = @intFromFloat(d.in_rate), .avg_out = @intFromFloat(d.out_rate), .left = left };
}

fn updateBuffering(d: *Self) [*c]c.GstMessage {
    const p = percent(d, null) orelse return null;
    var send = false;
    if (d.is_buffering != 0) {
        send = true;
        if (p >= d.high_percent) d.is_buffering = 0;
    } else if (p < d.low_percent) {
        d.is_buffering = 1;
        send = true;
    }
    if (!send or p == d.buffering_percent) return null;
    d.buffering_percent = p;
    const st = stats(d, p);
    const m = c.gst_message_new_buffering(cm.obj(d), p);
    c.gst_message_set_buffering_stats(m, c.GST_BUFFERING_DOWNLOAD, st.avg_in, st.avg_out, st.left);
    return m;
}

fn seekTo(d: *Self, off: u64) void {
    if (d.seeking != 0) return;
    d.seeking = 1;
    d.write_pos = off;
    d.filling = 0;
    unlockQ(d);
    _ = c.gst_pad_push_event(d.sinkpad, c.gst_event_new_seek(1.0, c.GST_FORMAT_BYTES, c.GST_SEEK_FLAG_FLUSH | c.GST_SEEK_FLAG_ACCURATE, c.GST_SEEK_TYPE_SET, @bitCast(off), c.GST_SEEK_TYPE_NONE, -1));
    lockQ(d);
}

fn updateUpstream(d: *Self) void {
    var size: i64 = 0;
    if (c.gst_pad_peer_query_duration(d.sinkpad, c.GST_FORMAT_BYTES, &size) != 0) d.upstream_size = @bitCast(size);
}

fn waitData(d: *Self, off_in: u64, len: c.guint) c.GstFlowReturn {
    var off = off_in;
    const wanted = off + len;
    const started = d.out_started != 0;
    if (started) c.g_timer_stop(d.out_timer);
    if (d.file.?.before(off)) |r| {
        if (r.start <= off and off < r.stop) {
            off = r.stop;
        } else if (off - r.stop <= SEEK_THRESHOLD) off = r.stop;
    }
    if (d.write_pos != off) {
        seekTo(d, off);
        if (d.srcresult == c.GST_FLOW_FLUSHING) return c.GST_FLOW_FLUSHING;
    }
    d.filling = 1;
    levelTo(d, d.write_pos, d.read_pos);
    d.waiting_add = 1;
    d.waiting_offset = wanted;
    c.g_cond_wait(&d.item_add, &d.qlock);
    d.waiting_add = 0;
    if (d.srcresult != c.GST_FLOW_OK) return c.GST_FLOW_FLUSHING;
    if (started) c.g_timer_continue(d.out_timer);
    return c.GST_FLOW_OK;
}

fn fitUpstream(d: *Self, off: u64, len: *c.guint) bool {
    const stop = off + len.*;
    if (d.upstream_size == NONE or stop >= d.upstream_size) updateUpstream(d);
    if (d.upstream_size != NONE) {
        if (off >= d.upstream_size) return false;
        if (stop > d.upstream_size) len.* = @truncate(d.upstream_size - off);
    }
    return true;
}

fn readBuffer(d: *Self, off_in: u64, len_in: c.guint, out: [*c][*c]c.GstBuffer) c.GstFlowReturn {
    var len: c.guint = if (len_in == std.math.maxInt(c.guint)) BLOCK else len_in;
    const off = if (off_in == NONE) d.read_pos else off_in;
    if (!fitUpstream(d, off, &len)) return c.GST_FLOW_EOS;
    const b = if (out[0] == null) c.gst_buffer_new_allocate(null, len, null) else out[0];
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(b, &info, c.GST_MAP_WRITE) == 0) {
        resError(d, c.GST_RESOURCE_ERROR_BUSY, c.g_strdup(cm.tr(DOMAIN, "Failed to map buffer.")), c.g_strdup("failed to map buffer in WRITE mode"), "read_buffer", 849);
        if (out[0] == null) c.gst_buffer_unref(b);
        return c.GST_FLOW_ERROR;
    }
    d.read_pos = off;
    var remaining: usize = 0;
    var got: usize = 0;
    while (got == 0) {
        var err: [*c]c.GError = null;
        got = d.file.?.read(off, info.data, len, &remaining, &err);
        if (got != 0) break;
        const would_block = err[0].code == sparse.WOULD_BLOCK;
        c.g_clear_error(&err);
        const r: c.GstFlowReturn = if (would_block) waitData(d, off, len) else c.GST_FLOW_ERROR;
        if (r != c.GST_FLOW_OK) {
            c.gst_buffer_unmap(b, &info);
            if (out[0] == null) c.gst_buffer_unref(b);
            return if (would_block) c.GST_FLOW_FLUSHING else c.GST_FLOW_ERROR;
        }
    }
    c.gst_buffer_unmap(b, &info);
    c.gst_buffer_resize(b, 0, @intCast(got));
    d.bytes_out += got;
    d.read_pos += got;
    if (d.read_pos + remaining == d.upstream_size) {
        updateLevels(d, d.max_level.bytes);
    } else updateLevels(d, @truncate(remaining));
    cm.buf(b).offset = off;
    cm.buf(b).offset_end = off + got;
    out[0] = b;
    return c.GST_FLOW_OK;
}

fn openTemp(d: *Self) bool {
    if (d.file != null) return true;
    if (d.temp_template == null) {
        resError(d, c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(cm.tr(DOMAIN, "No Temp directory specified.")), null, "open_temp_location_file", 934);
        return false;
    }
    const name = c.g_strdup(d.temp_template);
    const fd = c.g_mkstemp(name);
    if (fd == -1) {
        resError(d, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf(cm.tr(DOMAIN, "Could not create temp file \"%s\"."), d.temp_template), c.g_strdup_printf("system error: %s", c.g_strerror(std.c._errno().*)), "open_temp_location_file", 940);
        c.g_free(name);
        return false;
    }
    const f = sparse.File.create();
    d.file = f;
    if (!f.setFd(fd)) {
        resError(d, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf(cm.tr(DOMAIN, "Could not open file \"%s\" for reading."), name), c.g_strdup_printf("system error: %s", c.g_strerror(std.c._errno().*)), "open_temp_location_file", 948);
        c.g_free(name);
        _ = c.close(fd);
        return false;
    }
    c.g_free(d.temp_location);
    d.temp_location = name;
    d.temp_fd = fd;
    resetPositions(d);
    unlockQ(d);
    c.g_object_notify(@ptrCast(@alignCast(d)), "temp-location");
    lockQ(d);
    return true;
}

fn closeTemp(d: *Self) void {
    const f = d.file orelse return;
    f.destroy();
    d.file = null;
    d.temp_fd = -1;
    if (d.temp_remove != 0) _ = c.remove(d.temp_location);
}

fn lockedFlush(d: *Self, clear_temp: bool) void {
    if (clear_temp) if (d.file) |f| f.clear();
    resetPositions(d);
    replace(&d.stream_start, null);
    replace(&d.segment, null);
}

fn srcMode(p: ?*c.GstPad) c.GstPadMode {
    return cm.pad(p).mode;
}

fn sinkEvent(_: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const d = me(par);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_FLUSH_START => {
            if (srcMode(d.srcpad) == c.GST_PAD_MODE_PUSH) {
                const r = c.gst_pad_push_event(d.srcpad, ev);
                lockQ(d);
                d.srcresult = c.GST_FLOW_FLUSHING;
                d.sinkresult = c.GST_FLOW_FLUSHING;
                signalAdd(d, NONE);
                unlockQ(d);
                _ = c.gst_pad_pause_task(d.srcpad);
                return r;
            }
            lockQ(d);
            d.sinkresult = c.GST_FLOW_FLUSHING;
            unlockQ(d);
            c.gst_mini_object_unref(@ptrCast(ev));
            return 1;
        },
        c.GST_EVENT_FLUSH_STOP => {
            if (srcMode(d.srcpad) == c.GST_PAD_MODE_PUSH) {
                const r = c.gst_pad_push_event(d.srcpad, ev);
                lockQ(d);
                lockedFlush(d, true);
                d.srcresult = c.GST_FLOW_OK;
                d.sinkresult = c.GST_FLOW_OK;
                d.unexpected = 0;
                d.seeking = 0;
                resetRates(d);
                _ = c.gst_pad_start_task(d.srcpad, loop, d.srcpad, null);
                unlockQ(d);
                return r;
            }
            lockQ(d);
            d.unexpected = 0;
            d.sinkresult = c.GST_FLOW_OK;
            d.seeking = 0;
            unlockQ(d);
            c.gst_mini_object_unref(@ptrCast(ev));
            return 1;
        },
        else => {},
    }
    if (!cm.eventSerialized(ev)) return c.gst_pad_push_event(d.srcpad, ev);
    lockQ(d);
    if (d.sinkresult != c.GST_FLOW_OK) {
        unlockQ(d);
        c.gst_mini_object_unref(@ptrCast(ev));
        return 0;
    }
    var msg: [*c]c.GstMessage = null;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_EOS => {
            updateLevels(d, d.max_level.bytes);
            msg = updateBuffering(d);
            signalAdd(d, NONE);
        },
        c.GST_EVENT_SEGMENT => {
            replace(&d.segment, ev);
            d.unexpected = 0;
        },
        c.GST_EVENT_STREAM_START => replace(&d.stream_start, ev),
        else => {},
    }
    c.gst_mini_object_unref(@ptrCast(ev));
    unlockQ(d);
    post(d, msg);
    return 1;
}

fn sinkQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (cm.querySerialized(q)) return 0;
    return c.gst_pad_query_default(pad, par, q);
}

fn complete(d: *Self) c.GstFlowReturn {
    d.write_pos = d.upstream_size;
    d.filling = 0;
    updateLevels(d, d.max_level.bytes);
    const msg = updateBuffering(d);
    const done = c.gst_message_new_element(cm.obj(d), c.gst_structure_new("GstCacheDownloadComplete", "location", c.G_TYPE_STRING, d.temp_location, @as(?*anyopaque, null)));
    unlockQ(d);
    post(d, done);
    post(d, msg);
    return c.GST_FLOW_EOS;
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const d = me(par);
    lockQ(d);
    if (d.sinkresult != c.GST_FLOW_OK) {
        const r = d.sinkresult;
        unlockQ(d);
        c.gst_buffer_unref(b);
        return r;
    }
    if (d.unexpected != 0 or d.seeking != 0) {
        const r: c.GstFlowReturn = if (d.unexpected != 0) c.GST_FLOW_EOS else c.GST_FLOW_OK;
        unlockQ(d);
        c.gst_buffer_unref(b);
        return r;
    }
    const off = d.write_pos;
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(b, &info, c.GST_MAP_READ) == 0) {
        unlockQ(d);
        c.gst_buffer_unref(b);
        resError(d, c.GST_RESOURCE_ERROR_BUSY, c.g_strdup(cm.tr(DOMAIN, "Failed to map buffer.")), c.g_strdup("failed to map buffer in READ mode"), "chain", 1276);
        return c.GST_FLOW_ERROR;
    }
    var avail: usize = 0;
    var err: [*c]c.GError = null;
    if (d.file.?.write(off, info.data, info.size, &avail, &err) == 0) {
        unlockQ(d);
        c.gst_buffer_unmap(b, &info);
        c.gst_buffer_unref(b);
        resError(d, c.GST_RESOURCE_ERROR_WRITE, c.g_strdup(cm.tr(DOMAIN, "Error while writing to download file.")), c.g_strdup_printf("%s", err[0].message), "chain", 1285);
        c.g_clear_error(&err);
        return c.GST_FLOW_ERROR;
    }
    const size = info.size;
    c.gst_buffer_unmap(b, &info);
    c.gst_buffer_unref(b);
    d.write_pos = off + size;
    d.bytes_in += size;
    signalAdd(d, d.write_pos + avail);
    if (d.write_pos + avail == d.upstream_size) {
        if (d.file.?.after(0)) |r| {
            if (r.stop < d.upstream_size) {
                seekTo(d, r.stop);
            } else return complete(d);
        }
    } else if (avail > SEEK_THRESHOLD) seekTo(d, d.write_pos + avail);
    if (d.filling != 0) levelTo(d, d.write_pos, d.read_pos);
    const msg = updateBuffering(d);
    unlockQ(d);
    post(d, msg);
    return c.GST_FLOW_OK;
}

fn pauseLoop(d: *Self) void {
    const r = d.srcresult;
    _ = c.gst_pad_pause_task(d.srcpad);
    unlockQ(d);
    if (r == c.GST_FLOW_EOS) {
        _ = c.gst_pad_push_event(d.srcpad, c.gst_event_new_eos());
    } else if (r == c.GST_FLOW_NOT_LINKED or r < c.GST_FLOW_EOS) {
        cm.flowError(d, r, FILE, "gst_download_buffer_loop", 1377);
        _ = c.gst_pad_push_event(d.srcpad, c.gst_event_new_eos());
    }
}

fn loop(data: c.gpointer) callconv(.c) void {
    const d = me(cm.padParent(@as(?*c.GstPad, @ptrCast(@alignCast(data)))));
    lockQ(d);
    if (d.srcresult != c.GST_FLOW_OK) return pauseLoop(d);
    var b: [*c]c.GstBuffer = null;
    var r = readBuffer(d, NONE, std.math.maxInt(c.guint), &b);
    if (r != c.GST_FLOW_OK) {
        d.srcresult = r;
        return pauseLoop(d);
    }
    if (d.stream_start != null) {
        _ = c.gst_pad_push_event(d.srcpad, d.stream_start);
        d.stream_start = null;
    }
    if (d.segment != null) {
        _ = c.gst_pad_push_event(d.srcpad, d.segment);
        d.segment = null;
    }
    const msg = updateBuffering(d);
    unlockQ(d);
    post(d, msg);
    r = c.gst_pad_push(d.srcpad, b);
    lockQ(d);
    if (d.srcresult != c.GST_FLOW_OK) return pauseLoop(d);
    d.srcresult = r;
    d.sinkresult = r;
    if (r != c.GST_FLOW_OK) return pauseLoop(d);
    unlockQ(d);
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const d = me(par);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_FLUSH_START, c.GST_EVENT_FLUSH_STOP => {
            lockQ(d);
            if (cm.eventType(ev) == c.GST_EVENT_FLUSH_START) {
                d.srcresult = c.GST_FLOW_FLUSHING;
                signalAdd(d, NONE);
            } else d.srcresult = c.GST_FLOW_OK;
            unlockQ(d);
            c.gst_mini_object_unref(@ptrCast(ev));
            return 1;
        },
        c.GST_EVENT_RECONFIGURE => {
            lockQ(d);
            if (d.srcresult == c.GST_FLOW_NOT_LINKED) {
                d.srcresult = c.GST_FLOW_OK;
                d.sinkresult = c.GST_FLOW_OK;
                if (srcMode(pad) == c.GST_PAD_MODE_PUSH) _ = c.gst_pad_start_task(pad, loop, pad, null);
            }
            unlockQ(d);
        },
        else => {},
    }
    return c.gst_pad_push_event(d.sinkpad, ev);
}

fn bufferingQuery(d: *Self, q: [*c]c.GstQuery) void {
    var buffering: c.gboolean = 0;
    const p = percent(d, &buffering) orelse 100;
    c.gst_query_set_buffering_percent(q, buffering, p);
    const st = stats(d, p);
    c.gst_query_set_buffering_stats(q, c.GST_BUFFERING_DOWNLOAD, st.avg_in, st.avg_out, st.left);
    lockQ(d);
    const wpos = d.write_pos;
    updateUpstream(d);
    const dur = d.upstream_size;
    var fmt: c.GstFormat = 0;
    c.gst_query_parse_buffering_range(q, &fmt, null, null, null);
    var start: i64 = 0;
    var stop: i64 = -1;
    var total: i64 = -1;
    var off: usize = 0;
    while (d.file.?.after(off)) |r| {
        off = r.stop;
        var rs: u64 = r.start;
        var re: u64 = r.stop;
        const current = rs <= wpos and re >= wpos;
        if (current and @as(i64, @bitCast(dur)) >= @as(i64, @intCast(re)) and st.avg_in > 0) total = @divTrunc((@as(i64, @bitCast(dur)) - @as(i64, @intCast(re))) * 1000, st.avg_in);
        switch (fmt) {
            c.GST_FORMAT_PERCENT => if (dur == NONE) {
                rs = 0;
                re = 0;
            } else {
                rs = c.gst_util_uint64_scale(c.GST_FORMAT_PERCENT_MAX, rs, dur);
                re = c.gst_util_uint64_scale(c.GST_FORMAT_PERCENT_MAX, re, dur);
            },
            c.GST_FORMAT_BYTES => {},
            else => {
                rs = NONE;
                re = NONE;
            },
        }
        if (current) {
            start = @bitCast(rs);
            stop = @bitCast(re);
        }
        if (rs == re) continue;
        _ = c.gst_query_add_buffering_range(q, @bitCast(rs), @bitCast(re));
    }
    c.gst_query_set_buffering_range(q, fmt, start, stop, total);
    unlockQ(d);
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const d = me(par);
    switch (cm.queryType(q)) {
        c.GST_QUERY_POSITION => {
            if (c.gst_pad_peer_query(d.sinkpad, q) == 0) return 0;
            var fmt: c.GstFormat = 0;
            var pos: i64 = 0;
            c.gst_query_parse_position(q, &fmt, &pos);
            switch (fmt) {
                c.GST_FORMAT_BYTES => pos -= d.cur_level.bytes,
                c.GST_FORMAT_TIME => pos -%= @bitCast(d.cur_level.time),
                else => return 0,
            }
            if (pos < 0) pos = 0;
            c.gst_query_set_position(q, fmt, pos);
        },
        c.GST_QUERY_DURATION => if (c.gst_pad_peer_query(d.sinkpad, q) == 0) return 0,
        c.GST_QUERY_BUFFERING => bufferingQuery(d, q),
        c.GST_QUERY_SCHEDULING => {
            if (c.gst_pad_peer_query(d.sinkpad, q) == 0) return 0;
            var flags: c.GstSchedulingFlags = 0;
            c.gst_query_parse_scheduling(q, &flags, null, null, null);
            c.gst_query_set_scheduling(q, flags | c.GST_SCHEDULING_FLAG_SEEKABLE, 0, -1, 0);
            c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PULL);
            c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PUSH);
        },
        else => if (c.gst_pad_query_default(pad, par, q) == 0) return 0,
    }
    return 1;
}

fn elementQuery(el: [*c]c.GstElement, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    return srcQuery(me(el).srcpad, cm.obj(el), q);
}

fn getRange(_: ?*c.GstPad, par: [*c]c.GstObject, off: u64, len: c.guint, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const d = me(par);
    lockQ(d);
    if (d.srcresult != c.GST_FLOW_OK) {
        const r = d.srcresult;
        unlockQ(d);
        return r;
    }
    const r = readBuffer(d, off, len, out);
    const msg = updateBuffering(d);
    unlockQ(d);
    post(d, msg);
    return r;
}

fn sinkMode(pad: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, on: c.gboolean) callconv(.c) c.gboolean {
    const d = me(par);
    if (mode != c.GST_PAD_MODE_PUSH) return 0;
    lockQ(d);
    if (on != 0) {
        d.srcresult = c.GST_FLOW_OK;
        d.sinkresult = c.GST_FLOW_OK;
        d.unexpected = 0;
        resetRates(d);
        unlockQ(d);
        return 1;
    }
    d.srcresult = c.GST_FLOW_FLUSHING;
    d.sinkresult = c.GST_FLOW_FLUSHING;
    unlockQ(d);
    cm.streamLock(pad);
    lockQ(d);
    lockedFlush(d, false);
    unlockQ(d);
    cm.streamUnlock(pad);
    return 1;
}

fn srcModeFn(pad: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, on: c.gboolean) callconv(.c) c.gboolean {
    const d = me(par);
    if (mode != c.GST_PAD_MODE_PULL and mode != c.GST_PAD_MODE_PUSH) return 0;
    lockQ(d);
    if (on == 0) {
        d.srcresult = c.GST_FLOW_FLUSHING;
        d.sinkresult = c.GST_FLOW_FLUSHING;
        signalAdd(d, NONE);
        unlockQ(d);
        return if (mode == c.GST_PAD_MODE_PUSH) c.gst_pad_stop_task(pad) else 1;
    }
    var res: c.gboolean = 1;
    if (mode == c.GST_PAD_MODE_PULL) res = @intFromBool(openTemp(d));
    d.srcresult = c.GST_FLOW_OK;
    d.sinkresult = c.GST_FLOW_OK;
    d.unexpected = 0;
    d.upstream_size = NONE;
    if (mode == c.GST_PAD_MODE_PUSH) res = c.gst_pad_start_task(pad, loop, pad, null);
    unlockQ(d);
    return res;
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const d = me(el);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        lockQ(d);
        const ok = openTemp(d);
        replace(&d.stream_start, null);
        replace(&d.segment, null);
        unlockQ(d);
        if (!ok) return c.GST_STATE_CHANGE_FAILURE;
    }
    const r = parent.?.change_state.?(el, t);
    if (r == c.GST_STATE_CHANGE_FAILURE) return r;
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        lockQ(d);
        closeTemp(d);
        replace(&d.stream_start, null);
        replace(&d.segment, null);
        unlockQ(d);
    }
    return r;
}

fn setTemplate(d: *Self, t: [*c]const u8) void {
    cm.lock(d);
    const st = element(d)[0].current_state;
    cm.unlock(d);
    if (st != c.GST_STATE_READY and st != c.GST_STATE_NULL) return;
    c.g_free(d.temp_template);
    d.temp_template = c.g_strdup(t);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const d = me(o);
    var msg: [*c]c.GstMessage = null;
    lockQ(d);
    switch (id) {
        PROP_MAX_SIZE_BYTES => {
            d.max_level.bytes = c.g_value_get_uint(v);
            msg = updateBuffering(d);
        },
        PROP_MAX_SIZE_TIME => {
            d.max_level.time = c.g_value_get_uint64(v);
            msg = updateBuffering(d);
        },
        PROP_LOW_PERCENT => d.low_percent = c.g_value_get_int(v),
        PROP_HIGH_PERCENT => d.high_percent = c.g_value_get_int(v),
        PROP_TEMP_TEMPLATE => setTemplate(d, c.g_value_get_string(v)),
        PROP_TEMP_REMOVE => d.temp_remove = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 1928),
    }
    unlockQ(d);
    post(d, msg);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const d = me(o);
    lockQ(d);
    defer unlockQ(d);
    switch (id) {
        PROP_MAX_SIZE_BYTES => c.g_value_set_uint(v, d.max_level.bytes),
        PROP_MAX_SIZE_TIME => c.g_value_set_uint64(v, d.max_level.time),
        PROP_LOW_PERCENT => c.g_value_set_int(v, d.low_percent),
        PROP_HIGH_PERCENT => c.g_value_set_int(v, d.high_percent),
        PROP_TEMP_TEMPLATE => c.g_value_set_string(v, d.temp_template),
        PROP_TEMP_LOCATION => c.g_value_set_string(v, d.temp_location),
        PROP_TEMP_REMOVE => c.g_value_set_boolean(v, d.temp_remove),
        else => cm.warnInvalid(FILE, o, id, spec, 1970),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const d = me(o);
    c.g_mutex_clear(&d.qlock);
    c.g_cond_clear(&d.item_add);
    c.g_timer_destroy(d.in_timer);
    c.g_timer_destroy(d.out_timer);
    c.g_free(d.temp_template);
    c.g_free(d.temp_location);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const P = cm.RW | cm.MUTABLE_PLAYING;
    c.g_object_class_install_property(oc, PROP_MAX_SIZE_BYTES, c.g_param_spec_uint("max-size-bytes", "Max. size (kB)", "Max. amount of data to buffer (bytes, 0=disable)", 0, std.math.maxInt(c.guint), 2 * 1024 * 1024, P));
    c.g_object_class_install_property(oc, PROP_MAX_SIZE_TIME, c.g_param_spec_uint64("max-size-time", "Max. size (ns)", "Max. amount of data to buffer (in ns, 0=disable)", 0, std.math.maxInt(u64), 2 * SEC, P));
    c.g_object_class_install_property(oc, PROP_LOW_PERCENT, c.g_param_spec_int("low-percent", "Low percent", "Low threshold for buffering to start. Emits GST_MESSAGE_BUFFERING with a value of 0%", 0, 100, 10, cm.RW));
    c.g_object_class_install_property(oc, PROP_HIGH_PERCENT, c.g_param_spec_int("high-percent", "High percent", "High threshold for buffering to finish. Emits GST_MESSAGE_BUFFERING with a value of 100%", 0, 100, 99, cm.RW));
    c.g_object_class_install_property(oc, PROP_TEMP_TEMPLATE, c.g_param_spec_string("temp-template", "Temporary File Template", "File template to store temporary files in, should contain directory and XXXXXX. (NULL == disabled)", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_TEMP_LOCATION, c.g_param_spec_string("temp-location", "Temporary File Location", "Location to store temporary files in (Only read this property, use temp-template to configure the name template)", null, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PROP_TEMP_REMOVE, c.g_param_spec_boolean("temp-remove", "Remove the Temporary File", "Remove the temp-location after use", 1, cm.RW));
    oc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "DownloadBuffer", "Generic", "Download Buffer element", "Wim Taymans <wim.taymans@gmail.com>");
    ec.change_state = changeState;
    ec.query = elementQuery;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const d = me(inst);
    d.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(d.sinkpad, chain, null, null);
    c.gst_pad_set_activatemode_function_full(d.sinkpad, sinkMode, null, null);
    c.gst_pad_set_event_function_full(d.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(d.sinkpad, sinkQuery, null, null);
    cm.setPadFlag(d.sinkpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(element(d), d.sinkpad);
    d.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_activatemode_function_full(d.srcpad, srcModeFn, null, null);
    c.gst_pad_set_getrange_function_full(d.srcpad, getRange, null, null);
    c.gst_pad_set_event_function_full(d.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(d.srcpad, srcQuery, null, null);
    cm.setPadFlag(d.srcpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(element(d), d.srcpad);
    d.cur_level = .{ .bytes = 0, .time = 0 };
    d.max_level = .{ .bytes = 2 * 1024 * 1024, .time = 2 * SEC };
    d.low_percent = 10;
    d.high_percent = 99;
    d.srcresult = c.GST_FLOW_FLUSHING;
    d.sinkresult = c.GST_FLOW_FLUSHING;
    d.in_timer = c.g_timer_new();
    d.out_timer = c.g_timer_new();
    c.g_mutex_init(&d.qlock);
    d.waiting_add = 0;
    c.g_cond_init(&d.item_add);
    d.temp_template = null;
    d.temp_location = null;
    d.temp_remove = 1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstDownloadBuffer", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("downloadbuffer", 0, "downloadbuffer element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "downloadbuffer", c.GST_RANK_NONE, getType()) != 0;
}
