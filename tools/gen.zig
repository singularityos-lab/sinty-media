const std = @import("std");
const c = @import("c").c;

var buf: [1 << 22]u8 = undefined;
var len: usize = 0;

fn emit(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(buf[len..], fmt, args) catch unreachable;
    len += s.len;
}

fn zstr(s: []const u8) void {
    emit("\"", .{});
    for (s) |ch| {
        if (ch == '"' or ch == '\\') emit("\\", .{});
        emit("{c}", .{ch});
    }
    emit("\"", .{});
}

fn readFile(path: [*:0]const u8) []const u8 {
    var contents: [*c]u8 = null;
    var n: usize = 0;
    if (c.g_file_get_contents(path, &contents, &n, null) == 0) std.process.exit(1);
    return contents[0..n];
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn getTypeNames(text: []const u8, names: *std.ArrayList([]const u8)) void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "GType")) |at| {
        i = at + 5;
        if (at > 0 and isIdent(text[at - 1])) continue;
        var j = i;
        if (j >= text.len or !std.ascii.isWhitespace(text[j])) continue;
        while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
        const start = j;
        while (j < text.len and isIdent(text[j])) j += 1;
        const name = text[start..j];
        if (!std.mem.endsWith(u8, name, "_get_type")) continue;
        while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
        if (!std.mem.startsWith(u8, text[j..], "(void)")) continue;
        names.append(std.heap.c_allocator, name) catch unreachable;
    }
}

fn enums(header: [*:0]const u8, libname: [*:0]const u8) void {
    var names = std.ArrayList([]const u8).empty;
    getTypeNames(readFile(header), &names);
    const lib = c.dlopen(libname, c.RTLD_NOW);
    emit("const c = @import(\"c.zig\").c;\nconst gtype = @import(\"gtype.zig\");\n", .{});
    for (names.items) |fname| {
        const z = std.heap.c_allocator.dupeZ(u8, fname) catch unreachable;
        const sym = c.dlsym(lib, z) orelse continue;
        const f: *const fn () callconv(.c) c.GType = @ptrCast(sym);
        const t = f();
        const fund = c.g_type_fundamental(t) >> 2;
        const base = fname[0 .. fname.len - "_get_type".len];
        const klass = c.g_type_class_ref(t);
        if (fund == 12) {
            const k: *c.GEnumClass = @ptrCast(@alignCast(klass));
            emit("\nvar {s}_values = [_]c.GEnumValue{{\n", .{base});
            for (0..k.n_values) |v| {
                emit("    .{{ .value = {d}, .value_name = ", .{k.values[v].value});
                zstr(std.mem.span(k.values[v].value_name));
                emit(", .value_nick = ", .{});
                zstr(std.mem.span(k.values[v].value_nick));
                emit(" }},\n", .{});
            }
        } else if (fund == 13) {
            const k: *c.GFlagsClass = @ptrCast(@alignCast(klass));
            emit("\nvar {s}_values = [_]c.GFlagsValue{{\n", .{base});
            for (0..k.n_values) |v| {
                emit("    .{{ .value = {d}, .value_name = ", .{k.values[v].value});
                zstr(std.mem.span(k.values[v].value_name));
                emit(", .value_nick = ", .{});
                zstr(std.mem.span(k.values[v].value_nick));
                emit(" }},\n", .{});
            }
        } else continue;
        emit("    .{{ .value = 0, .value_name = null, .value_nick = null }},\n}};\n", .{});
        emit("var {s}_once: gtype.Once = .{{}};\n", .{base});
        emit("fn {s}_register() c.GType {{\n", .{base});
        emit("    return c.{s}(\"{s}\", &{s}_values);\n}}\n", .{ if (fund == 12) "g_enum_register_static" else "g_flags_register_static", std.mem.span(c.g_type_name(t)), base });
        emit("pub export fn {s}() c.GType {{\n    return {s}_once.get({s}_register);\n}}\n", .{ fname, base, base });
    }
}

fn errors() void {
    emit("pub const Entry = struct {{ domain: []const u8, code: c_int, text: ?[:0]const u8 }};\n\npub const entries = [_]Entry{{\n", .{});
    const domains = [_]struct { name: []const u8, q: c.GQuark, n: c_int }{
        .{ .name = "core", .q = c.gst_core_error_quark(), .n = c.GST_CORE_ERROR_NUM_ERRORS },
        .{ .name = "library", .q = c.gst_library_error_quark(), .n = c.GST_LIBRARY_ERROR_NUM_ERRORS },
        .{ .name = "resource", .q = c.gst_resource_error_quark(), .n = c.GST_RESOURCE_ERROR_NUM_ERRORS },
        .{ .name = "stream", .q = c.gst_stream_error_quark(), .n = c.GST_STREAM_ERROR_NUM_ERRORS },
    };
    for (domains) |d| {
        var i: c_int = 0;
        while (i <= d.n) : (i += 1) {
            const m = c.gst_error_get_message(d.q, i);
            const text = std.mem.span(m);
            emit("    .{{ .domain = ", .{});
            zstr(d.name);
            emit(", .code = {d}, .text = ", .{i});
            if (std.mem.startsWith(u8, text, "No standard error message")) emit("null", .{}) else zstr(text);
            emit(" }},\n", .{});
            c.g_free(m);
        }
    }
    emit("}};\n", .{});
}

fn fill(v: *c.GValue, t: c.GType, which: c_int) void {
    _ = c.g_value_init(v, t);
    if (t == c.G_TYPE_STRING) {
        c.g_value_set_string(v, if (which != 0) "b" else "a");
    } else if (t == c.G_TYPE_UINT) {
        c.g_value_set_uint(v, @intCast(which + 1));
    } else if (t == c.G_TYPE_UINT64) {
        c.g_value_set_uint64(v, @intCast(which + 1));
    } else if (t == c.G_TYPE_DOUBLE) {
        c.g_value_set_double(v, @as(f64, @floatFromInt(which)) + 1.5);
    } else if (t == c.g_date_get_type()) {
        c.g_value_take_boxed(v, c.g_date_new_dmy(@intCast(1 + which), 2, 2000));
    } else if (t == c.gst_date_time_get_type()) {
        c.g_value_take_boxed(v, c.gst_date_time_new_ymd(2000 + which, 1, 1));
    } else if (t == c.gst_sample_get_type()) {
        const b = c.gst_buffer_new_allocate(null, @intCast(1 + which), null);
        _ = c.gst_buffer_memset(b, 0, @intCast(which), @intCast(1 + which));
        c.g_value_take_boxed(v, c.gst_sample_new(b, null, null, null));
        c.gst_buffer_unref(b);
    } else std.process.exit(2);
}

const TypeExpr = struct { name: []const u8, expr: []const u8 };
const TYPE_EXPRS = [_]TypeExpr{
    .{ .name = "gchararray", .expr = "c.G_TYPE_STRING" },
    .{ .name = "guint", .expr = "c.G_TYPE_UINT" },
    .{ .name = "gdouble", .expr = "c.G_TYPE_DOUBLE" },
    .{ .name = "guint64", .expr = "c.G_TYPE_UINT64" },
    .{ .name = "GDate", .expr = "c.g_date_get_type()" },
    .{ .name = "GstDateTime", .expr = "c.gst_date_time_get_type()" },
    .{ .name = "GstSample", .expr = "c.gst_sample_get_type()" },
};

fn tags(header: [*:0]const u8) void {
    const text = readFile(header);
    var names = std.ArrayList([]const u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "#define GST_TAG_")) continue;
        var j: usize = "#define ".len;
        while (j < line.len and isIdent(line[j])) j += 1;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        if (j >= line.len or line[j] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, line, j + 1, '"') orelse continue;
        names.append(std.heap.c_allocator, line[j + 1 .. end]) catch unreachable;
    }
    var seen = std.ArrayList([]const u8).empty;
    var heads = std.ArrayList(u8).empty;
    const Row = struct { name: []const u8, t: usize, nick: []const u8, blurb: []const u8, flag: c.GstTagFlag, merge: []const u8 };
    var rows = std.ArrayList(Row).empty;
    for (names.items) |name| {
        const z = std.heap.c_allocator.dupeZ(u8, name) catch unreachable;
        if (c.gst_tag_exists(z) == 0) continue;
        const t = c.gst_tag_get_type(z);
        var a = std.mem.zeroes(c.GValue);
        var b = std.mem.zeroes(c.GValue);
        var o = std.mem.zeroes(c.GValue);
        fill(&a, t, 0);
        fill(&b, t, 1);
        const l = c.gst_tag_list_new_empty();
        c.gst_tag_list_add_value(l, c.GST_TAG_MERGE_APPEND, z, &a);
        c.gst_tag_list_add_value(l, c.GST_TAG_MERGE_APPEND, z, &b);
        _ = c.gst_tag_list_copy_value(&o, l, z);
        const merge: []const u8 = if (c.gst_tag_is_fixed(z) != 0) ".none" else if (o.g_type == c.gst_value_list_get_type()) std.process.exit(3) else if (t == c.G_TYPE_STRING and std.mem.eql(u8, std.mem.span(c.g_value_get_string(&o)), "a, b")) ".comma" else if (c.gst_value_compare(&o, &a) == c.GST_VALUE_EQUAL) ".first" else std.process.exit(4);
        const tname = std.mem.span(c.g_type_name(t));
        var idx: ?usize = null;
        for (seen.items, 0..) |s, k| {
            if (std.mem.eql(u8, s, tname)) idx = k;
        }
        if (idx == null) {
            idx = seen.items.len;
            seen.append(std.heap.c_allocator, tname) catch unreachable;
            var expr: []const u8 = "";
            for (TYPE_EXPRS) |te| {
                if (std.mem.eql(u8, te.name, tname)) expr = te.expr;
            }
            const s = std.fmt.allocPrint(std.heap.c_allocator, "fn t{d}() c.GType {{\n    return {s};\n}}\n\n", .{ idx.?, expr }) catch unreachable;
            heads.appendSlice(std.heap.c_allocator, s) catch unreachable;
        }
        rows.append(std.heap.c_allocator, .{ .name = name, .t = idx.?, .nick = std.mem.span(c.gst_tag_get_nick(z)), .blurb = std.mem.span(c.gst_tag_get_description(z)), .flag = c.gst_tag_get_flag(z), .merge = merge }) catch unreachable;
        c.g_value_unset(&a);
        c.g_value_unset(&b);
        c.g_value_unset(&o);
        c.gst_tag_list_unref(l);
    }
    emit("const c = @import(\"c.zig\").c;\n\npub const Merge = enum {{ none, first, comma }};\n\n", .{});
    emit("pub const Def = struct {{ name: [:0]const u8, flag: c.GstTagFlag, t: *const fn () c.GType, nick: [:0]const u8, blurb: [:0]const u8, merge: Merge }};\n\n", .{});
    emit("{s}", .{heads.items});
    emit("pub const defs = [_]Def{{\n", .{});
    for (rows.items) |r| {
        emit("    .{{ .name = ", .{});
        zstr(r.name);
        emit(", .flag = {d}, .t = t{d}, .nick = ", .{ r.flag, r.t });
        zstr(r.nick);
        emit(", .blurb = ", .{});
        zstr(r.blurb);
        emit(", .merge = {s} }},\n", .{r.merge});
    }
    emit("}};\n", .{});
}

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(std.heap.c_allocator) catch unreachable;
    c.gst_init(null, null);
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "enums")) enums(args[2].ptr, args[3].ptr) else if (std.mem.eql(u8, cmd, "errors")) errors() else if (std.mem.eql(u8, cmd, "tags")) tags(args[2].ptr) else std.process.exit(1);
    _ = std.c.write(1, &buf, len);
}
