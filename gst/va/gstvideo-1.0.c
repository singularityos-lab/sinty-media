#include <stdarg.h>

void sinty_va_gst_navigation_query_set_commands(void *query, int n_cmds, va_list *ap);

void gst_navigation_query_set_commands(void *query, int n_cmds, ...)
{
	va_list ap;
	va_start(ap, n_cmds);
	sinty_va_gst_navigation_query_set_commands(query, n_cmds, &ap);
	va_end(ap);
}
