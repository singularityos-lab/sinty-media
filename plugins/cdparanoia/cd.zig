pub const p = @cImport({
    @cInclude("stdio.h");
    @cInclude("sys/types.h");
    @cInclude("cdda_interface.h");
    @cInclude("cdda_paranoia.h");
});
