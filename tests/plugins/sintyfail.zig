const c = @import("c").c;

fn init(_: ?*c.GstPlugin) callconv(.c) c.gboolean {
    return 0;
}

export var gst_plugin_desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "sintyfail",
    .description = "Fails to initialize",
    .plugin_init = init,
    .version = "1.0",
    .license = "MIT/X11",
    .source = "sinty-media",
    .package = "sinty-media tests",
    .origin = "https://sinty.dev",
    .release_datetime = null,
    ._gst_reserved = .{null} ** 4,
};
