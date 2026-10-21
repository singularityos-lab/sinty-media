const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

var seed: u32 = 3;

fn rnd() u8 {
    seed = seed *% 1103515245 +% 12345;
    return @truncate(seed >> 16);
}

fn fnv(b: []const u8) u32 {
    var h: u32 = 2166136261;
    for (b) |x| h = (h ^ x) *% 16777619;
    return h;
}

var line: [16384]u8 = undefined;

fn parseAll(p: ?*c.GstVideoVBIParser) void {
    var anc: c.GstVideoAncillary = undefined;
    var n: usize = 0;
    while (n < 40) : (n += 1) {
        const r = c.gst_video_vbi_parser_get_ancillary(p, &anc);
        if (r != c.GST_VIDEO_VBI_PARSER_RESULT_OK) {
            out("    end {d}", .{r});
            break;
        }
        out("    anc {d} {d} {d} {x}", .{ anc.DID, anc.SDID_block_number, anc.data_count, fnv(anc.data[0..256]) });
    }
}

fn vbi() void {
    out("vbi", .{});
    for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_v210 }) |f| for ([_]u32{ 64, 720, 1280, 1920 }) |w| {
        out("  fmt {d} w {d}", .{ f, w });
        const e = c.gst_video_vbi_encoder_new(f, w);
        var data: [256]u8 = undefined;
        for (&data) |*d| d.* = rnd();
        var k: u32 = 0;
        while (k < 12) : (k += 1) {
            const ok = c.gst_video_vbi_encoder_add_ancillary(e, @intFromBool(k % 2 == 0), @truncate(0x41 + k), @truncate(k * 7), &data, (k * 37) % 200);
            out("    add {d}: {d}", .{ k, ok });
        }
        const e2 = c.gst_video_vbi_encoder_copy(e);
        @memset(&line, 0xcd);
        c.gst_video_vbi_encoder_write_line(e, &line);
        out("    line {x}", .{fnv(&line)});
        @memset(&line, 0xcd);
        c.gst_video_vbi_encoder_write_line(e2, &line);
        out("    line copy {x}", .{fnv(&line)});
        c.gst_video_vbi_encoder_write_line(e, &line);
        out("    empty write {x}", .{fnv(&line)});
        c.gst_video_vbi_encoder_free(e2);
        c.gst_video_vbi_encoder_free(e);
        const p = c.gst_video_vbi_parser_new(f, w);
        c.gst_video_vbi_parser_add_line(p, &line);
        parseAll(p);
        for (0..3) |round| {
            for (&line) |*b| b.* = rnd();
            if (round == 1) {
                for (0..@min(line.len, 600)) |i| line[i] = if (i % 3 == 0) 0 else 0xff;
            }
            if (round == 2) {
                const e3 = c.gst_video_vbi_encoder_new(f, w);
                _ = c.gst_video_vbi_encoder_add_ancillary(e3, 0, 0x61, 0x02, &data, 9);
                c.gst_video_vbi_encoder_write_line(e3, &line);
                c.gst_video_vbi_encoder_free(e3);
                line[40] ^= 1;
            }
            c.gst_video_vbi_parser_add_line(p, &line);
            const pc = c.gst_video_vbi_parser_copy(p);
            parseAll(p);
            parseAll(pc);
            c.gst_video_vbi_parser_free(pc);
        }
        c.gst_video_vbi_parser_free(p);
    };
    out("  bad {d} {d}", .{ @intFromBool(c.gst_video_vbi_parser_new(c.GST_VIDEO_FORMAT_I420, 720) == null), @intFromBool(c.gst_video_vbi_encoder_new(c.GST_VIDEO_FORMAT_v210, 0) == null) });
    out("  types {s} {s}", .{ c.g_type_name(c.gst_video_vbi_parser_get_type()), c.g_type_name(c.gst_video_vbi_encoder_get_type()) });
}

fn metas() void {
    out("metas", .{});
    const b = c.gst_buffer_new().?;
    var data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    for (0..6) |t| {
        const m = c.gst_buffer_add_video_caption_meta(b, @intCast(t), &data, 5 + t);
        out("  caption {d}: {d}", .{ t, @intFromBool(m != null) });
    }
    _ = c.gst_buffer_add_video_caption_meta(b, 1, &data, 0);
    const cp = c.gst_buffer_copy(b);
    var st: c.gpointer = null;
    while (c.gst_buffer_iterate_meta_filtered(cp, &st, c.gst_video_caption_meta_api_get_type())) |m| {
        const cm: *c.GstVideoCaptionMeta = @ptrCast(@alignCast(m));
        out("  copied caption {d} {d} {any}", .{ cm.caption_type, cm.size, cm.data[0..cm.size] });
    }
    for (0..6) |t| {
        const caps = c.gst_video_caption_type_to_caps(@intCast(t));
        if (caps == null) {
            out("  to caps {d}: null", .{t});
            continue;
        }
        const s = c.gst_caps_to_string(caps);
        out("  to caps {d}: {s} back {d}", .{ t, s, c.gst_video_caption_type_from_caps(caps) });
        c.g_free(s);
        c.gst_caps_unref(caps);
    }
    for ([_][*:0]const u8{ "closedcaption/x-cea-608, format=foo", "closedcaption/x-cea-708", "video/x-raw", "closedcaption/x-cea-608, format={raw, s334-1a}" }) |str| {
        const caps = c.gst_caps_from_string(str);
        out("  from {s}: {d}", .{ str, c.gst_video_caption_type_from_caps(caps) });
        c.gst_caps_unref(caps);
    }
    const a = c.gst_buffer_add_ancillary_meta(b);
    out("  anc init {d} {d} {d} {d} {d}", .{ a[0].field, a[0].line, a[0].offset, a[0].DID, @intFromBool(a[0].data == null) });
    a[0].DID = 0x61;
    a[0].SDID_block_number = 0x101;
    a[0].data_count = 0x103;
    a[0].line = 9;
    a[0].checksum = 77;
    const ad: [*]u16 = @ptrCast(@alignCast(c.g_malloc(6).?));
    ad[0..3].* = .{ 5, 6, 7 };
    a[0].data = ad;
    for ([_]u8{ 0, 1, 2 }) |field| for ([_]c.GstVideoAFDSpec{ 0, 1, 2, 3 }) |spec| for ([_]c.GstVideoAFDValue{ 0, 1, 2, 4, 5, 8, 12, 15, 16, 255 }) |v| {
        const m = c.gst_buffer_add_video_afd_meta(b, field, spec, v);
        out("  afd {d} {d} {d}: {d}", .{ field, spec, v, @intFromBool(m != null) });
    };
    out("  bar {d} {d}", .{ @intFromBool(c.gst_buffer_add_video_bar_meta(b, 1, 1, 10, 20) != null), @intFromBool(c.gst_buffer_add_video_bar_meta(b, 2, 0, 1, 2) != null) });
    var uuid = [16]u8{ 0x4D, 0x49, 0x53, 0x50, 0x6D, 0x69, 0x63, 0x72, 0x6F, 0x73, 0x65, 0x63, 0x74, 0x69, 0x6D, 0x65 };
    const sm = c.gst_buffer_add_video_sei_user_data_unregistered_meta(b, &uuid, &data, 14);
    var status: u8 = 0;
    var pts: u64 = 0;
    out("  sei parse {d} {d} {d}", .{ c.gst_video_sei_user_data_unregistered_parse_precision_time_stamp(sm, &status, &pts), status, pts });
    sm[0].size = 11;
    out("  sei short {d}", .{c.gst_video_sei_user_data_unregistered_parse_precision_time_stamp(sm, &status, &pts)});
    sm[0].size = 14;
    sm[0].uuid[3] = 0;
    out("  sei uuid {d}", .{c.gst_video_sei_user_data_unregistered_parse_precision_time_stamp(sm, &status, &pts)});
    const cp2 = c.gst_buffer_copy(b);
    st = null;
    while (c.gst_buffer_iterate_meta(cp2, &st)) |m| {
        const api = m[0].info[0].api;
        if (api == c.gst_ancillary_meta_api_get_type()) {
            const q: *c.GstAncillaryMeta = @ptrCast(@alignCast(m));
            out("  copy anc {d} {d} {d} {d} {d} {any}", .{ q.field, q.line, q.DID, q.SDID_block_number, q.checksum, q.data[0..3] });
        } else if (api == c.gst_video_afd_meta_api_get_type()) {
            const q: *c.GstVideoAFDMeta = @ptrCast(@alignCast(m));
            out("  copy afd {d} {d} {d}", .{ q.field, q.spec, q.afd });
        } else if (api == c.gst_video_bar_meta_api_get_type()) {
            const q: *c.GstVideoBarMeta = @ptrCast(@alignCast(m));
            out("  copy bar {d} {d} {d} {d}", .{ q.field, q.is_letterbox, q.bar_data1, q.bar_data2 });
        } else if (api == c.gst_video_sei_user_data_unregistered_meta_api_get_type()) {
            const q: *c.GstVideoSEIUserDataUnregisteredMeta = @ptrCast(@alignCast(m));
            out("  copy sei {any} {any}", .{ q.uuid, q.data[0..q.size] });
        } else {
            out("  copy other {s}", .{c.g_type_name(api)});
        }
    }
    var ii: c.GstVideoInfo = undefined;
    var oi: c.GstVideoInfo = undefined;
    const afd = c.gst_buffer_get_meta(b, c.gst_video_afd_meta_api_get_type());
    for ([_][4]c.guint{ .{ 320, 240, 640, 480 }, .{ 320, 240, 640, 360 }, .{ 1920, 1080, 1280, 720 } }) |sz| {
        _ = c.gst_video_info_set_format(&ii, c.GST_VIDEO_FORMAT_I420, sz[0], sz[1]);
        _ = c.gst_video_info_set_format(&oi, c.GST_VIDEO_FORMAT_I420, sz[2], sz[3]);
        var t = c.GstVideoMetaTransform{ .in_info = &ii, .out_info = &oi };
        const d = c.gst_buffer_new();
        const r = afd[0].info[0].transform_func.?(d, afd, b, c.gst_video_meta_transform_scale_get_quark(), &t);
        out("  afd scale {any}: {d} {d}", .{ sz, r, @intFromBool(c.gst_buffer_get_meta(d, c.gst_video_afd_meta_api_get_type()) != null) });
        c.gst_buffer_unref(d);
    }
    for ([_]c.GType{ c.gst_video_caption_meta_api_get_type(), c.gst_ancillary_meta_api_get_type(), c.gst_video_afd_meta_api_get_type(), c.gst_video_bar_meta_api_get_type(), c.gst_video_sei_user_data_unregistered_meta_api_get_type() }) |api| {
        out("  api {s} video {d} size {d}", .{ c.g_type_name(api), c.gst_meta_api_type_has_tag(api, c.g_quark_from_string("video")), c.gst_meta_api_type_has_tag(api, c.g_quark_from_string("size")) });
    }
    out("  infos {s} {s} {s} {s} {s}", .{ c.g_type_name(c.gst_video_caption_meta_get_info()[0].type), c.g_type_name(c.gst_ancillary_meta_get_info()[0].type), c.g_type_name(c.gst_video_afd_meta_get_info()[0].type), c.g_type_name(c.gst_video_bar_meta_get_info()[0].type), c.g_type_name(c.gst_video_sei_user_data_unregistered_meta_get_info()[0].type) });
    c.gst_buffer_unref(cp2);
    c.gst_buffer_unref(cp);
    c.gst_buffer_unref(b);
}

pub fn main() void {
    c.gst_init(null, null);
    vbi();
    metas();
}
