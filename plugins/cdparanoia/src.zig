const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const cd = @import("cd.zig").p;

const FILE = "../ext/cdparanoia/gstcdparanoiasrc.c";
const DOMAIN = "gst-plugins-base-1.0";
const RAW = 2352;
const WORDS = RAW / 2;

const Prop = enum(c.guint) { read_speed = 1, paranoia_mode, search_overlap, generic_device, cache_size };
const Sig = enum { transport_error, uncorrected_error };

const Self = extern struct {
    audiocdsrc: c.GstAudioCdSrc,
    d: ?*cd.cdrom_drive,
    p: ?*cd.cdrom_paranoia,
    next_sector: c.gint,
    paranoia_mode: c.gint,
    read_speed: c.gint,
    search_overlap: c.gint,
    cache_size: c.gint,
    generic_device: [*c]u8,
};

const Class = extern struct {
    parent: c.GstAudioCdSrcClass,
    transport_error: ?*const fn (*Self, c.gint) callconv(.c) void,
    uncorrected_error: ?*const fn (*Self, c.gint) callconv(.c) void,
};

var once: cm.Once = .{};
var mode_once: cm.Once = .{};
var parent_obj: *c.GObjectClass = undefined;
var signals: [2]c.guint = .{ 0, 0 };
var cb_source: ?*Self = null;
var cb_mutex: c.GMutex = std.mem.zeroes(c.GMutex);

fn me(x: anytype) *Self {
    return @ptrCast(@alignCast(x));
}

fn modeType() c.GType {
    return mode_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = cd.PARANOIA_MODE_DISABLE, .value_name = "PARANOIA_MODE_DISABLE", .value_nick = "disable" },
            .{ .value = cd.PARANOIA_MODE_FRAGMENT, .value_name = "PARANOIA_MODE_FRAGMENT", .value_nick = "fragment" },
            .{ .value = cd.PARANOIA_MODE_OVERLAP, .value_name = "PARANOIA_MODE_OVERLAP", .value_nick = "overlap" },
            .{ .value = cd.PARANOIA_MODE_SCRATCH, .value_name = "PARANOIA_MODE_SCRATCH", .value_nick = "scratch" },
            .{ .value = cd.PARANOIA_MODE_REPAIR, .value_name = "PARANOIA_MODE_REPAIR", .value_nick = "repair" },
            .{ .value = cd.PARANOIA_MODE_FULL, .value_name = "PARANOIA_MODE_FULL", .value_nick = "full" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static("GstCdParanoiaMode", &values);
        }
    }.f);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.d = null;
    s.p = null;
    s.next_sector = -1;
    s.search_overlap = -1;
    s.paranoia_mode = cd.PARANOIA_MODE_FRAGMENT;
    s.read_speed = -1;
    s.generic_device = null;
    s.cache_size = -1;
}

fn openError(s: *Self, detail: [*:0]const u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup(cm.tr(DOMAIN, "Could not open CD device for reading.")), c.g_strdup(detail), FILE, "gst_cd_paranoia_src_open", line);
}

fn open(acs: [*c]c.GstAudioCdSrc, device: [*c]const u8) callconv(.c) c.gboolean {
    const s = me(acs);
    if (s.generic_device != null) {
        s.d = cd.cdda_identify_scsi(s.generic_device, device, 0, null);
    } else {
        s.d = cd.cdda_identify(if (device != null) device else "/dev/cdrom", 0, null);
    }
    const d = s.d orelse {
        openError(s, "cdda_identify failed", 283);
        return 0;
    };
    cd.cdda_verbose_set(d, cd.CDDA_MESSAGE_FORGETIT, cd.CDDA_MESSAGE_FORGETIT);
    if (cd.cdda_open(d) != 0) {
        openError(s, "cdda_open failed", 289);
        _ = cd.cdda_close(d);
        s.d = null;
        return 0;
    }
    _ = cd.cdda_speed_set(d, s.read_speed);
    var i: c_int = 1;
    while (i < d.tracks + 1) : (i += 1) {
        var track = std.mem.zeroes(c.GstAudioCdSrcTrack);
        track.num = @bitCast(i);
        track.is_audio = @intFromBool(d.disc_toc[@intCast(i - 1)].bFlags & 0x04 == 0);
        track.start = @truncate(@as(c_ulong, @bitCast(cd.cdda_track_firstsector(d, i))));
        track.end = @truncate(@as(c_ulong, @bitCast(cd.cdda_track_lastsector(d, i))));
        track.tags = null;
        _ = c.gst_audio_cd_src_add_track(acs, &track);
    }
    s.p = cd.paranoia_init(d);
    if (s.p == null) {
        cm.elementError(s, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_INIT, c.g_strdup("failed to initialize paranoia"), c.g_strdup("failed to initialize paranoia"), FILE, "gst_cd_paranoia_src_open", 297);
        return 0;
    }
    cd.paranoia_modeset(s.p, s.paranoia_mode);
    if (s.search_overlap != -1) cd.paranoia_overlapset(s.p, s.search_overlap);
    var cache = s.cache_size;
    if (cache == -1) cache = if (s.paranoia_mode <= cd.PARANOIA_MODE_FRAGMENT) 150 else cd.paranoia_cachemodel_size(s.p, -1);
    _ = cd.paranoia_cachemodel_size(s.p, cache);
    s.next_sector = -1;
    return 1;
}

fn close(acs: [*c]c.GstAudioCdSrc) callconv(.c) void {
    const s = me(acs);
    if (s.p != null) cd.paranoia_free(s.p);
    s.p = null;
    if (s.d != null) _ = cd.cdda_close(s.d);
    s.d = null;
    s.next_sector = -1;
}

fn dummy(_: c_long, _: c_int) callconv(.c) void {}

fn callback(inpos: c_long, function: c_int) callconv(.c) void {
    const s = cb_source;
    const sector: c.gint = @truncate(@divTrunc(inpos, WORDS));
    switch (function) {
        cd.PARANOIA_CB_SKIP => c.g_signal_emit(s, signals[@intFromEnum(Sig.uncorrected_error)], 0, sector),
        cd.PARANOIA_CB_READERR => c.g_signal_emit(s, signals[@intFromEnum(Sig.transport_error)], 0, sector),
        else => {},
    }
}

fn watched(s: *Self, sig: Sig) bool {
    return c.g_signal_has_handler_pending(s, signals[@intFromEnum(sig)], 0, 0) != 0;
}

fn readSector(acs: [*c]c.GstAudioCdSrc, sector: c.gint) callconv(.c) [*c]c.GstBuffer {
    const s = me(acs);
    if (s.next_sector == -1 or s.next_sector != sector) {
        if (cd.paranoia_seek(s.p, sector, cd.SEEK_SET) == -1) {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_SEEK, c.g_strdup(cm.tr(DOMAIN, "Could not seek CD.")), c.g_strdup_printf("paranoia_seek to %d failed: %s", sector, c.g_strerror(std.c._errno().*)), FILE, "gst_cd_paranoia_src_read_sector", 415);
            return null;
        }
        s.next_sector = sector;
    }
    var buf: [*c]i16 = undefined;
    if (watched(s, .transport_error) or watched(s, .uncorrected_error)) {
        c.g_mutex_lock(&cb_mutex);
        cb_source = s;
        buf = cd.paranoia_read(s.p, callback);
        cb_source = null;
        c.g_mutex_unlock(&cb_mutex);
    } else buf = cd.paranoia_read(s.p, dummy);
    if (buf == null) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_READ, c.g_strdup(cm.tr(DOMAIN, "Could not read CD.")), c.g_strdup_printf("paranoia_read at %d failed: %s", sector, c.g_strerror(std.c._errno().*)), FILE, "gst_cd_paranoia_src_read_sector", 423);
        return null;
    }
    const out = c.gst_buffer_new_allocate(null, RAW, null);
    _ = c.gst_buffer_fill(out, 0, buf, RAW);
    s.next_sector += 1;
    return out;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_free(me(o).generic_device);
    parent_obj.finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        @intFromEnum(Prop.generic_device) => {
            c.g_free(s.generic_device);
            s.generic_device = c.g_value_dup_string(v);
            if (s.generic_device != null and s.generic_device[0] == 0) {
                c.g_free(s.generic_device);
                s.generic_device = null;
            }
        },
        @intFromEnum(Prop.read_speed) => {
            s.read_speed = c.g_value_get_int(v);
            if (s.read_speed == 0) s.read_speed = -1;
        },
        @intFromEnum(Prop.paranoia_mode) => s.paranoia_mode = @bitCast(c.g_value_get_flags(v) & cd.PARANOIA_MODE_FULL),
        @intFromEnum(Prop.search_overlap) => s.search_overlap = c.g_value_get_int(v),
        @intFromEnum(Prop.cache_size) => s.cache_size = c.g_value_get_int(v),
        else => cm.warnInvalid(FILE, o, id, spec, 477),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        @intFromEnum(Prop.read_speed) => c.g_value_set_int(v, s.read_speed),
        @intFromEnum(Prop.paranoia_mode) => c.g_value_set_flags(v, @bitCast(s.paranoia_mode)),
        @intFromEnum(Prop.generic_device) => c.g_value_set_string(v, s.generic_device),
        @intFromEnum(Prop.search_overlap) => c.g_value_set_int(v, s.search_overlap),
        @intFromEnum(Prop.cache_size) => c.g_value_set_int(v, s.cache_size),
        else => cm.warnInvalid(FILE, o, id, spec, 509),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_obj = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "CD Audio (cdda) Source, Paranoia IV", "Source/File", "Read audio from CD in paranoid mode", "Erik Walthinsen <omega@cse.ogi.edu>, Wim Taymans <wim@fluendo.com>");
    const ac: *c.GstAudioCdSrcClass = @ptrCast(@alignCast(k));
    ac.open = open;
    ac.close = close;
    ac.read_sector = readSector;
    c.g_object_class_install_property(oc, @intFromEnum(Prop.generic_device), c.g_param_spec_string("generic-device", "Generic device", "Use specified generic scsi device", null, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.read_speed), c.g_param_spec_int("read-speed", "Read speed", "Read from device at specified speed (-1 and 0 = full speed)", -1, std.math.maxInt(c.gint), -1, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.paranoia_mode), c.g_param_spec_flags("paranoia-mode", "Paranoia mode", "Type of checking to perform", modeType(), cd.PARANOIA_MODE_FRAGMENT, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.search_overlap), c.g_param_spec_int("search-overlap", "Search overlap", "Force minimum overlap search during verification to n sectors", -1, 75, -1, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.cache_size), c.g_param_spec_int("cache-size", "Cache size", "Set CD cache size to n sectors (-1 = auto)", -1, std.math.maxInt(c.gint), -1, cm.RW));
    signals[@intFromEnum(Sig.transport_error)] = c.g_signal_new("transport-error", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "transport_error"), null, null, null, c.G_TYPE_NONE, 1, c.G_TYPE_INT);
    signals[@intFromEnum(Sig.uncorrected_error)] = c.g_signal_new("uncorrected-error", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "uncorrected_error"), null, null, null, c.G_TYPE_NONE, 1, c.G_TYPE_INT);
    c.gst_type_mark_as_plugin_api(modeType(), 0);
    _ = c._gst_debug_category_new("cdparanoiasrc", 0, "CD Paranoia Source");
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_audio_cd_src_get_type(), "GstCdParanoiaSrc", Class, Self, classInit, init);
        }
    }.f);
}
