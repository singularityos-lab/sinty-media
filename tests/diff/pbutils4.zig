const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);
const P = ?*c.GstEncodingProfile;

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn capsS(cp: [*c]c.GstCaps) []const u8 {
    if (cp == null) return "-";
    const s = c.gst_caps_to_string(cp);
    c.gst_caps_unref(cp);
    return z(s);
}

fn tname(o: anytype) []const u8 {
    if (o == null) return "-";
    return z(c.g_type_name_from_instance(@ptrCast(@alignCast(o))));
}

fn dump(prefix: []const u8, p: P, depth: usize) void {
    if (p == null) {
        out("{s}profile -", .{prefix});
        return;
    }
    const ep = c.gst_encoding_profile_get_element_properties(p);
    const eps = if (ep != null) c.gst_structure_to_string(ep) else null;
    out("{s}{s} nick={s} name={s} desc={s} fmt={s} preset={s} pname={s} presence={d} en={d} dyn={d} seg={d} restr={s} eprops={s} input={s} ext={s}", .{ prefix, tname(p), z(c.gst_encoding_profile_get_type_nick(p)), z(c.gst_encoding_profile_get_name(p)), z(c.gst_encoding_profile_get_description(p)), capsS(c.gst_encoding_profile_get_format(p)), z(c.gst_encoding_profile_get_preset(p)), z(c.gst_encoding_profile_get_preset_name(p)), c.gst_encoding_profile_get_presence(p), c.gst_encoding_profile_is_enabled(p), c.gst_encoding_profile_get_allow_dynamic_output(p), c.gst_encoding_profile_get_single_segment(p), capsS(c.gst_encoding_profile_get_restriction(p)), z(eps), capsS(c.gst_encoding_profile_get_input_caps(p)), z(c.gst_encoding_profile_get_file_extension(p)) });
    if (ep != null) c.gst_structure_free(ep);
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(p)), c.gst_encoding_video_profile_get_type()) != 0) {
        out("{s}  pass={d} vfr={d}", .{ prefix, c.gst_encoding_video_profile_get_pass(@ptrCast(p)), c.gst_encoding_video_profile_get_variableframerate(@ptrCast(p)) });
    }
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(p)), c.gst_encoding_container_profile_get_type()) != 0) {
        var l: [*c]const c.GList = c.gst_encoding_container_profile_get_profiles(@ptrCast(p));
        var buf: [64]u8 = undefined;
        const np = std.fmt.bufPrint(&buf, "{s}  ", .{prefix}) catch prefix;
        while (l != null) : (l = l[0].next) dump(np, @ptrCast(l[0].data), depth + 1);
    }
    const s = c.gst_encoding_profile_to_string(p);
    out("{s}  str={s}", .{ prefix, z(s) });
    c.g_free(s);
}

fn caps(s: [*c]const u8) [*c]c.GstCaps {
    return c.gst_caps_from_string(s);
}

fn notify(_: ?*c.GObject, pspec: [*c]c.GParamSpec, _: c.gpointer) callconv(.c) void {
    out("  notify {s}", .{z(pspec[0].name)});
}

fn fromString(s: [*c]const u8) void {
    out("from '{s}'", .{z(s)});
    const p = c.gst_encoding_profile_from_string(s);
    dump("  ", p, 0);
    if (p != null) c.g_object_unref(p);
}

fn basics() void {
    out("== basics", .{});
    const cont = c.gst_encoding_container_profile_new("cont", "A container", caps("application/ogg"), "pre");
    const v = c.gst_encoding_video_profile_new(caps("video/x-theora"), "vpre", caps("video/x-raw, width=320"), 1);
    const a = c.gst_encoding_audio_profile_new(caps("audio/x-vorbis"), null, caps("audio/x-raw, channels=2; audio/x-raw, channels=1"), 0);
    _ = c.g_signal_connect_data(v, "notify", @ptrCast(&notify), null, null, 0);
    c.gst_encoding_video_profile_set_pass(v, 2);
    c.gst_encoding_video_profile_set_variableframerate(v, 1);
    c.gst_encoding_profile_set_name(@ptrCast(v), "vid");
    c.gst_encoding_profile_set_description(@ptrCast(v), "video stream");
    c.gst_encoding_profile_set_preset_name(@ptrCast(v), "theoraenc");
    c.gst_encoding_profile_set_enabled(@ptrCast(v), 0);
    c.gst_encoding_profile_set_allow_dynamic_output(@ptrCast(v), 0);
    c.gst_encoding_profile_set_single_segment(@ptrCast(v), 1);
    c.gst_encoding_profile_set_restriction(@ptrCast(v), caps("video/x-raw, height=240"));
    c.gst_encoding_profile_set_element_properties(@ptrCast(v), c.gst_structure_from_string("properties, bitrate=100", null));
    c.gst_encoding_profile_set_element_properties(@ptrCast(v), c.gst_structure_from_string("map, foo=1", null));
    c.gst_encoding_profile_set_element_properties(@ptrCast(v), c.gst_structure_from_string("element-properties-map, map={ [x, a=1] }", null));
    var rc: [*c]c.GstCaps = null;
    var es: ?*c.GstStructure = null;
    c.g_object_get(v, "restriction-caps", &rc, "element-properties", &es, NONE);
    out("  props {s} {s}", .{ capsS(rc), z(if (es != null) c.gst_structure_to_string(es) else null) });
    c.g_object_set(v, "restriction-caps", caps("video/x-raw, height=480"), "element-properties", c.gst_structure_from_string("properties, q=5", null), NONE);
    c.g_object_set(v, "element-properties", @as(?*c.GstStructure, null), NONE);
    out("  add {d} {d} {d}", .{ c.gst_encoding_container_profile_add_profile(cont, @ptrCast(v)), c.gst_encoding_container_profile_add_profile(cont, @ptrCast(a)), c.gst_encoding_container_profile_contains_profile(cont, @ptrCast(a)) });
    dump("  ", @ptrCast(cont), 0);
    const cp = c.gst_encoding_profile_copy(@ptrCast(cont));
    dump("  copy ", cp, 0);
    out("  equal {d} {d} {d}", .{ c.gst_encoding_profile_is_equal(@ptrCast(cont), cp), c.gst_encoding_profile_is_equal(@ptrCast(v), @ptrCast(a)), c.gst_encoding_profile_is_equal(@ptrCast(a), @ptrCast(a)) });
    const v2 = c.gst_encoding_profile_copy(@ptrCast(v));
    c.gst_encoding_video_profile_set_pass(@ptrCast(v2), 1);
    out("  equal v {d} contains {d}", .{ c.gst_encoding_profile_is_equal(@ptrCast(v), v2), c.gst_encoding_container_profile_contains_profile(cont, v2) });
    const other = c.gst_encoding_container_profile_new("cont", "A container", caps("application/ogg"), "pre");
    _ = c.gst_encoding_container_profile_add_profile(other, c.gst_encoding_profile_copy(@ptrCast(a)));
    _ = c.gst_encoding_container_profile_add_profile(other, c.gst_encoding_profile_copy(@ptrCast(a)));
    out("  equal containers {d}", .{c.gst_encoding_profile_is_equal(@ptrCast(cont), @ptrCast(other))});
    c.g_object_unref(cp);
    c.g_object_unref(v2);
    c.g_object_unref(other);
    c.g_object_unref(cont);
}

fn extensions() void {
    out("== ext", .{});
    const cases = [_]struct { [*c]const u8, []const [*c]const u8 }{
        .{ "application/ogg", &.{ "video/x-theora", "audio/x-vorbis" } },
        .{ "application/ogg", &.{"audio/x-speex"} },
        .{ "application/ogg", &.{"audio/x-vorbis"} },
        .{ "application/ogg", &.{} },
        .{ "audio/x-matroska", &.{ "video/x-vp8", "audio/x-vorbis" } },
        .{ "audio/x-matroska", &.{"audio/x-vorbis"} },
        .{ "video/x-ms-asf", &.{ "video/x-wmv", "audio/x-wma" } },
        .{ "video/x-ms-asf", &.{"audio/x-wma"} },
        .{ "video/x-ms-asf", &.{"video/x-wmv"} },
        .{ "video/x-ms-asf", &.{ "video/x-wmv", "audio/mpeg" } },
        .{ "application/x-id3", &.{"audio/mpeg, mpegversion=1, layer=3"} },
        .{ "application/x-id3", &.{ "audio/mpeg, mpegversion=1, layer=3", "audio/mpeg" } },
        .{ "application/x-apetag", &.{"audio/x-flac"} },
        .{ "video/quicktime", &.{"video/x-h264"} },
        .{ "video/x-matroska", &.{"video/x-h264"} },
    };
    for (cases) |cs| {
        const cont = c.gst_encoding_container_profile_new(null, null, caps(cs[0]), null);
        for (cs[1]) |child| {
            const cc = caps(child);
            const isv = c.g_str_has_prefix(child, "video/") != 0;
            const p: P = if (isv) @ptrCast(c.gst_encoding_video_profile_new(cc, null, null, 0)) else @ptrCast(c.gst_encoding_audio_profile_new(cc, null, null, 0));
            _ = c.gst_encoding_container_profile_add_profile(cont, p);
        }
        out("{s} [{d}] -> {s}", .{ z(cs[0]), cs[1].len, z(c.gst_encoding_profile_get_file_extension(@ptrCast(cont))) });
        c.g_object_unref(cont);
    }
    const nested = c.gst_encoding_container_profile_new(null, null, caps("application/ogg"), null);
    const inner = c.gst_encoding_container_profile_new(null, null, caps("video/x-matroska"), null);
    _ = c.gst_encoding_container_profile_add_profile(inner, @ptrCast(c.gst_encoding_video_profile_new(caps("video/x-vp8"), null, null, 0)));
    _ = c.gst_encoding_container_profile_add_profile(nested, @ptrCast(inner));
    out("nested {s}", .{z(c.gst_encoding_profile_get_file_extension(@ptrCast(nested)))});
    for ([_][*c]const u8{ "audio/mpeg, mpegversion=1, layer=2", "audio/mpeg, mpegversion=4", "video/x-h264", "audio/x-raw" }) |s| {
        const a = c.gst_encoding_audio_profile_new(caps(s), null, null, 0);
        out("single {s} -> {s}", .{ z(s), z(c.gst_encoding_profile_get_file_extension(@ptrCast(a))) });
        c.g_object_unref(a);
    }
}

fn strings() void {
    out("== strings", .{});
    for ([_][*c]const u8{
        "application/ogg:video/x-theora:audio/x-vorbis",
        "video/webm:video/x-vp8|1:audio/x-vorbis|2",
        "video/webm:video/x-vp8+mypreset|1:audio/x-vorbis+other",
        "video/x-raw,width=640->video/x-vp8",
        "audio/x-raw,channels=1->audio/x-vorbis|presence=3|single-segment=true",
        "audio/x-vorbis|variable-framerate=true",
        "video/x-vp8|variable-framerate=true",
        "video/x-vp8|variable-framerate=nope",
        "video/x-vp8|single-segment=maybe",
        "video/x-vp8|a=b=c",
        "video/x-vp8|unknown=1",
        "video/x-vp8|factory-name=vp8enc|factory-name=x",
        "video/x-vp8|factory-name=vp8enc",
        "video/x-vp8|element-properties,deadline=1|presence=4",
        "video/x-vp8|properties,a=1,b=2|other,c=3",
        "video/x-vp8|presence",
        "video/x-vp8|abc",
        "video/x-vp8|1x",
        "vp8enc",
        "vp8enc,deadline=1",
        "oggmux:vorbisenc:theoraenc",
        "matroskamux:opusenc",
        "webmmux",
        "audio/x-raw",
        "video/x-raw:audio/x-raw",
        "audio/x-vorbis:video/x-theora",
        "application/ogg:video/x-nonexisting",
        "nonexisting",
        "identity",
        "",
        ":::",
        "application/ogg::audio/x-vorbis",
        "video/x-vp8\\:x",
        "a/b/c/d",
        "mytarget/myprofile",
        "file.gep",
        "file.gep:prof",
        "file.gepx",
    }) |s| fromString(s);
    var v = std.mem.zeroes(c.GValue);
    var sv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&sv, c.G_TYPE_STRING);
    c.g_value_set_string(&sv, "application/ogg:audio/x-vorbis");
    _ = c.g_value_init(&v, c.gst_encoding_profile_get_type());
    out("transform {d}", .{c.g_value_transform(&sv, &v)});
    dump("  ", @ptrCast(c.g_value_get_object(&v)), 0);
    const ser = c.gst_value_serialize(&v);
    out("serialize {s}", .{z(ser)});
    var v2 = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v2, c.gst_encoding_profile_get_type());
    out("deserialize {d} {d}", .{ c.gst_value_deserialize(&v2, "video/webm:video/x-vp8"), c.gst_value_deserialize(&v2, "nope/nope") });
    dump("  ", @ptrCast(c.g_value_get_object(&v2)), 0);
    const st = c.gst_structure_from_string("s, p=(GstEncodingProfile)\"application/ogg:audio/x-vorbis\"", null);
    out("structure {s}", .{z(if (st != null) c.gst_structure_to_string(st) else null)});
}

fn targets(dir: [*c]const u8) void {
    out("== targets", .{});
    const p1 = c.gst_encoding_container_profile_new("default", "Default profile", caps("application/ogg"), "pre");
    const v = c.gst_encoding_video_profile_new(caps("video/x-theora"), "vp", caps("video/x-raw, width=(int)320"), 1);
    c.gst_encoding_video_profile_set_pass(v, 2);
    c.gst_encoding_profile_set_name(@ptrCast(v), "video");
    _ = c.gst_encoding_container_profile_add_profile(p1, @ptrCast(v));
    _ = c.gst_encoding_container_profile_add_profile(p1, @ptrCast(c.gst_encoding_audio_profile_new(caps("audio/x-vorbis"), null, null, 0)));
    const p2 = c.gst_encoding_audio_profile_new(caps("audio/x-flac"), null, null, 0);
    c.gst_encoding_profile_set_name(@ptrCast(p2), "flac");
    c.gst_encoding_profile_set_description(@ptrCast(p2), "lossless");
    for ([_][3][*c]const u8{ .{ "Bad", "cat", "d" }, .{ "1bad", "cat", "d" }, .{ "good", "Cat", "d" }, .{ "go_od", "cat", "d" }, .{ "go-od;x2", "c-at", "d" }, .{ "", "cat", "d" } }) |n| {
        const t = c.gst_encoding_target_new(n[0], n[1], n[2], null);
        out("new {s} {s} -> {d}", .{ z(n[0]), z(n[1]), @intFromBool(t != null) });
        if (t != null) c.g_object_unref(t);
    }
    var list: [*c]c.GList = null;
    list = c.g_list_append(list, p1);
    const t = c.gst_encoding_target_new("my-target;alias", "mycat", "My target", list);
    out("add {d} {d}", .{ c.gst_encoding_target_add_profile(t, @ptrCast(p2)), c.gst_encoding_target_add_profile(t, @ptrCast(c.gst_encoding_audio_profile_new(caps("audio/x-flac"), null, null, 0))) });
    out("target {s} {s} {s} {s} n={d}", .{ z(c.gst_encoding_target_get_name(t)), z(c.gst_encoding_target_get_category(t)), z(c.gst_encoding_target_get_description(t)), z(c.gst_encoding_target_get_path(t)), c.g_list_length(@constCast(c.gst_encoding_target_get_profiles(t))) });
    const gp = c.gst_encoding_target_get_profile(t, "flac");
    out("get {s} {d}", .{ tname(gp), @intFromBool(c.gst_encoding_target_get_profile(t, "nope") != null) });
    const file = c.g_build_filename(dir, "cat1", "explicit.gep", NONE);
    _ = c.g_mkdir_with_parents(c.g_path_get_dirname(file), 0o755);
    out("save_to_file {d} path={s}", .{ c.gst_encoding_target_save_to_file(t, file, null), z(if (c.gst_encoding_target_get_path(t) != null) c.g_path_get_basename(c.gst_encoding_target_get_path(t)) else null) });
    var data: [*c]u8 = null;
    _ = c.g_file_get_contents(file, &data, null, null);
    out("file:\n{s}", .{z(data)});
    var err: [*c]c.GError = null;
    out("save {d}", .{c.gst_encoding_target_save(t, &err)});
    const loaded = c.gst_encoding_target_load_from_file(file, null);
    out("loaded {s} {s} {s} n={d}", .{ z(c.gst_encoding_target_get_name(loaded)), z(c.gst_encoding_target_get_category(loaded)), z(c.gst_encoding_target_get_description(loaded)), c.g_list_length(@constCast(c.gst_encoding_target_get_profiles(loaded))) });
    var l: [*c]const c.GList = c.gst_encoding_target_get_profiles(loaded);
    while (l != null) : (l = l[0].next) dump("  ", @ptrCast(l[0].data), 0);
    var e2: [*c]c.GError = null;
    out("load missing {d} err={s}", .{ @intFromBool(c.gst_encoding_target_load_from_file("/nonexistent/x.gep", &e2) != null), z(if (e2 != null) e2[0].message else null) });
    const bad = c.g_build_filename(dir, "bad.gep", NONE);
    _ = c.g_file_set_contents(bad, "[GStreamer Encoding Target]\ncategory=x\n", -1, null);
    var e3: [*c]c.GError = null;
    out("load noname {d} err={s}", .{ @intFromBool(c.gst_encoding_target_load_from_file(bad, &e3) != null), z(if (e3 != null) e3[0].message else null) });
    const odd = c.g_build_filename(dir, "cat1", "odd.gep", NONE);
    _ = c.g_file_set_contents(odd, "[GStreamer Encoding Target]\nname=odd\ncategory=cat1\ndescription=Odd\n\n[profile-a]\nname=a\ntype=container\nformat=application/ogg\ndescription=Plain\ndescription[it]=Italiano\n\n[streamprofile-a-0]\nparent=a;b\ntype=audio\nformat=audio/x-vorbis\npresence=2\n\n[streamprofile-x]\nparent=zzz\ntype=video\nformat=video/x-vp8\n\n[profile-b]\nname=b\ntype=video\nformat=video/x-vp8\npass=3\nvariableframerate=true\nrestriction=video/x-raw\n\n[profile-c]\nname=c\ntype=weird\n\n[profile-d]\nname=d\n", -1, null);
    const ot = c.gst_encoding_target_load_from_file(odd, null);
    l = c.gst_encoding_target_get_profiles(ot);
    while (l != null) : (l = l[0].next) dump("  odd ", @ptrCast(l[0].data), 0);
    for ([_][2][*c]const u8{ .{ "explicit", "cat1" }, .{ "odd", null }, .{ "ODD", "cat1" }, .{ "my-target", null }, .{ "alias", null }, .{ "alias", "mycat" }, .{ "alias", "other" }, .{ "nope", null }, .{ "Bad Name", null }, .{ "odd", "Bad" } }) |q| {
        const lt = c.gst_encoding_target_load(q[0], q[1], null);
        out("load {s} {s} -> {s} path={s}", .{ z(q[0]), z(q[1]), z(if (lt != null) c.gst_encoding_target_get_name(lt) else null), z(if (lt != null and c.gst_encoding_target_get_path(lt) != null) c.g_path_get_basename(c.gst_encoding_target_get_path(lt)) else null) });
    }
    for ([_][3][*c]const u8{ .{ "odd", "a", null }, .{ "odd", null, null }, .{ "explicit", "default", "cat1" }, .{ "explicit", "flac", null } }) |q| {
        const fp = c.gst_encoding_profile_find(q[0], q[1], q[2]);
        out("find {s} {s} {s} -> {s}", .{ z(q[0]), z(q[1]), z(q[2]), tname(fp) });
    }
    fromString("explicit/flac");
    fromString("odd/a/cat1");
    fromString("odd");
    const gepname = c.g_strdup_printf("%s:flac", file);
    fromString(gepname);
    fromString(file);
    var all = c.gst_encoding_list_all_targets(null);
    out("all {d}", .{c.g_list_length(all)});
    while (all != null) : (all = all[0].next) out("  {s} {s} {s}", .{ z(c.gst_encoding_target_get_name(@ptrCast(all[0].data))), z(c.gst_encoding_target_get_category(@ptrCast(all[0].data))), z(c.g_path_get_basename(c.gst_encoding_target_get_path(@ptrCast(all[0].data)))) });
    out("all cat1 {d}", .{c.g_list_length(c.gst_encoding_list_all_targets("cat1"))});
    var cats = c.gst_encoding_list_available_categories();
    while (cats != null) : (cats = cats[0].next) out("  category {s}", .{z(@ptrCast(cats[0].data))});
}

fn checks() void {
    out("== checks", .{});
    _ = c.gst_encoding_profile_get_name(null);
    _ = c.gst_encoding_profile_get_format(null);
    c.gst_encoding_profile_set_name(null, "x");
    c.gst_encoding_profile_set_restriction(null, null);
    const b = c.gst_buffer_new();
    c.gst_encoding_profile_set_restriction(null, @ptrCast(b));
    c.gst_encoding_profile_set_element_properties(null, null);
    const a = c.gst_encoding_audio_profile_new(caps("audio/x-vorbis"), null, null, 0);
    c.gst_encoding_profile_set_element_properties(@ptrCast(a), @ptrCast(b));
    _ = c.gst_encoding_profile_get_element_properties(null);
    _ = c.gst_encoding_container_profile_get_profiles(@ptrCast(a));
    _ = c.gst_encoding_video_profile_get_pass(@ptrCast(a));
    c.gst_encoding_video_profile_set_variableframerate(@ptrCast(a), 1);
    out("{d}", .{c.gst_encoding_container_profile_add_profile(@ptrCast(a), @ptrCast(a))});
    out("{d}", .{c.gst_encoding_container_profile_contains_profile(null, @ptrCast(a))});
    out("{d}", .{@intFromBool(c.gst_encoding_container_profile_new("x", "y", null, null) != null)});
    out("{d}", .{c.gst_encoding_profile_is_equal(null, @ptrCast(a))});
    _ = c.gst_encoding_profile_get_input_caps(null);
    _ = c.gst_encoding_profile_get_file_extension(null);
    _ = c.gst_encoding_profile_to_string(null);
    _ = c.gst_encoding_profile_find(null, null, null);
    _ = c.gst_encoding_target_new(null, "c", "d", null);
    _ = c.gst_encoding_target_new("n", null, "d", null);
    _ = c.gst_encoding_target_new("n", "c", null, null);
    _ = c.gst_encoding_target_get_path(null);
    _ = c.gst_encoding_target_get_profile(null, "x");
    _ = c.gst_encoding_target_add_profile(null, null);
    _ = c.gst_encoding_target_load(null, null, null);
    _ = c.gst_encoding_target_save_to_file(null, "x", null);
    _ = c.gst_encoding_target_save(null, null);
    var bogus = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&bogus, c.G_TYPE_INT);
    const ps = c.g_param_spec_int("bogus", "b", "b", 0, 1, 0, c.G_PARAM_READWRITE);
    const k: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_peek(c.gst_encoding_profile_get_type())));
    k.get_property.?(@ptrCast(@alignCast(a)), 9, &bogus, ps);
    k.set_property.?(@ptrCast(@alignCast(a)), 9, &bogus, ps);
}

pub fn main() void {
    _ = c.g_spawn_command_line_sync("rm -rf zig-out/pbu4", null, null, null, null);
    const cwd = c.g_get_current_dir();
    const dir = c.g_build_filename(cwd, "zig-out", "pbu4", NONE);
    _ = c.g_setenv("XDG_DATA_HOME", c.g_build_filename(dir, "xdg", NONE), 1);
    _ = c.g_setenv("GST_ENCODING_TARGET_PATH", c.g_strdup_printf("%s:%s/nothing", dir, dir), 1);
    _ = c.g_setenv("LC_ALL", "C", 1);
    c.gst_init(null, null);
    basics();
    extensions();
    strings();
    targets(dir);
    checks();
}
