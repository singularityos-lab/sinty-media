const std = @import("std");
const c = @cImport({
    @cInclude("web-import.h");
});

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const PAGE =
    \\<!doctype html><html><body>
    \\<video id="v" src="clip.webm" muted autoplay playsinline></video>
    \\<canvas id="k" width="64" height="48"></canvas>
    \\<script>
    \\const v = document.getElementById("v");
    \\const types = ['video/webm; codecs="vp8, opus"', 'video/webm; codecs="vp9"', 'video/mp4; codecs="avc1.42E01E, mp4a.40.2"', 'video/mp4; codecs="av01.0.05M.08"', 'audio/ogg; codecs="opus"', 'audio/ogg; codecs="vorbis"', 'audio/mpeg', 'audio/flac', 'audio/wav', 'video/ogg; codecs="theora"', 'application/vnd.apple.mpegurl'];
    \\const r = { can: types.map(t => t + "=" + v.canPlayType(t)), mse: types.map(t => t + "=" + (window.MediaSource ? MediaSource.isTypeSupported(t) : "none")), events: [] };
    \\["loadedmetadata", "loadeddata", "canplay", "playing", "seeked", "ended", "error"].forEach(e => v.addEventListener(e, () => { if (!r.events.includes(e)) r.events.push(e); }));
    \\function finish() {
    \\  r.ready = v.readyState; r.w = v.videoWidth; r.h = v.videoHeight; r.duration = Math.round(v.duration * 1000);
    \\  r.ended = v.ended; r.error = v.error ? v.error.code : 0; r.buffered = v.buffered.length;
    \\  const k = document.getElementById("k").getContext("2d");
    \\  k.drawImage(v, 0, 0, 64, 48);
    \\  const d = k.getImageData(0, 0, 64, 48).data;
    \\  let s = 0; for (let i = 0; i < d.length; i++) s = (s * 31 + d[i]) % 1000000007;
    \\  r.pixels = s; r.corner = Array.from(d.slice(0, 8));
    \\  document.title = "RESULT " + JSON.stringify(r);
    \\}
    \\v.addEventListener("ended", () => { v.currentTime = 0.5; v.addEventListener("seeked", () => setTimeout(finish, 200), { once: true }); }, { once: true });
    \\v.addEventListener("error", finish);
    \\setTimeout(finish, 12000);
    \\</script></body></html>
;

const MSE =
    \\<!doctype html><html><body>
    \\<video id="v" muted playsinline></video>
    \\<canvas id="k" width="64" height="48"></canvas>
    \\<script>
    \\const v = document.getElementById("v");
    \\const r = { events: [] };
    \\["loadedmetadata", "canplay", "playing", "seeked", "ended", "error"].forEach(e => v.addEventListener(e, () => { if (!r.events.includes(e)) r.events.push(e); }));
    \\function finish() {
    \\  r.ready = v.readyState; r.w = v.videoWidth; r.h = v.videoHeight; r.duration = Math.round(v.duration * 1000);
    \\  r.error = v.error ? v.error.code : 0; r.buffered = v.buffered.length ? [Math.round(v.buffered.start(0) * 1000), Math.round(v.buffered.end(0) * 1000)] : [];
    \\  const k = document.getElementById("k").getContext("2d");
    \\  k.drawImage(v, 0, 0, 64, 48);
    \\  const d = k.getImageData(0, 0, 64, 48).data;
    \\  let s = 0; for (let i = 0; i < d.length; i++) s = (s * 31 + d[i]) % 1000000007;
    \\  r.pixels = s;
    \\  document.title = "RESULT " + JSON.stringify(r);
    \\}
    \\const ms = new MediaSource();
    \\v.src = URL.createObjectURL(ms);
    \\ms.addEventListener("sourceopen", () => {
    \\  r.open = ms.readyState;
    \\  const sb = ms.addSourceBuffer('video/webm; codecs="vp9"');
    \\  fetch("clip-vp9.webm").then(x => x.arrayBuffer()).then(b => {
    \\    r.bytes = b.byteLength;
    \\    sb.addEventListener("updateend", () => { r.updated = true; ms.endOfStream(); v.play().catch(e => { r.play = String(e); }); }, { once: true });
    \\    sb.appendBuffer(b);
    \\  }).catch(e => { r.fetch = String(e); finish(); });
    \\});
    \\v.addEventListener("ended", () => { v.currentTime = 1.0; v.addEventListener("seeked", () => setTimeout(finish, 200), { once: true }); }, { once: true });
    \\v.addEventListener("error", finish);
    \\setTimeout(finish, 12000);
    \\</script></body></html>
;

const AUDIO =
    \\<!doctype html><html><body>
    \\<script>
    \\const files = ["tone.flac", "tone.mp3", "tone.opus.ogg"];
    \\const r = {};
    \\let left = files.length;
    \\function done() { if (--left === 0) document.title = "RESULT " + JSON.stringify(r); }
    \\files.forEach(f => {
    \\  const a = new Audio(f);
    \\  a.muted = true;
    \\  const e = r[f] = { events: [] };
    \\  ["loadedmetadata", "playing", "ended", "error"].forEach(n => a.addEventListener(n, () => e.events.push(n)));
    \\  a.addEventListener("ended", () => { e.duration = Math.round(a.duration * 100); e.played = a.played.length; done(); });
    \\  a.addEventListener("error", () => { e.error = a.error.code; done(); });
    \\  a.play().catch(x => { e.play = String(x); });
    \\});
    \\setTimeout(() => { left = 1; done(); }, 12000);
    \\</script></body></html>
;

const PAGES = [_][*:0]const u8{ PAGE, MSE, AUDIO };
var page: usize = 0;
var base_uri: [*:0]const u8 = "";

var loop: ?*c.GMainLoop = null;

fn titleChanged(view: ?*c.WebKitWebView, _: ?*c.GParamSpec, _: c.gpointer) callconv(.c) void {
    const t = c.webkit_web_view_get_title(view);
    if (t == null) return;
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(t)));
    if (!std.mem.startsWith(u8, s, "RESULT ")) return;
    var it = std.mem.splitSequence(u8, s[7..], "\",\"");
    out("page {d}", .{page});
    while (it.next()) |part| out("{s}", .{part});
    page += 1;
    if (page == PAGES.len) {
        c.g_main_loop_quit(loop);
        return;
    }
    c.webkit_web_view_load_html(view, PAGES[page], base_uri);
}

fn timeout(_: c.gpointer) callconv(.c) c.gboolean {
    out("timeout", .{});
    c.g_main_loop_quit(loop);
    return 0;
}

pub fn main() void {
    _ = c.setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1", 1);
    _ = c.setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", 1);
    c.gtk_init();
    var cwd: [4096]u8 = undefined;
    if (c.getcwd(&cwd, cwd.len) == null) return;
    const dir = std.mem.sliceTo(&cwd, 0);
    var base: [4200]u8 = undefined;
    const uri = std.fmt.bufPrintZ(&base, "file://{s}/tests/data/", .{dir}) catch return;
    const policies = c.webkit_website_policies_new_with_policies("autoplay", @as(c_int, c.WEBKIT_AUTOPLAY_ALLOW), @as(?*anyopaque, null));
    const view: *c.WebKitWebView = @ptrCast(@alignCast(c.g_object_new(c.webkit_web_view_get_type(), "website-policies", policies, @as(?*anyopaque, null))));
    const settings = c.webkit_web_view_get_settings(view);
    c.webkit_settings_set_enable_media(settings, 1);
    c.webkit_settings_set_allow_file_access_from_file_urls(settings, 1);
    c.webkit_settings_set_media_playback_requires_user_gesture(settings, 0);
    const win = c.gtk_window_new();
    c.gtk_window_set_default_size(@ptrCast(win), 320, 240);
    c.gtk_window_set_child(@ptrCast(win), @ptrCast(view));
    c.gtk_window_present(@ptrCast(win));
    _ = c.g_signal_connect_data(view, "notify::title", @ptrCast(&titleChanged), null, null, 0);
    base_uri = uri.ptr;
    c.webkit_web_view_load_html(view, PAGES[0], uri.ptr);
    loop = c.g_main_loop_new(null, 0);
    _ = c.g_timeout_add_seconds(50, timeout, null);
    c.g_main_loop_run(loop);
    out("done", .{});
}
