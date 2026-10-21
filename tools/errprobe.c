#include <gst/gst.h>
#include <stdio.h>
static void dump(const char *name, GQuark q, int n) {
  for (int i = 0; i <= n; i++) {
    gchar *m = gst_error_get_message(q, i);
    printf("%s\t%d\t%s\n", name, i, m);
    g_free(m);
  }
}
int main(int argc, char **argv) {
  gst_init(&argc, &argv);
  dump("core", GST_CORE_ERROR, GST_CORE_ERROR_NUM_ERRORS);
  dump("library", GST_LIBRARY_ERROR, GST_LIBRARY_ERROR_NUM_ERRORS);
  dump("resource", GST_RESOURCE_ERROR, GST_RESOURCE_ERROR_NUM_ERRORS);
  dump("stream", GST_STREAM_ERROR, GST_STREAM_ERROR_NUM_ERRORS);
  return 0;
}
