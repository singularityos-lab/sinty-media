const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const tables = @import("tables.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const PREFIX = "http://creativecommons.org/licenses/";
const DICT_PATH = "/usr/share/gst-plugins-base/1.0/license-translations.dict";

var dict_once: usize = 0;

fn dictionary() ?*c.GVariant {
    if (c.g_once_init_enter(&dict_once) != 0) {
        var path: [*c]const u8 = c.g_getenv("GST_TAG_LICENSE_TRANSLATIONS_DICT");
        if (path == null) path = DICT_PATH;
        var data: [*c]u8 = null;
        var len: usize = 0;
        var err: [*c]c.GError = null;
        var v: ?*c.GVariant = null;
        if (c.g_file_get_contents(path, &data, &len, &err) != 0) {
            v = c.g_variant_new_from_data(c.g_variant_type_checked_("a{sa{ss}}"), data, len, 1, c.g_free, data);
        } else {
            c.g_error_free(err);
            v = c.g_variant_new_array(c.g_variant_type_checked_("{sa{ss}}"), null, 0);
        }
        c.g_once_init_leave(&dict_once, @intFromPtr(v));
    }
    return @ptrFromInt(dict_once);
}

fn lookupString(dict: ?*c.GVariant, lang: [*c]const u8, out: *[*c]const u8) bool {
    const t = c.g_variant_lookup_value(dict, lang, c.g_variant_type_checked_("s"));
    if (t == null) return false;
    out.* = c.g_variant_get_string(t, null);
    c.g_variant_unref(t);
    return true;
}

fn translate(s_in: [*c]const u8) [*c]const u8 {
    var s = s_in;
    const v = dictionary();
    const dict = c.g_variant_lookup_value(v, s, c.g_variant_type_checked_("a{ss}"));
    if (dict == null) return s;
    defer c.g_variant_unref(dict);
    const env_lang = c.g_getenv("GST_TAG_LICENSE_TRANSLATIONS_LANG");
    if (env_lang != null and lookupString(dict, env_lang, &s)) return s;
    var lang = c.g_get_language_names();
    while (lang != null and lang[0] != null) : (lang += 1) {
        if (lookupString(dict, lang[0], &s)) break;
    }
    return s;
}

pub export fn gst_tag_get_licenses() [*c][*c]u8 {
    const arr = c.g_ptr_array_new();
    for (tables.LICENSES) |l| {
        const ref = if (l.jur) |j| c.g_strconcat(PREFIX, l.base.ptr, j.ptr, "/", @as(?*anyopaque, null)) else c.g_strconcat(PREFIX, l.base.ptr, @as(?*anyopaque, null));
        c.g_ptr_array_add(arr, ref);
    }
    c.g_ptr_array_add(arr, null);
    return @ptrCast(@alignCast(c.g_ptr_array_free(arr, 0)));
}

fn find(license_ref: [*c]const u8, jurisdiction: ?*[*c]const u8) ?*const tables.License {
    const full = std.mem.span(license_ref);
    if (!std.mem.startsWith(u8, full, PREFIX)) return null;
    if (jurisdiction) |j| j.* = null;
    const ref = full[PREFIX.len..];
    for (&tables.LICENSES) |*l| {
        const base: []const u8 = l.base;
        if (l.jur) |jur| {
            if (!std.mem.startsWith(u8, ref, base)) continue;
            const suffix = ref[base.len..];
            if (suffix.len == 0) continue;
            if (std.mem.startsWith(u8, suffix, jur) and (suffix.len == jur.len or suffix[jur.len] == '/')) {
                if (jurisdiction) |j| j.* = jur.ptr;
                return l;
            }
        } else if (std.mem.eql(u8, ref, base) or std.mem.eql(u8, ref, base[0 .. base.len - 1])) return l;
    }
    return null;
}

pub export fn gst_tag_get_license_flags(license_ref: [*c]const u8) c.GstTagLicenseFlags {
    if (!check.that(license_ref != null, "gst_tag_get_license_flags", "license_ref != NULL")) return 0;
    return if (find(license_ref, null)) |l| l.flags else 0;
}

pub export fn gst_tag_get_license_nick(license_ref: [*c]const u8) [*c]const u8 {
    if (!check.that(license_ref != null, "gst_tag_get_license_nick", "license_ref != NULL")) return null;
    const flags = gst_tag_get_license_flags(license_ref);
    const prefix: [*c]const u8 = if (flags & c.GST_TAG_LICENSE_CREATIVE_COMMONS_LICENSE != 0) "CC " else if (flags & c.GST_TAG_LICENSE_FREE_SOFTWARE_FOUNDATION_LICENSE != 0) "FSF " else if (c.g_str_has_suffix(license_ref, "publicdomain/") != 0) "" else return null;
    const nick = c.g_strdup_printf("%s%s", prefix, license_ref + PREFIX.len);
    _ = c.g_strdelimit(nick, "/", ' ');
    _ = c.g_strchomp(nick);
    var p = nick;
    while (p[0] != 0) : (p += 1) p[0] = c.g_ascii_toupper(p[0]);
    const res = c.g_intern_string(nick);
    c.g_free(nick);
    return res;
}

pub export fn gst_tag_get_license_title(license_ref: [*c]const u8) [*c]const u8 {
    if (!check.that(license_ref != null, "gst_tag_get_license_title", "license_ref != NULL")) return null;
    const l = find(license_ref, null) orelse return null;
    return if (l.title) |t| translate(t) else null;
}

pub export fn gst_tag_get_license_description(license_ref: [*c]const u8) [*c]const u8 {
    if (!check.that(license_ref != null, "gst_tag_get_license_description", "license_ref != NULL")) return null;
    const l = find(license_ref, null) orelse return null;
    return if (l.desc) |d| translate(d) else null;
}

pub export fn gst_tag_get_license_jurisdiction(license_ref: [*c]const u8) [*c]const u8 {
    if (!check.that(license_ref != null, "gst_tag_get_license_jurisdiction", "license_ref != NULL")) return null;
    var jur: [*c]const u8 = null;
    _ = find(license_ref, &jur) orelse return null;
    return jur;
}

pub export fn gst_tag_get_license_version(license_ref: [*c]const u8) [*c]const u8 {
    if (!check.that(license_ref != null, "gst_tag_get_license_version", "license_ref != NULL")) return null;
    const l = find(license_ref, null) orelse return null;
    if (l.flags & (c.GST_TAG_LICENSE_CREATIVE_COMMONS_LICENSE | c.GST_TAG_LICENSE_FREE_SOFTWARE_FOUNDATION_LICENSE) == 0) return null;
    const base: []const u8 = l.base;
    for ([_][]const u8{ "1.0", "2.0", "2.1", "2.5", "3.0" }) |v| {
        var pat: [8]u8 = undefined;
        const p = std.fmt.bufPrint(&pat, "/{s}/", .{v}) catch unreachable;
        if (std.mem.indexOf(u8, base, p) != null) return v.ptr;
    }
    return null;
}
