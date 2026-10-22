const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const basic = @import("basic.zig");
const config = @import("config");

comptime {
    @import("../abi.zig").check(@This());
}

const NONE = basic.NONE;
const SECOND = basic.SECOND;
const MS: u64 = 1_000_000;
const ID_NONE: u64 = std.math.maxInt(u64);
const FILE = "../libs/gst/net/gstptpclock.c";
const WINDOW = 9;
const MAX_SKIPPED = 5;
const RECEIPT_TIMEOUT = 4;

const SYNC = 0x0;
const DELAY_REQ = 0x1;
const FOLLOW_UP = 0x8;
const DELAY_RESP = 0x9;
const ANNOUNCE = 0xB;

const TYPE_EVENT = 0;
const TYPE_GENERAL = 1;
const TYPE_CLOCK_ID = 2;
const TYPE_SEND_TIME_ACK = 3;

const NEW_DOMAIN = "GstPtpStatisticsNewDomainFound";
const BEST_MASTER = "GstPtpStatisticsBestMasterClockSelected";
const PATH_DELAY = "GstPtpStatisticsPathDelayMeasured";
const TIME_UPDATED = "GstPtpStatisticsTimeUpdated";

const Id = struct {
    clock: u64 = 0,
    port: u16 = 0,

    fn cmp(a: Id, b: Id) i32 {
        if (a.clock < b.clock) return -1;
        if (a.clock > b.clock) return 1;
        if (a.port < b.port) return -1;
        if (a.port > b.port) return 1;
        return 0;
    }
};

const Quality = struct { class: u8 = 0, accuracy: u8 = 0, variance: u16 = 0 };

const Message = struct {
    kind: u8 = 0,
    version: u8 = 0,
    length: u16 = 0,
    domain: u8 = 0,
    flags: u16 = 0,
    correction: i64 = 0,
    source: Id = .{},
    seq: u16 = 0,
    control: u8 = 0,
    interval: i8 = 0,
    stamp: u64 = 0,
    stamp_seconds: u64 = 0,
    utc_offset: i16 = 0,
    prio1: u8 = 0,
    quality: Quality = .{},
    prio2: u8 = 0,
    grandmaster: u64 = 0,
    steps: u16 = 0,
    source_kind: u8 = 0,
    requester: Id = .{},
};

const Sender = struct {
    master: Id,
    iface: u8,
    interval: u64 = 0,
    messages: c.GQueue = std.mem.zeroes(c.GQueue),
    timed_out_sync: u64 = 0,
    timed_out_delay_resp: u64 = 0,
};

const Announce = struct {
    sender: *Sender,
    receive_time: u64,
    master: Id,
    iface: u8,
    prio1: u8,
    quality: Quality,
    prio2: u8,
    grandmaster: u64,
    steps: u16,
    source_kind: u8,
    seq: u16,
};

const Pending = struct {
    domain: c.guint,
    sync_seqnum: u32 = 0,
    sync_recv_local: u64 = NONE,
    sync_send_remote: u64 = NONE,
    follow_up_recv_local: u64 = NONE,
    timeout_source: ?*c.GSource = null,
    iface: u8 = 0,
    delay_req_seqnum: u32 = std.math.maxInt(u32),
    delay_req_send_local: u64 = NONE,
    delay_req_recv_remote: u64 = NONE,
    delay_resp_recv_local: u64 = NONE,
    correction_sync: i64 = 0,
    correction_delay: i64 = 0,
};

const Domain = struct {
    domain: c.guint,
    last_ptp_time: u64 = 0,
    last_local_time: u64 = 0,
    skipped_updates: i32 = 0,
    senders: [*c]c.GList = null,
    have_master: bool = false,
    master: Id = .{},
    iface: u8 = 0,
    grandmaster: u64 = 0,
    last_sync_time: u64 = 0,
    last_sync_time_local: u64 = 0,
    sync_interval: u64 = 0,
    mean_path_delay: u64 = 0,
    last_delay_req: u64 = 0,
    min_delay_req_interval: u64 = 0,
    last_delay_req_seqnum: u16 = 0,
    last_delay_resp_local: u64 = 0,
    last_path_delays: [WINDOW]u64 = .{0} ** WINDOW,
    last_path_delays_missing: i32 = 9,
    pending: c.GQueue = std.mem.zeroes(c.GQueue),
    clock: [*c]c.GstClock = null,
};

const A = std.heap.c_allocator;

var ptp_lock: c.GMutex = std.mem.zeroes(c.GMutex);
var ptp_cond: c.GCond = std.mem.zeroes(c.GCond);
var initted: bool = false;
var supported: bool = true;
var helper: ?*c.GSubprocess = null;
var stdout_pipe: ?*c.GInputStream = null;
var stderr_pipe: ?*c.GInputStream = null;
var stdin_pipe: ?*c.GOutputStream = null;
var stdio_header: [3]u8 = .{ 0, 0, 0 };
var stdout_buffer: [8192]u8 = undefined;
var stderr_header: [2]u8 = .{ 0, 0 };
var stderr_buffer: [8192]u8 = undefined;
var helper_thread: ?*c.GThread = null;
var main_context: ?*c.GMainContext = null;
var main_loop: ?*c.GMainLoop = null;
var delay_rand: ?*c.GRand = null;
var observation: [*c]c.GstClock = null;
var clock_id: Id = .{ .clock = ID_NONE, .port = 0 };
var domains: [*c]c.GList = null;
var domain_clocks_lock: c.GMutex = std.mem.zeroes(c.GMutex);
var domain_clocks: [*c]c.GList = null;
const HookList = extern struct {
    seq_id: c.gulong = 0,
    bits: c.guint = 0,
    hooks: ?*c.GHook = null,
    dummy3: c.gpointer = null,
    finalize_hook: c.gpointer = null,
    dummy: [2]c.gpointer = .{ null, null },
};

var hook_store: HookList = .{};
const hooks: *c.GHookList = @ptrCast(&hook_store);
var n_hooks: c.gint = 0;
var hooks_initted = false;
var hybrid_warned = false;
var cat: ?*c.GstDebugCategory = null;
var cat_once: usize = 0;

fn category() ?*c.GstDebugCategory {
    if (c.g_once_init_enter(&cat_once) != 0) {
        cat = c._gst_debug_category_new("ptp", 0, "PTP clock");
        c.g_once_init_leave(&cat_once, 1);
    }
    return cat;
}

fn log(level: c.GstDebugLevel, comptime func: [:0]const u8, line: c_int, comptime fmt: [:0]const u8, args: anytype) void {
    @call(.auto, c.gst_debug_log, .{ category(), level, FILE, func.ptr, line, @as([*c]c.GObject, null), fmt.ptr } ++ args);
}

fn log2Time(l: i8) u64 {
    if (l < 0) return SECOND >> @intCast(@min(63, -@as(i16, l)));
    return SECOND << @intCast(@min(63, @as(i16, l)));
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn remaining(r: *Reader) usize {
        return r.data.len - r.pos;
    }

    fn u8_(r: *Reader) u8 {
        const v = r.data[r.pos];
        r.pos += 1;
        return v;
    }

    fn u16_(r: *Reader) u16 {
        const v = std.mem.readInt(u16, r.data[r.pos..][0..2], .big);
        r.pos += 2;
        return v;
    }

    fn u32_(r: *Reader) u32 {
        const v = std.mem.readInt(u32, r.data[r.pos..][0..4], .big);
        r.pos += 4;
        return v;
    }

    fn u64_(r: *Reader) u64 {
        const v = std.mem.readInt(u64, r.data[r.pos..][0..8], .big);
        r.pos += 8;
        return v;
    }

    fn skip(r: *Reader, n: usize) void {
        r.pos += n;
    }
};

fn timestamp(r: *Reader, seconds: *u64) ?u64 {
    if (!basic.that(r.remaining() >= 10, "parse_ptp_timestamp", "gst_byte_reader_get_remaining (reader) >= 10")) return null;
    const s = (@as(u64, r.u32_()) << 16) | r.u16_();
    const ns = r.u32_();
    seconds.* = s;
    if (ns >= 1000000000) return null;
    return s *% SECOND +% ns;
}

fn parse(msg: *Message, data: []const u8) bool {
    var r = Reader{ .data = data };
    if (!basic.that(r.remaining() >= 34, "parse_ptp_message_header", "gst_byte_reader_get_remaining (reader) >= 34")) {
        log(c.GST_LEVEL_WARNING, "parse_ptp_message", 681, "Failed to parse PTP message header", .{});
        return false;
    }
    var b = r.u8_();
    msg.kind = b & 0x0f;
    b = r.u8_();
    msg.version = b & 0x0f;
    if (msg.version != 2) {
        log(c.GST_LEVEL_WARNING, "parse_ptp_message_header", 534, "Unsupported PTP message version (%u != 2)", .{@as(c.guint, msg.version)});
        log(c.GST_LEVEL_WARNING, "parse_ptp_message", 681, "Failed to parse PTP message header", .{});
        return false;
    }
    msg.length = r.u16_();
    if (r.remaining() + 4 < msg.length) {
        log(c.GST_LEVEL_WARNING, "parse_ptp_message_header", 540, "Not enough data (%u < %u)", .{ @as(c.guint, @intCast(r.remaining() + 4)), @as(c.guint, msg.length) });
        log(c.GST_LEVEL_WARNING, "parse_ptp_message", 681, "Failed to parse PTP message header", .{});
        return false;
    }
    msg.domain = r.u8_();
    r.skip(1);
    msg.flags = r.u16_();
    msg.correction = @bitCast(r.u64_());
    r.skip(4);
    msg.source.clock = r.u64_();
    msg.source.port = r.u16_();
    msg.seq = r.u16_();
    msg.control = r.u8_();
    msg.interval = @bitCast(r.u8_());
    switch (msg.kind) {
        SYNC, FOLLOW_UP, DELAY_REQ => {
            if (r.remaining() < 10) return false;
            msg.stamp = timestamp(&r, &msg.stamp_seconds) orelse return false;
            return true;
        },
        DELAY_RESP => {
            if (r.remaining() < 20) return false;
            msg.stamp = timestamp(&r, &msg.stamp_seconds) orelse return false;
            msg.requester.clock = r.u64_();
            msg.requester.port = r.u16_();
            return true;
        },
        ANNOUNCE => {
            if (r.remaining() < 30) return false;
            msg.stamp = timestamp(&r, &msg.stamp_seconds) orelse return false;
            msg.utc_offset = @bitCast(r.u16_());
            r.skip(1);
            msg.prio1 = r.u8_();
            msg.quality.class = r.u8_();
            msg.quality.accuracy = r.u8_();
            msg.quality.variance = r.u16_();
            msg.prio2 = r.u8_();
            msg.grandmaster = r.u64_();
            msg.steps = r.u16_();
            msg.source_kind = r.u8_();
            return true;
        },
        else => return false,
    }
}

fn compareAnnounce(a: *Announce, b: *Announce, skip_ties: bool) i32 {
    if (a.grandmaster == b.grandmaster) {
        const ta = a.sender.timed_out_delay_resp +% a.sender.timed_out_sync;
        const tb = b.sender.timed_out_delay_resp +% b.sender.timed_out_sync;
        if (ta +% 4 < tb) return -1;
        if (ta > tb +% 4) return 1;
        if (a.steps < b.steps) return -1;
        if (a.steps > b.steps) return 1;
        if (ta < tb) return -1;
        if (ta > tb) return 1;
        if (skip_ties) return 0;
        const r = Id.cmp(a.master, b.master);
        if (r != 0) return r;
        if (a.iface < b.iface) return -1;
        if (a.iface > b.iface) return 1;
        return 0;
    }
    const pairs = [_][2]u64{
        .{ a.prio1, b.prio1 },
        .{ a.quality.class, b.quality.class },
        .{ a.quality.accuracy, b.quality.accuracy },
        .{ a.quality.variance, b.quality.variance },
        .{ a.prio2, b.prio2 },
        .{ a.grandmaster, b.grandmaster },
    };
    for (pairs) |p| {
        if (p[0] < p[1]) return -1;
        if (p[0] > p[1]) return 1;
    }
    return 0;
}

fn emit(domain: c.guint, stats: ?*c.GstStructure) void {
    const Data = struct { domain: u8, stats: ?*c.GstStructure };
    var d = Data{ .domain = @truncate(domain), .stats = stats };
    const marshal = struct {
        fn f(hook: [*c]c.GHook, data: c.gpointer) callconv(.c) void {
            const dd: *Data = @ptrCast(@alignCast(data));
            const cb: c.GstPtpStatisticsCallback = @ptrCast(hook.*.func);
            if (cb.?(dd.domain, dd.stats, hook.*.data) == 0) _ = c.g_hook_destroy(hooks, hook.*.hook_id);
        }
    }.f;
    c.g_mutex_lock(&ptp_lock);
    c.g_hook_list_marshal(hooks, 1, marshal, &d);
    c.g_mutex_unlock(&ptp_lock);
}

fn hasHooks() bool {
    return @atomicLoad(c.gint, &n_hooks, .seq_cst) != 0;
}

fn freePending(p: *Pending) void {
    if (p.timeout_source) |s| {
        c.g_source_destroy(s);
        c.g_source_unref(s);
    }
    A.destroy(p);
}

fn freePendingCb(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    freePending(@ptrCast(@alignCast(p)));
}

fn freeAnnounceCb(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    A.destroy(@as(*Announce, @ptrCast(@alignCast(p))));
}

fn findSender(d: *Domain, id: Id, iface: u8) ?*Sender {
    var l = d.senders;
    while (l != null) : (l = l.*.next) {
        const s: *Sender = @ptrCast(@alignCast(l.*.data));
        if (Id.cmp(s.master, id) == 0 and s.iface == iface) return s;
    }
    return null;
}

fn selectBest(d: *Domain, now: u64) void {
    var qualified: [*c]c.GList = null;
    var l = d.senders;
    while (l != null) : (l = l.*.next) {
        const s: *Sender = @ptrCast(@alignCast(l.*.data));
        const window = 4 *% s.interval;
        var count: i32 = 0;
        var m = s.messages.head;
        while (m != null) : (m = m.*.next) {
            const a: *Announce = @ptrCast(@alignCast(m.*.data));
            if (now -% a.receive_time <= window) count += 1;
        }
        if (count >= 2) qualified = c.g_list_prepend(qualified, c.g_queue_peek_tail(&s.messages));
    }
    if (qualified == null) {
        d.have_master = false;
        return;
    }
    var best: ?*Announce = null;
    l = qualified;
    while (l != null) : (l = l.*.next) {
        const a: *Announce = @ptrCast(@alignCast(l.*.data));
        if (best == null or compareAnnounce(a, best.?, false) < 0) best = a;
    }
    if (d.have_master and (Id.cmp(d.master, best.?.master) != 0 or d.iface != best.?.iface)) {
        if (findSender(d, d.master, d.iface)) |s| {
            var m = qualified;
            while (m != null) : (m = m.*.next) {
                const a: *Announce = @ptrCast(@alignCast(m.*.data));
                if (Id.cmp(s.master, a.master) == 0 and s.iface == a.iface) {
                    if (compareAnnounce(a, best.?, true) == 0) best = a;
                    break;
                }
            }
        }
    }
    c.g_list_free(qualified);
    const b = best.?;
    if (d.have_master and Id.cmp(d.master, b.master) == 0 and d.iface == b.iface) return;
    d.have_master = true;
    d.grandmaster = b.grandmaster;
    if (Id.cmp(d.master, b.master) != 0 or d.iface != b.iface) {
        d.master = b.master;
        d.iface = b.iface;
        d.mean_path_delay = 0;
        d.last_delay_req = 0;
        d.last_path_delays_missing = 9;
        d.last_delay_resp_local = 0;
        d.min_delay_req_interval = 0;
        d.sync_interval = 0;
        d.last_sync_time = 0;
        d.last_sync_time_local = 0;
        d.skipped_updates = 0;
        c.g_queue_foreach(&d.pending, freePendingCb, null);
        c.g_queue_clear(&d.pending);
    }
    if (hasHooks()) {
        const st = c.gst_structure_new(BEST_MASTER, "domain", c.G_TYPE_UINT, d.domain, "master-clock-id", c.G_TYPE_UINT64, d.master.clock, "master-clock-port", c.G_TYPE_UINT, @as(c.guint, d.master.port), "grandmaster-clock-id", c.G_TYPE_UINT64, d.grandmaster, @as(?*anyopaque, null));
        emit(d.domain, st);
        c.gst_structure_free(st);
    }
}

fn findDomain(n: c.guint) ?*Domain {
    var l = domains;
    while (l != null) : (l = l.*.next) {
        const d: *Domain = @ptrCast(@alignCast(l.*.data));
        if (d.domain == n) return d;
    }
    return null;
}

fn newDomain(n: c.guint) *Domain {
    const d = A.create(Domain) catch unreachable;
    d.* = .{ .domain = n };
    const name = c.g_strdup_printf("ptp-clock-%u", n);
    d.clock = @ptrCast(@alignCast(c.g_object_new(c.gst_system_clock_get_type(), "name", name, @as(?*anyopaque, null))));
    _ = c.gst_object_ref_sink(d.clock);
    c.g_free(name);
    domains = c.g_list_prepend(domains, d);
    c.g_mutex_lock(&domain_clocks_lock);
    domain_clocks = c.g_list_prepend(domain_clocks, d);
    c.g_mutex_unlock(&domain_clocks_lock);
    return d;
}

fn warnHybrid() void {
    if (!hybrid_warned) {
        log(c.GST_LEVEL_WARNING, "handle_announce_message", 1048, "Working around ptpd bug: ptpd sends multicast PTP packets with invalid logMessageInterval", .{});
        hybrid_warned = true;
    }
}

fn handleAnnounce(msg: *Message, iface: u8, recv: u64) void {
    if (msg.flags & 0x0100 != 0) return;
    if (msg.steps >= 255) return;
    const d = findDomain(msg.domain) orelse blk: {
        const nd = newDomain(msg.domain);
        if (hasHooks()) {
            const st = c.gst_structure_new(NEW_DOMAIN, "domain", c.G_TYPE_UINT, nd.domain, "clock", c.gst_clock_get_type(), nd.clock, @as(?*anyopaque, null));
            emit(nd.domain, st);
            c.gst_structure_free(st);
        }
        break :blk nd;
    };
    const s = findSender(d, msg.source, iface) orelse blk: {
        const ns = A.create(Sender) catch unreachable;
        ns.* = .{ .master = msg.source, .iface = iface };
        d.senders = c.g_list_prepend(d.senders, ns);
        break :blk ns;
    };
    var l = s.messages.head;
    while (l != null) : (l = l.*.next) {
        const a: *Announce = @ptrCast(@alignCast(l.*.data));
        if (a.seq == msg.seq) return;
    }
    if (msg.interval == 0x7f) {
        s.interval = 2 * SECOND;
        warnHybrid();
    } else s.interval = log2Time(msg.interval);
    const a = A.create(Announce) catch unreachable;
    a.* = .{ .sender = s, .receive_time = recv, .seq = msg.seq, .master = msg.source, .iface = iface, .grandmaster = msg.grandmaster, .prio1 = msg.prio1, .quality = msg.quality, .prio2 = msg.prio2, .steps = msg.steps, .source_kind = msg.source_kind };
    c.g_queue_push_tail(&s.messages, a);
    selectBest(d, recv);
}

fn sendDelayReqTimeout(data: c.gpointer) callconv(.c) c.gboolean {
    const p: *Pending = @ptrCast(@alignCast(data));
    var msg = [_]u8{0} ** (3 + 1 + 8 + 44);
    const now = c.gst_clock_get_time(observation);
    p.delay_req_send_local = now;
    std.mem.writeInt(u16, msg[0..2], 1 + 8 + 44, .big);
    msg[2] = TYPE_EVENT;
    msg[3] = p.iface;
    std.mem.writeInt(u64, msg[4..12], now, .big);
    msg[12] = DELAY_REQ;
    msg[13] = 2;
    std.mem.writeInt(u16, msg[14..16], 44, .big);
    msg[16] = @truncate(p.domain);
    std.mem.writeInt(u64, msg[32..40], clock_id.clock, .big);
    std.mem.writeInt(u16, msg[40..42], clock_id.port, .big);
    std.mem.writeInt(u16, msg[42..44], @truncate(p.delay_req_seqnum), .big);
    msg[44] = 0x01;
    msg[45] = 0x7f;
    var written: usize = 0;
    var err: [*c]c.GError = null;
    if (c.g_output_stream_write_all(stdin_pipe, &msg, msg.len, &written, null, &err) == 0) {
        if (c.g_error_matches(err, c.g_io_error_quark(), c.G_IO_ERROR_CLOSED) != 0 or c.g_error_matches(err, c.g_io_error_quark(), c.G_IO_ERROR_CONNECTION_CLOSED) != 0) {
            log(c.GST_LEVEL_ERROR, "send_delay_req_timeout", 1123, "Got EOF on stdout", .{});
        } else log(c.GST_LEVEL_ERROR, "send_delay_req_timeout", 1125, "Failed to write delay-req to stdin: %s", .{err.*.message});
        c.g_clear_error(&err);
        c.g_log(basic.DOMAIN, c.G_LOG_LEVEL_MESSAGE, "EOF on stdout");
        c.g_main_loop_quit(main_loop);
        return 0;
    } else if (written != msg.len) {
        log(c.GST_LEVEL_ERROR, "send_delay_req_timeout", 1132, "Unexpected write size: %" ++ "lu", .{written});
        c.g_main_loop_quit(main_loop);
    }
    return 0;
}

fn sendDelayReq(d: *Domain, p: *Pending) bool {
    const now = c.gst_clock_get_time(observation);
    if (d.last_delay_req != 0 and d.last_delay_req +% d.min_delay_req_interval > now) return false;
    d.last_delay_req = now;
    p.iface = d.iface;
    p.delay_req_seqnum = d.last_delay_req_seqnum;
    d.last_delay_req_seqnum +%= 1;
    const timeout: c.guint = if (d.last_delay_req == 0 or d.min_delay_req_interval == 0) 0 else @bitCast(c.g_rand_int_range(delay_rand, 0, @intCast((d.min_delay_req_interval * 2) / MS)));
    const src = c.g_timeout_source_new(timeout);
    p.timeout_source = src;
    c.g_source_set_priority(src, c.G_PRIORITY_DEFAULT);
    c.g_source_set_callback(src, sendDelayReqTimeout, p, null);
    _ = c.g_source_attach(src, main_context);
    return true;
}

fn rounding(x: i64) i64 {
    return @divTrunc(x +% 32768, 65536);
}

fn adjust(k: [*c]c.GstClock, t: u64, i: u64, e: u64, n: u64, dd: u64) u64 {
    return c.gst_clock_adjust_with_calibration(k, t, i, e, n, dd);
}

fn diff(a: u64, b: u64) i64 {
    return @as(i64, @bitCast(b)) -% @as(i64, @bitCast(a));
}

fn pathDelay(p: *Pending) u64 {
    const sum = p.delay_req_recv_remote -% p.sync_send_remote +% p.sync_recv_local -% p.delay_req_send_local;
    return (sum -% @as(u64, @bitCast(rounding(p.correction_sync +% p.correction_delay)))) / 2;
}

fn updateTime(d: *Domain, p: *Pending) void {
    var it: u64 = 0;
    var et: u64 = 0;
    var rn: u64 = 0;
    var rd: u64 = 0;
    var r2: f64 = 0;
    var synced = false;
    var discont: i64 = 0;
    var estimated: u64 = NONE;
    if (p.delay_req_send_local == NONE) return;
    const mpd = pathDelay(p);
    const ptp = p.sync_send_remote +% @as(u64, @bitCast(rounding(p.correction_sync)));
    const local = p.sync_recv_local -% mpd;
    out: {
        if (p.follow_up_recv_local != NONE and p.follow_up_recv_local > p.sync_recv_local +% @max(100 * MS, 20 *% d.mean_path_delay)) {
            const delay = diff(p.sync_recv_local, p.follow_up_recv_local);
            _ = delay;
            log(c.GST_LEVEL_WARNING, "update_ptp_time", 1239, "Sync-follow-up delay for domain %u too big", .{d.domain});
            synced = false;
            c.gst_clock_get_calibration(d.clock, &it, &et, &rn, &rd);
            break :out;
        }
        if (d.last_ptp_time == 0) c.gst_clock_set_calibration(d.clock, local, ptp, 1, 1);
        var oi: u64 = 0;
        var oe: u64 = 0;
        var on: u64 = 0;
        var od: u64 = 0;
        c.gst_clock_get_calibration(d.clock, &oi, &oe, &on, &od);
        it = oi;
        et = oe;
        rn = on;
        rd = od;
        const maxd = d.mean_path_delay *% 3 / 2;
        var lo = adjust(d.clock, local -% maxd, it, et, rn, rd);
        var hi = adjust(d.clock, local +% maxd, it, et, rn, rd);
        synced = lo < ptp and ptp < hi;
        if (c.gst_clock_add_observation_unapplied(d.clock, local, ptp, &r2, &it, &et, &rn, &rd) != 0) {
            estimated = adjust(d.clock, local, oi, oe, on, od);
            const fresh = adjust(d.clock, local, it, et, rn, rd);
            discont = diff(estimated, fresh);
            const md: i64 = @bitCast(maxd);
            if (synced and @abs(discont) > maxd) {
                var off: i64 = 0;
                if (discont > 0) {
                    off = md -% discont;
                    if (-off > @as(i64, @bitCast(et))) {
                        et = 0;
                    } else et = @bitCast(@as(i64, @bitCast(et)) +% off);
                } else {
                    off = -(md +% discont);
                    et = @bitCast(@as(i64, @bitCast(et)) +% off);
                }
                discont +%= off;
            }
            lo = adjust(d.clock, local -% maxd, it, et, rn, rd);
            hi = adjust(d.clock, local +% maxd, it, et, rn, rd);
            const now_synced = lo < ptp and ptp < hi;
            if (synced or now_synced or d.skipped_updates > MAX_SKIPPED) {
                c.gst_clock_set_calibration(d.clock, it, et, rn, rd);
                d.skipped_updates = 0;
                d.last_ptp_time = ptp;
                d.last_local_time = local;
            } else d.skipped_updates += 1;
        } else {
            d.last_ptp_time = ptp;
            d.last_local_time = local;
        }
    }
    if (hasHooks()) {
        const ct = c.gst_clock_get_type();
        _ = ct;
        const st = c.gst_structure_new(TIME_UPDATED, "domain", c.G_TYPE_UINT, d.domain, "mean-path-delay-avg", c.G_TYPE_UINT64, d.mean_path_delay, "local-time", c.G_TYPE_UINT64, local, "ptp-time", c.G_TYPE_UINT64, ptp, "estimated-ptp-time", c.G_TYPE_UINT64, estimated, "discontinuity", c.G_TYPE_INT64, discont, "synced", c.G_TYPE_BOOLEAN, @as(c.gboolean, @intFromBool(synced)), "r-squared", c.G_TYPE_DOUBLE, r2, "internal-time", c.G_TYPE_UINT64, it, "external-time", c.G_TYPE_UINT64, et, "rate-num", c.G_TYPE_UINT64, rn, "rate-den", c.G_TYPE_UINT64, rd, "rate", c.G_TYPE_DOUBLE, @as(f64, @floatFromInt(rn)) / @as(f64, @floatFromInt(rd)), @as(?*anyopaque, null));
        emit(d.domain, st);
        c.gst_structure_free(st);
    }
}

fn compareTime(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    const x: *const u64 = @ptrCast(@alignCast(a));
    const y: *const u64 = @ptrCast(@alignCast(b));
    return if (x.* < y.*) -1 else if (x.* > y.*) 1 else 0;
}

fn updatePathDelay(d: *Domain, p: *Pending) bool {
    const mpd = pathDelay(p);
    var delay: u64 = 0;
    var ret = false;
    done: {
        for (1..WINDOW) |i| d.last_path_delays[i - 1] = d.last_path_delays[i];
        d.last_path_delays[WINDOW - 1] = mpd;
        if (d.last_path_delays_missing != 0) {
            d.last_path_delays_missing -= 1;
        } else {
            var sorted = d.last_path_delays;
            c.g_sort_array(&sorted, WINDOW, @sizeOf(u64), compareTime, null);
            if (mpd > 2 *% sorted[WINDOW / 2]) {
                log(c.GST_LEVEL_WARNING, "update_mean_path_delay", 1474, "Path delay for domain %u too big compared to median", .{d.domain});
                break :done;
            }
        }
        if (d.mean_path_delay == 0) {
            d.mean_path_delay = mpd;
        } else if (mpd < d.mean_path_delay) {
            d.mean_path_delay = (3 *% d.mean_path_delay +% mpd) / 4;
        } else d.mean_path_delay = (15 *% d.mean_path_delay +% mpd) / 16;
        if (p.follow_up_recv_local != NONE and d.mean_path_delay != 0 and p.follow_up_recv_local > p.sync_recv_local +% @max(100 * MS, 20 *% d.mean_path_delay)) break :done;
        if (mpd > 2 *% d.mean_path_delay) break :done;
        delay = p.delay_resp_recv_local -% p.delay_req_send_local;
        if (delay > @max(100 * MS, 20 *% d.mean_path_delay)) break :done;
        ret = true;
    }
    if (hasHooks()) {
        const tt = c.G_TYPE_UINT64;
        const st = c.gst_structure_new(PATH_DELAY, "domain", c.G_TYPE_UINT, d.domain, "mean-path-delay-avg", tt, d.mean_path_delay, "mean-path-delay", tt, mpd, "delay-request-delay", tt, delay, @as(?*anyopaque, null));
        emit(d.domain, st);
        c.gst_structure_free(st);
    }
    return ret;
}

fn resetTimeout(d: *Domain, sync: bool) void {
    if (findSender(d, d.master, d.iface)) |s| {
        if (sync) s.timed_out_sync = 0 else s.timed_out_delay_resp = 0;
    }
}

fn wrongMaster(d: *Domain, msg: *Message, iface: u8) bool {
    return d.have_master and (Id.cmp(d.master, msg.source) != 0 or d.iface != iface);
}

fn handleSync(msg: *Message, iface: u8, recv: u64) void {
    if (msg.flags & 0x0100 != 0) return;
    const d = findDomain(msg.domain) orelse newDomain(msg.domain);
    if (wrongMaster(d, msg, iface)) return;
    if (!d.have_master) {
        d.master = msg.source;
        d.iface = iface;
    }
    if (msg.interval == 0x7f) {
        d.sync_interval = SECOND;
        warnHybrid();
    } else d.sync_interval = log2Time(msg.interval);
    var l = d.pending.head;
    while (l != null) : (l = l.*.next) {
        const p: *Pending = @ptrCast(@alignCast(l.*.data));
        if (p.sync_seqnum == msg.seq) return;
    }
    if (msg.stamp_seconds > NONE / SECOND) return;
    const p = A.create(Pending) catch unreachable;
    p.* = .{ .domain = d.domain, .sync_seqnum = msg.seq, .sync_recv_local = recv, .correction_sync = msg.correction };
    if (msg.flags & 0x0200 == 0) {
        p.sync_send_remote = msg.stamp;
        if (d.last_sync_time != 0 and d.last_sync_time >= p.sync_send_remote) {
            freePending(p);
            return;
        }
        d.last_sync_time = p.sync_send_remote;
        d.last_sync_time_local = recv;
        resetTimeout(d, true);
        if (!sendDelayReq(d, p)) {
            updateTime(d, p);
            freePending(p);
            return;
        }
    }
    c.g_queue_push_tail(&d.pending, p);
}

fn handleFollowUp(msg: *Message, iface: u8, recv: u64) void {
    if (msg.flags & 0x0100 != 0) return;
    const d = findDomain(msg.domain) orelse return;
    if (wrongMaster(d, msg, iface)) return;
    var p: ?*Pending = null;
    var l = d.pending.head;
    while (l != null) : (l = l.*.next) {
        const t: *Pending = @ptrCast(@alignCast(l.*.data));
        if (t.sync_seqnum == msg.seq) {
            p = t;
            break;
        }
    }
    const s = p orelse return;
    if (s.sync_send_remote != NONE) return;
    if (s.sync_recv_local >= recv) {
        _ = c.g_queue_remove(&d.pending, s);
        freePending(s);
        return;
    }
    s.correction_sync +%= msg.correction;
    s.sync_send_remote = msg.stamp;
    s.follow_up_recv_local = recv;
    if (d.last_sync_time >= s.sync_send_remote) {
        _ = c.g_queue_remove(&d.pending, s);
        freePending(s);
        return;
    }
    d.last_sync_time = s.sync_send_remote;
    d.last_sync_time_local = recv;
    resetTimeout(d, true);
    if (!sendDelayReq(d, s)) {
        updateTime(d, s);
        _ = c.g_queue_remove(&d.pending, s);
        freePending(s);
    }
}

fn handleDelayResp(msg: *Message, iface: u8, recv: u64) void {
    if (msg.requester.clock != clock_id.clock or msg.requester.port != clock_id.port) return;
    if (msg.flags & 0x0100 != 0) return;
    const d = findDomain(msg.domain) orelse return;
    if (wrongMaster(d, msg, iface)) return;
    if (msg.interval == 0x7f) {
        d.min_delay_req_interval = SECOND;
        warnHybrid();
    } else d.min_delay_req_interval = log2Time(msg.interval);
    var p: ?*Pending = null;
    var l = d.pending.head;
    while (l != null) : (l = l.*.next) {
        const t: *Pending = @ptrCast(@alignCast(l.*.data));
        if (t.delay_req_seqnum == msg.seq) {
            p = t;
            break;
        }
    }
    const s = p orelse return;
    if (s.delay_req_recv_remote != NONE) return;
    if (s.delay_req_send_local > recv) {
        _ = c.g_queue_remove(&d.pending, s);
        freePending(s);
        return;
    }
    s.correction_delay = msg.correction;
    s.delay_req_recv_remote = msg.stamp;
    s.delay_resp_recv_local = recv;
    if (d.mean_path_delay != 0 and s.sync_send_remote > s.delay_req_recv_remote) {
        _ = c.g_queue_remove(&d.pending, s);
        freePending(s);
        return;
    }
    d.last_delay_resp_local = recv;
    resetTimeout(d, false);
    if (updatePathDelay(d, s)) updateTime(d, s);
    _ = c.g_queue_remove(&d.pending, s);
    freePending(s);
}

fn handleMessage(msg: *Message, iface: u8, recv: u64) void {
    if (msg.source.clock == clock_id.clock and msg.source.port == clock_id.port) return;
    switch (msg.kind) {
        ANNOUNCE => handleAnnounce(msg, iface, recv),
        SYNC => handleSync(msg, iface, recv),
        FOLLOW_UP => handleFollowUp(msg, iface, recv),
        DELAY_RESP => handleDelayResp(msg, iface, recv),
        else => {},
    }
}

fn handleAck(data: []const u8, recv: u64) void {
    _ = recv;
    const sent = std.mem.readInt(u64, data[0..8], .big);
    const kind = data[8];
    const dn = data[9];
    const seq = std.mem.readInt(u16, data[10..12], .big);
    if (kind != DELAY_REQ) return;
    const d = findDomain(dn) orelse return;
    var l = d.pending.head;
    while (l != null) : (l = l.*.next) {
        const p: *Pending = @ptrCast(@alignCast(l.*.data));
        if (p.delay_req_seqnum == seq) {
            if (p.delay_req_recv_remote != NONE) return;
            if (sent != 0) p.delay_req_send_local = sent;
            return;
        }
    }
}

fn headerSize() u16 {
    return std.mem.readInt(u16, stdio_header[0..2], .big);
}

fn readError(err: [*c]c.GError, comptime what: [:0]const u8, comptime func: [:0]const u8, line: c_int) void {
    if (c.g_error_matches(err, c.g_io_error_quark(), c.G_IO_ERROR_CLOSED) != 0 or c.g_error_matches(err, c.g_io_error_quark(), c.G_IO_ERROR_CONNECTION_CLOSED) != 0) {
        log(c.GST_LEVEL_ERROR, func, line, "Got EOF on " ++ what, .{});
    } else log(c.GST_LEVEL_ERROR, func, line + 2, "Failed to read header from " ++ what ++ ": %s", .{err.*.message});
}

fn readStdoutHeader() void {
    stdio_header = .{ 0, 0, 0 };
    c.g_input_stream_read_all_async(stdout_pipe, &stdio_header, 3, c.G_PRIORITY_DEFAULT, null, haveStdoutHeader, null);
}

fn haveStdoutBody(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    var err: [*c]c.GError = null;
    var got: usize = 0;
    const F = "have_stdout_body";
    if (c.g_input_stream_read_all_finish(@ptrCast(src), res, &got, &err) == 0) {
        readError(err, "stdout", F, 2074);
        c.g_clear_error(&err);
        c.g_main_loop_quit(main_loop);
        return;
    } else if (got == 0) {
        log(c.GST_LEVEL_ERROR, F, 2082, "Got EOF on stdin", .{});
        c.g_main_loop_quit(main_loop);
        return;
    } else if (got != headerSize()) {
        log(c.GST_LEVEL_ERROR, F, 2086, "Unexpected read size: %lu", .{got});
        c.g_main_loop_quit(main_loop);
        return;
    }
    const size = headerSize();
    switch (stdio_header[2]) {
        TYPE_EVENT, TYPE_GENERAL => {
            var recv = c.gst_clock_get_time(observation);
            const iface = stdout_buffer[0];
            const helper_recv = std.mem.readInt(u64, stdout_buffer[1..9], .big);
            var msg = Message{};
            const end = @min(stdout_buffer.len, 9 + @as(usize, size));
            if (parse(&msg, stdout_buffer[9..end])) {
                if (helper_recv != 0) recv = helper_recv;
                handleMessage(&msg, iface, recv);
            }
        },
        TYPE_CLOCK_ID => {
            if (size != 8) {
                log(c.GST_LEVEL_ERROR, F, 2119, "Unexpected clock id size (%u != 8)", .{@as(c.guint, size)});
                c.g_main_loop_quit(main_loop);
                return;
            }
            c.g_mutex_lock(&ptp_lock);
            clock_id.clock = std.mem.readInt(u64, stdout_buffer[0..8], .big);
            clock_id.port = @truncate(@as(u32, @bitCast(c.getpid())));
            c.g_cond_signal(&ptp_cond);
            c.g_mutex_unlock(&ptp_lock);
        },
        TYPE_SEND_TIME_ACK => {
            const recv = c.gst_clock_get_time(observation);
            if (size != 12) {
                log(c.GST_LEVEL_ERROR, F, 2140, "Unexpected send time ack size (%u != 12)", .{@as(c.guint, size)});
                c.g_main_loop_quit(main_loop);
                return;
            }
            handleAck(stdout_buffer[0..12], recv);
        },
        else => {},
    }
    readStdoutHeader();
}

fn haveStdoutHeader(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    var err: [*c]c.GError = null;
    var got: usize = 0;
    const F = "have_stdout_header";
    if (c.g_input_stream_read_all_finish(@ptrCast(src), res, &got, &err) == 0) {
        readError(err, "stdout", F, 2171);
        c.g_clear_error(&err);
        c.g_main_loop_quit(main_loop);
        return;
    } else if (got == 0) {
        log(c.GST_LEVEL_ERROR, F, 2179, "Got EOF on stdin", .{});
        return;
    } else if (got != 3) {
        log(c.GST_LEVEL_ERROR, F, 2182, "Unexpected read size: %lu", .{got});
        c.g_main_loop_quit(main_loop);
        return;
    } else if (headerSize() > 8192) {
        log(c.GST_LEVEL_ERROR, F, 2186, "Unexpected size: %u", .{@as(c.guint, headerSize())});
        c.g_main_loop_quit(main_loop);
        return;
    }
    c.g_input_stream_read_all_async(stdout_pipe, &stdout_buffer, headerSize(), c.G_PRIORITY_DEFAULT, null, haveStdoutBody, null);
}

fn stderrSize() u16 {
    return std.mem.readInt(u16, stderr_header[0..2], .big);
}

fn readStderrHeader() void {
    stderr_header = .{ 0, 0 };
    c.g_input_stream_read_all_async(stderr_pipe, &stderr_header, 2, c.G_PRIORITY_DEFAULT, null, haveStderrHeader, null);
}

fn haveStderrBody(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    var err: [*c]c.GError = null;
    var got: usize = 0;
    const F = "have_stderr_body";
    if (c.g_input_stream_read_all_finish(@ptrCast(src), res, &got, &err) == 0) {
        readError(err, "stderr", F, 2223);
        c.g_clear_error(&err);
        c.g_main_loop_quit(main_loop);
        return;
    } else if (got == 0) {
        log(c.GST_LEVEL_ERROR, F, 2231, "Got EOF on stderr", .{});
        c.g_main_loop_quit(main_loop);
        return;
    } else if (got != stderrSize()) {
        log(c.GST_LEVEL_ERROR, F, 2235, "Unexpected read size: %lu", .{got});
        c.g_main_loop_quit(main_loop);
        return;
    }
    var r = Reader{ .data = stderr_buffer[0..stderrSize()] };
    bad: {
        if (r.remaining() < 1) break :bad;
        const level = r.u8_();
        if (level > c.GST_LEVEL_MAX) break :bad;
        if (r.remaining() < 2) break :bad;
        const fl = r.u16_();
        if (fl > r.remaining()) break :bad;
        const file = c.g_strndup(@ptrCast(r.data[r.pos..].ptr), fl);
        r.skip(fl);
        if (r.remaining() < 2) {
            c.g_free(file);
            break :bad;
        }
        const ml = r.u16_();
        if (ml > r.remaining()) {
            c.g_free(file);
            break :bad;
        }
        const module = c.g_strndup(@ptrCast(r.data[r.pos..].ptr), ml);
        r.skip(ml);
        if (r.remaining() < 4) {
            c.g_free(file);
            c.g_free(module);
            break :bad;
        }
        const line = r.u32_();
        const text = c.g_strndup(@ptrCast(r.data[r.pos..].ptr), r.remaining());
        c.gst_debug_log_literal(category(), level, file, module, @bitCast(line), null, text);
        c.g_free(file);
        c.g_free(module);
        c.g_free(text);
        readStderrHeader();
        return;
    }
    log(c.GST_LEVEL_ERROR, F, 2286, "Unexpected stderr data", .{});
    c.g_main_loop_quit(main_loop);
}

fn haveStderrHeader(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    var err: [*c]c.GError = null;
    var got: usize = 0;
    const F = "have_stderr_header";
    if (c.g_input_stream_read_all_finish(@ptrCast(src), res, &got, &err) == 0) {
        readError(err, "stderr", F, 2307);
        c.g_clear_error(&err);
        c.g_main_loop_quit(main_loop);
        return;
    } else if (got == 0) {
        log(c.GST_LEVEL_ERROR, F, 2315, "Got EOF on stderr", .{});
        c.g_main_loop_quit(main_loop);
        return;
    } else if (got != 2) {
        log(c.GST_LEVEL_ERROR, F, 2319, "Unexpected read size: %lu", .{got});
        c.g_main_loop_quit(main_loop);
        return;
    } else if (stderrSize() > 8192 or stderrSize() < 9) {
        log(c.GST_LEVEL_ERROR, F, 2323, "Unexpected size: %u", .{@as(c.guint, stderrSize())});
        c.g_main_loop_quit(main_loop);
        return;
    }
    c.g_input_stream_read_all_async(stderr_pipe, &stderr_buffer, stderrSize(), c.G_PRIORITY_DEFAULT, null, haveStderrBody, null);
}

fn cleanup(_: c.gpointer) callconv(.c) c.gboolean {
    const now = c.gst_clock_get_time(observation);
    var l = domains;
    while (l != null) : (l = l.*.next) {
        const d: *Domain = @ptrCast(@alignCast(l.*.data));
        var n = d.senders;
        while (n != null) {
            const s: *Sender = @ptrCast(@alignCast(n.*.data));
            while (c.g_queue_get_length(&s.messages) > 5) A.destroy(@as(*Announce, @ptrCast(@alignCast(c.g_queue_pop_head(&s.messages)))));
            var timed_out = true;
            var m = s.messages.head;
            while (m != null) : (m = m.*.next) {
                const a: *Announce = @ptrCast(@alignCast(m.*.data));
                if (a.receive_time +% s.interval *% RECEIPT_TIMEOUT > now) {
                    timed_out = false;
                    break;
                }
            }
            if (timed_out) {
                c.g_queue_foreach(&s.messages, freeAnnounceCb, null);
                c.g_queue_clear(&s.messages);
            }
            if (c.g_queue_get_length(&s.messages) == 0) {
                const next = n.*.next;
                if (Id.cmp(s.master, d.master) == 0 and s.iface == d.iface) log(c.GST_LEVEL_WARNING, "cleanup_cb", 2380, "currently selected master clock timed out", .{});
                A.destroy(s);
                d.senders = c.g_list_delete_link(d.senders, n);
                n = next;
            } else n = n.*.next;
        }
        n = d.pending.head;
        while (n != null) {
            const p: *Pending = @ptrCast(@alignCast(n.*.data));
            var timed_out = false;
            var to_sync = false;
            var to_resp = false;
            if (p.delay_req_send_local != NONE and ((d.min_delay_req_interval != 0 and p.delay_req_send_local +% 4 *% d.min_delay_req_interval < now) or p.delay_req_send_local +% 10 * SECOND < now)) {
                timed_out = true;
                if (d.last_delay_resp_local < p.delay_req_send_local) to_resp = true;
            } else if (p.follow_up_recv_local == NONE and ((d.sync_interval != 0 and p.sync_recv_local +% 4 *% d.sync_interval < now) or p.sync_recv_local +% 10 * SECOND < now)) {
                timed_out = true;
                if (d.last_sync_time_local < p.sync_recv_local) to_sync = true;
            }
            if (d.have_master and (to_sync or to_resp)) {
                if (findSender(d, d.master, d.iface)) |s| {
                    if (to_sync) s.timed_out_sync += 1;
                    if (to_resp) s.timed_out_delay_resp += 1;
                }
            }
            if (timed_out) {
                const next = n.*.next;
                freePending(p);
                c.g_queue_delete_link(&d.pending, n);
                n = next;
            } else n = n.*.next;
        }
        selectBest(d, now);
    }
    return 1;
}

fn helperMain(_: c.gpointer) callconv(.c) c.gpointer {
    c.g_main_context_push_thread_default(main_context);
    readStdoutHeader();
    readStderrHeader();
    const src = c.g_timeout_source_new_seconds(1);
    c.g_source_set_priority(src, c.G_PRIORITY_DEFAULT);
    c.g_source_set_callback(src, cleanup, null, null);
    _ = c.g_source_attach(src, main_context);
    c.g_source_unref(src);
    c.g_main_loop_run(main_loop);
    c.g_main_context_pop_thread_default(main_context);
    c.g_mutex_lock(&ptp_lock);
    clock_id = .{ .clock = ID_NONE, .port = 0 };
    initted = false;
    c.g_cond_signal(&ptp_cond);
    c.g_mutex_unlock(&ptp_lock);
    return null;
}

pub export fn gst_ptp_is_supported() c.gboolean {
    return @intFromBool(supported);
}

pub export fn gst_ptp_is_initialized() c.gboolean {
    return @intFromBool(initted);
}

fn countDirs(path: []const u8) usize {
    var n: isize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) {
            n -= 1;
        } else if (!std.mem.eql(u8, seg, ".")) n += 1;
    }
    return if (n < 0) 0 else @intCast(n);
}

fn helperPath() [*c]u8 {
    var info: c.Dl_info = undefined;
    if (c.dladdr(@ptrCast(&gst_ptp_init), &info) == 0 or info.dli_fname == null) return c.g_strdup(config.ptp_helper.ptr);
    var real: [4096]u8 = undefined;
    const dir = if (c.realpath(info.dli_fname, &real) != null) c.g_path_get_dirname(&real) else c.g_path_get_dirname(info.dli_fname);
    defer c.g_free(dir);
    const depth = countDirs(config.plugin_subdir);
    if (depth >= 64) return c.g_strdup(config.ptp_helper.ptr);
    var parts: [70][*c]const u8 = undefined;
    var i: usize = 0;
    parts[i] = dir;
    i += 1;
    for (0..depth) |_| {
        parts[i] = "..";
        i += 1;
    }
    parts[i] = config.helper_subdir.ptr;
    parts[i + 1] = "gstreamer-1.0";
    parts[i + 2] = "gst-ptp-helper";
    parts[i + 3] = null;
    return c.g_build_filenamev(@ptrCast(@constCast(&parts)));
}

fn initHooks() void {
    if (!hooks_initted) {
        c.g_hook_list_init(hooks, @sizeOf(c.GHook));
        hooks_initted = true;
    }
}

fn teardown() void {
    if (helper != null) {
        c.g_clear_object(@ptrCast(&stdin_pipe));
        c.g_clear_object(@ptrCast(&stdout_pipe));
        c.g_clear_object(@ptrCast(&stderr_pipe));
        c.g_subprocess_force_exit(helper);
        c.g_clear_object(@ptrCast(&helper));
    }
    if (main_loop != null and helper_thread != null) {
        c.g_main_loop_quit(main_loop);
        _ = c.g_thread_join(helper_thread);
    }
    helper_thread = null;
    if (main_loop) |m| c.g_main_loop_unref(m);
    main_loop = null;
    if (main_context) |m| c.g_main_context_unref(m);
    main_context = null;
    if (delay_rand) |r| c.g_rand_free(r);
    delay_rand = null;
    if (observation != null) c.gst_object_unref(observation);
    observation = null;
}

pub export fn gst_ptp_init_full(cfg: ?*const c.GstStructure) c.gboolean {
    _ = category();
    c.g_mutex_lock(&ptp_lock);
    var ret = false;
    var argv: [*c][*c]u8 = null;
    defer {
        c.g_strfreev(argv);
        if (!ret) teardown();
        c.g_mutex_unlock(&ptp_lock);
    }
    if (!supported) {
        log(c.GST_LEVEL_ERROR, "gst_ptp_init_full", 2739, "PTP not supported", .{});
        return 0;
    }
    if (initted) {
        ret = true;
        return 1;
    }
    if (helper == null) {
        initHooks();
        var cid: u64 = ID_NONE;
        _ = c.gst_structure_get_uint64(cfg, "clock-id", &cid);
        var ifaces: [*c][*c]u8 = null;
        const v = c.gst_structure_get_value(cfg, "interfaces");
        if (v != null and c.g_type_check_value_holds(v, c.g_strv_get_type()) != 0) ifaces = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
        var ttl: c.guint = 1;
        _ = c.gst_structure_get_uint(cfg, "ttl", &ttl);
        var argc: usize = 3;
        if (cid != ID_NONE) argc += 2;
        if (ifaces != null) argc += 2 * c.g_strv_length(ifaces);
        argv = @ptrCast(@alignCast(c.g_malloc0((argc + 3) * @sizeOf([*c]u8))));
        var n: usize = 0;
        var env = c.g_getenv("GST_PTP_HELPER_1_0");
        if (env == null) env = c.g_getenv("GST_PTP_HELPER");
        if (env != null and env[0] != 0) {
            argv[n] = c.g_strdup(env);
        } else argv[n] = helperPath();
        n += 1;
        if (cid != ID_NONE) {
            argv[n] = c.g_strdup("-c");
            argv[n + 1] = c.g_strdup_printf("0x%016lx", cid);
            n += 2;
        }
        if (ifaces != null) {
            var p = ifaces;
            while (p.* != null) : (p += 1) {
                argv[n] = c.g_strdup("-i");
                argv[n + 1] = c.g_strdup(p.*);
                n += 2;
            }
        }
        argv[n] = c.g_strdup("--ttl");
        argv[n + 1] = c.g_strdup_printf("%u", ttl);
        n += 2;
        const verbose = c.g_getenv("GST_PTP_HELPER_VERBOSE");
        if (verbose != null and c.g_ascii_strcasecmp(verbose, "no") != 0) argv[n] = c.g_strdup("-v");
        var err: [*c]c.GError = null;
        helper = c.g_subprocess_newv(@ptrCast(argv), c.G_SUBPROCESS_FLAGS_STDIN_PIPE | c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_PIPE, &err);
        if (helper == null) {
            log(c.GST_LEVEL_ERROR, "gst_ptp_init_full", 2866, "Failed to start ptp helper process: %s", .{err.*.message});
            c.g_clear_error(&err);
            supported = false;
            return 0;
        }
        stdin_pipe = c.g_subprocess_get_stdin_pipe(helper);
        if (stdin_pipe != null) _ = c.g_object_ref(stdin_pipe);
        stdout_pipe = c.g_subprocess_get_stdout_pipe(helper);
        if (stdout_pipe != null) _ = c.g_object_ref(stdout_pipe);
        stderr_pipe = c.g_subprocess_get_stderr_pipe(helper);
        if (stderr_pipe != null) _ = c.g_object_ref(stderr_pipe);
        if (stdin_pipe == null or stdout_pipe == null or stderr_pipe == null) {
            log(c.GST_LEVEL_ERROR, "gst_ptp_init_full", 2883, "Failed to get ptp helper process pipes", .{});
            supported = false;
            return 0;
        }
        delay_rand = c.g_rand_new();
        observation = @ptrCast(@alignCast(c.g_object_new(c.gst_system_clock_get_type(), "name", "ptp-observation-clock", @as(?*anyopaque, null))));
        _ = c.gst_object_ref_sink(observation);
        main_context = c.g_main_context_new();
        main_loop = c.g_main_loop_new(main_context, 0);
        helper_thread = c.g_thread_try_new("ptp-helper-thread", helperMain, null, &err);
        if (helper_thread == null) {
            log(c.GST_LEVEL_ERROR, "gst_ptp_init_full", 2901, "Failed to start PTP helper thread: %s", .{err.*.message});
            c.g_clear_error(&err);
            return 0;
        }
        initted = true;
    }
    while (clock_id.clock == ID_NONE and initted) c.g_cond_wait(&ptp_cond, &ptp_lock);
    ret = initted;
    if (!ret) {
        log(c.GST_LEVEL_ERROR, "gst_ptp_init_full", 2920, "Failed to initialize", .{});
        supported = false;
    }
    return @intFromBool(ret);
}

pub export fn gst_ptp_init(cid: c.guint64, ifaces: [*c][*c]c.gchar) c.gboolean {
    const cfg = c.gst_structure_new("config/ptp", "clock-id", c.G_TYPE_UINT64, cid, "interfaces", c.g_strv_get_type(), ifaces, @as(?*anyopaque, null));
    const r = gst_ptp_init_full(cfg);
    c.gst_structure_free(cfg);
    return r;
}

pub export fn gst_ptp_deinit() void {
    c.g_mutex_lock(&ptp_lock);
    if (helper != null) {
        c.g_clear_object(@ptrCast(&stdin_pipe));
        c.g_clear_object(@ptrCast(&stdout_pipe));
        c.g_clear_object(@ptrCast(&stderr_pipe));
        c.g_subprocess_force_exit(helper);
        c.g_clear_object(@ptrCast(&helper));
    }
    if (main_loop != null and helper_thread != null) {
        const t = helper_thread;
        helper_thread = null;
        c.g_mutex_unlock(&ptp_lock);
        c.g_main_loop_quit(main_loop);
        _ = c.g_thread_join(t);
        c.g_mutex_lock(&ptp_lock);
    }
    if (main_loop) |m| c.g_main_loop_unref(m);
    main_loop = null;
    if (main_context) |m| c.g_main_context_unref(m);
    main_context = null;
    if (delay_rand) |r| c.g_rand_free(r);
    delay_rand = null;
    if (observation != null) c.gst_object_unref(observation);
    observation = null;
    var l = domains;
    while (l != null) : (l = l.*.next) {
        const d: *Domain = @ptrCast(@alignCast(l.*.data));
        var m = d.senders;
        while (m != null) : (m = m.*.next) {
            const s: *Sender = @ptrCast(@alignCast(m.*.data));
            c.g_queue_foreach(&s.messages, freeAnnounceCb, null);
            c.g_queue_clear(&s.messages);
            A.destroy(s);
        }
        c.g_list_free(d.senders);
        c.g_queue_foreach(&d.pending, freePendingCb, null);
        c.g_queue_clear(&d.pending);
        c.gst_object_unref(d.clock);
        A.destroy(d);
    }
    c.g_list_free(domains);
    domains = null;
    c.g_list_free(domain_clocks);
    domain_clocks = null;
    clock_id = .{ .clock = ID_NONE, .port = 0 };
    initted = false;
    c.g_mutex_unlock(&ptp_lock);
}

pub export fn gst_ptp_statistics_callback_add(cb: c.GstPtpStatisticsCallback, data: c.gpointer, destroy: c.GDestroyNotify) c.gulong {
    c.g_mutex_lock(&ptp_lock);
    initHooks();
    const hook = c.g_hook_alloc(hooks);
    hook.*.func = @ptrCast(@constCast(cb));
    hook.*.data = data;
    hook.*.destroy = destroy;
    c.g_hook_prepend(hooks, hook);
    _ = @atomicRmw(c.gint, &n_hooks, .Add, 1, .seq_cst);
    c.g_mutex_unlock(&ptp_lock);
    return hook.*.hook_id;
}

pub export fn gst_ptp_statistics_callback_remove(id: c.gulong) void {
    c.g_mutex_lock(&ptp_lock);
    if (c.g_hook_destroy(hooks, id) != 0) _ = @atomicRmw(c.gint, &n_hooks, .Add, -1, .seq_cst);
    c.g_mutex_unlock(&ptp_lock);
}

const Clock = c.GstPtpClock;

const Priv = extern struct {
    domain: c.guint,
    domain_clock: [*c]c.GstClock,
    domain_stats_id: c.gulong,
};

var clock_once: gtype.Once = .{};
var clock_offset: c.gint = 0;
var clock_parent: ?*c.GObjectClass = null;

fn priv(s: anytype) *Priv {
    const p: [*]u8 = @ptrCast(s);
    return @ptrCast(@alignCast(p + @as(usize, @bitCast(@as(isize, clock_offset)))));
}

fn ensureDomainClock(s: *Clock) bool {
    const p = priv(s);
    var got = true;
    if (p.domain_clock == null) {
        c.g_mutex_lock(&domain_clocks_lock);
        if (p.domain_clock == null) {
            got = false;
            var l = domain_clocks;
            while (l != null) : (l = l.*.next) {
                const d: *Domain = @ptrCast(@alignCast(l.*.data));
                if (d.domain == p.domain and d.have_master and d.last_ptp_time != 0) {
                    p.domain_clock = d.clock;
                    got = true;
                    break;
                }
            }
        }
        c.g_mutex_unlock(&domain_clocks_lock);
        if (got) {
            c.g_object_notify(@ptrCast(s), "internal-clock");
            _ = c.gst_clock_set_synced(@ptrCast(s), 1);
        }
    }
    return got;
}

fn statsCb(domain: u8, stats: ?*const c.GstStructure, data: c.gpointer) callconv(.c) c.gboolean {
    const s: *Clock = @ptrCast(@alignCast(data));
    const p = priv(s);
    if (domain != p.domain or c.gst_structure_has_name(stats, TIME_UPDATED) == 0) return 1;
    if (!ensureDomainClock(s)) return 1;
    p.domain_stats_id = 0;
    return 0;
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log(basic.DOMAIN, c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", FILE, line, "property", id, spec.*.name, c.g_type_name(spec.*.g_type_instance.g_class.*.g_type), c.g_type_name(o.*.g_type_instance.g_class.*.g_type));
}

fn clockSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Clock = @ptrCast(@alignCast(o));
    const p = priv(s);
    if (id == 1) {
        p.domain = c.g_value_get_uint(v);
        _ = ensureDomainClock(s);
        if (p.domain_clock == null) p.domain_stats_id = gst_ptp_statistics_callback_add(statsCb, s, null);
    } else warnInvalid(o, id, spec, 3223);
}

fn clockGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Clock = @ptrCast(@alignCast(o));
    const p = priv(s);
    switch (id) {
        1 => c.g_value_set_uint(v, p.domain),
        2 => {
            _ = ensureDomainClock(s);
            c.g_value_set_object(v, p.domain_clock);
        },
        3, 4 => {
            c.g_mutex_lock(&domain_clocks_lock);
            c.g_value_set_uint64(v, 0);
            var l = domain_clocks;
            while (l != null) : (l = l.*.next) {
                const d: *Domain = @ptrCast(@alignCast(l.*.data));
                if (d.domain == p.domain) {
                    c.g_value_set_uint64(v, if (id == 3) d.master.clock else d.grandmaster);
                    break;
                }
            }
            c.g_mutex_unlock(&domain_clocks_lock);
        },
        else => warnInvalid(o, id, spec, 3265),
    }
}

fn clockFinalize(o: [*c]c.GObject) callconv(.c) void {
    const p = priv(o);
    if (p.domain_stats_id != 0) gst_ptp_statistics_callback_remove(p.domain_stats_id);
    clock_parent.?.finalize.?(o);
}

fn clockInternalTime(k: [*c]c.GstClock) callconv(.c) c.GstClockTime {
    const s: *Clock = @ptrCast(@alignCast(k));
    _ = ensureDomainClock(s);
    const p = priv(s);
    if (p.domain_clock == null) {
        @call(.auto, c.gst_debug_log, .{ category(), @as(c.GstDebugLevel, c.GST_LEVEL_ERROR), FILE, "gst_ptp_clock_get_internal_time", @as(c_int, 3289), @as([*c]c.GObject, @ptrCast(@alignCast(s))), "Domain %u has no clock yet and is not synced", p.domain });
        return NONE;
    }
    return c.gst_clock_get_time(p.domain_clock);
}

fn clockInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *Clock = @ptrCast(@alignCast(inst));
    s.priv = @ptrCast(priv(s));
    const o: *c.GstObject = @ptrCast(s);
    o.flags |= c.GST_CLOCK_FLAG_CAN_SET_MASTER | c.GST_CLOCK_FLAG_NEEDS_STARTUP_SYNC;
    priv(s).domain = 0;
}

fn clockClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    clock_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    c.g_type_class_adjust_private_offset(k, &clock_offset);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = clockFinalize;
    gc.get_property = clockGet;
    gc.set_property = clockSet;
    const ss = c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_uint("domain", "Domain", "The PTP domain", 0, 255, 0, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | ss));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_object("internal-clock", "Internal Clock", "Internal clock", c.gst_clock_get_type(), c.G_PARAM_READABLE | ss));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_uint64("master-clock-id", "Master Clock ID", "Master Clock ID", 0, std.math.maxInt(u64), 0, c.G_PARAM_READABLE | ss));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_uint64("grandmaster-clock-id", "Grand Master Clock ID", "Grand Master Clock ID", 0, std.math.maxInt(u64), 0, c.G_PARAM_READABLE | ss));
    const cc: *c.GstClockClass = @ptrCast(@alignCast(k));
    cc.get_internal_time = clockInternalTime;
}

pub export fn gst_ptp_clock_get_type() c.GType {
    return clock_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_system_clock_get_type, "GstPtpClock", c.GstPtpClockClass, Clock, clockClassInit, clockInit, 0);
            clock_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            return t;
        }
    }.f);
}

pub export fn gst_ptp_clock_new(name: [*c]const u8, domain: c.guint) [*c]c.GstClock {
    if (!basic.that(domain <= 255, "gst_ptp_clock_new", "domain <= G_MAXUINT8")) return null;
    if (!initted and gst_ptp_init(ID_NONE, null) == 0) {
        log(c.GST_LEVEL_ERROR, "gst_ptp_clock_new", 3326, "Failed to initialize PTP", .{});
        return null;
    }
    const k = c.g_object_new(gst_ptp_clock_get_type(), "name", name, "domain", domain, @as(?*anyopaque, null));
    _ = c.gst_object_ref_sink(k);
    return @ptrCast(@alignCast(k));
}
