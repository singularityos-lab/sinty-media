#include <stdarg.h>

void sinty_va_gst_bin_add_many(void *b, void *first, va_list *ap);

void gst_bin_add_many(void *b, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	sinty_va_gst_bin_add_many(b, first, &ap);
	va_end(ap);
}

void sinty_va_gst_bin_remove_many(void *b, void *first, va_list *ap);

void gst_bin_remove_many(void *b, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	sinty_va_gst_bin_remove_many(b, first, &ap);
	va_end(ap);
}

void *sinty_va_gst_caps_new_simple(void *media, void *field, va_list *ap);

void *gst_caps_new_simple(void *media, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	void *r = sinty_va_gst_caps_new_simple(media, field, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_caps_new_static_str_simple(void *media, void *field, va_list *ap);

void *gst_caps_new_static_str_simple(void *media, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	void *r = sinty_va_gst_caps_new_static_str_simple(media, field, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_caps_new_id_str_simple(void *media, void *field, va_list *ap);

void *gst_caps_new_id_str_simple(void *media, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	void *r = sinty_va_gst_caps_new_id_str_simple(media, field, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_caps_new_full(void *first, va_list *ap);

void *gst_caps_new_full(void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_caps_new_full(first, &ap);
	va_end(ap);
	return r;
}

void sinty_va_gst_caps_set_simple(void *p, void *field, va_list *ap);

void gst_caps_set_simple(void *p, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	sinty_va_gst_caps_set_simple(p, field, &ap);
	va_end(ap);
}

void sinty_va_gst_caps_set_simple_static_str(void *p, void *field, va_list *ap);

void gst_caps_set_simple_static_str(void *p, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	sinty_va_gst_caps_set_simple_static_str(p, field, &ap);
	va_end(ap);
}

void sinty_va_gst_caps_id_str_set_simple(void *p, void *field, va_list *ap);

void gst_caps_id_str_set_simple(void *p, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	sinty_va_gst_caps_id_str_set_simple(p, field, &ap);
	va_end(ap);
}

void *sinty_va_gst_caps_features_new(void *first, va_list *ap);

void *gst_caps_features_new(void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_caps_features_new(first, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_caps_features_new_static_str(void *first, va_list *ap);

void *gst_caps_features_new_static_str(void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_caps_features_new_static_str(first, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_caps_features_new_id(unsigned int first, va_list *ap);

void *gst_caps_features_new_id(unsigned int first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_caps_features_new_id(first, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_caps_features_new_id_str(void *first, va_list *ap);

void *gst_caps_features_new_id_str(void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_caps_features_new_id_str(first, &ap);
	va_end(ap);
	return r;
}

void sinty_va_gst_child_proxy_get(void *p, void *first, va_list *ap);

void gst_child_proxy_get(void *p, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	sinty_va_gst_child_proxy_get(p, first, &ap);
	va_end(ap);
}

void sinty_va_gst_child_proxy_set(void *p, void *first, va_list *ap);

void gst_child_proxy_set(void *p, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	sinty_va_gst_child_proxy_set(p, first, &ap);
	va_end(ap);
}

void *sinty_va__gst_element_error_printf(void *fmt, va_list *ap);

void *_gst_element_error_printf(void *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	void *r = sinty_va__gst_element_error_printf(fmt, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_make_element_message_details(void *first, va_list *ap);

void *gst_make_element_message_details(void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_make_element_message_details(first, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_element_factory_create_full(void *f, void *first, va_list *ap);

void *gst_element_factory_create_full(void *f, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_element_factory_create_full(f, first, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_element_factory_make_full(void *name, void *first, va_list *ap);

void *gst_element_factory_make_full(void *name, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_element_factory_make_full(name, first, &ap);
	va_end(ap);
	return r;
}

int sinty_va_gst_element_link_many(void *a_in, void *b_in, va_list *ap);

int gst_element_link_many(void *a_in, void *b_in, ...)
{
	va_list ap;
	va_start(ap, b_in);
	int r = sinty_va_gst_element_link_many(a_in, b_in, &ap);
	va_end(ap);
	return r;
}

void sinty_va_gst_element_unlink_many(void *a_in, void *b_in, va_list *ap);

void gst_element_unlink_many(void *a_in, void *b_in, ...)
{
	va_list ap;
	va_start(ap, b_in);
	sinty_va_gst_element_unlink_many(a_in, b_in, &ap);
	va_end(ap);
}

void *sinty_va_gst_element_decorate_stream_id_printf(void *e, void *fmt, va_list *ap);

void *gst_element_decorate_stream_id_printf(void *e, void *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	void *r = sinty_va_gst_element_decorate_stream_id_printf(e, fmt, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_pad_create_stream_id_printf(void *p, void *parent, void *fmt, va_list *ap);

void *gst_pad_create_stream_id_printf(void *p, void *parent, void *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	void *r = sinty_va_gst_pad_create_stream_id_printf(p, parent, fmt, &ap);
	va_end(ap);
	return r;
}

void sinty_va_gst_debug_log(void *cat, int level, void *file, void *func, int line, void *object, void *format, va_list *ap);

void gst_debug_log(void *cat, int level, void *file, void *func, int line, void *object, void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va_gst_debug_log(cat, level, file, func, line, object, format, &ap);
	va_end(ap);
}

void sinty_va_gst_debug_log_id(void *cat, int level, void *file, void *func, int line, void *id, void *format, va_list *ap);

void gst_debug_log_id(void *cat, int level, void *file, void *func, int line, void *id, void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va_gst_debug_log_id(cat, level, file, func, line, id, format, &ap);
	va_end(ap);
}

void *sinty_va_gst_info_strdup_printf(void *format, va_list *ap);

void *gst_info_strdup_printf(void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	void *r = sinty_va_gst_info_strdup_printf(format, &ap);
	va_end(ap);
	return r;
}

void sinty_va_gst_print(void *format, va_list *ap);

void gst_print(void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va_gst_print(format, &ap);
	va_end(ap);
}

void sinty_va_gst_println(void *format, va_list *ap);

void gst_println(void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va_gst_println(format, &ap);
	va_end(ap);
}

void sinty_va_gst_printerr(void *format, va_list *ap);

void gst_printerr(void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va_gst_printerr(format, &ap);
	va_end(ap);
}

void sinty_va_gst_printerrln(void *format, va_list *ap);

void gst_printerrln(void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va_gst_printerrln(format, &ap);
	va_end(ap);
}

void sinty_va_gst_debug_log_with_context(void *ctx, int level, void *file, void *func, int line, void *object, void *format, va_list *ap);

void gst_debug_log_with_context(void *ctx, int level, void *file, void *func, int line, void *object, void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va_gst_debug_log_with_context(ctx, level, file, func, line, object, format, &ap);
	va_end(ap);
}

void sinty_va_gst_debug_log_id_with_context(void *ctx, int level, void *file, void *func, int line, void *id, void *format, va_list *ap);

void gst_debug_log_id_with_context(void *ctx, int level, void *file, void *func, int line, void *id, void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va_gst_debug_log_id_with_context(ctx, level, file, func, line, id, format, &ap);
	va_end(ap);
}

void sinty_va__gst_debug_log_once(void *cat, int level, void *file, void *func, int line, void *object, void *format, va_list *ap);

void _gst_debug_log_once(void *cat, int level, void *file, void *func, int line, void *object, void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va__gst_debug_log_once(cat, level, file, func, line, object, format, &ap);
	va_end(ap);
}

void sinty_va__gst_debug_log_once_id(void *cat, int level, void *file, void *func, int line, void *id, void *format, va_list *ap);

void _gst_debug_log_once_id(void *cat, int level, void *file, void *func, int line, void *id, void *format, ...)
{
	va_list ap;
	va_start(ap, format);
	sinty_va__gst_debug_log_once_id(cat, level, file, func, line, id, format, &ap);
	va_end(ap);
}

void sinty_va_gst_query_set_formats(void *q, int n, va_list *ap);

void gst_query_set_formats(void *q, int n, ...)
{
	va_list ap;
	va_start(ap, n);
	sinty_va_gst_query_set_formats(q, n, &ap);
	va_end(ap);
}

void sinty_va_gst_tag_setter_add_tags(void *s, int mode, void *tag, va_list *ap);

void gst_tag_setter_add_tags(void *s, int mode, void *tag, ...)
{
	va_list ap;
	va_start(ap, tag);
	sinty_va_gst_tag_setter_add_tags(s, mode, tag, &ap);
	va_end(ap);
}

void sinty_va_gst_tag_setter_add_tag_values(void *s, int mode, void *tag, va_list *ap);

void gst_tag_setter_add_tag_values(void *s, int mode, void *tag, ...)
{
	va_list ap;
	va_start(ap, tag);
	sinty_va_gst_tag_setter_add_tag_values(s, mode, tag, &ap);
	va_end(ap);
}

void *sinty_va_gst_structure_new(void *name, void *first, va_list *ap);

void *gst_structure_new(void *name, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_structure_new(name, first, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_structure_new_static_str(void *name, void *first, va_list *ap);

void *gst_structure_new_static_str(void *name, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_structure_new_static_str(name, first, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_structure_new_id(unsigned int name, unsigned int first, va_list *ap);

void *gst_structure_new_id(unsigned int name, unsigned int first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_structure_new_id(name, first, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_structure_new_id_str(void *name, void *first, va_list *ap);

void *gst_structure_new_id_str(void *name, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_structure_new_id_str(name, first, &ap);
	va_end(ap);
	return r;
}

void sinty_va_gst_structure_set(void *s, void *field, va_list *ap);

void gst_structure_set(void *s, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	sinty_va_gst_structure_set(s, field, &ap);
	va_end(ap);
}

void sinty_va_gst_structure_set_static_str(void *s, void *field, va_list *ap);

void gst_structure_set_static_str(void *s, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	sinty_va_gst_structure_set_static_str(s, field, &ap);
	va_end(ap);
}

void sinty_va_gst_structure_id_set(void *s, unsigned int field, va_list *ap);

void gst_structure_id_set(void *s, unsigned int field, ...)
{
	va_list ap;
	va_start(ap, field);
	sinty_va_gst_structure_id_set(s, field, &ap);
	va_end(ap);
}

void sinty_va_gst_structure_id_str_set(void *s, void *field, va_list *ap);

void gst_structure_id_str_set(void *s, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	sinty_va_gst_structure_id_str_set(s, field, &ap);
	va_end(ap);
}

void sinty_va_gst_structure_remove_fields(void *s, void *first, va_list *ap);

void gst_structure_remove_fields(void *s, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	sinty_va_gst_structure_remove_fields(s, first, &ap);
	va_end(ap);
}

void sinty_va_gst_structure_id_str_remove_fields(void *s, void *first, va_list *ap);

void gst_structure_id_str_remove_fields(void *s, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	sinty_va_gst_structure_id_str_remove_fields(s, first, &ap);
	va_end(ap);
}

int sinty_va_gst_structure_get(void *s, void *first, va_list *ap);

int gst_structure_get(void *s, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	int r = sinty_va_gst_structure_get(s, first, &ap);
	va_end(ap);
	return r;
}

int sinty_va_gst_structure_id_str_get(void *s, void *first, va_list *ap);

int gst_structure_id_str_get(void *s, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	int r = sinty_va_gst_structure_id_str_get(s, first, &ap);
	va_end(ap);
	return r;
}

int sinty_va_gst_structure_id_get(void *s, unsigned int first, va_list *ap);

int gst_structure_id_get(void *s, unsigned int first, ...)
{
	va_list ap;
	va_start(ap, first);
	int r = sinty_va_gst_structure_id_get(s, first, &ap);
	va_end(ap);
	return r;
}

void *sinty_va_gst_tag_list_new(void *tag, va_list *ap);

void *gst_tag_list_new(void *tag, ...)
{
	va_list ap;
	va_start(ap, tag);
	void *r = sinty_va_gst_tag_list_new(tag, &ap);
	va_end(ap);
	return r;
}

void sinty_va_gst_tag_list_add(void *l, int mode, void *tag, va_list *ap);

void gst_tag_list_add(void *l, int mode, void *tag, ...)
{
	va_list ap;
	va_start(ap, tag);
	sinty_va_gst_tag_list_add(l, mode, tag, &ap);
	va_end(ap);
}

void sinty_va_gst_tag_list_add_values(void *l, int mode, void *tag, va_list *ap);

void gst_tag_list_add_values(void *l, int mode, void *tag, ...)
{
	va_list ap;
	va_start(ap, tag);
	sinty_va_gst_tag_list_add_values(l, mode, tag, &ap);
	va_end(ap);
}

void *sinty_va_gst_tracer_record_new(void *name, void *first, va_list *ap);

void *gst_tracer_record_new(void *name, void *first, ...)
{
	va_list ap;
	va_start(ap, first);
	void *r = sinty_va_gst_tracer_record_new(name, first, &ap);
	va_end(ap);
	return r;
}

void sinty_va_gst_tracer_record_log(void *r, va_list *ap);

void gst_tracer_record_log(void *r, ...)
{
	va_list ap;
	va_start(ap, r);
	sinty_va_gst_tracer_record_log(r, &ap);
	va_end(ap);
}

void sinty_va_gst_type_find_suggest_simple(void *find, unsigned int probability, void *media, void *field, va_list *ap);

void gst_type_find_suggest_simple(void *find, unsigned int probability, void *media, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	sinty_va_gst_type_find_suggest_simple(find, probability, media, field, &ap);
	va_end(ap);
}
