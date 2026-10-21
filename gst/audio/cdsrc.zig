const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const enums = @import("enumtypes.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Src = c.GstAudioCdSrc;
const Class = c.GstAudioCdSrcClass;
const Track = c.GstAudioCdSrcTrack;
const PATH = "../gst-libs/gst/audio/gstaudiocdsrc.c";
const DEFAULT_DEVICE = "/dev/cdrom";
const SAMPLES_PER_SECTOR: i64 = 2352 >> 2;
const SECTORS_PER_SECOND: c.guint = 75;
const SECTORS_PER_MINUTE: c.guint = 75 * 60;
const MSF_OFFSET: c.guint = 150;
const NONE: u64 = std.math.maxInt(u64);

const Private = struct {
    mode: c.GstAudioCdSrcMode,
    device: [*c]u8,
    num_tracks: c.guint,
    num_all_tracks: c.guint,
    tracks: [*c]Track,
    cur_track: c.gint,
    prev_track: c.gint,
    cur_sector: c.gint,
    seek_sector: c.gint,
    uri_track: c.gint,
    uri: [*c]u8,
    discid: u32,
    mb_discid: [32]u8,
    toc_offset: c.gint,
    toc_bias: c.gboolean,
    toc_event: [*c]c.GstEvent,
    toc: ?*c.GstToc,
};

var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*c.GstBaseSrcClass = null;
var track_format: c.GstFormat = 0;
var sector_format: c.GstFormat = 0;
var templ = c.GstStaticPadTemplate{ .name_template = "src", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "audio/x-raw, format = (string) S16LE, layout = (string) interleaved, rate = (int) 44100, channels = (int) 2", ._gst_reserved = .{ null, null, null, null } } };

fn of(p: anytype) [*c]Src {
    return @ptrCast(@alignCast(p));
}

fn priv(p: anytype) *Private {
    return @ptrCast(@alignCast(of(p).*.priv));
}

fn klass(p: anytype) *Class {
    return gtype.classPeek(Class, p);
}

fn started(p: anytype) bool {
    return el.flags(p) & c.GST_BASE_SRC_FLAG_STARTED != 0;
}

fn srcPad(p: anytype) ?*c.GstPad {
    return @as([*c]c.GstBaseSrc, @ptrCast(@alignCast(p))).*.srcpad;
}

fn setDevice(s: [*c]Src, device_in: [*c]const u8) void {
    const r = priv(s);
    c.g_free(r.device);
    r.device = null;
    if (device_in == null) return;
    var device = device_in;
    while (device[0] == '/' and device[1] == '/') device += 1;
    r.device = c.g_strdup(device);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    const r = priv(s);
    el.lock(s);
    defer el.unlock(s);
    switch (id) {
        1 => r.mode = @bitCast(c.g_value_get_enum(v)),
        2 => setDevice(s, c.g_value_get_string(v)),
        3 => {
            const track = c.g_value_get_uint(v);
            if (r.num_tracks > 0 and track > r.num_tracks) {
                c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Invalid track %u", track);
            } else if (track > 0 and r.tracks != null) {
                r.cur_sector = @intCast(r.tracks[track - 1].start);
                r.uri_track = @intCast(track);
            } else r.uri_track = @intCast(track);
        },
        4 => r.toc_offset = c.g_value_get_int(v),
        5 => r.toc_bias = c.g_value_get_boolean(v),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 391),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    const r = priv(s);
    el.lock(s);
    defer el.unlock(s);
    switch (id) {
        1 => c.g_value_set_enum(v, @bitCast(r.mode)),
        2 => c.g_value_set_string(v, if (r.device == null) DEFAULT_DEVICE else r.device),
        3 => c.g_value_set_uint(v, if (r.num_tracks <= 0 and r.uri_track > 0) @intCast(r.uri_track) else @bitCast(r.cur_track + 1)),
        4 => c.g_value_set_int(v, r.toc_offset),
        5 => c.g_value_set_boolean(v, r.toc_bias),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 447),
    }
}

fn trackFromSector(s: [*c]Src, sector: i64) c.gint {
    const r = priv(s);
    var i: c.guint = 0;
    while (i < r.num_tracks) : (i += 1) {
        if (sector >= r.tracks[i].start and sector <= r.tracks[i].end) return @intCast(i);
    }
    return -1;
}

fn convert(s: [*c]Src, src_fmt_in: c.GstFormat, src_val_in: i64, dest_fmt: c.GstFormat, dest: *i64) bool {
    var src_fmt = src_fmt_in;
    var src_val = src_val_in;
    if (src_fmt == dest_fmt) {
        dest.* = src_val;
        return true;
    }
    const st = started(s);
    const r = priv(s);
    if (src_fmt == track_format) {
        if (!st) return false;
        if (src_val < 0 or src_val >= r.num_tracks) return false;
        src_fmt = c.GST_FORMAT_DEFAULT;
        src_val = @as(i64, r.tracks[@intCast(src_val)].start) * SAMPLES_PER_SECTOR;
    } else if (src_fmt == sector_format) {
        src_fmt = c.GST_FORMAT_DEFAULT;
        src_val = src_val *% SAMPLES_PER_SECTOR;
    }
    if (src_fmt == dest_fmt) {
        dest.* = src_val;
        return true;
    }
    switch (src_fmt) {
        c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT => {
            if (src_fmt == c.GST_FORMAT_BYTES) src_val = src_val >> 2;
            switch (dest_fmt) {
                c.GST_FORMAT_BYTES => {
                    if (src_val < 0) return false;
                    dest.* = src_val << 2;
                },
                c.GST_FORMAT_TIME => dest.* = @bitCast(c.gst_util_uint64_scale_int(@bitCast(src_val), c.GST_SECOND, 44100)),
                else => {
                    const sector = @divTrunc(src_val, SAMPLES_PER_SECTOR);
                    if (dest_fmt == sector_format) {
                        dest.* = sector;
                    } else if (dest_fmt == track_format) {
                        if (!st) return false;
                        dest.* = trackFromSector(s, sector);
                    } else return false;
                },
            }
        },
        c.GST_FORMAT_TIME => {
            if (@as(u64, @bitCast(src_val)) == NONE) return false;
            const so: i64 = @bitCast(c.gst_util_uint64_scale_int(@bitCast(src_val), 44100, c.GST_SECOND));
            switch (dest_fmt) {
                c.GST_FORMAT_BYTES => dest.* = so << 2,
                c.GST_FORMAT_DEFAULT => dest.* = so,
                else => {
                    const sector = @divTrunc(so, SAMPLES_PER_SECTOR);
                    if (dest_fmt == sector_format) {
                        dest.* = sector;
                    } else if (dest_fmt == track_format) {
                        if (!st) return false;
                        dest.* = trackFromSector(s, sector);
                    } else return false;
                },
            }
        },
        else => return false,
    }
    return true;
}

fn assertTracks(r: *Private, line: c.gint) void {
    if (r.tracks == null) c.g_assertion_message_expr(check.DOMAIN, PATH, line, "gst_audio_cd_src_query", "src->priv->tracks != NULL");
}

fn query(b: [*c]c.GstBaseSrc, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = of(b);
    const r = priv(s);
    const st = started(b);
    switch (q.*.type) {
        c.GST_QUERY_DURATION => {
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_duration(q, &fmt, null);
            if (!st) return 0;
            assertTracks(r, 630);
            if (fmt == track_format) {
                c.gst_query_set_duration(q, track_format, r.num_tracks);
                return 1;
            }
            if (r.cur_track < 0 or r.cur_track >= r.num_tracks) return 0;
            const t: usize = @intCast(r.cur_track);
            const sectors: c.guint = if (r.mode == c.GST_AUDIO_CD_SRC_MODE_NORMAL) r.tracks[t].end -% r.tracks[t].start +% 1 else r.tracks[r.num_tracks - 1].end -% r.tracks[0].start +% 1;
            var v: i64 = 0;
            if (!convert(s, sector_format, sectors, fmt, &v)) return 0;
            c.gst_query_set_duration(q, fmt, v);
            return 1;
        },
        c.GST_QUERY_POSITION => {
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_position(q, &fmt, null);
            if (!st) return 0;
            assertTracks(r, 672);
            if (fmt == track_format) {
                c.gst_query_set_position(q, track_format, r.cur_track);
                return 1;
            }
            if (r.cur_track < 0 or r.cur_track >= r.num_tracks) return 0;
            const t: usize = @intCast(r.cur_track);
            const pos: i64 = if (r.mode == c.GST_AUDIO_CD_SRC_MODE_NORMAL) @as(i64, r.cur_sector) - r.tracks[t].start else @as(i64, r.cur_sector) - r.tracks[0].start;
            var v: i64 = 0;
            if (!convert(s, sector_format, pos, fmt, &v)) return 0;
            c.gst_query_set_position(q, fmt, v);
            return 1;
        },
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            c.gst_query_parse_convert(q, &sf, &sv, &df, null);
            var dv: i64 = 0;
            if (!convert(s, sf, sv, df, &dv)) return 0;
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return 1;
        },
        else => return parent.?.query.?(b, q),
    }
}

fn isSeekable(_: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return 1;
}

fn doSeek(b: [*c]c.GstBaseSrc, segment: [*c]c.GstSegment) callconv(.c) c.gboolean {
    const s = of(b);
    const r = priv(s);
    var sector: i64 = 0;
    if (!convert(s, c.GST_FORMAT_TIME, @bitCast(segment.*.start), sector_format, &sector)) return 0;
    if (!(r.cur_track >= 0 and r.cur_track < r.num_tracks)) c.g_assertion_message_expr(check.DOMAIN, PATH, 749, "gst_audio_cd_src_do_seek", "src->priv->cur_track >= 0 && src->priv->cur_track < src->priv->num_tracks");
    switch (r.mode) {
        c.GST_AUDIO_CD_SRC_MODE_NORMAL => sector += r.tracks[@intCast(r.cur_track)].start,
        c.GST_AUDIO_CD_SRC_MODE_CONTINUOUS => sector += r.tracks[0].start,
        else => {
            check.reached("gstaudiocdsrc.c", 760, "gst_audio_cd_src_do_seek");
            return 0;
        },
    }
    r.cur_sector = @truncate(sector);
    return 1;
}

fn updateDuration(s: [*c]Src) void {
    var dur: i64 = 0;
    if (c.gst_pad_query_duration(srcPad(s), c.GST_FORMAT_TIME, &dur) == 0) dur = -1;
    @as([*c]c.GstBaseSrc, @ptrCast(@alignCast(s))).*.segment.duration = @bitCast(dur);
    _ = c.gst_element_post_message(@ptrCast(s), c.gst_message_new_duration_changed(@ptrCast(s)));
}

fn endpoint(s: [*c]Src, kind: c.GstSeekType, val: i64, out: *i64, reached_line: c.gint) ?c.GstSeekType {
    const r = priv(s);
    switch (kind) {
        c.GST_SEEK_TYPE_SET => {
            if (!convert(s, track_format, val, c.GST_FORMAT_TIME, out)) return null;
            return kind;
        },
        c.GST_SEEK_TYPE_END => {
            if (!convert(s, track_format, @as(i64, r.num_tracks) - val - 1, c.GST_FORMAT_TIME, out)) return null;
            return c.GST_SEEK_TYPE_SET;
        },
        c.GST_SEEK_TYPE_NONE => {
            out.* = -1;
            return kind;
        },
        else => {
            check.reached("gstaudiocdsrc.c", reached_line, "gst_audio_cd_src_handle_track_seek");
            return null;
        },
    }
}

fn trackSeek(s: [*c]Src, rate: f64, flags: c.GstSeekFlags, start_type: c.GstSeekType, start: i64, stop_type: c.GstSeekType, stop: i64) c.gboolean {
    const r = priv(s);
    const b: [*c]c.GstBaseSrc = @ptrCast(@alignCast(s));
    if (flags & c.GST_SEEK_FLAG_SEGMENT == c.GST_SEEK_FLAG_SEGMENT) {
        if (r.mode != c.GST_AUDIO_CD_SRC_MODE_CONTINUOUS) return 0;
        var st: i64 = -1;
        var sp: i64 = -1;
        const t1 = endpoint(s, start_type, start, &st, 811) orelse return 0;
        const t2 = endpoint(s, stop_type, stop, &sp, 837) orelse return 0;
        const e = c.gst_event_new_seek(rate, c.GST_FORMAT_TIME, flags, t1, st, t2, sp);
        const ret = parent.?.event.?(b, e);
        c.gst_mini_object_unref(@ptrCast(e));
        return ret;
    }
    if (start_type == c.GST_SEEK_TYPE_NONE) return 1;
    if (start < 0 or start >= r.num_tracks) return 0;
    r.cur_sector = @intCast(r.tracks[@intCast(start)].start);
    if (r.cur_track != start) {
        r.cur_track = @intCast(start);
        r.uri_track = -1;
        r.prev_track = -1;
        updateDuration(s);
    }
    const e = c.gst_event_new_seek(rate, c.GST_FORMAT_TIME, flags, c.GST_SEEK_TYPE_SET, 0, c.GST_SEEK_TYPE_NONE, -1);
    const ret = parent.?.event.?(b, e);
    c.gst_mini_object_unref(@ptrCast(e));
    return ret;
}

fn handleEvent(b: [*c]c.GstBaseSrc, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = of(b);
    switch (e.*.type) {
        c.GST_EVENT_SEEK => {
            if (!started(b)) return 0;
            var rate: f64 = 0;
            var fmt: c.GstFormat = 0;
            var flags: c.GstSeekFlags = 0;
            var st: c.GstSeekType = 0;
            var et: c.GstSeekType = 0;
            var start: i64 = 0;
            var stop: i64 = 0;
            c.gst_event_parse_seek(e, &rate, &fmt, &flags, &st, &start, &et, &stop);
            if (fmt == sector_format) return 0;
            if (fmt == track_format) return trackSeek(s, rate, flags, st, start, et, stop);
            return parent.?.event.?(b, e);
        },
        c.GST_EVENT_TOC_SELECT => {
            var uid: [*c]u8 = null;
            c.gst_event_parse_toc_select(e, &uid);
            var ret: c.gboolean = 0;
            if (uid != null) {
                const u = std.mem.span(uid);
                const prefix = "audiocd-track-";
                if (std.mem.startsWith(u8, u, prefix)) {
                    var n: u32 = 0;
                    var digits: usize = 0;
                    for (u[prefix.len..]) |ch| {
                        if (ch < '0' or ch > '9' or digits == 3) break;
                        n = n * 10 + (ch - '0');
                        digits += 1;
                    }
                    if (digits > 0) ret = trackSeek(s, 1.0, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, n, c.GST_SEEK_TYPE_NONE, -1);
                }
            }
            c.g_free(uid);
            return ret;
        },
        else => return parent.?.event.?(b, e),
    }
}

fn uriType(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SRC;
}

var protocols = [_][*c]const u8{ "cdda", null };

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const u8 {
    return &protocols;
}

fn getUri(h: ?*c.GstURIHandler) callconv(.c) [*c]u8 {
    const s = of(h);
    const r = priv(s);
    el.lock(s);
    c.g_free(r.uri);
    r.uri = if (started(s)) c.g_strdup_printf("cdda://%s#%d", r.device, if (r.uri_track > 0) r.uri_track else @as(c.gint, 1)) else c.g_strdup("cdda://1");
    el.unlock(s);
    return c.g_strdup(r.uri);
}

fn setUri(h: ?*c.GstURIHandler, uri: [*c]const u8, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const s = of(h);
    const r = priv(s);
    el.lock(s);
    const location = uri + 7;
    const hash = c.g_strrstr(location, "#");
    r.uri_track = 0;
    if (hash != null and hash[1] != '/') {
        const nuri = c.g_strdup(uri);
        const pos = nuri + (@intFromPtr(hash) - @intFromPtr(uri));
        pos[0] = 0;
        const device = c.gst_uri_get_location(nuri);
        setDevice(s, device);
        c.g_free(device);
        r.uri_track = @truncate(c.strtol(pos + 1, null, 10));
        c.g_free(nuri);
    } else {
        r.uri_track = if (location[0] == 0) 1 else @truncate(c.strtol(location, null, 10));
    }
    if (r.uri_track < 1 or (r.num_tracks > 0 and r.tracks != null and r.uri_track > r.num_tracks)) {
        el.unlock(s);
        c.g_set_error_literal(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_URI, "Could not handle CDDA URI");
        return 0;
    }
    el.unlock(s);
    if (r.uri_track > 0 and r.tracks != null) _ = c.gst_pad_send_event(srcPad(s), c.gst_event_new_seek(1.0, track_format, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, r.uri_track - 1, c.GST_SEEK_TYPE_NONE, -1));
    return 1;
}

fn uriInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstURIHandlerInterface = @ptrCast(@alignCast(iface));
    i.get_type = uriType;
    i.get_uri = getUri;
    i.set_uri = setUri;
    i.get_protocols = uriProtocols;
}

pub export fn gst_audio_cd_src_add_track(s: [*c]Src, track: [*c]Track) c.gboolean {
    const fname = "gst_audio_cd_src_add_track";
    if (!check.that(gtype.instanceOf(s, gst_audio_cd_src_get_type()), fname, "GST_IS_AUDIO_CD_SRC (src)")) return 0;
    if (!check.that(track != null, fname, "track != NULL")) return 0;
    if (!check.that(track.*.num > 0, fname, "track->num > 0")) return 0;
    const r = priv(s);
    if (r.num_tracks > 0 and track.*.start <= r.tracks[r.num_tracks - 1].end) return 0;
    el.lock(s);
    r.num_tracks += 1;
    r.tracks = @ptrCast(@alignCast(c.g_realloc_n(r.tracks, r.num_tracks, @sizeOf(Track))));
    r.tracks[r.num_tracks - 1] = track.*;
    el.unlock(s);
    return 1;
}

fn cddbSum(n_in: c.guint) c.guint {
    var n = n_in;
    var ret: c.guint = 0;
    while (n > 0) : (n /= 10) ret += n % 10;
    return ret;
}

fn hexInto(buf: []u8, comptime fmt: []const u8, v: c.guint) []const u8 {
    return std.fmt.bufPrint(buf, fmt, .{v}) catch unreachable;
}

fn musicbrainz(s: [*c]Src) void {
    const r = priv(s);
    const str = c.g_string_new(null);
    var last: c.guint = 0;
    var i: c.guint = 0;
    while (i < r.num_tracks) : (i += 1) {
        if (r.tracks[i].is_audio != 0) last = r.tracks[i].num;
    }
    const leadout = r.tracks[last - 1].end + 1 + MSF_OFFSET;
    const sha = c.g_checksum_new(c.G_CHECKSUM_SHA1);
    var tmp: [9]u8 = undefined;
    var t = hexInto(&tmp, "{X:0>2}", r.tracks[0].num);
    _ = c.g_string_append_len(str, t.ptr, @intCast(t.len));
    c.g_checksum_update(sha, t.ptr, 2);
    t = hexInto(&tmp, "{X:0>2}", last);
    c.g_string_append_printf(str, " %02X", last);
    c.g_checksum_update(sha, t.ptr, 2);
    t = hexInto(&tmp, "{X:0>8}", leadout);
    c.g_string_append_printf(str, " %08X", leadout);
    c.g_checksum_update(sha, t.ptr, 8);
    i = 0;
    while (i < 99) : (i += 1) {
        if (i < last) {
            const off = r.tracks[i].start + MSF_OFFSET;
            t = hexInto(&tmp, "{X:0>8}", off);
            c.g_string_append_printf(str, " %08X", off);
            c.g_checksum_update(sha, t.ptr, 8);
        } else c.g_checksum_update(sha, "00000000", 8);
    }
    var digest: [20]u8 = undefined;
    var dlen: c.gsize = 20;
    c.g_checksum_get_digest(sha, &digest, &dlen);
    const enc = c.g_base64_encode(&digest, dlen);
    c.g_checksum_free(sha);
    const n = std.mem.len(enc);
    if (!(n < r.mb_discid.len + 1)) c.g_assertion_message_expr(check.DOMAIN, PATH, 1216, "gst_audio_cd_src_calculate_musicbrainz_discid", "i < sizeof (src->priv->mb_discid) + 1");
    @memcpy(r.mb_discid[0..n], enc[0..n]);
    r.mb_discid[n] = 0;
    c.free(enc);
    for (r.mb_discid[0..n]) |*ch| {
        ch.* = switch (ch.*) {
            '/' => '_',
            '+' => '.',
            '=' => '-',
            else => ch.*,
        };
    }
    c.gst_tag_list_add(s.*.tags, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_CDDA_MUSICBRAINZ_DISCID, &r.mb_discid, c.GST_TAG_CDDA_MUSICBRAINZ_DISCID_FULL, str.*.str, @as(?*anyopaque, null));
    _ = c.g_string_free(str, 1);
}

fn secondsOf(sector: c.guint) c.guint {
    const m = sector / SECTORS_PER_MINUTE;
    return (sector % SECTORS_PER_MINUTE) / SECTORS_PER_SECOND + m * 60;
}

fn cddb(s: [*c]Src) void {
    const r = priv(s);
    var id: c.guint = 0;
    var count: c.guint = 0;
    var first: c.guint = 0;
    var last: c.guint = 0;
    var i: c.guint = 0;
    while (i < r.num_tracks) : (i += 1) {
        if (count == 0) first = r.tracks[i].start + MSF_OFFSET;
        last = r.tracks[i].end + MSF_OFFSET + 1;
        count += 1;
        id +%= cddbSum(secondsOf(r.tracks[i].start + MSF_OFFSET));
    }
    const t = secondsOf(last) -% secondsOf(first);
    r.discid = (id % 0xff) << 24 | t << 8 | count;
    const str = c.g_string_new(null);
    c.g_string_append_printf(str, "%08x", r.discid);
    c.gst_tag_list_add(s.*.tags, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_CDDA_CDDB_DISCID, str.*.str, @as(?*anyopaque, null));
    c.g_string_append_printf(str, " %u", r.num_tracks);
    i = 0;
    while (i < r.num_tracks) : (i += 1) c.g_string_append_printf(str, " %u", r.tracks[i].start + MSF_OFFSET);
    c.g_string_append_printf(str, " %u", t);
    c.gst_tag_list_add(s.*.tags, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_CDDA_CDDB_DISCID_FULL, str.*.str, @as(?*anyopaque, null));
    _ = c.g_string_free(str, 1);
}

fn addTags(s: [*c]Src) void {
    const r = priv(s);
    var i: c.guint = 0;
    while (i < r.num_tracks) : (i += 1) {
        if (r.tracks[i].tags == null) r.tracks[i].tags = c.gst_tag_list_new_empty();
        var duration: i64 = 0;
        _ = convert(s, sector_format, r.tracks[i].end -% r.tracks[i].start +% 1, c.GST_FORMAT_TIME, &duration);
        c.gst_tag_list_add(r.tracks[i].tags, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_TRACK_NUMBER, i + 1, c.GST_TAG_TRACK_COUNT, r.num_tracks, c.GST_TAG_DURATION, duration, @as(?*anyopaque, null));
    }
    c.gst_tag_list_add(s.*.tags, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_TRACK_COUNT, r.num_tracks, @as(?*anyopaque, null));
}

fn addToc(s: [*c]Src) void {
    const r = priv(s);
    const toc = c.gst_toc_new(c.GST_TOC_SCOPE_GLOBAL);
    var i: c.guint = 0;
    while (i < r.num_tracks) : (i += 1) {
        const track = &r.tracks[i];
        const uid = c.g_strdup_printf("audiocd-track-%03u", track.num);
        const entry = c.gst_toc_entry_new(c.GST_TOC_ENTRY_TYPE_TRACK, uid);
        c.gst_toc_entry_set_tags(entry, @ptrCast(c.gst_mini_object_ref(@ptrCast(track.tags))));
        var st: i64 = 0;
        var sp: i64 = 0;
        _ = convert(s, sector_format, track.start, c.GST_FORMAT_TIME, &st);
        _ = convert(s, sector_format, track.end + 1, c.GST_FORMAT_TIME, &sp);
        c.gst_toc_entry_set_start_stop_times(entry, st, sp);
        c.gst_toc_append_entry(toc, entry);
        c.g_free(uid);
    }
    r.toc_event = c.gst_event_new_toc(toc, 0);
    if (r.mode == c.GST_AUDIO_CD_SRC_MODE_CONTINUOUS) r.toc_event = c.gst_event_new_toc(toc, 0);
    r.toc = toc;
}

fn trackOrder(_: void, a: Track, b: Track) bool {
    if (a.is_audio == b.is_audio) return @as(c.gint, @bitCast(a.num)) < @as(c.gint, @bitCast(b.num));
    return a.is_audio != 0;
}

fn startSrc(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = of(b);
    const r = priv(s);
    const k = klass(s);
    r.discid = 0;
    r.mb_discid[0] = 0;
    if (k.open == null) c.g_assertion_message_expr(check.DOMAIN, PATH, 1533, "gst_audio_cd_src_start", "klass->open != NULL");
    const device = if (r.device != null) c.g_strdup(r.device) else c.g_strdup(DEFAULT_DEVICE);
    s.*.tags = c.gst_tag_list_new_empty();
    const ok = k.open.?(s, device);
    c.g_free(device);
    if (ok == 0) {
        _ = stopSrc(b);
        return 0;
    }
    if (r.num_tracks == 0 or r.tracks == null) return noTracks(s, b);
    cddb(s);
    musicbrainz(s);
    r.num_all_tracks = r.num_tracks;
    std.mem.sort(Track, r.tracks[0..r.num_tracks], {}, trackOrder);
    while (r.num_tracks > 0 and r.tracks[r.num_tracks - 1].is_audio == 0) r.num_tracks -= 1;
    if (r.num_tracks == 0) return noTracks(s, b);
    addTags(s);
    addToc(s);
    r.cur_track = 0;
    r.prev_track = -1;
    if (r.uri_track > 0 and r.uri_track <= r.num_tracks) {
        r.cur_track = r.uri_track - 1;
        r.uri_track = -1;
        r.mode = c.GST_AUDIO_CD_SRC_MODE_NORMAL;
    }
    r.cur_sector = @intCast(r.tracks[@intCast(r.cur_track)].start);
    updateDuration(s);
    return 1;
}

fn noTracks(s: [*c]Src, b: [*c]c.GstBaseSrc) c.gboolean {
    el.messageAt(s, c.GST_MESSAGE_ERROR, .resource, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup(c.g_dgettext("gst-plugins-base-1.0", "This CD has no audio tracks")), null, PATH, "gst_audio_cd_src_start", 1626, null);
    _ = stopSrc(b);
    return 0;
}

fn stopSrc(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = of(b);
    const r = priv(s);
    const k = klass(s);
    if (k.close == null) c.g_assertion_message_expr(check.DOMAIN, PATH, 1657, "gst_audio_cd_src_stop", "klass->close != NULL");
    k.close.?(s);
    if (r.tracks != null) {
        var i: c.guint = 0;
        while (i < r.num_all_tracks) : (i += 1) {
            if (r.tracks[i].tags != null) c.gst_mini_object_unref(@ptrCast(r.tracks[i].tags));
        }
        c.g_free(r.tracks);
        r.tracks = null;
    }
    r.num_tracks = 0;
    r.num_all_tracks = 0;
    if (s.*.tags != null) {
        c.gst_mini_object_unref(@ptrCast(s.*.tags));
        s.*.tags = null;
    }
    _ = c.gst_mini_object_replace(@ptrCast(&r.toc_event), null);
    if (r.toc) |t| {
        c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
        r.toc = null;
    }
    r.prev_track = -1;
    r.cur_track = -1;
    return 1;
}

fn create(ps: [*c]c.GstPushSrc, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = of(ps);
    const r = priv(s);
    const k = klass(s);
    if (k.read_sector == null) c.g_assertion_message_expr(check.DOMAIN, PATH, 1694, "gst_audio_cd_src_create", "klass->read_sector != NULL");
    var eos: bool = undefined;
    switch (r.mode) {
        c.GST_AUDIO_CD_SRC_MODE_NORMAL => eos = r.cur_sector > r.tracks[@intCast(r.cur_track)].end,
        c.GST_AUDIO_CD_SRC_MODE_CONTINUOUS => {
            eos = r.cur_sector > r.tracks[r.num_tracks - 1].end;
            r.cur_track = trackFromSector(s, r.cur_sector);
        },
        else => {
            check.reached("gstaudiocdsrc.c", 1709, "gst_audio_cd_src_create");
            return c.GST_FLOW_ERROR;
        },
    }
    if (eos) {
        r.prev_track = -1;
        return c.GST_FLOW_EOS;
    }
    if (r.toc_event != null) {
        _ = c.gst_pad_push_event(srcPad(s), r.toc_event);
        r.toc_event = null;
    }
    if (r.prev_track != r.cur_track) {
        const tags = c.gst_tag_list_merge(s.*.tags, r.tracks[@intCast(r.cur_track)].tags, c.GST_TAG_MERGE_REPLACE);
        _ = c.gst_pad_push_event(srcPad(s), c.gst_event_new_tag(tags));
        r.prev_track = r.cur_track;
        updateDuration(s);
        c.g_object_notify(@ptrCast(s), "track");
    }
    const buf = k.read_sector.?(s, r.cur_sector);
    if (buf == null) return c.GST_FLOW_ERROR;
    var position: u64 = NONE;
    var duration: u64 = NONE;
    var qpos: i64 = 0;
    if (c.gst_pad_query_position(srcPad(s), c.GST_FORMAT_TIME, &qpos) != 0) {
        position = @bitCast(qpos);
        r.cur_sector += 1;
        var next: i64 = 0;
        if (c.gst_pad_query_position(srcPad(s), c.GST_FORMAT_TIME, &next) != 0) duration = @bitCast(next -% qpos);
        r.cur_sector -= 1;
    }
    if (duration == NONE) duration = c.gst_util_uint64_scale_int(c.gst_buffer_get_size(buf) >> 2, c.GST_SECOND, 44100);
    buf.*.pts = position;
    buf.*.duration = duration;
    r.cur_sector += 1;
    out.* = buf;
    return c.GST_FLOW_OK;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_free(priv(o).uri);
    c.g_free(priv(o).device);
    @as(*c.GObjectClass, @ptrCast(parent)).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    _ = c._gst_debug_category_new("audiocdsrc", 0, "Audio CD source base class");
    track_format = c.gst_format_register("track", "CD track");
    sector_format = c.gst_format_register("sector", "CD sector");
    c.gst_tag_register_musicbrainz_tags();
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const F = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 2, c.g_param_spec_string("device", "Device", "CD device location", null, F));
    c.g_object_class_install_property(oc, 1, c.g_param_spec_enum("mode", "Mode", "Mode", enums.gst_audio_cd_src_mode_get_type(), c.GST_AUDIO_CD_SRC_MODE_NORMAL, F));
    c.g_object_class_install_property(oc, 3, c.g_param_spec_uint("track", "Track", "Track", 1, 99, 1, F));
    c.gst_element_class_add_static_pad_template(@ptrCast(@alignCast(k)), &templ);
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.start = startSrc;
    bc.stop = stopSrc;
    bc.query = query;
    bc.event = handleEvent;
    bc.do_seek = doSeek;
    bc.is_seekable = isSeekable;
    @as(*c.GstPushSrcClass, @ptrCast(@alignCast(k))).create = create;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = of(inst);
    s.*.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset_))));
    const r = priv(s);
    r.* = std.mem.zeroes(Private);
    c.gst_base_src_set_format(@ptrCast(s), c.GST_FORMAT_TIME);
    c.gst_base_src_set_live(@ptrCast(s), 0);
    el.setFlag(s, c.GST_ELEMENT_FLAG_INDEXABLE);
    r.mode = c.GST_AUDIO_CD_SRC_MODE_NORMAL;
    r.uri_track = -1;
}

pub export fn gst_audio_cd_src_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_push_src_get_type, "GstAudioCdSrc", Class, Src, classInit, init, 0);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            const iface = c.GInterfaceInfo{ .interface_init = uriInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_uri_handler_get_type(), &iface);
            return t;
        }
    }.f);
}
