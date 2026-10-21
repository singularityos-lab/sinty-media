#include <gst/gst.h>
#include <stdio.h>
#include <string.h>
static void fill(GValue *v, GType t, int which) {
  g_value_init(v, t);
  if (t == G_TYPE_STRING) g_value_set_string(v, which ? "b" : "a");
  else if (t == G_TYPE_UINT) g_value_set_uint(v, which + 1);
  else if (t == G_TYPE_INT) g_value_set_int(v, which + 1);
  else if (t == G_TYPE_UINT64) g_value_set_uint64(v, which + 1);
  else if (t == G_TYPE_INT64) g_value_set_int64(v, which + 1);
  else if (t == G_TYPE_DOUBLE) g_value_set_double(v, which + 1.5);
  else if (t == G_TYPE_BOOLEAN) g_value_set_boolean(v, which);
  else if (t == G_TYPE_DATE) g_value_take_boxed(v, g_date_new_dmy(1 + which, 2, 2000));
  else if (t == GST_TYPE_DATE_TIME) g_value_take_boxed(v, gst_date_time_new_ymd(2000 + which, 1, 1));
  else if (t == GST_TYPE_SAMPLE) { GstBuffer *b = gst_buffer_new_allocate(NULL, 1 + which, NULL); gst_buffer_memset(b, 0, which, 1 + which); g_value_take_boxed(v, gst_sample_new(b, NULL, NULL, NULL)); gst_buffer_unref(b); }
  else if (t == GST_TYPE_BUFFER) { g_value_take_boxed(v, gst_buffer_new_allocate(NULL, 1 + which, NULL)); }
  else { printf("UNKNOWN %s\n", g_type_name(t)); }
}
int main(int argc, char **argv) {
  gst_init(&argc, &argv);
  for (int i = 1; i < argc; i++) {
    const char *tag = argv[i];
    if (!gst_tag_exists(tag)) { printf("MISSING %s\n", tag); continue; }
    GType t = gst_tag_get_type(tag);
    GstTagList *l = gst_tag_list_new_empty();
    GValue a = G_VALUE_INIT, b = G_VALUE_INIT, out = G_VALUE_INIT;
    fill(&a, t, 0); fill(&b, t, 1);
    gst_tag_list_add_value(l, GST_TAG_MERGE_APPEND, tag, &a);
    gst_tag_list_add_value(l, GST_TAG_MERGE_APPEND, tag, &b);
    gst_tag_list_copy_value(&out, l, tag);
    const char *merge;
    if (gst_tag_is_fixed(tag)) merge = "none";
    else if (G_VALUE_TYPE(&out) == GST_TYPE_LIST) merge = "list";
    else if (t == G_TYPE_STRING && strcmp(g_value_get_string(&out), "a, b") == 0) merge = "comma";
    else if (gst_value_compare(&out, &a) == GST_VALUE_EQUAL) merge = "first";
    else merge = "other";
    printf("%s\t%s\t%s\t%s\t%d\t%s\n", tag, g_type_name(t), gst_tag_get_nick(tag), gst_tag_get_description(tag), gst_tag_get_flag(tag), merge);
    g_value_unset(&a); g_value_unset(&b); g_value_unset(&out); gst_tag_list_unref(l);
  }
  return 0;
}
