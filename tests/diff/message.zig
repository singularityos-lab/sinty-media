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

fn z(p: [*:0]const u8) [*c]const u8 {
    return p;
}

const end: ?*anyopaque = null;
var base_seq: u32 = 0;

fn show(label: []const u8, m: [*c]c.GstMessage) void {
    if (m == null) {
        out("{s}: (null)", .{label});
        return;
    }
    const s = c.gst_message_get_structure(m);
    const ss = if (s != null) c.gst_structure_to_string(s) else null;
    out("{s}: type {s} quark {s} src {s} seq +{d} ts {d} struct {s}", .{ label, str(c.gst_message_type_get_name(m.*.type)), str(c.g_quark_to_string(c.gst_message_type_to_quark(m.*.type))), if (m.*.src != null) str(m.*.src.*.name) else "-", c.gst_message_get_seqnum(m) -% base_seq, m.*.timestamp, str(ss) });
    c.g_free(ss);
}

pub fn main() void {
    c.gst_init(null, null);
    const src: [*c]c.GstObject = @ptrCast(@alignCast(c.gst_stream_new("srcobj", null, c.GST_STREAM_TYPE_AUDIO, 0)));
    const types = [_]c_int{ c.GST_MESSAGE_UNKNOWN, c.GST_MESSAGE_EOS, c.GST_MESSAGE_REDIRECT, c.GST_MESSAGE_INSTANT_RATE_REQUEST, c.GST_MESSAGE_DEVICE_MONITOR_STARTED, c.GST_MESSAGE_ANY, 3 };
    for (types) |t| out("t {d} {s} q {s}", .{ t, str(c.gst_message_type_get_name(t)), str(c.g_quark_to_string(c.gst_message_type_to_quark(t))) });

    const eos = c.gst_message_new_eos(src);
    base_seq = c.gst_message_get_seqnum(eos);
    show("eos", eos);
    out("  src refs {d}", .{@as(*c.GObject, @ptrCast(@alignCast(src))).ref_count});

    const err = c.g_error_new_literal(c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, "boom");
    const em = c.gst_message_new_error(src, err, "dbg info");
    show("error", em);
    var ge: [*c]c.GError = null;
    var dbg: [*c]u8 = null;
    c.gst_message_parse_error(em, &ge, &dbg);
    out("  {s} {s} {d}", .{ str(ge.*.message), str(dbg), ge.*.code });
    c.g_error_free(ge);
    c.g_free(dbg);
    var det: [*c]const c.GstStructure = null;
    c.gst_message_parse_error_details(em, &det);
    out("  details {d}", .{@intFromBool(det == null)});
    var wd: [*c]c.GstStructure = null;
    c.gst_message_parse_error_writable_details(em, &wd);
    c.gst_structure_set(wd, "extra", c.G_TYPE_INT, @as(c_int, 3), end);
    show("error+details", em);
    c.gst_message_set_details(em, c.gst_structure_new_empty("again"));
    const wm = c.gst_message_new_warning_with_details(src, err, "w\xff", c.gst_structure_new_empty("wd"));
    show("warning", wm);
    c.gst_message_parse_warning_details(wm, &det);
    out("  {s}", .{str(c.gst_structure_get_name(det))});
    const im = c.gst_message_new_info(null, err, null);
    show("info", im);
    c.gst_message_parse_info(im, &ge, &dbg);
    out("  {s} {s}", .{ str(ge.*.message), str(dbg) });
    c.g_error_free(ge);
    c.gst_message_parse_info_details(im, &det);
    out("  det {d}", .{@intFromBool(det == null)});
    out("  get_details {d} writable {s}", .{ @intFromBool(c.gst_message_get_details(eos) == null), str(c.gst_structure_get_name(c.gst_message_writable_details(eos))) });
    show("eos+details", eos);

    const tm = c.gst_message_new_tag(src, c.gst_tag_list_new(z("title"), z("x"), end));
    show("tag", tm);
    var tl: [*c]c.GstTagList = null;
    c.gst_message_parse_tag(tm, &tl);
    out("  {d}", .{c.gst_tag_list_n_tags(tl)});
    c.gst_tag_list_unref(tl);
    show("tag bad", c.gst_message_new_tag(src, null));

    const bm = c.gst_message_new_buffering(src, 40);
    show("buffering", bm);
    show("buffering 100", c.gst_message_new_buffering(src, 100));
    show("buffering bad", c.gst_message_new_buffering(src, 101));
    c.gst_message_set_buffering_stats(bm, c.GST_BUFFERING_LIVE, 10, 20, 30);
    var pct: c_int = 0;
    var bmode: c.GstBufferingMode = 0;
    var ai: c_int = 0;
    var ao: c_int = 0;
    var left: i64 = 0;
    c.gst_message_parse_buffering(bm, &pct);
    c.gst_message_parse_buffering_stats(bm, &bmode, &ai, &ao, &left);
    out("  {d} {d} {d} {d} {d}", .{ pct, bmode, ai, ao, left });

    const sc = c.gst_message_new_state_changed(src, c.GST_STATE_READY, c.GST_STATE_PAUSED, c.GST_STATE_PLAYING);
    show("state", sc);
    var s1: c.GstState = 0;
    var s2: c.GstState = 0;
    var s3: c.GstState = 0;
    c.gst_message_parse_state_changed(sc, &s1, &s2, &s3);
    out("  {d} {d} {d}", .{ s1, s2, s3 });
    show("dirty", c.gst_message_new_state_dirty(src));
    const ss = c.gst_message_new_segment_start(src, c.GST_FORMAT_TIME, 5);
    show("segstart", ss);
    var f: c.GstFormat = 0;
    var pos: i64 = 0;
    c.gst_message_parse_segment_start(ss, &f, &pos);
    out("  {d} {d}", .{ f, pos });
    const sd = c.gst_message_new_segment_done(src, c.GST_FORMAT_BYTES, 9);
    c.gst_message_parse_segment_done(sd, &f, &pos);
    show("segdone", sd);
    out("  {d} {d}", .{ f, pos });
    show("application", c.gst_message_new_application(src, c.gst_structure_new_empty("app")));
    show("application bad", c.gst_message_new_application(src, null));
    show("element", c.gst_message_new_element(null, c.gst_structure_new_empty("el")));
    show("duration", c.gst_message_new_duration_changed(src));
    show("async-start", c.gst_message_new_async_start(src));
    const ad = c.gst_message_new_async_done(src, 77);
    show("async-done", ad);
    var rt: u64 = 0;
    c.gst_message_parse_async_done(ad, &rt);
    out("  {d}", .{rt});
    show("latency", c.gst_message_new_latency(src));
    const rs = c.gst_message_new_request_state(src, c.GST_STATE_NULL);
    show("request-state", rs);
    c.gst_message_parse_request_state(rs, &s1);
    out("  {d}", .{s1});

    const sst = c.gst_message_new_stream_status(src, c.GST_STREAM_STATUS_TYPE_ENTER, null);
    show("stream-status", sst);
    var gv: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&gv, c.G_TYPE_INT);
    c.g_value_set_int(&gv, 4);
    c.gst_message_set_stream_status_object(sst, &gv);
    out("  obj {d}", .{c.g_value_get_int(c.gst_message_get_stream_status_object(sst))});
    var sstt: c.GstStreamStatusType = 0;
    c.gst_message_parse_stream_status(sst, &sstt, null);
    out("  {d}", .{sstt});

    const sdm = c.gst_message_new_step_done(src, c.GST_FORMAT_BUFFERS, 4, 1.5, 1, 0, 100, 1);
    show("step-done", sdm);
    var amt: u64 = 0;
    var rate: f64 = 0;
    var fl: c.gboolean = 0;
    var inter: c.gboolean = 0;
    var dur: u64 = 0;
    var eosb: c.gboolean = 0;
    c.gst_message_parse_step_done(sdm, &f, &amt, &rate, &fl, &inter, &dur, &eosb);
    out("  {d} {d} {d} {d} {d} {d} {d}", .{ f, amt, rate, fl, inter, dur, eosb });
    const stm = c.gst_message_new_step_start(src, 1, c.GST_FORMAT_TIME, 2, 0.5, 0, 1);
    show("step-start", stm);
    var act: c.gboolean = 0;
    c.gst_message_parse_step_start(stm, &act, &f, &amt, &rate, &fl, &inter);
    out("  {d} {d} {d} {d} {d} {d}", .{ act, f, amt, rate, fl, inter });

    const qm = c.gst_message_new_qos(src, 1, 1, 2, 3, 4);
    show("qos", qm);
    c.gst_message_set_qos_values(qm, -5, 0.75, 900);
    c.gst_message_set_qos_stats(qm, c.GST_FORMAT_BUFFERS, 10, 2);
    show("qos set", qm);
    var live: c.gboolean = 0;
    var a1: u64 = 0;
    var a2: u64 = 0;
    var a3: u64 = 0;
    var a4: u64 = 0;
    c.gst_message_parse_qos(qm, &live, &a1, &a2, &a3, &a4);
    var jit: i64 = 0;
    var prop: f64 = 0;
    var qual: c_int = 0;
    c.gst_message_parse_qos_values(qm, &jit, &prop, &qual);
    c.gst_message_parse_qos_stats(qm, &f, &a1, &a2);
    out("  {d} {d} {d} {d} {d} {d} {d} {d}", .{ live, a3, a4, jit, prop, qual, a1, a2 });

    const pm = c.gst_message_new_progress(src, c.GST_PROGRESS_TYPE_START, "code", "text");
    show("progress", pm);
    show("progress done", c.gst_message_new_progress(src, c.GST_PROGRESS_TYPE_COMPLETE, "c", "t"));
    show("progress bad", c.gst_message_new_progress(src, c.GST_PROGRESS_TYPE_COMPLETE, null, "t"));
    var pt: c.GstProgressType = 0;
    var code: [*c]u8 = null;
    var text: [*c]u8 = null;
    c.gst_message_parse_progress(pm, &pt, &code, &text);
    out("  {d} {s} {s}", .{ pt, str(code), str(text) });
    c.g_free(code);
    c.g_free(text);

    const toc = c.gst_toc_new(c.GST_TOC_SCOPE_GLOBAL);
    const tcm = c.gst_message_new_toc(src, toc, 0);
    out("toc type {s}", .{str(c.gst_message_type_get_name(tcm.*.type))});
    var ptoc: ?*c.GstToc = null;
    var upd: c.gboolean = 5;
    c.gst_message_parse_toc(tcm, &ptoc, &upd);
    out("  same {d} upd {d}", .{ @intFromBool(ptoc == toc), upd });
    show("reset-time", c.gst_message_new_reset_time(src, 12));
    show("reset-time bad", c.gst_message_new_reset_time(src, c.GST_CLOCK_TIME_NONE));
    const ssm = c.gst_message_new_stream_start(src);
    var gid: c_uint = 9;
    out("group {d} {d}", .{ c.gst_message_parse_group_id(ssm, &gid), gid });
    c.gst_message_set_group_id(ssm, 3);
    out("group {d} {d}", .{ c.gst_message_parse_group_id(ssm, &gid), gid });
    show("stream-start", ssm);
    const nc = c.gst_message_new_need_context(src, "gst.gl.Display");
    show("need-context", nc);
    var ct: [*c]const u8 = null;
    out("  {d} {s}", .{ c.gst_message_parse_context_type(nc, &ct), str(ct) });
    const hc = c.gst_message_new_have_context(src, c.gst_context_new("ctx.type", 1));
    out("have-context {s}", .{str(c.gst_message_type_get_name(hc.*.type))});
    var pctx: ?*c.GstContext = null;
    c.gst_message_parse_have_context(hc, &pctx);
    out("  {s}", .{str(c.gst_context_get_context_type(pctx))});
    c.gst_context_unref(pctx);
    show("monitor", c.gst_message_new_device_monitor_started(src, 1));

    var pv: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&pv, c.G_TYPE_STRING);
    c.g_value_set_string(&pv, "val");
    const pn = c.gst_message_new_property_notify(src, "prop", &pv);
    show("property-notify", pn);
    var pobj: [*c]c.GstObject = null;
    var pname: [*c]const u8 = null;
    var pval: [*c]const c.GValue = null;
    c.gst_message_parse_property_notify(pn, &pobj, &pname, &pval);
    out("  {d} {s} {s}", .{ @intFromBool(pobj == src), str(pname), str(c.g_value_get_string(pval)) });
    show("property-notify null", c.gst_message_new_property_notify(src, "p2", null));

    const col = c.gst_stream_collection_new("up");
    const cm = c.gst_message_new_stream_collection(src, col);
    out("collection {s}", .{str(c.gst_message_type_get_name(cm.*.type))});
    const sel = c.gst_message_new_streams_selected(src, col);
    c.gst_message_streams_selected_add(sel, @ptrCast(@alignCast(src)));
    out("selected size {d} first {s} oob {d}", .{ c.gst_message_streams_selected_get_size(sel), str(c.gst_stream_get_stream_id(c.gst_message_streams_selected_get_stream(sel, 0))), @intFromBool(c.gst_message_streams_selected_get_stream(sel, 5) == null) });
    var pcol: ?*c.GstStreamCollection = null;
    c.gst_message_parse_streams_selected(sel, @ptrCast(&pcol));
    out("  {s}", .{str(c.gst_stream_collection_get_upstream_id(pcol))});

    const rd = c.gst_message_new_redirect(src, "file:///a", c.gst_tag_list_new(z("title"), z("A"), end), c.gst_structure_new_empty("e1"));
    c.gst_message_add_redirect_entry(rd, "file:///b", null, null);
    show("redirect", rd);
    out("  n {d}", .{c.gst_message_get_num_redirect_entries(rd)});
    var loc: [*c]const u8 = null;
    var rtl: [*c]c.GstTagList = null;
    var rst: [*c]const c.GstStructure = null;
    c.gst_message_parse_redirect_entry(rd, 1, &loc, &rtl, &rst);
    out("  {s} {d} {d}", .{ str(loc), @intFromBool(rtl == null), @intFromBool(rst == null) });
    c.gst_message_parse_redirect_entry(rd, 7, &loc, null, null);

    const irr = c.gst_message_new_instant_rate_request(src, 2.5);
    show("irr", irr);
    c.gst_message_parse_instant_rate_request(irr, &rate);
    out("  {d}", .{rate});

    const cu = c.gst_message_new_custom(c.GST_MESSAGE_APPLICATION, src, c.gst_structure_new_empty("custom"));
    out("has {d} {d}", .{ c.gst_message_has_name(cu, "custom"), c.gst_message_has_name(eos, "x") });
    show("owned", c.gst_message_new_custom(c.GST_MESSAGE_ELEMENT, null, @constCast(c.gst_message_get_structure(cu))));
    const lm = c.gst_message_new_latency(null);
    const lw = c.gst_message_writable_structure(lm);
    c.gst_structure_set(lw, "k", c.G_TYPE_INT, @as(c_int, 1), end);
    show("latency writable", lm);
    const cp = c.gst_message_copy(em);
    show("copy", cp);
    c.gst_message_set_seqnum(cp, 99);
    c.gst_message_set_seqnum(cp, 0);
    out("  seq {d}", .{c.gst_message_get_seqnum(cp)});
    out("wrong", .{});
    c.gst_message_parse_buffering(eos, &pct);
    c.gst_message_parse_tag(eos, &tl);
    c.gst_message_parse_toc(tcm, null, null);
    out("{d}", .{c.gst_message_get_seqnum(null)});
    var slot: [*c]c.GstMessage = null;
    out("replace {d} take {d} steal {d}", .{ c.gst_message_replace(&slot, eos), c.gst_message_take(&slot, c.gst_message_new_eos(null)), @intFromBool(c.gst_message_steal(&slot) != null) });
    slot = c.gst_message_new_eos(null);
    c.gst_clear_message(&slot);
    const doms = [_]c.GQuark{ c.gst_core_error_quark(), c.gst_library_error_quark(), c.gst_resource_error_quark(), c.gst_stream_error_quark(), c.g_quark_from_string("other") };
    for (doms) |d| {
        var ec: c_int = 0;
        while (ec < 17) : (ec += 1) {
            const em2 = c.gst_error_get_message(d, ec);
            out("err {s} {d} {s}", .{ str(c.g_quark_to_string(d)), ec, str(em2) });
            c.g_free(em2);
        }
    }
    out("cleared {d} writable {d}", .{ @intFromBool(slot == null), c.gst_message_is_writable(eos) });
}
