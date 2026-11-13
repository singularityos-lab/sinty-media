#include <stdarg.h>

void sinty_va_gst_gl_insert_debug_marker(void *ctx, void *format, va_list *ap);

void gst_gl_insert_debug_marker(void *ctx, void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va_gst_gl_insert_debug_marker(ctx, format, &ap);
	va_end(ap);
}

void sinty_va_gst_gl_async_debug_store_log_msg(void *ad, void *dc, int level, void *file, void *function, int line, void *object, void *format, va_list *ap);

void gst_gl_async_debug_store_log_msg(void *ad, void *dc, int level, void *file, void *function, int line, void *object, void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va_gst_gl_async_debug_store_log_msg(ad, dc, level, file, function, line, object, format, &ap);
	va_end(ap);
}

void *sinty_va_gst_gl_shader_new_link_with_stages(void *ctx, void *err, va_list *ap);

void *gst_gl_shader_new_link_with_stages(void *ctx, void *err, ...)
{
	va_list ap;
	va_start(ap, err);
	void *r = sinty_va_gst_gl_shader_new_link_with_stages(ctx, err, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_gl_shader_new_with_stages(void *ctx, void *err, va_list *ap);

void *gst_gl_shader_new_with_stages(void *ctx, void *err, ...)
{
	va_list ap;
	va_start(ap, err);
	void *r = sinty_va_gst_gl_shader_new_with_stages(ctx, err, &ap);
	va_end(ap);
	return r;
}
