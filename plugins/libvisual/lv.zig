pub const p = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("libvisual/libvisual.h");
});
