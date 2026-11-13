#include <stdarg.h>

int sinty_va_gst_rtp_base_payload_set_outcaps(void *p, void *field, va_list *ap);

int gst_rtp_base_payload_set_outcaps(void *p, void *field, ...)
{
	va_list ap;
	va_start(ap, field);
	int r = sinty_va_gst_rtp_base_payload_set_outcaps(p, field, &ap);
	va_end(ap);
	return r;
}
