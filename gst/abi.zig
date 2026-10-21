const std = @import("std");
const c = @import("c.zig").c;

fn pointee(comptime T: type) ?std.builtin.Type.Pointer {
    return switch (@typeInfo(T)) {
        .pointer => |p| p,
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => |p| p,
            else => null,
        },
        else => null,
    };
}

fn compatible(comptime ours: type, comptime theirs: type) bool {
    if (ours == theirs) return true;
    const a = pointee(ours) orelse return false;
    const b = pointee(theirs) orelse return false;
    if (a.is_const != b.is_const) return false;
    if (@typeInfo(a.child) == .@"struct" and @hasDecl(a.child, "Header") and a.child.Header == b.child) return true;
    return compatible(a.child, b.child);
}

fn sameFn(comptime ours: type, comptime theirs: type) bool {
    if (ours == theirs) return true;
    const a = @typeInfo(ours).@"fn";
    const b = @typeInfo(theirs).@"fn";
    if (a.params.len != b.params.len or a.is_var_args != b.is_var_args) return false;
    if (!compatible(a.return_type.?, b.return_type.?)) return false;
    for (a.params, b.params) |x, y| if (!compatible(x.type.?, y.type.?)) return false;
    return true;
}

pub fn check(comptime Impl: type) void {
    @setEvalBranchQuota(1_000_000);
    for (@typeInfo(Impl).@"struct".decls) |d| {
        if (!@hasDecl(c, d.name)) continue;
        const theirs = @TypeOf(@field(c, d.name));
        if (@typeInfo(theirs) != .@"fn") continue;
        const ours = @TypeOf(@field(Impl, d.name));
        if (!sameFn(ours, theirs)) @compileError("signature of " ++ d.name ++ " differs from the GStreamer header: " ++ @typeName(ours) ++ " vs " ++ @typeName(theirs));
    }
}
