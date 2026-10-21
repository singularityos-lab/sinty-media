const c = @import("../c.zig").c;

comptime {
    @import("../abi.zig").check(@This());
}

const Q = c.GstQueueArray;

fn v(q: ?*Q) ?*c.GstVecDeque {
    return @ptrCast(q);
}

pub export fn gst_queue_array_new_for_struct(size: c.gsize, initial: c.guint) ?*Q {
    return @ptrCast(c.gst_vec_deque_new_for_struct(size, initial));
}

pub export fn gst_queue_array_new(initial: c.guint) ?*Q {
    return @ptrCast(c.gst_vec_deque_new(initial));
}

pub export fn gst_queue_array_free(q: ?*Q) void {
    c.gst_vec_deque_free(v(q));
}

pub export fn gst_queue_array_set_clear_func(q: ?*Q, f: c.GDestroyNotify) void {
    c.gst_vec_deque_set_clear_func(v(q), f);
}

pub export fn gst_queue_array_clear(q: ?*Q) void {
    c.gst_vec_deque_clear(v(q));
}

pub export fn gst_queue_array_pop_head_struct(q: ?*Q) c.gpointer {
    return c.gst_vec_deque_pop_head_struct(v(q));
}

pub export fn gst_queue_array_pop_head(q: ?*Q) c.gpointer {
    return c.gst_vec_deque_pop_head(v(q));
}

pub export fn gst_queue_array_peek_head_struct(q: ?*Q) c.gpointer {
    return c.gst_vec_deque_peek_head_struct(v(q));
}

pub export fn gst_queue_array_peek_head(q: ?*Q) c.gpointer {
    return c.gst_vec_deque_peek_head(v(q));
}

pub export fn gst_queue_array_peek_nth(q: ?*Q, i: c.guint) c.gpointer {
    return c.gst_vec_deque_peek_nth(v(q), i);
}

pub export fn gst_queue_array_peek_nth_struct(q: ?*Q, i: c.guint) c.gpointer {
    return c.gst_vec_deque_peek_nth_struct(v(q), i);
}

pub export fn gst_queue_array_push_tail_struct(q: ?*Q, p: c.gpointer) void {
    c.gst_vec_deque_push_tail_struct(v(q), p);
}

pub export fn gst_queue_array_push_tail(q: ?*Q, p: c.gpointer) void {
    c.gst_vec_deque_push_tail(v(q), p);
}

pub export fn gst_queue_array_push_sorted(q: ?*Q, p: c.gpointer, f: c.GCompareDataFunc, data: c.gpointer) void {
    c.gst_vec_deque_push_sorted(v(q), p, f, data);
}

pub export fn gst_queue_array_push_sorted_struct(q: ?*Q, p: c.gpointer, f: c.GCompareDataFunc, data: c.gpointer) void {
    c.gst_vec_deque_push_sorted_struct(v(q), p, f, data);
}

pub export fn gst_queue_array_sort(q: ?*Q, f: c.GCompareDataFunc, data: c.gpointer) void {
    c.gst_vec_deque_sort(v(q), f, data);
}

pub export fn gst_queue_array_peek_tail(q: ?*Q) c.gpointer {
    return c.gst_vec_deque_peek_tail(v(q));
}

pub export fn gst_queue_array_peek_tail_struct(q: ?*Q) c.gpointer {
    return c.gst_vec_deque_peek_tail_struct(v(q));
}

pub export fn gst_queue_array_pop_tail(q: ?*Q) c.gpointer {
    return c.gst_vec_deque_pop_tail(v(q));
}

pub export fn gst_queue_array_pop_tail_struct(q: ?*Q) c.gpointer {
    return c.gst_vec_deque_pop_tail_struct(v(q));
}

pub export fn gst_queue_array_is_empty(q: ?*Q) c.gboolean {
    return c.gst_vec_deque_is_empty(v(q));
}

pub export fn gst_queue_array_drop_struct(q: ?*Q, i: c.guint, p: c.gpointer) c.gboolean {
    return c.gst_vec_deque_drop_struct(v(q), i, p);
}

pub export fn gst_queue_array_drop_element(q: ?*Q, i: c.guint) c.gpointer {
    return c.gst_vec_deque_drop_element(v(q), i);
}

pub export fn gst_queue_array_find(q: ?*Q, f: c.GCompareFunc, data: c.gpointer) c.guint {
    return @truncate(c.gst_vec_deque_find(v(q), f, data));
}

pub export fn gst_queue_array_get_length(q: ?*Q) c.guint {
    return @truncate(c.gst_vec_deque_get_length(v(q)));
}
