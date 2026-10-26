const std = @import("std");
const bits = @import("bits.zig");

pub const Error = bits.Error || error{ BadNal, Unsupported, MissingParameterSet };

pub const NAL_SLICE = 1;
pub const NAL_IDR = 5;
pub const NAL_SPS = 7;
pub const NAL_PPS = 8;

pub const P = 0;
pub const B = 1;
pub const I = 2;
pub const SP = 3;
pub const SI = 4;

pub const DEFAULT_4X4 = [2][16]u8{
    .{ 6, 13, 13, 20, 20, 20, 28, 28, 28, 28, 32, 32, 32, 37, 37, 42 },
    .{ 10, 14, 14, 20, 20, 20, 24, 24, 24, 24, 27, 27, 27, 30, 30, 34 },
};

pub const DEFAULT_8X8 = [2][64]u8{
    .{
        6,  10, 10, 13, 11, 13, 16, 16, 16, 16, 18, 18, 18, 18, 18, 23,
        23, 23, 23, 23, 23, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27,
        27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31,
        31, 33, 33, 33, 33, 33, 36, 36, 36, 36, 38, 38, 38, 40, 40, 42,
    },
    .{
        9,  13, 13, 15, 13, 15, 17, 17, 17, 17, 19, 19, 19, 19, 19, 21,
        21, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 24, 24, 24, 24,
        24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27,
        27, 28, 28, 28, 28, 28, 30, 30, 30, 30, 32, 32, 32, 33, 33, 35,
    },
};

const HIGH_PROFILES = [_]u8{ 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135 };

pub const Scaling = struct {
    l4: [6][16]u8 = .{.{16} ** 16} ** 6,
    l8: [6][64]u8 = .{.{16} ** 64} ** 6,
};

pub const Sps = struct {
    profile: u8 = 0,
    level: u8 = 0,
    constraint3: bool = false,
    id: u32 = 0,
    chroma_format: u32 = 1,
    separate_planes: bool = false,
    depth_luma: u32 = 8,
    depth_chroma: u32 = 8,
    bypass: bool = false,
    matrix: bool = false,
    scaling: Scaling = .{},
    log2_frame_num: u5 = 4,
    poc_type: u32 = 0,
    log2_poc_lsb: u5 = 4,
    poc_zero: bool = false,
    offset_non_ref: i32 = 0,
    offset_top_bottom: i32 = 0,
    cycle: u32 = 0,
    offset_ref: [256]i32 = .{0} ** 256,
    max_refs: u32 = 0,
    gaps: bool = false,
    width_mbs: u32 = 0,
    height_units: u32 = 0,
    frame_only: bool = true,
    mbaff: bool = false,
    direct8x8: bool = false,
    crop: [4]u32 = .{ 0, 0, 0, 0 },
    reorder: ?u32 = null,
    dpb_frames: ?u32 = null,
    full_range: bool = false,
    num_units: u32 = 0,
    time_scale: u32 = 0,

    pub fn heightMbs(s: *const Sps) u32 {
        return s.height_units * (if (s.frame_only) @as(u32, 1) else 2);
    }

    pub fn maxFrameNum(s: *const Sps) u32 {
        return @as(u32, 1) << s.log2_frame_num;
    }

    pub fn chromaType(s: *const Sps) u32 {
        return if (s.separate_planes) 0 else s.chroma_format;
    }

    pub fn dpbSize(s: *const Sps) u32 {
        if (s.dpb_frames) |n| return @max(@max(n, s.max_refs), 1);
        const mbs = s.width_mbs * s.heightMbs();
        const max: u32 = switch (s.level) {
            9, 10 => 396,
            11 => if (s.constraint3 and s.profile != 100) 396 else 900,
            12, 13, 20 => 2376,
            21 => 4752,
            22, 30 => 8100,
            31 => 18000,
            32 => 20480,
            40, 41 => 32768,
            42 => 34816,
            50 => 110400,
            51, 52 => 184320,
            else => 696320,
        };
        return std.math.clamp(@max(max / @max(mbs, 1), s.max_refs), 1, 16);
    }

    pub fn reorderFrames(s: *const Sps) u32 {
        if (s.reorder) |n| return n;
        if (s.profile == 66 or s.profile == 83) return 0;
        return s.dpbSize();
    }
};

pub const Pps = struct {
    id: u32 = 0,
    sps: u32 = 0,
    cabac: bool = false,
    bottom_poc: bool = false,
    l0_default: u32 = 0,
    l1_default: u32 = 0,
    weighted: bool = false,
    bipred: u2 = 0,
    qp: i32 = 0,
    qs: i32 = 0,
    chroma_qp: i32 = 0,
    second_chroma_qp: i32 = 0,
    deblocking: bool = false,
    constrained_intra: bool = false,
    redundant: bool = false,
    t8x8: bool = false,
    matrix: bool = false,
    scaling: Scaling = .{},
};

pub const Mod = struct { idc: u32, value: u32 };
pub const Mmco = struct { op: u32, diff: u32 = 0, long_num: u32 = 0, long_idx: u32 = 0, max_plus1: u32 = 0 };

pub const Weights = struct {
    luma_denom: u32 = 0,
    chroma_denom: u32 = 0,
    luma_any: [2]bool = .{ false, false },
    chroma_any: [2]bool = .{ false, false },
    luma: [2][32][2]i16 = undefined,
    chroma: [2][32][2][2]i16 = undefined,
};

pub const Slice = struct {
    nal_type: u5 = 0,
    nal_ref: u2 = 0,
    first_mb: u32 = 0,
    kind: u32 = 0,
    pps: u32 = 0,
    frame_num: u32 = 0,
    field: bool = false,
    bottom: bool = false,
    idr_id: u32 = 0,
    poc_lsb: u32 = 0,
    poc_bottom: i32 = 0,
    poc_delta: [2]i32 = .{ 0, 0 },
    redundant: u32 = 0,
    direct_spatial: bool = false,
    l0: u32 = 0,
    l1: u32 = 0,
    mods: [2][33]Mod = undefined,
    mod_count: [2]usize = .{ 0, 0 },
    weights: ?Weights = null,
    no_output_prior: bool = false,
    long_ref: bool = false,
    adaptive: bool = false,
    mmco: [33]Mmco = undefined,
    mmco_count: usize = 0,
    cabac_init: u32 = 0,
    qp_delta: i32 = 0,
    deblock: u32 = 0,
    alpha: i32 = 0,
    beta: i32 = 0,
    header_bits: usize = 0,

    pub fn idr(s: *const Slice) bool {
        return s.nal_type == NAL_IDR;
    }

    pub fn hasMmco5(s: *const Slice) bool {
        for (s.mmco[0..s.mmco_count]) |m| {
            if (m.op == 5) return true;
        }
        return false;
    }
};

pub const Nal = struct {
    data: []const u8,
    kind: u5,
    ref: u2,
};

pub const Iter = struct {
    data: []const u8,
    pos: usize = 0,
    length_size: usize = 0,

    pub fn next(it: *Iter) ?[]const u8 {
        if (it.length_size > 0) {
            if (it.pos + it.length_size > it.data.len) return null;
            var n: usize = 0;
            for (it.data[it.pos .. it.pos + it.length_size]) |b| n = (n << 8) | b;
            it.pos += it.length_size;
            const end = @min(it.data.len, it.pos + n);
            const out = it.data[it.pos..end];
            it.pos = end;
            return out;
        }
        const start = findStart(it.data, it.pos) orelse return null;
        const after = findStart(it.data, start) orelse it.data.len + 3;
        it.pos = after - 3;
        var end = after - 3;
        while (end > start and it.data[end - 1] == 0) end -= 1;
        return it.data[start..end];
    }

    fn findStart(d: []const u8, from: usize) ?usize {
        var i = from;
        while (i + 3 <= d.len) : (i += 1) {
            if (d[i] == 0 and d[i + 1] == 0 and d[i + 2] == 1) return i + 3;
        }
        return null;
    }
};

pub const Rbsp = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    epb: [512]usize = undefined,
    epb_count: usize = 0,

    pub fn load(r: *Rbsp, nal: []const u8, limit: usize) void {
        r.len = 0;
        r.epb_count = 0;
        var zeros: usize = 0;
        for (nal) |b| {
            if (r.len >= r.buf.len or r.len >= limit) break;
            if (zeros >= 2 and b == 3) {
                if (r.epb_count < r.epb.len) {
                    r.epb[r.epb_count] = r.len;
                    r.epb_count += 1;
                }
                zeros = 0;
                continue;
            }
            zeros = if (b == 0) zeros + 1 else 0;
            r.buf[r.len] = b;
            r.len += 1;
        }
    }

    pub fn bytes(r: *const Rbsp) []const u8 {
        return r.buf[0..r.len];
    }

    pub fn escapedBits(r: *const Rbsp, pos: usize) usize {
        var n: usize = 0;
        for (r.epb[0..r.epb_count]) |at| {
            if (at * 8 <= pos) n += 1;
        }
        return pos + n * 8;
    }
};

fn scalingList(r: *bits.Reader, list: []u8, default: []const u8) Error!void {
    var last: i32 = 8;
    var next: i32 = 8;
    for (list, 0..) |*v, j| {
        if (next != 0) {
            const delta = try r.se();
            next = @mod(last + delta + 256, 256);
            if (j == 0 and next == 0) {
                @memcpy(list, default);
                return;
            }
        }
        v.* = @intCast(if (next == 0) last else next);
        last = v.*;
    }
}

fn scalingMatrix(r: *bits.Reader, sc: *Scaling, count: usize, fallback: ?*const Scaling) Error!void {
    for (0..count) |i| {
        const present = try r.flag();
        if (i < 6) {
            const default = &DEFAULT_4X4[if (i < 3) 0 else 1];
            if (present) {
                try scalingList(r, &sc.l4[i], default);
            } else if (i == 0 or i == 3) {
                sc.l4[i] = if (fallback) |f| f.l4[i] else default.*;
            } else sc.l4[i] = sc.l4[i - 1];
        } else {
            const k = i - 6;
            const default = &DEFAULT_8X8[k & 1];
            if (present) {
                try scalingList(r, &sc.l8[k], default);
            } else if (k < 2) {
                sc.l8[k] = if (fallback) |f| f.l8[k] else default.*;
            } else sc.l8[k] = sc.l8[k - 2];
        }
    }
}

fn skipHrd(r: *bits.Reader) Error!void {
    const cpb = try r.ue();
    _ = try r.f(8);
    for (0..cpb + 1) |_| {
        _ = try r.ue();
        _ = try r.ue();
        _ = try r.flag();
    }
    _ = try r.f(20);
}

fn vui(r: *bits.Reader, s: *Sps) Error!void {
    if (try r.flag()) {
        if (try r.f(8) == 255) _ = try r.f(32);
    }
    if (try r.flag()) _ = try r.flag();
    if (try r.flag()) {
        _ = try r.f(3);
        s.full_range = try r.flag();
        if (try r.flag()) _ = try r.f(24);
    }
    if (try r.flag()) {
        _ = try r.ue();
        _ = try r.ue();
    }
    if (try r.flag()) {
        s.num_units = try r.f(32);
        s.time_scale = try r.f(32);
        _ = try r.flag();
    }
    const nal_hrd = try r.flag();
    if (nal_hrd) try skipHrd(r);
    const vcl_hrd = try r.flag();
    if (vcl_hrd) try skipHrd(r);
    if (nal_hrd or vcl_hrd) _ = try r.flag();
    _ = try r.flag();
    if (try r.flag()) {
        _ = try r.flag();
        for (0..4) |_| _ = try r.ue();
        s.reorder = try r.ue();
        s.dpb_frames = try r.ue();
    }
}

pub fn parseSps(data: []const u8) Error!Sps {
    var r = bits.Reader{ .data = data };
    var s = Sps{};
    s.profile = @intCast(try r.f(8));
    const constraints = try r.f(8);
    s.constraint3 = constraints & 0x10 != 0;
    s.level = @intCast(try r.f(8));
    s.id = try r.ue();
    if (s.id > 31) return error.BadNal;
    if (std.mem.indexOfScalar(u8, &HIGH_PROFILES, s.profile) != null) {
        s.chroma_format = try r.ue();
        if (s.chroma_format > 3) return error.BadNal;
        if (s.chroma_format == 3) s.separate_planes = try r.flag();
        s.depth_luma = try r.ue() + 8;
        s.depth_chroma = try r.ue() + 8;
        s.bypass = try r.flag();
        s.matrix = try r.flag();
        if (s.matrix) try scalingMatrix(&r, &s.scaling, if (s.chroma_format != 3) 8 else 12, null);
    }
    const lfn = try r.ue();
    if (lfn > 12) return error.BadNal;
    s.log2_frame_num = @intCast(lfn + 4);
    s.poc_type = try r.ue();
    if (s.poc_type == 0) {
        const l = try r.ue();
        if (l > 12) return error.BadNal;
        s.log2_poc_lsb = @intCast(l + 4);
    } else if (s.poc_type == 1) {
        s.poc_zero = try r.flag();
        s.offset_non_ref = try r.se();
        s.offset_top_bottom = try r.se();
        s.cycle = try r.ue();
        if (s.cycle > 255) return error.BadNal;
        for (s.offset_ref[0..s.cycle]) |*o| o.* = try r.se();
    } else if (s.poc_type != 2) return error.BadNal;
    s.max_refs = try r.ue();
    s.gaps = try r.flag();
    s.width_mbs = try r.ue() + 1;
    s.height_units = try r.ue() + 1;
    s.frame_only = try r.flag();
    if (!s.frame_only) s.mbaff = try r.flag();
    s.direct8x8 = try r.flag();
    if (try r.flag()) {
        for (&s.crop) |*c| c.* = try r.ue();
    }
    if (try r.flag()) vui(&r, &s) catch {};
    return s;
}

pub fn parsePps(data: []const u8, spss: *const [32]?Sps) Error!Pps {
    var r = bits.Reader{ .data = data };
    var p = Pps{};
    p.id = try r.ue();
    if (p.id > 255) return error.BadNal;
    p.sps = try r.ue();
    if (p.sps > 31) return error.BadNal;
    const sps = &(spss[p.sps] orelse return error.MissingParameterSet);
    p.cabac = try r.flag();
    p.bottom_poc = try r.flag();
    if (try r.ue() > 0) return error.Unsupported;
    p.l0_default = try r.ue();
    p.l1_default = try r.ue();
    if (p.l0_default > 31 or p.l1_default > 31) return error.BadNal;
    p.weighted = try r.flag();
    p.bipred = @intCast(try r.f(2));
    p.qp = try r.se();
    p.qs = try r.se();
    p.chroma_qp = try r.se();
    p.deblocking = try r.flag();
    p.constrained_intra = try r.flag();
    p.redundant = try r.flag();
    p.second_chroma_qp = p.chroma_qp;
    p.scaling = sps.scaling;
    if (r.moreData()) {
        p.t8x8 = try r.flag();
        p.matrix = try r.flag();
        if (p.matrix) {
            const n: usize = 6 + (if (sps.chroma_format != 3) @as(usize, 2) else 6) * @intFromBool(p.t8x8);
            try scalingMatrix(&r, &p.scaling, n, if (sps.matrix) &sps.scaling else null);
        }
        p.second_chroma_qp = try r.se();
    }
    return p;
}

fn mods(r: *bits.Reader, out: []Mod, count: *usize) Error!void {
    count.* = 0;
    if (!try r.flag()) return;
    while (true) {
        const idc = try r.ue();
        if (idc == 3) return;
        if (idc > 5 or count.* >= out.len) return error.BadNal;
        out[count.*] = .{ .idc = idc, .value = try r.ue() };
        count.* += 1;
    }
}

fn weightTable(r: *bits.Reader, sl: *const Slice, chroma: bool) Error!Weights {
    var w = Weights{};
    w.luma_denom = try r.ue();
    if (w.luma_denom > 7) return error.BadNal;
    if (chroma) {
        w.chroma_denom = try r.ue();
        if (w.chroma_denom > 7) return error.BadNal;
    }
    const lists: usize = if (sl.kind == B) 2 else 1;
    for (0..lists) |l| {
        const n = (if (l == 0) sl.l0 else sl.l1) + 1;
        for (0..32) |i| {
            w.luma[l][i] = .{ @as(i16, 1) << @intCast(w.luma_denom), 0 };
            w.chroma[l][i] = .{ .{ @as(i16, 1) << @intCast(w.chroma_denom), 0 }, .{ @as(i16, 1) << @intCast(w.chroma_denom), 0 } };
        }
        for (0..n) |i| {
            if (try r.flag()) {
                w.luma_any[l] = true;
                w.luma[l][i] = .{ @intCast(try r.se()), @intCast(try r.se()) };
            }
            if (chroma and try r.flag()) {
                w.chroma_any[l] = true;
                for (0..2) |j| w.chroma[l][i][j] = .{ @intCast(try r.se()), @intCast(try r.se()) };
            }
        }
    }
    return w;
}

pub fn parseSlice(rb: *const Rbsp, spss: *const [32]?Sps, ppss: *const [256]?Pps) Error!Slice {
    const data = rb.bytes();
    if (data.len < 2) return error.BadNal;
    var sl = Slice{ .nal_type = @intCast(data[0] & 0x1f), .nal_ref = @intCast((data[0] >> 5) & 3) };
    var r = bits.Reader{ .data = data, .pos = 8 };
    sl.first_mb = try r.ue();
    const raw = try r.ue();
    if (raw > 9) return error.BadNal;
    sl.kind = raw % 5;
    sl.pps = try r.ue();
    if (sl.pps > 255) return error.BadNal;
    const pps = &(ppss[sl.pps] orelse return error.MissingParameterSet);
    const sps = &(spss[pps.sps] orelse return error.MissingParameterSet);
    if (sps.separate_planes) _ = try r.f(2);
    sl.frame_num = try r.f(sps.log2_frame_num);
    if (!sps.frame_only) {
        sl.field = try r.flag();
        if (sl.field) sl.bottom = try r.flag();
    }
    if (sl.idr()) sl.idr_id = try r.ue();
    if (sps.poc_type == 0) {
        sl.poc_lsb = try r.f(sps.log2_poc_lsb);
        if (pps.bottom_poc and !sl.field) sl.poc_bottom = try r.se();
    }
    if (sps.poc_type == 1 and !sps.poc_zero) {
        sl.poc_delta[0] = try r.se();
        if (pps.bottom_poc and !sl.field) sl.poc_delta[1] = try r.se();
    }
    if (pps.redundant) sl.redundant = try r.ue();
    if (sl.kind == B) sl.direct_spatial = try r.flag();
    sl.l0 = pps.l0_default;
    sl.l1 = pps.l1_default;
    if (sl.kind == P or sl.kind == SP or sl.kind == B) {
        if (try r.flag()) {
            sl.l0 = try r.ue();
            if (sl.kind == B) sl.l1 = try r.ue();
        }
        if (sl.l0 > 31 or sl.l1 > 31) return error.BadNal;
    }
    if (sl.nal_type == 20 or sl.nal_type == 21) return error.Unsupported;
    if (sl.kind != I and sl.kind != SI) try mods(&r, &sl.mods[0], &sl.mod_count[0]);
    if (sl.kind == B) try mods(&r, &sl.mods[1], &sl.mod_count[1]);
    if ((pps.weighted and (sl.kind == P or sl.kind == SP)) or (pps.bipred == 1 and sl.kind == B)) sl.weights = try weightTable(&r, &sl, sps.chromaType() != 0);
    if (sl.nal_ref != 0) {
        if (sl.idr()) {
            sl.no_output_prior = try r.flag();
            sl.long_ref = try r.flag();
        } else {
            sl.adaptive = try r.flag();
            if (sl.adaptive) {
                while (true) {
                    const op = try r.ue();
                    if (op == 0) break;
                    if (op > 6 or sl.mmco_count >= sl.mmco.len) return error.BadNal;
                    var m = Mmco{ .op = op };
                    if (op == 1 or op == 3) m.diff = try r.ue();
                    if (op == 2) m.long_num = try r.ue();
                    if (op == 3 or op == 6) m.long_idx = try r.ue();
                    if (op == 4) m.max_plus1 = try r.ue();
                    sl.mmco[sl.mmco_count] = m;
                    sl.mmco_count += 1;
                }
            }
        }
    }
    if (pps.cabac and sl.kind != I and sl.kind != SI) sl.cabac_init = try r.ue();
    sl.qp_delta = try r.se();
    if (sl.kind == SP or sl.kind == SI) {
        if (sl.kind == SP) _ = try r.flag();
        _ = try r.se();
    }
    if (pps.deblocking) {
        sl.deblock = try r.ue();
        if (sl.deblock != 1) {
            sl.alpha = try r.se();
            sl.beta = try r.se();
        }
    }
    sl.header_bits = rb.escapedBits(r.pos);
    return sl;
}

pub fn avcConfig(data: []const u8, out: *[64][]const u8, count: *usize) ?usize {
    if (data.len < 7 or data[0] != 1) return null;
    const length_size: usize = (data[4] & 3) + 1;
    var p: usize = 5;
    count.* = 0;
    for (0..2) |k| {
        if (p >= data.len) return null;
        const n: usize = if (k == 0) data[p] & 0x1f else data[p];
        p += 1;
        for (0..n) |_| {
            if (p + 2 > data.len) return null;
            const len = (@as(usize, data[p]) << 8) | data[p + 1];
            p += 2;
            if (p + len > data.len or count.* >= out.len) return null;
            out[count.*] = data[p .. p + len];
            count.* += 1;
            p += len;
        }
    }
    return length_size;
}

test "the clip parameter sets and slices parse" {
    const data = @embedFile("clip.h264");
    var spss: [32]?Sps = .{null} ** 32;
    var ppss: [256]?Pps = .{null} ** 256;
    var it = Iter{ .data = data };
    var slices: usize = 0;
    var idrs: usize = 0;
    var bs: usize = 0;
    var rb: Rbsp = .{};
    while (it.next()) |nal| {
        if (nal.len == 0) continue;
        rb.load(nal, 512);
        const kind = nal[0] & 0x1f;
        switch (kind) {
            NAL_SPS => {
                rb.load(nal, std.math.maxInt(usize));
                const s = try parseSps(rb.bytes()[1..]);
                try std.testing.expectEqual(@as(u32, 4), s.width_mbs);
                try std.testing.expectEqual(@as(u32, 3), s.heightMbs());
                try std.testing.expectEqual(@as(u8, 100), s.profile);
                try std.testing.expectEqual(@as(?u32, 2), s.reorder);
                spss[s.id] = s;
            },
            NAL_PPS => {
                rb.load(nal, std.math.maxInt(usize));
                const p = try parsePps(rb.bytes()[1..], &spss);
                try std.testing.expect(p.cabac);
                ppss[p.id] = p;
            },
            NAL_SLICE, NAL_IDR => {
                const sl = try parseSlice(&rb, &spss, &ppss);
                slices += 1;
                if (sl.idr()) idrs += 1;
                if (sl.kind == B) bs += 1;
                try std.testing.expect(sl.header_bits > 8 and sl.header_bits < nal.len * 8);
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 30), slices);
    try std.testing.expect(idrs >= 1);
    try std.testing.expect(bs > 0);
}

test "emulation prevention bytes are removed and counted" {
    var rb: Rbsp = .{};
    rb.load(&.{ 0x65, 0, 0, 3, 1, 0, 0, 3, 0 }, 64);
    try std.testing.expectEqualSlices(u8, &.{ 0x65, 0, 0, 1, 0, 0, 0 }, rb.bytes());
    try std.testing.expectEqual(@as(usize, 40), rb.escapedBits(32));
    try std.testing.expectEqual(@as(usize, 16), rb.escapedBits(16));
}
