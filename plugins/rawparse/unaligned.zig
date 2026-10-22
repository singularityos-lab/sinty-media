const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

pub fn Bin(comptime name: [:0]const u8, comptime type_name: [:0]const u8, comptime inner: [:0]const u8, comptime sink_caps: [:0]const u8, comptime src_caps: [:0]const u8, comptime klass: [:0]const u8, comptime desc: [:0]const u8, comptime debug: [:0]const u8) type {
    return struct {
        const Self = extern struct {
            parent: c.GstBin,
            inner_parser: ?*c.GstElement,
        };

        const Class = extern struct {
            parent: c.GstBinClass,
        };

        var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, sink_caps);
        var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, src_caps);
        var once: cm.Once = .{};

        fn ghost(s: *Self, pad: [*c]const u8) void {
            const ipad = c.gst_element_get_static_pad(s.inner_parser, pad);
            const g = c.gst_ghost_pad_new_from_template(pad, ipad, c.gst_element_class_get_pad_template(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(s)).g_class)), pad));
            _ = c.gst_element_add_pad(@ptrCast(s), g);
            c.gst_object_unref(ipad);
        }

        fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
            _ = c._gst_debug_category_new(name, 0, debug);
            const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
            c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&sink_t));
            c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&src_t));
            c.gst_element_class_set_static_metadata(ec, name, klass, desc, "Carlos Rafael Giani <dv@pseudoterminal.org>");
        }

        fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
            const s: *Self = @ptrCast(@alignCast(inst));
            s.inner_parser = c.gst_element_factory_make(inner, "inner_parser");
            c.g_object_set(s.inner_parser, "use-sink-caps", @as(c.gboolean, 1), @as(?*anyopaque, null));
            _ = c.gst_bin_add(@ptrCast(s), s.inner_parser);
            ghost(s, "sink");
            ghost(s, "src");
        }

        pub fn getType() c.GType {
            return once.get(struct {
                fn f() c.GType {
                    return cm.register(c.gst_bin_get_type(), type_name, Class, Self, classInit, init);
                }
            }.f);
        }

        pub fn register(p: ?*c.GstPlugin) bool {
            return c.gst_element_register(p, name, c.GST_RANK_MARGINAL, getType()) != 0;
        }
    };
}
