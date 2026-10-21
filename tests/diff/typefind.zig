const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn show(label: []const u8, caps: [*c]c.GstCaps, prob: c.GstTypeFindProbability) void {
    if (caps == null) {
        out("{s}: none prob {d}", .{ label, prob });
        return;
    }
    const s = c.gst_caps_to_string(caps);
    out("{s}: {s} prob {d}", .{ label, std.mem.span(s), prob });
    c.g_free(s);
    c.gst_caps_unref(caps);
}

const PNG = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 16, 0, 0, 0, 16, 8, 6, 0, 0, 0 };

fn wav() [44 + 64]u8 {
    var w = [_]u8{0} ** (44 + 64);
    @memcpy(w[0..4], "RIFF");
    std.mem.writeInt(u32, w[4..8], 36 + 64, .little);
    @memcpy(w[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, w[16..20], 16, .little);
    std.mem.writeInt(u16, w[20..22], 1, .little);
    std.mem.writeInt(u16, w[22..24], 2, .little);
    std.mem.writeInt(u32, w[24..28], 44100, .little);
    std.mem.writeInt(u32, w[28..32], 44100 * 4, .little);
    std.mem.writeInt(u16, w[32..34], 4, .little);
    std.mem.writeInt(u16, w[34..36], 16, .little);
    @memcpy(w[36..40], "data");
    std.mem.writeInt(u32, w[40..44], 64, .little);
    return w;
}

var source: []const u8 = &.{};
var pulls: u32 = 0;
var fail_after: u32 = 1000;

fn getRange(_: [*c]c.GstObject, _: [*c]c.GstObject, off: u64, len: c.guint, out_buf: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    pulls += 1;
    if (pulls > fail_after) return c.GST_FLOW_ERROR;
    if (off >= source.len) return c.GST_FLOW_EOS;
    const n = @min(len, source.len - off);
    const d: [*c]u8 = @ptrCast(c.g_memdup2(source.ptr + off, n));
    const b = c.gst_buffer_new_wrapped(d, n);
    b[0].offset = off;
    out_buf.* = b;
    return c.GST_FLOW_OK;
}

fn padRange(_: ?*c.GstPad, _: [*c]c.GstObject, off: u64, len: c.guint, out_buf: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return getRange(null, null, off, len, out_buf);
}

fn pngFind(tf: [*c]c.GstTypeFind, _: c.gpointer) callconv(.c) void {
    const d = c.gst_type_find_peek(tf, 0, 8);
    if (d != null and d[0] == 0x89 and d[1] == 'P' and d[2] == 'N' and d[3] == 'G') c.gst_type_find_suggest(tf, c.GST_TYPE_FIND_MAXIMUM, c.gst_caps_new_empty_simple("image/png"));
}

fn wavFind(tf: [*c]c.GstTypeFind, _: c.gpointer) callconv(.c) void {
    const d = c.gst_type_find_peek(tf, 0, 12);
    if (d == null or c.memcmp(d, "RIFF", 4) != 0) return;
    if (c.memcmp(d + 8, "WAVE", 4) == 0) {
        c.gst_type_find_suggest(tf, c.GST_TYPE_FIND_MAXIMUM, c.gst_caps_new_empty_simple("audio/x-wav"));
    } else {
        c.gst_type_find_suggest(tf, c.GST_TYPE_FIND_POSSIBLE, c.gst_caps_new_empty_simple("audio/x-riff"));
    }
}

fn tailFind(tf: [*c]c.GstTypeFind, _: c.gpointer) callconv(.c) void {
    const len = c.gst_type_find_get_length(tf);
    const d = c.gst_type_find_peek(tf, -4, 4);
    out("  tail finder len {d} tail {d}", .{ len, @intFromBool(d != null) });
    const far = c.gst_type_find_peek(tf, 2, 40);
    out("  far peek {d}", .{@intFromBool(far != null)});
    if (d != null and d[3] == 0x0a) c.gst_type_find_suggest(tf, c.GST_TYPE_FIND_LIKELY, c.gst_caps_new_empty_simple("x/tail"));
}

fn plugin(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    const png = c.gst_caps_new_empty_simple("image/png");
    _ = c.gst_type_find_register(p, "tfpng", c.GST_RANK_PRIMARY, pngFind, "png", png, null, null);
    _ = c.gst_type_find_register(p, "tfwav", c.GST_RANK_PRIMARY, wavFind, "wav,wave", null, null, null);
    _ = c.gst_type_find_register(p, "tftail", c.GST_RANK_MARGINAL, tailFind, "tl", null, null, null);
    const mkv = c.gst_caps_new_empty_simple("video/x-matroska");
    _ = c.gst_type_find_register(p, "tfmkv", c.GST_RANK_SECONDARY, null, "mkv,mka", mkv, null, null);
    _ = c.gst_type_find_register(p, "tfpngext", c.GST_RANK_SECONDARY, null, "png,apng", png, null, null);
    c.gst_caps_unref(png);
    c.gst_caps_unref(mkv);
    return 1;
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    _ = c.gst_plugin_register_static(1, 28, "tftest", "typefind test", plugin, "1.0", "LGPL", "x", "x", "x");
    var prob: c.GstTypeFindProbability = 0;
    const obj: [*c]c.GstObject = @ptrCast(@alignCast(c.gst_bin_new("tf")));
    show("png", c.gst_type_find_helper_for_data(obj, &PNG, PNG.len, &prob), prob);
    var w = wav();
    show("wav", c.gst_type_find_helper_for_data(obj, &w, w.len, &prob), prob);
    show("wav ext", c.gst_type_find_helper_for_data_with_extension(obj, &w, w.len, "wav", &prob), prob);
    const junk = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    show("junk", c.gst_type_find_helper_for_data(obj, &junk, junk.len, &prob), prob);
    show("empty", c.gst_type_find_helper_for_data(obj, &junk, 0, &prob), prob);
    const b = c.gst_buffer_new_wrapped(@ptrCast(c.g_memdup2(&PNG, PNG.len)), PNG.len);
    show("buffer", c.gst_type_find_helper_for_buffer(obj, b, &prob), prob);
    show("buffer ext", c.gst_type_find_helper_for_buffer_with_extension(obj, b, "png", null), 0);
    const pc = c.gst_caps_from_string("image/png");
    show("buffer caps", c.gst_type_find_helper_for_buffer_with_caps(obj, b, pc, &prob), prob);
    show("data caps", c.gst_type_find_helper_for_data_with_caps(obj, &PNG, PNG.len, pc, &prob), prob);
    const vc = c.gst_caps_from_string("video/x-matroska");
    const riff = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'A', 'V', 'I', ' ', 0, 0, 0, 0 };
    show("riff", c.gst_type_find_helper_for_data(obj, &riff, riff.len, &prob), prob);
    show("riff tl", c.gst_type_find_helper_for_data_with_extension(obj, &riff, riff.len, "tl", &prob), prob);
    show("data caps mkv", c.gst_type_find_helper_for_data_with_caps(obj, &PNG, PNG.len, vc, &prob), prob);
    const lf = c.gst_type_find_list_factories_for_caps(obj, vc);
    out("factories for mkv {d}", .{c.g_list_length(lf)});
    c.g_list_free_full(lf, c.gst_object_unref);
    c.gst_caps_unref(pc);
    c.gst_caps_unref(vc);
    b[0].offset = 5;
    show("buffer offset", c.gst_type_find_helper_for_buffer(obj, b, &prob), prob);
    c.gst_buffer_unref(b);
    for ([_][*:0]const u8{ "mka", "mkv", "png", "apng", "nosuch", "wav" }) |e| show(std.mem.span(e), c.gst_type_find_helper_for_extension(obj, e), 0);

    source = &w;
    var caps: [*c]c.GstCaps = null;
    var r = c.gst_type_find_helper_get_range_full(obj, null, getRange, w.len, null, &caps, &prob);
    out("range flow {d} pulls {d}", .{ r, pulls });
    show("range", caps, prob);
    pulls = 0;
    show("range no size", c.gst_type_find_helper_get_range(obj, null, getRange, 0, "wav", &prob), prob);
    out("pulls {d}", .{pulls});
    source = &junk;
    pulls = 0;
    r = c.gst_type_find_helper_get_range_full(obj, null, getRange, junk.len, null, &caps, &prob);
    out("junk range flow {d} caps null {d} prob {d}", .{ r, @intFromBool(caps == null), prob });
    source = &PNG;
    pulls = 0;
    fail_after = 0;
    r = c.gst_type_find_helper_get_range_full(obj, null, getRange, PNG.len, null, &caps, &prob);
    out("error range flow {d} caps null {d} prob {d} pulls {d}", .{ r, @intFromBool(caps == null), prob, pulls });
    fail_after = 1000;
    const pad = c.gst_pad_new("src", c.GST_PAD_SRC);
    c.gst_pad_set_getrange_function_full(pad, padRange, null, null);
    show("pad", c.gst_type_find_helper(pad, PNG.len), 0);
    c.gst_object_unref(pad);
    const nopad = c.gst_pad_new("x", c.GST_PAD_SRC);
    show("crit pad", c.gst_type_find_helper(nopad, 1), 0);
    c.gst_object_unref(nopad);
    out("crit {d}", .{c.gst_type_find_helper_get_range_full(null, null, getRange, 1, null, &caps, null)});
    out("crit {d}", .{c.gst_type_find_helper_get_range_full(obj, null, null, 1, null, &caps, null)});
    out("crit {d}", .{c.gst_type_find_helper_get_range_full(obj, null, getRange, 1, null, null, null)});
    show("crit data", c.gst_type_find_helper_for_data(obj, null, 1, null), 0);
    show("crit ext", c.gst_type_find_helper_for_extension(obj, null), 0);
    show("crit buffer", c.gst_type_find_helper_for_buffer(obj, null, null), 0);
    show("crit caps", c.gst_type_find_helper_for_data_with_caps(obj, &PNG, 0, null, null), 0);
    out("crit list {d}", .{@intFromBool(c.gst_type_find_list_factories_for_caps(obj, null) == null)});
    c.gst_object_unref(obj);
    out("done", .{});
}
