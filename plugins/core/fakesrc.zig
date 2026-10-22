const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstfakesrc.c";

const PROP_OUTPUT = 1;
const PROP_DATA = 2;
const PROP_SIZETYPE = 3;
const PROP_SIZEMIN = 4;
const PROP_SIZEMAX = 5;
const PROP_FILLTYPE = 6;
const PROP_DATARATE = 7;
const PROP_SYNC = 8;
const PROP_PATTERN = 9;
const PROP_EOS = 10;
const PROP_SIGNAL_HANDOFFS = 11;
const PROP_SILENT = 12;
const PROP_DUMP = 13;
const PROP_PARENTSIZE = 14;
const PROP_LAST_MESSAGE = 15;
const PROP_CAN_ACTIVATE_PULL = 16;
const PROP_CAN_ACTIVATE_PUSH = 17;
const PROP_IS_LIVE = 18;
const PROP_FORMAT = 19;

const DATA_ALLOCATE = 1;
const DATA_SUBBUFFER = 2;
const SIZE_EMPTY = 1;
const SIZE_FIXED = 2;
const SIZE_RANDOM = 3;
const FILL_NOTHING = 1;
const FILL_ZERO = 2;
const FILL_RANDOM = 3;
const FILL_PATTERN = 4;
const FILL_PATTERN_CONT = 5;
const OUTPUT_FIRST_LAST_LOOP = 1;

const Handoff = ?*const fn ([*c]c.GstElement, [*c]c.GstBuffer, ?*c.GstPad) callconv(.c) void;

const Self = extern struct {
    parent_obj: c.GstBaseSrc,
    has_loop: c.gboolean,
    has_getrange: c.gboolean,
    output: c.gint,
    data: c.gint,
    sizetype: c.gint,
    filltype: c.gint,
    sizemin: c.guint,
    sizemax: c.guint,
    parent: [*c]c.GstBuffer,
    parentsize: c.guint,
    parentoffset: c.guint,
    pattern_byte: u8,
    datarate: c.gint,
    sync: c.gboolean,
    clock: [*c]c.GstClock,
    num_buffers: c.gint,
    rt_num_buffers: c.gint,
    buffer_count: c.guint64,
    silent: c.gboolean,
    signal_handoffs: c.gboolean,
    dump: c.gboolean,
    can_activate_pull: c.gboolean,
    format: c.GstFormat,
    bytes_sent: c.guint64,
    last_message: [*c]u8,
};

const Class = extern struct {
    parent: c.GstBaseSrcClass,
    handoff: Handoff,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");

var once: cm.Once = .{};
var data_once: cm.Once = .{};
var size_once: cm.Once = .{};
var fill_once: cm.Once = .{};
var parent_class: ?*c.GstBaseSrcClass = null;
var sig_handoff: c.guint = 0;
var pspec_last: [*c]c.GParamSpec = null;

var data_values = [_]c.GEnumValue{
    .{ .value = DATA_ALLOCATE, .value_name = "Allocate data", .value_nick = "allocate" },
    .{ .value = DATA_SUBBUFFER, .value_name = "Subbuffer data", .value_nick = "subbuffer" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

var size_values = [_]c.GEnumValue{
    .{ .value = SIZE_EMPTY, .value_name = "Send empty buffers", .value_nick = "empty" },
    .{ .value = SIZE_FIXED, .value_name = "Fixed size buffers (sizemax sized)", .value_nick = "fixed" },
    .{ .value = SIZE_RANDOM, .value_name = "Random sized buffers (sizemin <= size <= sizemax)", .value_nick = "random" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

var fill_values = [_]c.GEnumValue{
    .{ .value = FILL_NOTHING, .value_name = "Leave data as malloced", .value_nick = "nothing" },
    .{ .value = FILL_ZERO, .value_name = "Fill buffers with zeros", .value_nick = "zero" },
    .{ .value = FILL_RANDOM, .value_name = "Fill buffers with random data", .value_nick = "random" },
    .{ .value = FILL_PATTERN, .value_name = "Fill buffers with pattern 0x00 -> 0xff", .value_nick = "pattern" },
    .{ .value = FILL_PATTERN_CONT, .value_name = "Fill buffers with pattern 0x00 -> 0xff that spans buffers", .value_nick = "pattern-span" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn enumType(o: *cm.Once, comptime name: [:0]const u8, comptime values: anytype) c.GType {
    return o.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static(name, values);
        }
    }.f);
}

fn dataType() c.GType {
    return enumType(&data_once, "GstFakeSrcDataType", &data_values);
}

fn sizeType() c.GType {
    return enumType(&size_once, "GstFakeSrcSizeType", &size_values);
}

fn fillType() c.GType {
    return enumType(&fill_once, "GstFakeSrcFillType", &fill_values);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn bsrc(p: anytype) [*c]c.GstBaseSrc {
    return @ptrCast(@alignCast(p));
}

fn notifyLast(s: *Self) void {
    c.g_object_notify_by_pspec(@ptrCast(@alignCast(s)), pspec_last);
}

fn allocParent(s: *Self) void {
    s.parent = c.gst_buffer_new_allocate(null, s.parentsize, null);
    s.parentoffset = 0;
}

fn dropParent(s: *Self) void {
    if (s.parent != null) {
        c.gst_buffer_unref(s.parent);
        s.parent = null;
    }
}

fn started(o: anytype) bool {
    return cm.obj(o).flags & c.GST_BASE_SRC_FLAG_STARTED != 0;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_OUTPUT => c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "not yet implemented"),
        PROP_DATA => {
            s.data = c.g_value_get_enum(v);
            if (s.data == DATA_SUBBUFFER) {
                if (s.parent == null) allocParent(s);
            } else dropParent(s);
        },
        PROP_SIZETYPE => s.sizetype = c.g_value_get_enum(v),
        PROP_SIZEMIN => s.sizemin = @bitCast(c.g_value_get_int(v)),
        PROP_SIZEMAX => s.sizemax = @bitCast(c.g_value_get_int(v)),
        PROP_PARENTSIZE => s.parentsize = @bitCast(c.g_value_get_int(v)),
        PROP_FILLTYPE => s.filltype = c.g_value_get_enum(v),
        PROP_DATARATE => s.datarate = c.g_value_get_int(v),
        PROP_SYNC => s.sync = c.g_value_get_boolean(v),
        PROP_PATTERN => {},
        PROP_SILENT => s.silent = c.g_value_get_boolean(v),
        PROP_SIGNAL_HANDOFFS => s.signal_handoffs = c.g_value_get_boolean(v),
        PROP_DUMP => s.dump = c.g_value_get_boolean(v),
        PROP_CAN_ACTIVATE_PUSH => {
            if (!cm.that(!started(o), "gst_fake_src_set_property", "!GST_OBJECT_FLAG_IS_SET (object, GST_BASE_SRC_FLAG_STARTED)")) return;
            s.parent_obj.can_activate_push = c.g_value_get_boolean(v);
        },
        PROP_CAN_ACTIVATE_PULL => {
            if (!cm.that(!started(o), "gst_fake_src_set_property", "!GST_OBJECT_FLAG_IS_SET (object, GST_BASE_SRC_FLAG_STARTED)")) return;
            s.can_activate_pull = c.g_value_get_boolean(v);
        },
        PROP_IS_LIVE => c.gst_base_src_set_live(bsrc(s), c.g_value_get_boolean(v)),
        PROP_FORMAT => s.format = @bitCast(c.g_value_get_enum(v)),
        else => cm.warnInvalid(FILE, o, id, spec, 519),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_OUTPUT => c.g_value_set_enum(v, s.output),
        PROP_DATA => c.g_value_set_enum(v, s.data),
        PROP_SIZETYPE => c.g_value_set_enum(v, s.sizetype),
        PROP_SIZEMIN => c.g_value_set_int(v, @bitCast(s.sizemin)),
        PROP_SIZEMAX => c.g_value_set_int(v, @bitCast(s.sizemax)),
        PROP_PARENTSIZE => c.g_value_set_int(v, @bitCast(s.parentsize)),
        PROP_FILLTYPE => c.g_value_set_enum(v, s.filltype),
        PROP_DATARATE => c.g_value_set_int(v, s.datarate),
        PROP_SYNC => c.g_value_set_boolean(v, s.sync),
        PROP_PATTERN => {},
        PROP_SILENT => c.g_value_set_boolean(v, s.silent),
        PROP_SIGNAL_HANDOFFS => c.g_value_set_boolean(v, s.signal_handoffs),
        PROP_DUMP => c.g_value_set_boolean(v, s.dump),
        PROP_LAST_MESSAGE => {
            cm.lock(s);
            c.g_value_set_string(v, s.last_message);
            cm.unlock(s);
        },
        PROP_CAN_ACTIVATE_PUSH => c.g_value_set_boolean(v, s.parent_obj.can_activate_push),
        PROP_CAN_ACTIVATE_PULL => c.g_value_set_boolean(v, s.can_activate_pull),
        PROP_IS_LIVE => c.g_value_set_boolean(v, c.gst_base_src_is_live(bsrc(s))),
        PROP_FORMAT => c.g_value_set_enum(v, @bitCast(s.format)),
        else => cm.warnInvalid(FILE, o, id, spec, 593),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_free(s.last_message);
    dropParent(s);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).finalize.?(o);
}

fn event(b: [*c]c.GstBaseSrc, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(b);
    if (s.silent == 0) {
        const pad = b[0].srcpad;
        cm.lock(s);
        c.g_free(s.last_message);
        const st = c.gst_event_get_structure(ev);
        const sstr = if (st != null) c.gst_structure_to_string(st) else c.g_strdup("");
        s.last_message = c.g_strdup_printf("event   ******* (%s:%s) E (type: %s (%d), %s) %p", cm.padParentName(pad), cm.padName(pad), c.gst_event_type_get_name(cm.eventType(ev)), cm.eventType(ev), sstr, ev);
        c.g_free(sstr);
        cm.unlock(s);
        notifyLast(s);
    }
    return parent_class.?.event.?(b, ev);
}

fn prepare(s: *Self, data: [*]u8, size: usize) void {
    if (size == 0) return;
    switch (s.filltype) {
        FILL_ZERO => @memset(data[0..size], 0),
        FILL_RANDOM => for (data[0..size]) |*p| {
            p.* = @truncate(@as(c.guint32, @bitCast(c.g_random_int_range(0, 256))));
        },
        FILL_PATTERN, FILL_PATTERN_CONT => {
            if (s.filltype == FILL_PATTERN) s.pattern_byte = 0;
            for (data[0..size]) |*p| {
                p.* = s.pattern_byte;
                s.pattern_byte +%= 1;
            }
        },
        else => {},
    }
}

fn allocBuffer(s: *Self, size: c.guint) [*c]c.GstBuffer {
    const b = c.gst_buffer_new();
    if (size != 0) {
        const data: [*]u8 = @ptrCast(if (s.filltype == FILL_ZERO) c.g_malloc0(size) else c.g_malloc(size));
        if (s.filltype != FILL_NOTHING and s.filltype != FILL_ZERO) prepare(s, data, size);
        c.gst_buffer_append_memory(b, c.gst_memory_new_wrapped(0, data, size, 0, size, data, c.g_free));
    }
    return b;
}

fn getSize(s: *Self) c.guint {
    return switch (s.sizetype) {
        SIZE_FIXED => s.sizemax,
        SIZE_RANDOM => @bitCast(c.g_random_int_range(@bitCast(s.sizemin), @bitCast(s.sizemax))),
        else => 0,
    };
}

fn createBuffer(s: *Self, out_size: *usize) [*c]c.GstBuffer {
    const size = getSize(s);
    const dump = s.dump;
    out_size.* = size;
    var b: [*c]c.GstBuffer = undefined;
    switch (s.data) {
        DATA_ALLOCATE => b = allocBuffer(s, size),
        DATA_SUBBUFFER => {
            if (s.parent == null) allocParent(s);
            if (s.parentsize - s.parentoffset >= size) {
                b = c.gst_buffer_copy_region(s.parent, c.GST_BUFFER_COPY_ALL, s.parentoffset, size);
                s.parentoffset += size;
            } else {
                dropParent(s);
                return createBuffer(s, out_size);
            }
            if (b == null) {
                cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_BUSY, null, c.g_strdup("Failed to create a buffer"), FILE, "gst_fake_src_create_buffer", 749);
                return null;
            }
            var info: c.GstMapInfo = undefined;
            if (c.gst_buffer_map(b, &info, c.GST_MAP_WRITE) == 0) {
                cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, null, c.g_strdup("Failed to write to buffer"), FILE, "gst_fake_src_create_buffer", 756);
                c.gst_buffer_unref(b);
                return null;
            }
            prepare(s, info.data, info.size);
            c.gst_buffer_unmap(b, &info);
        },
        else => {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "fakesrc: dunno how to allocate buffers !");
            b = c.gst_buffer_new();
        },
    }
    if (dump != 0) {
        var info: c.GstMapInfo = undefined;
        if (c.gst_buffer_map(b, &info, c.GST_MAP_READ) != 0) {
            c.gst_util_dump_mem(info.data, @intCast(info.size));
            c.gst_buffer_unmap(b, &info);
        }
    }
    return b;
}

fn getTimes(b: [*c]c.GstBaseSrc, buffer: [*c]c.GstBuffer, st: [*c]c.GstClockTime, end: [*c]c.GstClockTime) callconv(.c) void {
    const s = me(b);
    if (s.sync != 0) {
        const bf = cm.buf(buffer);
        var ts = bf.dts;
        if (ts == cm.CLOCK_NONE) ts = bf.pts;
        if (ts != cm.CLOCK_NONE) {
            if (bf.duration != cm.CLOCK_NONE) end[0] = ts + bf.duration;
            st[0] = ts;
        }
    } else {
        st[0] = cm.CLOCK_NONE;
        end[0] = cm.CLOCK_NONE;
    }
}

fn create(b: [*c]c.GstBaseSrc, offset: c.guint64, _: c.guint, ret: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(b);
    var size: usize = 0;
    const buffer = createBuffer(s, &size);
    const bf = cm.buf(buffer);
    bf.offset = offset;
    var time: u64 = cm.CLOCK_NONE;
    if (s.datarate > 0) {
        time = c.gst_util_uint64_scale_int(s.bytes_sent, c.GST_SECOND, s.datarate);
        bf.duration = c.gst_util_uint64_scale_int(size, c.GST_SECOND, s.datarate);
    } else if (c.gst_base_src_is_live(b) != 0) {
        const clock = c.gst_element_get_clock(@ptrCast(@alignCast(s)));
        if (clock != null) {
            time = c.gst_clock_get_time(clock) -% c.gst_element_get_base_time(@ptrCast(@alignCast(s)));
            c.gst_object_unref(clock);
        }
    }
    bf.dts = time;
    bf.pts = time;
    if (s.silent == 0) {
        var dts: [64]u8 = undefined;
        var pts: [64]u8 = undefined;
        var dur: [64]u8 = undefined;
        const flags = cm.flagsString(buffer);
        const pad = b[0].srcpad;
        cm.lock(s);
        c.g_free(s.last_message);
        s.last_message = c.g_strdup_printf("create   ******* (%s:%s) (%u bytes, dts: %s, pts:%s, duration: %s, offset: %li, offset_end: %li, flags: %08x %s) %p", cm.padParentName(pad), cm.padName(pad), @as(c.guint, @truncate(size)), cm.timeStr(&dts, bf.dts), cm.timeStr(&pts, bf.pts), cm.timeStr(&dur, bf.duration), bf.offset, bf.offset_end, bf.mini_object.flags, flags, buffer);
        c.g_free(flags);
        cm.unlock(s);
        notifyLast(s);
    }
    if (s.signal_handoffs != 0) c.g_signal_emit(s, sig_handoff, 0, buffer, b[0].srcpad);
    s.bytes_sent += size;
    ret[0] = buffer;
    return c.GST_FLOW_OK;
}

fn start(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    s.pattern_byte = 0;
    s.bytes_sent = 0;
    c.gst_base_src_set_format(b, s.format);
    return 1;
}

fn stop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    cm.lock(s);
    dropParent(s);
    c.g_free(s.last_message);
    s.last_message = null;
    cm.unlock(s);
    return 1;
}

fn isSeekable(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return me(b).can_activate_pull;
}

fn intProp(oc: *c.GObjectClass, id: c.guint, name: [*c]const u8, nick: [*c]const u8, blurb: [*c]const u8, def: c.gint) void {
    c.g_object_class_install_property(oc, id, c.g_param_spec_int(name, nick, blurb, 0, std.math.maxInt(c.gint), def, cm.RW));
}

fn boolProp(oc: *c.GObjectClass, id: c.guint, name: [*c]const u8, nick: [*c]const u8, blurb: [*c]const u8, def: bool, flags: c.GParamFlags) void {
    c.g_object_class_install_property(oc, id, c.g_param_spec_boolean(name, nick, blurb, @intFromBool(def), flags));
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_DATA, c.g_param_spec_enum("data", "data", "Data allocation method", dataType(), DATA_ALLOCATE, cm.RW));
    c.g_object_class_install_property(oc, PROP_SIZETYPE, c.g_param_spec_enum("sizetype", "sizetype", "How to determine buffer sizes", sizeType(), SIZE_EMPTY, cm.RW));
    intProp(oc, PROP_SIZEMIN, "sizemin", "sizemin", "Minimum buffer size", 0);
    intProp(oc, PROP_SIZEMAX, "sizemax", "sizemax", "Maximum buffer size", 4096);
    intProp(oc, PROP_PARENTSIZE, "parentsize", "parentsize", "Size of parent buffer for sub-buffered allocation", 4096 * 10);
    c.g_object_class_install_property(oc, PROP_FILLTYPE, c.g_param_spec_enum("filltype", "filltype", "How to fill the buffer, if at all", fillType(), FILL_ZERO, cm.RW));
    intProp(oc, PROP_DATARATE, "datarate", "Datarate", "Timestamps buffers with number of bytes per second (0 = none)", 0);
    boolProp(oc, PROP_SYNC, "sync", "Sync", "Sync to the clock to the datarate", false, cm.RW);
    c.g_object_class_install_property(oc, PROP_PATTERN, c.g_param_spec_string("pattern", "pattern", "Set the pattern (unused)", null, cm.RW));
    pspec_last = c.g_param_spec_string("last-message", "last-message", "The last status message", null, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS);
    c.g_object_class_install_property(oc, PROP_LAST_MESSAGE, pspec_last);
    boolProp(oc, PROP_SILENT, "silent", "Silent", "Don't produce last_message events", true, cm.RW);
    boolProp(oc, PROP_SIGNAL_HANDOFFS, "signal-handoffs", "Signal handoffs", "Send a signal before pushing the buffer", false, cm.RW);
    boolProp(oc, PROP_DUMP, "dump", "Dump", "Dump buffer contents to stdout", false, cm.RW);
    boolProp(oc, PROP_CAN_ACTIVATE_PUSH, "can-activate-push", "Can activate push", "Can activate in push mode", true, cm.RW | c.G_PARAM_CONSTRUCT);
    boolProp(oc, PROP_CAN_ACTIVATE_PULL, "can-activate-pull", "Can activate pull", "Can activate in pull mode", true, cm.RW | c.G_PARAM_CONSTRUCT);
    boolProp(oc, PROP_IS_LIVE, "is-live", "Is this a live source", "True if the element cannot produce data in PAUSED", false, cm.RW | c.G_PARAM_CONSTRUCT);
    c.g_object_class_install_property(oc, PROP_FORMAT, c.g_param_spec_enum("format", "Format", "The format of the segment events", c.gst_format_get_type(), c.GST_FORMAT_BYTES, cm.RW));
    sig_handoff = c.g_signal_new("handoff", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "handoff"), null, null, null, c.G_TYPE_NONE, 2, c.gst_buffer_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE, c.gst_pad_get_type());
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Fake Source", "Source", "Push empty (no data) buffers around", "Erik Walthinsen <omega@cse.ogi.edu>, Wim Taymans <wim@fluendo.com>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.is_seekable = isSeekable;
    bc.start = start;
    bc.stop = stop;
    bc.event = event;
    bc.get_times = getTimes;
    bc.create = create;
    c.gst_type_mark_as_plugin_api(dataType(), 0);
    c.gst_type_mark_as_plugin_api(sizeType(), 0);
    c.gst_type_mark_as_plugin_api(fillType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.output = OUTPUT_FIRST_LAST_LOOP;
    s.silent = 1;
    s.signal_handoffs = 0;
    s.dump = 0;
    s.pattern_byte = 0;
    s.data = DATA_ALLOCATE;
    s.sizetype = SIZE_EMPTY;
    s.filltype = FILL_NOTHING;
    s.sizemin = 0;
    s.sizemax = 4096;
    s.parent = null;
    s.parentsize = 4096 * 10;
    s.last_message = null;
    s.datarate = 0;
    s.sync = 0;
    s.format = c.GST_FORMAT_BYTES;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_base_src_get_type(), "GstFakeSrc", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("fakesrc", 0, "fakesrc element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "fakesrc", c.GST_RANK_NONE, getType()) != 0;
}
