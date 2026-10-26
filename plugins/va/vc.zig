pub const v = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("va/va.h");
    @cInclude("va/va_drm.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
