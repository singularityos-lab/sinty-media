const std = @import("std");

const SEC: u64 = 1_000_000_000;
const MS: u64 = 1_000_000;
const US: u64 = 1_000;
const MASTER: u64 = 0x1122334455667788;
const OFFSET: u64 = 5000 * SEC;

fn writeAll(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) std.c.exit(0);
        off += @intCast(n);
    }
}

fn readAll(fd: c_int, data: []u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.read(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn sleepMs(ms: u64) void {
    var ts = std.c.timespec{ .sec = 0, .nsec = @intCast(ms * MS) };
    _ = std.c.nanosleep(&ts, null);
}

const Out = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn u8_(o: *Out, v: u8) void {
        o.buf[o.len] = v;
        o.len += 1;
    }

    fn u16_(o: *Out, v: u16) void {
        std.mem.writeInt(u16, o.buf[o.len..][0..2], v, .big);
        o.len += 2;
    }

    fn u32_(o: *Out, v: u32) void {
        std.mem.writeInt(u32, o.buf[o.len..][0..4], v, .big);
        o.len += 4;
    }

    fn u64_(o: *Out, v: u64) void {
        std.mem.writeInt(u64, o.buf[o.len..][0..8], v, .big);
        o.len += 8;
    }

    fn stamp(o: *Out, t: u64) void {
        const s = t / SEC;
        o.u32_(@truncate(s >> 16));
        o.u16_(@truncate(s));
        o.u32_(@truncate(t % SEC));
    }
};

fn header(o: *Out, kind: u8, version: u8, length: u16, domain: u8, flags: u16, corr: i64, clock: u64, port: u16, seq: u16, interval: i8) void {
    o.u8_(kind);
    o.u8_(version);
    o.u16_(length);
    o.u8_(domain);
    o.u8_(0);
    o.u16_(flags);
    o.u64_(@bitCast(corr));
    o.u32_(0);
    o.u64_(clock);
    o.u16_(port);
    o.u16_(seq);
    o.u8_(0);
    o.u8_(@bitCast(interval));
}

fn frame(kind: u8, recv: u64, msg: *Out) void {
    var o = Out{};
    o.u16_(@intCast(1 + 8 + msg.len));
    o.u8_(kind);
    o.u8_(0);
    o.u64_(recv);
    @memcpy(o.buf[o.len .. o.len + msg.len], msg.buf[0..msg.len]);
    o.len += msg.len;
    writeAll(1, o.buf[0..o.len]);
}

fn announce(seq: u16, recv: u64, clock: u64, prio1: u8, gm: u64) void {
    var m = Out{};
    header(&m, 0xB, 2, 64, 0, 0, 0, clock, 1, seq, 0);
    m.stamp(recv + OFFSET);
    m.u16_(37);
    m.u8_(0);
    m.u8_(prio1);
    m.u8_(248);
    m.u8_(0xfe);
    m.u16_(0xffff);
    m.u8_(128);
    m.u64_(gm);
    m.u16_(0);
    m.u8_(0xa0);
    frame(1, recv, &m);
}

fn sync(seq: u16, recv: u64, two_step: bool, remote: u64, corr: i64) void {
    var m = Out{};
    header(&m, 0x0, 2, 44, 0, if (two_step) 0x0200 else 0, corr, MASTER, 1, seq, -3);
    m.stamp(if (two_step) 0 else remote);
    frame(0, recv, &m);
}

fn followUp(seq: u16, recv: u64, remote: u64, corr: i64) void {
    var m = Out{};
    header(&m, 0x8, 2, 44, 0, 0, corr, MASTER, 1, seq, -3);
    m.stamp(remote);
    frame(1, recv, &m);
}

fn delayResp(seq: u16, recv: u64, remote: u64, req_clock: u64, req_port: u16) void {
    var m = Out{};
    header(&m, 0x9, 2, 54, 0, 0, 1 << 15, MASTER, 1, seq, -10);
    m.stamp(remote);
    m.u64_(req_clock);
    m.u16_(req_port);
    frame(1, recv, &m);
}

fn ack(sent: u64, seq: u16) void {
    var o = Out{};
    o.u16_(12);
    o.u8_(3);
    o.u64_(sent);
    o.u8_(1);
    o.u8_(0);
    o.u16_(seq);
    writeAll(1, o.buf[0..o.len]);
}

fn raw(kind: u8, payload: []const u8) void {
    var o = Out{};
    o.u16_(@intCast(payload.len));
    o.u8_(kind);
    @memcpy(o.buf[o.len .. o.len + payload.len], payload);
    o.len += payload.len;
    writeAll(1, o.buf[0..o.len]);
}

pub fn main() void {
    var id = Out{};
    id.u64_(0xa1a2a3a4a5a6a7a8);
    raw(2, id.buf[0..8]);
    sleepMs(50);
    const t0: u64 = 1000 * SEC;
    announce(1, t0, MASTER, 128, 0xaabbccddeeff0011);
    announce(1, t0 + 10 * MS, 0x99, 200, 0x55);
    announce(2, t0 + SEC, MASTER, 128, 0xaabbccddeeff0011);
    announce(2, t0 + SEC + 10 * MS, 0x99, 200, 0x55);
    announce(2, t0 + SEC + 20 * MS, MASTER, 128, 0xaabbccddeeff0011);
    raw(0, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    var bad = Out{};
    header(&bad, 0x0, 3, 44, 0, 0, 0, MASTER, 1, 77, 0);
    bad.stamp(0);
    frame(0, t0, &bad);
    sleepMs(30);
    var base = t0 + 2 * SEC;
    var req: [56]u8 = undefined;
    for (0..14) |k| {
        const seq: u16 = @intCast(k + 10);
        const local = base;
        const remote = local + OFFSET - 100 * US + @as(u64, k) * 7 * US;
        const two = k % 3 != 2;
        sync(seq, local, two, remote, @as(i64, @intCast(k)) * 65536 * 3);
        if (two) followUp(seq, local + MS, remote, 65536 * 5);
        if (k == 6) sync(200, local + MS, true, 0, 0);
        if (k == 9) followUp(seq, local + 2 * MS, remote, 0);
        if (!readAll(0, &req)) return;
        const dseq = std.mem.readInt(u16, req[42..44], .big);
        const rclock = std.mem.readInt(u64, req[32..40], .big);
        const rport = std.mem.readInt(u16, req[40..42], .big);
        const sent = local + 2 * MS + @as(u64, k % 4) * 50 * US;
        ack(sent, dseq);
        const path = 100 * US + @as(u64, k % 5) * 3 * US + if (k == 11) 2 * MS else 0;
        delayResp(dseq, local + 4 * MS, sent + OFFSET - 100 * US + path, rclock, rport);
        if (k == 12) delayResp(dseq, local + 5 * MS, sent + OFFSET, rclock, rport);
        sleepMs(25);
        base += 125 * MS;
    }
    sleepMs(100);
    var tail: [1]u8 = undefined;
    _ = std.c.read(0, &tail, 1);
}
