const c = @import("c.zig").c;

const Var = struct {
    name: [:0]const u8,
    size: usize,
};

const vars = [_]Var{
    .{ .name = "GST_CAT_BUFFER", .size = 8 },
    .{ .name = "GST_CAT_BUFFER_LIST", .size = 8 },
    .{ .name = "GST_CAT_BUS", .size = 8 },
    .{ .name = "GST_CAT_CALL_TRACE", .size = 8 },
    .{ .name = "GST_CAT_CAPS", .size = 8 },
    .{ .name = "GST_CAT_CLOCK", .size = 8 },
    .{ .name = "GST_CAT_CONTEXT", .size = 8 },
    .{ .name = "GST_CAT_DEFAULT", .size = 8 },
    .{ .name = "GST_CAT_ELEMENT_PADS", .size = 8 },
    .{ .name = "GST_CAT_ERROR_SYSTEM", .size = 8 },
    .{ .name = "GST_CAT_EVENT", .size = 8 },
    .{ .name = "GST_CAT_GST_INIT", .size = 8 },
    .{ .name = "GST_CAT_LOCKING", .size = 8 },
    .{ .name = "GST_CAT_MEMORY", .size = 8 },
    .{ .name = "GST_CAT_MESSAGE", .size = 8 },
    .{ .name = "GST_CAT_META", .size = 8 },
    .{ .name = "GST_CAT_NEGOTIATION", .size = 8 },
    .{ .name = "GST_CAT_PADS", .size = 8 },
    .{ .name = "GST_CAT_PARAMS", .size = 8 },
    .{ .name = "GST_CAT_PARENTAGE", .size = 8 },
    .{ .name = "GST_CAT_PERFORMANCE", .size = 8 },
    .{ .name = "GST_CAT_PIPELINE", .size = 8 },
    .{ .name = "GST_CAT_PLUGIN_INFO", .size = 8 },
    .{ .name = "GST_CAT_PLUGIN_LOADING", .size = 8 },
    .{ .name = "GST_CAT_PROBE", .size = 8 },
    .{ .name = "GST_CAT_PROPERTIES", .size = 8 },
    .{ .name = "GST_CAT_QOS", .size = 8 },
    .{ .name = "GST_CAT_REFCOUNTING", .size = 8 },
    .{ .name = "GST_CAT_REGISTRY", .size = 8 },
    .{ .name = "GST_CAT_SCHEDULING", .size = 8 },
    .{ .name = "GST_CAT_SIGNAL", .size = 8 },
    .{ .name = "GST_CAT_STATES", .size = 8 },
    .{ .name = "__gst_deviceproviderclass_factory", .size = 4 },
    .{ .name = "__gst_elementclass_factory", .size = 4 },
    .{ .name = "__gst_elementclass_skip_doc", .size = 4 },
    .{ .name = "_gst_bitmask_type", .size = 8 },
    .{ .name = "_gst_buffer_list_type", .size = 8 },
    .{ .name = "_gst_buffer_type", .size = 8 },
    .{ .name = "_gst_caps_any", .size = 8 },
    .{ .name = "_gst_caps_features_any", .size = 8 },
    .{ .name = "_gst_caps_features_memory_system_memory", .size = 8 },
    .{ .name = "_gst_caps_features_type", .size = 8 },
    .{ .name = "_gst_caps_none", .size = 8 },
    .{ .name = "_gst_caps_type", .size = 8 },
    .{ .name = "_gst_context_type", .size = 8 },
    .{ .name = "_gst_date_time_type", .size = 8 },
    .{ .name = "_gst_debug_enabled", .size = 4 },
    .{ .name = "_gst_debug_min", .size = 4 },
    .{ .name = "_gst_double_range_type", .size = 8 },
    .{ .name = "_gst_event_type", .size = 8 },
    .{ .name = "_gst_flagset_type", .size = 8 },
    .{ .name = "_gst_fraction_range_type", .size = 8 },
    .{ .name = "_gst_fraction_type", .size = 8 },
    .{ .name = "_gst_int64_range_type", .size = 8 },
    .{ .name = "_gst_int_range_type", .size = 8 },
    .{ .name = "_gst_memory_type", .size = 8 },
    .{ .name = "_gst_message_type", .size = 8 },
    .{ .name = "_gst_meta_tag_memory", .size = 4 },
    .{ .name = "_gst_meta_tag_memory_reference", .size = 4 },
    .{ .name = "_gst_meta_transform_copy", .size = 4 },
    .{ .name = "_gst_mini_object_type", .size = 8 },
    .{ .name = "_gst_query_type", .size = 8 },
    .{ .name = "_gst_sample_type", .size = 8 },
    .{ .name = "_gst_structure_type", .size = 8 },
    .{ .name = "_gst_tag_list_type", .size = 8 },
    .{ .name = "_gst_toc_entry_type", .size = 8 },
    .{ .name = "_gst_toc_type", .size = 8 },
    .{ .name = "_gst_uri_type", .size = 8 },
    .{ .name = "_gst_value_array_type", .size = 8 },
    .{ .name = "_gst_value_list_type", .size = 8 },
    .{ .name = "_gst_value_unique_list_type", .size = 8 },
    .{ .name = "gst_memory_alignment", .size = 8 },
};

var self: ?*anyopaque = null;

fn handle() ?*anyopaque {
    if (self) |h| return h;
    var info: c.Dl_info = undefined;
    if (c.dladdr(@ptrCast(&handle), &info) == 0 or info.dli_fname == null) return null;
    self = c.dlopen(info.dli_fname, c.RTLD_NOLOAD | c.RTLD_LAZY);
    return self;
}

fn sync(v: Var) void {
    const h = handle() orelse return;
    const own = c.dlsym(h, v.name.ptr) orelse return;
    const seen = c.dlsym(null, v.name.ptr) orelse return;
    if (own == seen) return;
    @memcpy(@as([*]u8, @ptrCast(seen))[0..v.size], @as([*]const u8, @ptrCast(own))[0..v.size]);
}

pub fn publish() void {
    for (vars) |v| sync(v);
}

pub fn publishDebug() void {
    sync(.{ .name = "_gst_debug_min", .size = 4 });
    sync(.{ .name = "_gst_debug_enabled", .size = 4 });
}
