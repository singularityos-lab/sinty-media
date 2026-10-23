pub const v = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("vorbis/codec.h");
    @cInclude("vorbis/vorbisenc.h");
});
