pub const pw_thread_loop = opaque {};
pub const pw_loop = opaque {};
pub const pw_context = opaque {};
pub const pw_core = opaque {};
pub const pw_stream = opaque {};
pub const pw_properties = opaque {};

pub const spa_pod = extern struct {
    size: u32,
    type: u32,
};

pub const spa_chunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};

pub const spa_data = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    mapoffset: u32,
    maxsize: u32,
    data: ?*anyopaque,
    chunk: ?*spa_chunk,
};

pub const spa_meta = extern struct {
    type: u32,
    size: u32,
    data: ?*anyopaque,
};

pub const spa_buffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: ?[*]spa_meta,
    datas: [*]spa_data,
};

pub const pw_buffer = extern struct {
    buffer: ?*spa_buffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
};

pub const spa_hook = extern struct {
    prev: ?*anyopaque = null,
    next: ?*anyopaque = null,
    funcs: ?*const anyopaque = null,
    data: ?*anyopaque = null,
    removed: ?*anyopaque = null,
    priv: ?*anyopaque = null,
};

pub const State = c_int;
pub const STATE_ERROR: State = -1;
pub const STATE_UNCONNECTED: State = 0;
pub const STATE_STREAMING: State = 3;

pub const pw_stream_events = extern struct {
    version: u32 = VERSION_STREAM_EVENTS,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (?*anyopaque, State, State, ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const anyopaque = null,
    io_changed: ?*const anyopaque = null,
    param_changed: ?*const fn (?*anyopaque, u32, ?*const spa_pod) callconv(.c) void = null,
    add_buffer: ?*const anyopaque = null,
    remove_buffer: ?*const anyopaque = null,
    process: ?*const fn (?*anyopaque) callconv(.c) void = null,
    drained: ?*const anyopaque = null,
    command: ?*const anyopaque = null,
    trigger_done: ?*const anyopaque = null,
};

pub const VERSION_STREAM_EVENTS: u32 = 2;
pub const DIRECTION_INPUT: u32 = 0;
pub const FLAG_AUTOCONNECT: u32 = 1 << 0;
pub const FLAG_MAP_BUFFERS: u32 = 1 << 2;
pub const ID_ANY: u32 = 0xffffffff;

pub extern fn pw_init(argc: ?*c_int, argv: ?*anyopaque) void;
pub extern fn pw_thread_loop_new(name: [*:0]const u8, props: ?*const anyopaque) ?*pw_thread_loop;
pub extern fn pw_thread_loop_get_loop(l: ?*pw_thread_loop) ?*pw_loop;
pub extern fn pw_thread_loop_start(l: ?*pw_thread_loop) c_int;
pub extern fn pw_thread_loop_stop(l: ?*pw_thread_loop) void;
pub extern fn pw_thread_loop_lock(l: ?*pw_thread_loop) void;
pub extern fn pw_thread_loop_unlock(l: ?*pw_thread_loop) void;
pub extern fn pw_thread_loop_destroy(l: ?*pw_thread_loop) void;
pub extern fn pw_context_new(l: ?*pw_loop, props: ?*pw_properties, user_data_size: usize) ?*pw_context;
pub extern fn pw_context_destroy(ctx: ?*pw_context) void;
pub extern fn pw_context_connect(ctx: ?*pw_context, props: ?*pw_properties, user_data_size: usize) ?*pw_core;
pub extern fn pw_context_connect_fd(ctx: ?*pw_context, fd: c_int, props: ?*pw_properties, user_data_size: usize) ?*pw_core;
pub extern fn pw_core_disconnect(core: ?*pw_core) c_int;
pub extern fn pw_properties_new(key: ?[*:0]const u8, ...) ?*pw_properties;
pub extern fn pw_properties_set(props: ?*pw_properties, key: [*c]const u8, value: [*c]const u8) c_int;
pub extern fn pw_stream_new(core: ?*pw_core, name: [*c]const u8, props: ?*pw_properties) ?*pw_stream;
pub extern fn pw_stream_add_listener(s: ?*pw_stream, hook: *spa_hook, events: *const pw_stream_events, data: ?*anyopaque) void;
pub extern fn pw_stream_connect(s: ?*pw_stream, direction: u32, target: u32, flags: u32, params: [*]const *const spa_pod, n: u32) c_int;
pub extern fn pw_stream_update_params(s: ?*pw_stream, params: [*]const *const spa_pod, n: u32) c_int;
pub extern fn pw_stream_dequeue_buffer(s: ?*pw_stream) ?*pw_buffer;
pub extern fn pw_stream_queue_buffer(s: ?*pw_stream, b: *pw_buffer) c_int;
pub extern fn pw_stream_disconnect(s: ?*pw_stream) c_int;
pub extern fn pw_stream_destroy(s: ?*pw_stream) void;
