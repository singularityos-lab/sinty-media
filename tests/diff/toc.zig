const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
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

fn tags(t: [*c]const c.GstTagList) []const u8 {
    if (t == null) return "(no tags)";
    const s = c.gst_tag_list_to_string(t);
    return std.mem.span(s);
}

fn dumpEntries(list: [*c]c.GList, depth: usize) void {
    var l = list;
    while (l != null) : (l = l.*.next) {
        const e: ?*c.GstTocEntry = @ptrCast(@alignCast(l.*.data));
        var start: i64 = 0;
        var stop: i64 = 0;
        _ = c.gst_toc_entry_get_start_stop_times(e, &start, &stop);
        var lt: c.GstTocLoopType = 0;
        var rc: c_int = 0;
        _ = c.gst_toc_entry_get_loop(e, &lt, &rc);
        const parent = c.gst_toc_entry_get_parent(e);
        out("{d} {s} {s} alt {d} seq {d} {d}..{d} loop {d} {d} parent {s} hastoc {d} {s}", .{ depth, str(c.gst_toc_entry_get_uid(e)), str(c.gst_toc_entry_type_get_nick(c.gst_toc_entry_get_entry_type(e))), c.gst_toc_entry_is_alternative(e), c.gst_toc_entry_is_sequence(e), start, stop, lt, rc, if (parent != null) str(c.gst_toc_entry_get_uid(parent)) else "-", @intFromBool(c.gst_toc_entry_get_toc(e) != null), tags(c.gst_toc_entry_get_tags(e)) });
        dumpEntries(c.gst_toc_entry_get_sub_entries(e), depth + 1);
    }
}

fn dump(label: []const u8, t: ?*c.GstToc) void {
    out("{s}: scope {d} {s}", .{ label, c.gst_toc_get_scope(t), tags(c.gst_toc_get_tags(t)) });
    dumpEntries(c.gst_toc_get_entries(t), 0);
}

pub fn main() void {
    c.gst_init(null, null);
    out("bad scope {d}", .{@intFromBool(c.gst_toc_new(7) == null)});
    const t = c.gst_toc_new(c.GST_TOC_SCOPE_GLOBAL);
    const ed = c.gst_toc_entry_new(c.GST_TOC_ENTRY_TYPE_EDITION, "ed1");
    var i: c_int = 0;
    while (i < 3) : (i += 1) {
        var buf: [16]u8 = undefined;
        const uid = std.fmt.bufPrintZ(&buf, "ch{d}", .{i}) catch unreachable;
        const ch = c.gst_toc_entry_new(c.GST_TOC_ENTRY_TYPE_CHAPTER, uid.ptr);
        c.gst_toc_entry_set_start_stop_times(ch, i * 1000, (i + 1) * 1000);
        c.gst_toc_entry_set_tags(ch, c.gst_tag_list_new(z("title"), uid.ptr, end));
        if (i == 1) {
            const sub = c.gst_toc_entry_new(c.GST_TOC_ENTRY_TYPE_ANGLE, "angle");
            c.gst_toc_entry_set_loop(sub, c.GST_TOC_LOOP_PING_PONG, 3);
            c.gst_toc_entry_append_sub_entry(ch, sub);
            c.gst_toc_entry_append_sub_entry(ch, sub);
        }
        c.gst_toc_entry_append_sub_entry(ed, ch);
    }
    c.gst_toc_entry_merge_tags(ed, c.gst_tag_list_new(z("album"), z("Album"), end), c.GST_TAG_MERGE_APPEND);
    c.gst_toc_append_entry(t, ed);
    c.gst_toc_append_entry(t, ed);
    c.gst_toc_merge_tags(t, c.gst_tag_list_new(z("artist"), z("Who"), end), c.GST_TAG_MERGE_APPEND);
    const extra = c.gst_tag_list_new(z("artist"), z("Else"), end);
    c.gst_toc_merge_tags(t, extra, c.GST_TAG_MERGE_PREPEND);
    c.gst_tag_list_unref(extra);
    dump("toc", t);
    const found = c.gst_toc_find_entry(t, "angle");
    out("find angle {s} missing {d}", .{ str(c.gst_toc_entry_get_uid(found)), @intFromBool(c.gst_toc_find_entry(t, "nope") == null) });
    const cp: ?*c.GstToc = @ptrCast(c.gst_mini_object_copy(@ptrCast(@alignCast(t))));
    dump("copy", cp);
    const ref: *c.GstMiniObject = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(@alignCast(cp)))));
    c.gst_toc_set_tags(cp, null);
    c.gst_mini_object_unref(ref);
    c.gst_toc_set_tags(cp, null);
    dump("copy notags", cp);
    var nicks: c_int = -4;
    while (nicks <= 4) : (nicks += 1) out("nick {d} {s}", .{ nicks, str(c.gst_toc_entry_type_get_nick(nicks)) });
    out("null uid {d}", .{@intFromBool(c.gst_toc_entry_new(c.GST_TOC_ENTRY_TYPE_TRACK, null) == null)});
    out("null scope {d}", .{c.gst_toc_get_scope(null)});
    var v: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_toc_get_type());
    c.g_value_set_boxed(&v, t);
    out("type {s} {s}", .{ str(c.g_type_name(c.gst_toc_get_type())), str(c.g_type_name(c.gst_toc_entry_get_type())) });
    c.g_value_unset(&v);
    c.gst_mini_object_unref(@ptrCast(@alignCast(cp)));
    c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
}
