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
const Z = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT;

pub const positions = [8][8]P{
    .{ MONO, Z, Z, Z, Z, Z, Z, Z },
    .{ FL, FR, Z, Z, Z, Z, Z, Z },
    .{ FL, FC, FR, Z, Z, Z, Z, Z },
    .{ FL, FR, RL, RR, Z, Z, Z, Z },
    .{ FL, FC, FR, RL, RR, Z, Z, Z },
    .{ FL, FC, FR, RL, RR, LFE, Z, Z },
    .{ FL, FC, FR, SL, SR, RC, LFE, Z },
    .{ FL, FC, FR, SL, SR, RL, RR, LFE },
};

pub const default_positions = [8][8]P{
    .{ MONO, Z, Z, Z, Z, Z, Z, Z },
    .{ FL, FR, Z, Z, Z, Z, Z, Z },
    .{ FL, FR, FC, Z, Z, Z, Z, Z },
    .{ FL, FR, RL, RR, Z, Z, Z, Z },
    .{ FL, FR, FC, RL, RR, Z, Z, Z },
    .{ FL, FR, FC, LFE, RL, RR, Z, Z },
    .{ FL, FR, FC, LFE, RC, SL, SR, Z },
    .{ FL, FR, FC, LFE, RL, RR, SL, SR },
};

pub const reorder = [8][8]u8{
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 0, 0, 0, 0 },
    .{ 0, 2, 1, 0, 0, 0, 0, 0 },
    .{ 0, 1, 2, 3, 0, 0, 0, 0 },
    .{ 0, 2, 1, 3, 4, 0, 0, 0 },
    .{ 0, 2, 1, 5, 3, 4, 0, 0 },
    .{ 0, 2, 1, 6, 5, 3, 4, 0 },
    .{ 0, 2, 1, 7, 5, 6, 3, 4 },
};

var once: c.gsize = 0;

pub fn elementInit() void {
    if (c.g_once_init_enter(&once) != 0) {
        c.gst_tag_register_musicbrainz_tags();
        c.g_once_init_leave(&once, 1);
    }
}
