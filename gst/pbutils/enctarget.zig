const std = @import("std");
const c = @import("../c.zig").c;
const config = @import("config");
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const init = @import("init.zig");
const prof = @import("encprofile.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const OTarget = ?*c.GstEncodingTarget;
const OProfile = ?*c.GstEncodingProfile;
const HEADER = "GStreamer Encoding Target";

const Target = extern struct {
    parent: c.GObject,
    name: [*c]u8,
    category: [*c]u8,
    description: [*c]u8,
    path: [*c]u8,
    profiles: [*c]c.GList,
    keyfile: [*c]u8,
};

var once: gtype.Once = .{};
var parent: ?*c.GObjectClass = null;

fn of(t: anytype) *Target {
    return @ptrCast(@alignCast(t));
}

fn isTarget(t: anytype) bool {
    return gtype.instanceOf(t, gst_encoding_target_get_type());
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const t = of(o);
    c.g_free(t.name);
    c.g_free(t.category);
    c.g_free(t.description);
    c.g_free(t.path);
    c.g_list_foreach(t.profiles, @ptrCast(&c.g_object_unref), null);
    c.g_list_free(t.profiles);
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

pub export fn gst_encoding_target_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.object(c.g_object_get_type, "GstEncodingTarget", c.GObjectClass, Target, classInit, null, 0);
        }
    }.f);
}

pub export fn gst_encoding_target_get_name(t: OTarget) [*c]const c.gchar {
    return of(t).name;
}

pub export fn gst_encoding_target_get_category(t: OTarget) [*c]const c.gchar {
    return of(t).category;
}

pub export fn gst_encoding_target_get_description(t: OTarget) [*c]const c.gchar {
    return of(t).description;
}

pub export fn gst_encoding_target_get_path(t: OTarget) [*c]const c.gchar {
    if (!check.that(isTarget(t), "gst_encoding_target_get_path", "GST_IS_ENCODING_TARGET (target)")) return null;
    return of(t).path;
}

pub export fn gst_encoding_target_get_profiles(t: OTarget) [*c]const c.GList {
    return of(t).profiles;
}

pub export fn gst_encoding_target_get_profile(t: OTarget, name: [*c]const c.gchar) OProfile {
    if (!check.that(isTarget(t), "gst_encoding_target_get_profile", "GST_IS_ENCODING_TARGET (target)")) return null;
    if (!check.that(name != null, "gst_encoding_target_get_profile", "name != NULL")) return null;
    var l = of(t).profiles;
    while (l != null) : (l = l[0].next) {
        if (c.g_strcmp0(prof.gst_encoding_profile_get_name(@ptrCast(l[0].data)), name) == 0) {
            _ = c.g_object_ref(l[0].data);
            return @ptrCast(l[0].data);
        }
    }
    return null;
}

fn validName(name: [*c]const u8) bool {
    const n = std.mem.span(@as([*:0]const u8, @ptrCast(name)));
    if (n.len == 0) return false;
    if (!c.g_ascii_isalpha(n[0]) or !c.g_ascii_islower(n[0])) return false;
    for (n[1..]) |ch| {
        if (c.g_ascii_isupper(ch)) return false;
        if (c.g_ascii_isdigit(ch) or ch == '-' or ch == ';') continue;
        if (!c.g_ascii_isalpha(ch)) return false;
    }
    return true;
}

pub export fn gst_encoding_target_new(name: [*c]const c.gchar, category: [*c]const c.gchar, description: [*c]const c.gchar, profiles: [*c]const c.GList) OTarget {
    const fname = "gst_encoding_target_new";
    if (!check.that(name != null, fname, "name != NULL")) return null;
    if (!check.that(category != null, fname, "category != NULL")) return null;
    if (!check.that(description != null, fname, "description != NULL")) return null;
    if (!validName(name) or !validName(category)) return null;
    const t = of(c.g_object_new(gst_encoding_target_get_type(), @as([*c]const u8, null)));
    t.name = c.g_strdup(name);
    t.category = c.g_strdup(category);
    t.description = c.g_strdup(description);
    var l = profiles;
    while (l != null) : (l = l[0].next) t.profiles = c.g_list_append(t.profiles, c.g_object_ref(l[0].data));
    return @ptrCast(t);
}

pub export fn gst_encoding_target_add_profile(t: OTarget, profile: OProfile) c.gboolean {
    const fname = "gst_encoding_target_add_profile";
    if (!check.that(isTarget(t), fname, "GST_IS_ENCODING_TARGET (target)")) return 0;
    if (!check.that(prof.isProfile(profile), fname, "GST_IS_ENCODING_PROFILE (profile)")) return 0;
    var l = of(t).profiles;
    while (l != null) : (l = l[0].next) {
        if (c.g_strcmp0(prof.gst_encoding_profile_get_name(profile), prof.gst_encoding_profile_get_name(@ptrCast(l[0].data))) == 0) return 0;
    }
    of(t).profiles = c.g_list_append(of(t).profiles, profile);
    return 1;
}

fn writeStream(out: ?*c.GKeyFile, sp: OProfile, profilename: [*c]const u8, id: c.guint) void {
    const g = c.g_strdup_printf("streamprofile-%s-%d", profilename, id);
    defer c.g_free(g);
    c.g_key_file_set_value(out, g, "parent", profilename);
    c.g_key_file_set_value(out, g, "type", prof.gst_encoding_profile_get_type_nick(sp));
    const format = prof.gst_encoding_profile_get_format(sp);
    if (format != null) {
        const s = c.gst_caps_to_string(format);
        c.g_key_file_set_value(out, g, "format", s);
        c.g_free(s);
    }
    const name = prof.gst_encoding_profile_get_name(sp);
    if (name != null) c.g_key_file_set_string(out, g, "name", name);
    const d = prof.gst_encoding_profile_get_description(sp);
    if (d != null) c.g_key_file_set_string(out, g, "description", d);
    const preset = prof.gst_encoding_profile_get_preset(sp);
    if (preset != null) c.g_key_file_set_string(out, g, "preset", preset);
    const r = prof.gst_encoding_profile_get_restriction(sp);
    if (r != null) {
        const s = c.gst_caps_to_string(r);
        c.g_key_file_set_value(out, g, "restriction", s);
        c.g_free(s);
    }
    c.g_key_file_set_integer(out, g, "presence", @bitCast(prof.gst_encoding_profile_get_presence(sp)));
    if (prof.isVideo(sp)) {
        c.g_key_file_set_integer(out, g, "pass", @bitCast(prof.gst_encoding_video_profile_get_pass(@ptrCast(sp))));
        c.g_key_file_set_boolean(out, g, "variableframerate", prof.gst_encoding_video_profile_get_variableframerate(@ptrCast(sp)));
    }
    if (format != null) c.gst_mini_object_unref(@ptrCast(format));
    if (r != null) c.gst_mini_object_unref(@ptrCast(r));
}

fn locale() [*c]u8 {
    init.ensureLocale();
    const loc = c.setlocale(c.LC_MESSAGES, null);
    if (loc == null or c.g_ascii_strncasecmp(loc, "en", 2) == 0) return null;
    const r = c.g_ascii_strdown(loc, -1);
    return c.g_strcanon(r, "abcdefghijklmnopqrstuvwxyz", 0);
}

fn writeProfile(out: ?*c.GKeyFile, p: OProfile) void {
    const name = prof.gst_encoding_profile_get_name(p);
    const d = prof.gst_encoding_profile_get_description(p);
    const format = prof.gst_encoding_profile_get_format(p);
    const preset = prof.gst_encoding_profile_get_preset(p);
    const kind = prof.gst_encoding_profile_get_type_nick(p);
    const g = c.g_strdup_printf("profile-%s", name);
    c.g_key_file_set_string(out, g, "name", name);
    c.g_key_file_set_value(out, g, "type", kind);
    if (d != null) {
        const loc = locale();
        if (loc != null) {
            c.g_key_file_set_locale_string(out, g, "description", loc, d);
            c.g_free(loc);
        } else c.g_key_file_set_string(out, g, "description", d);
    }
    if (format != null) {
        const s = c.gst_caps_to_string(format);
        c.g_key_file_set_string(out, g, "format", s);
        c.g_free(s);
    }
    if (preset != null) c.g_key_file_set_string(out, g, "preset", preset);
    if (prof.isContainer(p)) {
        var l = prof.gst_encoding_container_profile_get_profiles(@ptrCast(p));
        var i: c.guint = 0;
        while (l != null) : ({
            l = l[0].next;
            i += 1;
        }) writeStream(out, @ptrCast(l[0].data), name, i);
    }
    if (format != null) c.gst_mini_object_unref(@ptrCast(format));
    c.g_free(g);
}

fn readProfile(in: ?*c.GKeyFile, parentname: [*c]const u8, group: [*c]const u8, groups: [*c][*c]u8, n: usize) OProfile {
    if (parentname != null) {
        var count: usize = 0;
        const par = c.g_key_file_get_string_list(in, group, "parent", &count, null);
        if (par == null or count == 0) return null;
        var found = false;
        for (0..count) |i| {
            if (c.g_strcmp0(par[i], parentname) == 0) {
                found = true;
                break;
            }
        }
        c.g_strfreev(par);
        if (!found) return null;
    }
    const pname = c.g_key_file_get_value(in, group, "name", null);
    const loc = locale();
    const d = c.g_key_file_get_locale_string(in, group, "description", loc, null);
    c.g_free(loc);
    const kind = c.g_key_file_get_value(in, group, "type", null);
    if (kind == null) {
        c.g_free(pname);
        c.g_free(d);
        return null;
    }
    var format: [*c]c.GstCaps = null;
    const fs = c.g_key_file_get_value(in, group, "format", null);
    if (fs != null) {
        format = c.gst_caps_from_string(fs);
        c.g_free(fs);
    }
    const preset = c.g_key_file_get_value(in, group, "preset", null);
    var restriction: [*c]c.GstCaps = null;
    const rs = c.g_key_file_get_value(in, group, "restriction", null);
    if (rs != null) {
        restriction = c.gst_caps_from_string(rs);
        c.g_free(rs);
    }
    const presence = c.g_key_file_get_integer(in, group, "presence", null);
    const pass = c.g_key_file_get_integer(in, group, "pass", null);
    const vfr = c.g_key_file_get_boolean(in, group, "variableframerate", null);
    var sp: OProfile = null;
    if (c.g_strcmp0(kind, "container") == 0) {
        sp = @ptrCast(prof.gst_encoding_container_profile_new(pname, d, format, preset));
        for (0..n) |i| {
            if (c.g_ascii_strncasecmp(groups[i], "streamprofile-", 13) == 0) {
                const child = readProfile(in, pname, groups[i], groups, n);
                if (child != null) _ = prof.gst_encoding_container_profile_add_profile(@ptrCast(sp), child);
            }
        }
    } else if (c.g_strcmp0(kind, "video") == 0) {
        sp = @ptrCast(prof.gst_encoding_video_profile_new(format, preset, restriction, @bitCast(presence)));
        prof.gst_encoding_video_profile_set_variableframerate(@ptrCast(sp), vfr);
        prof.gst_encoding_video_profile_set_pass(@ptrCast(sp), @bitCast(pass));
        prof.gst_encoding_profile_set_name(sp, pname);
        prof.gst_encoding_profile_set_description(sp, d);
    } else if (c.g_strcmp0(kind, "audio") == 0) {
        sp = @ptrCast(prof.gst_encoding_audio_profile_new(format, preset, restriction, @bitCast(presence)));
        prof.gst_encoding_profile_set_name(sp, pname);
        prof.gst_encoding_profile_set_description(sp, d);
    }
    if (restriction != null) c.gst_mini_object_unref(@ptrCast(restriction));
    if (format != null) c.gst_mini_object_unref(@ptrCast(format));
    c.g_free(pname);
    c.g_free(d);
    c.g_free(preset);
    c.g_free(kind);
    return sp;
}

pub export fn gst_encoding_target_load_from_file(filepath: [*c]const c.gchar, err: [*c][*c]c.GError) OTarget {
    if (!check.that(err == null or err[0] == null, "load_file_and_read_header", "error == NULL || *error == NULL")) return null;
    const in = c.g_key_file_new();
    defer c.g_key_file_free(in);
    var kerr: [*c]c.GError = null;
    if (c.g_key_file_load_from_file(in, filepath, c.G_KEY_FILE_KEEP_COMMENTS | c.G_KEY_FILE_KEEP_TRANSLATIONS, &kerr) == 0 or kerr != null) {
        c.g_propagate_error(err, kerr);
        return null;
    }
    const name = c.g_key_file_get_value(in, HEADER, "name", &kerr);
    if (name == null) {
        c.g_propagate_error(err, kerr);
        return null;
    }
    const category = c.g_key_file_get_value(in, HEADER, "category", null);
    const description = c.g_key_file_get_value(in, HEADER, "description", null);
    const t = gst_encoding_target_new(name, category, description, null);
    var n: usize = 0;
    const groups = c.g_key_file_get_groups(in, &n);
    for (0..n) |i| {
        if (c.g_ascii_strncasecmp(groups[i], "profile-", 8) == 0) {
            const p = readProfile(in, null, groups[i], groups, n);
            if (p != null) _ = gst_encoding_target_add_profile(t, p);
        }
    }
    c.g_strfreev(groups);
    c.g_free(name);
    c.g_free(category);
    c.g_free(description);
    return t;
}

fn matching(path: [*c]const u8, filename: [*c]const u8) [*c]c.GList {
    var res: [*c]c.GList = null;
    const dir = c.g_dir_open(path, 0, null);
    if (dir == null) return null;
    const direct = c.g_build_filename(path, filename, @as([*c]const u8, null));
    if (c.g_file_test(direct, c.G_FILE_TEST_EXISTS) != 0) res = c.g_list_append(res, direct) else c.g_free(direct);
    while (true) {
        const sub = c.g_dir_read_name(dir);
        if (sub == null) break;
        const full = c.g_build_filename(path, sub, @as([*c]const u8, null));
        if (c.g_file_test(full, c.G_FILE_TEST_IS_DIR) != 0) {
            const f = c.g_build_filename(path, sub, filename, @as([*c]const u8, null));
            if (c.g_file_test(f, c.G_FILE_TEST_EXISTS) != 0) res = c.g_list_append(res, f) else c.g_free(f);
        }
        c.g_free(full);
    }
    c.g_dir_close(dir);
    return res;
}

fn subload(path: [*c]const u8, category: [*c]const u8, filename: [*c]const u8, err: [*c][*c]c.GError) OTarget {
    if (category != null) {
        const f = c.g_build_filename(path, category, filename, @as([*c]const u8, null));
        defer c.g_free(f);
        return gst_encoding_target_load_from_file(f, err);
    }
    const tries = matching(path, filename);
    var t: OTarget = null;
    var l = tries;
    while (l != null) : (l = l[0].next) {
        t = gst_encoding_target_load_from_file(@ptrCast(l[0].data), null);
        if (t != null) break;
    }
    c.g_list_foreach(tries, @ptrCast(&c.g_free), null);
    if (tries != null) c.g_list_free(tries);
    return t;
}

fn userDir(extra: [*c]const u8) [*c]u8 {
    return c.g_build_filename(c.g_get_user_data_dir(), "gstreamer-1.0", "encoding-profiles", extra, @as([*c]const u8, null));
}

fn systemDir() [*c]u8 {
    return c.g_build_filename(config.data_dir.ptr, "gstreamer-1.0", "encoding-profiles", @as([*c]const u8, null));
}

pub export fn gst_encoding_target_load(name: [*c]const c.gchar, category: [*c]const c.gchar, err: [*c][*c]c.GError) OTarget {
    if (!check.that(name != null, "gst_encoding_target_load", "name != NULL")) return null;
    const lname = c.g_str_to_ascii(name, null);
    defer c.g_free(lname);
    var p = lname;
    while (p[0] != 0) : (p += 1) p[0] = c.g_ascii_tolower(p[0]);
    if (!validName(lname)) return null;
    if (category != null and !validName(category)) return null;
    const lfile = c.g_strdup_printf("%s.gep", lname);
    defer c.g_free(lfile);
    var t: OTarget = null;
    const env = c.g_getenv("GST_ENCODING_TARGET_PATH");
    if (env != null) {
        const dirs = c.g_strsplit(env, ":", -1);
        var i: usize = 0;
        while (dirs[i] != null) : (i += 1) {
            t = subload(dirs[i], category, lfile, err);
            if (t != null) break;
        }
        c.g_strfreev(dirs);
        if (t != null) return t;
    }
    const ud = userDir(null);
    t = subload(ud, category, lfile, err);
    c.g_free(ud);
    if (t == null) {
        const sd = systemDir();
        t = subload(sd, category, lfile, err);
        c.g_free(sd);
    }
    if (t == null) {
        const all = gst_encoding_list_all_targets(null);
        var l = all;
        outer: while (l != null) : (l = l[0].next) {
            const tt = of(l[0].data);
            const names = c.g_strsplit(tt.name, ";", -1);
            defer c.g_strfreev(names);
            var i: usize = 0;
            while (names[i] != null) : (i += 1) {
                if (c.g_strcmp0(names[i], lname) == 0 and (category == null or c.g_strcmp0(tt.category, category) == 0)) {
                    t = @ptrCast(c.gst_object_ref(tt));
                    break :outer;
                }
            }
        }
        c.g_list_free_full(all, @ptrCast(&c.gst_object_unref));
    }
    return t;
}

pub export fn gst_encoding_target_save_to_file(t: OTarget, filepath: [*c]const c.gchar, err: [*c][*c]c.GError) c.gboolean {
    if (!check.that(isTarget(t), "gst_encoding_target_save_to_file", "GST_IS_ENCODING_TARGET (target)")) return 0;
    if (!check.that(filepath != null, "gst_encoding_target_save_to_file", "filepath != NULL")) return 0;
    const out = c.g_key_file_new();
    defer c.g_key_file_free(out);
    const tt = of(t);
    c.g_key_file_set_string(out, HEADER, "name", tt.name);
    c.g_key_file_set_string(out, HEADER, "category", tt.category);
    c.g_key_file_set_string(out, HEADER, "description", tt.description);
    var l = tt.profiles;
    while (l != null) : (l = l[0].next) writeProfile(out, @ptrCast(l[0].data));
    var size: usize = 0;
    const data = c.g_key_file_to_data(out, &size, err);
    if (data == null) return 0;
    defer c.g_free(data);
    if (c.g_file_set_contents(filepath, data, @intCast(size), err) == 0) return 0;
    tt.path = c.g_strdup(filepath);
    return 1;
}

pub export fn gst_encoding_target_save(t: OTarget, err: [*c][*c]c.GError) c.gboolean {
    if (!check.that(isTarget(t), "gst_encoding_target_save", "GST_IS_ENCODING_TARGET (target)")) return 0;
    const tt = of(t);
    if (!check.that(tt.category != null, "gst_encoding_target_save", "target->category != NULL")) return 0;
    const lfile = c.g_strdup_printf("%s.gep", tt.name);
    const dir = userDir(tt.category);
    if (c.g_mkdir_with_parents(dir, 0o755) != 0) {
        c.g_free(dir);
        c.g_free(lfile);
        return 0;
    }
    const f = c.g_build_filename(dir, lfile, @as([*c]const u8, null));
    c.g_free(dir);
    c.g_free(lfile);
    _ = gst_encoding_target_save_to_file(t, f, err);
    c.g_free(f);
    return 1;
}

fn categories(path: [*c]const u8) [*c]c.GList {
    var res: [*c]c.GList = null;
    const dir = c.g_dir_open(path, 0, null);
    if (dir == null) return null;
    while (true) {
        const sub = c.g_dir_read_name(dir);
        if (sub == null) break;
        const full = c.g_build_filename(path, sub, @as([*c]const u8, null));
        if (c.g_file_test(full, c.G_FILE_TEST_IS_DIR) != 0) res = c.g_list_append(res, c.g_strdup(sub));
        c.g_free(full);
    }
    c.g_dir_close(dir);
    return res;
}

fn strcmp0(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return c.g_strcmp0(@ptrCast(a), @ptrCast(b));
}

pub export fn gst_encoding_list_available_categories() [*c]c.GList {
    const ud = userDir(null);
    var res = categories(ud);
    c.g_free(ud);
    const sd = systemDir();
    const more = categories(sd);
    c.g_free(sd);
    var l = more;
    while (l != null) : (l = l[0].next) {
        if (c.g_list_find_custom(res, l[0].data, strcmp0) == null) res = c.g_list_append(res, l[0].data) else c.g_free(l[0].data);
    }
    c.g_list_free(more);
    return res;
}

fn targetsIn(sub: [*c]const u8) [*c]c.GList {
    var res: [*c]c.GList = null;
    const dir = c.g_dir_open(sub, 0, null);
    if (dir == null) return null;
    while (true) {
        const f = c.g_dir_read_name(dir);
        if (f == null) break;
        if (c.g_str_has_suffix(f, ".gep") == 0) continue;
        const full = c.g_build_filename(sub, f, @as([*c]const u8, null));
        const t = gst_encoding_target_load_from_file(full, null);
        if (t != null) {
            of(t).path = full;
            res = c.g_list_append(res, t);
        } else c.g_free(full);
    }
    c.g_dir_close(dir);
    return res;
}

fn allTargets(top: [*c]const u8, category: [*c]const u8) [*c]c.GList {
    if (category != null) {
        const sub = c.g_build_filename(top, category, @as([*c]const u8, null));
        defer c.g_free(sub);
        return targetsIn(sub);
    }
    var res: [*c]c.GList = null;
    const dir = c.g_dir_open(top, 0, null);
    if (dir == null) return null;
    while (true) {
        const sub = c.g_dir_read_name(dir);
        if (sub == null) break;
        const full = c.g_build_filename(top, sub, @as([*c]const u8, null));
        if (c.g_file_test(full, c.G_FILE_TEST_IS_DIR) != 0) res = c.g_list_concat(res, targetsIn(full));
        c.g_free(full);
    }
    c.g_dir_close(dir);
    return res;
}

fn compareTargets(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const x = of(@constCast(a));
    const y = of(@constCast(b));
    if (c.g_strcmp0(x.name, y.name) != 0 or c.g_strcmp0(x.category, y.category) != 0) return -1;
    return 0;
}

fn merge(res_in: [*c]c.GList, extra: [*c]c.GList) [*c]c.GList {
    var res = res_in;
    var l = extra;
    while (l != null) : (l = l[0].next) {
        if (c.g_list_find_custom(res, l[0].data, compareTargets) != null) c.g_object_unref(l[0].data) else res = c.g_list_append(res, l[0].data);
    }
    c.g_list_free(extra);
    return res;
}

pub export fn gst_encoding_list_all_targets(categoryname: [*c]const c.gchar) [*c]c.GList {
    var res: [*c]c.GList = null;
    const env = c.g_getenv("GST_ENCODING_TARGET_PATH");
    if (env != null) {
        const dirs = c.g_strsplit(env, ":", -1);
        var i: usize = 0;
        while (dirs[i] != null) : (i += 1) res = merge(res, allTargets(dirs[i], categoryname));
        c.g_strfreev(dirs);
    }
    const ud = userDir(null);
    res = merge(res, allTargets(ud, categoryname));
    c.g_free(ud);
    const sd = systemDir();
    res = merge(res, allTargets(sd, categoryname));
    c.g_free(sd);
    return res;
}
