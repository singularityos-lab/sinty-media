const std = @import("std");
const c = @import("../c.zig").c;
const libm = @import("../libm.zig");
const kiss = @import("kiss.zig");

const DOMAIN = "GStreamer-FFT";

fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as([*c]const u8, func ++ ""), @as([*c]const u8, expr ++ ""));
    return ok;
}

fn Api(comptime T: type, comptime tag: []const u8, comptime assert_line: c_int) type {
    const K = kiss.Fft(T);
    return struct {
        const Self = struct {
            st: K.State,
            inverse: c.gboolean,
            len: c.gint,
        };

        fn new(len: c.gint, inverse: c.gboolean) callconv(.c) ?*anyopaque {
            if (!that(len > 0, "gst_fft_" ++ tag ++ "_new", "len > 0")) return null;
            if (!that(@rem(len, 2) == 0, "gst_fft_" ++ tag ++ "_new", "len % 2 == 0")) return null;
            const s: *Self = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Self))));
            K.init(&s.st, @intCast(len), inverse != 0);
            s.inverse = inverse;
            s.len = len;
            return s;
        }

        fn fft(self: ?*anyopaque, time: [*c]const T, freq: [*c]K.Cpx) callconv(.c) void {
            const fname = "gst_fft_" ++ tag ++ "_fft";
            if (!that(self != null, fname, "self")) return;
            const s: *Self = @ptrCast(@alignCast(self));
            if (!that(s.inverse == 0, fname, "!self->inverse")) return;
            if (!that(time != null, fname, "timedata")) return;
            if (!that(freq != null, fname, "freqdata")) return;
            K.forward(&s.st, time, freq);
        }

        fn inverseFft(self: ?*anyopaque, freq: [*c]const K.Cpx, time: [*c]T) callconv(.c) void {
            const fname = "gst_fft_" ++ tag ++ "_inverse_fft";
            if (!that(self != null, fname, "self")) return;
            const s: *Self = @ptrCast(@alignCast(self));
            if (!that(s.inverse != 0, fname, "self->inverse")) return;
            if (!that(time != null, fname, "timedata")) return;
            if (!that(freq != null, fname, "freqdata")) return;
            K.inverseFft(&s.st, freq, time);
        }

        fn free(self: ?*anyopaque) callconv(.c) void {
            if (self == null) return;
            const s: *Self = @ptrCast(@alignCast(self));
            K.deinit(&s.st);
            c.g_free(s);
        }

        fn scale(x: T, k: f64) T {
            if (@typeInfo(T) == .int) return @intFromFloat(@as(f64, @floatFromInt(x)) * k);
            return @floatCast(@as(f64, x) * k);
        }

        fn window(self: ?*anyopaque, time: [*c]T, kind: c.GstFFTWindow) callconv(.c) void {
            const fname = "gst_fft_" ++ tag ++ "_window";
            if (!that(self != null, fname, "self")) return;
            if (!that(time != null, fname, "timedata")) return;
            const s: *Self = @ptrCast(@alignCast(self));
            const len = s.len;
            const lf: f64 = @floatFromInt(len);
            var i: c.gint = 0;
            switch (kind) {
                c.GST_FFT_WINDOW_RECTANGULAR => {},
                c.GST_FFT_WINDOW_HAMMING => while (i < len) : (i += 1) {
                    time[@intCast(i)] = scale(time[@intCast(i)], 0.53836 - 0.46164 * libm.cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / lf));
                },
                c.GST_FFT_WINDOW_HANN => while (i < len) : (i += 1) {
                    time[@intCast(i)] = scale(time[@intCast(i)], 0.5 - 0.5 * libm.cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / lf));
                },
                c.GST_FFT_WINDOW_BARTLETT => while (i < len) : (i += 1) {
                    time[@intCast(i)] = scale(time[@intCast(i)], 1.0 - c.fabs((2.0 * @as(f64, @floatFromInt(i)) - lf) / lf));
                },
                c.GST_FFT_WINDOW_BLACKMAN => while (i < len) : (i += 1) {
                    const fi: f64 = @floatFromInt(i);
                    time[@intCast(i)] = scale(time[@intCast(i)], 0.42 - 0.5 * libm.cos((2.0 * fi) / lf) + 0.08 * libm.cos((4.0 * fi) / lf));
                },
                else => c.g_assertion_message_expr(DOMAIN, "../gst-libs/gst/fft/gstfft" ++ tag ++ ".c", assert_line, "gst_fft_" ++ tag ++ "_window", null),
            }
        }

        comptime {
            @export(&new, .{ .name = "gst_fft_" ++ tag ++ "_new" });
            @export(&fft, .{ .name = "gst_fft_" ++ tag ++ "_fft" });
            @export(&inverseFft, .{ .name = "gst_fft_" ++ tag ++ "_inverse_fft" });
            @export(&free, .{ .name = "gst_fft_" ++ tag ++ "_free" });
            @export(&window, .{ .name = "gst_fft_" ++ tag ++ "_window" });
        }
    };
}

comptime {
    _ = Api(i16, "s16", 217);
    _ = Api(i32, "s32", 216);
    _ = Api(f32, "f32", 217);
    _ = Api(f64, "f64", 217);
}

pub export fn gst_fft_next_fast_length(n: c.gint) c.gint {
    return 2 * kiss.nextFastSize(@divTrunc(n + 1, 2));
}
