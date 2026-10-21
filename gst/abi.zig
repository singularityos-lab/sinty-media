const std = @import("std");
const c = @import("c.zig").c;

pub fn check(comptime Impl: type) void {
    @setEvalBranchQuota(1_000_000);
    for (@typeInfo(Impl).@"struct".decls) |d| {
        if (!@hasDecl(c, d.name)) continue;
        const theirs = @TypeOf(@field(c, d.name));
        if (@typeInfo(theirs) != .@"fn") continue;
        const ours = @TypeOf(@field(Impl, d.name));
        if (ours != theirs) @compileError("signature of " ++ d.name ++ " differs from the GStreamer header: " ++ @typeName(ours) ++ " vs " ++ @typeName(theirs));
    }
}
