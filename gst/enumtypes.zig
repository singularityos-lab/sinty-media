const c = @import("c.zig").c;
const gtype = @import("gtype.zig");

var gst_allocator_flags_values = [_]c.GFlagsValue{
    .{ .value = 16, .value_name = "GST_ALLOCATOR_FLAG_CUSTOM_ALLOC", .value_nick = "custom-alloc" },
    .{ .value = 32, .value_name = "GST_ALLOCATOR_FLAG_NO_COPY", .value_nick = "no-copy" },
    .{ .value = 1048576, .value_name = "GST_ALLOCATOR_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_allocator_flags_once: gtype.Once = .{};
fn gst_allocator_flags_register() c.GType {
    return c.g_flags_register_static("GstAllocatorFlags", &gst_allocator_flags_values);
}
pub export fn gst_allocator_flags_get_type() c.GType {
    return gst_allocator_flags_once.get(gst_allocator_flags_register);
}

var gst_bin_flags_values = [_]c.GFlagsValue{
    .{ .value = 16384, .value_name = "GST_BIN_FLAG_NO_RESYNC", .value_nick = "no-resync" },
    .{ .value = 32768, .value_name = "GST_BIN_FLAG_STREAMS_AWARE", .value_nick = "streams-aware" },
    .{ .value = 524288, .value_name = "GST_BIN_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_bin_flags_once: gtype.Once = .{};
fn gst_bin_flags_register() c.GType {
    return c.g_flags_register_static("GstBinFlags", &gst_bin_flags_values);
}
pub export fn gst_bin_flags_get_type() c.GType {
    return gst_bin_flags_once.get(gst_bin_flags_register);
}

var gst_buffer_flags_values = [_]c.GFlagsValue{
    .{ .value = 16, .value_name = "GST_BUFFER_FLAG_LIVE", .value_nick = "live" },
    .{ .value = 32, .value_name = "GST_BUFFER_FLAG_DECODE_ONLY", .value_nick = "decode-only" },
    .{ .value = 64, .value_name = "GST_BUFFER_FLAG_DISCONT", .value_nick = "discont" },
    .{ .value = 128, .value_name = "GST_BUFFER_FLAG_RESYNC", .value_nick = "resync" },
    .{ .value = 256, .value_name = "GST_BUFFER_FLAG_CORRUPTED", .value_nick = "corrupted" },
    .{ .value = 512, .value_name = "GST_BUFFER_FLAG_MARKER", .value_nick = "marker" },
    .{ .value = 1024, .value_name = "GST_BUFFER_FLAG_HEADER", .value_nick = "header" },
    .{ .value = 2048, .value_name = "GST_BUFFER_FLAG_GAP", .value_nick = "gap" },
    .{ .value = 4096, .value_name = "GST_BUFFER_FLAG_DROPPABLE", .value_nick = "droppable" },
    .{ .value = 8192, .value_name = "GST_BUFFER_FLAG_DELTA_UNIT", .value_nick = "delta-unit" },
    .{ .value = 16384, .value_name = "GST_BUFFER_FLAG_TAG_MEMORY", .value_nick = "tag-memory" },
    .{ .value = 32768, .value_name = "GST_BUFFER_FLAG_SYNC_AFTER", .value_nick = "sync-after" },
    .{ .value = 65536, .value_name = "GST_BUFFER_FLAG_NON_DROPPABLE", .value_nick = "non-droppable" },
    .{ .value = 1048576, .value_name = "GST_BUFFER_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_buffer_flags_once: gtype.Once = .{};
fn gst_buffer_flags_register() c.GType {
    return c.g_flags_register_static("GstBufferFlags", &gst_buffer_flags_values);
}
pub export fn gst_buffer_flags_get_type() c.GType {
    return gst_buffer_flags_once.get(gst_buffer_flags_register);
}

var gst_buffer_copy_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_BUFFER_COPY_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_BUFFER_COPY_FLAGS", .value_nick = "flags" },
    .{ .value = 2, .value_name = "GST_BUFFER_COPY_TIMESTAMPS", .value_nick = "timestamps" },
    .{ .value = 4, .value_name = "GST_BUFFER_COPY_META", .value_nick = "meta" },
    .{ .value = 8, .value_name = "GST_BUFFER_COPY_MEMORY", .value_nick = "memory" },
    .{ .value = 16, .value_name = "GST_BUFFER_COPY_MERGE", .value_nick = "merge" },
    .{ .value = 32, .value_name = "GST_BUFFER_COPY_DEEP", .value_nick = "deep" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_buffer_copy_flags_once: gtype.Once = .{};
fn gst_buffer_copy_flags_register() c.GType {
    return c.g_flags_register_static("GstBufferCopyFlags", &gst_buffer_copy_flags_values);
}
pub export fn gst_buffer_copy_flags_get_type() c.GType {
    return gst_buffer_copy_flags_once.get(gst_buffer_copy_flags_register);
}

var gst_buffer_pool_acquire_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_BUFFER_POOL_ACQUIRE_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_BUFFER_POOL_ACQUIRE_FLAG_KEY_UNIT", .value_nick = "key-unit" },
    .{ .value = 2, .value_name = "GST_BUFFER_POOL_ACQUIRE_FLAG_DONTWAIT", .value_nick = "dontwait" },
    .{ .value = 4, .value_name = "GST_BUFFER_POOL_ACQUIRE_FLAG_DISCONT", .value_nick = "discont" },
    .{ .value = 65536, .value_name = "GST_BUFFER_POOL_ACQUIRE_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_buffer_pool_acquire_flags_once: gtype.Once = .{};
fn gst_buffer_pool_acquire_flags_register() c.GType {
    return c.g_flags_register_static("GstBufferPoolAcquireFlags", &gst_buffer_pool_acquire_flags_values);
}
pub export fn gst_buffer_pool_acquire_flags_get_type() c.GType {
    return gst_buffer_pool_acquire_flags_once.get(gst_buffer_pool_acquire_flags_register);
}

var gst_bus_flags_values = [_]c.GFlagsValue{
    .{ .value = 16, .value_name = "GST_BUS_FLUSHING", .value_nick = "flushing" },
    .{ .value = 32, .value_name = "GST_BUS_FLAG_LAST", .value_nick = "flag-last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_bus_flags_once: gtype.Once = .{};
fn gst_bus_flags_register() c.GType {
    return c.g_flags_register_static("GstBusFlags", &gst_bus_flags_values);
}
pub export fn gst_bus_flags_get_type() c.GType {
    return gst_bus_flags_once.get(gst_bus_flags_register);
}

var gst_bus_sync_reply_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_BUS_DROP", .value_nick = "drop" },
    .{ .value = 1, .value_name = "GST_BUS_PASS", .value_nick = "pass" },
    .{ .value = 2, .value_name = "GST_BUS_ASYNC", .value_nick = "async" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_bus_sync_reply_once: gtype.Once = .{};
fn gst_bus_sync_reply_register() c.GType {
    return c.g_enum_register_static("GstBusSyncReply", &gst_bus_sync_reply_values);
}
pub export fn gst_bus_sync_reply_get_type() c.GType {
    return gst_bus_sync_reply_once.get(gst_bus_sync_reply_register);
}

var gst_caps_flags_values = [_]c.GFlagsValue{
    .{ .value = 16, .value_name = "GST_CAPS_FLAG_ANY", .value_nick = "any" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_caps_flags_once: gtype.Once = .{};
fn gst_caps_flags_register() c.GType {
    return c.g_flags_register_static("GstCapsFlags", &gst_caps_flags_values);
}
pub export fn gst_caps_flags_get_type() c.GType {
    return gst_caps_flags_once.get(gst_caps_flags_register);
}

var gst_caps_intersect_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_CAPS_INTERSECT_ZIG_ZAG", .value_nick = "zig-zag" },
    .{ .value = 1, .value_name = "GST_CAPS_INTERSECT_FIRST", .value_nick = "first" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_caps_intersect_mode_once: gtype.Once = .{};
fn gst_caps_intersect_mode_register() c.GType {
    return c.g_enum_register_static("GstCapsIntersectMode", &gst_caps_intersect_mode_values);
}
pub export fn gst_caps_intersect_mode_get_type() c.GType {
    return gst_caps_intersect_mode_once.get(gst_caps_intersect_mode_register);
}

var gst_clock_return_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_CLOCK_OK", .value_nick = "ok" },
    .{ .value = 1, .value_name = "GST_CLOCK_EARLY", .value_nick = "early" },
    .{ .value = 2, .value_name = "GST_CLOCK_UNSCHEDULED", .value_nick = "unscheduled" },
    .{ .value = 3, .value_name = "GST_CLOCK_BUSY", .value_nick = "busy" },
    .{ .value = 4, .value_name = "GST_CLOCK_BADTIME", .value_nick = "badtime" },
    .{ .value = 5, .value_name = "GST_CLOCK_ERROR", .value_nick = "error" },
    .{ .value = 6, .value_name = "GST_CLOCK_UNSUPPORTED", .value_nick = "unsupported" },
    .{ .value = 7, .value_name = "GST_CLOCK_DONE", .value_nick = "done" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_clock_return_once: gtype.Once = .{};
fn gst_clock_return_register() c.GType {
    return c.g_enum_register_static("GstClockReturn", &gst_clock_return_values);
}
pub export fn gst_clock_return_get_type() c.GType {
    return gst_clock_return_once.get(gst_clock_return_register);
}

var gst_clock_entry_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_CLOCK_ENTRY_SINGLE", .value_nick = "single" },
    .{ .value = 1, .value_name = "GST_CLOCK_ENTRY_PERIODIC", .value_nick = "periodic" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_clock_entry_type_once: gtype.Once = .{};
fn gst_clock_entry_type_register() c.GType {
    return c.g_enum_register_static("GstClockEntryType", &gst_clock_entry_type_values);
}
pub export fn gst_clock_entry_type_get_type() c.GType {
    return gst_clock_entry_type_once.get(gst_clock_entry_type_register);
}

var gst_clock_flags_values = [_]c.GFlagsValue{
    .{ .value = 16, .value_name = "GST_CLOCK_FLAG_CAN_DO_SINGLE_SYNC", .value_nick = "can-do-single-sync" },
    .{ .value = 32, .value_name = "GST_CLOCK_FLAG_CAN_DO_SINGLE_ASYNC", .value_nick = "can-do-single-async" },
    .{ .value = 64, .value_name = "GST_CLOCK_FLAG_CAN_DO_PERIODIC_SYNC", .value_nick = "can-do-periodic-sync" },
    .{ .value = 128, .value_name = "GST_CLOCK_FLAG_CAN_DO_PERIODIC_ASYNC", .value_nick = "can-do-periodic-async" },
    .{ .value = 256, .value_name = "GST_CLOCK_FLAG_CAN_SET_RESOLUTION", .value_nick = "can-set-resolution" },
    .{ .value = 512, .value_name = "GST_CLOCK_FLAG_CAN_SET_MASTER", .value_nick = "can-set-master" },
    .{ .value = 1024, .value_name = "GST_CLOCK_FLAG_NEEDS_STARTUP_SYNC", .value_nick = "needs-startup-sync" },
    .{ .value = 4096, .value_name = "GST_CLOCK_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_clock_flags_once: gtype.Once = .{};
fn gst_clock_flags_register() c.GType {
    return c.g_flags_register_static("GstClockFlags", &gst_clock_flags_values);
}
pub export fn gst_clock_flags_get_type() c.GType {
    return gst_clock_flags_once.get(gst_clock_flags_register);
}

var gst_debug_graph_details_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_DEBUG_GRAPH_SHOW_MEDIA_TYPE", .value_nick = "media-type" },
    .{ .value = 2, .value_name = "GST_DEBUG_GRAPH_SHOW_CAPS_DETAILS", .value_nick = "caps-details" },
    .{ .value = 4, .value_name = "GST_DEBUG_GRAPH_SHOW_NON_DEFAULT_PARAMS", .value_nick = "non-default-params" },
    .{ .value = 8, .value_name = "GST_DEBUG_GRAPH_SHOW_STATES", .value_nick = "states" },
    .{ .value = 16, .value_name = "GST_DEBUG_GRAPH_SHOW_FULL_PARAMS", .value_nick = "full-params" },
    .{ .value = 15, .value_name = "GST_DEBUG_GRAPH_SHOW_ALL", .value_nick = "all" },
    .{ .value = 4294967295, .value_name = "GST_DEBUG_GRAPH_SHOW_VERBOSE", .value_nick = "verbose" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_debug_graph_details_once: gtype.Once = .{};
fn gst_debug_graph_details_register() c.GType {
    return c.g_flags_register_static("GstDebugGraphDetails", &gst_debug_graph_details_values);
}
pub export fn gst_debug_graph_details_get_type() c.GType {
    return gst_debug_graph_details_once.get(gst_debug_graph_details_register);
}

var gst_state_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_STATE_VOID_PENDING", .value_nick = "void-pending" },
    .{ .value = 1, .value_name = "GST_STATE_NULL", .value_nick = "null" },
    .{ .value = 2, .value_name = "GST_STATE_READY", .value_nick = "ready" },
    .{ .value = 3, .value_name = "GST_STATE_PAUSED", .value_nick = "paused" },
    .{ .value = 4, .value_name = "GST_STATE_PLAYING", .value_nick = "playing" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_state_once: gtype.Once = .{};
fn gst_state_register() c.GType {
    return c.g_enum_register_static("GstState", &gst_state_values);
}
pub export fn gst_state_get_type() c.GType {
    return gst_state_once.get(gst_state_register);
}

var gst_state_change_return_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_STATE_CHANGE_FAILURE", .value_nick = "failure" },
    .{ .value = 1, .value_name = "GST_STATE_CHANGE_SUCCESS", .value_nick = "success" },
    .{ .value = 2, .value_name = "GST_STATE_CHANGE_ASYNC", .value_nick = "async" },
    .{ .value = 3, .value_name = "GST_STATE_CHANGE_NO_PREROLL", .value_nick = "no-preroll" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_state_change_return_once: gtype.Once = .{};
fn gst_state_change_return_register() c.GType {
    return c.g_enum_register_static("GstStateChangeReturn", &gst_state_change_return_values);
}
pub export fn gst_state_change_return_get_type() c.GType {
    return gst_state_change_return_once.get(gst_state_change_return_register);
}

var gst_state_change_values = [_]c.GEnumValue{
    .{ .value = 10, .value_name = "GST_STATE_CHANGE_NULL_TO_READY", .value_nick = "null-to-ready" },
    .{ .value = 19, .value_name = "GST_STATE_CHANGE_READY_TO_PAUSED", .value_nick = "ready-to-paused" },
    .{ .value = 28, .value_name = "GST_STATE_CHANGE_PAUSED_TO_PLAYING", .value_nick = "paused-to-playing" },
    .{ .value = 35, .value_name = "GST_STATE_CHANGE_PLAYING_TO_PAUSED", .value_nick = "playing-to-paused" },
    .{ .value = 26, .value_name = "GST_STATE_CHANGE_PAUSED_TO_READY", .value_nick = "paused-to-ready" },
    .{ .value = 17, .value_name = "GST_STATE_CHANGE_READY_TO_NULL", .value_nick = "ready-to-null" },
    .{ .value = 9, .value_name = "GST_STATE_CHANGE_NULL_TO_NULL", .value_nick = "null-to-null" },
    .{ .value = 18, .value_name = "GST_STATE_CHANGE_READY_TO_READY", .value_nick = "ready-to-ready" },
    .{ .value = 27, .value_name = "GST_STATE_CHANGE_PAUSED_TO_PAUSED", .value_nick = "paused-to-paused" },
    .{ .value = 36, .value_name = "GST_STATE_CHANGE_PLAYING_TO_PLAYING", .value_nick = "playing-to-playing" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_state_change_once: gtype.Once = .{};
fn gst_state_change_register() c.GType {
    return c.g_enum_register_static("GstStateChange", &gst_state_change_values);
}
pub export fn gst_state_change_get_type() c.GType {
    return gst_state_change_once.get(gst_state_change_register);
}

var gst_element_flags_values = [_]c.GFlagsValue{
    .{ .value = 16, .value_name = "GST_ELEMENT_FLAG_LOCKED_STATE", .value_nick = "locked-state" },
    .{ .value = 32, .value_name = "GST_ELEMENT_FLAG_SINK", .value_nick = "sink" },
    .{ .value = 64, .value_name = "GST_ELEMENT_FLAG_SOURCE", .value_nick = "source" },
    .{ .value = 128, .value_name = "GST_ELEMENT_FLAG_PROVIDE_CLOCK", .value_nick = "provide-clock" },
    .{ .value = 256, .value_name = "GST_ELEMENT_FLAG_REQUIRE_CLOCK", .value_nick = "require-clock" },
    .{ .value = 512, .value_name = "GST_ELEMENT_FLAG_INDEXABLE", .value_nick = "indexable" },
    .{ .value = 16384, .value_name = "GST_ELEMENT_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_element_flags_once: gtype.Once = .{};
fn gst_element_flags_register() c.GType {
    return c.g_flags_register_static("GstElementFlags", &gst_element_flags_values);
}
pub export fn gst_element_flags_get_type() c.GType {
    return gst_element_flags_once.get(gst_element_flags_register);
}

var gst_core_error_values = [_]c.GEnumValue{
    .{ .value = 1, .value_name = "GST_CORE_ERROR_FAILED", .value_nick = "failed" },
    .{ .value = 2, .value_name = "GST_CORE_ERROR_TOO_LAZY", .value_nick = "too-lazy" },
    .{ .value = 3, .value_name = "GST_CORE_ERROR_NOT_IMPLEMENTED", .value_nick = "not-implemented" },
    .{ .value = 4, .value_name = "GST_CORE_ERROR_STATE_CHANGE", .value_nick = "state-change" },
    .{ .value = 5, .value_name = "GST_CORE_ERROR_PAD", .value_nick = "pad" },
    .{ .value = 6, .value_name = "GST_CORE_ERROR_THREAD", .value_nick = "thread" },
    .{ .value = 7, .value_name = "GST_CORE_ERROR_NEGOTIATION", .value_nick = "negotiation" },
    .{ .value = 8, .value_name = "GST_CORE_ERROR_EVENT", .value_nick = "event" },
    .{ .value = 9, .value_name = "GST_CORE_ERROR_SEEK", .value_nick = "seek" },
    .{ .value = 10, .value_name = "GST_CORE_ERROR_CAPS", .value_nick = "caps" },
    .{ .value = 11, .value_name = "GST_CORE_ERROR_TAG", .value_nick = "tag" },
    .{ .value = 12, .value_name = "GST_CORE_ERROR_MISSING_PLUGIN", .value_nick = "missing-plugin" },
    .{ .value = 13, .value_name = "GST_CORE_ERROR_CLOCK", .value_nick = "clock" },
    .{ .value = 14, .value_name = "GST_CORE_ERROR_DISABLED", .value_nick = "disabled" },
    .{ .value = 15, .value_name = "GST_CORE_ERROR_NUM_ERRORS", .value_nick = "num-errors" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_core_error_once: gtype.Once = .{};
fn gst_core_error_register() c.GType {
    return c.g_enum_register_static("GstCoreError", &gst_core_error_values);
}
pub export fn gst_core_error_get_type() c.GType {
    return gst_core_error_once.get(gst_core_error_register);
}

var gst_library_error_values = [_]c.GEnumValue{
    .{ .value = 1, .value_name = "GST_LIBRARY_ERROR_FAILED", .value_nick = "failed" },
    .{ .value = 2, .value_name = "GST_LIBRARY_ERROR_TOO_LAZY", .value_nick = "too-lazy" },
    .{ .value = 3, .value_name = "GST_LIBRARY_ERROR_INIT", .value_nick = "init" },
    .{ .value = 4, .value_name = "GST_LIBRARY_ERROR_SHUTDOWN", .value_nick = "shutdown" },
    .{ .value = 5, .value_name = "GST_LIBRARY_ERROR_SETTINGS", .value_nick = "settings" },
    .{ .value = 6, .value_name = "GST_LIBRARY_ERROR_ENCODE", .value_nick = "encode" },
    .{ .value = 7, .value_name = "GST_LIBRARY_ERROR_NUM_ERRORS", .value_nick = "num-errors" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_library_error_once: gtype.Once = .{};
fn gst_library_error_register() c.GType {
    return c.g_enum_register_static("GstLibraryError", &gst_library_error_values);
}
pub export fn gst_library_error_get_type() c.GType {
    return gst_library_error_once.get(gst_library_error_register);
}

var gst_resource_error_values = [_]c.GEnumValue{
    .{ .value = 1, .value_name = "GST_RESOURCE_ERROR_FAILED", .value_nick = "failed" },
    .{ .value = 2, .value_name = "GST_RESOURCE_ERROR_TOO_LAZY", .value_nick = "too-lazy" },
    .{ .value = 3, .value_name = "GST_RESOURCE_ERROR_NOT_FOUND", .value_nick = "not-found" },
    .{ .value = 4, .value_name = "GST_RESOURCE_ERROR_BUSY", .value_nick = "busy" },
    .{ .value = 5, .value_name = "GST_RESOURCE_ERROR_OPEN_READ", .value_nick = "open-read" },
    .{ .value = 6, .value_name = "GST_RESOURCE_ERROR_OPEN_WRITE", .value_nick = "open-write" },
    .{ .value = 7, .value_name = "GST_RESOURCE_ERROR_OPEN_READ_WRITE", .value_nick = "open-read-write" },
    .{ .value = 8, .value_name = "GST_RESOURCE_ERROR_CLOSE", .value_nick = "close" },
    .{ .value = 9, .value_name = "GST_RESOURCE_ERROR_READ", .value_nick = "read" },
    .{ .value = 10, .value_name = "GST_RESOURCE_ERROR_WRITE", .value_nick = "write" },
    .{ .value = 11, .value_name = "GST_RESOURCE_ERROR_SEEK", .value_nick = "seek" },
    .{ .value = 12, .value_name = "GST_RESOURCE_ERROR_SYNC", .value_nick = "sync" },
    .{ .value = 13, .value_name = "GST_RESOURCE_ERROR_SETTINGS", .value_nick = "settings" },
    .{ .value = 14, .value_name = "GST_RESOURCE_ERROR_NO_SPACE_LEFT", .value_nick = "no-space-left" },
    .{ .value = 15, .value_name = "GST_RESOURCE_ERROR_NOT_AUTHORIZED", .value_nick = "not-authorized" },
    .{ .value = 16, .value_name = "GST_RESOURCE_ERROR_NUM_ERRORS", .value_nick = "num-errors" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_resource_error_once: gtype.Once = .{};
fn gst_resource_error_register() c.GType {
    return c.g_enum_register_static("GstResourceError", &gst_resource_error_values);
}
pub export fn gst_resource_error_get_type() c.GType {
    return gst_resource_error_once.get(gst_resource_error_register);
}

var gst_stream_error_values = [_]c.GEnumValue{
    .{ .value = 1, .value_name = "GST_STREAM_ERROR_FAILED", .value_nick = "failed" },
    .{ .value = 2, .value_name = "GST_STREAM_ERROR_TOO_LAZY", .value_nick = "too-lazy" },
    .{ .value = 3, .value_name = "GST_STREAM_ERROR_NOT_IMPLEMENTED", .value_nick = "not-implemented" },
    .{ .value = 4, .value_name = "GST_STREAM_ERROR_TYPE_NOT_FOUND", .value_nick = "type-not-found" },
    .{ .value = 5, .value_name = "GST_STREAM_ERROR_WRONG_TYPE", .value_nick = "wrong-type" },
    .{ .value = 6, .value_name = "GST_STREAM_ERROR_CODEC_NOT_FOUND", .value_nick = "codec-not-found" },
    .{ .value = 7, .value_name = "GST_STREAM_ERROR_DECODE", .value_nick = "decode" },
    .{ .value = 8, .value_name = "GST_STREAM_ERROR_ENCODE", .value_nick = "encode" },
    .{ .value = 9, .value_name = "GST_STREAM_ERROR_DEMUX", .value_nick = "demux" },
    .{ .value = 10, .value_name = "GST_STREAM_ERROR_MUX", .value_nick = "mux" },
    .{ .value = 11, .value_name = "GST_STREAM_ERROR_FORMAT", .value_nick = "format" },
    .{ .value = 12, .value_name = "GST_STREAM_ERROR_DECRYPT", .value_nick = "decrypt" },
    .{ .value = 13, .value_name = "GST_STREAM_ERROR_DECRYPT_NOKEY", .value_nick = "decrypt-nokey" },
    .{ .value = 14, .value_name = "GST_STREAM_ERROR_NUM_ERRORS", .value_nick = "num-errors" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_stream_error_once: gtype.Once = .{};
fn gst_stream_error_register() c.GType {
    return c.g_enum_register_static("GstStreamError", &gst_stream_error_values);
}
pub export fn gst_stream_error_get_type() c.GType {
    return gst_stream_error_once.get(gst_stream_error_register);
}

var gst_event_type_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_EVENT_TYPE_UPSTREAM", .value_nick = "upstream" },
    .{ .value = 2, .value_name = "GST_EVENT_TYPE_DOWNSTREAM", .value_nick = "downstream" },
    .{ .value = 4, .value_name = "GST_EVENT_TYPE_SERIALIZED", .value_nick = "serialized" },
    .{ .value = 8, .value_name = "GST_EVENT_TYPE_STICKY", .value_nick = "sticky" },
    .{ .value = 16, .value_name = "GST_EVENT_TYPE_STICKY_MULTI", .value_nick = "sticky-multi" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_event_type_flags_once: gtype.Once = .{};
fn gst_event_type_flags_register() c.GType {
    return c.g_flags_register_static("GstEventTypeFlags", &gst_event_type_flags_values);
}
pub export fn gst_event_type_flags_get_type() c.GType {
    return gst_event_type_flags_once.get(gst_event_type_flags_register);
}

var gst_event_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_EVENT_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 2563, .value_name = "GST_EVENT_FLUSH_START", .value_nick = "flush-start" },
    .{ .value = 5127, .value_name = "GST_EVENT_FLUSH_STOP", .value_nick = "flush-stop" },
    .{ .value = 10254, .value_name = "GST_EVENT_STREAM_START", .value_nick = "stream-start" },
    .{ .value = 12814, .value_name = "GST_EVENT_CAPS", .value_nick = "caps" },
    .{ .value = 17934, .value_name = "GST_EVENT_SEGMENT", .value_nick = "segment" },
    .{ .value = 19230, .value_name = "GST_EVENT_STREAM_COLLECTION", .value_nick = "stream-collection" },
    .{ .value = 20510, .value_name = "GST_EVENT_TAG", .value_nick = "tag" },
    .{ .value = 23054, .value_name = "GST_EVENT_BUFFERSIZE", .value_nick = "buffersize" },
    .{ .value = 25630, .value_name = "GST_EVENT_SINK_MESSAGE", .value_nick = "sink-message" },
    .{ .value = 26894, .value_name = "GST_EVENT_STREAM_GROUP_DONE", .value_nick = "stream-group-done" },
    .{ .value = 28174, .value_name = "GST_EVENT_EOS", .value_nick = "eos" },
    .{ .value = 30750, .value_name = "GST_EVENT_TOC", .value_nick = "toc" },
    .{ .value = 33310, .value_name = "GST_EVENT_PROTECTION", .value_nick = "protection" },
    .{ .value = 38406, .value_name = "GST_EVENT_SEGMENT_DONE", .value_nick = "segment-done" },
    .{ .value = 40966, .value_name = "GST_EVENT_GAP", .value_nick = "gap" },
    .{ .value = 46090, .value_name = "GST_EVENT_INSTANT_RATE_CHANGE", .value_nick = "instant-rate-change" },
    .{ .value = 48641, .value_name = "GST_EVENT_QOS", .value_nick = "qos" },
    .{ .value = 51201, .value_name = "GST_EVENT_SEEK", .value_nick = "seek" },
    .{ .value = 53761, .value_name = "GST_EVENT_NAVIGATION", .value_nick = "navigation" },
    .{ .value = 56321, .value_name = "GST_EVENT_LATENCY", .value_nick = "latency" },
    .{ .value = 58881, .value_name = "GST_EVENT_STEP", .value_nick = "step" },
    .{ .value = 61441, .value_name = "GST_EVENT_RECONFIGURE", .value_nick = "reconfigure" },
    .{ .value = 64001, .value_name = "GST_EVENT_TOC_SELECT", .value_nick = "toc-select" },
    .{ .value = 66561, .value_name = "GST_EVENT_SELECT_STREAMS", .value_nick = "select-streams" },
    .{ .value = 66817, .value_name = "GST_EVENT_INSTANT_RATE_SYNC_TIME", .value_nick = "instant-rate-sync-time" },
    .{ .value = 69121, .value_name = "GST_EVENT_CUSTOM_UPSTREAM", .value_nick = "custom-upstream" },
    .{ .value = 71686, .value_name = "GST_EVENT_CUSTOM_DOWNSTREAM", .value_nick = "custom-downstream" },
    .{ .value = 74242, .value_name = "GST_EVENT_CUSTOM_DOWNSTREAM_OOB", .value_nick = "custom-downstream-oob" },
    .{ .value = 76830, .value_name = "GST_EVENT_CUSTOM_DOWNSTREAM_STICKY", .value_nick = "custom-downstream-sticky" },
    .{ .value = 79367, .value_name = "GST_EVENT_CUSTOM_BOTH", .value_nick = "custom-both" },
    .{ .value = 81923, .value_name = "GST_EVENT_CUSTOM_BOTH_OOB", .value_nick = "custom-both-oob" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_event_type_once: gtype.Once = .{};
fn gst_event_type_register() c.GType {
    return c.g_enum_register_static("GstEventType", &gst_event_type_values);
}
pub export fn gst_event_type_get_type() c.GType {
    return gst_event_type_once.get(gst_event_type_register);
}

var gst_stream_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_STREAM_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_STREAM_FLAG_SPARSE", .value_nick = "sparse" },
    .{ .value = 2, .value_name = "GST_STREAM_FLAG_SELECT", .value_nick = "select" },
    .{ .value = 4, .value_name = "GST_STREAM_FLAG_UNSELECT", .value_nick = "unselect" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_stream_flags_once: gtype.Once = .{};
fn gst_stream_flags_register() c.GType {
    return c.g_flags_register_static("GstStreamFlags", &gst_stream_flags_values);
}
pub export fn gst_stream_flags_get_type() c.GType {
    return gst_stream_flags_once.get(gst_stream_flags_register);
}

var gst_qos_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_QOS_TYPE_OVERFLOW", .value_nick = "overflow" },
    .{ .value = 1, .value_name = "GST_QOS_TYPE_UNDERFLOW", .value_nick = "underflow" },
    .{ .value = 2, .value_name = "GST_QOS_TYPE_THROTTLE", .value_nick = "throttle" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_qos_type_once: gtype.Once = .{};
fn gst_qos_type_register() c.GType {
    return c.g_enum_register_static("GstQOSType", &gst_qos_type_values);
}
pub export fn gst_qos_type_get_type() c.GType {
    return gst_qos_type_once.get(gst_qos_type_register);
}

var gst_gap_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_GAP_FLAG_MISSING_DATA", .value_nick = "data" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_gap_flags_once: gtype.Once = .{};
fn gst_gap_flags_register() c.GType {
    return c.g_flags_register_static("GstGapFlags", &gst_gap_flags_values);
}
pub export fn gst_gap_flags_get_type() c.GType {
    return gst_gap_flags_once.get(gst_gap_flags_register);
}

var gst_format_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_FORMAT_UNDEFINED", .value_nick = "undefined" },
    .{ .value = 1, .value_name = "GST_FORMAT_DEFAULT", .value_nick = "default" },
    .{ .value = 2, .value_name = "GST_FORMAT_BYTES", .value_nick = "bytes" },
    .{ .value = 3, .value_name = "GST_FORMAT_TIME", .value_nick = "time" },
    .{ .value = 4, .value_name = "GST_FORMAT_BUFFERS", .value_nick = "buffers" },
    .{ .value = 5, .value_name = "GST_FORMAT_PERCENT", .value_nick = "percent" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_format_once: gtype.Once = .{};
fn gst_format_register() c.GType {
    return c.g_enum_register_static("GstFormat", &gst_format_values);
}
pub export fn gst_format_get_type() c.GType {
    return gst_format_once.get(gst_format_register);
}

var gst_debug_level_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_LEVEL_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_LEVEL_ERROR", .value_nick = "error" },
    .{ .value = 2, .value_name = "GST_LEVEL_WARNING", .value_nick = "warning" },
    .{ .value = 3, .value_name = "GST_LEVEL_FIXME", .value_nick = "fixme" },
    .{ .value = 4, .value_name = "GST_LEVEL_INFO", .value_nick = "info" },
    .{ .value = 5, .value_name = "GST_LEVEL_DEBUG", .value_nick = "debug" },
    .{ .value = 6, .value_name = "GST_LEVEL_LOG", .value_nick = "log" },
    .{ .value = 7, .value_name = "GST_LEVEL_TRACE", .value_nick = "trace" },
    .{ .value = 9, .value_name = "GST_LEVEL_MEMDUMP", .value_nick = "memdump" },
    .{ .value = 10, .value_name = "GST_LEVEL_COUNT", .value_nick = "count" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_debug_level_once: gtype.Once = .{};
fn gst_debug_level_register() c.GType {
    return c.g_enum_register_static("GstDebugLevel", &gst_debug_level_values);
}
pub export fn gst_debug_level_get_type() c.GType {
    return gst_debug_level_once.get(gst_debug_level_register);
}

var gst_debug_color_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_DEBUG_FG_BLACK", .value_nick = "fg-black" },
    .{ .value = 1, .value_name = "GST_DEBUG_FG_RED", .value_nick = "fg-red" },
    .{ .value = 2, .value_name = "GST_DEBUG_FG_GREEN", .value_nick = "fg-green" },
    .{ .value = 3, .value_name = "GST_DEBUG_FG_YELLOW", .value_nick = "fg-yellow" },
    .{ .value = 4, .value_name = "GST_DEBUG_FG_BLUE", .value_nick = "fg-blue" },
    .{ .value = 5, .value_name = "GST_DEBUG_FG_MAGENTA", .value_nick = "fg-magenta" },
    .{ .value = 6, .value_name = "GST_DEBUG_FG_CYAN", .value_nick = "fg-cyan" },
    .{ .value = 7, .value_name = "GST_DEBUG_FG_WHITE", .value_nick = "fg-white" },
    .{ .value = 0, .value_name = "GST_DEBUG_BG_BLACK", .value_nick = "bg-black" },
    .{ .value = 16, .value_name = "GST_DEBUG_BG_RED", .value_nick = "bg-red" },
    .{ .value = 32, .value_name = "GST_DEBUG_BG_GREEN", .value_nick = "bg-green" },
    .{ .value = 48, .value_name = "GST_DEBUG_BG_YELLOW", .value_nick = "bg-yellow" },
    .{ .value = 64, .value_name = "GST_DEBUG_BG_BLUE", .value_nick = "bg-blue" },
    .{ .value = 80, .value_name = "GST_DEBUG_BG_MAGENTA", .value_nick = "bg-magenta" },
    .{ .value = 96, .value_name = "GST_DEBUG_BG_CYAN", .value_nick = "bg-cyan" },
    .{ .value = 112, .value_name = "GST_DEBUG_BG_WHITE", .value_nick = "bg-white" },
    .{ .value = 256, .value_name = "GST_DEBUG_BOLD", .value_nick = "bold" },
    .{ .value = 512, .value_name = "GST_DEBUG_UNDERLINE", .value_nick = "underline" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_debug_color_flags_once: gtype.Once = .{};
fn gst_debug_color_flags_register() c.GType {
    return c.g_flags_register_static("GstDebugColorFlags", &gst_debug_color_flags_values);
}
pub export fn gst_debug_color_flags_get_type() c.GType {
    return gst_debug_color_flags_once.get(gst_debug_color_flags_register);
}

var gst_stack_trace_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_STACK_TRACE_SHOW_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_STACK_TRACE_SHOW_FULL", .value_nick = "full" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_stack_trace_flags_once: gtype.Once = .{};
fn gst_stack_trace_flags_register() c.GType {
    return c.g_flags_register_static("GstStackTraceFlags", &gst_stack_trace_flags_values);
}
pub export fn gst_stack_trace_flags_get_type() c.GType {
    return gst_stack_trace_flags_once.get(gst_stack_trace_flags_register);
}

var gst_debug_color_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_DEBUG_COLOR_MODE_OFF", .value_nick = "off" },
    .{ .value = 1, .value_name = "GST_DEBUG_COLOR_MODE_ON", .value_nick = "on" },
    .{ .value = 2, .value_name = "GST_DEBUG_COLOR_MODE_UNIX", .value_nick = "unix" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_debug_color_mode_once: gtype.Once = .{};
fn gst_debug_color_mode_register() c.GType {
    return c.g_enum_register_static("GstDebugColorMode", &gst_debug_color_mode_values);
}
pub export fn gst_debug_color_mode_get_type() c.GType {
    return gst_debug_color_mode_once.get(gst_debug_color_mode_register);
}

var gst_log_context_hash_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_LOG_CONTEXT_DEFAULT", .value_nick = "default" },
    .{ .value = 1, .value_name = "GST_LOG_CONTEXT_IGNORE_OBJECT", .value_nick = "ignore-object" },
    .{ .value = 2, .value_name = "GST_LOG_CONTEXT_IGNORE_FORMAT", .value_nick = "ignore-format" },
    .{ .value = 4, .value_name = "GST_LOG_CONTEXT_IGNORE_FILE", .value_nick = "ignore-file" },
    .{ .value = 8, .value_name = "GST_LOG_CONTEXT_USE_LINE_NUMBER", .value_nick = "use-line-number" },
    .{ .value = 16, .value_name = "GST_LOG_CONTEXT_USE_STRING_ARGS", .value_nick = "use-string-args" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_log_context_hash_flags_once: gtype.Once = .{};
fn gst_log_context_hash_flags_register() c.GType {
    return c.g_flags_register_static("GstLogContextHashFlags", &gst_log_context_hash_flags_values);
}
pub export fn gst_log_context_hash_flags_get_type() c.GType {
    return gst_log_context_hash_flags_once.get(gst_log_context_hash_flags_register);
}

var gst_log_context_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_LOG_CONTEXT_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_LOG_CONTEXT_FLAG_THROTTLE", .value_nick = "throttle" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_log_context_flags_once: gtype.Once = .{};
fn gst_log_context_flags_register() c.GType {
    return c.g_flags_register_static("GstLogContextFlags", &gst_log_context_flags_values);
}
pub export fn gst_log_context_flags_get_type() c.GType {
    return gst_log_context_flags_once.get(gst_log_context_flags_register);
}

var gst_iterator_result_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_ITERATOR_DONE", .value_nick = "done" },
    .{ .value = 1, .value_name = "GST_ITERATOR_OK", .value_nick = "ok" },
    .{ .value = 2, .value_name = "GST_ITERATOR_RESYNC", .value_nick = "resync" },
    .{ .value = 3, .value_name = "GST_ITERATOR_ERROR", .value_nick = "error" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_iterator_result_once: gtype.Once = .{};
fn gst_iterator_result_register() c.GType {
    return c.g_enum_register_static("GstIteratorResult", &gst_iterator_result_values);
}
pub export fn gst_iterator_result_get_type() c.GType {
    return gst_iterator_result_once.get(gst_iterator_result_register);
}

var gst_iterator_item_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_ITERATOR_ITEM_SKIP", .value_nick = "skip" },
    .{ .value = 1, .value_name = "GST_ITERATOR_ITEM_PASS", .value_nick = "pass" },
    .{ .value = 2, .value_name = "GST_ITERATOR_ITEM_END", .value_nick = "end" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_iterator_item_once: gtype.Once = .{};
fn gst_iterator_item_register() c.GType {
    return c.g_enum_register_static("GstIteratorItem", &gst_iterator_item_values);
}
pub export fn gst_iterator_item_get_type() c.GType {
    return gst_iterator_item_once.get(gst_iterator_item_register);
}

var gst_memory_flags_values = [_]c.GFlagsValue{
    .{ .value = 2, .value_name = "GST_MEMORY_FLAG_READONLY", .value_nick = "readonly" },
    .{ .value = 16, .value_name = "GST_MEMORY_FLAG_NO_SHARE", .value_nick = "no-share" },
    .{ .value = 32, .value_name = "GST_MEMORY_FLAG_ZERO_PREFIXED", .value_nick = "zero-prefixed" },
    .{ .value = 64, .value_name = "GST_MEMORY_FLAG_ZERO_PADDED", .value_nick = "zero-padded" },
    .{ .value = 128, .value_name = "GST_MEMORY_FLAG_PHYSICALLY_CONTIGUOUS", .value_nick = "physically-contiguous" },
    .{ .value = 256, .value_name = "GST_MEMORY_FLAG_NOT_MAPPABLE", .value_nick = "not-mappable" },
    .{ .value = 1048576, .value_name = "GST_MEMORY_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_memory_flags_once: gtype.Once = .{};
fn gst_memory_flags_register() c.GType {
    return c.g_flags_register_static("GstMemoryFlags", &gst_memory_flags_values);
}
pub export fn gst_memory_flags_get_type() c.GType {
    return gst_memory_flags_once.get(gst_memory_flags_register);
}

var gst_map_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_MAP_READ", .value_nick = "read" },
    .{ .value = 2, .value_name = "GST_MAP_WRITE", .value_nick = "write" },
    .{ .value = 256, .value_name = "GST_MAP_REF_MEMORY", .value_nick = "ref-memory" },
    .{ .value = 65536, .value_name = "GST_MAP_FLAG_LAST", .value_nick = "flag-last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_map_flags_once: gtype.Once = .{};
fn gst_map_flags_register() c.GType {
    return c.g_flags_register_static("GstMapFlags", &gst_map_flags_values);
}
pub export fn gst_map_flags_get_type() c.GType {
    return gst_map_flags_once.get(gst_map_flags_register);
}

var gst_message_type_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_MESSAGE_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_MESSAGE_EOS", .value_nick = "eos" },
    .{ .value = 2, .value_name = "GST_MESSAGE_ERROR", .value_nick = "error" },
    .{ .value = 4, .value_name = "GST_MESSAGE_WARNING", .value_nick = "warning" },
    .{ .value = 8, .value_name = "GST_MESSAGE_INFO", .value_nick = "info" },
    .{ .value = 16, .value_name = "GST_MESSAGE_TAG", .value_nick = "tag" },
    .{ .value = 32, .value_name = "GST_MESSAGE_BUFFERING", .value_nick = "buffering" },
    .{ .value = 64, .value_name = "GST_MESSAGE_STATE_CHANGED", .value_nick = "state-changed" },
    .{ .value = 128, .value_name = "GST_MESSAGE_STATE_DIRTY", .value_nick = "state-dirty" },
    .{ .value = 256, .value_name = "GST_MESSAGE_STEP_DONE", .value_nick = "step-done" },
    .{ .value = 512, .value_name = "GST_MESSAGE_CLOCK_PROVIDE", .value_nick = "clock-provide" },
    .{ .value = 1024, .value_name = "GST_MESSAGE_CLOCK_LOST", .value_nick = "clock-lost" },
    .{ .value = 2048, .value_name = "GST_MESSAGE_NEW_CLOCK", .value_nick = "new-clock" },
    .{ .value = 4096, .value_name = "GST_MESSAGE_STRUCTURE_CHANGE", .value_nick = "structure-change" },
    .{ .value = 8192, .value_name = "GST_MESSAGE_STREAM_STATUS", .value_nick = "stream-status" },
    .{ .value = 16384, .value_name = "GST_MESSAGE_APPLICATION", .value_nick = "application" },
    .{ .value = 32768, .value_name = "GST_MESSAGE_ELEMENT", .value_nick = "element" },
    .{ .value = 65536, .value_name = "GST_MESSAGE_SEGMENT_START", .value_nick = "segment-start" },
    .{ .value = 131072, .value_name = "GST_MESSAGE_SEGMENT_DONE", .value_nick = "segment-done" },
    .{ .value = 262144, .value_name = "GST_MESSAGE_DURATION_CHANGED", .value_nick = "duration-changed" },
    .{ .value = 524288, .value_name = "GST_MESSAGE_LATENCY", .value_nick = "latency" },
    .{ .value = 1048576, .value_name = "GST_MESSAGE_ASYNC_START", .value_nick = "async-start" },
    .{ .value = 2097152, .value_name = "GST_MESSAGE_ASYNC_DONE", .value_nick = "async-done" },
    .{ .value = 4194304, .value_name = "GST_MESSAGE_REQUEST_STATE", .value_nick = "request-state" },
    .{ .value = 8388608, .value_name = "GST_MESSAGE_STEP_START", .value_nick = "step-start" },
    .{ .value = 16777216, .value_name = "GST_MESSAGE_QOS", .value_nick = "qos" },
    .{ .value = 33554432, .value_name = "GST_MESSAGE_PROGRESS", .value_nick = "progress" },
    .{ .value = 67108864, .value_name = "GST_MESSAGE_TOC", .value_nick = "toc" },
    .{ .value = 134217728, .value_name = "GST_MESSAGE_RESET_TIME", .value_nick = "reset-time" },
    .{ .value = 268435456, .value_name = "GST_MESSAGE_STREAM_START", .value_nick = "stream-start" },
    .{ .value = 536870912, .value_name = "GST_MESSAGE_NEED_CONTEXT", .value_nick = "need-context" },
    .{ .value = 1073741824, .value_name = "GST_MESSAGE_HAVE_CONTEXT", .value_nick = "have-context" },
    .{ .value = 2147483648, .value_name = "GST_MESSAGE_EXTENDED", .value_nick = "extended" },
    .{ .value = 2147483649, .value_name = "GST_MESSAGE_DEVICE_ADDED", .value_nick = "device-added" },
    .{ .value = 2147483650, .value_name = "GST_MESSAGE_DEVICE_REMOVED", .value_nick = "device-removed" },
    .{ .value = 2147483651, .value_name = "GST_MESSAGE_PROPERTY_NOTIFY", .value_nick = "property-notify" },
    .{ .value = 2147483652, .value_name = "GST_MESSAGE_STREAM_COLLECTION", .value_nick = "stream-collection" },
    .{ .value = 2147483653, .value_name = "GST_MESSAGE_STREAMS_SELECTED", .value_nick = "streams-selected" },
    .{ .value = 2147483654, .value_name = "GST_MESSAGE_REDIRECT", .value_nick = "redirect" },
    .{ .value = 2147483655, .value_name = "GST_MESSAGE_DEVICE_CHANGED", .value_nick = "device-changed" },
    .{ .value = 2147483656, .value_name = "GST_MESSAGE_INSTANT_RATE_REQUEST", .value_nick = "instant-rate-request" },
    .{ .value = 2147483657, .value_name = "GST_MESSAGE_DEVICE_MONITOR_STARTED", .value_nick = "device-monitor-started" },
    .{ .value = 4294967295, .value_name = "GST_MESSAGE_ANY", .value_nick = "any" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_message_type_once: gtype.Once = .{};
fn gst_message_type_register() c.GType {
    return c.g_flags_register_static("GstMessageType", &gst_message_type_values);
}
pub export fn gst_message_type_get_type() c.GType {
    return gst_message_type_once.get(gst_message_type_register);
}

var gst_structure_change_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_STRUCTURE_CHANGE_TYPE_PAD_LINK", .value_nick = "link" },
    .{ .value = 1, .value_name = "GST_STRUCTURE_CHANGE_TYPE_PAD_UNLINK", .value_nick = "unlink" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_structure_change_type_once: gtype.Once = .{};
fn gst_structure_change_type_register() c.GType {
    return c.g_enum_register_static("GstStructureChangeType", &gst_structure_change_type_values);
}
pub export fn gst_structure_change_type_get_type() c.GType {
    return gst_structure_change_type_once.get(gst_structure_change_type_register);
}

var gst_stream_status_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_STREAM_STATUS_TYPE_CREATE", .value_nick = "create" },
    .{ .value = 1, .value_name = "GST_STREAM_STATUS_TYPE_ENTER", .value_nick = "enter" },
    .{ .value = 2, .value_name = "GST_STREAM_STATUS_TYPE_LEAVE", .value_nick = "leave" },
    .{ .value = 3, .value_name = "GST_STREAM_STATUS_TYPE_DESTROY", .value_nick = "destroy" },
    .{ .value = 8, .value_name = "GST_STREAM_STATUS_TYPE_START", .value_nick = "start" },
    .{ .value = 9, .value_name = "GST_STREAM_STATUS_TYPE_PAUSE", .value_nick = "pause" },
    .{ .value = 10, .value_name = "GST_STREAM_STATUS_TYPE_STOP", .value_nick = "stop" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_stream_status_type_once: gtype.Once = .{};
fn gst_stream_status_type_register() c.GType {
    return c.g_enum_register_static("GstStreamStatusType", &gst_stream_status_type_values);
}
pub export fn gst_stream_status_type_get_type() c.GType {
    return gst_stream_status_type_once.get(gst_stream_status_type_register);
}

var gst_progress_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_PROGRESS_TYPE_START", .value_nick = "start" },
    .{ .value = 1, .value_name = "GST_PROGRESS_TYPE_CONTINUE", .value_nick = "continue" },
    .{ .value = 2, .value_name = "GST_PROGRESS_TYPE_COMPLETE", .value_nick = "complete" },
    .{ .value = 3, .value_name = "GST_PROGRESS_TYPE_CANCELED", .value_nick = "canceled" },
    .{ .value = 4, .value_name = "GST_PROGRESS_TYPE_ERROR", .value_nick = "error" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_progress_type_once: gtype.Once = .{};
fn gst_progress_type_register() c.GType {
    return c.g_enum_register_static("GstProgressType", &gst_progress_type_values);
}
pub export fn gst_progress_type_get_type() c.GType {
    return gst_progress_type_once.get(gst_progress_type_register);
}

var gst_meta_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_META_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_META_FLAG_READONLY", .value_nick = "readonly" },
    .{ .value = 2, .value_name = "GST_META_FLAG_POOLED", .value_nick = "pooled" },
    .{ .value = 4, .value_name = "GST_META_FLAG_LOCKED", .value_nick = "locked" },
    .{ .value = 65536, .value_name = "GST_META_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_meta_flags_once: gtype.Once = .{};
fn gst_meta_flags_register() c.GType {
    return c.g_flags_register_static("GstMetaFlags", &gst_meta_flags_values);
}
pub export fn gst_meta_flags_get_type() c.GType {
    return gst_meta_flags_once.get(gst_meta_flags_register);
}

var gst_mini_object_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_MINI_OBJECT_FLAG_LOCKABLE", .value_nick = "lockable" },
    .{ .value = 2, .value_name = "GST_MINI_OBJECT_FLAG_LOCK_READONLY", .value_nick = "lock-readonly" },
    .{ .value = 4, .value_name = "GST_MINI_OBJECT_FLAG_MAY_BE_LEAKED", .value_nick = "may-be-leaked" },
    .{ .value = 16, .value_name = "GST_MINI_OBJECT_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_mini_object_flags_once: gtype.Once = .{};
fn gst_mini_object_flags_register() c.GType {
    return c.g_flags_register_static("GstMiniObjectFlags", &gst_mini_object_flags_values);
}
pub export fn gst_mini_object_flags_get_type() c.GType {
    return gst_mini_object_flags_once.get(gst_mini_object_flags_register);
}

var gst_lock_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_LOCK_FLAG_READ", .value_nick = "read" },
    .{ .value = 2, .value_name = "GST_LOCK_FLAG_WRITE", .value_nick = "write" },
    .{ .value = 4, .value_name = "GST_LOCK_FLAG_EXCLUSIVE", .value_nick = "exclusive" },
    .{ .value = 256, .value_name = "GST_LOCK_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_lock_flags_once: gtype.Once = .{};
fn gst_lock_flags_register() c.GType {
    return c.g_flags_register_static("GstLockFlags", &gst_lock_flags_values);
}
pub export fn gst_lock_flags_get_type() c.GType {
    return gst_lock_flags_once.get(gst_lock_flags_register);
}

var gst_object_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_OBJECT_FLAG_MAY_BE_LEAKED", .value_nick = "may-be-leaked" },
    .{ .value = 2, .value_name = "GST_OBJECT_FLAG_CONSTRUCTED", .value_nick = "constructed" },
    .{ .value = 16, .value_name = "GST_OBJECT_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_object_flags_once: gtype.Once = .{};
fn gst_object_flags_register() c.GType {
    return c.g_flags_register_static("GstObjectFlags", &gst_object_flags_values);
}
pub export fn gst_object_flags_get_type() c.GType {
    return gst_object_flags_once.get(gst_object_flags_register);
}

var gst_pad_direction_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_PAD_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_PAD_SRC", .value_nick = "src" },
    .{ .value = 2, .value_name = "GST_PAD_SINK", .value_nick = "sink" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_pad_direction_once: gtype.Once = .{};
fn gst_pad_direction_register() c.GType {
    return c.g_enum_register_static("GstPadDirection", &gst_pad_direction_values);
}
pub export fn gst_pad_direction_get_type() c.GType {
    return gst_pad_direction_once.get(gst_pad_direction_register);
}

var gst_pad_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_PAD_MODE_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_PAD_MODE_PUSH", .value_nick = "push" },
    .{ .value = 2, .value_name = "GST_PAD_MODE_PULL", .value_nick = "pull" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_pad_mode_once: gtype.Once = .{};
fn gst_pad_mode_register() c.GType {
    return c.g_enum_register_static("GstPadMode", &gst_pad_mode_values);
}
pub export fn gst_pad_mode_get_type() c.GType {
    return gst_pad_mode_once.get(gst_pad_mode_register);
}

var gst_pad_link_return_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_PAD_LINK_OK", .value_nick = "ok" },
    .{ .value = -1, .value_name = "GST_PAD_LINK_WRONG_HIERARCHY", .value_nick = "wrong-hierarchy" },
    .{ .value = -2, .value_name = "GST_PAD_LINK_WAS_LINKED", .value_nick = "was-linked" },
    .{ .value = -3, .value_name = "GST_PAD_LINK_WRONG_DIRECTION", .value_nick = "wrong-direction" },
    .{ .value = -4, .value_name = "GST_PAD_LINK_NOFORMAT", .value_nick = "noformat" },
    .{ .value = -5, .value_name = "GST_PAD_LINK_NOSCHED", .value_nick = "nosched" },
    .{ .value = -6, .value_name = "GST_PAD_LINK_REFUSED", .value_nick = "refused" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_pad_link_return_once: gtype.Once = .{};
fn gst_pad_link_return_register() c.GType {
    return c.g_enum_register_static("GstPadLinkReturn", &gst_pad_link_return_values);
}
pub export fn gst_pad_link_return_get_type() c.GType {
    return gst_pad_link_return_once.get(gst_pad_link_return_register);
}

var gst_flow_return_values = [_]c.GEnumValue{
    .{ .value = 102, .value_name = "GST_FLOW_CUSTOM_SUCCESS_2", .value_nick = "custom-success-2" },
    .{ .value = 101, .value_name = "GST_FLOW_CUSTOM_SUCCESS_1", .value_nick = "custom-success-1" },
    .{ .value = 100, .value_name = "GST_FLOW_CUSTOM_SUCCESS", .value_nick = "custom-success" },
    .{ .value = 0, .value_name = "GST_FLOW_OK", .value_nick = "ok" },
    .{ .value = -1, .value_name = "GST_FLOW_NOT_LINKED", .value_nick = "not-linked" },
    .{ .value = -2, .value_name = "GST_FLOW_FLUSHING", .value_nick = "flushing" },
    .{ .value = -3, .value_name = "GST_FLOW_EOS", .value_nick = "eos" },
    .{ .value = -4, .value_name = "GST_FLOW_NOT_NEGOTIATED", .value_nick = "not-negotiated" },
    .{ .value = -5, .value_name = "GST_FLOW_ERROR", .value_nick = "error" },
    .{ .value = -6, .value_name = "GST_FLOW_NOT_SUPPORTED", .value_nick = "not-supported" },
    .{ .value = -100, .value_name = "GST_FLOW_CUSTOM_ERROR", .value_nick = "custom-error" },
    .{ .value = -101, .value_name = "GST_FLOW_CUSTOM_ERROR_1", .value_nick = "custom-error-1" },
    .{ .value = -102, .value_name = "GST_FLOW_CUSTOM_ERROR_2", .value_nick = "custom-error-2" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_flow_return_once: gtype.Once = .{};
fn gst_flow_return_register() c.GType {
    return c.g_enum_register_static("GstFlowReturn", &gst_flow_return_values);
}
pub export fn gst_flow_return_get_type() c.GType {
    return gst_flow_return_once.get(gst_flow_return_register);
}

var gst_pad_link_check_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_PAD_LINK_CHECK_NOTHING", .value_nick = "nothing" },
    .{ .value = 1, .value_name = "GST_PAD_LINK_CHECK_HIERARCHY", .value_nick = "hierarchy" },
    .{ .value = 2, .value_name = "GST_PAD_LINK_CHECK_TEMPLATE_CAPS", .value_nick = "template-caps" },
    .{ .value = 4, .value_name = "GST_PAD_LINK_CHECK_CAPS", .value_nick = "caps" },
    .{ .value = 8, .value_name = "GST_PAD_LINK_CHECK_NO_RECONFIGURE", .value_nick = "no-reconfigure" },
    .{ .value = 5, .value_name = "GST_PAD_LINK_CHECK_DEFAULT", .value_nick = "default" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_pad_link_check_once: gtype.Once = .{};
fn gst_pad_link_check_register() c.GType {
    return c.g_flags_register_static("GstPadLinkCheck", &gst_pad_link_check_values);
}
pub export fn gst_pad_link_check_get_type() c.GType {
    return gst_pad_link_check_once.get(gst_pad_link_check_register);
}

var gst_pad_probe_type_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_PAD_PROBE_TYPE_INVALID", .value_nick = "invalid" },
    .{ .value = 1, .value_name = "GST_PAD_PROBE_TYPE_IDLE", .value_nick = "idle" },
    .{ .value = 2, .value_name = "GST_PAD_PROBE_TYPE_BLOCK", .value_nick = "block" },
    .{ .value = 16, .value_name = "GST_PAD_PROBE_TYPE_BUFFER", .value_nick = "buffer" },
    .{ .value = 32, .value_name = "GST_PAD_PROBE_TYPE_BUFFER_LIST", .value_nick = "buffer-list" },
    .{ .value = 64, .value_name = "GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM", .value_nick = "event-downstream" },
    .{ .value = 128, .value_name = "GST_PAD_PROBE_TYPE_EVENT_UPSTREAM", .value_nick = "event-upstream" },
    .{ .value = 256, .value_name = "GST_PAD_PROBE_TYPE_EVENT_FLUSH", .value_nick = "event-flush" },
    .{ .value = 512, .value_name = "GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM", .value_nick = "query-downstream" },
    .{ .value = 1024, .value_name = "GST_PAD_PROBE_TYPE_QUERY_UPSTREAM", .value_nick = "query-upstream" },
    .{ .value = 4096, .value_name = "GST_PAD_PROBE_TYPE_PUSH", .value_nick = "push" },
    .{ .value = 8192, .value_name = "GST_PAD_PROBE_TYPE_PULL", .value_nick = "pull" },
    .{ .value = 3, .value_name = "GST_PAD_PROBE_TYPE_BLOCKING", .value_nick = "blocking" },
    .{ .value = 112, .value_name = "GST_PAD_PROBE_TYPE_DATA_DOWNSTREAM", .value_nick = "data-downstream" },
    .{ .value = 128, .value_name = "GST_PAD_PROBE_TYPE_DATA_UPSTREAM", .value_nick = "data-upstream" },
    .{ .value = 240, .value_name = "GST_PAD_PROBE_TYPE_DATA_BOTH", .value_nick = "data-both" },
    .{ .value = 114, .value_name = "GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM", .value_nick = "block-downstream" },
    .{ .value = 130, .value_name = "GST_PAD_PROBE_TYPE_BLOCK_UPSTREAM", .value_nick = "block-upstream" },
    .{ .value = 192, .value_name = "GST_PAD_PROBE_TYPE_EVENT_BOTH", .value_nick = "event-both" },
    .{ .value = 1536, .value_name = "GST_PAD_PROBE_TYPE_QUERY_BOTH", .value_nick = "query-both" },
    .{ .value = 1776, .value_name = "GST_PAD_PROBE_TYPE_ALL_BOTH", .value_nick = "all-both" },
    .{ .value = 12288, .value_name = "GST_PAD_PROBE_TYPE_SCHEDULING", .value_nick = "scheduling" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_pad_probe_type_once: gtype.Once = .{};
fn gst_pad_probe_type_register() c.GType {
    return c.g_flags_register_static("GstPadProbeType", &gst_pad_probe_type_values);
}
pub export fn gst_pad_probe_type_get_type() c.GType {
    return gst_pad_probe_type_once.get(gst_pad_probe_type_register);
}

var gst_pad_probe_return_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_PAD_PROBE_DROP", .value_nick = "drop" },
    .{ .value = 1, .value_name = "GST_PAD_PROBE_OK", .value_nick = "ok" },
    .{ .value = 2, .value_name = "GST_PAD_PROBE_REMOVE", .value_nick = "remove" },
    .{ .value = 3, .value_name = "GST_PAD_PROBE_PASS", .value_nick = "pass" },
    .{ .value = 4, .value_name = "GST_PAD_PROBE_HANDLED", .value_nick = "handled" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_pad_probe_return_once: gtype.Once = .{};
fn gst_pad_probe_return_register() c.GType {
    return c.g_enum_register_static("GstPadProbeReturn", &gst_pad_probe_return_values);
}
pub export fn gst_pad_probe_return_get_type() c.GType {
    return gst_pad_probe_return_once.get(gst_pad_probe_return_register);
}

var gst_pad_flags_values = [_]c.GFlagsValue{
    .{ .value = 16, .value_name = "GST_PAD_FLAG_BLOCKED", .value_nick = "blocked" },
    .{ .value = 32, .value_name = "GST_PAD_FLAG_FLUSHING", .value_nick = "flushing" },
    .{ .value = 64, .value_name = "GST_PAD_FLAG_EOS", .value_nick = "eos" },
    .{ .value = 128, .value_name = "GST_PAD_FLAG_BLOCKING", .value_nick = "blocking" },
    .{ .value = 256, .value_name = "GST_PAD_FLAG_NEED_PARENT", .value_nick = "need-parent" },
    .{ .value = 512, .value_name = "GST_PAD_FLAG_NEED_RECONFIGURE", .value_nick = "need-reconfigure" },
    .{ .value = 1024, .value_name = "GST_PAD_FLAG_PENDING_EVENTS", .value_nick = "pending-events" },
    .{ .value = 2048, .value_name = "GST_PAD_FLAG_FIXED_CAPS", .value_nick = "fixed-caps" },
    .{ .value = 4096, .value_name = "GST_PAD_FLAG_PROXY_CAPS", .value_nick = "proxy-caps" },
    .{ .value = 8192, .value_name = "GST_PAD_FLAG_PROXY_ALLOCATION", .value_nick = "proxy-allocation" },
    .{ .value = 16384, .value_name = "GST_PAD_FLAG_PROXY_SCHEDULING", .value_nick = "proxy-scheduling" },
    .{ .value = 32768, .value_name = "GST_PAD_FLAG_ACCEPT_INTERSECT", .value_nick = "accept-intersect" },
    .{ .value = 65536, .value_name = "GST_PAD_FLAG_ACCEPT_TEMPLATE", .value_nick = "accept-template" },
    .{ .value = 1048576, .value_name = "GST_PAD_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_pad_flags_once: gtype.Once = .{};
fn gst_pad_flags_register() c.GType {
    return c.g_flags_register_static("GstPadFlags", &gst_pad_flags_values);
}
pub export fn gst_pad_flags_get_type() c.GType {
    return gst_pad_flags_once.get(gst_pad_flags_register);
}

var gst_pad_presence_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_PAD_ALWAYS", .value_nick = "always" },
    .{ .value = 1, .value_name = "GST_PAD_SOMETIMES", .value_nick = "sometimes" },
    .{ .value = 2, .value_name = "GST_PAD_REQUEST", .value_nick = "request" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_pad_presence_once: gtype.Once = .{};
fn gst_pad_presence_register() c.GType {
    return c.g_enum_register_static("GstPadPresence", &gst_pad_presence_values);
}
pub export fn gst_pad_presence_get_type() c.GType {
    return gst_pad_presence_once.get(gst_pad_presence_register);
}

var gst_pad_template_flags_values = [_]c.GFlagsValue{
    .{ .value = 256, .value_name = "GST_PAD_TEMPLATE_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_pad_template_flags_once: gtype.Once = .{};
fn gst_pad_template_flags_register() c.GType {
    return c.g_flags_register_static("GstPadTemplateFlags", &gst_pad_template_flags_values);
}
pub export fn gst_pad_template_flags_get_type() c.GType {
    return gst_pad_template_flags_once.get(gst_pad_template_flags_register);
}

var gst_parse_error_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_PARSE_ERROR_SYNTAX", .value_nick = "syntax" },
    .{ .value = 1, .value_name = "GST_PARSE_ERROR_NO_SUCH_ELEMENT", .value_nick = "no-such-element" },
    .{ .value = 2, .value_name = "GST_PARSE_ERROR_NO_SUCH_PROPERTY", .value_nick = "no-such-property" },
    .{ .value = 3, .value_name = "GST_PARSE_ERROR_LINK", .value_nick = "link" },
    .{ .value = 4, .value_name = "GST_PARSE_ERROR_COULD_NOT_SET_PROPERTY", .value_nick = "could-not-set-property" },
    .{ .value = 5, .value_name = "GST_PARSE_ERROR_EMPTY_BIN", .value_nick = "empty-bin" },
    .{ .value = 6, .value_name = "GST_PARSE_ERROR_EMPTY", .value_nick = "empty" },
    .{ .value = 7, .value_name = "GST_PARSE_ERROR_DELAYED_LINK", .value_nick = "delayed-link" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_parse_error_once: gtype.Once = .{};
fn gst_parse_error_register() c.GType {
    return c.g_enum_register_static("GstParseError", &gst_parse_error_values);
}
pub export fn gst_parse_error_get_type() c.GType {
    return gst_parse_error_once.get(gst_parse_error_register);
}

var gst_parse_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_PARSE_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_PARSE_FLAG_FATAL_ERRORS", .value_nick = "fatal-errors" },
    .{ .value = 2, .value_name = "GST_PARSE_FLAG_NO_SINGLE_ELEMENT_BINS", .value_nick = "no-single-element-bins" },
    .{ .value = 4, .value_name = "GST_PARSE_FLAG_PLACE_IN_BIN", .value_nick = "place-in-bin" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_parse_flags_once: gtype.Once = .{};
fn gst_parse_flags_register() c.GType {
    return c.g_flags_register_static("GstParseFlags", &gst_parse_flags_values);
}
pub export fn gst_parse_flags_get_type() c.GType {
    return gst_parse_flags_once.get(gst_parse_flags_register);
}

var gst_pipeline_flags_values = [_]c.GFlagsValue{
    .{ .value = 524288, .value_name = "GST_PIPELINE_FLAG_FIXED_CLOCK", .value_nick = "fixed-clock" },
    .{ .value = 8388608, .value_name = "GST_PIPELINE_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_pipeline_flags_once: gtype.Once = .{};
fn gst_pipeline_flags_register() c.GType {
    return c.g_flags_register_static("GstPipelineFlags", &gst_pipeline_flags_values);
}
pub export fn gst_pipeline_flags_get_type() c.GType {
    return gst_pipeline_flags_once.get(gst_pipeline_flags_register);
}

var gst_plugin_error_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_PLUGIN_ERROR_MODULE", .value_nick = "module" },
    .{ .value = 1, .value_name = "GST_PLUGIN_ERROR_DEPENDENCIES", .value_nick = "dependencies" },
    .{ .value = 2, .value_name = "GST_PLUGIN_ERROR_NAME_MISMATCH", .value_nick = "name-mismatch" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_plugin_error_once: gtype.Once = .{};
fn gst_plugin_error_register() c.GType {
    return c.g_enum_register_static("GstPluginError", &gst_plugin_error_values);
}
pub export fn gst_plugin_error_get_type() c.GType {
    return gst_plugin_error_once.get(gst_plugin_error_register);
}

var gst_plugin_flags_values = [_]c.GFlagsValue{
    .{ .value = 16, .value_name = "GST_PLUGIN_FLAG_CACHED", .value_nick = "cached" },
    .{ .value = 32, .value_name = "GST_PLUGIN_FLAG_BLACKLISTED", .value_nick = "blacklisted" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_plugin_flags_once: gtype.Once = .{};
fn gst_plugin_flags_register() c.GType {
    return c.g_flags_register_static("GstPluginFlags", &gst_plugin_flags_values);
}
pub export fn gst_plugin_flags_get_type() c.GType {
    return gst_plugin_flags_once.get(gst_plugin_flags_register);
}

var gst_plugin_dependency_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_PLUGIN_DEPENDENCY_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_PLUGIN_DEPENDENCY_FLAG_RECURSE", .value_nick = "recurse" },
    .{ .value = 2, .value_name = "GST_PLUGIN_DEPENDENCY_FLAG_PATHS_ARE_DEFAULT_ONLY", .value_nick = "paths-are-default-only" },
    .{ .value = 4, .value_name = "GST_PLUGIN_DEPENDENCY_FLAG_FILE_NAME_IS_SUFFIX", .value_nick = "file-name-is-suffix" },
    .{ .value = 8, .value_name = "GST_PLUGIN_DEPENDENCY_FLAG_FILE_NAME_IS_PREFIX", .value_nick = "file-name-is-prefix" },
    .{ .value = 16, .value_name = "GST_PLUGIN_DEPENDENCY_FLAG_PATHS_ARE_RELATIVE_TO_EXE", .value_nick = "paths-are-relative-to-exe" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_plugin_dependency_flags_once: gtype.Once = .{};
fn gst_plugin_dependency_flags_register() c.GType {
    return c.g_flags_register_static("GstPluginDependencyFlags", &gst_plugin_dependency_flags_values);
}
pub export fn gst_plugin_dependency_flags_get_type() c.GType {
    return gst_plugin_dependency_flags_once.get(gst_plugin_dependency_flags_register);
}

var gst_rank_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_RANK_NONE", .value_nick = "none" },
    .{ .value = 64, .value_name = "GST_RANK_MARGINAL", .value_nick = "marginal" },
    .{ .value = 128, .value_name = "GST_RANK_SECONDARY", .value_nick = "secondary" },
    .{ .value = 256, .value_name = "GST_RANK_PRIMARY", .value_nick = "primary" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_rank_once: gtype.Once = .{};
fn gst_rank_register() c.GType {
    return c.g_enum_register_static("GstRank", &gst_rank_values);
}
pub export fn gst_rank_get_type() c.GType {
    return gst_rank_once.get(gst_rank_register);
}

var gst_promise_result_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_PROMISE_RESULT_PENDING", .value_nick = "pending" },
    .{ .value = 1, .value_name = "GST_PROMISE_RESULT_INTERRUPTED", .value_nick = "interrupted" },
    .{ .value = 2, .value_name = "GST_PROMISE_RESULT_REPLIED", .value_nick = "replied" },
    .{ .value = 3, .value_name = "GST_PROMISE_RESULT_EXPIRED", .value_nick = "expired" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_promise_result_once: gtype.Once = .{};
fn gst_promise_result_register() c.GType {
    return c.g_enum_register_static("GstPromiseResult", &gst_promise_result_values);
}
pub export fn gst_promise_result_get_type() c.GType {
    return gst_promise_result_once.get(gst_promise_result_register);
}

var gst_query_type_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_QUERY_TYPE_UPSTREAM", .value_nick = "upstream" },
    .{ .value = 2, .value_name = "GST_QUERY_TYPE_DOWNSTREAM", .value_nick = "downstream" },
    .{ .value = 4, .value_name = "GST_QUERY_TYPE_SERIALIZED", .value_nick = "serialized" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_query_type_flags_once: gtype.Once = .{};
fn gst_query_type_flags_register() c.GType {
    return c.g_flags_register_static("GstQueryTypeFlags", &gst_query_type_flags_values);
}
pub export fn gst_query_type_flags_get_type() c.GType {
    return gst_query_type_flags_once.get(gst_query_type_flags_register);
}

var gst_query_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_QUERY_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 2563, .value_name = "GST_QUERY_POSITION", .value_nick = "position" },
    .{ .value = 5123, .value_name = "GST_QUERY_DURATION", .value_nick = "duration" },
    .{ .value = 7683, .value_name = "GST_QUERY_LATENCY", .value_nick = "latency" },
    .{ .value = 10243, .value_name = "GST_QUERY_JITTER", .value_nick = "jitter" },
    .{ .value = 12803, .value_name = "GST_QUERY_RATE", .value_nick = "rate" },
    .{ .value = 15363, .value_name = "GST_QUERY_SEEKING", .value_nick = "seeking" },
    .{ .value = 17923, .value_name = "GST_QUERY_SEGMENT", .value_nick = "segment" },
    .{ .value = 20483, .value_name = "GST_QUERY_CONVERT", .value_nick = "convert" },
    .{ .value = 23043, .value_name = "GST_QUERY_FORMATS", .value_nick = "formats" },
    .{ .value = 28163, .value_name = "GST_QUERY_BUFFERING", .value_nick = "buffering" },
    .{ .value = 30723, .value_name = "GST_QUERY_CUSTOM", .value_nick = "custom" },
    .{ .value = 33283, .value_name = "GST_QUERY_URI", .value_nick = "uri" },
    .{ .value = 35846, .value_name = "GST_QUERY_ALLOCATION", .value_nick = "allocation" },
    .{ .value = 38401, .value_name = "GST_QUERY_SCHEDULING", .value_nick = "scheduling" },
    .{ .value = 40963, .value_name = "GST_QUERY_ACCEPT_CAPS", .value_nick = "accept-caps" },
    .{ .value = 43523, .value_name = "GST_QUERY_CAPS", .value_nick = "caps" },
    .{ .value = 46086, .value_name = "GST_QUERY_DRAIN", .value_nick = "drain" },
    .{ .value = 48643, .value_name = "GST_QUERY_CONTEXT", .value_nick = "context" },
    .{ .value = 51202, .value_name = "GST_QUERY_BITRATE", .value_nick = "bitrate" },
    .{ .value = 53763, .value_name = "GST_QUERY_SELECTABLE", .value_nick = "selectable" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_query_type_once: gtype.Once = .{};
fn gst_query_type_register() c.GType {
    return c.g_enum_register_static("GstQueryType", &gst_query_type_values);
}
pub export fn gst_query_type_get_type() c.GType {
    return gst_query_type_once.get(gst_query_type_register);
}

var gst_buffering_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_BUFFERING_STREAM", .value_nick = "stream" },
    .{ .value = 1, .value_name = "GST_BUFFERING_DOWNLOAD", .value_nick = "download" },
    .{ .value = 2, .value_name = "GST_BUFFERING_TIMESHIFT", .value_nick = "timeshift" },
    .{ .value = 3, .value_name = "GST_BUFFERING_LIVE", .value_nick = "live" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_buffering_mode_once: gtype.Once = .{};
fn gst_buffering_mode_register() c.GType {
    return c.g_enum_register_static("GstBufferingMode", &gst_buffering_mode_values);
}
pub export fn gst_buffering_mode_get_type() c.GType {
    return gst_buffering_mode_once.get(gst_buffering_mode_register);
}

var gst_scheduling_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_SCHEDULING_FLAG_SEEKABLE", .value_nick = "seekable" },
    .{ .value = 2, .value_name = "GST_SCHEDULING_FLAG_SEQUENTIAL", .value_nick = "sequential" },
    .{ .value = 4, .value_name = "GST_SCHEDULING_FLAG_BANDWIDTH_LIMITED", .value_nick = "bandwidth-limited" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_scheduling_flags_once: gtype.Once = .{};
fn gst_scheduling_flags_register() c.GType {
    return c.g_flags_register_static("GstSchedulingFlags", &gst_scheduling_flags_values);
}
pub export fn gst_scheduling_flags_get_type() c.GType {
    return gst_scheduling_flags_once.get(gst_scheduling_flags_register);
}

var gst_seek_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_SEEK_TYPE_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_SEEK_TYPE_SET", .value_nick = "set" },
    .{ .value = 2, .value_name = "GST_SEEK_TYPE_END", .value_nick = "end" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_seek_type_once: gtype.Once = .{};
fn gst_seek_type_register() c.GType {
    return c.g_enum_register_static("GstSeekType", &gst_seek_type_values);
}
pub export fn gst_seek_type_get_type() c.GType {
    return gst_seek_type_once.get(gst_seek_type_register);
}

var gst_seek_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_SEEK_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_SEEK_FLAG_FLUSH", .value_nick = "flush" },
    .{ .value = 2, .value_name = "GST_SEEK_FLAG_ACCURATE", .value_nick = "accurate" },
    .{ .value = 4, .value_name = "GST_SEEK_FLAG_KEY_UNIT", .value_nick = "key-unit" },
    .{ .value = 8, .value_name = "GST_SEEK_FLAG_SEGMENT", .value_nick = "segment" },
    .{ .value = 16, .value_name = "GST_SEEK_FLAG_TRICKMODE", .value_nick = "trickmode" },
    .{ .value = 16, .value_name = "GST_SEEK_FLAG_SKIP", .value_nick = "skip" },
    .{ .value = 32, .value_name = "GST_SEEK_FLAG_SNAP_BEFORE", .value_nick = "snap-before" },
    .{ .value = 64, .value_name = "GST_SEEK_FLAG_SNAP_AFTER", .value_nick = "snap-after" },
    .{ .value = 96, .value_name = "GST_SEEK_FLAG_SNAP_NEAREST", .value_nick = "snap-nearest" },
    .{ .value = 128, .value_name = "GST_SEEK_FLAG_TRICKMODE_KEY_UNITS", .value_nick = "trickmode-key-units" },
    .{ .value = 256, .value_name = "GST_SEEK_FLAG_TRICKMODE_NO_AUDIO", .value_nick = "trickmode-no-audio" },
    .{ .value = 512, .value_name = "GST_SEEK_FLAG_TRICKMODE_FORWARD_PREDICTED", .value_nick = "trickmode-forward-predicted" },
    .{ .value = 1024, .value_name = "GST_SEEK_FLAG_INSTANT_RATE_CHANGE", .value_nick = "instant-rate-change" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_seek_flags_once: gtype.Once = .{};
fn gst_seek_flags_register() c.GType {
    return c.g_flags_register_static("GstSeekFlags", &gst_seek_flags_values);
}
pub export fn gst_seek_flags_get_type() c.GType {
    return gst_seek_flags_once.get(gst_seek_flags_register);
}

var gst_segment_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_SEGMENT_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_SEGMENT_FLAG_RESET", .value_nick = "reset" },
    .{ .value = 16, .value_name = "GST_SEGMENT_FLAG_TRICKMODE", .value_nick = "trickmode" },
    .{ .value = 16, .value_name = "GST_SEGMENT_FLAG_SKIP", .value_nick = "skip" },
    .{ .value = 8, .value_name = "GST_SEGMENT_FLAG_SEGMENT", .value_nick = "segment" },
    .{ .value = 128, .value_name = "GST_SEGMENT_FLAG_TRICKMODE_KEY_UNITS", .value_nick = "trickmode-key-units" },
    .{ .value = 512, .value_name = "GST_SEGMENT_FLAG_TRICKMODE_FORWARD_PREDICTED", .value_nick = "trickmode-forward-predicted" },
    .{ .value = 256, .value_name = "GST_SEGMENT_FLAG_TRICKMODE_NO_AUDIO", .value_nick = "trickmode-no-audio" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_segment_flags_once: gtype.Once = .{};
fn gst_segment_flags_register() c.GType {
    return c.g_flags_register_static("GstSegmentFlags", &gst_segment_flags_values);
}
pub export fn gst_segment_flags_get_type() c.GType {
    return gst_segment_flags_once.get(gst_segment_flags_register);
}

var gst_stream_type_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_STREAM_TYPE_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 2, .value_name = "GST_STREAM_TYPE_AUDIO", .value_nick = "audio" },
    .{ .value = 4, .value_name = "GST_STREAM_TYPE_VIDEO", .value_nick = "video" },
    .{ .value = 8, .value_name = "GST_STREAM_TYPE_CONTAINER", .value_nick = "container" },
    .{ .value = 16, .value_name = "GST_STREAM_TYPE_TEXT", .value_nick = "text" },
    .{ .value = 32, .value_name = "GST_STREAM_TYPE_METADATA", .value_nick = "metadata" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_stream_type_once: gtype.Once = .{};
fn gst_stream_type_register() c.GType {
    return c.g_flags_register_static("GstStreamType", &gst_stream_type_values);
}
pub export fn gst_stream_type_get_type() c.GType {
    return gst_stream_type_once.get(gst_stream_type_register);
}

var gst_serialize_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_SERIALIZE_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_SERIALIZE_FLAG_BACKWARD_COMPAT", .value_nick = "backward-compat" },
    .{ .value = 2, .value_name = "GST_SERIALIZE_FLAG_STRICT", .value_nick = "strict" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_serialize_flags_once: gtype.Once = .{};
fn gst_serialize_flags_register() c.GType {
    return c.g_flags_register_static("GstSerializeFlags", &gst_serialize_flags_values);
}
pub export fn gst_serialize_flags_get_type() c.GType {
    return gst_serialize_flags_once.get(gst_serialize_flags_register);
}

var gst_clock_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_CLOCK_TYPE_REALTIME", .value_nick = "realtime" },
    .{ .value = 1, .value_name = "GST_CLOCK_TYPE_MONOTONIC", .value_nick = "monotonic" },
    .{ .value = 2, .value_name = "GST_CLOCK_TYPE_OTHER", .value_nick = "other" },
    .{ .value = 3, .value_name = "GST_CLOCK_TYPE_TAI", .value_nick = "tai" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_clock_type_once: gtype.Once = .{};
fn gst_clock_type_register() c.GType {
    return c.g_enum_register_static("GstClockType", &gst_clock_type_values);
}
pub export fn gst_clock_type_get_type() c.GType {
    return gst_clock_type_once.get(gst_clock_type_register);
}

var gst_tag_merge_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_TAG_MERGE_UNDEFINED", .value_nick = "undefined" },
    .{ .value = 1, .value_name = "GST_TAG_MERGE_REPLACE_ALL", .value_nick = "replace-all" },
    .{ .value = 2, .value_name = "GST_TAG_MERGE_REPLACE", .value_nick = "replace" },
    .{ .value = 3, .value_name = "GST_TAG_MERGE_APPEND", .value_nick = "append" },
    .{ .value = 4, .value_name = "GST_TAG_MERGE_PREPEND", .value_nick = "prepend" },
    .{ .value = 5, .value_name = "GST_TAG_MERGE_KEEP", .value_nick = "keep" },
    .{ .value = 6, .value_name = "GST_TAG_MERGE_KEEP_ALL", .value_nick = "keep-all" },
    .{ .value = 7, .value_name = "GST_TAG_MERGE_COUNT", .value_nick = "count" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_tag_merge_mode_once: gtype.Once = .{};
fn gst_tag_merge_mode_register() c.GType {
    return c.g_enum_register_static("GstTagMergeMode", &gst_tag_merge_mode_values);
}
pub export fn gst_tag_merge_mode_get_type() c.GType {
    return gst_tag_merge_mode_once.get(gst_tag_merge_mode_register);
}

var gst_tag_flag_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_TAG_FLAG_UNDEFINED", .value_nick = "undefined" },
    .{ .value = 1, .value_name = "GST_TAG_FLAG_META", .value_nick = "meta" },
    .{ .value = 2, .value_name = "GST_TAG_FLAG_ENCODED", .value_nick = "encoded" },
    .{ .value = 3, .value_name = "GST_TAG_FLAG_DECODED", .value_nick = "decoded" },
    .{ .value = 4, .value_name = "GST_TAG_FLAG_COUNT", .value_nick = "count" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_tag_flag_once: gtype.Once = .{};
fn gst_tag_flag_register() c.GType {
    return c.g_enum_register_static("GstTagFlag", &gst_tag_flag_values);
}
pub export fn gst_tag_flag_get_type() c.GType {
    return gst_tag_flag_once.get(gst_tag_flag_register);
}

var gst_tag_scope_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_TAG_SCOPE_STREAM", .value_nick = "stream" },
    .{ .value = 1, .value_name = "GST_TAG_SCOPE_GLOBAL", .value_nick = "global" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_tag_scope_once: gtype.Once = .{};
fn gst_tag_scope_register() c.GType {
    return c.g_enum_register_static("GstTagScope", &gst_tag_scope_values);
}
pub export fn gst_tag_scope_get_type() c.GType {
    return gst_tag_scope_once.get(gst_tag_scope_register);
}

var gst_task_state_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_TASK_STARTED", .value_nick = "started" },
    .{ .value = 1, .value_name = "GST_TASK_STOPPED", .value_nick = "stopped" },
    .{ .value = 2, .value_name = "GST_TASK_PAUSED", .value_nick = "paused" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_task_state_once: gtype.Once = .{};
fn gst_task_state_register() c.GType {
    return c.g_enum_register_static("GstTaskState", &gst_task_state_values);
}
pub export fn gst_task_state_get_type() c.GType {
    return gst_task_state_once.get(gst_task_state_register);
}

var gst_toc_scope_values = [_]c.GEnumValue{
    .{ .value = 1, .value_name = "GST_TOC_SCOPE_GLOBAL", .value_nick = "global" },
    .{ .value = 2, .value_name = "GST_TOC_SCOPE_CURRENT", .value_nick = "current" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_toc_scope_once: gtype.Once = .{};
fn gst_toc_scope_register() c.GType {
    return c.g_enum_register_static("GstTocScope", &gst_toc_scope_values);
}
pub export fn gst_toc_scope_get_type() c.GType {
    return gst_toc_scope_once.get(gst_toc_scope_register);
}

var gst_toc_entry_type_values = [_]c.GEnumValue{
    .{ .value = -3, .value_name = "GST_TOC_ENTRY_TYPE_ANGLE", .value_nick = "angle" },
    .{ .value = -2, .value_name = "GST_TOC_ENTRY_TYPE_VERSION", .value_nick = "version" },
    .{ .value = -1, .value_name = "GST_TOC_ENTRY_TYPE_EDITION", .value_nick = "edition" },
    .{ .value = 0, .value_name = "GST_TOC_ENTRY_TYPE_INVALID", .value_nick = "invalid" },
    .{ .value = 1, .value_name = "GST_TOC_ENTRY_TYPE_TITLE", .value_nick = "title" },
    .{ .value = 2, .value_name = "GST_TOC_ENTRY_TYPE_TRACK", .value_nick = "track" },
    .{ .value = 3, .value_name = "GST_TOC_ENTRY_TYPE_CHAPTER", .value_nick = "chapter" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_toc_entry_type_once: gtype.Once = .{};
fn gst_toc_entry_type_register() c.GType {
    return c.g_enum_register_static("GstTocEntryType", &gst_toc_entry_type_values);
}
pub export fn gst_toc_entry_type_get_type() c.GType {
    return gst_toc_entry_type_once.get(gst_toc_entry_type_register);
}

var gst_toc_loop_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_TOC_LOOP_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_TOC_LOOP_FORWARD", .value_nick = "forward" },
    .{ .value = 2, .value_name = "GST_TOC_LOOP_REVERSE", .value_nick = "reverse" },
    .{ .value = 3, .value_name = "GST_TOC_LOOP_PING_PONG", .value_nick = "ping-pong" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_toc_loop_type_once: gtype.Once = .{};
fn gst_toc_loop_type_register() c.GType {
    return c.g_enum_register_static("GstTocLoopType", &gst_toc_loop_type_values);
}
pub export fn gst_toc_loop_type_get_type() c.GType {
    return gst_toc_loop_type_once.get(gst_toc_loop_type_register);
}

var gst_tracer_value_scope_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_TRACER_VALUE_SCOPE_PROCESS", .value_nick = "process" },
    .{ .value = 1, .value_name = "GST_TRACER_VALUE_SCOPE_THREAD", .value_nick = "thread" },
    .{ .value = 2, .value_name = "GST_TRACER_VALUE_SCOPE_ELEMENT", .value_nick = "element" },
    .{ .value = 3, .value_name = "GST_TRACER_VALUE_SCOPE_PAD", .value_nick = "pad" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_tracer_value_scope_once: gtype.Once = .{};
fn gst_tracer_value_scope_register() c.GType {
    return c.g_enum_register_static("GstTracerValueScope", &gst_tracer_value_scope_values);
}
pub export fn gst_tracer_value_scope_get_type() c.GType {
    return gst_tracer_value_scope_once.get(gst_tracer_value_scope_register);
}

var gst_tracer_value_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_TRACER_VALUE_FLAGS_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_TRACER_VALUE_FLAGS_OPTIONAL", .value_nick = "optional" },
    .{ .value = 2, .value_name = "GST_TRACER_VALUE_FLAGS_AGGREGATED", .value_nick = "aggregated" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_tracer_value_flags_once: gtype.Once = .{};
fn gst_tracer_value_flags_register() c.GType {
    return c.g_flags_register_static("GstTracerValueFlags", &gst_tracer_value_flags_values);
}
pub export fn gst_tracer_value_flags_get_type() c.GType {
    return gst_tracer_value_flags_once.get(gst_tracer_value_flags_register);
}

var gst_type_find_probability_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_TYPE_FIND_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_TYPE_FIND_MINIMUM", .value_nick = "minimum" },
    .{ .value = 50, .value_name = "GST_TYPE_FIND_POSSIBLE", .value_nick = "possible" },
    .{ .value = 80, .value_name = "GST_TYPE_FIND_LIKELY", .value_nick = "likely" },
    .{ .value = 99, .value_name = "GST_TYPE_FIND_NEARLY_CERTAIN", .value_nick = "nearly-certain" },
    .{ .value = 100, .value_name = "GST_TYPE_FIND_MAXIMUM", .value_nick = "maximum" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_type_find_probability_once: gtype.Once = .{};
fn gst_type_find_probability_register() c.GType {
    return c.g_enum_register_static("GstTypeFindProbability", &gst_type_find_probability_values);
}
pub export fn gst_type_find_probability_get_type() c.GType {
    return gst_type_find_probability_once.get(gst_type_find_probability_register);
}

var gst_uri_error_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_URI_ERROR_UNSUPPORTED_PROTOCOL", .value_nick = "unsupported-protocol" },
    .{ .value = 1, .value_name = "GST_URI_ERROR_BAD_URI", .value_nick = "bad-uri" },
    .{ .value = 2, .value_name = "GST_URI_ERROR_BAD_STATE", .value_nick = "bad-state" },
    .{ .value = 3, .value_name = "GST_URI_ERROR_BAD_REFERENCE", .value_nick = "bad-reference" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_uri_error_once: gtype.Once = .{};
fn gst_uri_error_register() c.GType {
    return c.g_enum_register_static("GstURIError", &gst_uri_error_values);
}
pub export fn gst_uri_error_get_type() c.GType {
    return gst_uri_error_once.get(gst_uri_error_register);
}

var gst_uri_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_URI_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_URI_SINK", .value_nick = "sink" },
    .{ .value = 2, .value_name = "GST_URI_SRC", .value_nick = "src" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_uri_type_once: gtype.Once = .{};
fn gst_uri_type_register() c.GType {
    return c.g_enum_register_static("GstURIType", &gst_uri_type_values);
}
pub export fn gst_uri_type_get_type() c.GType {
    return gst_uri_type_once.get(gst_uri_type_register);
}

var gst_search_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_SEARCH_MODE_EXACT", .value_nick = "exact" },
    .{ .value = 1, .value_name = "GST_SEARCH_MODE_BEFORE", .value_nick = "before" },
    .{ .value = 2, .value_name = "GST_SEARCH_MODE_AFTER", .value_nick = "after" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_search_mode_once: gtype.Once = .{};
fn gst_search_mode_register() c.GType {
    return c.g_enum_register_static("GstSearchMode", &gst_search_mode_values);
}
pub export fn gst_search_mode_get_type() c.GType {
    return gst_search_mode_once.get(gst_search_mode_register);
}

var gst_plugin_api_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_PLUGIN_API_FLAG_IGNORE_ENUM_MEMBERS", .value_nick = "members" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_plugin_api_flags_once: gtype.Once = .{};
fn gst_plugin_api_flags_register() c.GType {
    return c.g_flags_register_static("GstPluginAPIFlags", &gst_plugin_api_flags_values);
}
pub export fn gst_plugin_api_flags_get_type() c.GType {
    return gst_plugin_api_flags_once.get(gst_plugin_api_flags_register);
}
