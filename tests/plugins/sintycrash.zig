const c = @import("c").c;

fn init(_: ?*c.GstPlugin) callconv(.c) c.gboolean {
    const p: *allowzero volatile u32 = @ptrFromInt(0);
    p.* = 1;
    return 1;
}

export var gst_plugin_desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "sintycrash",
    .description = "Crashes",
    .plugin_init = init,
    .version = "1.0",
    .license = "LGPL",
    .source = "sinty-media",
    .package = "sinty-media tests",
    .origin = "https://sinty.dev",
    .release_datetime = null,
    ._gst_reserved = .{null} ** 4,
};
