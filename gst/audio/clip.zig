const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const channels = @import("channels.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Buffer = c.GstBuffer;
const NONE: u64 = std.math.maxInt(u64);

fn isBuffer(b: [*c]Buffer) bool {
    return b != null and @as(*c.GstMiniObject, @ptrCast(b)).type == c.gst_buffer_get_type();
}

fn writable(b: [*c]Buffer) [*c]Buffer {
    return @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(b))));
}

fn scale(v: u64, n: u64, d: u64) u64 {
    return c.gst_util_uint64_scale(v, n, d);
}

pub export fn gst_audio_buffer_clip(buffer: [*c]Buffer, segment: [*c]const c.GstSegment, rate: c.gint, bpf: c.gint) [*c]Buffer {
    const fname = "gst_audio_buffer_clip";
    if (!check.that(segment.*.format == c.GST_FORMAT_TIME or segment.*.format == c.GST_FORMAT_DEFAULT, fname, "segment->format == GST_FORMAT_TIME || segment->format == GST_FORMAT_DEFAULT")) return buffer;
    if (!check.that(isBuffer(buffer), fname, "GST_IS_BUFFER (buffer)")) return null;
    if (buffer.*.pts == NONE) return buffer;
    const meta = channels.audioMeta(buffer);
    var trim: u64 = 0;
    const osize: u64 = if (meta != null) meta.*.samples else c.gst_buffer_get_size(buffer) / @as(usize, @intCast(bpf));
    var size = osize;
    if (size == 0) return buffer;
    const urate: u64 = @intCast(rate);
    var timestamp = buffer.*.pts;
    var change_duration = true;
    var change_offset = true;
    var change_offset_end = true;
    var duration: u64 = undefined;
    if (buffer.*.duration != NONE) {
        duration = buffer.*.duration;
    } else {
        change_duration = false;
        duration = scale(size, c.GST_SECOND, urate);
    }
    var offset: u64 = undefined;
    if (buffer.*.offset != NONE) {
        offset = buffer.*.offset;
    } else {
        change_offset = false;
        offset = 0;
    }
    var offset_end: u64 = undefined;
    if (buffer.*.offset_end != NONE) {
        offset_end = buffer.*.offset_end;
    } else {
        change_offset_end = false;
        offset_end = offset +% size;
    }
    var cstart: u64 = 0;
    var cstop: u64 = 0;
    if (segment.*.format == c.GST_FORMAT_TIME) {
        const start = timestamp;
        const stop = timestamp +% duration;
        if (c.gst_segment_clip(segment, c.GST_FORMAT_TIME, start, stop, &cstart, &cstop) == 0) {
            c.gst_mini_object_unref(@ptrCast(buffer));
            return null;
        }
        var diff = cstart -% start;
        if (diff > 0) {
            timestamp = cstart;
            if (change_duration) duration -%= diff;
            diff = scale(diff, urate, c.GST_SECOND);
            if (change_offset) offset +%= diff;
            trim +%= diff;
            size -%= diff;
        }
        diff = stop -% cstop;
        if (diff > 0) {
            duration -%= diff;
            diff = scale(diff, urate, c.GST_SECOND);
            if (change_offset_end) offset_end -%= diff;
            size -%= diff;
        }
    } else {
        if (!check.that(buffer.*.offset != NONE, fname, "GST_BUFFER_OFFSET_IS_VALID (buffer)")) return buffer;
        const start = offset;
        const stop = offset_end;
        if (c.gst_segment_clip(segment, c.GST_FORMAT_DEFAULT, start, stop, &cstart, &cstop) == 0) {
            c.gst_mini_object_unref(@ptrCast(buffer));
            return null;
        }
        var diff = cstart -% start;
        if (diff > 0) {
            offset = cstart;
            timestamp = scale(cstart, c.GST_SECOND, urate);
            if (change_duration) duration -%= scale(diff, c.GST_SECOND, urate);
            trim +%= diff;
            size -%= diff;
        }
        diff = stop -% cstop;
        if (diff > 0) {
            offset_end = cstop;
            if (change_duration) duration -%= scale(diff, c.GST_SECOND, urate);
            size -%= diff;
        }
    }
    var ret = buffer;
    if (trim == 0 and size == osize) {
        if (ret.*.pts != timestamp) {
            ret = writable(ret);
            ret.*.pts = timestamp;
        }
        if (ret.*.duration != duration) {
            ret = writable(ret);
            ret.*.duration = duration;
        }
        return ret;
    }
    ret = gst_audio_buffer_truncate(buffer, bpf, trim, size);
    if (ret != null) {
        ret.*.pts = timestamp;
        if (change_duration) ret.*.duration = duration;
        if (change_offset) ret.*.offset = offset;
        if (change_offset_end) ret.*.offset_end = offset_end;
    }
    return ret;
}

pub export fn gst_audio_buffer_truncate(buffer: [*c]Buffer, bpf: c.gint, trim: c_ulong, samples_in: c_ulong) [*c]Buffer {
    const fname = "gst_audio_buffer_truncate";
    if (!check.that(isBuffer(buffer), fname, "GST_IS_BUFFER (buffer)")) return null;
    var meta = channels.audioMeta(buffer);
    const ubpf: usize = @bitCast(@as(isize, bpf));
    const orig = if (meta != null) meta.*.samples else c.gst_buffer_get_size(buffer) / ubpf;
    const orig_ts = buffer.*.pts;
    const orig_offset = buffer.*.offset;
    var samples = samples_in;
    if (!check.that(trim < orig, fname, "trim < orig_samples")) return null;
    if (!check.that(samples == std.math.maxInt(usize) or trim + samples <= orig, fname, "samples == -1 || trim + samples <= orig_samples")) return null;
    if (samples == std.math.maxInt(usize)) samples = orig - trim;
    if (samples == orig) return buffer;
    var ret: [*c]Buffer = undefined;
    if (meta == null or meta.*.info.layout == c.GST_AUDIO_LAYOUT_INTERLEAVED) {
        ret = c.gst_buffer_copy_region(buffer, c.GST_BUFFER_COPY_ALL, trim *% ubpf, samples *% ubpf);
        c.gst_mini_object_unref(@ptrCast(buffer));
        meta = channels.audioMeta(ret);
        if (meta != null) meta.*.samples = samples;
    } else {
        ret = writable(buffer);
        meta = channels.audioMeta(ret);
        meta.*.samples = samples;
        const n: usize = @intCast(meta.*.info.channels);
        for (0..n) |i| meta.*.offsets[i] +%= trim *% ubpf / n;
    }
    ret.*.dts = NONE;
    ret.*.pts = if (orig_ts != NONE and trim == 0) orig_ts else NONE;
    ret.*.duration = NONE;
    if (orig_offset != NONE) {
        ret.*.offset = orig_offset +% trim;
        ret.*.offset_end = ret.*.offset +% samples;
    } else {
        ret.*.offset = NONE;
        ret.*.offset_end = NONE;
    }
    return ret;
}
