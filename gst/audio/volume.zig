const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const libm = @import("../libm.zig");
const pow = libm.pow;
const log10 = libm.log10;

const Vol = c.GstStreamVolume;
const NONE = @as(?*anyopaque, null);

var type_once: gtype.Once = .{};

fn classInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_object_interface_install_property(iface, c.g_param_spec_double("volume", "Volume", "Linear volume factor, 1.0=100%", 0.0, std.math.floatMax(f64), 1.0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_interface_install_property(iface, c.g_param_spec_boolean("mute", "Mute", "Mute the audio channel without changing the volume", 0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
}

pub export fn gst_stream_volume_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = c.g_type_register_static_simple(c.G_TYPE_INTERFACE, "GstStreamVolume", @sizeOf(c.GstStreamVolumeInterface), classInit, 0, null, 0);
            c.g_type_interface_add_prerequisite(t, c.G_TYPE_OBJECT);
            return t;
        }
    }.f);
}

fn isVolume(v: ?*Vol) bool {
    return gtype.instanceOf(v, gst_stream_volume_get_type());
}

pub export fn gst_stream_volume_get_volume(v: ?*Vol, fmt: c.GstStreamVolumeFormat) f64 {
    if (!check.that(isVolume(v), "gst_stream_volume_get_volume", "GST_IS_STREAM_VOLUME (volume)")) return 1.0;
    var val: f64 = 0;
    c.g_object_get(v, "volume", &val, NONE);
    if (fmt != c.GST_STREAM_VOLUME_FORMAT_LINEAR) val = gst_stream_volume_convert_volume(c.GST_STREAM_VOLUME_FORMAT_LINEAR, fmt, val);
    return val;
}

pub export fn gst_stream_volume_set_volume(v: ?*Vol, fmt: c.GstStreamVolumeFormat, val_in: f64) void {
    if (!check.that(isVolume(v), "gst_stream_volume_set_volume", "GST_IS_STREAM_VOLUME (volume)")) return;
    var val = val_in;
    if (fmt != c.GST_STREAM_VOLUME_FORMAT_LINEAR) val = gst_stream_volume_convert_volume(fmt, c.GST_STREAM_VOLUME_FORMAT_LINEAR, val);
    c.g_object_set(v, "volume", val, NONE);
}

pub export fn gst_stream_volume_get_mute(v: ?*Vol) c.gboolean {
    if (!check.that(isVolume(v), "gst_stream_volume_get_mute", "GST_IS_STREAM_VOLUME (volume)")) return 0;
    var val: c.gboolean = 0;
    c.g_object_get(v, "mute", &val, NONE);
    return val;
}

pub export fn gst_stream_volume_set_mute(v: ?*Vol, mute: c.gboolean) void {
    if (!check.that(isVolume(v), "gst_stream_volume_set_mute", "GST_IS_STREAM_VOLUME (volume)")) return;
    c.g_object_set(v, "mute", mute, NONE);
}

pub export fn gst_stream_volume_convert_volume(from: c.GstStreamVolumeFormat, to: c.GstStreamVolumeFormat, val: f64) f64 {
    const fname = "gst_stream_volume_convert_volume";
    switch (from) {
        c.GST_STREAM_VOLUME_FORMAT_LINEAR => {
            if (!check.that(val >= 0.0, fname, "val >= 0.0")) return 0.0;
            switch (to) {
                c.GST_STREAM_VOLUME_FORMAT_LINEAR => return val,
                c.GST_STREAM_VOLUME_FORMAT_CUBIC => return pow(val, 1.0 / 3.0),
                c.GST_STREAM_VOLUME_FORMAT_DB => return 20.0 * log10(val),
                else => {},
            }
        },
        c.GST_STREAM_VOLUME_FORMAT_CUBIC => {
            if (!check.that(val >= 0.0, fname, "val >= 0.0")) return 0.0;
            switch (to) {
                c.GST_STREAM_VOLUME_FORMAT_LINEAR => return val * val * val,
                c.GST_STREAM_VOLUME_FORMAT_CUBIC => return val,
                c.GST_STREAM_VOLUME_FORMAT_DB => return 3.0 * 20.0 * log10(val),
                else => {},
            }
        },
        c.GST_STREAM_VOLUME_FORMAT_DB => switch (to) {
            c.GST_STREAM_VOLUME_FORMAT_LINEAR => return pow(10.0, val / 20.0),
            c.GST_STREAM_VOLUME_FORMAT_CUBIC => return pow(10.0, val / (3.0 * 20.0)),
            c.GST_STREAM_VOLUME_FORMAT_DB => return val,
            else => {},
        },
        else => {},
    }
    check.reached("streamvolume.c", 210, fname);
    return 0.0;
}
