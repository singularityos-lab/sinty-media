pub const p = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("stdio.h");
    @cInclude("sys/types.h");
    @cInclude("cdda_interface.h");
    @cInclude("cdda_paranoia.h");
});
