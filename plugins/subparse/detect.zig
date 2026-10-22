const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

pub const UNKNOWN = 0;
pub const MDVDSUB = 1;
pub const SUBRIP = 2;
pub const MPSUB = 3;
pub const SAMI = 4;
pub const TMPLAYER = 5;
pub const MPL2 = 6;
pub const SUBVIEWER = 7;
pub const DKS = 8;
pub const QTTEXT = 9;
pub const LRC = 10;
pub const VTT = 11;

var mdvd_rx: ?*c.GRegex = null;
var subrip_rx: ?*c.GRegex = null;
var dks_rx: ?*c.GRegex = null;
var vtt_rx: ?*c.GRegex = null;
var rx_once: ?*anyopaque = null;
var init_done: ?*anyopaque = null;

fn compile(pattern: [*c]const u8, flags: c.GRegexCompileFlags, what: [*c]const u8) ?*c.GRegex {
    var err: [*c]c.GError = null;
    const r = c.g_regex_new(pattern, flags, 0, &err);
    if (r == null) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "Compilation of %s regex failed: %s", what, err.*.message);
        c.g_clear_error(&err);
    }
    return r;
}

fn regexes() void {
    if (c.g_once_init_enter_pointer(@ptrCast(&rx_once)) != 0) {
        const jit = c.G_REGEX_OPTIMIZE | c.G_REGEX_RAW;
        mdvd_rx = compile("^\\{[0-9]+\\}\\{[0-9]+\\}", jit, "mdvd");
        subrip_rx = compile("^[\\s\\n]*[\\n]? {0,3}[ 0-9]{1,4}\\s*(\x0d)?\x0a ?[0-9]{1,2}: ?[0-9]{1,2}: ?[0-9]{1,2}[,.] {0,2}[0-9]{1,3} +--> +[0-9]{1,2}: ?[0-9]{1,2}: ?[0-9]{1,2}[,.] {0,2}[0-9]{1,2}", jit, "subrip");
        dks_rx = compile("^\\[[0-9]+:[0-9]+:[0-9]+\\].*", jit, "dks");
        vtt_rx = compile("^(\\xef\\xbb\\xbf)?WEBVTT[\\xa\\xd\\x20\\x9]", 0, "vtt");
        c.g_once_init_leave_pointer(@ptrCast(&rx_once), @ptrFromInt(1));
    }
}

fn lrcLines(s: [*c]u8) bool {
    var n1: c.guint = 0;
    var n2: c.guint = 0;
    var n3: c.guint = 0;
    const split = c.g_strsplit(s, "\n", -1);
    defer c.g_strfreev(split);
    var good = true;
    var p = split;
    while (p[0] != null and p[1] != null) : (p += 1) {
        const str = p[0];
        const len = c.strlen(str);
        if (c.sscanf(str, "[%u:%02u.%02u]", &n1, &n2, &n3) == 3 or c.sscanf(str, "[%u:%02u.%03u]", &n1, &n2, &n3) == 3) {
            good = true;
        } else if (len > 0 and str[len - 1] == ']' and c.strchr(str, ':') != null) {
            good = true;
        } else {
            good = false;
            break;
        }
    }
    return good;
}

pub fn autodetect(s: [*c]u8) c_int {
    regexes();
    var n1: c.guint = 0;
    var n2: c.guint = 0;
    var n3: c.guint = 0;
    if (c.g_regex_match(mdvd_rx, s, 0, null) != 0) return MDVDSUB;
    if (c.g_regex_match(subrip_rx, s, 0, null) != 0) return SUBRIP;
    if (c.g_regex_match(dks_rx, s, 0, null) != 0) return DKS;
    if (c.g_regex_match(vtt_rx, s, 0, null) != 0) return VTT;
    if (c.strncmp(s, "FORMAT=TIME", 11) == 0) return MPSUB;
    if (c.strstr(s, "<SAMI>") != null or c.strstr(s, "<sami>") != null) return SAMI;
    if (c.sscanf(s, "0:%02u:%02u:", &n1, &n2) == 2 or c.sscanf(s, "0:%02u:%02u=", &n1, &n2) == 2 or
        c.sscanf(s, "00:%02u:%02u:", &n1, &n2) == 2 or c.sscanf(s, "00:%02u:%02u=", &n1, &n2) == 2 or
        c.sscanf(s, "00:%02u:%02u,%u=", &n1, &n2, &n3) == 3) return TMPLAYER;
    if (c.sscanf(s, "[%u][%u]", &n1, &n2) == 2) return MPL2;
    if (c.strstr(s, "[INFORMATION]") != null) return SUBVIEWER;
    if (c.strstr(s, "{QTtext}") != null) return QTTEXT;
    if (s[0] == '[' and lrcLines(s)) return LRC;
    return UNKNOWN;
}

pub fn toUtf8(str: [*c]const u8, len: usize, encoding: [*c]const u8, consumed: *usize, err: [*c][*c]c.GError) [*c]u8 {
    consumed.* = 0;
    const ret = c.g_convert_with_fallback(str, @intCast(len), "UTF-8", encoding, @constCast("*"), consumed, null, err);
    if (ret == null) return null;
    const n = c.strlen(ret);
    if (n >= 3 and ret[0] == 0xEF and ret[1] == 0xBB and ret[2] == 0xBF) _ = c.memmove(ret, ret + 3, n + 1 - 3);
    return ret;
}

pub fn detectEncoding(str: [*c]const u8, len: usize) [*c]u8 {
    if (len >= 3 and str[0] == 0xEF and str[1] == 0xBB and str[2] == 0xBF) return c.g_strdup("UTF-8");
    if (len >= 2 and str[0] == 0xFE and str[1] == 0xFF) return c.g_strdup("UTF-16BE");
    if (len >= 2 and str[0] == 0xFF and str[1] == 0xFE) return c.g_strdup("UTF-16LE");
    if (len >= 4 and str[0] == 0x00 and str[1] == 0x00 and str[2] == 0xFE and str[3] == 0xFF) return c.g_strdup("UTF-32BE");
    if (len >= 4 and str[0] == 0xFF and str[1] == 0xFE and str[2] == 0x00 and str[3] == 0x00) return c.g_strdup("UTF-32LE");
    return null;
}

var mpl2_caps = c.GstStaticCaps{ .caps = null, .string = "application/x-subtitle-mpl2", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var tmp_caps = c.GstStaticCaps{ .caps = null, .string = "application/x-subtitle-tmplayer", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var sub_caps = c.GstStaticCaps{ .caps = null, .string = "application/x-subtitle", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var smi_caps = c.GstStaticCaps{ .caps = null, .string = "application/x-subtitle-sami", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var dks_caps = c.GstStaticCaps{ .caps = null, .string = "application/x-subtitle-dks", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var vtt_caps = c.GstStaticCaps{ .caps = null, .string = "application/x-subtitle-vtt", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var qttext_caps = c.GstStaticCaps{ .caps = null, .string = "application/x-subtitle-qttext", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var lrc_caps = c.GstStaticCaps{ .caps = null, .string = "application/x-subtitle-lrc", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };

fn typeFind(tf: ?*c.GstTypeFind, _: c.gpointer) callconv(.c) void {
    var len: u64 = 128;
    var data = c.gst_type_find_peek(tf, 0, @intCast(len));
    if (data == null) {
        len = c.gst_type_find_get_length(tf);
        if (len == 0) return;
        data = c.gst_type_find_peek(tf, 0, @intCast(len));
        if (data == null) return;
    }
    var str: [*c]u8 = @ptrCast(c.g_malloc0(len + 1));
    @memcpy(str[0..len], data[0..len]);
    const enc = detectEncoding(str, len);
    if (enc != null) {
        var err: [*c]c.GError = null;
        var used: usize = 0;
        const conv = toUtf8(str, len, enc, &used, &err);
        if (conv == null) {
            c.g_clear_error(&err);
        } else {
            c.g_free(str);
            str = conv;
        }
        c.g_free(enc);
    }
    const checked: u64 = if (len > 8) len - 8 else len;
    var end: [*c]const u8 = null;
    if (c.g_utf8_validate(str, @intCast(len), &end) == 0 and @intFromPtr(end) - @intFromPtr(str) < checked) {
        var e: [*c]const u8 = c.g_getenv("GST_SUBTITLE_ENCODING");
        if (e == null or e[0] == 0) {
            if (c.g_get_charset(&e) != 0) e = "ISO-8859-15";
        }
        var used: usize = 0;
        const conv = toUtf8(str, len, e, &used, null);
        if (conv != null) {
            c.g_free(str);
            str = conv;
        }
    }
    const format = autodetect(str);
    c.g_free(str);
    const caps = switch (format) {
        MDVDSUB, SUBRIP, MPSUB, SUBVIEWER => &sub_caps,
        SAMI => &smi_caps,
        TMPLAYER => &tmp_caps,
        MPL2 => &mpl2_caps,
        DKS => &dks_caps,
        QTTEXT => &qttext_caps,
        LRC => &lrc_caps,
        VTT => &vtt_caps,
        else => return,
    };
    c.gst_type_find_suggest(tf, c.GST_TYPE_FIND_MAXIMUM, c.gst_static_caps_get(caps));
}

pub fn elementInit(p: ?*c.GstPlugin) void {
    if (c.g_once_init_enter_pointer(@ptrCast(&init_done)) != 0) {
        _ = c._gst_debug_category_new("subparse", 0, ".sub parser");
        _ = c.gst_type_find_register(p, "subparse_typefind", c.GST_RANK_MARGINAL, typeFind, "srt,sub,mpsub,mdvd,smi,txt,dks,vtt", c.gst_static_caps_get(&sub_caps), null, null);
        c.g_once_init_leave_pointer(@ptrCast(&init_done), @ptrFromInt(1));
    }
}
