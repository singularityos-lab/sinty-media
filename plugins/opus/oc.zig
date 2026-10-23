pub const o = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("opus.h");
    @cInclude("opus_multistream.h");
});
