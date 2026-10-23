pub const p = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("stdio.h");
    @cInclude("png.h");
    @cInclude("jpeglib.h");
});
