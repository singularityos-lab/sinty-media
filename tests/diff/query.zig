const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const end: ?*anyopaque = null;

fn show(label: []const u8, q: [*c]c.GstQuery) void {
    if (q == null) {
        out("{s}: (null)", .{label});
        return;
    }
    const s = c.gst_query_get_structure(q);
    const ss = if (s != null) c.gst_structure_to_string(s) else null;
    out("{s}: type {s} quark {s} flags {d} struct {s}", .{ label, str(c.gst_query_type_get_name(q.*.type)), str(c.g_quark_to_string(c.gst_query_type_to_quark(q.*.type))), c.gst_query_type_get_flags(q.*.type), str(ss) });
    c.g_free(ss);
}

pub fn main() void {
    c.gst_init(null, null);
    const cat = c._gst_debug_get_category("query");
    out("cat {s} {s}", .{ str(c.gst_debug_category_get_name(cat)), str(c.gst_debug_category_get_description(cat)) });
    var f: c.GstFormat = 0;
    var v1: i64 = 0;
    var v2: i64 = 0;
    var v3: i64 = 0;
    var b: c.gboolean = 0;
    var ua: u64 = 0;
    var ub: u64 = 0;

    const pos = c.gst_query_new_position(c.GST_FORMAT_TIME);
    show("position", pos);
    c.gst_query_set_position(pos, c.GST_FORMAT_TIME, 55);
    c.gst_query_set_position(pos, c.GST_FORMAT_BYTES, 66);
    c.gst_query_parse_position(pos, &f, &v1);
    out("  {d} {d}", .{ f, v1 });
    const dur = c.gst_query_new_duration(c.GST_FORMAT_BYTES);
    c.gst_query_set_duration(dur, c.GST_FORMAT_BYTES, 1000);
    c.gst_query_parse_duration(dur, &f, &v1);
    show("duration", dur);
    out("  {d} {d}", .{ f, v1 });
    c.gst_query_parse_duration(pos, &f, &v1);

    const lat = c.gst_query_new_latency();
    show("latency", lat);
    c.gst_query_set_latency(lat, 1, 10, 20);
    c.gst_query_set_latency(lat, 1, c.GST_CLOCK_TIME_NONE, 20);
    c.gst_query_parse_latency(lat, &b, &ua, &ub);
    out("  {d} {d} {d}", .{ b, ua, ub });

    const conv = c.gst_query_new_convert(c.GST_FORMAT_TIME, 100, c.GST_FORMAT_BYTES);
    show("convert", conv);
    c.gst_query_set_convert(conv, c.GST_FORMAT_TIME, 100, c.GST_FORMAT_BYTES, 4000);
    var f2: c.GstFormat = 0;
    c.gst_query_parse_convert(conv, &f, &v1, &f2, &v2);
    out("  {d} {d} {d} {d}", .{ f, v1, f2, v2 });

    const seg = c.gst_query_new_segment(c.GST_FORMAT_TIME);
    show("segment", seg);
    c.gst_query_set_segment(seg, 1.5, c.GST_FORMAT_TIME, 1, 9);
    var rate: f64 = 0;
    c.gst_query_parse_segment(seg, &rate, &f, &v1, &v2);
    show("segment set", seg);
    out("  {d} {d} {d} {d}", .{ rate, f, v1, v2 });

    const sk = c.gst_query_new_seeking(c.GST_FORMAT_TIME);
    c.gst_query_set_seeking(sk, c.GST_FORMAT_TIME, 1, 0, 500);
    c.gst_query_parse_seeking(sk, &f, &b, &v1, &v2);
    show("seeking", sk);
    out("  {d} {d} {d} {d}", .{ f, b, v1, v2 });

    const fm = c.gst_query_new_formats();
    var n: c_uint = 9;
    c.gst_query_parse_n_formats(fm, &n);
    c.gst_query_parse_nth_format(fm, 0, &f);
    out("formats empty {d} {d}", .{ n, f });
    c.gst_query_set_formats(fm, 3, @as(c_int, c.GST_FORMAT_TIME), @as(c_int, c.GST_FORMAT_BYTES), @as(c_int, c.GST_FORMAT_PERCENT));
    show("formats", fm);
    c.gst_query_parse_n_formats(fm, &n);
    c.gst_query_parse_nth_format(fm, 2, &f);
    var f9: c.GstFormat = 0;
    c.gst_query_parse_nth_format(fm, 9, &f9);
    out("  {d} {d} {d}", .{ n, f, f9 });
    const fv = [_]c.GstFormat{ c.GST_FORMAT_DEFAULT, c.GST_FORMAT_BUFFERS };
    c.gst_query_set_formatsv(fm, 2, &fv);
    show("formatsv", fm);

    const bq = c.gst_query_new_buffering(c.GST_FORMAT_PERCENT);
    show("buffering", bq);
    c.gst_query_set_buffering_percent(bq, 1, 50);
    c.gst_query_set_buffering_percent(bq, 1, 150);
    c.gst_query_set_buffering_stats(bq, c.GST_BUFFERING_DOWNLOAD, 1, 2, 3);
    c.gst_query_set_buffering_range(bq, c.GST_FORMAT_BYTES, 0, 100, 1000);
    var pct: c_int = 0;
    c.gst_query_parse_buffering_percent(bq, &b, &pct);
    var mode: c.GstBufferingMode = 0;
    var ai: c_int = 0;
    var ao: c_int = 0;
    c.gst_query_parse_buffering_stats(bq, &mode, &ai, &ao, &v1);
    c.gst_query_parse_buffering_range(bq, &f, &v2, &v3, &v1);
    out("  {d} {d} {d} {d} {d} {d} {d} {d}", .{ b, pct, mode, ai, ao, f, v2, v3 });
    out("  ranges n {d}", .{c.gst_query_get_n_buffering_ranges(bq)});
    out("  add {d} {d} {d} {d} {d}", .{ c.gst_query_add_buffering_range(bq, 0, 10), c.gst_query_add_buffering_range(bq, 20, 30), c.gst_query_add_buffering_range(bq, 15, 18), c.gst_query_add_buffering_range(bq, 40, 40), c.gst_query_add_buffering_range(bq, 50, 60) });
    out("  n {d} nth {d} {d} {d}", .{ c.gst_query_get_n_buffering_ranges(bq), c.gst_query_parse_nth_buffering_range(bq, 1, &v1, &v2), v1, v2 });
    out("  oob {d}", .{c.gst_query_parse_nth_buffering_range(bq, 9, &v1, &v2)});
    show("buffering after", bq);

    const uq = c.gst_query_new_uri();
    show("uri", uq);
    var uri: [*c]u8 = null;
    c.gst_query_parse_uri(uq, &uri);
    out("  {s}", .{str(uri)});
    c.gst_query_set_uri(uq, "file:///x");
    c.gst_query_parse_uri(uq, &uri);
    out("  {s}", .{str(uri)});
    c.g_free(uri);
    c.gst_query_parse_uri_redirection(uq, &uri);
    var perm: c.gboolean = 7;
    c.gst_query_parse_uri_redirection_permanent(uq, &perm);
    out("  redir {s} perm {d}", .{ str(uri), perm });
    c.gst_query_set_uri_redirection(uq, "http://y");
    c.gst_query_set_uri_redirection_permanent(uq, 1);
    c.gst_query_parse_uri_redirection(uq, &uri);
    c.gst_query_parse_uri_redirection_permanent(uq, &perm);
    out("  redir {s} perm {d}", .{ str(uri), perm });
    c.g_free(uri);
    show("uri set", uq);

    const caps = c.gst_caps_from_string("video/x-raw, width=(int)2");
    const aq = c.gst_query_new_allocation(caps, 1);
    show("allocation", aq);
    var pc: [*c]c.GstCaps = null;
    c.gst_query_parse_allocation(aq, &pc, &b);
    out("  same {d} need {d}", .{ @intFromBool(pc == caps), b });
    const pool = c.gst_buffer_pool_new();
    c.gst_query_add_allocation_pool(aq, pool, 100, 2, 4);
    c.gst_query_add_allocation_pool(aq, null, 200, 0, 0);
    var pp: [*c]c.GstBufferPool = null;
    var sz: c_uint = 0;
    var mn: c_uint = 0;
    var mx: c_uint = 0;
    c.gst_query_parse_nth_allocation_pool(aq, 0, &pp, &sz, &mn, &mx);
    out("  pools {d} p0 same {d} {d} {d} {d}", .{ c.gst_query_get_n_allocation_pools(aq), @intFromBool(pp == pool), sz, mn, mx });
    if (pp != null) c.gst_object_unref(pp);
    c.gst_query_set_nth_allocation_pool(aq, 1, pool, 300, 1, 1);
    c.gst_query_parse_nth_allocation_pool(aq, 1, &pp, &sz, &mn, &mx);
    out("  p1 {d} {d} {d} {d}", .{ @intFromBool(pp == pool), sz, mn, mx });
    if (pp != null) c.gst_object_unref(pp);
    c.gst_query_parse_nth_allocation_pool(aq, 5, &pp, &sz, &mn, &mx);
    c.gst_query_remove_nth_allocation_pool(aq, 0);
    out("  pools {d} refs {d}", .{ c.gst_query_get_n_allocation_pools(aq), @as(*c.GObject, @ptrCast(@alignCast(pool))).ref_count });
    const params = c.gst_structure_new_empty("meta-params");
    c.gst_query_add_allocation_meta(aq, c.G_TYPE_INT, params);
    c.gst_query_add_allocation_meta(aq, c.G_TYPE_STRING, null);
    c.gst_query_add_allocation_meta(aq, 0, null);
    var pparams: [*c]const c.GstStructure = null;
    var idx: c_uint = 99;
    out("  metas {d} nth1 {s} p {d} find {d} {d} miss {d}", .{ c.gst_query_get_n_allocation_metas(aq), str(c.g_type_name(c.gst_query_parse_nth_allocation_meta(aq, 0, &pparams))), @intFromBool(pparams != null), c.gst_query_find_allocation_meta(aq, c.G_TYPE_STRING, &idx), idx, c.gst_query_find_allocation_meta(aq, c.G_TYPE_DOUBLE, null) });
    c.gst_query_remove_nth_allocation_meta(aq, 0);
    out("  metas {d}", .{c.gst_query_get_n_allocation_metas(aq)});
    var ap: c.GstAllocationParams = undefined;
    c.gst_allocation_params_init(&ap);
    ap.@"align" = 15;
    ap.prefix = 4;
    c.gst_query_add_allocation_param(aq, null, &ap);
    c.gst_query_add_allocation_param(aq, null, null);
    var pa: [*c]c.GstAllocator = null;
    var pap: c.GstAllocationParams = undefined;
    c.gst_query_parse_nth_allocation_param(aq, 0, &pa, &pap);
    out("  params {d} a {d} align {d} prefix {d}", .{ c.gst_query_get_n_allocation_params(aq), @intFromBool(pa == null), pap.@"align", pap.prefix });
    c.gst_query_set_nth_allocation_param(aq, 0, null, null);
    c.gst_query_parse_nth_allocation_param(aq, 0, &pa, &pap);
    out("  align {d}", .{pap.@"align"});
    c.gst_query_remove_nth_allocation_param(aq, 1);
    out("  params {d}", .{c.gst_query_get_n_allocation_params(aq)});
    const acp = c.gst_query_copy(aq);
    out("  copy pools {d} metas {d} params {d}", .{ c.gst_query_get_n_allocation_pools(acp), c.gst_query_get_n_allocation_metas(acp), c.gst_query_get_n_allocation_params(acp) });

    const sq = c.gst_query_new_scheduling();
    show("scheduling", sq);
    c.gst_query_set_scheduling(sq, c.GST_SCHEDULING_FLAG_SEEKABLE, 2, 3, 4);
    c.gst_query_add_scheduling_mode(sq, c.GST_PAD_MODE_PUSH);
    c.gst_query_add_scheduling_mode(sq, c.GST_PAD_MODE_PULL);
    var sf: c.GstSchedulingFlags = 0;
    var mi: c_int = 0;
    var ma: c_int = 0;
    var al: c_int = 0;
    c.gst_query_parse_scheduling(sq, &sf, &mi, &ma, &al);
    out("  {d} {d} {d} {d} modes {d} m1 {d} has {d} {d} wf {d} {d}", .{ sf, mi, ma, al, c.gst_query_get_n_scheduling_modes(sq), c.gst_query_parse_nth_scheduling_mode(sq, 1), c.gst_query_has_scheduling_mode(sq, c.GST_PAD_MODE_PULL), c.gst_query_has_scheduling_mode(sq, c.GST_PAD_MODE_NONE), c.gst_query_has_scheduling_mode_with_flags(sq, c.GST_PAD_MODE_PUSH, c.GST_SCHEDULING_FLAG_SEEKABLE), c.gst_query_has_scheduling_mode_with_flags(sq, c.GST_PAD_MODE_PUSH, c.GST_SCHEDULING_FLAG_SEQUENTIAL) });
    out("  oob {d}", .{c.gst_query_parse_nth_scheduling_mode(sq, 5)});

    const acq = c.gst_query_new_accept_caps(caps);
    show("accept-caps", acq);
    c.gst_query_set_accept_caps_result(acq, 1);
    c.gst_query_parse_accept_caps_result(acq, &b);
    c.gst_query_parse_accept_caps(acq, &pc);
    out("  {d} {d}", .{ b, @intFromBool(pc == caps) });
    const unfixed = c.gst_caps_from_string("video/x-raw, width=(int)[1,2]");
    show("accept-caps bad", c.gst_query_new_accept_caps(unfixed));
    const cq = c.gst_query_new_caps(unfixed);
    show("caps", cq);
    c.gst_query_set_caps_result(cq, caps);
    c.gst_query_parse_caps_result(cq, &pc);
    var pf: [*c]c.GstCaps = null;
    c.gst_query_parse_caps(cq, &pf);
    out("  {d} {d}", .{ @intFromBool(pc == caps), @intFromBool(pf == unfixed) });
    show("drain", c.gst_query_new_drain());
    const ctq = c.gst_query_new_context("my.ctx");
    show("context", ctq);
    var ct: [*c]const u8 = null;
    out("  {d} {s}", .{ c.gst_query_parse_context_type(ctq, &ct), str(ct) });
    var pctx: ?*c.GstContext = null;
    c.gst_query_parse_context(ctq, &pctx);
    out("  ctx null {d}", .{@intFromBool(pctx == null)});
    const ctx = c.gst_context_new("my.ctx", 0);
    c.gst_query_set_context(ctq, ctx);
    const ctx2 = c.gst_context_new("other", 0);
    c.gst_query_set_context(ctq, ctx2);
    c.gst_query_parse_context(ctq, &pctx);
    out("  ctx {s}", .{str(c.gst_context_get_context_type(pctx))});
    show("context null type", c.gst_query_new_context(null));
    const brq = c.gst_query_new_bitrate();
    c.gst_query_set_bitrate(brq, 128000);
    c.gst_query_parse_bitrate(brq, &n);
    show("bitrate", brq);
    out("  {d}", .{n});
    const slq = c.gst_query_new_selectable();
    c.gst_query_parse_selectable(slq, &b);
    out("selectable {d}", .{b});
    c.gst_query_set_selectable(slq, 1);
    c.gst_query_parse_selectable(slq, &b);
    show("selectable", slq);
    out("  {d}", .{b});

    const cu = c.gst_query_new_custom(c.GST_QUERY_CUSTOM, c.gst_structure_new_empty("myq"));
    show("custom", cu);
    show("custom owned", c.gst_query_new_custom(c.GST_QUERY_CUSTOM, @constCast(c.gst_query_get_structure(cu))));
    const nq = c.gst_query_new_custom(c.GST_QUERY_JITTER, null);
    const ws = c.gst_query_writable_structure(nq);
    c.gst_structure_set(ws, "k", c.G_TYPE_INT, @as(c_int, 1), end);
    show("jitter writable", nq);
    _ = c.gst_query_ref(nq);
    c.gst_query_set_seeking(nq, c.GST_FORMAT_TIME, 1, 0, 0);
    out("  writable {d}", .{c.gst_query_is_writable(nq)});
    const w = c.gst_query_make_writable(nq);
    show("made writable", w);
    out("  diff {d}", .{@intFromBool(w != nq)});
    out("wrong type", .{});
    c.gst_query_parse_latency(pos, null, null, null);
    c.gst_query_add_scheduling_mode(pos, c.GST_PAD_MODE_PUSH);
    out("{d}", .{@intFromBool(c.gst_query_get_structure(null) == null)});
    var slot: [*c]c.GstQuery = null;
    out("replace {d} take {d} steal {d}", .{ c.gst_query_replace(&slot, pos), c.gst_query_take(&slot, c.gst_query_new_drain()), @intFromBool(c.gst_query_steal(&slot) != null) });
    slot = c.gst_query_new_drain();
    c.gst_clear_query(&slot);
    out("cleared {d}", .{@intFromBool(slot == null)});
    const types = [_]c_uint{ c.GST_QUERY_UNKNOWN, c.GST_QUERY_POSITION, c.GST_QUERY_SELECTABLE, 77 };
    for (types) |t| out("t {d} {s} {d}", .{ t, str(c.gst_query_type_get_name(t)), c.gst_query_type_get_flags(t) });
}
