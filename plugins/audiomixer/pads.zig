const cm = @import("../common.zig");
const c = cm.c;

pub const AggPad = extern struct {
    parent: cm.Pad,
    segment: c.GstSegment,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

pub const APad = extern struct {
    parent: AggPad,
    info: c.GstAudioInfo,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

pub const CPad = extern struct {
    parent: APad,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

pub fn apad(p: anytype) *APad {
    return @ptrCast(@alignCast(p));
}
