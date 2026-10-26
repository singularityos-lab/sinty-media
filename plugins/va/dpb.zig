const std = @import("std");
const h = @import("h264.zig");

pub const INVALID: u32 = 0xffffffff;
pub const MAX = 17;

pub const Pic = struct {
    used: bool = false,
    surface: u32 = INVALID,
    frame: u32 = 0,
    frame_num: u32 = 0,
    wrap: i32 = 0,
    long_idx: u32 = 0,
    top: i32 = 0,
    bottom: i32 = 0,
    short: bool = false,
    long: bool = false,
    output: bool = false,
    nonexisting: bool = false,

    pub fn poc(p: *const Pic) i32 {
        return @min(p.top, p.bottom);
    }

    pub fn ref(p: *const Pic) bool {
        return p.short or p.long;
    }
};

pub const Out = struct {
    frame: u32,
    surface: u32,
};

pub const Outputs = struct {
    items: [MAX + 1]Out = undefined,
    count: usize = 0,

    fn push(o: *Outputs, p: *const Pic) void {
        if (o.count < o.items.len) {
            o.items[o.count] = .{ .frame = p.frame, .surface = p.surface };
            o.count += 1;
        }
    }
};

pub const List = struct {
    idx: [33]u8 = undefined,
    count: usize = 0,
};

pub const Dpb = struct {
    pics: [MAX]Pic = .{Pic{}} ** MAX,
    size: u32 = 16,
    reorder: u32 = 16,
    max_long: ?u32 = null,
    prev_msb: i32 = 0,
    prev_lsb: i32 = 0,
    prev_offset: i32 = 0,
    prev_frame_num: u32 = 0,
    prev_ref_frame_num: u32 = 0,
    prev_mmco5: bool = false,
    cur: Pic = .{},
    cur_offset: i32 = 0,
    cur_msb: i32 = 0,
    max_frame_num: u32 = 16,

    pub fn reset(d: *Dpb) void {
        const size = d.size;
        const reorder = d.reorder;
        d.* = .{ .size = size, .reorder = reorder };
    }

    pub fn configure(d: *Dpb, sps: *const h.Sps) void {
        d.size = @min(sps.dpbSize(), MAX - 1);
        d.reorder = @min(sps.reorderFrames(), d.size);
        d.max_frame_num = sps.maxFrameNum();
    }

    fn poc(d: *Dpb, sps: *const h.Sps, sl: *const h.Slice) void {
        const max_frame: i32 = @intCast(sps.maxFrameNum());
        const frame_num: i32 = @intCast(sl.frame_num);
        switch (sps.poc_type) {
            0 => {
                var prev_msb = d.prev_msb;
                var prev_lsb = d.prev_lsb;
                if (sl.idr()) {
                    prev_msb = 0;
                    prev_lsb = 0;
                }
                const max_lsb: i32 = @as(i32, 1) << sps.log2_poc_lsb;
                const lsb: i32 = @intCast(sl.poc_lsb);
                var msb = prev_msb;
                if (lsb < prev_lsb and prev_lsb - lsb >= @divTrunc(max_lsb, 2)) {
                    msb = prev_msb + max_lsb;
                } else if (lsb > prev_lsb and lsb - prev_lsb > @divTrunc(max_lsb, 2)) msb = prev_msb - max_lsb;
                d.cur_msb = msb;
                d.cur.top = msb + lsb;
                d.cur.bottom = d.cur.top + sl.poc_bottom;
            },
            1 => {
                const prev_offset: i32 = if (d.prev_mmco5) 0 else d.prev_offset;
                d.cur_offset = if (sl.idr()) 0 else if (d.prev_frame_num > sl.frame_num) prev_offset + max_frame else prev_offset;
                var abs: i32 = if (sps.cycle != 0) d.cur_offset + frame_num else 0;
                if (sl.nal_ref == 0 and abs > 0) abs -= 1;
                var expected: i32 = 0;
                if (abs > 0) {
                    var delta: i32 = 0;
                    for (sps.offset_ref[0..sps.cycle]) |o| delta += o;
                    const cycle: i32 = @intCast(sps.cycle);
                    const cnt = @divTrunc(abs - 1, cycle);
                    const in_cycle: usize = @intCast(@mod(abs - 1, cycle));
                    expected = cnt * delta;
                    for (sps.offset_ref[0 .. in_cycle + 1]) |o| expected += o;
                }
                if (sl.nal_ref == 0) expected += sps.offset_non_ref;
                d.cur.top = expected + sl.poc_delta[0];
                d.cur.bottom = d.cur.top + sps.offset_top_bottom + sl.poc_delta[1];
            },
            else => {
                const prev_offset: i32 = if (d.prev_mmco5) 0 else d.prev_offset;
                d.cur_offset = if (sl.idr()) 0 else if (d.prev_frame_num > sl.frame_num) prev_offset + max_frame else prev_offset;
                const temp: i32 = if (sl.idr()) 0 else if (sl.nal_ref == 0) 2 * (d.cur_offset + frame_num) - 1 else 2 * (d.cur_offset + frame_num);
                d.cur.top = temp;
                d.cur.bottom = temp;
            },
        }
    }

    fn wraps(d: *Dpb, frame_num: u32) void {
        for (&d.pics) |*p| {
            if (!p.used or !p.short) continue;
            p.wrap = if (p.frame_num > frame_num) @as(i32, @intCast(p.frame_num)) - @as(i32, @intCast(d.max_frame_num)) else @intCast(p.frame_num);
        }
    }

    fn counts(d: *const Dpb) [2]u32 {
        var n = [2]u32{ 0, 0 };
        for (d.pics) |p| {
            if (!p.used) continue;
            if (p.short) n[0] += 1;
            if (p.long) n[1] += 1;
        }
        return n;
    }

    fn slidingWindow(d: *Dpb, max_refs: u32) void {
        const n = d.counts();
        if (n[0] + n[1] < @max(max_refs, 1) or n[0] == 0) return;
        var victim: ?usize = null;
        for (d.pics, 0..) |p, i| {
            if (!p.used or !p.short) continue;
            if (victim == null or p.wrap < d.pics[victim.?].wrap) victim = i;
        }
        if (victim) |i| d.pics[i].short = false;
    }

    fn removeUnused(d: *Dpb) void {
        for (&d.pics) |*p| {
            if (p.used and !p.ref() and !p.output) p.* = .{};
        }
    }

    fn bump(d: *Dpb, out: *Outputs) bool {
        var best: ?usize = null;
        for (d.pics, 0..) |p, i| {
            if (!p.used or !p.output) continue;
            if (best == null or p.poc() < d.pics[best.?].poc()) best = i;
        }
        const i = best orelse return false;
        out.push(&d.pics[i]);
        d.pics[i].output = false;
        if (!d.pics[i].ref()) d.pics[i] = .{};
        return true;
    }

    fn waiting(d: *const Dpb) u32 {
        var n: u32 = 0;
        for (d.pics) |p| {
            if (p.used and p.output) n += 1;
        }
        return n;
    }

    fn used(d: *const Dpb) u32 {
        var n: u32 = 0;
        for (d.pics) |p| {
            if (p.used) n += 1;
        }
        return n;
    }

    fn slot(d: *Dpb, out: *Outputs) ?usize {
        while (true) {
            if (d.used() < d.size) {
                for (d.pics, 0..) |p, i| {
                    if (!p.used) return i;
                }
            }
            if (!d.bump(out)) return null;
        }
    }

    pub fn flush(d: *Dpb, out: *Outputs) void {
        while (d.bump(out)) {}
        d.removeUnused();
    }

    pub fn drop(d: *Dpb, out: *Outputs) void {
        for (&d.pics) |*p| {
            if (p.used and p.output) {
                out.push(p);
                out.items[out.count - 1].surface = INVALID;
                p.output = false;
            }
        }
        d.removeUnused();
    }

    pub fn surfaceBusy(d: *const Dpb, surface: u32) bool {
        for (d.pics) |p| {
            if (p.used and p.surface == surface) return true;
        }
        return false;
    }

    pub fn begin(d: *Dpb, sps: *const h.Sps, sl: *const h.Slice, out: *Outputs) void {
        d.max_frame_num = sps.maxFrameNum();
        if (sl.idr()) {
            for (&d.pics) |*p| {
                p.short = false;
                p.long = false;
            }
            if (sl.no_output_prior) d.drop(out) else d.flush(out);
            d.max_long = null;
            d.prev_ref_frame_num = 0;
        } else if (sl.frame_num != d.prev_ref_frame_num and sl.frame_num != (d.prev_ref_frame_num + 1) % d.max_frame_num) {
            d.gaps(sps, sl, out);
        }
        d.cur = .{ .used = true, .frame_num = sl.frame_num, .output = true };
        d.poc(sps, sl);
        d.wraps(sl.frame_num);
    }

    fn gaps(d: *Dpb, sps: *const h.Sps, sl: *const h.Slice, out: *Outputs) void {
        var n = (d.prev_ref_frame_num + 1) % d.max_frame_num;
        var guard: u32 = 0;
        while (n != sl.frame_num and guard < d.max_frame_num) : (guard += 1) {
            d.wraps(n);
            d.slidingWindow(sps.max_refs);
            d.removeUnused();
            const i = d.slot(out) orelse return;
            var fake = h.Slice{ .frame_num = n, .nal_ref = 1 };
            fake.nal_type = h.NAL_SLICE;
            d.cur = .{ .used = true, .frame_num = n, .short = true, .nonexisting = true };
            if (sps.poc_type != 0) d.poc(sps, &fake);
            d.pics[i] = d.cur;
            d.prev_frame_num = n;
            d.prev_ref_frame_num = n;
            d.prev_offset = d.cur_offset;
            d.prev_mmco5 = false;
            n = (n + 1) % d.max_frame_num;
        }
    }

    fn sortBy(d: *const Dpb, l: []u8, comptime key: fn (*const Dpb, u8) i64) void {
        std.mem.sort(u8, l, d, struct {
            fn lt(dd: *const Dpb, a: u8, b: u8) bool {
                return key(dd, a) < key(dd, b);
            }
        }.lt);
    }

    fn keyNumDesc(d: *const Dpb, i: u8) i64 {
        return -@as(i64, d.pics[i].wrap);
    }

    fn keyLong(d: *const Dpb, i: u8) i64 {
        return d.pics[i].long_idx;
    }

    fn keyPoc(d: *const Dpb, i: u8) i64 {
        return d.pics[i].poc();
    }

    fn keyPocDesc(d: *const Dpb, i: u8) i64 {
        return -@as(i64, d.pics[i].poc());
    }

    pub fn lists(d: *const Dpb, sps: *const h.Sps, sl: *const h.Slice, l0: *List, l1: *List) void {
        l0.count = 0;
        l1.count = 0;
        if (sl.kind == h.I or sl.kind == h.SI) return;
        var short: [MAX]u8 = undefined;
        var ns: usize = 0;
        var long: [MAX]u8 = undefined;
        var nl: usize = 0;
        for (d.pics, 0..) |p, i| {
            if (!p.used) continue;
            if (p.short and !(p.nonexisting and (sl.kind == h.B and sps.poc_type == 0))) {
                short[ns] = @intCast(i);
                ns += 1;
            } else if (p.long) {
                long[nl] = @intCast(i);
                nl += 1;
            }
        }
        d.sortBy(long[0..nl], keyLong);
        if (sl.kind != h.B) {
            d.sortBy(short[0..ns], keyNumDesc);
            append(l0, short[0..ns]);
            append(l0, long[0..nl]);
        } else {
            const cur = d.cur.poc();
            var before: [MAX]u8 = undefined;
            var nb: usize = 0;
            var after: [MAX]u8 = undefined;
            var na: usize = 0;
            for (short[0..ns]) |i| {
                if (d.pics[i].poc() < cur) {
                    before[nb] = i;
                    nb += 1;
                } else {
                    after[na] = i;
                    na += 1;
                }
            }
            d.sortBy(before[0..nb], keyPocDesc);
            d.sortBy(after[0..na], keyPoc);
            append(l0, before[0..nb]);
            append(l0, after[0..na]);
            append(l0, long[0..nl]);
            append(l1, after[0..na]);
            append(l1, before[0..nb]);
            append(l1, long[0..nl]);
            if (l1.count > 1 and std.mem.eql(u8, l0.idx[0..l0.count], l1.idx[0..l1.count])) std.mem.swap(u8, &l1.idx[0], &l1.idx[1]);
        }
        l0.count = @min(l0.count, sl.l0 + 1);
        l1.count = if (sl.kind == h.B) @min(l1.count, sl.l1 + 1) else 0;
        d.modify(sl, 0, l0);
        if (sl.kind == h.B) d.modify(sl, 1, l1);
    }

    fn append(l: *List, items: []const u8) void {
        for (items) |i| {
            if (l.count < l.idx.len) {
                l.idx[l.count] = i;
                l.count += 1;
            }
        }
    }

    fn modify(d: *const Dpb, sl: *const h.Slice, which: usize, l: *List) void {
        const ops = sl.mods[which][0..sl.mod_count[which]];
        if (ops.len == 0) return;
        const active: usize = (if (which == 0) sl.l0 else sl.l1) + 1;
        var full: [34]u8 = .{0xff} ** 34;
        @memcpy(full[0..l.count], l.idx[0..l.count]);
        const max_pic: i32 = @intCast(d.max_frame_num);
        const cur_num: i32 = @intCast(sl.frame_num);
        var pred = cur_num;
        var ref_idx: usize = 0;
        for (ops) |op| {
            var target: ?u8 = null;
            if (op.idc == 0 or op.idc == 1) {
                const diff: i32 = @intCast(op.value + 1);
                var no_wrap: i32 = if (op.idc == 0) pred - diff else pred + diff;
                if (op.idc == 0 and no_wrap < 0) no_wrap += max_pic;
                if (op.idc == 1 and no_wrap >= max_pic) no_wrap -= max_pic;
                pred = no_wrap;
                const num = if (no_wrap > cur_num) no_wrap - max_pic else no_wrap;
                for (d.pics, 0..) |p, i| {
                    if (p.used and p.short and p.wrap == num) target = @intCast(i);
                }
            } else if (op.idc == 2) {
                for (d.pics, 0..) |p, i| {
                    if (p.used and p.long and p.long_idx == op.value) target = @intCast(i);
                }
            } else continue;
            const t = target orelse continue;
            var c = active;
            while (c > ref_idx) : (c -= 1) full[c] = full[c - 1];
            full[ref_idx] = t;
            ref_idx += 1;
            var n = ref_idx;
            for (ref_idx..active + 1) |k| {
                if (full[k] != t) {
                    full[n] = full[k];
                    n += 1;
                }
            }
        }
        l.count = 0;
        for (full[0..active]) |i| {
            if (l.count < l.idx.len) {
                l.idx[l.count] = i;
                l.count += 1;
            }
        }
    }

    pub fn finish(d: *Dpb, sps: *const h.Sps, sl: *const h.Slice, surface: u32, frame: u32, out: *Outputs) void {
        d.cur.surface = surface;
        d.cur.frame = frame;
        const mmco5 = sl.hasMmco5();
        if (sl.nal_ref != 0) {
            if (sl.idr()) {
                if (sl.long_ref) {
                    d.cur.long = true;
                    d.cur.long_idx = 0;
                    d.max_long = 0;
                } else d.cur.short = true;
            } else if (sl.adaptive) {
                d.mmcos(sl);
                if (!d.cur.long) d.cur.short = true;
            } else {
                d.slidingWindow(sps.max_refs);
                d.cur.short = true;
            }
        }
        if (mmco5) {
            const temp = d.cur.poc();
            d.cur.top -= temp;
            d.cur.bottom -= temp;
            d.cur.frame_num = 0;
            d.flush(out);
        }
        d.removeUnused();
        if (sl.nal_ref == 0 and d.used() >= d.size) {
            var lowest = true;
            for (d.pics) |p| {
                if (p.used and p.output and p.poc() < d.cur.poc()) lowest = false;
            }
            if (lowest) {
                out.push(&d.cur);
                d.cur.output = false;
            }
        }
        if (d.cur.output or d.cur.ref()) {
            if (d.slot(out)) |i| d.pics[i] = d.cur;
        }
        while (d.waiting() > d.reorder) _ = d.bump(out);
        if (sl.nal_ref != 0) {
            d.prev_ref_frame_num = if (mmco5) 0 else sl.frame_num;
            d.prev_msb = if (mmco5) 0 else d.cur_msb;
            d.prev_lsb = if (mmco5) d.cur.top else @intCast(sl.poc_lsb);
        }
        d.prev_frame_num = if (mmco5) 0 else sl.frame_num;
        d.prev_offset = d.cur_offset;
        d.prev_mmco5 = mmco5;
    }

    fn mmcos(d: *Dpb, sl: *const h.Slice) void {
        const cur_num: i32 = @intCast(sl.frame_num);
        for (sl.mmco[0..sl.mmco_count]) |m| {
            switch (m.op) {
                1 => {
                    const x = cur_num - @as(i32, @intCast(m.diff + 1));
                    for (&d.pics) |*p| {
                        if (p.used and p.short and p.wrap == x) p.short = false;
                    }
                },
                2 => for (&d.pics) |*p| {
                    if (p.used and p.long and p.long_idx == m.long_num) p.long = false;
                },
                3 => {
                    const x = cur_num - @as(i32, @intCast(m.diff + 1));
                    for (&d.pics) |*p| {
                        if (p.used and p.long and p.long_idx == m.long_idx) p.long = false;
                    }
                    for (&d.pics) |*p| {
                        if (p.used and p.short and p.wrap == x) {
                            p.short = false;
                            p.long = true;
                            p.long_idx = m.long_idx;
                        }
                    }
                },
                4 => {
                    for (&d.pics) |*p| {
                        if (p.used and p.long and (m.max_plus1 == 0 or p.long_idx > m.max_plus1 - 1)) p.long = false;
                    }
                    d.max_long = if (m.max_plus1 == 0) null else m.max_plus1 - 1;
                },
                5 => {
                    for (&d.pics) |*p| {
                        p.short = false;
                        p.long = false;
                    }
                    d.max_long = null;
                },
                6 => {
                    for (&d.pics) |*p| {
                        if (p.used and p.long and p.long_idx == m.long_idx) p.long = false;
                    }
                    d.cur.long = true;
                    d.cur.long_idx = m.long_idx;
                },
                else => {},
            }
        }
    }
};

test "the clip comes out in presentation order" {
    const data = @embedFile("clip.h264");
    var spss: [32]?h.Sps = .{null} ** 32;
    var ppss: [256]?h.Pps = .{null} ** 256;
    var it = h.Iter{ .data = data };
    var rb: h.Rbsp = .{};
    var d = Dpb{};
    var out = Outputs{};
    var order: [64]i32 = undefined;
    var n: usize = 0;
    var pocs: [64]i32 = undefined;
    var frame: u32 = 0;
    var l0 = List{};
    var l1 = List{};
    var configured = false;
    while (it.next()) |nal| {
        if (nal.len == 0) continue;
        switch (nal[0] & 0x1f) {
            h.NAL_SPS => {
                rb.load(nal, std.math.maxInt(usize));
                const s = try h.parseSps(rb.bytes()[1..]);
                spss[s.id] = s;
            },
            h.NAL_PPS => {
                rb.load(nal, std.math.maxInt(usize));
                const p = try h.parsePps(rb.bytes()[1..], &spss);
                ppss[p.id] = p;
            },
            h.NAL_SLICE, h.NAL_IDR => {
                rb.load(nal, 512);
                const sl = try h.parseSlice(&rb, &spss, &ppss);
                const sps = &spss[ppss[sl.pps].?.sps].?;
                if (!configured) {
                    d.configure(sps);
                    configured = true;
                }
                out.count = 0;
                d.begin(sps, &sl, &out);
                d.lists(sps, &sl, &l0, &l1);
                if (sl.kind == h.P) try std.testing.expect(l0.count > 0);
                if (sl.kind == h.B) try std.testing.expect(l1.count > 0);
                pocs[frame] = d.cur.poc();
                d.finish(sps, &sl, frame, frame, &out);
                frame += 1;
                for (out.items[0..out.count]) |o| {
                    order[n] = pocs[o.frame];
                    n += 1;
                }
            },
            else => {},
        }
    }
    out.count = 0;
    d.flush(&out);
    for (out.items[0..out.count]) |o| {
        order[n] = pocs[o.frame];
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 30), n);
    for (order[0..n], 0..) |p, i| try std.testing.expectEqual(@as(i32, @intCast((i % 10) * 2)), p);
    try std.testing.expectEqual(@as(u32, 2), d.reorder);
}
