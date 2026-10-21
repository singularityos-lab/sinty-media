const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const m = @import("../libm.zig");
const format = @import("format.zig");
const color = @import("color.zig");
const chroma = @import("chroma.zig");
const scaler = @import("scaler.zig");
const dither = @import("dither.zig");
const meta = @import("meta.zig");
const fast = @import("convfast.zig");

comptime {
    @import("../abi.zig").check(@This());
}

pub const Info = c.GstVideoInfo;
pub const Frame = c.GstVideoFrame;
const Opaque = c.GstVideoConverter;

pub const SCALE = 8;
const SCALE_F: f32 = 256.0;
const BACKLOG = 2;

pub const TaskFunc = *const fn (c.gpointer) void;

const WorkItem = struct { runner: *Runner, func: TaskFunc, data: c.gpointer };

pub const Runner = struct {
    pool: *c.GstTaskPool,
    own_pool: bool,
    n_threads: c.guint,
    tasks: ?*c.GstVecDeque,
    work_items: ?*c.GstVecDeque,
    lock: c.GMutex,
    async_tasks: bool,
};

fn threadFunc(data: c.gpointer) callconv(.c) void {
    const r: *Runner = @ptrCast(@alignCast(data));
    c.g_mutex_lock(&r.lock);
    const w: ?*WorkItem = @ptrCast(@alignCast(c.gst_vec_deque_pop_head(r.work_items)));
    c.g_mutex_unlock(&r.lock);
    const item = w.?;
    item.func(item.data);
    if (r.async_tasks) c.g_free(item);
}

fn runnerJoin(r: *Runner) void {
    while (true) {
        c.g_mutex_lock(&r.lock);
        if (c.gst_vec_deque_is_empty(r.tasks) != 0) {
            c.g_mutex_unlock(&r.lock);
            return;
        }
        const task = c.gst_vec_deque_pop_head(r.tasks);
        c.g_mutex_unlock(&r.lock);
        c.gst_task_pool_join(r.pool, task);
    }
}

fn runnerFree(r: *Runner) void {
    runnerJoin(r);
    c.gst_vec_deque_free(r.work_items);
    c.gst_vec_deque_free(r.tasks);
    if (r.own_pool) c.gst_task_pool_cleanup(r.pool);
    c.gst_object_unref(r.pool);
    c.g_mutex_clear(&r.lock);
    c.g_free(r);
}

fn isSharedPool(pool: *c.GstTaskPool) bool {
    return c.g_type_check_instance_is_a(@ptrCast(pool), c.gst_shared_task_pool_get_type()) != 0;
}

fn runnerNew(n_in: c.guint, pool: ?*c.GstTaskPool, async_tasks: bool) *Runner {
    var n = n_in;
    if (n == 0) n = c.g_get_num_processors();
    const r: *Runner = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Runner))));
    if (pool) |p| {
        r.pool = @ptrCast(@alignCast(c.g_object_ref(p)));
        r.own_pool = false;
        if (isSharedPool(p)) n = @min(n, c.gst_shared_task_pool_get_max_threads(@ptrCast(p)));
    } else {
        r.pool = c.gst_shared_task_pool_new();
        r.own_pool = true;
        c.gst_shared_task_pool_set_max_threads(@ptrCast(r.pool), n);
        c.gst_task_pool_prepare(r.pool, null);
    }
    r.tasks = c.gst_vec_deque_new(n);
    r.work_items = c.gst_vec_deque_new(n);
    r.n_threads = n;
    c.g_mutex_init(&r.lock);
    r.async_tasks = async_tasks;
    return r;
}

pub fn runnerRun(r: *Runner, func: TaskFunc, data: [*]c.gpointer) void {
    const n = r.n_threads;
    var items: [64]WorkItem = undefined;
    if (n > 1 or r.async_tasks) {
        var i: c.guint = if (r.async_tasks) 0 else 1;
        c.g_mutex_lock(&r.lock);
        while (i < n) : (i += 1) {
            const w: *WorkItem = if (r.async_tasks) @ptrCast(@alignCast(c.g_malloc0(@sizeOf(WorkItem)))) else &items[i];
            w.* = .{ .runner = r, .func = func, .data = data[i] };
            c.gst_vec_deque_push_tail(r.work_items, w);
            const task = c.gst_task_pool_push(r.pool, threadFunc, r, null);
            c.gst_vec_deque_push_tail(r.tasks, task);
        }
        c.g_mutex_unlock(&r.lock);
    }
    if (!r.async_tasks) {
        func(data[0]);
        runnerJoin(r);
    }
}

pub const NeedFn = *const fn (*LineCache, c.gint, c.gint, c.gint, *Converter) bool;
pub const AllocFn = *const fn (*LineCache, c.gint, c.gpointer) c.gpointer;

pub const LineCache = struct {
    first: c.gint = 0,
    backlog: c.gint = 0,
    lines: *c.GPtrArray,
    prev: ?*LineCache,
    write_input: bool = false,
    pass_alloc: bool = false,
    alloc_writable: bool = false,
    need_line: ?NeedFn = null,
    need_line_idx: c.gint = 0,
    need_line_data: ?*Converter = null,
    n_lines: c.guint = 0,
    stride: c.guint = 0,
    alloc_line: ?AllocFn = null,
    alloc_line_data: c.gpointer = null,
    alloc_line_notify: ?*const fn (c.gpointer) void = null,
};

fn cacheNew(prev: ?*LineCache) *LineCache {
    const r: *LineCache = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(LineCache))));
    r.* = .{ .lines = c.g_ptr_array_new(), .prev = prev };
    return r;
}

fn cacheClear(cache: *LineCache) void {
    c.g_ptr_array_set_size(cache.lines, 0);
    cache.first = 0;
}

fn cacheFree(cache: *LineCache) void {
    if (cache.alloc_line_notify) |n| n(cache.alloc_line_data);
    cacheClear(cache);
    c.g_ptr_array_unref(cache.lines);
    c.g_free(cache);
}

fn len(cache: *LineCache) c.gint {
    return @bitCast(cache.lines.*.len);
}

pub fn getLines(cache: *LineCache, idx: c.gint, out_line: c.gint, in_line: c.gint, n_lines: c.gint) ?[*]c.gpointer {
    if (cache.first + cache.backlog < in_line) {
        const want: c.guint = @bitCast(in_line - (cache.first + cache.backlog));
        const to_remove: c.gint = @bitCast(@min(want, cache.lines.*.len));
        if (to_remove > 0) _ = c.g_ptr_array_remove_range(cache.lines, 0, @bitCast(to_remove));
        cache.first += to_remove;
    } else if (in_line < cache.first) {
        cacheClear(cache);
        cache.first = in_line;
    }
    while (true) {
        if (cache.first <= in_line and in_line + n_lines <= cache.first + len(cache))
            return @ptrCast(cache.lines.*.pdata + @as(usize, @intCast(in_line - cache.first)));
        const need = cache.need_line orelse break;
        if (len(cache) == 0 and cache.first + cache.backlog < in_line) cache.first = in_line - cache.backlog;
        const oline = out_line +% cache.first +% len(cache) -% in_line;
        if (!need(cache, idx, oline, cache.first + len(cache), cache.need_line_data.?)) break;
    }
    return null;
}

fn addLine(cache: *LineCache, idx: c.gint, line: c.gpointer) void {
    if (cache.first +% len(cache) != idx) {
        cacheClear(cache);
        cache.first = idx;
    }
    c.g_ptr_array_add(cache.lines, line);
}

fn allocLine(cache: *LineCache, idx: c.gint) c.gpointer {
    if (cache.alloc_line) |f| return f(cache, idx, cache.alloc_line_data);
    return null;
}

const Alloc = struct {
    data: [*]u8,
    stride: c.guint,
    n_lines: c.guint,
    idx: c.guint,
    user_data: *Converter,
};

fn allocNew(stride: c.guint, n_lines: c.guint, conv: *Converter) *Alloc {
    const a: *Alloc = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Alloc))));
    a.* = .{ .data = @ptrCast(c.g_malloc(stride *% n_lines)), .stride = stride, .n_lines = n_lines, .idx = 0, .user_data = conv };
    return a;
}

fn allocFree(p: c.gpointer) void {
    const a: *Alloc = @ptrCast(@alignCast(p));
    c.g_free(a.data);
    c.g_free(a);
}

fn tempLine(_: *LineCache, _: c.gint, user_data: c.gpointer) c.gpointer {
    const a: *Alloc = @ptrCast(@alignCast(user_data));
    const line = a.data + a.stride * a.idx;
    a.idx = (a.idx + 1) % a.n_lines;
    return line;
}

fn borderTempLine(_: *LineCache, _: c.gint, user_data: c.gpointer) c.gpointer {
    const a: *Alloc = @ptrCast(@alignCast(user_data));
    const conv = a.user_data;
    const line = a.data + a.stride * a.idx + @as(usize, @intCast(conv.out_x * conv.pack_pstride));
    a.idx = (a.idx + 1) % a.n_lines;
    return line;
}

pub const MatrixFn = *const fn (*MatrixData, c.gpointer) void;

pub const MatrixData = struct {
    dm: [4][4]f64 = std.mem.zeroes([4][4]f64),
    im: [4][4]c.gint = std.mem.zeroes([4][4]c.gint),
    width: c.gint = 0,
    orc_p1: u64 = 0,
    orc_p2: u64 = 0,
    orc_p3: u64 = 0,
    orc_p4: u64 = 0,
    t_r: ?[*]i64 = null,
    t_g: ?[*]i64 = null,
    t_b: ?[*]i64 = null,
    t_c: i64 = 0,
    matrix_func: ?MatrixFn = null,
};

const GammaFn = *const fn (*Gamma, c.gpointer, c.gpointer) void;

const Gamma = struct {
    table: ?*anyopaque = null,
    width: c.gint = 0,
    func: ?GammaFn = null,
};

pub const ALPHA_NONE: c_int = 0;
pub const ALPHA_COPY: c_int = 1;
pub const ALPHA_SET: c_int = 2;
pub const ALPHA_MULT: c_int = 4;

pub const FastFn = *const fn (*Converter, *const Frame, *Frame, c.gint) void;
pub const ConvFn = *const fn (*Converter, *const Frame, *Frame) void;
const AlphaFn = *const fn (*Converter, c.gpointer, c.gint) void;

fn PerThread(comptime T: type) type {
    return ?[*]?*T;
}

pub const Converter = struct {
    flags: c.gint = 0,
    in_info: Info,
    out_info: Info,
    in_x: c.gint = 0,
    in_y: c.gint = 0,
    in_width: c.gint = 0,
    in_height: c.gint = 0,
    in_maxwidth: c.gint = 0,
    in_maxheight: c.gint = 0,
    out_x: c.gint = 0,
    out_y: c.gint = 0,
    out_width: c.gint = 0,
    out_height: c.gint = 0,
    out_maxwidth: c.gint = 0,
    out_maxheight: c.gint = 0,
    current_pstride: c.gint = 0,
    current_width: c.gint = 0,
    current_height: c.gint = 0,
    current_format: c.GstVideoFormat = 0,
    current_bits: c.gint = 0,
    config: ?*c.GstStructure = null,
    runner: ?*Runner = null,
    tmpline: ?[*][*]u16 = null,
    fill_border: bool = false,
    borderline: ?[*]u8 = null,
    borders: [4]u64 = .{ 0, 0, 0, 0 },
    border_argb: u32 = 0,
    alpha_value: u32 = 0,
    alpha_mode: c_int = 0,
    convert: ?ConvFn = null,
    unpack_lines: PerThread(LineCache) = null,
    unpack_format: c.GstVideoFormat = 0,
    unpack_bits: c.guint = 0,
    unpack_rgb: bool = false,
    identity_unpack: bool = false,
    unpack_pstride: c.gint = 0,
    upsample_lines: PerThread(LineCache) = null,
    upsample: PerThread(c.GstVideoChromaResample) = null,
    upsample_p: PerThread(c.GstVideoChromaResample) = null,
    upsample_i: PerThread(c.GstVideoChromaResample) = null,
    up_n_lines: c.guint = 0,
    up_offset: c.gint = 0,
    to_RGB_lines: PerThread(LineCache) = null,
    to_RGB_matrix: MatrixData = .{},
    gamma_dec: Gamma = .{},
    hscale_lines: PerThread(LineCache) = null,
    h_scaler: PerThread(c.GstVideoScaler) = null,
    h_scale_format: c.GstVideoFormat = 0,
    vscale_lines: PerThread(LineCache) = null,
    v_scaler: PerThread(c.GstVideoScaler) = null,
    v_scaler_p: PerThread(c.GstVideoScaler) = null,
    v_scaler_i: PerThread(c.GstVideoScaler) = null,
    v_scale_width: c.gint = 0,
    v_scale_format: c.GstVideoFormat = 0,
    convert_lines: PerThread(LineCache) = null,
    convert_matrix: MatrixData = .{},
    in_bits: c.gint = 0,
    out_bits: c.gint = 0,
    alpha_lines: PerThread(LineCache) = null,
    alpha_func: ?AlphaFn = null,
    gamma_enc: Gamma = .{},
    to_YUV_lines: PerThread(LineCache) = null,
    to_YUV_matrix: MatrixData = .{},
    downsample_lines: PerThread(LineCache) = null,
    downsample: PerThread(c.GstVideoChromaResample) = null,
    downsample_p: PerThread(c.GstVideoChromaResample) = null,
    downsample_i: PerThread(c.GstVideoChromaResample) = null,
    down_n_lines: c.guint = 0,
    down_offset: c.gint = 0,
    dither_lines: PerThread(LineCache) = null,
    dither: PerThread(c.GstVideoDither) = null,
    pack_lines: PerThread(LineCache) = null,
    pack_nlines: c.guint = 0,
    pack_format: c.GstVideoFormat = 0,
    pack_bits: c.guint = 0,
    pack_rgb: bool = false,
    identity_pack: bool = false,
    pack_pstride: c.gint = 0,
    pack_pal: c.gconstpointer = null,
    pack_palsize: c.gsize = 0,
    src: ?*const Frame = null,
    dest: ?*Frame = null,
    fformat: [4]c.GstVideoFormat = .{ 0, 0, 0, 0 },
    fin_x: [4]c.gint = .{ 0, 0, 0, 0 },
    fin_y: [4]c.gint = .{ 0, 0, 0, 0 },
    fout_x: [4]c.gint = .{ 0, 0, 0, 0 },
    fout_y: [4]c.gint = .{ 0, 0, 0, 0 },
    fout_width: [4]c.gint = .{ 0, 0, 0, 0 },
    fout_height: [4]c.gint = .{ 0, 0, 0, 0 },
    fsplane: [4]c.gint = .{ 0, 0, 0, 0 },
    ffill: [4]c.gint = .{ 0, 0, 0, 0 },
    fh_scaler: [4]PerThread(c.GstVideoScaler) = .{ null, null, null, null },
    fv_scaler: [4]PerThread(c.GstVideoScaler) = .{ null, null, null, null },
    fconvert: [4]?FastFn = .{ null, null, null, null },
    tasks: [4]c.gpointer = .{ null, null, null, null },
    tasks_p: [4]c.gpointer = .{ null, null, null, null },
};

fn of(p: ?*Opaque) *Converter {
    return @ptrCast(@alignCast(p.?));
}

pub fn nThreads(conv: *const Converter) c.guint {
    return conv.runner.?.n_threads;
}

fn newArray(comptime T: type, n: c.guint) [*]?*T {
    return @ptrCast(@alignCast(c.g_malloc0(@sizeOf(?*T) * n)));
}

pub fn optInt(conv: *Converter, opt: [*c]const u8, def: c.gint) c.gint {
    var r: c.gint = 0;
    if (c.gst_structure_get_int(conv.config, opt, &r) == 0) return def;
    return r;
}

pub fn optUint(conv: *Converter, opt: [*c]const u8, def: c.guint) c.guint {
    var r: c.guint = 0;
    if (c.gst_structure_get_uint(conv.config, opt, &r) == 0) return def;
    return r;
}

fn optDouble(conv: *Converter, opt: [*c]const u8, def: f64) f64 {
    var r: f64 = 0;
    if (c.gst_structure_get_double(conv.config, opt, &r) == 0) return def;
    return r;
}

fn optBool(conv: *Converter, opt: [*c]const u8, def: bool) bool {
    var r: c.gboolean = 0;
    if (c.gst_structure_get_boolean(conv.config, opt, &r) == 0) return def;
    return r != 0;
}

fn optEnum(conv: *Converter, opt: [*c]const u8, t: c.GType, def: c.gint) c.gint {
    var r: c.gint = 0;
    if (c.gst_structure_get_enum(conv.config, opt, t, &r) == 0) return def;
    return r;
}

pub fn alphaMode(conv: *Converter) c.gint {
    return optEnum(conv, c.GST_VIDEO_CONVERTER_OPT_ALPHA_MODE, c.gst_video_alpha_mode_get_type(), c.GST_VIDEO_ALPHA_MODE_COPY);
}

pub fn matrixMode(conv: *Converter) c.gint {
    return optEnum(conv, c.GST_VIDEO_CONVERTER_OPT_MATRIX_MODE, c.gst_video_matrix_mode_get_type(), c.GST_VIDEO_MATRIX_MODE_FULL);
}

pub fn gammaMode(conv: *Converter) c.gint {
    return optEnum(conv, c.GST_VIDEO_CONVERTER_OPT_GAMMA_MODE, c.gst_video_gamma_mode_get_type(), c.GST_VIDEO_GAMMA_MODE_NONE);
}

pub fn primariesMode(conv: *Converter) c.gint {
    return optEnum(conv, c.GST_VIDEO_CONVERTER_OPT_PRIMARIES_MODE, c.gst_video_primaries_mode_get_type(), c.GST_VIDEO_PRIMARIES_MODE_NONE);
}

fn chromaMode(conv: *Converter) c.gint {
    return optEnum(conv, c.GST_VIDEO_CONVERTER_OPT_CHROMA_MODE, c.gst_video_chroma_mode_get_type(), c.GST_VIDEO_CHROMA_MODE_FULL);
}

pub fn resamplerMethod(conv: *Converter) c.gint {
    return optEnum(conv, c.GST_VIDEO_CONVERTER_OPT_RESAMPLER_METHOD, c.gst_video_resampler_method_get_type(), c.GST_VIDEO_RESAMPLER_METHOD_CUBIC);
}

pub fn chromaResamplerMethod(conv: *Converter) c.gint {
    return optEnum(conv, c.GST_VIDEO_CONVERTER_OPT_CHROMA_RESAMPLER_METHOD, c.gst_video_resampler_method_get_type(), c.GST_VIDEO_RESAMPLER_METHOD_LINEAR);
}

pub fn resamplerTaps(conv: *Converter) c.guint {
    return optUint(conv, c.GST_VIDEO_CONVERTER_OPT_RESAMPLER_TAPS, 0);
}

pub fn ditherQuantization(conv: *Converter) c.guint {
    return optUint(conv, c.GST_VIDEO_CONVERTER_OPT_DITHER_QUANTIZATION, 1);
}

fn alphaValue(conv: *Converter) f64 {
    return optDouble(conv, c.GST_VIDEO_CONVERTER_OPT_ALPHA_VALUE, 1.0);
}

fn chainUnpack(conv: *Converter, idx: usize) *LineCache {
    const info = &conv.in_info;
    conv.current_format = conv.unpack_format;
    conv.current_bits = @bitCast(conv.unpack_bits);
    conv.current_pstride = conv.current_bits >> 1;
    conv.unpack_pstride = conv.current_pstride;
    conv.identity_unpack = conv.current_format == info.finfo[0].format;
    const prev = cacheNew(null);
    conv.unpack_lines.?[idx] = prev;
    prev.write_input = false;
    prev.pass_alloc = false;
    prev.n_lines = 1;
    prev.stride = @bitCast(conv.current_pstride *% conv.current_width);
    setNeed(prev, doUnpack, idx, conv);
    return prev;
}

fn setNeed(cache: *LineCache, f: NeedFn, idx: usize, conv: *Converter) void {
    cache.need_line = f;
    cache.need_line_idx = @intCast(idx);
    cache.need_line_data = conv;
}

fn chainUpsample(conv: *Converter, prev_in: *LineCache, idx: usize) *LineCache {
    var prev = prev_in;
    computeResample(conv, idx);
    if (conv.upsample_p.?[idx] != null or conv.upsample_i.?[idx] != null) {
        prev = cacheNew(prev);
        conv.upsample_lines.?[idx] = prev;
        prev.write_input = true;
        prev.pass_alloc = true;
        prev.n_lines = 5;
        prev.stride = @bitCast(conv.current_pstride *% conv.current_width);
        setNeed(prev, doUpsample, idx, conv);
    }
    return prev;
}

pub fn setIdentity(mtx: *MatrixData) void {
    for (0..4) |i| for (0..4) |j| {
        mtx.dm[i][j] = if (i == j) 1 else 0;
    };
}

fn multiply(dst: *MatrixData, a: *const MatrixData, b: *const MatrixData) void {
    var tmp: [4][4]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        var x: f64 = 0;
        for (0..4) |k| x += a.dm[i][k] * b.dm[k][j];
        tmp[i][j] = x;
    };
    dst.dm = tmp;
}

fn invert(d: *MatrixData, s: *const MatrixData) void {
    var tmp = MatrixData{};
    setIdentity(&tmp);
    for (0..3) |j| for (0..3) |i| {
        tmp.dm[j][i] = s.dm[(i + 1) % 3][(j + 1) % 3] * s.dm[(i + 2) % 3][(j + 2) % 3] - s.dm[(i + 1) % 3][(j + 2) % 3] * s.dm[(i + 2) % 3][(j + 1) % 3];
    };
    const det = tmp.dm[0][0] * s.dm[0][0] + tmp.dm[0][1] * s.dm[1][0] + tmp.dm[0][2] * s.dm[2][0];
    for (0..3) |j| for (0..3) |i| {
        tmp.dm[i][j] /= det;
    };
    d.dm = tmp.dm;
}

fn offsetComponents(mtx: *MatrixData, a1: f64, a2: f64, a3: f64) void {
    var a = MatrixData{};
    setIdentity(&a);
    a.dm[0][3] = a1;
    a.dm[1][3] = a2;
    a.dm[2][3] = a3;
    multiply(mtx, &a, mtx);
}

fn scaleComponents(mtx: *MatrixData, a1: f64, a2: f64, a3: f64) void {
    var a = MatrixData{};
    setIdentity(&a);
    a.dm[0][0] = a1;
    a.dm[1][1] = a2;
    a.dm[2][2] = a3;
    multiply(mtx, &a, mtx);
}

fn toInt(x: f64) c.gint {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(c.gint);
    return @intFromFloat(x);
}

pub fn matrixConvert(s: *MatrixData) void {
    for (0..4) |i| for (0..4) |j| {
        s.im[i][j] = toInt(m.rint(s.dm[i][j]));
    };
}

fn ycbcrToRgb(mtx: *MatrixData, kr: f64, kb: f64) void {
    const kg = 1.0 - kr - kb;
    var k = MatrixData{};
    k.dm = .{
        .{ 1.0, 0.0, 2 * (1 - kr), 0.0 },
        .{ 1.0, -2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg, 0.0 },
        .{ 1.0, 2 * (1 - kb), 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    };
    multiply(mtx, &k, mtx);
}

fn rgbToYcbcr(mtx: *MatrixData, kr: f64, kb: f64) void {
    const kg = 1.0 - kr - kb;
    var k = MatrixData{};
    k.dm[0] = .{ kr, kg, kb, 0 };
    var x = 1 / (2 * (1 - kb));
    k.dm[1] = .{ -x * kr, -x * kg, x * (1 - kb), 0 };
    x = 1 / (2 * (1 - kr));
    k.dm[2] = .{ x * (1 - kr), -x * kg, -x * kb, 0 };
    k.dm[3] = .{ 0, 0, 0, 1 };
    multiply(mtx, &k, mtx);
}

fn rgbToXyz(dst: *MatrixData, rx: f64, ry: f64, gx: f64, gy: f64, bx: f64, by: f64, wxin: f64, wyin: f64) void {
    var mtx = MatrixData{};
    var im = MatrixData{};
    setIdentity(&mtx);
    mtx.dm[0][0] = rx;
    mtx.dm[1][0] = ry;
    mtx.dm[2][0] = 1.0 - rx - ry;
    mtx.dm[0][1] = gx;
    mtx.dm[1][1] = gy;
    mtx.dm[2][1] = 1.0 - gx - gy;
    mtx.dm[0][2] = bx;
    mtx.dm[1][2] = by;
    mtx.dm[2][2] = 1.0 - bx - by;
    invert(&im, &mtx);
    const wx = wxin / wyin;
    const wy = 1.0;
    const wz = (1.0 - wxin - wyin) / wyin;
    const sx = im.dm[0][0] * wx + im.dm[0][1] * wy + im.dm[0][2] * wz;
    const sy = im.dm[1][0] * wx + im.dm[1][1] * wy + im.dm[1][2] * wz;
    const sz = im.dm[2][0] * wx + im.dm[2][1] * wy + im.dm[2][2] * wz;
    for (0..3) |r| {
        mtx.dm[r][0] *= sx;
        mtx.dm[r][1] *= sy;
        mtx.dm[r][2] *= sz;
    }
    dst.dm = mtx.dm;
}

fn initTables(data: *MatrixData) void {
    const tr: [*]i64 = @ptrCast(@alignCast(c.g_malloc(@sizeOf(i64) * 256)));
    const tg: [*]i64 = @ptrCast(@alignCast(c.g_malloc(@sizeOf(i64) * 256)));
    const tb: [*]i64 = @ptrCast(@alignCast(c.g_malloc(@sizeOf(i64) * 256)));
    for (0..256) |i| {
        var r: i64 = 0;
        var g: i64 = 0;
        var b: i64 = 0;
        const v: i64 = @intCast(i);
        for (0..3) |j| {
            r = (r << 16) +% @as(i64, data.im[j][0]) * v;
            g = (g << 16) +% @as(i64, data.im[j][1]) * v;
            b = (b << 16) +% @as(i64, data.im[j][2]) * v;
        }
        tr[i] = r;
        tg[i] = g;
        tb[i] = b;
    }
    data.t_r = tr;
    data.t_g = tg;
    data.t_b = tb;
    data.t_c = (@as(i64, data.im[0][3]) << 32) +% (@as(i64, data.im[1][3]) << 16) +% @as(i64, data.im[2][3]);
}

fn mulhsw(a: i16, b: i16) i16 {
    return @truncate((@as(i32, a) * b) >> 16);
}

fn ssb(x: i16) i8 {
    return @intCast(std.math.clamp(x, -128, 127));
}

fn splat(b: u8) i16 {
    return @bitCast(@as(u16, b) | @as(u16, b) << 8);
}

fn lanes(p: u64) [4]i16 {
    return .{ @bitCast(@as(u16, @truncate(p))), @bitCast(@as(u16, @truncate(p >> 16))), @bitCast(@as(u16, @truncate(p >> 32))), @bitCast(@as(u16, @truncate(p >> 48))) };
}

fn matrix8(data: *MatrixData, pixels: c.gpointer) void {
    const p: [*]u8 = @ptrCast(pixels);
    const p1 = lanes(data.orc_p1);
    const p2 = lanes(data.orc_p2);
    const p3 = lanes(data.orc_p3);
    for (0..@intCast(data.width)) |i| {
        const px = p + i * 4;
        const sa = px[0] -% 128;
        const sr = splat(px[1] -% 128);
        const sg = splat(px[2] -% 128);
        const sb = splat(px[3] -% 128);
        var aq = [4]i16{ splat(sa), 0, 0, 0 };
        for (0..4) |l| {
            aq[l] +%= mulhsw(sr, p1[l]);
            aq[l] +%= mulhsw(sg, p2[l]);
            aq[l] +%= mulhsw(sb, p3[l]);
        }
        for (0..4) |l| px[l] = @as(u8, @bitCast(ssb(aq[l]))) +% 128;
    }
}

fn matrix8Table(data: *MatrixData, pixels: c.gpointer) void {
    const p: [*]u8 = @ptrCast(pixels);
    const cc = data.t_c;
    var i: usize = 0;
    while (i < @as(usize, @intCast(data.width)) * 4) : (i += 4) {
        const x = data.t_r.?[p[i + 1]] +% data.t_g.?[p[i + 2]] +% data.t_b.?[p[i + 3]] +% cc;
        p[i + 1] = @truncate(@as(u64, @bitCast(x >> (32 + SCALE))));
        p[i + 2] = @truncate(@as(u64, @bitCast(x >> (16 + SCALE))));
        p[i + 3] = @truncate(@as(u64, @bitCast(x >> SCALE)));
    }
}

pub fn yuvRgb(y: u8, u: u8, v: u8, k: [5]i16) [3]u8 {
    const wy = mulhsw(splat(y -% 128), k[0]);
    const wu = splat(u -% 128);
    const wv = splat(v -% 128);
    const r = ssb(wy +% mulhsw(wv, k[1]));
    const b = ssb(wy +% mulhsw(wu, k[2]));
    const g = ssb(wy +% mulhsw(wu, k[3]) +% mulhsw(wv, k[4]));
    return .{ @as(u8, @bitCast(r)) +% 128, @as(u8, @bitCast(g)) +% 128, @as(u8, @bitCast(b)) +% 128 };
}

pub fn ayuvToArgb(d: [*]u8, s: [*]const u8, n: usize, k: [5]i16) void {
    for (0..n) |i| {
        const px = s + i * 4;
        const rgb = yuvRgb(px[1], px[2], px[3], k);
        const o = d + i * 4;
        o[0] = px[0];
        o[1] = rgb[0];
        o[2] = rgb[1];
        o[3] = rgb[2];
    }
}

pub fn ayuvKeys(data: *const MatrixData) [5]i16 {
    return .{ @truncate(data.im[0][0]), @truncate(data.im[0][2]), @truncate(data.im[2][1]), @truncate(data.im[1][1]), @truncate(data.im[1][2]) };
}

fn matrix8Ayuv(data: *MatrixData, pixels: c.gpointer) void {
    const p: [*]u8 = @ptrCast(pixels);
    ayuvToArgb(p, p, @intCast(data.width), ayuvKeys(data));
}

fn isAyuvToRgb(data: *const MatrixData) bool {
    if (data.im[0][0] != data.im[1][0] or data.im[1][0] != data.im[2][0]) return false;
    if (data.im[0][1] != 0 or data.im[2][2] != 0) return false;
    return true;
}

fn isIdentity(data: *const MatrixData) bool {
    const cc = data.im[0][0];
    for (0..4) |i| for (0..4) |j| {
        if (i == j) {
            if (i == 3 and data.im[i][j] != 1) return false;
            if (i != 3 and data.im[i][j] != cc) return false;
        } else if (data.im[i][j] != 0) return false;
    };
    return true;
}

fn isNoClip(data: *const MatrixData) bool {
    const tests = [8][3]c.gint{ .{ 0, 0, 0 }, .{ 0, 0, 255 }, .{ 0, 255, 0 }, .{ 0, 255, 255 }, .{ 255, 0, 0 }, .{ 255, 0, 255 }, .{ 255, 255, 0 }, .{ 255, 255, 255 } };
    for (tests) |t| {
        for (0..3) |row| {
            const v = (data.im[row][0] *% t[0] +% data.im[row][1] *% t[1] +% data.im[row][2] *% t[2] +% data.im[row][3]) >> SCALE;
            if (v < 0 or v > 255) return false;
        }
    }
    return true;
}

fn matrix16(data: *MatrixData, pixels: c.gpointer) void {
    const p: [*]align(1) u16 = @ptrCast(pixels);
    for (0..@intCast(data.width)) |i| {
        const r: c.gint = p[i * 4 + 1];
        const g: c.gint = p[i * 4 + 2];
        const b: c.gint = p[i * 4 + 3];
        for (0..3) |row| {
            const v = (data.im[row][0] *% r +% data.im[row][1] *% g +% data.im[row][2] *% b +% data.im[row][3]) >> SCALE;
            p[i * 4 + 1 + row] = @intCast(std.math.clamp(v, 0, 65535));
        }
    }
}

fn prepareMatrix(conv: *Converter, data: *MatrixData) void {
    if (isIdentity(data)) return;
    scaleComponents(data, SCALE_F, SCALE_F, SCALE_F);
    matrixConvert(data);
    data.width = conv.current_width;
    if (conv.current_bits == 8) {
        if (!conv.unpack_rgb and conv.pack_rgb and isAyuvToRgb(data)) {
            data.matrix_func = matrix8Ayuv;
        } else if (isNoClip(data)) {
            data.matrix_func = matrix8Table;
            initTables(data);
        } else {
            data.matrix_func = matrix8;
            const w = struct {
                fn f(v: c.gint) u64 {
                    return @as(u16, @truncate(@as(u32, @bitCast(v))));
                }
            }.f;
            data.orc_p1 = w(data.im[2][0]) << 48 | w(data.im[1][0]) << 32 | w(data.im[0][0]) << 16;
            data.orc_p2 = w(data.im[2][1]) << 48 | w(data.im[1][1]) << 32 | w(data.im[0][1]) << 16;
            data.orc_p3 = w(data.im[2][2]) << 48 | w(data.im[1][2]) << 32 | w(data.im[0][2]) << 16;
            data.orc_p4 = w(data.im[2][3] >> SCALE) << 48 | w(data.im[1][3] >> SCALE) << 32 | w(data.im[0][3] >> SCALE) << 16;
        }
    } else data.matrix_func = matrix16;
}

fn fl(v: c.gint) f64 {
    return @as(f32, @floatFromInt(v));
}

fn inv(v: c.gint) f64 {
    return 1.0 / @as(f32, @floatFromInt(v));
}

pub fn matrixToRgb(conv: *Converter, data: *MatrixData) void {
    var info = &conv.in_info;
    var off: [4]c.gint = undefined;
    var sc: [4]c.gint = undefined;
    color.gst_video_color_range_offsets(info.colorimetry.range, format.get(conv.unpack_format), &off, &sc);
    offsetComponents(data, @floatFromInt(-off[0]), @floatFromInt(-off[1]), @floatFromInt(-off[2]));
    scaleComponents(data, inv(sc[0]), inv(sc[1]), inv(sc[2]));
    if (!conv.unpack_rgb and matrixMode(conv) != c.GST_VIDEO_MATRIX_MODE_NONE) {
        if (matrixMode(conv) == c.GST_VIDEO_MATRIX_MODE_OUTPUT_ONLY) info = &conv.out_info;
        var kr: f64 = 0;
        var kb: f64 = 0;
        if (color.gst_video_color_matrix_get_Kr_Kb(info.colorimetry.matrix, &kr, &kb) != 0) ycbcrToRgb(data, kr, kb);
    }
}

pub fn matrixToYuv(conv: *Converter, data: *MatrixData, force: bool) void {
    if (force or (!conv.pack_rgb and matrixMode(conv) != c.GST_VIDEO_MATRIX_MODE_NONE)) {
        const info = if (matrixMode(conv) == c.GST_VIDEO_MATRIX_MODE_INPUT_ONLY) &conv.in_info else &conv.out_info;
        var kr: f64 = 0;
        var kb: f64 = 0;
        if (color.gst_video_color_matrix_get_Kr_Kb(info.colorimetry.matrix, &kr, &kb) != 0) rgbToYcbcr(data, kr, kb);
    }
    var off: [4]c.gint = undefined;
    var sc: [4]c.gint = undefined;
    color.gst_video_color_range_offsets(conv.out_info.colorimetry.range, format.get(conv.pack_format), &off, &sc);
    scaleComponents(data, fl(sc[0]), fl(sc[1]), fl(sc[2]));
    offsetComponents(data, @floatFromInt(off[0]), @floatFromInt(off[1]), @floatFromInt(off[2]));
}

fn gamma8to16(g: *Gamma, dest: c.gpointer, src: c.gpointer) void {
    const s: [*]const u8 = @ptrCast(src);
    const d: [*]align(1) u16 = @ptrCast(dest);
    const t: [*]const u16 = @ptrCast(@alignCast(g.table.?));
    var i: usize = 0;
    while (i < @as(usize, @intCast(g.width)) * 4) : (i += 4) {
        d[i] = @as(u16, s[i]) << 8 | s[i];
        d[i + 1] = t[s[i + 1]];
        d[i + 2] = t[s[i + 2]];
        d[i + 3] = t[s[i + 3]];
    }
}

fn gamma16to8(g: *Gamma, dest: c.gpointer, src: c.gpointer) void {
    const s: [*]align(1) const u16 = @ptrCast(src);
    const d: [*]u8 = @ptrCast(dest);
    const t: [*]const u8 = @ptrCast(g.table.?);
    var i: usize = 0;
    while (i < @as(usize, @intCast(g.width)) * 4) : (i += 4) {
        d[i] = @truncate(s[i] >> 8);
        d[i + 1] = t[s[i + 1]];
        d[i + 2] = t[s[i + 2]];
        d[i + 3] = t[s[i + 3]];
    }
}

fn gamma16to16(g: *Gamma, dest: c.gpointer, src: c.gpointer) void {
    const s: [*]align(1) const u16 = @ptrCast(src);
    const d: [*]align(1) u16 = @ptrCast(dest);
    const t: [*]const u16 = @ptrCast(@alignCast(g.table.?));
    var i: usize = 0;
    while (i < @as(usize, @intCast(g.width)) * 4) : (i += 4) {
        d[i] = s[i];
        d[i + 1] = t[s[i + 1]];
        d[i + 2] = t[s[i + 2]];
        d[i + 3] = t[s[i + 3]];
    }
}

fn truncInt(x: f64) u32 {
    return @bitCast(toInt(x));
}

fn setupGammaDecode(conv: *Converter) void {
    const func = conv.in_info.colorimetry.transfer;
    conv.gamma_dec.width = conv.current_width;
    if (conv.gamma_dec.table != null) {} else if (conv.current_bits == 8) {
        conv.gamma_dec.func = gamma8to16;
        const t: [*]u16 = @ptrCast(@alignCast(c.g_malloc(@sizeOf(u16) * 256)));
        conv.gamma_dec.table = t;
        for (0..256) |i| t[i] = @truncate(truncInt(m.rint(color.gst_video_transfer_function_decode(func, @as(f64, @floatFromInt(i)) / 255.0) * 65535.0)));
    } else {
        conv.gamma_dec.func = gamma16to16;
        const t: [*]u16 = @ptrCast(@alignCast(c.g_malloc(@sizeOf(u16) * 65536)));
        conv.gamma_dec.table = t;
        for (0..65536) |i| t[i] = @truncate(truncInt(m.rint(color.gst_video_transfer_function_decode(func, @as(f64, @floatFromInt(i)) / 65535.0) * 65535.0)));
    }
    conv.current_bits = 16;
    conv.current_pstride = 8;
    conv.current_format = c.GST_VIDEO_FORMAT_ARGB64;
}

fn setupGammaEncode(conv: *Converter, target_bits: c.guint) void {
    const func = conv.out_info.colorimetry.transfer;
    conv.gamma_enc.width = conv.current_width;
    if (conv.gamma_enc.table != null) {} else if (target_bits == 8) {
        conv.gamma_enc.func = gamma16to8;
        const t: [*]u8 = @ptrCast(c.g_malloc(65536));
        conv.gamma_enc.table = t;
        for (0..65536) |i| t[i] = @truncate(truncInt(m.rint(color.gst_video_transfer_function_encode(func, @as(f64, @floatFromInt(i)) / 65535.0) * 255.0)));
    } else {
        conv.gamma_enc.func = gamma16to16;
        const t: [*]u16 = @ptrCast(@alignCast(c.g_malloc(@sizeOf(u16) * 65536)));
        conv.gamma_enc.table = t;
        for (0..65536) |i| t[i] = @truncate(truncInt(m.rint(color.gst_video_transfer_function_encode(func, @as(f64, @floatFromInt(i)) / 65535.0) * 65535.0)));
    }
}

fn gammaRemap(conv: *Converter) bool {
    return gammaMode(conv) == c.GST_VIDEO_GAMMA_MODE_REMAP;
}

fn chainToRgb(conv: *Converter, prev_in: *LineCache, idx: usize) *LineCache {
    var prev = prev_in;
    if (!gammaRemap(conv)) return prev;
    if (idx == 0 and !conv.unpack_rgb) {
        setIdentity(&conv.to_RGB_matrix);
        matrixToRgb(conv, &conv.to_RGB_matrix);
        const scale: c.gint = @as(c.gint, 1) << @intCast(conv.current_bits);
        scaleComponents(&conv.to_RGB_matrix, fl(scale), fl(scale), fl(scale));
        prepareMatrix(conv, &conv.to_RGB_matrix);
        conv.current_format = if (conv.current_bits == 8) c.GST_VIDEO_FORMAT_ARGB else c.GST_VIDEO_FORMAT_ARGB64;
    }
    prev = cacheNew(prev);
    conv.to_RGB_lines.?[idx] = prev;
    prev.write_input = true;
    prev.pass_alloc = false;
    prev.n_lines = 1;
    prev.stride = @bitCast(conv.current_pstride *% conv.current_width);
    setNeed(prev, doToRgb, idx, conv);
    setupGammaDecode(conv);
    return prev;
}

fn chainHscale(conv: *Converter, prev_in: *LineCache, idx: usize) *LineCache {
    const method = resamplerMethod(conv);
    var taps = resamplerTaps(conv);
    conv.h_scaler.?[idx] = scaler.gst_video_scaler_new(@bitCast(method), c.GST_VIDEO_SCALER_FLAG_NONE, taps, @bitCast(conv.in_width), @bitCast(conv.out_width), conv.config);
    _ = scaler.gst_video_scaler_get_coeff(conv.h_scaler.?[idx], 0, null, &taps);
    conv.current_width = conv.out_width;
    conv.h_scale_format = conv.current_format;
    const prev = cacheNew(prev_in);
    conv.hscale_lines.?[idx] = prev;
    prev.write_input = false;
    prev.pass_alloc = false;
    prev.n_lines = 1;
    prev.stride = @bitCast(conv.current_pstride *% conv.current_width);
    setNeed(prev, doHscale, idx, conv);
    return prev;
}

pub fn isInterlaced(info: *const Info) bool {
    return info.interlace_mode != c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE;
}

fn chainVscale(conv: *Converter, prev_in: *LineCache, idx: usize) *LineCache {
    const method = resamplerMethod(conv);
    var taps = resamplerTaps(conv);
    var taps_i: c.guint = 0;
    var backlog: c.gint = 0;
    if (isInterlaced(&conv.in_info) and conv.in_info.interlace_mode != c.GST_VIDEO_INTERLACE_MODE_ALTERNATE) {
        conv.v_scaler_i.?[idx] = scaler.gst_video_scaler_new(@bitCast(method), c.GST_VIDEO_SCALER_FLAG_INTERLACED, taps, @bitCast(conv.in_height), @bitCast(conv.out_height), conv.config);
        _ = scaler.gst_video_scaler_get_coeff(conv.v_scaler_i.?[idx], 0, null, &taps_i);
        backlog = @bitCast(taps_i);
    }
    conv.v_scaler_p.?[idx] = scaler.gst_video_scaler_new(@bitCast(method), 0, taps, @bitCast(conv.in_height), @bitCast(conv.out_height), conv.config);
    conv.v_scale_width = conv.current_width;
    conv.v_scale_format = conv.current_format;
    conv.current_height = conv.out_height;
    _ = scaler.gst_video_scaler_get_coeff(conv.v_scaler_p.?[idx], 0, null, &taps);
    prev_in.backlog = backlog;
    const prev = cacheNew(prev_in);
    conv.vscale_lines.?[idx] = prev;
    prev.pass_alloc = taps == 1;
    prev.write_input = false;
    prev.n_lines = @max(taps_i, taps);
    prev.stride = @bitCast(conv.current_pstride *% conv.current_width);
    setNeed(prev, doVscale, idx, conv);
    return prev;
}

fn chainScale(conv: *Converter, prev_in: *LineCache, force: bool, idx: usize) *LineCache {
    var prev = prev_in;
    const s0 = conv.current_width *% conv.current_height;
    const s3 = conv.out_width *% conv.out_height;
    if (s3 <= s0 or force) {
        const s1 = conv.out_width *% conv.current_height;
        const s2 = conv.current_width *% conv.out_height;
        if (s1 <= s2) {
            if (conv.current_width != conv.out_width) prev = chainHscale(conv, prev, idx);
            if (conv.current_height != conv.out_height) prev = chainVscale(conv, prev, idx);
        } else {
            if (conv.current_height != conv.out_height) prev = chainVscale(conv, prev, idx);
            if (conv.current_width != conv.out_width) prev = chainHscale(conv, prev, idx);
        }
    }
    return prev;
}

fn chainConvert(conv: *Converter, prev_in: *LineCache, idx: usize) *LineCache {
    var prev = prev_in;
    var pass_alloc = false;
    var do_conversion = false;
    const same_bits = conv.unpack_bits == conv.pack_bits;
    const same_matrix = matrixMode(conv) == c.GST_VIDEO_MATRIX_MODE_NONE or conv.in_info.colorimetry.matrix == conv.out_info.colorimetry.matrix;
    const same_primaries = primariesMode(conv) == c.GST_VIDEO_PRIMARIES_MODE_NONE or color.gst_video_color_primaries_is_equivalent(conv.in_info.colorimetry.primaries, conv.out_info.colorimetry.primaries) != 0;
    setIdentity(&conv.convert_matrix);
    if (!same_primaries) {
        var p1 = MatrixData{};
        var p2 = MatrixData{};
        var pi = color.gst_video_color_primaries_get_info(conv.in_info.colorimetry.primaries).?;
        rgbToXyz(&p1, pi.Rx, pi.Ry, pi.Gx, pi.Gy, pi.Bx, pi.By, pi.Wx, pi.Wy);
        multiply(&conv.convert_matrix, &conv.convert_matrix, &p1);
        pi = color.gst_video_color_primaries_get_info(conv.out_info.colorimetry.primaries).?;
        rgbToXyz(&p2, pi.Rx, pi.Ry, pi.Gx, pi.Gy, pi.Bx, pi.By, pi.Wx, pi.Wy);
        invert(&p2, &p2);
        multiply(&conv.convert_matrix, &p2, &conv.convert_matrix);
    }
    if (!gammaRemap(conv)) {
        conv.in_bits = @bitCast(conv.unpack_bits);
        conv.out_bits = @bitCast(conv.pack_bits);
        if (!same_bits or !same_matrix or !same_primaries) {
            if (conv.in_bits < conv.out_bits) {
                const scale: c.gint = @as(c.gint, 1) << @intCast(conv.out_bits - conv.in_bits);
                scaleComponents(&conv.convert_matrix, inv(scale), inv(scale), inv(scale));
            }
            matrixToRgb(conv, &conv.convert_matrix);
            matrixToYuv(conv, &conv.convert_matrix, false);
            if (conv.in_bits > conv.out_bits) {
                const scale: c.gint = @as(c.gint, 1) << @intCast(conv.in_bits - conv.out_bits);
                scaleComponents(&conv.convert_matrix, fl(scale), fl(scale), fl(scale));
            }
            conv.current_bits = @max(conv.in_bits, conv.out_bits);
            do_conversion = true;
            if ((!same_matrix or !same_primaries) and idx == 0) prepareMatrix(conv, &conv.convert_matrix);
            if (conv.in_bits == conv.out_bits) pass_alloc = true;
        }
        conv.current_bits = @bitCast(conv.pack_bits);
        conv.current_format = conv.pack_format;
        conv.current_pstride = conv.current_bits >> 1;
    } else if (!same_primaries) {
        if (idx == 0) prepareMatrix(conv, &conv.convert_matrix);
        conv.in_bits = 16;
        conv.out_bits = 16;
        pass_alloc = true;
        do_conversion = true;
    }
    if (do_conversion) {
        prev = cacheNew(prev);
        conv.convert_lines.?[idx] = prev;
        prev.write_input = true;
        prev.pass_alloc = pass_alloc;
        prev.n_lines = 1;
        prev.stride = @bitCast(conv.current_pstride *% conv.current_width);
        setNeed(prev, doConvert, idx, conv);
    }
    return prev;
}

fn setAlpha8(conv: *Converter, pixels: c.gpointer, width: c.gint) void {
    const p: [*]u8 = @ptrCast(pixels);
    const alpha: u8 = @truncate(@min(conv.alpha_value, 255));
    for (0..@intCast(@max(width, 0))) |i| p[i * 4] = alpha;
}

fn setAlpha16(conv: *Converter, pixels: c.gpointer, width: c.gint) void {
    const p: [*]align(1) u16 = @ptrCast(pixels);
    var alpha: u16 = @truncate(@min(conv.alpha_value, 255));
    alpha |= alpha << 8;
    for (0..@intCast(@max(width, 0))) |i| p[i * 4] = alpha;
}

fn multAlpha8(conv: *Converter, pixels: c.gpointer, width: c.gint) void {
    const p: [*]u8 = @ptrCast(pixels);
    for (0..@intCast(@max(width, 0))) |i| {
        const a = (@as(u32, p[i * 4]) *% conv.alpha_value) / 255;
        p[i * 4] = @truncate(@min(a, 255));
    }
}

fn multAlpha16(conv: *Converter, pixels: c.gpointer, width: c.gint) void {
    const p: [*]align(1) u16 = @ptrCast(pixels);
    for (0..@intCast(@max(width, 0))) |i| {
        const a: c.gint = @bitCast((@as(u32, p[i * 4]) *% conv.alpha_value) / 255);
        p[i * 4] = @intCast(std.math.clamp(a, 0, 65535));
    }
}

fn chainAlpha(conv: *Converter, prev_in: *LineCache, idx: usize) *LineCache {
    switch (conv.alpha_mode) {
        ALPHA_SET => conv.alpha_func = if (conv.current_bits == 8) setAlpha8 else setAlpha16,
        ALPHA_MULT => conv.alpha_func = if (conv.current_bits == 8) multAlpha8 else multAlpha16,
        else => return prev_in,
    }
    const prev = cacheNew(prev_in);
    conv.alpha_lines.?[idx] = prev;
    prev.write_input = true;
    prev.pass_alloc = true;
    prev.n_lines = 1;
    prev.stride = @bitCast(conv.current_pstride *% conv.current_width);
    setNeed(prev, doAlpha, idx, conv);
    return prev;
}

fn chainToYuv(conv: *Converter, prev_in: *LineCache, idx: usize) *LineCache {
    if (!gammaRemap(conv)) return prev_in;
    setupGammaEncode(conv, conv.pack_bits);
    conv.current_bits = @bitCast(conv.pack_bits);
    conv.current_pstride = conv.current_bits >> 1;
    if (idx == 0 and !conv.pack_rgb) {
        setIdentity(&conv.to_YUV_matrix);
        const scale: c.gint = @as(c.gint, 1) << @intCast(conv.pack_bits);
        scaleComponents(&conv.to_YUV_matrix, inv(scale), inv(scale), inv(scale));
        matrixToYuv(conv, &conv.to_YUV_matrix, false);
        prepareMatrix(conv, &conv.to_YUV_matrix);
    }
    conv.current_format = conv.pack_format;
    const prev = cacheNew(prev_in);
    conv.to_YUV_lines.?[idx] = prev;
    prev.write_input = false;
    prev.pass_alloc = false;
    prev.n_lines = 1;
    prev.stride = @bitCast(conv.current_pstride *% conv.current_width);
    setNeed(prev, doToYuv, idx, conv);
    return prev;
}

fn chainDownsample(conv: *Converter, prev_in: *LineCache, idx: usize) *LineCache {
    if (conv.downsample_p.?[idx] == null and conv.downsample_i.?[idx] == null) return prev_in;
    const prev = cacheNew(prev_in);
    conv.downsample_lines.?[idx] = prev;
    prev.write_input = true;
    prev.pass_alloc = true;
    prev.n_lines = 5;
    prev.stride = @bitCast(conv.current_pstride *% conv.current_width);
    setNeed(prev, doDownsample, idx, conv);
    return prev;
}

fn chainDither(conv: *Converter, prev_in: *LineCache, idx: usize) *LineCache {
    const method = optEnum(conv, c.GST_VIDEO_CONVERTER_OPT_DITHER_METHOD, c.gst_video_dither_method_get_type(), c.GST_VIDEO_DITHER_BAYER);
    if (method == c.GST_VIDEO_DITHER_NONE) return prev_in;
    const target = ditherQuantization(conv);
    var quant: [4]c.guint = undefined;
    var flags: c.GstVideoDitherFlags = 0;
    var do_dither = false;
    if (conv.pack_pal != null) {
        quant = .{ 47, 47, 47, 1 };
        do_dither = true;
    } else {
        for (0..4) |i| {
            const depth: c.gint = @bitCast(conv.out_info.finfo[0].depth[i]);
            if (depth == 0) {
                quant[i] = 0;
                continue;
            }
            if (conv.current_bits >= depth) {
                quant[i] = @as(c.guint, 1) << @intCast(conv.current_bits - depth);
                if (target > quant[i]) {
                    flags |= c.GST_VIDEO_DITHER_FLAG_QUANTIZE;
                    quant[i] = target;
                }
            } else quant[i] = 0;
            if (quant[i] > 1) do_dither = true;
        }
    }
    if (!do_dither) return prev_in;
    conv.dither.?[idx] = dither.gst_video_dither_new(@bitCast(method), flags, conv.pack_format, &quant, @bitCast(conv.current_width));
    const prev = cacheNew(prev_in);
    conv.dither_lines.?[idx] = prev;
    prev.write_input = true;
    prev.pass_alloc = true;
    prev.n_lines = 1;
    prev.stride = @bitCast(conv.current_pstride *% conv.current_width);
    setNeed(prev, doDither, idx, conv);
    return prev;
}

fn chainPack(conv: *Converter, prev: *LineCache) *LineCache {
    conv.pack_nlines = @bitCast(conv.out_info.finfo[0].pack_lines);
    conv.pack_pstride = conv.current_pstride;
    conv.identity_pack = conv.out_info.finfo[0].format == conv.out_info.finfo[0].unpack_format;
    return prev;
}

fn setupAllocators(conv: *Converter) void {
    var width = @max(conv.in_maxwidth, conv.out_maxwidth);
    width += conv.out_x;
    const w: c.guint = @bitCast(width);
    for (0..nThreads(conv)) |i| {
        var alloc_line: AllocFn = undefined;
        var alloc_writable: bool = undefined;
        var user_data: c.gpointer = undefined;
        var notify: ?*const fn (c.gpointer) void = null;
        if (conv.identity_pack) {
            alloc_line = destLine;
            alloc_writable = true;
            user_data = conv;
        } else {
            const a = allocNew(@sizeOf(u16) * w * 4, 4 + BACKLOG, conv);
            if (conv.borderline) |b| {
                for (0..a.n_lines) |k| @memcpy(a.data[k * a.stride ..][0..a.stride], b[0..a.stride]);
            }
            user_data = a;
            notify = allocFree;
            alloc_line = borderTempLine;
            alloc_writable = conv.borderline != null;
        }
        var prev = conv.pack_lines.?[i];
        var cache = prev;
        while (cache) |cc| : (cache = cc.prev) {
            prev.?.n_lines = @max(prev.?.n_lines, cc.n_lines);
            if (!cc.pass_alloc) prev = cc;
        }
        cache = conv.pack_lines.?[i];
        while (cache) |cc| : (cache = cc.prev) {
            cc.alloc_line = alloc_line;
            cc.alloc_line_data = user_data;
            cc.alloc_line_notify = notify;
            cc.alloc_writable = alloc_writable;
            notify = null;
            if (!cc.pass_alloc) {
                user_data = allocNew(@sizeOf(u16) * w * 4, cc.n_lines +% @as(c.guint, @bitCast(cc.backlog)), conv);
                notify = allocFree;
                alloc_line = tempLine;
                alloc_writable = false;
            }
            if (cc.write_input) alloc_writable = true;
        }
        if (notify) |n| n(user_data);
    }
}

fn splatU32(d: [*]u8, v: u32, n: usize) void {
    for (0..n) |i| std.mem.writeInt(u32, d[i * 4 ..][0..4], v, .little);
}

fn splat2U64(d: [*]u8, v: u32, n: usize) void {
    for (0..n) |i| {
        for (0..4) |k| {
            const b: u16 = @as(u8, @truncate(v >> @intCast(k * 8)));
            std.mem.writeInt(u16, d[i * 8 + k * 2 ..][0..2], b | b << 8, .little);
        }
    }
}

pub fn setupBorderline(conv: *Converter) void {
    var width = @max(conv.in_maxwidth, conv.out_maxwidth);
    width += conv.out_x;
    if (!(conv.fill_border and (conv.out_height < conv.out_maxheight or conv.out_width < conv.out_maxwidth))) {
        conv.borderline = null;
        return;
    }
    const n: usize = @intCast(width);
    const bl: [*]u8 = @ptrCast(c.g_malloc0(@sizeOf(u16) * n * 4));
    conv.borderline = bl;
    const out = conv.out_info.finfo;
    var border_val: u32 = @byteSwap(conv.border_argb);
    if (out[0].flags & c.GST_VIDEO_FORMAT_FLAG_YUV != 0) {
        var cm = MatrixData{};
        setIdentity(&cm);
        matrixToYuv(conv, &cm, true);
        matrixConvert(&cm);
        const b: c.gint = @intCast((0xFF000000 & border_val) >> 24);
        const g: c.gint = @intCast((0x00FF0000 & border_val) >> 16);
        const r: c.gint = @intCast((0x0000FF00 & border_val) >> 8);
        var a: c.gint = @intCast(0x000000FF & border_val);
        var y = 16 + ((r *% cm.im[0][0] +% g *% cm.im[0][1] +% b *% cm.im[0][2]) >> 8);
        var u = 128 + ((r *% cm.im[1][0] +% g *% cm.im[1][1] +% b *% cm.im[1][2]) >> 8);
        var v = 128 + ((r *% cm.im[2][0] +% g *% cm.im[2][1] +% b *% cm.im[2][2]) >> 8);
        a = std.math.clamp(a, 0, 255);
        y = std.math.clamp(y, 0, 255);
        u = std.math.clamp(u, 0, 255);
        v = std.math.clamp(v, 0, 255);
        border_val = @as(u32, @intCast(a)) | @as(u32, @intCast(y)) << 8 | @as(u32, @intCast(u)) << 16 | @as(u32, @intCast(v)) << 24;
    }
    if (conv.pack_bits == 8) splatU32(bl, border_val, n) else splat2U64(bl, border_val, n);
    var planes: [4]c.gpointer = undefined;
    var strides: [4]c.gint = undefined;
    for (0..out[0].n_planes) |i| {
        planes[i] = &conv.borders[i];
        strides[i] = @sizeOf(u64);
    }
    var w_sub: c.guint = 0;
    if (out[0].n_planes == 1) {
        for (0..out[0].n_components) |i| w_sub = @max(w_sub, out[0].w_sub[i]);
    }
    out[0].pack_func.?(out, c.GST_VIDEO_PACK_FLAG_NONE, bl, 0, &planes, &strides, c.GST_VIDEO_CHROMA_SITE_UNKNOWN, 0, @as(c.gint, 1) << @intCast(w_sub));
}

fn hasAlpha(info: *const Info) bool {
    return info.finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_ALPHA != 0;
}

fn getAlphaMode(conv: *Converter) c_int {
    if (!hasAlpha(&conv.out_info)) return ALPHA_NONE;
    if (hasAlpha(&conv.in_info)) {
        if (alphaMode(conv) == c.GST_VIDEO_ALPHA_MODE_COPY) return ALPHA_COPY;
        if (alphaMode(conv) == c.GST_VIDEO_ALPHA_MODE_MULT) return if (alphaValue(conv) == 1.0) ALPHA_COPY else ALPHA_MULT;
    }
    if (alphaValue(conv) == 1.0) return ALPHA_NONE;
    return ALPHA_SET;
}

fn initFromConfig(conv: *Converter) void {
    const fin = conv.in_info.finfo;
    const fout = conv.out_info.finfo;
    conv.in_x = optInt(conv, c.GST_VIDEO_CONVERTER_OPT_SRC_X, 0);
    conv.in_y = optInt(conv, c.GST_VIDEO_CONVERTER_OPT_SRC_Y, 0);
    conv.in_x &= ~((@as(c.gint, 1) << @intCast(fin[0].w_sub[1])) - 1);
    conv.in_y &= ~((@as(c.gint, 1) << @intCast(fin[0].h_sub[1])) - 1);
    conv.in_width = optInt(conv, c.GST_VIDEO_CONVERTER_OPT_SRC_WIDTH, conv.in_maxwidth - conv.in_x);
    conv.in_height = optInt(conv, c.GST_VIDEO_CONVERTER_OPT_SRC_HEIGHT, conv.in_maxheight - conv.in_y);
    conv.in_width = @min(conv.in_width, conv.in_maxwidth - conv.in_x);
    if (conv.in_width + conv.in_x < 0 or conv.in_width + conv.in_x > conv.in_maxwidth) conv.in_width = 0;
    conv.in_height = @min(conv.in_height, conv.in_maxheight - conv.in_y);
    if (conv.in_height + conv.in_y < 0 or conv.in_height + conv.in_y > conv.in_maxheight) conv.in_height = 0;
    conv.out_x = optInt(conv, c.GST_VIDEO_CONVERTER_OPT_DEST_X, 0);
    conv.out_y = optInt(conv, c.GST_VIDEO_CONVERTER_OPT_DEST_Y, 0);
    conv.out_x &= ~((@as(c.gint, 1) << @intCast(fout[0].w_sub[1])) - 1);
    conv.out_y &= ~((@as(c.gint, 1) << @intCast(fout[0].h_sub[1])) - 1);
    conv.out_width = optInt(conv, c.GST_VIDEO_CONVERTER_OPT_DEST_WIDTH, conv.out_maxwidth - conv.out_x);
    conv.out_height = optInt(conv, c.GST_VIDEO_CONVERTER_OPT_DEST_HEIGHT, conv.out_maxheight - conv.out_y);
    if (conv.out_width > conv.out_maxwidth - conv.out_x) conv.out_width = conv.out_maxwidth - conv.out_x;
    conv.out_width = std.math.clamp(conv.out_width, 0, @max(conv.out_maxwidth, 0));
    if (conv.out_width + conv.out_x < 0 or conv.out_width + conv.out_x > conv.out_maxwidth) conv.out_width = 0;
    if (conv.out_height > conv.out_maxheight - conv.out_y) conv.out_height = conv.out_maxheight - conv.out_y;
    conv.out_height = std.math.clamp(conv.out_height, 0, @max(conv.out_maxheight, 0));
    if (conv.out_height + conv.out_y < 0 or conv.out_height + conv.out_y > conv.out_maxheight) conv.out_height = 0;
    conv.fill_border = optBool(conv, c.GST_VIDEO_CONVERTER_OPT_FILL_BORDER, true);
    conv.border_argb = optUint(conv, c.GST_VIDEO_CONVERTER_OPT_BORDER_ARGB, 0xff000000);
    conv.alpha_value = @bitCast(toInt(255 * alphaValue(conv)));
    conv.alpha_mode = getAlphaMode(conv);
    conv.unpack_format = fin[0].unpack_format;
    var f = format.get(conv.unpack_format);
    conv.unpack_bits = f[0].depth[0];
    conv.unpack_rgb = f[0].flags & c.GST_VIDEO_FORMAT_FLAG_RGB != 0;
    if (conv.unpack_rgb and conv.in_info.colorimetry.matrix != c.GST_VIDEO_COLOR_MATRIX_RGB) conv.in_info.colorimetry.matrix = c.GST_VIDEO_COLOR_MATRIX_RGB;
    conv.pack_format = fout[0].unpack_format;
    f = format.get(conv.pack_format);
    conv.pack_bits = f[0].depth[0];
    conv.pack_rgb = f[0].flags & c.GST_VIDEO_FORMAT_FLAG_RGB != 0;
    conv.pack_pal = format.gst_video_format_get_palette(fout[0].format, &conv.pack_palsize);
    if (conv.pack_rgb and conv.out_info.colorimetry.matrix != c.GST_VIDEO_COLOR_MATRIX_RGB) conv.out_info.colorimetry.matrix = c.GST_VIDEO_COLOR_MATRIX_RGB;
}

pub fn fieldHeight(info: *allowzero const Info) c.gint {
    if (info.interlace_mode == c.GST_VIDEO_INTERLACE_MODE_ALTERNATE) return @divTrunc((info.height + 1) & ~@as(c.gint, 1), 2);
    return info.height;
}

pub export fn gst_video_converter_new_with_pool(in_info: [*c]const Info, out_info: [*c]const Info, config: ?*c.GstStructure, pool: ?*c.GstTaskPool) ?*Opaque {
    const fname = "gst_video_converter_new_with_pool";
    if (!check.that(in_info != null, fname, "in_info != NULL")) return null;
    if (!check.that(out_info != null, fname, "out_info != NULL")) return null;
    if (!check.that(in_info[0].fps_n == out_info[0].fps_n, fname, "in_info->fps_n == out_info->fps_n")) return null;
    if (!check.that(in_info[0].fps_d == out_info[0].fps_d, fname, "in_info->fps_d == out_info->fps_d")) return null;
    if (!check.that(in_info[0].interlace_mode == out_info[0].interlace_mode, fname, "in_info->interlace_mode == out_info->interlace_mode")) return null;
    const conv: *Converter = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Converter))));
    conv.* = .{ .in_info = in_info[0], .out_info = out_info[0] };
    conv.in_maxwidth = in_info[0].width;
    conv.in_maxheight = fieldHeight(&in_info[0]);
    conv.out_maxwidth = out_info[0].width;
    conv.out_maxheight = fieldHeight(&out_info[0]);
    conv.config = c.gst_structure_new_static_str_empty("GstVideoConverter");
    var n_threads: c.guint = 1;
    if (config != null) {
        _ = gst_video_converter_set_config(@ptrCast(conv), config);
        n_threads = optUint(conv, c.GST_VIDEO_CONVERTER_OPT_THREADS, 1);
    } else {
        initFromConfig(conv);
        if (pool != null and isSharedPool(pool.?)) {
            n_threads = c.gst_shared_task_pool_get_max_threads(@ptrCast(pool));
            c.gst_structure_set(conv.config, c.GST_VIDEO_CONVERTER_OPT_THREADS, c.G_TYPE_UINT, n_threads, @as(?*anyopaque, null));
        } else n_threads = optUint(conv, c.GST_VIDEO_CONVERTER_OPT_THREADS, 1);
    }
    if (n_threads == 0 or n_threads > c.g_get_num_processors()) n_threads = c.g_get_num_processors();
    const mh: c.guint = @bitCast(@max(conv.out_height, conv.in_height));
    if (mh / n_threads < 200) n_threads = (mh +% 199) / 200;
    if (@as(c.gint, @bitCast(n_threads)) < 1) n_threads = 1;
    const async_tasks = optBool(conv, c.GST_VIDEO_CONVERTER_OPT_ASYNC_TASKS, false);
    conv.runner = runnerNew(n_threads, pool, async_tasks);
    if (fast.lookup(conv)) return @ptrCast(conv);
    if (in_info[0].finfo[0].unpack_func == null or out_info[0].finfo[0].pack_func == null) {
        gst_video_converter_free(@ptrCast(conv));
        return null;
    }
    conv.convert = generic;
    conv.upsample_p = newArray(c.GstVideoChromaResample, n_threads);
    conv.upsample_i = newArray(c.GstVideoChromaResample, n_threads);
    conv.downsample_p = newArray(c.GstVideoChromaResample, n_threads);
    conv.downsample_i = newArray(c.GstVideoChromaResample, n_threads);
    conv.v_scaler_p = newArray(c.GstVideoScaler, n_threads);
    conv.v_scaler_i = newArray(c.GstVideoScaler, n_threads);
    conv.h_scaler = newArray(c.GstVideoScaler, n_threads);
    conv.unpack_lines = newArray(LineCache, n_threads);
    conv.pack_lines = newArray(LineCache, n_threads);
    conv.upsample_lines = newArray(LineCache, n_threads);
    conv.to_RGB_lines = newArray(LineCache, n_threads);
    conv.hscale_lines = newArray(LineCache, n_threads);
    conv.vscale_lines = newArray(LineCache, n_threads);
    conv.convert_lines = newArray(LineCache, n_threads);
    conv.alpha_lines = newArray(LineCache, n_threads);
    conv.to_YUV_lines = newArray(LineCache, n_threads);
    conv.downsample_lines = newArray(LineCache, n_threads);
    conv.dither_lines = newArray(LineCache, n_threads);
    conv.dither = newArray(c.GstVideoDither, n_threads);
    if (conv.in_width > 0 and conv.out_width > 0 and conv.in_height > 0 and conv.out_height > 0) {
        for (0..n_threads) |i| {
            conv.current_format = in_info[0].finfo[0].format;
            conv.current_width = conv.in_width;
            conv.current_height = conv.in_height;
            var prev = chainUnpack(conv, i);
            prev = chainUpsample(conv, prev, i);
            prev = chainToRgb(conv, prev, i);
            prev = chainScale(conv, prev, false, i);
            prev = chainConvert(conv, prev, i);
            prev = chainAlpha(conv, prev, i);
            prev = chainScale(conv, prev, true, i);
            prev = chainToYuv(conv, prev, i);
            prev = chainDownsample(conv, prev, i);
            prev = chainDither(conv, prev, i);
            conv.pack_lines.?[i] = chainPack(conv, prev);
        }
    }
    setupBorderline(conv);
    setupAllocators(conv);
    return @ptrCast(conv);
}

pub export fn gst_video_converter_new(in_info: [*c]const Info, out_info: [*c]const Info, config: ?*c.GstStructure) ?*Opaque {
    return gst_video_converter_new_with_pool(in_info, out_info, config, null);
}

fn clearMatrix(d: *MatrixData) void {
    c.g_free(d.t_r);
    c.g_free(d.t_g);
    c.g_free(d.t_b);
}

fn freeEach(comptime T: type, arr: PerThread(T), i: usize, f: *const fn (?*T) callconv(.c) void) void {
    if (arr) |a| if (a[i]) |p| f(p);
}

fn freeCache(arr: PerThread(LineCache), i: usize) void {
    if (arr) |a| if (a[i]) |p| cacheFree(p);
}

pub export fn gst_video_converter_free(convert: ?*Opaque) void {
    if (!check.that(convert != null, "gst_video_converter_free", "convert != NULL")) return;
    const conv = of(convert);
    const n = nThreads(conv);
    for (0..n) |i| {
        freeEach(c.GstVideoChromaResample, conv.upsample_p, i, chroma.gst_video_chroma_resample_free);
        freeEach(c.GstVideoChromaResample, conv.upsample_i, i, chroma.gst_video_chroma_resample_free);
        freeEach(c.GstVideoChromaResample, conv.downsample_p, i, chroma.gst_video_chroma_resample_free);
        freeEach(c.GstVideoChromaResample, conv.downsample_i, i, chroma.gst_video_chroma_resample_free);
        freeEach(c.GstVideoScaler, conv.v_scaler_p, i, scaler.gst_video_scaler_free);
        freeEach(c.GstVideoScaler, conv.v_scaler_i, i, scaler.gst_video_scaler_free);
        freeEach(c.GstVideoScaler, conv.h_scaler, i, scaler.gst_video_scaler_free);
        freeCache(conv.unpack_lines, i);
        freeCache(conv.upsample_lines, i);
        freeCache(conv.to_RGB_lines, i);
        freeCache(conv.hscale_lines, i);
        freeCache(conv.vscale_lines, i);
        freeCache(conv.convert_lines, i);
        freeCache(conv.alpha_lines, i);
        freeCache(conv.to_YUV_lines, i);
        freeCache(conv.downsample_lines, i);
        freeCache(conv.dither_lines, i);
        freeEach(c.GstVideoDither, conv.dither, i, dither.gst_video_dither_free);
    }
    inline for (.{ "upsample_p", "upsample_i", "downsample_p", "downsample_i", "v_scaler_p", "v_scaler_i", "h_scaler", "unpack_lines", "pack_lines", "upsample_lines", "to_RGB_lines", "hscale_lines", "vscale_lines", "convert_lines", "alpha_lines", "to_YUV_lines", "downsample_lines", "dither_lines", "dither" }) |name| c.g_free(@ptrCast(@field(conv, name)));
    c.g_free(conv.gamma_dec.table);
    c.g_free(conv.gamma_enc.table);
    if (conv.tmpline) |t| {
        for (0..n) |i| c.g_free(t[i]);
        c.g_free(@ptrCast(t));
    }
    c.g_free(conv.borderline);
    if (conv.config) |cfg| c.gst_structure_free(cfg);
    for (0..4) |i| {
        for (0..n) |j| {
            if (conv.fv_scaler[i]) |s| scaler.gst_video_scaler_free(s[j]);
            if (conv.fh_scaler[i]) |s| scaler.gst_video_scaler_free(s[j]);
        }
        c.g_free(@ptrCast(conv.fv_scaler[i]));
        c.g_free(@ptrCast(conv.fh_scaler[i]));
    }
    if (conv.runner) |r| runnerFree(r);
    clearMatrix(&conv.to_RGB_matrix);
    clearMatrix(&conv.convert_matrix);
    clearMatrix(&conv.to_YUV_matrix);
    for (0..4) |i| {
        c.g_free(conv.tasks[i]);
        c.g_free(conv.tasks_p[i]);
    }
    c.g_free(conv);
}

fn copyConfig(field: ?*const c.GstIdStr, value: [*c]const c.GValue, user: c.gpointer) callconv(.c) c.gboolean {
    const conv: *Converter = @ptrCast(@alignCast(user));
    c.gst_structure_id_str_set_value(conv.config, field, value);
    return 1;
}

pub export fn gst_video_converter_set_config(convert: ?*Opaque, config: ?*c.GstStructure) c.gboolean {
    const fname = "gst_video_converter_set_config";
    if (!check.that(convert != null, fname, "convert != NULL")) return 0;
    if (!check.that(config != null, fname, "config != NULL")) return 0;
    const conv = of(convert);
    _ = c.gst_structure_foreach_id_str(config, copyConfig, conv);
    c.gst_structure_free(config);
    initFromConfig(conv);
    return 1;
}

pub export fn gst_video_converter_get_config(convert: ?*Opaque) ?*const c.GstStructure {
    if (!check.that(convert != null, "gst_video_converter_get_config", "convert != NULL")) return null;
    return of(convert).config;
}

fn frameFormat(f: *allowzero const Frame) c.GstVideoFormat {
    return f.info.finfo[0].format;
}

pub export fn gst_video_converter_frame(convert: ?*Opaque, src: [*c]const Frame, dest: [*c]Frame) void {
    const fname = "gst_video_converter_frame";
    if (!check.that(convert != null, fname, "convert != NULL")) return;
    if (!check.that(src != null, fname, "src != NULL")) return;
    if (!check.that(dest != null, fname, "dest != NULL")) return;
    const conv = of(convert);
    const s: *const Frame = @ptrCast(src);
    const d: *Frame = @ptrCast(dest);
    if (conv.in_info.finfo[0].format != frameFormat(s) or conv.in_info.width > s.info.width or fieldHeight(&conv.in_info) > s.info.height) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Input video frame does not match configuration");
        return;
    }
    if (conv.out_info.finfo[0].format != frameFormat(d) or conv.out_info.width > d.info.width or fieldHeight(&conv.out_info) > d.info.height) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Output video frame does not match configuration");
        return;
    }
    if (conv.in_width == 0 or conv.in_height == 0 or conv.out_width == 0 or conv.out_height == 0) return;
    conv.convert.?(conv, s, d);
}

pub export fn gst_video_converter_frame_finish(convert: ?*Opaque) void {
    const fname = "gst_video_converter_frame_finish";
    if (!check.that(convert != null, fname, "convert")) return;
    const conv = of(convert);
    if (!check.that(conv.runner != null, fname, "convert->conversion_runner")) return;
    if (!check.that(conv.runner.?.async_tasks, fname, "convert->conversion_runner->async_tasks")) return;
    runnerJoin(conv.runner.?);
}

pub fn computeMatrix(conv: *Converter) void {
    const dst = &conv.convert_matrix;
    setIdentity(dst);
    matrixToRgb(conv, dst);
    matrixToYuv(conv, dst, false);
    conv.current_bits = 8;
    prepareMatrix(conv, dst);
}

fn computeResample(conv: *Converter, idx: usize) void {
    const mode = chromaMode(conv);
    if (mode == c.GST_VIDEO_CHROMA_MODE_NONE) return;
    const in = &conv.in_info;
    const out = &conv.out_info;
    const sf = in.finfo;
    const df = out.finfo;
    if (!(sf[0].w_sub[2] != df[0].w_sub[2] or sf[0].h_sub[2] != df[0].h_sub[2] or in.chroma_site != out.chroma_site or in.width != out.width or in.height != out.height)) return;
    const sw: c.gint = @bitCast(sf[0].w_sub[2]);
    const sh: c.gint = @bitCast(sf[0].h_sub[2]);
    const dw: c.gint = @bitCast(df[0].w_sub[2]);
    const dh: c.gint = @bitCast(df[0].h_sub[2]);
    if (isInterlaced(in) and in.interlace_mode != c.GST_VIDEO_INTERLACE_MODE_ALTERNATE) {
        if (mode != c.GST_VIDEO_CHROMA_MODE_DOWNSAMPLE_ONLY) conv.upsample_i.?[idx] = @ptrCast(chroma.gst_video_chroma_resample_new(0, in.chroma_site, c.GST_VIDEO_CHROMA_FLAG_INTERLACED, sf[0].unpack_format, sw, sh));
        if (mode != c.GST_VIDEO_CHROMA_MODE_UPSAMPLE_ONLY) conv.downsample_i.?[idx] = @ptrCast(chroma.gst_video_chroma_resample_new(0, out.chroma_site, c.GST_VIDEO_CHROMA_FLAG_INTERLACED, df[0].unpack_format, -dw, -dh));
    }
    if (mode != c.GST_VIDEO_CHROMA_MODE_DOWNSAMPLE_ONLY) conv.upsample_p.?[idx] = @ptrCast(chroma.gst_video_chroma_resample_new(0, in.chroma_site, 0, sf[0].unpack_format, sw, sh));
    if (mode != c.GST_VIDEO_CHROMA_MODE_UPSAMPLE_ONLY) conv.downsample_p.?[idx] = @ptrCast(chroma.gst_video_chroma_resample_new(0, out.chroma_site, 0, df[0].unpack_format, -dw, -dh));
}

pub fn planeLine(f: *const Frame, plane: usize, line: anytype) [*]u8 {
    return @ptrFromInt(@intFromPtr(f.data[plane]) +% @as(usize, @bitCast(@as(isize, f.info.stride[plane]) * @as(isize, @intCast(line)))));
}

pub fn compLine(f: *const Frame, comp: usize, line: anytype) [*]u8 {
    const fi = f.info.finfo;
    const p = fi[0].plane[comp];
    return planeLine(f, p, line) + fi[0].poffset[comp];
}

pub fn frameInterlaced(f: *const Frame) bool {
    return f.flags & c.GST_VIDEO_FRAME_FLAG_INTERLACED != 0;
}

fn packFlags(f: *const Frame) c.GstVideoPackFlags {
    return if (frameInterlaced(f)) c.GST_VIDEO_PACK_FLAG_INTERLACED else c.GST_VIDEO_PACK_FLAG_NONE;
}

pub fn packFrame(f: *Frame, src: c.gpointer, line: c.gint, width: c.gint) void {
    f.info.finfo[0].pack_func.?(f.info.finfo, packFlags(f), src, 0, &f.data, &f.info.stride, f.info.chroma_site, line, width);
}

fn clampLine(v: c.gint, hi: c.gint) c.gint {
    return if (v > hi) hi else if (v < 0) 0 else v;
}

fn destLine(_: *LineCache, idx: c.gint, user_data: c.gpointer) c.gpointer {
    const conv: *Converter = @ptrCast(@alignCast(user_data));
    const pstride = conv.pack_pstride;
    const out_x = conv.out_x;
    const cline: c.guint = @bitCast(clampLine(idx, conv.out_maxheight - 1));
    var line = planeLine(conv.dest.?, 0, cline);
    if (conv.borderline) |b| {
        const r_border: usize = @intCast((out_x + conv.out_width) * pstride);
        const rb_width: usize = @intCast(conv.out_maxwidth * pstride - @as(c.gint, @intCast(r_border)));
        const lb_width: usize = @intCast(out_x * pstride);
        @memcpy(line[0..lb_width], b[0..lb_width]);
        @memcpy(line[r_border..][0..rb_width], b[0..rb_width]);
    }
    line += @as(usize, @intCast(out_x * pstride));
    return line;
}

fn doUnpack(cache: *LineCache, _: c.gint, out_line: c.gint, in_line: c.gint, conv: *Converter) bool {
    const cline = clampLine(in_line + conv.in_y, conv.in_maxheight - 1);
    var tmpline: c.gpointer = undefined;
    const src = conv.src.?;
    if (cache.alloc_writable or !conv.identity_unpack) {
        tmpline = allocLine(cache, out_line);
        src.info.finfo[0].unpack_func.?(src.info.finfo, packFlags(src), tmpline, &src.data, &src.info.stride, conv.in_x, cline, conv.in_width);
    } else {
        tmpline = planeLine(src, 0, cline) + @as(usize, @intCast(conv.in_x * conv.unpack_pstride));
    }
    addLine(cache, in_line, tmpline);
    return true;
}

fn doUpsample(cache: *LineCache, idx: c.gint, out_line_in: c.gint, in_line: c.gint, conv: *Converter) bool {
    const n: c.gint = @bitCast(conv.up_n_lines);
    var start = in_line;
    var out_line = out_line_in;
    if (start < n + conv.up_offset) {
        start += conv.up_offset;
        out_line += conv.up_offset;
    }
    const lines = getLines(cache.prev.?, idx, out_line, start, n).?;
    const u = conv.upsample.?[@intCast(idx)];
    if (u != null) chroma.gst_video_chroma_resample(@ptrCast(u), @ptrCast(lines), conv.in_width);
    for (0..@intCast(n)) |i| addLine(cache, start + @as(c.gint, @intCast(i)), lines[i]);
    return true;
}

fn doToRgb(cache: *LineCache, idx: c.gint, out_line: c.gint, in_line: c.gint, conv: *Converter) bool {
    const lines = getLines(cache.prev.?, idx, out_line, in_line, 1).?;
    var destline = lines[0];
    if (conv.to_RGB_matrix.matrix_func) |f| f(&conv.to_RGB_matrix, destline);
    if (conv.gamma_dec.func) |f| {
        destline = allocLine(cache, out_line);
        f(&conv.gamma_dec, destline, lines[0]);
    }
    addLine(cache, in_line, destline);
    return true;
}

fn doHscale(cache: *LineCache, idx: c.gint, out_line: c.gint, in_line: c.gint, conv: *Converter) bool {
    const lines = getLines(cache.prev.?, idx, out_line, in_line, 1).?;
    const destline = allocLine(cache, out_line);
    scaler.gst_video_scaler_horizontal(conv.h_scaler.?[@intCast(idx)], conv.h_scale_format, lines[0], destline, 0, @bitCast(conv.out_width));
    addLine(cache, in_line, destline);
    return true;
}

fn doVscale(cache: *LineCache, idx: c.gint, out_line: c.gint, in_line: c.gint, conv: *Converter) bool {
    const cline: c.guint = @bitCast(clampLine(in_line, conv.out_height - 1));
    var sline: c.guint = 0;
    var n_lines: c.guint = 0;
    const vs = conv.v_scaler.?[@intCast(idx)];
    _ = scaler.gst_video_scaler_get_coeff(vs, cline, &sline, &n_lines);
    const lines = getLines(cache.prev.?, idx, out_line, @bitCast(sline), @bitCast(n_lines)).?;
    const destline = allocLine(cache, out_line);
    scaler.gst_video_scaler_vertical(vs, conv.v_scale_format, @ptrCast(lines), destline, cline, @bitCast(conv.v_scale_width));
    addLine(cache, in_line, destline);
    return true;
}

fn u8ToU16(d: c.gpointer, s: c.gpointer, n: usize) void {
    const dp: [*]align(1) u16 = @ptrCast(d);
    const sp: [*]const u8 = @ptrCast(s);
    var i = n;
    while (i > 0) {
        i -= 1;
        dp[i] = @as(u16, sp[i]) | @as(u16, sp[i]) << 8;
    }
}

fn u16ToU8(d: c.gpointer, s: c.gpointer, n: usize) void {
    const dp: [*]u8 = @ptrCast(d);
    const sp: [*]align(1) const u16 = @ptrCast(s);
    for (0..n) |i| dp[i] = @truncate(sp[i] >> 8);
}

fn doConvert(cache: *LineCache, idx: c.gint, out_line: c.gint, in_line: c.gint, conv: *Converter) bool {
    const data = &conv.convert_matrix;
    const lines = getLines(cache.prev.?, idx, out_line, in_line, 1).?;
    var destline = lines[0];
    const in_bits = conv.in_bits;
    const out_bits = conv.out_bits;
    const width: usize = @intCast(@max(@min(conv.in_width, conv.out_width), 0));
    if (out_bits == 16 or in_bits == 16) {
        var srcline = lines[0];
        if (out_bits != in_bits) destline = allocLine(cache, out_line);
        if (in_bits == 8) {
            u8ToU16(destline, srcline, width * 4);
            srcline = destline;
        }
        if (data.matrix_func) |f| f(data, srcline);
        if (out_bits == 8) u16ToU8(destline, srcline, width * 4);
    } else if (data.matrix_func) |f| f(data, destline);
    addLine(cache, in_line, destline);
    return true;
}

fn doAlpha(cache: *LineCache, idx: c.gint, out_line: c.gint, in_line: c.gint, conv: *Converter) bool {
    const lines = getLines(cache.prev.?, idx, out_line, in_line, 1).?;
    conv.alpha_func.?(conv, lines[0], @min(conv.in_width, conv.out_width));
    addLine(cache, in_line, lines[0]);
    return true;
}

fn doToYuv(cache: *LineCache, idx: c.gint, out_line: c.gint, in_line: c.gint, conv: *Converter) bool {
    const lines = getLines(cache.prev.?, idx, out_line, in_line, 1).?;
    var destline = lines[0];
    if (conv.gamma_enc.func) |f| {
        destline = allocLine(cache, out_line);
        f(&conv.gamma_enc, destline, lines[0]);
    }
    if (conv.to_YUV_matrix.matrix_func) |f| f(&conv.to_YUV_matrix, destline);
    addLine(cache, in_line, destline);
    return true;
}

fn doDownsample(cache: *LineCache, idx: c.gint, out_line: c.gint, in_line: c.gint, conv: *Converter) bool {
    const n: c.gint = @bitCast(conv.down_n_lines);
    var start = in_line;
    if (start < n + conv.down_offset) start += conv.down_offset;
    const lines = getLines(cache.prev.?, idx, out_line, start, n).?;
    const d = conv.downsample.?[@intCast(idx)];
    if (d != null) chroma.gst_video_chroma_resample(@ptrCast(d), @ptrCast(lines), conv.out_width);
    for (0..@intCast(n)) |i| addLine(cache, start + @as(c.gint, @intCast(i)), lines[i]);
    return true;
}

fn doDither(cache: *LineCache, idx: c.gint, out_line: c.gint, in_line: c.gint, conv: *Converter) bool {
    const lines = getLines(cache.prev.?, idx, out_line, in_line, 1).?;
    const d = conv.dither.?[@intCast(idx)];
    if (d != null) dither.gst_video_dither_line(d, lines[0], 0, @bitCast(out_line), @bitCast(conv.out_width));
    addLine(cache, in_line, lines[0]);
    return true;
}

const Task = struct {
    pack_lines: ?*LineCache,
    idx: c.gint,
    h_0: c.gint,
    h_1: c.gint,
    pack_lines_count: c.gint,
    out_y: c.gint,
    identity_pack: bool,
    lb_width: c.gint,
    out_maxwidth: c.gint,
    dest: *Frame,
};

fn genericTask(p: c.gpointer) void {
    const t: *Task = @ptrCast(@alignCast(p));
    var i = t.h_0;
    while (i < t.h_1) : (i += t.pack_lines_count) {
        const lines = getLines(t.pack_lines.?, t.idx, i + t.out_y, i, t.pack_lines_count);
        if (!t.identity_pack) {
            const l: [*]u8 = @ptrFromInt(@intFromPtr(lines.?[0]) -% @as(usize, @intCast(t.lb_width)));
            packFrame(t.dest, l, i + t.out_y, t.out_maxwidth);
        }
    }
}

fn generic(conv: *Converter, src: *const Frame, dest: *Frame) void {
    const out_height = conv.out_height;
    const out_maxwidth = conv.out_maxwidth;
    const out_y = conv.out_y;
    conv.src = src;
    conv.dest = dest;
    if (frameInterlaced(src)) {
        conv.upsample = conv.upsample_i;
        conv.downsample = conv.downsample_i;
        conv.v_scaler = conv.v_scaler_i;
    } else {
        conv.upsample = conv.upsample_p;
        conv.downsample = conv.downsample_p;
        conv.v_scaler = conv.v_scaler_p;
    }
    if (conv.upsample.?[0]) |u| {
        chroma.gst_video_chroma_resample_get_info(@ptrCast(u), &conv.up_n_lines, &conv.up_offset);
    } else {
        conv.up_n_lines = 1;
        conv.up_offset = 0;
    }
    if (conv.downsample.?[0]) |d| {
        chroma.gst_video_chroma_resample_get_info(@ptrCast(d), &conv.down_n_lines, &conv.down_offset);
    } else {
        conv.down_n_lines = 1;
        conv.down_offset = 0;
    }
    const pack_lines: c.gint = @bitCast(conv.pack_nlines);
    const lb_width = conv.out_x * conv.pack_pstride;
    if (conv.borderline) |b| {
        var i: c.gint = 0;
        while (i < out_y) : (i += 1) packFrame(dest, b, i, out_maxwidth);
    }
    const n: c.gint = @bitCast(nThreads(conv));
    const tasks: [*]Task = @ptrCast(@alignCast(c.g_realloc(conv.tasks[0], @sizeOf(Task) * @as(usize, @intCast(n)))));
    conv.tasks[0] = tasks;
    const tasks_p: [*]c.gpointer = @ptrCast(@alignCast(c.g_realloc(conv.tasks_p[0], @sizeOf(c.gpointer) * @as(usize, @intCast(n)))));
    conv.tasks_p[0] = @ptrCast(tasks_p);
    const per = roundUpN(@divTrunc(out_height + n - 1, n), pack_lines);
    for (0..@intCast(n)) |k| {
        const i: c.gint = @intCast(k);
        tasks[k] = .{ .dest = dest, .pack_lines = conv.pack_lines.?[k], .idx = i, .pack_lines_count = pack_lines, .out_y = out_y, .identity_pack = conv.identity_pack, .lb_width = lb_width, .out_maxwidth = out_maxwidth, .h_0 = i * per, .h_1 = @min((i + 1) * per, out_height) };
        tasks_p[k] = &tasks[k];
    }
    runnerRun(conv.runner.?, genericTask, tasks_p);
    if (conv.borderline) |b| {
        var i = out_y + out_height;
        while (i < conv.out_maxheight) : (i += 1) packFrame(dest, b, i, out_maxwidth);
    }
    if (conv.pack_pal) |pal| {
        const d: [*]u8 = @ptrCast(dest.data[1]);
        const s: [*]const u8 = @ptrCast(pal);
        @memcpy(d[0..conv.pack_palsize], s[0..conv.pack_palsize]);
    }
}

pub fn roundUpN(v: c.gint, n: c.gint) c.gint {
    return (v + n - 1) & ~(n - 1);
}

pub export fn gst_video_converter_get_in_info(convert: ?*Opaque) [*c]const Info {
    return &of(convert).in_info;
}

pub export fn gst_video_converter_get_out_info(convert: ?*Opaque) [*c]const Info {
    return &of(convert).out_info;
}

var valid_tags = [_][*c]const u8{ "video", "orientation", "size", "colorspace", null };

pub export fn gst_video_converter_transform_metas(convert: ?*Opaque, src: [*c]c.GstBuffer, dest: [*c]c.GstBuffer) c.gboolean {
    const conv = of(convert);
    if (!check.that(c.gst_mini_object_is_writable(@ptrCast(dest)) != 0, "gst_video_converter_transform_metas", "gst_buffer_is_writable (dest)")) return 0;
    const crop = conv.in_x != 0 or conv.in_y != 0 or conv.in_width != conv.in_maxwidth or conv.in_height != conv.in_maxheight;
    const border = conv.out_x != 0 or conv.out_y != 0 or conv.out_width != conv.out_maxwidth or conv.out_height != conv.out_maxheight;
    if (conv.out_width <= 0 or conv.out_height <= 0) return 0;
    var tm: c.GstVideoMetaTransformMatrix = undefined;
    const in_r = c.GstVideoRectangle{ .x = conv.in_x, .y = conv.in_y, .w = conv.in_width, .h = conv.in_height };
    const out_r = c.GstVideoRectangle{ .x = conv.out_x, .y = conv.out_y, .w = conv.out_width, .h = conv.out_height };
    var trans = c.GstVideoMetaTransform{ .in_info = &conv.in_info, .out_info = &conv.out_info };
    meta.gst_video_meta_transform_matrix_init(&tm, &conv.in_info, &in_r, &conv.out_info, &out_r);
    var state: c.gpointer = null;
    var ret = false;
    while (true) {
        const mt = c.gst_buffer_iterate_meta(src, &state);
        if (mt == null) break;
        const tf = mt[0].info[0].transform_func orelse continue;
        if (c.gst_meta_api_type_tags_contain_only(mt[0].info[0].api, &valid_tags) == 0) continue;
        if (tf(dest, mt, src, meta.gst_video_meta_transform_matrix_get_quark(), &tm) == 0) {
            if (!crop and !border) ret = tf(dest, mt, src, meta.gst_video_meta_transform_scale_get_quark(), &trans) != 0 or ret;
        } else ret = true;
    }
    return @intFromBool(ret);
}
