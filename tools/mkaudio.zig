const std = @import("std");
const c = @import("c").c;

const Job = struct { name: []const u8, pipe: []const u8 };

const jobs = [_]Job{
    .{ .name = "tone.flac", .pipe = "audiotestsrc num-buffers=40 samplesperbuffer=1024 freq=440 ! audio/x-raw,format=S16LE,rate=44100,channels=2 ! flacenc ! filesink location=" },
    .{ .name = "tone.opus.ogg", .pipe = "audiotestsrc num-buffers=40 samplesperbuffer=960 freq=330 ! audio/x-raw,rate=48000,channels=2 ! opusenc ! oggmux ! filesink location=" },
    .{ .name = "tone.mp3", .pipe = "audiotestsrc num-buffers=40 samplesperbuffer=1152 freq=550 ! audio/x-raw,rate=44100,channels=2 ! lamemp3enc ! filesink location=" },
    .{ .name = "tone.alaw", .pipe = "audiotestsrc num-buffers=20 samplesperbuffer=800 freq=700 ! audio/x-raw,format=S16LE,rate=8000,channels=1 ! alawenc ! filesink location=" },
};

pub fn main() !void {
    c.gst_init(null, null);
    for (jobs) |j| {
        var buf: [1024]u8 = undefined;
        const desc = try std.fmt.bufPrintZ(&buf, "{s}tests/data/{s}", .{ j.pipe, j.name });
        var err: [*c]c.GError = null;
        const pipe = c.gst_parse_launch(desc.ptr, &err);
        if (pipe == null) {
            std.debug.print("{s}: {s}\n", .{ j.name, err.*.message });
            continue;
        }
        _ = c.gst_element_set_state(pipe, c.GST_STATE_PLAYING);
        const bus = c.gst_element_get_bus(pipe);
        const msg = c.gst_bus_timed_pop_filtered(bus, 20 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
        std.debug.print("{s}: {s}\n", .{ j.name, if (msg != null and msg.*.type == c.GST_MESSAGE_EOS) "ok" else "failed" });
        if (msg != null) c.gst_message_unref(msg);
        c.gst_object_unref(bus);
        _ = c.gst_element_set_state(pipe, c.GST_STATE_NULL);
        c.gst_object_unref(pipe);
    }
}
