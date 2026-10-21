const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const info = @import("info.zig");
const core = @import("core.zig");
const bin = @import("bin.zig");
const ghostpad = @import("ghostpad.zig");
const pad = @import("pad.zig");
const tracer = @import("tracer.zig");
const capsfeatures = @import("capsfeatures.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Bin = c.GstBin;
const Pad = pad.Pad;
const Element = c.GstElement;
const Details = c.GstDebugGraphDetails;
const Str = *c.GString;

const PARAM_MAX = 80;
const ICONS = "~0-=>";

pub var dot_dir: [*c]const u8 = null;
var dots_tracer: c.gsize = 0;

pub fn loadDotDir() void {
    if (dot_dir == null) dot_dir = c.g_getenv("GST_DEBUG_DUMP_DOT_DIR");
}

fn put(s: Str, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, c.g_string_append_printf, .{ s, fmt } ++ args);
}

fn indent(n: c.gint) [*c]const u8 {
    const spaces = " " ** 128;
    return spaces[spaces.len - @as(usize, @intCast(n * 2)) ..];
}

fn nodeName(o: anytype) [*c]u8 {
    const obj: [*c]c.GstObject = @ptrCast(@alignCast(o));
    return c.g_strcanon(c.g_strdup_printf("node_%s_%p", obj[0].name, obj), c.G_CSET_A_2_Z ++ c.G_CSET_a_2_z ++ c.G_CSET_DIGITS ++ "_", '_');
}

fn elementState(e: [*c]Element) [*c]u8 {
    var state: c.GstState = c.GST_STATE_VOID_PENDING;
    var pending: c.GstState = c.GST_STATE_VOID_PENDING;
    _ = c.gst_element_get_state(e, &state, &pending, 0);
    if (pending == c.GST_STATE_VOID_PENDING)
        return c.g_strdup_printf("\\n[%c]%s", @as(c_int, ICONS[@intCast(state)]), @as([*c]const u8, if (c.gst_element_is_locked_state(e) != 0) "(locked)" else ""));
    return c.g_strdup_printf("\\n[%c] -> [%c]", @as(c_int, ICONS[@intCast(state)]), @as(c_int, ICONS[@intCast(pending)]));
}

fn dotsTracerActive() bool {
    if (c.g_once_init_enter(&dots_tracer) != 0) {
        var found: c.gsize = 1;
        const list = tracer.gst_tracing_get_active_tracers();
        var l = list;
        while (l) |n| : (l = n.next) {
            if (c.g_strcmp0(c.g_type_name(gtype.typeOf(n.data)), "GstDotsTracer") == 0) {
                found = 2;
                break;
            }
        }
        c.g_list_free_full(list, c.gst_object_unref);
        c.g_once_init_leave(&dots_tracer, found);
    }
    return dots_tracer == 2;
}

fn enumNick(v: *c.GValue) [*c]u8 {
    const k: *c.GEnumClass = @ptrCast(@alignCast(c.g_type_class_ref(v.g_type)));
    const e = c.g_value_get_enum(v);
    for (k.values[0..k.n_values]) |x| if (x.value == e) return c.g_strdup(x.value_nick);
    return null;
}

fn flagsNicks(v: *c.GValue) [*c]u8 {
    const k: *c.GFlagsClass = @ptrCast(@alignCast(c.g_type_class_ref(v.g_type)));
    const s = c.g_string_new(null);
    var left = c.g_value_get_flags(v);
    var i = k.n_values;
    while (i > 0) {
        i -= 1;
        const x = k.values[i];
        if (x.value == 0 or left & x.value != x.value) continue;
        if (s[0].len > 0) _ = c.g_string_prepend_c(s, '+');
        _ = c.g_string_prepend(s, x.value_nick);
        left -= x.value;
        if (left == 0) break;
    }
    if (s[0].len == 0) _ = c.g_string_assign(s, "(none)");
    return c.g_string_free(s, 0);
}

fn ignored(name: [*c]const u8, skip: []const [*:0]const u8) bool {
    for (skip) |s| if (c.g_strcmp0(s, name) == 0) return true;
    return false;
}

fn objectParams(o: ?*anyopaque, details_in: Details, skip: []const [*:0]const u8, sep: [*c]const u8) [*c]u8 {
    var details = details_in;
    if (details == c.GST_DEBUG_GRAPH_SHOW_ALL and dotsTracerActive()) details = c.GST_DEBUG_GRAPH_SHOW_FULL_PARAMS;
    const full = details & c.GST_DEBUG_GRAPH_SHOW_FULL_PARAMS != 0;
    var n: c.guint = 0;
    const props = c.g_object_class_list_properties(@ptrCast(@alignCast(@as([*c]c.GTypeInstance, @ptrCast(@alignCast(o)))[0].g_class)), &n);
    if (props == null) return null;
    defer c.g_free(@ptrCast(props));
    var acc: [*c]u8 = null;
    for (props[0..n]) |p| {
        if (p.*.flags & c.G_PARAM_READABLE == 0) continue;
        if (c.strcmp(p.*.name, "name") == 0 or c.strcmp(p.*.name, "parent") == 0) continue;
        if (ignored(p.*.name, skip)) continue;
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, p.*.value_type);
        defer c.g_value_unset(&v);
        c.g_object_get_property(@ptrCast(@alignCast(o)), p.*.name, &v);
        if (c.g_param_value_defaults(p, &v) != 0) continue;
        const fund = c.g_type_fundamental(v.g_type);
        const text = if (fund == c.G_TYPE_ENUM) enumNick(&v) else if (fund == c.G_TYPE_FLAGS) flagsNicks(&v) else c.g_strdup_value_contents(&v);
        if (text == null) continue;
        const esc = c.g_strescape(text, null);
        c.g_free(text);
        defer c.g_free(esc);
        const prev: [*c]const u8 = if (acc != null) acc else "";
        const next = if (full)
            c.g_strdup_printf("%s%s%s=%s", prev, sep, p.*.name, esc)
        else
            c.g_strdup_printf("%s%s%s=%.80s%s", prev, sep, p.*.name, esc, @as([*c]const u8, if (c.strlen(esc) > PARAM_MAX) "…" else ""));
        c.g_free(acc);
        acc = next;
    }
    return acc;
}

fn opt(p: [*c]const u8) [*c]const u8 {
    return if (p != null) p else "";
}

fn dumpPad(p: [*c]Pad, color: [*c]const u8, owner: [*c]const u8, details: Details, s: Str, depth: c.gint) void {
    const name = nodeName(p);
    defer c.g_free(name);
    var style: [*c]const u8 = "filled,solid";
    const templ = pad.gst_pad_get_pad_template(p);
    if (templ != null) {
        const presence = templ[0].presence;
        c.gst_object_unref(templ);
        if (presence == c.GST_PAD_SOMETIMES) style = "filled,dotted" else if (presence == c.GST_PAD_REQUEST) style = "filled,dashed";
    }
    const params = objectParams(p, details, &.{ "direction", "template", "caps" }, "\n");
    defer c.g_free(params);
    const spc = indent(depth);
    if (details & c.GST_DEBUG_GRAPH_SHOW_STATES == 0) {
        put(s, "%s  %s_%s [color=black, fillcolor=\"%s\", label=\"%s%s\", height=\"0.2\", style=\"%s\"];\n", .{ spc, owner, name, color, p[0].object.name, opt(params), style });
        return;
    }
    var task_mode: [*c]const u8 = "";
    c.g_mutex_lock(&p[0].object.lock);
    if (p[0].task != null) {
        switch (c.gst_task_get_state(p[0].task)) {
            c.GST_TASK_STARTED => task_mode = "[T]",
            c.GST_TASK_PAUSED => task_mode = "[t]",
            else => {},
        }
    }
    c.g_mutex_unlock(&p[0].object.lock);
    const fl = p[0].object.flags;
    var flags = [5]u8{
        if (fl & c.GST_PAD_FLAG_BLOCKED != 0) 'B' else 'b',
        if (fl & c.GST_PAD_FLAG_FLUSHING != 0) 'F' else 'f',
        if (fl & c.GST_PAD_FLAG_BLOCKING != 0) 'B' else 'b',
        if (fl & c.GST_PAD_FLAG_EOS != 0) 'E' else 0,
        0,
    };
    put(s, "%s  %s_%s [color=black, fillcolor=\"%s\", label=\"%s%s\\n[%c][%s]%s\", height=\"0.2\", style=\"%s\"];\n", .{ spc, owner, name, color, p[0].object.name, opt(params), @as(c_int, "-><"[@intCast(p[0].mode)]), @as([*c]const u8, &flags), task_mode, style });
}

fn dumpElementPad(p: [*c]Pad, e: [*c]Element, details: Details, s: Str, depth: c.gint) void {
    const dir = pad.gst_pad_get_direction(p);
    const owner = nodeName(e);
    defer c.g_free(owner);
    var color: [*c]const u8 = undefined;
    if (ghostpad.isGhost(p)) {
        color = if (dir == c.GST_PAD_SRC) "#ffdddd" else if (dir == c.GST_PAD_SINK) "#ddddff" else "#ffffff";
        const inner = ghostpad.gst_ghost_pad_get_target(@ptrCast(p));
        if (inner != null) {
            defer c.gst_object_unref(inner);
            const target = pad.gst_pad_get_peer(inner);
            if (target != null) {
                defer c.gst_object_unref(target);
                const te = pad.gst_pad_get_parent_element(target);
                const tname = if (te != null) nodeName(te) else c.g_strdup("");
                defer {
                    c.g_free(tname);
                    if (te != null) c.gst_object_unref(te);
                }
                dumpPad(target, color, tname, details, s, depth);
                const pname = nodeName(p);
                const tpname = nodeName(target);
                defer {
                    c.g_free(pname);
                    c.g_free(tpname);
                }
                const spc = indent(depth);
                if (dir == c.GST_PAD_SRC)
                    put(s, "%s%s_%s -> %s_%s [style=dashed, minlen=0]\n", .{ spc, tname, tpname, owner, pname })
                else
                    put(s, "%s%s_%s -> %s_%s [style=dashed, minlen=0]\n", .{ spc, owner, pname, tname, tpname });
            }
        }
    } else {
        color = if (dir == c.GST_PAD_SRC) "#ffaaaa" else if (dir == c.GST_PAD_SINK) "#aaaaff" else "#cccccc";
    }
    dumpPad(p, color, owner, details, s, depth);
}

fn appendField(field: [*c]const c.GstIdStr, v: [*c]const c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const s: Str = @ptrCast(@alignCast(data));
    const fname = c.gst_id_str_as_str(field);
    const text = c.gst_value_serialize(v);
    if (text == null) {
        put(s, "  %18s: NULL\\l", .{fname});
        return 1;
    }
    defer c.g_free(text);
    if (c.strlen(text) > 25) {
        var pos: usize = 24;
        text[25] = 0;
        const closer: u8 = switch (text[0]) {
            '<' => '>',
            '[' => ']',
            '(' => ')',
            '{' => '}',
            '"' => '"',
            else => 0,
        };
        if (closer != 0) {
            text[pos] = closer;
            pos -= 1;
            text[pos] = ' ';
            pos -= 1;
        }
        text[pos] = '.';
        text[pos - 1] = '.';
        text[pos - 2] = '.';
    }
    const esc = c.g_strescape(text, null);
    defer c.g_free(esc);
    put(s, "  %18s: %s\\l", .{ fname, esc });
    return 1;
}

fn describeCaps(caps: [*c]c.GstCaps, details: Details) [*c]u8 {
    if (details & c.GST_DEBUG_GRAPH_SHOW_CAPS_DETAILS == 0) {
        if (c.gst_caps_is_any(caps) == 0 and c.gst_caps_get_size(caps) == 1) return c.g_strdup(c.gst_structure_get_name(c.gst_caps_get_structure(caps, 0)));
        return c.g_strdup("*");
    }
    if (c.gst_caps_is_any(caps) != 0 or c.gst_caps_is_empty(caps) != 0) return c.gst_caps_to_string(caps);
    const s = c.g_string_new(null);
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(caps)) : (i += 1) {
        const f = @import("caps.zig").__gst_caps_get_features_unchecked(@ptrCast(caps), i);
        const st = c.gst_caps_get_structure(caps, i);
        _ = c.g_string_append(s, c.gst_structure_get_name(st));
        if (f != null and (c.gst_caps_features_is_any(f) != 0 or c.gst_caps_features_is_equal(f, c._gst_caps_features_memory_system_memory) == 0)) {
            _ = c.g_string_append_c(s, '(');
            capsfeatures.appendTo(@ptrCast(f), s);
            _ = c.g_string_append_c(s, ')');
        }
        _ = c.g_string_append(s, "\\l");
        _ = c.gst_structure_foreach_id_str(st, appendField, s);
    }
    return c.g_string_free(s, 0);
}

fn padCaps(p: [*c]Pad) [*c]c.GstCaps {
    const cur = pad.gst_pad_get_current_caps(p);
    return if (cur != null) cur else pad.gst_pad_get_pad_template_caps(p);
}

fn dumpLink(p: [*c]Pad, e: [*c]Element, details: Details, s: Str, depth: c.gint) void {
    const peer = pad.gst_pad_get_peer(p);
    if (peer == null) return;
    defer c.gst_object_unref(peer);
    var media: [*c]u8 = null;
    var media_src: [*c]u8 = null;
    var media_sink: [*c]u8 = null;
    if (details & (c.GST_DEBUG_GRAPH_SHOW_MEDIA_TYPE | c.GST_DEBUG_GRAPH_SHOW_CAPS_DETAILS) != 0) {
        const caps = padCaps(p);
        const peer_caps = padCaps(peer);
        media = describeCaps(caps, details);
        if (peer_caps != null and c.gst_caps_is_equal(caps, peer_caps) == 0) {
            const other = describeCaps(peer_caps, details);
            if (pad.gst_pad_get_direction(p) == c.GST_PAD_SRC) {
                media_src = media;
                media_sink = other;
            } else {
                media_src = other;
                media_sink = media;
            }
            media = null;
        }
        c.gst_caps_unref(peer_caps);
        c.gst_caps_unref(caps);
    }
    const pname = nodeName(p);
    const ename = if (e != null) nodeName(e) else c.g_strdup("");
    const ppname = nodeName(peer);
    const pe = pad.gst_pad_get_parent_element(peer);
    const pename = if (pe != null) nodeName(pe) else c.g_strdup("");
    defer {
        c.g_free(pname);
        c.g_free(ename);
        c.g_free(ppname);
        c.g_free(pename);
        if (pe != null) c.gst_object_unref(pe);
    }
    const spc = indent(depth);
    if (media != null) {
        put(s, "%s%s_%s -> %s_%s [label=\"%s\"]\n", .{ spc, ename, pname, pename, ppname, media });
        c.g_free(media);
    } else if (media_src != null and media_sink != null) {
        put(s, "%s%s_%s -> %s_%s [labeldistance=\"10\", labelangle=\"0\", label=\"                                                  \", taillabel=\"%s\", headlabel=\"%s\"]\n", .{ spc, ename, pname, pename, ppname, media_src, media_sink });
        c.g_free(media_src);
        c.g_free(media_sink);
    } else {
        put(s, "%s%s_%s -> %s_%s\n", .{ spc, ename, pname, pename, ppname });
    }
}

fn each(it: ?*c.GstIterator, ctx: anytype, comptime f: fn (@TypeOf(ctx), c.gpointer) void) void {
    var item = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&item);
    while (true) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                f(ctx, c.g_value_get_object(&item));
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => c.gst_iterator_resync(it),
            else => return,
        }
    }
}

const PadsCtx = struct {
    e: [*c]Element,
    details: Details,
    s: Str,
    depth: c.gint,
    count: *c.guint,
    cluster: [*c]const u8,
    first: *[*c]u8,
};

fn padVisit(x: *const PadsCtx, obj: c.gpointer) void {
    const p: [*c]Pad = @ptrCast(@alignCast(obj));
    if (x.count.* == 0) {
        const spc = indent(x.depth);
        put(x.s, "%ssubgraph cluster_%s {\n", .{ spc, x.cluster });
        put(x.s, "%s  label=\"\";\n", .{spc});
        put(x.s, "%s  style=\"invis\";\n", .{spc});
        x.first.* = nodeName(p);
    }
    dumpElementPad(p, x.e, x.details, x.s, x.depth);
    x.count.* += 1;
}

fn dumpPads(it: ?*c.GstIterator, e: [*c]Element, details: Details, s: Str, depth: c.gint, count: *c.guint, cluster: [*c]const u8, first: *[*c]u8) void {
    const ctx = PadsCtx{ .e = e, .details = details, .s = s, .depth = depth, .count = count, .cluster = cluster, .first = first };
    each(it, &ctx, padVisit);
    if (count.* != 0) put(s, "%s}\n\n", .{indent(depth)});
}

const LinkCtx = struct {
    e: [*c]Element,
    details: Details,
    s: Str,
    depth: c.gint,
};

fn linkVisit(x: *const LinkCtx, obj: c.gpointer) void {
    const p: [*c]Pad = @ptrCast(@alignCast(obj));
    if (pad.gst_pad_is_linked(p) == 0) return;
    if (pad.gst_pad_get_direction(p) == c.GST_PAD_SRC) return dumpLink(p, x.e, x.details, x.s, x.depth);
    const peer = pad.gst_pad_get_peer(p);
    if (peer == null) return;
    defer c.gst_object_unref(peer);
    if (!ghostpad.isGhost(peer) and gtype.instanceOf(peer, ghostpad.gst_proxy_pad_get_type())) dumpLink(peer, null, x.details, x.s, x.depth);
}

const ElemCtx = struct {
    details: Details,
    s: Str,
    depth: c.gint,
};

fn elementVisit(x: *const ElemCtx, obj: c.gpointer) void {
    const e: [*c]Element = @ptrCast(@alignCast(obj));
    const s = x.s;
    const spc = indent(x.depth);
    const name = nodeName(e);
    defer c.g_free(name);
    const state = if (x.details & c.GST_DEBUG_GRAPH_SHOW_STATES != 0) elementState(e) else null;
    const params = if (x.details & c.GST_DEBUG_GRAPH_SHOW_NON_DEFAULT_PARAMS != 0) objectParams(e, x.details, &.{"stats"}, "\n") else null;
    put(s, "%ssubgraph cluster_%s {\n", .{ spc, name });
    put(s, "%s  fontname=\"Bitstream Vera Sans\";\n", .{spc});
    put(s, "%s  fontsize=\"8\";\n", .{spc});
    put(s, "%s  style=\"filled,rounded\";\n", .{spc});
    put(s, "%s  color=black;\n", .{spc});
    put(s, "%s  label=\"%s\\n%s%s%s\";\n", .{ spc, c.g_type_name(gtype.typeOf(e)), e[0].object.name, opt(state), opt(params) });
    c.g_free(state);
    c.g_free(params);
    var sinks: c.guint = 0;
    var srcs: c.guint = 0;
    var sink_first: [*c]u8 = null;
    var src_first: [*c]u8 = null;
    defer {
        c.g_free(sink_first);
        c.g_free(src_first);
    }
    if (c.gst_element_iterate_sink_pads(e)) |it| {
        const cluster = c.g_strdup_printf("%s_sink", name);
        dumpPads(it, e, x.details, s, x.depth + 1, &sinks, cluster, &sink_first);
        c.g_free(cluster);
        c.gst_iterator_free(it);
    }
    if (c.gst_element_iterate_src_pads(e)) |it| {
        const cluster = c.g_strdup_printf("%s_src", name);
        dumpPads(it, e, x.details, s, x.depth + 1, &srcs, cluster, &src_first);
        c.g_free(cluster);
        c.gst_iterator_free(it);
    }
    if (sinks != 0 and srcs != 0) put(s, "%s  %s_%s -> %s_%s [style=\"invis\"];\n", .{ spc, name, sink_first, name, src_first });
    if (bin.isBin(e)) {
        put(s, "%s  fillcolor=\"#ffffff\";\n", .{spc});
        dumpElements(@ptrCast(e), x.details, s, x.depth + 1);
    } else {
        const fill: [*c]const u8 = if (srcs != 0 and sinks == 0) "#ffaaaa" else if (srcs == 0 and sinks != 0) "#aaaaff" else if (srcs != 0 and sinks != 0) "#aaffaa" else "#ffffff";
        put(s, "%s  fillcolor=\"%s\";\n", .{ spc, fill });
    }
    put(s, "%s}\n\n", .{spc});
    if (c.gst_element_iterate_pads(e)) |it| {
        const ctx = LinkCtx{ .e = e, .details = x.details, .s = s, .depth = x.depth };
        each(it, &ctx, linkVisit);
        c.gst_iterator_free(it);
    }
}

fn dumpElements(b: [*c]Bin, details: Details, s: Str, depth: c.gint) void {
    const it = c.gst_bin_iterate_elements(b);
    defer c.gst_iterator_free(it);
    const ctx = ElemCtx{ .details = details, .s = s, .depth = depth };
    each(it, &ctx, elementVisit);
}

fn tracersInfo(details: Details) [*c]u8 {
    const list = tracer.gst_tracing_get_active_tracers() orelse return null;
    const s = c.g_string_new("Active Tracers:");
    var l: ?*c.GList = list;
    while (l) |n| : (l = n.next) {
        put(s, "\\l    - %s", .{c.g_type_name(gtype.typeOf(n.data))});
        if (details & c.GST_DEBUG_GRAPH_SHOW_NON_DEFAULT_PARAMS != 0) {
            const props = objectParams(n.data, details, &.{}, "\\l        * ");
            if (props != null) {
                _ = c.g_string_append_c(s, ':');
                put(s, "    %s", .{props});
            }
            c.g_free(props);
        }
        _ = c.g_string_append(s, "\\l");
    }
    c.g_list_free_full(list, c.gst_object_unref);
    return c.g_string_free(s, 0);
}

fn header(b: [*c]Bin, details: Details, s: Str) void {
    const state = if (details & c.GST_DEBUG_GRAPH_SHOW_STATES != 0) elementState(@ptrCast(b)) else null;
    const params = if (details & c.GST_DEBUG_GRAPH_SHOW_NON_DEFAULT_PARAMS != 0) objectParams(b, details, &.{}, "\n") else null;
    defer {
        c.g_free(state);
        c.g_free(params);
    }
    put(s, "digraph pipeline {\n" ++
        "  rankdir=LR;\n" ++
        "  fontname=\"sans\";\n" ++
        "  fontsize=\"10\";\n" ++
        "  labelloc=t;\n" ++
        "  nodesep=.1;\n" ++
        "  ranksep=.2;\n" ++
        "  label=\"<%s>\\n%s%s%s\";\n" ++
        "  node [style=\"filled,rounded\", shape=box, fontsize=\"9\", fontname=\"sans\", margin=\"0.0,0.0\"];\n" ++
        "  edge [labelfontsize=\"6\", fontsize=\"9\", fontname=\"monospace\"];\n" ++
        "  \n" ++
        "  legend [\n" ++
        "    pos=\"0,0!\",\n" ++
        "    margin=\"0.05,0.05\",\n" ++
        "    style=\"filled\",\n" ++
        "    label=\"Legend\\lElement-States: [~] void-pending, [0] null, [-] ready, [=] paused, [>] playing\\lPad-Activation: [-] none, [>] push, [<] pull\\lPad-Flags: [b]locked, [f]lushing, [b]locking, [E]OS; upper-case is set\\lPad-Task: [T] has started task, [t] has paused task\\l\",\n" ++
        "  ];\n", .{ c.g_type_name(gtype.typeOf(b)), b[0].element.object.name, opt(state), opt(params) });
    const tracers = tracersInfo(details);
    if (tracers == null) return;
    defer c.g_free(tracers);
    put(s, "  tracers [\n" ++
        "    pos=\"0,0!\",\n" ++
        "    margin=\"0.05,0.05\",\n" ++
        "    style=\"filled\",\n" ++
        "    fillcolor=\"#e0e0ff\",\n" ++
        "    label=\"%s\",\n" ++
        "  ];\n" ++
        "\n", .{tracers});
}

pub export fn gst_debug_bin_to_dot_data(b: [*c]Bin, details: Details) [*c]u8 {
    if (!check.that(bin.isBin(b), "gst_debug_bin_to_dot_data", "GST_IS_BIN (bin)")) return null;
    const s = c.g_string_new(null);
    header(b, details, s);
    dumpElements(b, details, s, 1);
    _ = c.g_string_append(s, "}\n");
    return c.g_string_free(s, 0);
}

fn appName(name: [*c]const u8) [*c]const u8 {
    if (name != null) return name;
    const app = c.g_get_application_name();
    return if (app != null) app else "unnamed";
}

pub export fn gst_debug_bin_to_dot_file(b: [*c]Bin, details: Details, name: [*c]const u8) void {
    if (!check.that(bin.isBin(b), "gst_debug_bin_to_dot_file", "GST_IS_BIN (bin)")) return;
    if (dot_dir == null) return;
    const path = c.g_strdup_printf("%s/%s.dot", dot_dir, appName(name));
    defer c.g_free(path);
    const data = gst_debug_bin_to_dot_data(b, details);
    defer c.g_free(data);
    var err: ?*c.GError = null;
    if (c.g_file_set_contents(path, data, -1, &err) == 0) {
        const text = c.g_strdup_printf("Failed to write file '%s' for writing: %s", path, err.?.message);
        defer c.g_free(text);
        info.logText(info.GST_CAT_DEFAULT, c.GST_LEVEL_WARNING, "../gst/gstdebugutils.c", "gst_debug_bin_to_dot_file", 0, null, null, text);
    }
    c.g_clear_error(&err);
}

pub export fn gst_debug_bin_to_dot_file_with_ts(b: [*c]Bin, details: Details, name: [*c]const u8) void {
    if (!check.that(bin.isBin(b), "gst_debug_bin_to_dot_file_with_ts", "GST_IS_BIN (bin)")) return;
    const now = c.gst_util_get_timestamp();
    const elapsed: u64 = if (now >= core.start_time) now - core.start_time else 0;
    const sec = elapsed / 1_000_000_000;
    const ts = c.g_strdup_printf("%u.%02u.%02u.%09u-%s", @as(c.guint, @intCast(sec / 3600)), @as(c.guint, @intCast(sec / 60 % 60)), @as(c.guint, @intCast(sec % 60)), @as(c.guint, @intCast(elapsed % 1_000_000_000)), appName(name));
    defer c.g_free(ts);
    gst_debug_bin_to_dot_file(b, details, ts);
}
