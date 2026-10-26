const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Stats = c.GstWebRTCICECandidateStats;
const Candidate = c.GstWebRTCICECandidate;
const Pair = c.GstWebRTCICECandidatePair;

var stats_once: gtype.Once = .{};
var candidate_once: gtype.Once = .{};
var pair_once: gtype.Once = .{};

pub export fn gst_webrtc_ice_candidate_stats_free(stats: [*c]Stats) void {
    if (stats != null) {
        c.g_free(stats.*.ipaddr);
        c.g_free(stats.*.url);
        c.g_free(stats.*.ABI.abi.foundation);
        c.g_free(stats.*.ABI.abi.related_address);
        c.g_free(stats.*.ABI.abi.username_fragment);
    }
    c.g_free(stats);
}

pub export fn gst_webrtc_ice_candidate_stats_copy(stats: [*c]Stats) [*c]Stats {
    if (stats == null) return null;
    const s: *Stats = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Stats))));
    s.* = stats.*;
    s.ipaddr = c.g_strdup(stats.*.ipaddr);
    s.url = c.g_strdup(stats.*.url);
    s.ABI.abi.foundation = c.g_strdup(stats.*.ABI.abi.foundation);
    s.ABI.abi.related_address = c.g_strdup(stats.*.ABI.abi.related_address);
    s.ABI.abi.username_fragment = c.g_strdup(stats.*.ABI.abi.username_fragment);
    return s;
}

pub export fn gst_webrtc_ice_candidate_stats_get_type() c.GType {
    return stats_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstWebRTCICECandidateStats", @ptrCast(&gst_webrtc_ice_candidate_stats_copy), @ptrCast(&gst_webrtc_ice_candidate_stats_free));
        }
    }.f);
}

pub export fn gst_webrtc_ice_candidate_free(candidate: [*c]Candidate) void {
    if (candidate != null) {
        c.g_free(candidate.*.candidate);
        gst_webrtc_ice_candidate_stats_free(candidate.*.stats);
        c.g_free(candidate.*.sdp_mid);
    }
    c.g_free(candidate);
}

pub export fn gst_webrtc_ice_candidate_copy(candidate: [*c]Candidate) [*c]Candidate {
    if (candidate == null) return null;
    const r: *Candidate = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Candidate))));
    r.* = candidate.*;
    r.candidate = c.g_strdup(candidate.*.candidate);
    r.stats = gst_webrtc_ice_candidate_stats_copy(candidate.*.stats);
    r.sdp_mid = c.g_strdup(candidate.*.sdp_mid);
    return r;
}

pub export fn gst_webrtc_ice_candidate_get_type() c.GType {
    return candidate_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstWebRTCICECandidate", @ptrCast(&gst_webrtc_ice_candidate_copy), @ptrCast(&gst_webrtc_ice_candidate_free));
        }
    }.f);
}

pub export fn gst_webrtc_ice_candidate_pair_free(pair: [*c]Pair) void {
    if (pair != null) {
        gst_webrtc_ice_candidate_free(pair.*.local);
        gst_webrtc_ice_candidate_free(pair.*.remote);
    }
    c.g_free(pair);
}

pub export fn gst_webrtc_ice_candidate_pair_copy(pair: [*c]Pair) [*c]Pair {
    if (pair == null) return null;
    const r: *Pair = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Pair))));
    r.local = gst_webrtc_ice_candidate_copy(pair.*.local);
    r.remote = gst_webrtc_ice_candidate_copy(pair.*.remote);
    return r;
}

pub export fn gst_webrtc_ice_candidate_pair_get_type() c.GType {
    return pair_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstWebRTCICECandidatePair", @ptrCast(&gst_webrtc_ice_candidate_pair_copy), @ptrCast(&gst_webrtc_ice_candidate_pair_free));
        }
    }.f);
}
