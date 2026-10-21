const std = @import("std");
const c = @import("../c.zig").c;

pub const Pair = struct { s: [:0]const u8, v: c.gint };

const ORIENTATION = [_]Pair{ .{ .s = "rotate-0", .v = 1 }, .{ .s = "flip-rotate-0", .v = 2 }, .{ .s = "rotate-180", .v = 3 }, .{ .s = "flip-rotate-180", .v = 4 }, .{ .s = "flip-rotate-270", .v = 5 }, .{ .s = "rotate-90", .v = 6 }, .{ .s = "flip-rotate-90", .v = 7 }, .{ .s = "rotate-270", .v = 8 } };
const EXPOSURE_PROGRAM = [_]Pair{ .{ .s = "undefined", .v = 0 }, .{ .s = "manual", .v = 1 }, .{ .s = "normal", .v = 2 }, .{ .s = "aperture-priority", .v = 3 }, .{ .s = "shutter-priority", .v = 4 }, .{ .s = "creative", .v = 5 }, .{ .s = "action", .v = 6 }, .{ .s = "portrait", .v = 7 }, .{ .s = "landscape", .v = 8 } };
const EXPOSURE_MODE = [_]Pair{ .{ .s = "auto-exposure", .v = 0 }, .{ .s = "manual-exposure", .v = 1 }, .{ .s = "auto-bracket", .v = 2 } };
const SCENE = [_]Pair{ .{ .s = "standard", .v = 0 }, .{ .s = "landscape", .v = 1 }, .{ .s = "portrait", .v = 2 }, .{ .s = "night-scene", .v = 3 } };
const GAIN = [_]Pair{ .{ .s = "none", .v = 0 }, .{ .s = "low-gain-up", .v = 1 }, .{ .s = "high-gain-up", .v = 2 }, .{ .s = "low-gain-down", .v = 3 }, .{ .s = "high-gain-down", .v = 4 } };
const LIGHT_TO = [_]Pair{ .{ .s = "unknown", .v = 0 }, .{ .s = "daylight", .v = 1 }, .{ .s = "flourescent", .v = 2 }, .{ .s = "tungsten", .v = 3 }, .{ .s = "flash", .v = 4 }, .{ .s = "fine-weather", .v = 9 }, .{ .s = "cloudy-weather", .v = 10 }, .{ .s = "shade", .v = 11 }, .{ .s = "daylight-fluorescent", .v = 12 }, .{ .s = "day-white-fluorescent", .v = 13 }, .{ .s = "cool-white-fluorescent", .v = 14 }, .{ .s = "white-fluorescent", .v = 15 }, .{ .s = "warm-white-fluorescent", .v = 16 }, .{ .s = "standard-light-A", .v = 17 }, .{ .s = "standard-light-B", .v = 18 }, .{ .s = "standard-light-C", .v = 19 }, .{ .s = "D55", .v = 20 }, .{ .s = "D65", .v = 21 }, .{ .s = "D75", .v = 22 }, .{ .s = "D50", .v = 23 }, .{ .s = "iso-studio-tungsten", .v = 24 }, .{ .s = "other", .v = 255 } };
const CONTRAST = [_]Pair{ .{ .s = "normal", .v = 0 }, .{ .s = "soft", .v = 1 }, .{ .s = "hard", .v = 2 } };
const SATURATION = [_]Pair{ .{ .s = "normal", .v = 0 }, .{ .s = "low-saturation", .v = 1 }, .{ .s = "high-saturation", .v = 2 } };
const METERING = [_]Pair{ .{ .s = "unknown", .v = 0 }, .{ .s = "average", .v = 1 }, .{ .s = "center-weighted-average", .v = 2 }, .{ .s = "spot", .v = 3 }, .{ .s = "multi-spot", .v = 4 }, .{ .s = "pattern", .v = 5 }, .{ .s = "partial", .v = 6 }, .{ .s = "other", .v = 255 } };
const SOURCE = [_]Pair{ .{ .s = "dsc", .v = 3 }, .{ .s = "other", .v = 0 }, .{ .s = "transparent-scanner", .v = 1 }, .{ .s = "reflex-scanner", .v = 2 } };

pub fn toExif(table: []const Pair, s: [*c]const u8) c.gint {
    if (s == null) return -1;
    for (table) |p| {
        if (c.strcmp(s, p.s.ptr) == 0) return p.v;
    }
    return -1;
}

pub fn fromExif(table: []const Pair, v: c.gint) ?[*:0]const u8 {
    for (table) |p| {
        if (p.v == v) return p.s.ptr;
    }
    return null;
}

pub fn orientationToExif(s: [*c]const u8) c.gint {
    return toExif(&ORIENTATION, s);
}

pub fn orientationFromExif(v: c.gint) ?[*:0]const u8 {
    return fromExif(&ORIENTATION, v);
}

pub const Kind = enum { exposure_program, exposure_mode, scene, gain, light, contrast, saturation, sharpness, metering, source, white_balance };

pub fn to(k: Kind, s: [*c]const u8) c.gint {
    return switch (k) {
        .exposure_program => toExif(&EXPOSURE_PROGRAM, s),
        .exposure_mode => toExif(&EXPOSURE_MODE, s),
        .scene => toExif(&SCENE, s),
        .gain => toExif(&GAIN, s),
        .light => toExif(&LIGHT_TO, s),
        .contrast, .sharpness => toExif(&CONTRAST, s),
        .saturation => toExif(&SATURATION, s),
        .metering => toExif(&METERING, s),
        .source => toExif(&SOURCE, s),
        .white_balance => if (s == null) -1 else if (c.strcmp(s, "auto") == 0) 0 else 1,
    };
}

pub fn from(k: Kind, v: c.gint) ?[*:0]const u8 {
    return switch (k) {
        .exposure_program => fromExif(&EXPOSURE_PROGRAM, v),
        .exposure_mode => fromExif(&EXPOSURE_MODE, v),
        .scene => fromExif(&SCENE, v),
        .gain => fromExif(&GAIN, v),
        .light => if (v == 3) null else fromExif(&LIGHT_TO, v),
        .contrast, .sharpness => fromExif(&CONTRAST, v),
        .saturation => fromExif(&SATURATION, v),
        .metering => fromExif(&METERING, v),
        .source => fromExif(&SOURCE, v),
        .white_balance => if (v == 0) "auto" else if (v == 1) "manual" else null,
    };
}
