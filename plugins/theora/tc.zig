pub const t = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("theora/theoradec.h");
    @cInclude("theora/theoraenc.h");
});
