const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const va = @import("varargs.zig");
const printf = @import("printf.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Category = c.GstDebugCategory;
const Level = c.GstDebugLevel;

pub export var _gst_debug_min: Level = c.GST_LEVEL_NONE;
pub export var _gst_debug_enabled: c.gboolean = 0;

var default_level = std.atomic.Value(c_int).init(c.GST_LEVEL_DEFAULT);
var categories: ?*c.GSList = null;
var cat_lock: c.GMutex = std.mem.zeroes(c.GMutex);

const Rule = struct { pattern: ?*c.GPatternSpec, level: Level };
var rules: std.ArrayListUnmanaged(Rule) = .empty;
var rule_lock: c.GMutex = std.mem.zeroes(c.GMutex);

fn threshold(cat: *Category) *std.atomic.Value(c_int) {
    return @ptrCast(&cat.threshold);
}

pub fn newCategory(name: [*c]const u8, color: c.guint, description: [*c]const u8) [*c]Category {
    return _gst_debug_category_new(name, color, description);
}

fn matchRule(cat: *Category) ?Level {
    c.g_mutex_lock(&rule_lock);
    defer c.g_mutex_unlock(&rule_lock);
    var i = rules.items.len;
    while (i > 0) {
        i -= 1;
        if (c.g_pattern_spec_match_string(rules.items[i].pattern, cat.name) != 0) return rules.items[i].level;
    }
    return null;
}

fn resetOne(cat: *Category) void {
    gst_debug_category_set_threshold(cat, matchRule(cat) orelse @intCast(default_level.load(.monotonic)));
}

fn resetAll() void {
    c.g_mutex_lock(&cat_lock);
    defer c.g_mutex_unlock(&cat_lock);
    var node = categories;
    while (node) |n| : (node = n.next) resetOne(@ptrCast(@alignCast(n.data)));
}

fn findLocked(name: [*c]const u8) ?*Category {
    var node = categories;
    while (node) |n| : (node = n.next) {
        const cat: *Category = @ptrCast(@alignCast(n.data));
        if (std.mem.orderZ(u8, name, cat.name) == .eq) return cat;
    }
    return null;
}

pub export fn _gst_debug_category_new(name: [*c]const u8, color: c.guint, description: [*c]const u8) [*c]Category {
    if (!check.that(name != null, "_gst_debug_category_new", "name != NULL")) return null;
    const cat: *Category = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Category))));
    cat.name = c.g_strdup(name);
    cat.color = color;
    cat.description = c.g_strdup(if (description != null) description else "no description");
    threshold(cat).store(0, .monotonic);
    resetOne(cat);
    c.g_mutex_lock(&cat_lock);
    defer c.g_mutex_unlock(&cat_lock);
    if (findLocked(name)) |found| {
        c.g_free(@constCast(cat.name));
        c.g_free(@constCast(cat.description));
        c.g_free(cat);
        return found;
    }
    categories = c.g_slist_prepend(categories, cat);
    return cat;
}

pub export fn _gst_debug_get_category(name: [*c]const u8) [*c]Category {
    c.g_mutex_lock(&cat_lock);
    defer c.g_mutex_unlock(&cat_lock);
    return findLocked(name) orelse null;
}

pub export fn gst_debug_category_free(_: [*c]Category) void {}

pub export fn gst_debug_category_set_threshold(cat: [*c]Category, level: Level) void {
    if (!check.that(cat != null, "gst_debug_category_set_threshold", "category != NULL")) return;
    if (level > _gst_debug_min) {
        _gst_debug_enabled = 1;
        _gst_debug_min = level;
    }
    threshold(cat).store(@intCast(level), .monotonic);
}

pub export fn gst_debug_category_reset_threshold(cat: [*c]Category) void {
    resetOne(cat);
}

pub export fn gst_debug_category_get_threshold(cat: [*c]Category) Level {
    return @intCast(threshold(cat).load(.monotonic));
}

pub export fn gst_debug_category_get_name(cat: [*c]Category) [*c]const u8 {
    return cat.*.name;
}

pub export fn gst_debug_category_get_color(cat: [*c]Category) c.guint {
    return cat.*.color;
}

pub export fn gst_debug_category_get_description(cat: [*c]Category) [*c]const u8 {
    return cat.*.description;
}

pub export fn gst_debug_get_all_categories() [*c]c.GSList {
    c.g_mutex_lock(&cat_lock);
    defer c.g_mutex_unlock(&cat_lock);
    return c.g_slist_copy(categories);
}

pub export fn gst_debug_set_default_threshold(level: Level) void {
    default_level.store(@intCast(level), .monotonic);
    resetAll();
}

pub export fn gst_debug_get_default_threshold() Level {
    return @intCast(default_level.load(.monotonic));
}

pub export fn gst_debug_set_threshold_for_name(name: [*c]const u8, level: Level) void {
    if (!check.that(name != null, "gst_debug_set_threshold_for_name", "name != NULL")) return;
    const rule = Rule{ .pattern = c.g_pattern_spec_new(name), .level = level };
    c.g_mutex_lock(&rule_lock);
    rules.append(std.heap.c_allocator, rule) catch @panic("out of memory");
    c.g_mutex_unlock(&rule_lock);
    c.g_mutex_lock(&cat_lock);
    defer c.g_mutex_unlock(&cat_lock);
    var node = categories;
    while (node) |n| : (node = n.next) {
        const cat: *Category = @ptrCast(@alignCast(n.data));
        if (c.g_pattern_spec_match_string(rule.pattern, cat.name) != 0) gst_debug_category_set_threshold(cat, level);
    }
}

pub export fn gst_debug_unset_threshold_for_name(name: [*c]const u8) void {
    if (!check.that(name != null, "gst_debug_unset_threshold_for_name", "name != NULL")) return;
    const pat = c.g_pattern_spec_new(name);
    defer c.g_pattern_spec_free(pat);
    c.g_mutex_lock(&rule_lock);
    var i: usize = 0;
    while (i < rules.items.len) {
        if (c.g_pattern_spec_equal(rules.items[i].pattern, pat) != 0) {
            c.g_pattern_spec_free(rules.items[i].pattern);
            _ = rules.orderedRemove(i);
        } else i += 1;
    }
    c.g_mutex_unlock(&rule_lock);
    resetAll();
}

fn clearRules() void {
    c.g_mutex_lock(&rule_lock);
    defer c.g_mutex_unlock(&rule_lock);
    for (rules.items) |r| c.g_pattern_spec_free(r.pattern);
    rules.clearRetainingCapacity();
}

fn parseLevel(s: [*c]u8) ?Level {
    const str = std.mem.span(c.g_strstrip(s));
    if (str.len == 0) return null;
    if (std.ascii.isDigit(str[0])) return std.fmt.parseInt(Level, str, 10) catch null;
    const names = [_]struct { []const u8, Level }{
        .{ "NONE", c.GST_LEVEL_NONE },   .{ "ERROR", c.GST_LEVEL_ERROR }, .{ "FIXME", c.GST_LEVEL_FIXME },
        .{ "INFO", c.GST_LEVEL_INFO },   .{ "DEBUG", c.GST_LEVEL_DEBUG }, .{ "LOG", c.GST_LEVEL_LOG },
        .{ "TRACE", c.GST_LEVEL_TRACE }, .{ "MEMDUMP", c.GST_LEVEL_MEMDUMP },
    };
    if (std.mem.startsWith(u8, str, "WARN")) return c.GST_LEVEL_WARNING;
    for (names) |n| if (std.mem.eql(u8, str, n[0])) return n[1];
    return null;
}

pub export fn gst_debug_set_threshold_from_string(list: [*c]const u8, reset: c.gboolean) void {
    if (reset != 0) {
        clearRules();
        gst_debug_set_default_threshold(c.GST_LEVEL_DEFAULT);
    }
    const parts = c.g_strsplit(list, ",", 0);
    defer c.g_strfreev(parts);
    var i: usize = 0;
    while (parts[i] != null) : (i += 1) {
        const item = parts[i];
        if (c.strchr(item, ':') != null) {
            const kv = c.g_strsplit(item, ":", 2);
            defer c.g_strfreev(kv);
            if (kv[0] == null or kv[1] == null) continue;
            const name = c.g_strstrip(kv[0]);
            if (name[0] == 0) continue;
            const level = parseLevel(kv[1]) orelse continue;
            gst_debug_set_threshold_for_name(name, level);
            if (level > _gst_debug_min) _gst_debug_min = level;
        } else if (parseLevel(item)) |level| {
            gst_debug_set_default_threshold(level);
        }
    }
}

pub export fn gst_debug_level_get_name(level: Level) [*c]const u8 {
    return switch (level) {
        c.GST_LEVEL_NONE => "",
        c.GST_LEVEL_ERROR => "ERROR  ",
        c.GST_LEVEL_WARNING => "WARN   ",
        c.GST_LEVEL_INFO => "INFO   ",
        c.GST_LEVEL_DEBUG => "DEBUG  ",
        c.GST_LEVEL_LOG => "LOG    ",
        c.GST_LEVEL_FIXME => "FIXME  ",
        c.GST_LEVEL_TRACE => "TRACE  ",
        c.GST_LEVEL_MEMDUMP => "MEMDUMP",
        else => blk: {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "invalid level specified for gst_debug_level_get_name");
            break :blk "";
        },
    };
}

const CatPtr = [*c]Category;
pub export var GST_CAT_DEFAULT: CatPtr = null;
pub export var GST_CAT_GST_INIT: CatPtr = null;
pub export var GST_CAT_MEMORY: CatPtr = null;
pub export var GST_CAT_PARENTAGE: CatPtr = null;
pub export var GST_CAT_STATES: CatPtr = null;
pub export var GST_CAT_SCHEDULING: CatPtr = null;
pub export var GST_CAT_BUFFER: CatPtr = null;
pub export var GST_CAT_BUFFER_LIST: CatPtr = null;
pub export var GST_CAT_BUS: CatPtr = null;
pub export var GST_CAT_CAPS: CatPtr = null;
pub export var GST_CAT_CLOCK: CatPtr = null;
pub export var GST_CAT_ELEMENT_PADS: CatPtr = null;
pub export var GST_CAT_PADS: CatPtr = null;
pub export var GST_CAT_PERFORMANCE: CatPtr = null;
pub export var GST_CAT_PIPELINE: CatPtr = null;
pub export var GST_CAT_PLUGIN_LOADING: CatPtr = null;
pub export var GST_CAT_PLUGIN_INFO: CatPtr = null;
pub export var GST_CAT_PROPERTIES: CatPtr = null;
pub export var GST_CAT_NEGOTIATION: CatPtr = null;
pub export var GST_CAT_REFCOUNTING: CatPtr = null;
pub export var GST_CAT_ERROR_SYSTEM: CatPtr = null;
pub export var GST_CAT_EVENT: CatPtr = null;
pub export var GST_CAT_MESSAGE: CatPtr = null;
pub export var GST_CAT_PARAMS: CatPtr = null;
pub export var GST_CAT_CALL_TRACE: CatPtr = null;
pub export var GST_CAT_SIGNAL: CatPtr = null;
pub export var GST_CAT_PROBE: CatPtr = null;
pub export var GST_CAT_REGISTRY: CatPtr = null;
pub export var GST_CAT_QOS: CatPtr = null;
pub export var GST_CAT_META: CatPtr = null;
pub export var GST_CAT_LOCKING: CatPtr = null;
pub export var GST_CAT_CONTEXT: CatPtr = null;
pub var cat_debug: CatPtr = null;
pub var cat_poll: CatPtr = null;
pub var cat_protection: CatPtr = null;

const B = c.GST_DEBUG_BOLD;
const U = c.GST_DEBUG_UNDERLINE;

var color_mode = std.atomic.Value(c_int).init(c.GST_DEBUG_COLOR_MODE_ON);
var add_default = true;
var pretty_tags = true;

const LogEntry = struct { func: c.GstLogFunction, data: c.gpointer, notify: c.GDestroyNotify };
var log_funcs: ?*c.GSList = null;
var log_lock: c.GRWLock = std.mem.zeroes(c.GRWLock);

fn fileFromEnv(name: [*c]const u8) ?*c.FILE {
    const env = std.mem.span(name);
    if (std.mem.eql(u8, env, "-")) return c.stdout;
    var path = std.ArrayListUnmanaged(u8).empty;
    defer path.deinit(std.heap.c_allocator);
    var i: usize = 0;
    while (i < env.len) : (i += 1) {
        if (env[i] == '%' and i + 1 < env.len and (env[i + 1] == 'p' or env[i + 1] == 'r')) {
            var buf: [32]u8 = undefined;
            const piece = if (env[i + 1] == 'p') std.fmt.bufPrint(&buf, "{d}", .{std.c.getpid()}) catch unreachable else std.fmt.bufPrint(&buf, "{x}", .{c.g_random_int()}) catch unreachable;
            path.appendSlice(std.heap.c_allocator, piece) catch @panic("out of memory");
            i += 1;
        } else path.append(std.heap.c_allocator, env[i]) catch @panic("out of memory");
    }
    path.append(std.heap.c_allocator, 0) catch @panic("out of memory");
    const f = c.fopen(@ptrCast(path.items.ptr), "w");
    if (f == null) {
        c.g_printerr("Could not open log file '%s' for writing: %s\n", name, c.g_strerror(std.c._errno().*));
        return c.stderr;
    }
    return f;
}

pub fn initialize() void {
    if (add_default) {
        const env = c.g_getenv("GST_DEBUG_FILE");
        const out: ?*c.FILE = if (env != null and env[0] != 0) fileFromEnv(env) else c.stderr;
        gst_debug_add_log_function(gst_debug_log_default, out, null);
    }
    printf.describe = describe;
    GST_CAT_DEFAULT = _gst_debug_category_new("default", U, null);
    cat_debug = _gst_debug_category_new("GST_DEBUG", B | c.GST_DEBUG_FG_YELLOW, "debugging subsystem");
    GST_CAT_GST_INIT = _gst_debug_category_new("GST_INIT", B | c.GST_DEBUG_FG_RED, null);
    GST_CAT_MEMORY = _gst_debug_category_new("GST_MEMORY", B | c.GST_DEBUG_FG_BLUE, "memory");
    GST_CAT_PARENTAGE = _gst_debug_category_new("GST_PARENTAGE", B | c.GST_DEBUG_FG_WHITE | c.GST_DEBUG_BG_RED, null);
    GST_CAT_STATES = _gst_debug_category_new("GST_STATES", B | c.GST_DEBUG_FG_RED, null);
    GST_CAT_SCHEDULING = _gst_debug_category_new("GST_SCHEDULING", B | c.GST_DEBUG_FG_MAGENTA, null);
    GST_CAT_BUFFER = _gst_debug_category_new("GST_BUFFER", B | c.GST_DEBUG_BG_GREEN, null);
    GST_CAT_BUFFER_LIST = _gst_debug_category_new("GST_BUFFER_LIST", B | c.GST_DEBUG_BG_GREEN, null);
    GST_CAT_BUS = _gst_debug_category_new("GST_BUS", c.GST_DEBUG_BG_YELLOW, null);
    GST_CAT_CAPS = _gst_debug_category_new("GST_CAPS", B | c.GST_DEBUG_FG_BLUE, null);
    GST_CAT_CLOCK = _gst_debug_category_new("GST_CLOCK", B | c.GST_DEBUG_FG_YELLOW, null);
    GST_CAT_ELEMENT_PADS = _gst_debug_category_new("GST_ELEMENT_PADS", B | c.GST_DEBUG_FG_WHITE | c.GST_DEBUG_BG_RED, null);
    GST_CAT_PADS = _gst_debug_category_new("GST_PADS", B | c.GST_DEBUG_FG_RED | c.GST_DEBUG_BG_BLUE, null);
    GST_CAT_PERFORMANCE = _gst_debug_category_new("GST_PERFORMANCE", B | c.GST_DEBUG_FG_WHITE | c.GST_DEBUG_BG_RED, null);
    GST_CAT_PIPELINE = _gst_debug_category_new("GST_PIPELINE", B | c.GST_DEBUG_FG_WHITE | c.GST_DEBUG_BG_RED, null);
    GST_CAT_PLUGIN_LOADING = _gst_debug_category_new("GST_PLUGIN_LOADING", B | c.GST_DEBUG_FG_CYAN, null);
    GST_CAT_PLUGIN_INFO = _gst_debug_category_new("GST_PLUGIN_INFO", B | c.GST_DEBUG_FG_CYAN, null);
    GST_CAT_PROPERTIES = _gst_debug_category_new("GST_PROPERTIES", B | c.GST_DEBUG_FG_WHITE | c.GST_DEBUG_BG_BLUE, null);
    GST_CAT_NEGOTIATION = _gst_debug_category_new("GST_NEGOTIATION", B | c.GST_DEBUG_FG_BLUE, null);
    GST_CAT_REFCOUNTING = _gst_debug_category_new("GST_REFCOUNTING", B | c.GST_DEBUG_FG_RED | c.GST_DEBUG_BG_BLUE, null);
    GST_CAT_ERROR_SYSTEM = _gst_debug_category_new("GST_ERROR_SYSTEM", B | c.GST_DEBUG_FG_RED | c.GST_DEBUG_BG_WHITE, null);
    GST_CAT_EVENT = _gst_debug_category_new("GST_EVENT", B | c.GST_DEBUG_FG_BLUE, null);
    GST_CAT_MESSAGE = _gst_debug_category_new("GST_MESSAGE", B | c.GST_DEBUG_FG_WHITE | c.GST_DEBUG_BG_RED, null);
    GST_CAT_PARAMS = _gst_debug_category_new("GST_PARAMS", B | c.GST_DEBUG_FG_BLACK | c.GST_DEBUG_BG_YELLOW, null);
    GST_CAT_CALL_TRACE = _gst_debug_category_new("GST_CALL_TRACE", B, null);
    GST_CAT_SIGNAL = _gst_debug_category_new("GST_SIGNAL", B | c.GST_DEBUG_FG_WHITE | c.GST_DEBUG_BG_RED, null);
    GST_CAT_PROBE = _gst_debug_category_new("GST_PROBE", B | c.GST_DEBUG_FG_GREEN, "pad probes");
    GST_CAT_REGISTRY = _gst_debug_category_new("GST_REGISTRY", 0, "registry");
    GST_CAT_QOS = _gst_debug_category_new("GST_QOS", 0, "QoS");
    cat_poll = _gst_debug_category_new("GST_POLL", 0, "poll");
    GST_CAT_META = _gst_debug_category_new("GST_META", 0, "meta");
    GST_CAT_LOCKING = _gst_debug_category_new("GST_LOCKING", 0, "locking");
    GST_CAT_CONTEXT = _gst_debug_category_new("GST_CONTEXT", 0, null);
    cat_protection = _gst_debug_category_new("GST_PROTECTION", 0, "protection");
    if (c.g_getenv("GST_DEBUG_OPTIONS")) |opts| {
        if (c.strstr(opts, "full_tags") != null or c.strstr(opts, "full-tags") != null) pretty_tags = false else if (c.strstr(opts, "pretty_tags") != null or c.strstr(opts, "pretty-tags") != null) pretty_tags = true;
    }
    if (c.g_getenv("GST_DEBUG_NO_COLOR") != null) gst_debug_set_color_mode(c.GST_DEBUG_COLOR_MODE_OFF);
    if (c.g_getenv("GST_DEBUG_COLOR_MODE")) |m| gst_debug_set_color_mode_from_string(m);
    if (c.g_getenv("GST_DEBUG")) |d| gst_debug_set_threshold_from_string(d, 0);
}

pub export fn gst_debug_set_colored(colored: c.gboolean) void {
    color_mode.store(if (colored != 0) c.GST_DEBUG_COLOR_MODE_ON else c.GST_DEBUG_COLOR_MODE_OFF, .monotonic);
}

pub export fn gst_debug_set_color_mode(mode: c.GstDebugColorMode) void {
    color_mode.store(@intCast(mode), .monotonic);
}

pub export fn gst_debug_set_color_mode_from_string(mode: [*c]const u8) void {
    const m = std.mem.span(mode);
    if (std.mem.eql(u8, m, "on") or std.mem.eql(u8, m, "auto")) gst_debug_set_color_mode(c.GST_DEBUG_COLOR_MODE_ON) else if (std.mem.eql(u8, m, "off") or std.mem.eql(u8, m, "disable")) gst_debug_set_color_mode(c.GST_DEBUG_COLOR_MODE_OFF) else if (std.mem.eql(u8, m, "unix")) gst_debug_set_color_mode(c.GST_DEBUG_COLOR_MODE_UNIX);
}

pub export fn gst_debug_is_colored() c.gboolean {
    const m = color_mode.load(.monotonic);
    return @intFromBool(m == c.GST_DEBUG_COLOR_MODE_UNIX or m == c.GST_DEBUG_COLOR_MODE_ON);
}

pub export fn gst_debug_get_color_mode() c.GstDebugColorMode {
    return @intCast(color_mode.load(.monotonic));
}

pub export fn gst_debug_set_active(active: c.gboolean) void {
    _gst_debug_enabled = active;
    _gst_debug_min = if (active != 0) c.GST_LEVEL_COUNT else c.GST_LEVEL_NONE;
}

pub export fn gst_debug_is_active() c.gboolean {
    return _gst_debug_enabled;
}

fn termColor(info: c.guint, out: *[20]u8) []const u8 {
    var n: usize = 0;
    const put = struct {
        fn f(o: *[20]u8, at: *usize, s: []const u8) void {
            @memcpy(o[at.*..][0..s.len], s);
            at.* += s.len;
        }
    }.f;
    put(out, &n, "\x1b[00");
    if (info & B != 0) put(out, &n, ";01");
    if (info & U != 0) put(out, &n, ";04");
    if (info & c.GST_DEBUG_FG_MASK != 0) put(out, &n, &.{ ';', '3', @as(u8, '0') + @as(u8, @intCast(info & c.GST_DEBUG_FG_MASK)) });
    if (info & c.GST_DEBUG_BG_MASK != 0) put(out, &n, &.{ ';', '4', @as(u8, '0') + @as(u8, @intCast((info & c.GST_DEBUG_BG_MASK) >> 4)) });
    put(out, &n, "m");
    return out[0..n];
}

pub export fn gst_debug_construct_term_color(info: c.guint) [*c]u8 {
    var buf: [20]u8 = undefined;
    const s = termColor(info, &buf);
    return c.g_strndup(s.ptr, s.len);
}

pub export fn gst_debug_construct_win_color(info: c.guint) c.gint {
    const map = [_]c.gint{ 0, 4, 2, 6, 1, 5, 3, 7 };
    var color: c.gint = 0;
    if (info & c.GST_DEBUG_FG_MASK != 0) color = map[info & 7];
    if (info & c.GST_DEBUG_BG_MASK != 0) color |= map[(info >> 4) & 7] << 4;
    if (info & B != 0) color |= 8;
    return color;
}

pub export fn gst_debug_add_log_function(func_in: c.GstLogFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    const func = func_in orelse gst_debug_log_default;
    const e: *LogEntry = @ptrCast(@alignCast(c.g_malloc(@sizeOf(LogEntry))));
    e.* = .{ .func = func, .data = data, .notify = notify };
    c.g_rw_lock_writer_lock(&log_lock);
    log_funcs = c.g_slist_prepend(log_funcs, e);
    c.g_rw_lock_writer_unlock(&log_lock);
}

fn removeWhere(comptime match: fn (*LogEntry, c.gpointer) bool, key: c.gpointer) c.guint {
    var gone: ?*c.GSList = null;
    var n: c.guint = 0;
    c.g_rw_lock_writer_lock(&log_lock);
    var node = log_funcs;
    while (node) |cur| {
        const next = cur.next;
        if (match(@ptrCast(@alignCast(cur.data)), key)) {
            gone = c.g_slist_prepend(gone, cur.data);
            log_funcs = c.g_slist_delete_link(log_funcs, cur);
            n += 1;
        }
        node = next;
    }
    c.g_rw_lock_writer_unlock(&log_lock);
    while (gone) |g| {
        const e: *LogEntry = @ptrCast(@alignCast(g.data));
        if (e.notify) |f| f(e.data);
        c.g_free(e);
        gone = c.g_slist_delete_link(gone, g);
    }
    return n;
}

fn byFunc(e: *LogEntry, key: c.gpointer) bool {
    return @intFromPtr(e.func) == @intFromPtr(key);
}

fn byData(e: *LogEntry, key: c.gpointer) bool {
    return e.data == key;
}

pub export fn gst_debug_remove_log_function(func_in: c.GstLogFunction) c.guint {
    const func = func_in orelse gst_debug_log_default;
    var n = removeWhere(byFunc, @constCast(@ptrCast(func)));
    if (@import("core.zig").gst_is_initialized() == 0 and func == @as(c.GstLogFunction, gst_debug_log_default)) {
        add_default = false;
        n += 1;
    }
    return n;
}

pub export fn gst_debug_remove_log_function_by_data(data: c.gpointer) c.guint {
    return removeWhere(byData, data);
}

const Message = struct {
    format: [*c]const u8,
    object: [*c]c.GObject,
    text: [*c]u8,
    owned_text: bool,
    id: [*c]u8,
    free_id: bool,
    args: ?*va.VaList,
};

pub export fn gst_debug_message_get(m: ?*c.GstDebugMessage) [*c]const u8 {
    const msg: *Message = @ptrCast(@alignCast(m));
    if (msg.text == null) {
        if (msg.args) |ap| {
            var copy = @cVaCopy(ap);
            defer @cVaEnd(&copy);
            if (printf.vasprintf(&msg.text, msg.format, &copy) < 0) msg.text = null;
        }
    }
    return msg.text;
}

fn padType() ?*const fn () callconv(.c) c.GType {
    return @import("gtype.zig").lookup(?*const fn () callconv(.c) c.GType, "gst_pad_get_type");
}

fn isA(obj: ?*anyopaque, t: c.GType) bool {
    if (obj == null or t == 0) return false;
    return c.g_type_check_instance_is_a(@ptrCast(@alignCast(obj)), t) != 0;
}

fn isPad(obj: ?*anyopaque) bool {
    const f = padType() orelse return false;
    return isA(obj, f());
}

fn objectName(obj: ?*anyopaque) [*c]u8 {
    return @as(*c.GstObject, @ptrCast(@alignCast(obj))).name;
}

fn padName(obj: ?*anyopaque) [*c]u8 {
    const o: *c.GstObject = @ptrCast(@alignCast(obj));
    const parent = o.parent;
    const pname: [*c]const u8 = if (parent != null) (if (parent[0].name != null) parent[0].name else "(NULL)") else "''";
    return c.g_strdup_printf("%s:%s", pname, if (o.name != null) o.name else @as([*c]const u8, "(NULL)"));
}

fn objectId(obj: ?*anyopaque, allocated: *bool) [*c]u8 {
    allocated.* = true;
    if (isPad(obj) and objectName(obj) != null) return padName(obj);
    if (isA(obj, c.gst_object_get_type()) and objectName(obj) != null) {
        allocated.* = false;
        return objectName(obj);
    }
    if (isA(obj, c.G_TYPE_OBJECT)) return c.g_strdup_printf("%s@%p", c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(obj))).g_class[0].g_type), obj);
    return c.g_strdup_printf("%p", obj);
}

pub export fn gst_debug_message_get_id(m: ?*c.GstDebugMessage) [*c]const u8 {
    const msg: *Message = @ptrCast(@alignCast(m));
    if (msg.id == null and msg.object != null) msg.id = objectId(msg.object, &msg.free_id);
    return msg.id;
}

fn dispatch(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, msg: *Message) void {
    c.g_rw_lock_reader_lock(&log_lock);
    var node = log_funcs;
    while (node) |n| : (node = n.next) {
        const e: *LogEntry = @ptrCast(@alignCast(n.data));
        e.func.?(cat, level, file, func, line, object, @ptrCast(msg), e.data);
    }
    c.g_rw_lock_reader_unlock(&log_lock);
    if (msg.free_id) c.g_free(msg.id);
}

fn logGuards(comptime f: []const u8, cat: CatPtr, file: [*c]const u8, func: [*c]const u8, text: [*c]const u8, comptime text_name: []const u8) bool {
    if (!check.that(file != null, f, "file != NULL")) return false;
    if (!check.that(func != null, f, "function != NULL")) return false;
    _ = cat;
    return check.that(text != null, f, text_name ++ " != NULL");
}

fn logVa(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, id: [*c]const u8, format: [*c]const u8, ap: *va.VaList) callconv(.c) void {
    if (!check.that(cat != null, "gst_debug_log_full_valist", "category != NULL")) return;
    if (level > gst_debug_category_get_threshold(cat)) return;
    if (!logGuards("gst_debug_log_full_valist", cat, file, func, format, "format")) return;
    var copy = @cVaCopy(ap);
    defer @cVaEnd(&copy);
    var msg = Message{ .format = format, .object = object, .text = null, .owned_text = true, .id = @constCast(id), .free_id = false, .args = &copy };
    dispatch(cat, level, file, func, line, object, &msg);
    c.g_free(msg.text);
}

pub export fn gst_debug_log(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, format: [*c]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    logVa(cat, level, file, func, line, object, null, format, &ap);
}

pub export fn gst_debug_log_id(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, id: [*c]const u8, format: [*c]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    logVa(cat, level, file, func, line, null, id, format, &ap);
}

pub export fn gst_debug_log_valist(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, format: [*c]const u8, ap: va.CVaList) void {
    logVa(cat, level, file, func, line, object, null, format, va.fromC(ap));
}

pub export fn gst_debug_log_id_valist(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, id: [*c]const u8, format: [*c]const u8, ap: va.CVaList) void {
    logVa(cat, level, file, func, line, null, id, format, va.fromC(ap));
}

fn logText(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, id: [*c]const u8, text: [*c]const u8) void {
    if (!check.that(cat != null, "gst_debug_log_literal_full", "category != NULL")) return;
    if (level > gst_debug_category_get_threshold(cat)) return;
    if (!logGuards("gst_debug_log_literal_full", cat, file, func, text, "message_string")) return;
    var msg = Message{ .format = null, .object = object, .text = @constCast(text), .owned_text = false, .id = @constCast(id), .free_id = false, .args = null };
    dispatch(cat, level, file, func, line, object, &msg);
}

pub export fn gst_debug_log_literal(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, text: [*c]const u8) void {
    logText(cat, level, file, func, line, object, null, text);
}

pub export fn gst_debug_log_id_literal(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, id: [*c]const u8, text: [*c]const u8) void {
    logText(cat, level, file, func, line, null, id, text);
}

fn basename(file: [*c]const u8) [*c]const u8 {
    const slash = c.strrchr(file, '/');
    if (slash != null) return slash + 1;
    if (std.ascii.isAlphabetic(file[0]) and file[1] == ':') return file + 2;
    return file;
}

const Preamble = struct { file: [*c]const u8, text: [*c]const u8, id: [*c]const u8, elapsed: c.GstClockTime };

fn preamble(m: ?*c.GstDebugMessage, file_in: [*c]const u8) Preamble {
    const text = gst_debug_message_get(m);
    var file = file_in;
    const ch = file[0];
    if (ch == '.' or ch == '/' or ch == '\\' or (ch != 0 and file[1] == ':')) file = basename(file);
    const start = @import("core.zig").start_time;
    const now = @import("util.zig").gst_util_get_timestamp();
    return .{ .file = file, .text = text, .id = gst_debug_message_get_id(m), .elapsed = now -% start };
}

fn tid() c_int {
    return @intCast(std.os.linux.gettid());
}

fn timeParts(t: c.GstClockTime) [4]c.guint {
    if (t == std.math.maxInt(u64)) return .{ 99, 99, 99, 999999999 };
    const s: u64 = 1000000000;
    return .{ @truncate(t / (s * 3600)), @truncate((t / (s * 60)) % 60), @truncate((t / s) % 60), @truncate(t % s) };
}

pub export fn gst_debug_log_get_line(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, _: [*c]c.GObject, m: ?*c.GstDebugMessage) [*c]u8 {
    const p = preamble(m, file);
    const t = timeParts(p.elapsed);
    const id: [*c]const u8 = if (p.id != null) p.id else "";
    const fmt: [*c]const u8 = if (p.id != null) "%u:%02u:%02u.%09u %10d %10d %s %20s %s:%d:%s:<%s> %s\n" else "%u:%02u:%02u.%09u %10d %10d %s %20s %s:%d:%s:%s %s\n";
    return c.g_strdup_printf(fmt, t[0], t[1], t[2], t[3], std.c.getpid(), tid(), gst_debug_level_get_name(level), gst_debug_category_get_name(cat), p.file, line, func, id, p.text);
}

const level_colors = [_][*c]const u8{ "\x1b[37m", "\x1b[31;01m", "\x1b[33;01m", "\x1b[32;01m", "\x1b[36m", "\x1b[37m", "\x1b[33;01m", "\x1b[37m", "\x1b[37m", "\x1b[37m" };

pub export fn gst_debug_log_default(cat: CatPtr, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, _: [*c]c.GObject, m: ?*c.GstDebugMessage, data: c.gpointer) void {
    const out: ?*c.FILE = if (data != null) @ptrCast(@alignCast(data)) else c.stderr;
    const p = preamble(m, file);
    const pid = std.c.getpid();
    const t = timeParts(p.elapsed);
    const name = gst_debug_category_get_name(cat);
    if (gst_debug_get_color_mode() != c.GST_DEBUG_COLOR_MODE_OFF) {
        var cbuf: [21]u8 = undefined;
        const color = termColor(gst_debug_category_get_color(cat), cbuf[0..20]);
        cbuf[color.len] = 0;
        var pidcolor: [12]u8 = undefined;
        _ = std.fmt.bufPrintZ(&pidcolor, "\x1b[{d:0>2}m", .{@as(u32, @intCast(@mod(pid, 6) + 31))}) catch unreachable;
        const lc = level_colors[@intCast(@min(@as(c_uint, @intCast(level)), level_colors.len - 1))];
        if (p.id != null) {
            _ = c.fprintf(out, "%u:%02u:%02u.%09u %s%10d%s %10d %s%s%s %s%20s %s:%d:%s:<%s>%s %s\n", t[0], t[1], t[2], t[3], &pidcolor, pid, "\x1b[00m", tid(), lc, gst_debug_level_get_name(level), "\x1b[00m", &cbuf, name, p.file, line, func, p.id, "\x1b[00m", p.text);
        } else {
            _ = c.fprintf(out, "%u:%02u:%02u.%09u %s%10d%s %10d %s%s%s %s%20s %s:%d:%s:%s%s %s\n", t[0], t[1], t[2], t[3], &pidcolor, pid, "\x1b[00m", tid(), lc, gst_debug_level_get_name(level), "\x1b[00m", &cbuf, name, p.file, line, func, "", "\x1b[00m", p.text);
        }
    } else if (p.id != null) {
        _ = c.fprintf(out, "%u:%02u:%02u.%09u %10d %10d %s %20s %s:%d:%s:<%s> %s\n", t[0], t[1], t[2], t[3], pid, tid(), gst_debug_level_get_name(level), name, p.file, line, func, p.id, p.text);
    } else {
        _ = c.fprintf(out, "%u:%02u:%02u.%09u %10d %10d %s %20s %s:%d:%s:%s %s\n", t[0], t[1], t[2], t[3], pid, tid(), gst_debug_level_get_name(level), name, p.file, line, func, "", p.text);
    }
    _ = c.fflush(out);
}

var funcptrs: ?*c.GHashTable = null;
var funcptr_lock: c.GMutex = std.mem.zeroes(c.GMutex);

pub export fn _gst_debug_register_funcptr(func: c.GstDebugFuncPtr, name: [*c]const u8) void {
    c.g_mutex_lock(&funcptr_lock);
    defer c.g_mutex_unlock(&funcptr_lock);
    if (funcptrs == null) funcptrs = c.g_hash_table_new(c.g_direct_hash, c.g_direct_equal);
    const key: c.gpointer = @constCast(@ptrCast(func));
    if (c.g_hash_table_lookup(funcptrs, key) == null) _ = c.g_hash_table_insert(funcptrs, key, @constCast(name));
}

pub export fn _gst_debug_nameof_funcptr(func: c.GstDebugFuncPtr) [*c]const u8 {
    if (func == null) return "(NULL)";
    const key: c.gpointer = @constCast(@ptrCast(func));
    c.g_mutex_lock(&funcptr_lock);
    const known: [*c]const u8 = if (funcptrs != null) @ptrCast(c.g_hash_table_lookup(funcptrs, key)) else null;
    c.g_mutex_unlock(&funcptr_lock);
    if (known != null) return known;
    var dl: c.Dl_info = undefined;
    if (c.dladdr(key, &dl) != 0 and dl.dli_sname != null) {
        const name = c.g_intern_string(dl.dli_sname);
        _gst_debug_register_funcptr(func, name);
        return name;
    }
    const tmp = c.g_strdup_printf("%p", key);
    const name = c.g_intern_string(tmp);
    c.g_free(tmp);
    _gst_debug_register_funcptr(func, name);
    return name;
}

fn dumpLine(buf: []u8, mem: [*c]const u8, offset: usize, size_in: usize) [*c]u8 {
    const size = @min(size_in, 16);
    var hex: [50]u8 = std.mem.zeroes([50]u8);
    var asc: [18]u8 = std.mem.zeroes([18]u8);
    if (mem != null) {
        var h: usize = 0;
        for (0..size) |i| {
            const b = mem[offset + i];
            asc[i] = if (std.ascii.isPrint(b)) b else '.';
            _ = std.fmt.bufPrint(hex[h..], "{x:0>2} ", .{b}) catch unreachable;
            h += 3;
        }
    }
    _ = c.g_snprintf(buf.ptr, buf.len, "%08x: %-48.48s %-16.16s", @as(c.guint, @truncate(offset)), &hex, &asc);
    return buf.ptr;
}

fn dumpMem(cat: CatPtr, file: [*c]const u8, func: [*c]const u8, line: c.gint, obj: [*c]c.GObject, id_in: [*c]const u8, msg: [*c]const u8, data: [*c]const u8, length: c.guint) void {
    var allocated = false;
    var id: [*c]const u8 = id_in;
    if (id == null and obj != null) id = objectId(obj, &allocated);
    const rule = "---------------------------------------------------------------------------";
    gst_debug_log_id_literal(cat, c.GST_LEVEL_MEMDUMP, file, func, line, id, rule);
    if (msg != null and msg[0] != 0) gst_debug_log_id_literal(cat, c.GST_LEVEL_MEMDUMP, file, func, line, id, msg);
    var off: usize = 0;
    while (off < length) : (off += 16) {
        var buf: [128]u8 = undefined;
        gst_debug_log_id_literal(cat, c.GST_LEVEL_MEMDUMP, file, func, line, id, dumpLine(&buf, data, off, length - off));
    }
    gst_debug_log_id_literal(cat, c.GST_LEVEL_MEMDUMP, file, func, line, id, rule);
    if (allocated) c.g_free(@constCast(id));
}

pub export fn _gst_debug_dump_mem(cat: CatPtr, file: [*c]const u8, func: [*c]const u8, line: c.gint, obj: [*c]c.GObject, msg: [*c]const u8, data: [*c]const u8, length: c.guint) void {
    dumpMem(cat, file, func, line, obj, null, msg, data, length);
}

pub export fn _gst_debug_dump_mem_id(cat: CatPtr, file: [*c]const u8, func: [*c]const u8, line: c.gint, id: [*c]const u8, msg: [*c]const u8, data: [*c]const u8, length: c.guint) void {
    dumpMem(cat, file, func, line, null, id, msg, data, length);
}

fn prettify(text: [*c]u8) [*c]u8 {
    if (text == null) return null;
    var pos: [*c]u8 = text;
    while (true) {
        pos = c.strstr(pos, "(buffer)");
        if (pos == null) break;
        pos += 8;
        var end = pos;
        while (end[0] != 0 and end[0] != ';' and end[0] != ' ') end += 1;
        const count = @intFromPtr(end) - @intFromPtr(pos);
        if (count > 100) {
            @memcpy(pos[94..96], "..");
            std.mem.copyForwards(u8, pos[96..100], pos[count - 4 .. count]);
            const rest = std.mem.len(pos + count) + 1;
            std.mem.copyForwards(u8, pos[100 .. 100 + rest], pos[count .. count + rest]);
            pos += 100;
        }
    }
    return text;
}

fn structureText(s: [*c]const c.GstStructure) [*c]u8 {
    if (s == null) return null;
    const text = c.gst_structure_to_string(s);
    if (pretty_tags and c.gst_structure_has_name(s, "taglist") != 0) return prettify(text);
    return text;
}

fn typeOfFirstWord(p: ?*anyopaque) c.GType {
    return @as(*const c.GType, @ptrCast(@alignCast(p))).*;
}

fn miniType(p: ?*anyopaque) c.GType {
    return @as(*const c.GstMiniObject, @ptrCast(@alignCast(p))).type;
}

fn bufferText(b: [*c]c.GstBuffer) [*c]u8 {
    var ob: [32]u8 = undefined;
    var oe: [32]u8 = undefined;
    const none = std.math.maxInt(u64);
    const os: [*c]const u8 = if (b[0].offset != none) (std.fmt.bufPrintZ(&ob, "{d}", .{b[0].offset}) catch unreachable).ptr else "none";
    const oes: [*c]const u8 = if (b[0].offset_end != none) (std.fmt.bufPrintZ(&oe, "{d}", .{b[0].offset_end}) catch unreachable).ptr else "none";
    const pts = printf.timeAlloc(b[0].pts);
    const dts = printf.timeAlloc(b[0].dts);
    const dur = printf.timeAlloc(b[0].duration);
    defer for ([_][*c]u8{ pts, dts, dur }) |x| c.g_free(x);
    return c.g_strdup_printf("buffer: %p, pts %s, dts %s, dur %s, size %lu, offset %s, offset_end %s, flags 0x%x", b, pts, dts, dur, c.gst_buffer_get_size(b), os, oes, b[0].mini_object.flags);
}

fn bufferListText(l: ?*c.GstBufferList) [*c]u8 {
    const n = c.gst_buffer_list_length(l);
    var pts: u64 = std.math.maxInt(u64);
    var dts: u64 = std.math.maxInt(u64);
    var total: usize = 0;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const b = c.gst_buffer_list_get(l, i);
        if (i == 0) {
            pts = b[0].pts;
            dts = b[0].dts;
        }
        total += c.gst_buffer_get_size(b);
    }
    const ps = printf.timeAlloc(pts);
    const ds = printf.timeAlloc(dts);
    defer c.g_free(ps);
    defer c.g_free(ds);
    return c.g_strdup_printf("bufferlist: %p, %u buffers, pts %s, dts %s, size %lu", l, n, ps, ds, total);
}

pub export fn gst_debug_print_object(ptr: c.gconstpointer) [*c]u8 {
    const p: ?*anyopaque = @constCast(ptr);
    if (p == null) return c.g_strdup("(NULL)");
    if (miniType(p) == c.gst_caps_get_type()) return c.gst_caps_to_string(@ptrCast(@alignCast(p)));
    if (typeOfFirstWord(p) == c.gst_structure_get_type()) return structureText(@ptrCast(@alignCast(p)));
    if (typeOfFirstWord(p) == c.gst_caps_features_get_type()) return c.gst_caps_features_to_string(@ptrCast(@alignCast(p)));
    if (miniType(p) == c.gst_tag_list_get_type()) {
        const t = c.gst_tag_list_to_string(@ptrCast(@alignCast(p)));
        return if (pretty_tags) prettify(t) else t;
    }
    if (miniType(p) == c.gst_date_time_get_type()) return @import("datetime.zig").serialize(@ptrCast(@alignCast(p)), true);
    if (miniType(p) == c.gst_buffer_get_type()) return bufferText(@ptrCast(@alignCast(p)));
    if (miniType(p) == c.gst_buffer_list_get_type()) return bufferListText(@ptrCast(@alignCast(p)));
    if (isPad(p) and objectName(p) != null) {
        const n = padName(p);
        defer c.g_free(n);
        return c.g_strdup_printf("<%s>", n);
    }
    if (isA(p, c.gst_object_get_type()) and objectName(p) != null) return c.g_strdup_printf("<%s>", objectName(p));
    if (isA(p, c.G_TYPE_OBJECT)) return c.g_strdup_printf("<%s@%p>", c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class[0].g_type), p);
    return c.g_strdup_printf("%p", p);
}

pub export fn gst_debug_print_segment(seg: [*c]const c.GstSegment) [*c]u8 {
    if (seg == null) return c.g_strdup("(NULL)");
    const s = seg.*;
    if (s.format == c.GST_FORMAT_UNDEFINED) return c.g_strdup_printf("UNDEFINED segment");
    if (s.format == c.GST_FORMAT_TIME) {
        var parts: [7][*c]u8 = undefined;
        for ([_]u64{ s.start, s.offset, s.stop, s.time, s.base, s.position, s.duration }, 0..) |v, i| parts[i] = printf.timeAlloc(v);
        defer for (parts) |x| c.g_free(x);
        var rb: [40]u8 = undefined;
        var ab: [40]u8 = undefined;
        return c.g_strdup_printf("time segment start=%s, offset=%s, stop=%s, rate=%s, applied_rate=%s, flags=0x%02x, time=%s, base=%s, position %s, duration %s", parts[0], parts[1], parts[2], c.g_ascii_formatd(&rb, rb.len, "%f", s.rate), c.g_ascii_formatd(&ab, ab.len, "%f", s.applied_rate), @as(c.guint, s.flags), parts[3], parts[4], parts[5], parts[6]);
    }
    var name = c.gst_format_get_name(s.format);
    if (name == null) name = "(UNKNOWN FORMAT)";
    var rb: [40]u8 = undefined;
    var ab: [40]u8 = undefined;
    return c.g_strdup_printf("%s segment start=%ld, offset=%ld, stop=%ld, rate=%s, applied_rate=%s, flags=0x%02x, time=%ld, base=%ld, position %ld, duration %ld", name, s.start, s.offset, s.stop, c.g_ascii_formatd(&rb, rb.len, "%f", s.rate), c.g_ascii_formatd(&ab, ab.len, "%f", s.applied_rate), @as(c.guint, s.flags), s.time, s.base, s.position, s.duration);
}

fn describe(kind: u8, ptr: ?*anyopaque) [*c]u8 {
    return switch (kind) {
        'A' => gst_debug_print_object(ptr),
        'B' => gst_debug_print_segment(@ptrCast(@alignCast(ptr))),
        'T' => if (ptr != null) printf.timeAlloc(@as(*const u64, @ptrCast(@alignCast(ptr))).*) else null,
        'S' => if (ptr != null) printf.stimeAlloc(@as(*const i64, @ptrCast(@alignCast(ptr))).*) else null,
        'a' => @import("vbasic.zig").takeAndWrap(gst_debug_print_object(ptr)),
        else => null,
    };
}

fn strdupVa(format: [*c]const u8, ap: *va.VaList) callconv(.c) [*c]u8 {
    var out: [*c]u8 = null;
    if (printf.vasprintf(&out, format, ap) < 0) return null;
    return out;
}

pub export fn gst_info_vasprintf(result: [*c][*c]u8, format: [*c]const u8, ap: va.CVaList) c.gint {
    return printf.vasprintf(result, format, va.fromC(ap));
}

pub export fn gst_info_strdup_vprintf(format: [*c]const u8, ap: va.CVaList) [*c]u8 {
    return strdupVa(format, va.fromC(ap));
}

pub export fn gst_info_strdup_printf(format: [*c]const u8, ...) callconv(.c) [*c]u8 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return strdupVa(format, &ap);
}

fn emit(text: [*c]u8, comptime err: bool, comptime newline: bool) void {
    const fmt = if (newline) "%s\n" else "%s";
    if (err) c.g_printerr(fmt, text) else c.g_print(fmt, text);
    c.g_free(text);
}

pub export fn gst_print(format: [*c]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    emit(strdupVa(format, &ap), false, false);
}

pub export fn gst_println(format: [*c]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    emit(strdupVa(format, &ap), false, true);
}

pub export fn gst_printerr(format: [*c]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    emit(strdupVa(format, &ap), true, false);
}

pub export fn gst_printerrln(format: [*c]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    emit(strdupVa(format, &ap), true, true);
}

fn byName(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return c.strcmp(gst_debug_category_get_name(@ptrCast(@constCast(@alignCast(a)))), gst_debug_category_get_name(@ptrCast(@constCast(@alignCast(b)))));
}

pub fn printHelp() void {
    const sorted: ?*c.GSList = c.g_slist_sort(gst_debug_get_all_categories(), byName);
    defer c.g_slist_free(sorted);
    var list = sorted;
    c.g_print("\n");
    c.g_print("name                  level    description\n");
    c.g_print("---------------------+--------+--------------------------------\n");
    while (list) |n| : (list = n.next) {
        const cat: CatPtr = @ptrCast(@alignCast(n.data));
        const mode = gst_debug_get_color_mode();
        const level = gst_debug_category_get_threshold(cat);
        if (mode == c.GST_DEBUG_COLOR_MODE_UNIX or mode == c.GST_DEBUG_COLOR_MODE_ON) {
            const color = gst_debug_construct_term_color(cat[0].color);
            defer c.g_free(color);
            c.g_print("%s%-20s\x1b[00m  %1d %s  %s%s\x1b[00m\n", color, gst_debug_category_get_name(cat), level, gst_debug_level_get_name(level), color, gst_debug_category_get_description(cat));
        } else c.g_print("%-20s  %1d %s  %s\n", gst_debug_category_get_name(cat), level, gst_debug_level_get_name(level), gst_debug_category_get_description(cat));
    }
    c.g_print("\n");
}
