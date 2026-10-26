const std = @import("std");
const bits = @import("bits.zig");
const quant = @import("quant.zig");

pub const Error = bits.Error || error{ BadMarker, BadSync, BadProfile, MissingReference };

const LITERAL_TO_TYPE = [4]u3{ 1, 0, 2, 3 };
const FEATURE_BITS = [4]u6{ 8, 6, 2, 0 };
const FEATURE_SIGNED = [4]bool{ true, true, false, false };
const CS_RGB = 7;
const MAX_LOOP_FILTER = 63;
const MIN_TILE_WIDTH_B64 = 4;
const MAX_TILE_WIDTH_B64 = 64;
const SEG_LVL_ALT_Q = 0;
const SEG_LVL_ALT_L = 1;
const SEG_LVL_REF_FRAME = 2;
const SEG_LVL_SKIP = 3;

pub const Segment = struct {
    reference_enabled: bool = false,
    reference: u2 = 0,
    skipped: bool = false,
    filter_level: [4][2]u8 = .{.{ 0, 0 }} ** 4,
    luma_ac: i16 = 0,
    luma_dc: i16 = 0,
    chroma_ac: i16 = 0,
    chroma_dc: i16 = 0,
};

pub const Frame = struct {
    profile: u2 = 0,
    show_existing: bool = false,
    show_idx: u3 = 0,
    key: bool = false,
    show: bool = false,
    error_resilient: bool = false,
    intra_only: bool = false,
    reset_context: u2 = 0,
    refresh_flags: u8 = 0,
    ref_idx: [3]u3 = .{ 0, 0, 0 },
    sign_bias: [3]bool = .{ false, false, false },
    width: u32 = 0,
    height: u32 = 0,
    render_width: u32 = 0,
    render_height: u32 = 0,
    high_precision_mv: bool = false,
    interp_filter: u3 = 0,
    refresh_context: bool = false,
    parallel: bool = false,
    context_idx: u2 = 0,
    filter_level: u8 = 0,
    sharpness: u8 = 0,
    base_q: u8 = 0,
    delta_y_dc: i32 = 0,
    delta_uv_dc: i32 = 0,
    delta_uv_ac: i32 = 0,
    lossless: bool = false,
    seg_enabled: bool = false,
    seg_update_map: bool = false,
    seg_temporal: bool = false,
    tree_probs: [7]u8 = .{255} ** 7,
    pred_probs: [3]u8 = .{255} ** 3,
    tile_cols_log2: u8 = 0,
    tile_rows_log2: u8 = 0,
    header_bytes: u32 = 0,
    compressed_bytes: u32 = 0,
    segments: [8]Segment = .{Segment{}} ** 8,
};

pub const State = struct {
    bit_depth: u8 = 8,
    color_space: u3 = 0,
    color_range: bool = false,
    subsampling_x: bool = true,
    subsampling_y: bool = true,
    ref_width: [8]u32 = .{0} ** 8,
    ref_height: [8]u32 = .{0} ** 8,
    ref_deltas: [4]i32 = .{ 1, 0, -1, -1 },
    mode_deltas: [2]i32 = .{ 0, 0 },
    delta_enabled: bool = false,
    abs_delta: bool = false,
    feature_enabled: [8][4]bool = .{.{false} ** 4} ** 8,
    feature_data: [8][4]i32 = .{.{0} ** 4} ** 8,

    fn colorConfig(st: *State, r: *bits.Reader, profile: u2) Error!void {
        st.bit_depth = if (profile >= 2) (if (try r.flag()) 12 else 10) else 8;
        st.color_space = @intCast(try r.f(3));
        if (st.color_space != CS_RGB) {
            st.color_range = try r.flag();
            if (profile == 1 or profile == 3) {
                st.subsampling_x = try r.flag();
                st.subsampling_y = try r.flag();
                if (try r.flag()) return error.BadProfile;
            } else {
                st.subsampling_x = true;
                st.subsampling_y = true;
            }
        } else {
            st.color_range = true;
            if (profile == 1 or profile == 3) {
                st.subsampling_x = false;
                st.subsampling_y = false;
                if (try r.flag()) return error.BadProfile;
            } else return error.BadProfile;
        }
    }

    fn pastIndependence(st: *State) void {
        st.feature_enabled = .{.{false} ** 4} ** 8;
        st.feature_data = .{.{0} ** 4} ** 8;
        st.abs_delta = false;
        st.delta_enabled = true;
        st.ref_deltas = .{ 1, 0, -1, -1 };
        st.mode_deltas = .{ 0, 0 };
    }

    fn loopFilter(st: *State, r: *bits.Reader, fr: *Frame) Error!void {
        fr.filter_level = @intCast(try r.f(6));
        fr.sharpness = @intCast(try r.f(3));
        st.delta_enabled = try r.flag();
        if (st.delta_enabled and try r.flag()) {
            for (&st.ref_deltas) |*d| {
                if (try r.flag()) d.* = try r.s(6);
            }
            for (&st.mode_deltas) |*d| {
                if (try r.flag()) d.* = try r.s(6);
            }
        }
    }

    fn quantization(r: *bits.Reader, fr: *Frame) Error!void {
        fr.base_q = @intCast(try r.f(8));
        fr.delta_y_dc = try deltaQ(r);
        fr.delta_uv_dc = try deltaQ(r);
        fr.delta_uv_ac = try deltaQ(r);
        fr.lossless = fr.base_q == 0 and fr.delta_y_dc == 0 and fr.delta_uv_dc == 0 and fr.delta_uv_ac == 0;
    }

    fn segmentation(st: *State, r: *bits.Reader, fr: *Frame) Error!void {
        fr.seg_enabled = try r.flag();
        if (!fr.seg_enabled) return;
        fr.seg_update_map = try r.flag();
        if (fr.seg_update_map) {
            for (&fr.tree_probs) |*p| p.* = try prob(r);
            fr.seg_temporal = try r.flag();
            for (&fr.pred_probs) |*p| p.* = if (fr.seg_temporal) try prob(r) else 255;
        }
        if (try r.flag()) {
            st.abs_delta = try r.flag();
            for (0..8) |i| {
                for (0..4) |j| {
                    var v: i32 = 0;
                    const on = try r.flag();
                    st.feature_enabled[i][j] = on;
                    if (on) {
                        v = @intCast(try r.f(FEATURE_BITS[j]));
                        if (FEATURE_SIGNED[j] and try r.flag()) v = -v;
                    }
                    st.feature_data[i][j] = v;
                }
            }
        }
    }

    fn active(st: *const State, fr: *const Frame, seg: usize, feature: usize) bool {
        return fr.seg_enabled and st.feature_enabled[seg][feature];
    }

    fn derive(st: *const State, fr: *Frame) void {
        const depth: usize = (st.bit_depth - 8) >> 1;
        const shift: u5 = @intCast(fr.filter_level >> 5);
        for (&fr.segments, 0..) |*sg, i| {
            var q: i32 = fr.base_q;
            if (st.active(fr, i, SEG_LVL_ALT_Q)) {
                q = st.feature_data[i][SEG_LVL_ALT_Q];
                if (!st.abs_delta) q += fr.base_q;
                q = std.math.clamp(q, 0, 255);
            }
            sg.luma_dc = lookup(&quant.DC[depth], q + fr.delta_y_dc);
            sg.luma_ac = lookup(&quant.AC[depth], q);
            sg.chroma_dc = lookup(&quant.DC[depth], q + fr.delta_uv_dc);
            sg.chroma_ac = lookup(&quant.AC[depth], q + fr.delta_uv_ac);
            var lvl: i32 = fr.filter_level;
            if (st.active(fr, i, SEG_LVL_ALT_L)) {
                lvl = st.feature_data[i][SEG_LVL_ALT_L];
                if (!st.abs_delta) lvl += fr.filter_level;
                lvl = std.math.clamp(lvl, 0, MAX_LOOP_FILTER);
            }
            if (!st.delta_enabled) {
                const l: u8 = @intCast(lvl);
                sg.filter_level = .{.{ l, l }} ** 4;
            } else {
                const intra: u8 = @intCast(std.math.clamp(lvl + (st.ref_deltas[0] << shift), 0, MAX_LOOP_FILTER));
                sg.filter_level[0] = .{ intra, intra };
                for (1..4) |ref| {
                    for (0..2) |mode| {
                        const v = lvl + (st.ref_deltas[ref] << shift) + (st.mode_deltas[mode] << shift);
                        sg.filter_level[ref][mode] = @intCast(std.math.clamp(v, 0, MAX_LOOP_FILTER));
                    }
                }
            }
            sg.reference_enabled = st.active(fr, i, SEG_LVL_REF_FRAME);
            sg.reference = @intCast(st.feature_data[i][SEG_LVL_REF_FRAME] & 3);
            sg.skipped = st.active(fr, i, SEG_LVL_SKIP);
        }
    }

    pub fn parse(st: *State, data: []const u8) Error!Frame {
        var r = bits.Reader{ .data = data };
        var fr = Frame{};
        if (try r.f(2) != 2) return error.BadMarker;
        const lo = try r.bit();
        const hi = try r.bit();
        fr.profile = (@as(u2, hi) << 1) | lo;
        if (fr.profile == 3 and try r.flag()) return error.BadProfile;
        fr.show_existing = try r.flag();
        if (fr.show_existing) {
            fr.show_idx = @intCast(try r.f(3));
            return fr;
        }
        fr.key = !try r.flag();
        fr.show = try r.flag();
        fr.error_resilient = try r.flag();
        if (fr.key) {
            try sync(&r);
            try st.colorConfig(&r, fr.profile);
            try frameSize(&r, &fr);
            try renderSize(&r, &fr);
            fr.refresh_flags = 0xff;
        } else {
            fr.intra_only = if (fr.show) false else try r.flag();
            fr.reset_context = if (fr.error_resilient) 0 else @intCast(try r.f(2));
            if (fr.intra_only) {
                try sync(&r);
                if (fr.profile > 0) {
                    try st.colorConfig(&r, fr.profile);
                } else {
                    st.color_space = 2;
                    st.subsampling_x = true;
                    st.subsampling_y = true;
                    st.bit_depth = 8;
                }
                fr.refresh_flags = @intCast(try r.f(8));
                try frameSize(&r, &fr);
                try renderSize(&r, &fr);
            } else {
                fr.refresh_flags = @intCast(try r.f(8));
                for (0..3) |i| {
                    fr.ref_idx[i] = @intCast(try r.f(3));
                    fr.sign_bias[i] = try r.flag();
                }
                var found = false;
                for (fr.ref_idx) |idx| {
                    if (try r.flag()) {
                        fr.width = st.ref_width[idx];
                        fr.height = st.ref_height[idx];
                        found = true;
                        break;
                    }
                }
                if (!found) try frameSize(&r, &fr);
                if (fr.width == 0 or fr.height == 0) return error.MissingReference;
                try renderSize(&r, &fr);
                fr.high_precision_mv = try r.flag();
                fr.interp_filter = if (try r.flag()) 4 else LITERAL_TO_TYPE[try r.f(2)];
            }
        }
        if (!fr.error_resilient) {
            fr.refresh_context = try r.flag();
            fr.parallel = try r.flag();
        } else {
            fr.parallel = true;
        }
        fr.context_idx = @intCast(try r.f(2));
        if (fr.key or fr.intra_only or fr.error_resilient) st.pastIndependence();
        try st.loopFilter(&r, &fr);
        try quantization(&r, &fr);
        try st.segmentation(&r, &fr);
        try tileInfo(&r, &fr);
        fr.compressed_bytes = try r.f(16);
        fr.header_bytes = @intCast(r.bytes());
        st.derive(&fr);
        return fr;
    }

    pub fn update(st: *State, fr: *const Frame) void {
        for (0..8) |i| {
            if (fr.refresh_flags & (@as(u8, 1) << @intCast(i)) != 0) {
                st.ref_width[i] = fr.width;
                st.ref_height[i] = fr.height;
            }
        }
    }
};

fn lookup(table: *const [256]u16, q: i32) i16 {
    return @intCast(table[@intCast(std.math.clamp(q, 0, 255))]);
}

fn deltaQ(r: *bits.Reader) Error!i32 {
    return if (try r.flag()) try r.s(4) else 0;
}

fn prob(r: *bits.Reader) Error!u8 {
    return if (try r.flag()) @intCast(try r.f(8)) else 255;
}

fn sync(r: *bits.Reader) Error!void {
    if (try r.f(8) != 0x49 or try r.f(8) != 0x83 or try r.f(8) != 0x42) return error.BadSync;
}

fn frameSize(r: *bits.Reader, fr: *Frame) Error!void {
    fr.width = try r.f(16) + 1;
    fr.height = try r.f(16) + 1;
}

fn renderSize(r: *bits.Reader, fr: *Frame) Error!void {
    if (try r.flag()) {
        fr.render_width = try r.f(16) + 1;
        fr.render_height = try r.f(16) + 1;
    } else {
        fr.render_width = fr.width;
        fr.render_height = fr.height;
    }
}

fn tileInfo(r: *bits.Reader, fr: *Frame) Error!void {
    const sb64: u32 = (((fr.width + 7) >> 3) + 7) >> 3;
    var min: u8 = 0;
    while ((@as(u32, MAX_TILE_WIDTH_B64) << @intCast(min)) < sb64) min += 1;
    var max: u8 = 1;
    while ((sb64 >> @intCast(max)) >= MIN_TILE_WIDTH_B64) max += 1;
    max -= 1;
    fr.tile_cols_log2 = min;
    while (fr.tile_cols_log2 < max) {
        if (!try r.flag()) break;
        fr.tile_cols_log2 += 1;
    }
    fr.tile_rows_log2 = try r.bit();
    if (fr.tile_rows_log2 == 1) fr.tile_rows_log2 += try r.bit();
}

pub const Superframe = struct {
    sizes: [8]u32 = undefined,
    count: usize = 0,
};

pub fn split(data: []const u8) Superframe {
    var sf = Superframe{};
    if (data.len > 0) {
        const last = data[data.len - 1];
        if (last & 0xe0 == 0xc0) {
            const sz: usize = ((last >> 3) & 3) + 1;
            const n: usize = (last & 7) + 1;
            const index = 2 + n * sz;
            if (data.len >= index and data[data.len - index] == last) {
                var p = data.len - index + 1;
                var total: usize = 0;
                for (0..n) |i| {
                    var v: u32 = 0;
                    for (0..sz) |j| v |= @as(u32, data[p + j]) << @intCast(j * 8);
                    p += sz;
                    sf.sizes[i] = v;
                    total += v;
                }
                if (total <= data.len - index) {
                    sf.count = n;
                    return sf;
                }
            }
        }
    }
    sf.sizes[0] = @intCast(data.len);
    sf.count = 1;
    return sf;
}

const Clip = struct {
    frames: [64][]const u8 = undefined,
    count: usize = 0,

    fn vint(d: []const u8, p: *usize, keep: bool) u64 {
        const first = d[p.*];
        const len: usize = @clz(first) + 1;
        var v: u64 = if (keep) first else first & @as(u8, @truncate(@as(u16, 0xff) >> @intCast(len)));
        for (1..len) |i| v = (v << 8) | d[p.* + i];
        p.* += len;
        return v;
    }

    fn walk(cl: *Clip, d: []const u8) void {
        var p: usize = 0;
        while (p < d.len) {
            const id = vint(d, &p, true);
            const size = vint(d, &p, false);
            const end = @min(d.len, p + @as(usize, @intCast(@min(size, d.len))));
            switch (id) {
                0x18538067, 0x1F43B675, 0xA0 => cl.walk(d[p..end]),
                0xA1, 0xA3 => {
                    var q = p;
                    _ = vint(d, &q, false);
                    q += 3;
                    cl.frames[cl.count] = d[q..end];
                    cl.count += 1;
                },
                else => {},
            }
            p = end;
        }
    }
};

fn checkClip(data: []const u8, frames: usize, profile: u2, depth: u8) !void {
    var cl = Clip{};
    cl.walk(data);
    try std.testing.expectEqual(frames, cl.count);
    var st = State{};
    var keys: usize = 0;
    for (cl.frames[0..cl.count], 0..) |f, i| {
        const sf = split(f);
        var off: usize = 0;
        for (sf.sizes[0..sf.count]) |sz| {
            const fr = try st.parse(f[off .. off + sz]);
            off += sz;
            if (fr.show_existing) continue;
            try std.testing.expectEqual(profile, fr.profile);
            try std.testing.expectEqual(@as(u32, 64), fr.width);
            try std.testing.expectEqual(@as(u32, 48), fr.height);
            try std.testing.expect(fr.header_bytes + fr.compressed_bytes <= sz);
            if (fr.key) {
                try std.testing.expectEqual(@as(usize, 0), i % 10);
                keys += 1;
            }
            try std.testing.expect(fr.segments[0].luma_ac > 0);
            st.update(&fr);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), keys);
    try std.testing.expectEqual(depth, st.bit_depth);
}

test "the clips parse frame by frame" {
    try checkClip(@embedFile("clip-vp9.webm"), 30, 3, 12);
    try checkClip(@embedFile("clip-vp9-420.webm"), 27, 0, 8);
}

test "a superframe index is split by its sizes" {
    const d = [_]u8{ 1, 2, 3, 4, 5, 0xc9, 3, 0, 2, 0, 0xc9 };
    const sf = split(&d);
    try std.testing.expectEqual(@as(usize, 2), sf.count);
    try std.testing.expectEqual(@as(u32, 3), sf.sizes[0]);
    try std.testing.expectEqual(@as(u32, 2), sf.sizes[1]);
    const plain = split(&.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 1), plain.count);
}

test "quant tables follow the spec" {
    try std.testing.expectEqual(@as(u16, 4), quant.DC[0][0]);
    try std.testing.expectEqual(@as(u16, 1336), quant.DC[0][255]);
    try std.testing.expectEqual(@as(u16, 1828), quant.AC[0][255]);
}
