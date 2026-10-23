pub const p = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cDefine("__GI_SCANNER__", "1");
    @cDefine("GLIB_VERSION_MIN_REQUIRED", "(G_ENCODE_VERSION (2, 40))");
    @cDefine("GLIB_VERSION_MAX_ALLOWED", "(G_ENCODE_VERSION (2, 42))");
    @cDefine("__GLIB_H_INSIDE__", "1");
    @cInclude("glib/gmacros.h");
    @cUndef("__GLIB_H_INSIDE__");
    @cUndef("G_GNUC_BEGIN_IGNORE_DEPRECATIONS");
    @cUndef("G_GNUC_END_IGNORE_DEPRECATIONS");
    @cDefine("G_GNUC_BEGIN_IGNORE_DEPRECATIONS", "");
    @cDefine("G_GNUC_END_IGNORE_DEPRECATIONS", "");
    @cInclude("pango/pangocairo.h");
    @cInclude("time.h");
});
