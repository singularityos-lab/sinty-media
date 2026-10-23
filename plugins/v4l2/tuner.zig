const cm = @import("../common.zig");
const c = cm.c;

pub const Iface = extern struct {
    iface: c.GTypeInterface,
    list_channels: ?*const anyopaque,
    set_channel: ?*const anyopaque,
    get_channel: ?*const anyopaque,
    list_norms: ?*const anyopaque,
    set_norm: ?*const anyopaque,
    get_norm: ?*const anyopaque,
    set_frequency: ?*const anyopaque,
    get_frequency: ?*const anyopaque,
    signal_strength: ?*const anyopaque,
    channel_changed: ?*const anyopaque,
    norm_changed: ?*const anyopaque,
    frequency_changed: ?*const anyopaque,
    signal_changed: ?*const anyopaque,
    reserved: [4]c.gpointer,
};

var once: cm.Once = .{};

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const existing = c.g_type_from_name("GstTuner");
            if (existing != 0) return existing;
            const info = c.GTypeInfo{
                .class_size = @sizeOf(Iface),
                .base_init = null,
                .base_finalize = null,
                .class_init = null,
                .class_finalize = null,
                .class_data = null,
                .instance_size = 0,
                .n_preallocs = 0,
                .instance_init = null,
                .value_table = null,
            };
            return c.g_type_register_static(c.G_TYPE_INTERFACE, "GstTuner", &info, 0);
        }
    }.f);
}

pub fn init(_: c.gpointer, _: c.gpointer) callconv(.c) void {}
