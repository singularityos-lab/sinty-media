const cm = @import("../common.zig");
const c = cm.c;

pub const P = c.GstAudioChannelPosition;

const FL = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT;
const FR = c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT;
const FC = c.GST_AUDIO_CHANNEL_POSITION_FRONT_CENTER;
const RL = c.GST_AUDIO_CHANNEL_POSITION_REAR_LEFT;
const RR = c.GST_AUDIO_CHANNEL_POSITION_REAR_RIGHT;
const RC = c.GST_AUDIO_CHANNEL_POSITION_REAR_CENTER;
const SL = c.GST_AUDIO_CHANNEL_POSITION_SIDE_LEFT;
const SR = c.GST_AUDIO_CHANNEL_POSITION_SIDE_RIGHT;
const LFE = c.GST_AUDIO_CHANNEL_POSITION_LFE1;
const MONO = c.GST_AUDIO_CHANNEL_POSITION_MONO;
const INV = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT;

pub const positions = [8][8]P{
    .{ MONO, INV, INV, INV, INV, INV, INV, INV },
    .{ FL, FR, INV, INV, INV, INV, INV, INV },
    .{ FL, FC, FR, INV, INV, INV, INV, INV },
    .{ FL, FR, RL, RR, INV, INV, INV, INV },
    .{ FL, FC, FR, RL, RR, INV, INV, INV },
    .{ FL, FC, FR, RL, RR, LFE, INV, INV },
    .{ FL, FC, FR, SL, SR, RC, LFE, INV },
    .{ FL, FC, FR, SL, SR, RL, RR, LFE },
};

pub const Layout = struct { streams: u8, coupled: u8, mapping: [8]u8 };

pub const vorbis_map = [8]Layout{
    .{ .streams = 1, .coupled = 0, .mapping = .{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    .{ .streams = 1, .coupled = 1, .mapping = .{ 0, 1, 0, 0, 0, 0, 0, 0 } },
    .{ .streams = 2, .coupled = 1, .mapping = .{ 0, 2, 1, 0, 0, 0, 0, 0 } },
    .{ .streams = 2, .coupled = 2, .mapping = .{ 0, 1, 2, 3, 0, 0, 0, 0 } },
    .{ .streams = 3, .coupled = 2, .mapping = .{ 0, 4, 1, 2, 3, 0, 0, 0 } },
    .{ .streams = 4, .coupled = 2, .mapping = .{ 0, 4, 1, 2, 3, 5, 0, 0 } },
    .{ .streams = 4, .coupled = 3, .mapping = .{ 0, 4, 1, 2, 3, 5, 6, 0 } },
    .{ .streams = 5, .coupled = 3, .mapping = .{ 0, 6, 1, 2, 3, 4, 5, 7 } },
};

pub fn isHeader(b: [*c]c.GstBuffer, magic: [*c]const u8, n: usize) bool {
    return c.gst_buffer_get_size(b) >= n and c.gst_buffer_memcmp(b, 0, magic, n) == 0;
}

pub fn isIdHeader(b: [*c]c.GstBuffer) bool {
    if (c.gst_buffer_get_size(b) < 19) return false;
    if (!isHeader(b, "OpusHead", 8)) return false;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &map);
    const d = map.data;
    if (d[8] >= 0x0f) return false;
    const ch = d[9];
    if (ch == 0) return false;
    if (d[18] == 0) return ch <= 2;
    if (map.size < 21 + @as(usize, ch)) return false;
    const ns = d[19];
    const nc = d[20];
    if (ns == 0 or nc > ns) return false;
    return @as(u32, ns) + nc <= 255;
}

var once: usize = 0;

pub fn elementInit() void {
    if (c.g_once_init_enter(&once) != 0) {
        c.gst_tag_register_musicbrainz_tags();
        c.g_once_init_leave(&once, 1);
    }
}
