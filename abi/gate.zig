const std = @import("std");

fn dynamicSymbols(gpa: std.mem.Allocator, data: []const u8, out: *std.StringHashMap(void)) !void {
    const hdr = std.mem.bytesAsValue(std.elf.Elf64_Ehdr, data[0..@sizeOf(std.elf.Elf64_Ehdr)]);
    const shdrs = std.mem.bytesAsSlice(std.elf.Elf64_Shdr, data[hdr.e_shoff..][0 .. @as(usize, hdr.e_shnum) * @sizeOf(std.elf.Elf64_Shdr)]);
    for (shdrs) |sh| {
        if (sh.sh_type != std.elf.SHT_DYNSYM) continue;
        const strtab = shdrs[sh.sh_link];
        const strs = data[strtab.sh_offset..][0..strtab.sh_size];
        const syms = std.mem.bytesAsSlice(std.elf.Elf64_Sym, data[sh.sh_offset..][0..sh.sh_size]);
        for (syms) |s| {
            if (s.st_shndx == std.elf.SHN_UNDEF or s.st_name == 0) continue;
            const name = std.mem.sliceTo(strs[s.st_name..], 0);
            try out.put(try gpa.dupe(u8, name), {});
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: gate <required.txt> <libdir> [--list]\n", .{});
        std.process.exit(2);
    }
    const list = args.len > 3 and std.mem.eql(u8, args[3], "--list");
    const cwd = std.Io.Dir.cwd();
    const required = try cwd.readFileAlloc(io, args[1], gpa, .unlimited);

    const Lib = struct { want: usize = 0, have: usize = 0, syms: std.StringHashMap(void) };
    var libs: std.StringArrayHashMapUnmanaged(Lib) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;
    var total: usize = 0;
    var done: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, required, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const sym = f.next() orelse continue;
        const lib = f.next() orelse continue;
        const e = try libs.getOrPut(gpa, lib);
        if (!e.found_existing) {
            e.value_ptr.* = .{ .syms = .init(gpa) };
            const path = try std.fs.path.join(gpa, &.{ args[2], lib });
            if (cwd.readFileAlloc(io, path, gpa, .unlimited)) |data| {
                try dynamicSymbols(gpa, data, &e.value_ptr.syms);
            } else |_| {}
        }
        e.value_ptr.want += 1;
        total += 1;
        if (e.value_ptr.syms.contains(sym)) {
            e.value_ptr.have += 1;
            done += 1;
        } else try missing.append(gpa, line);
    }
    var it = libs.iterator();
    while (it.next()) |e| std.debug.print("{s}: {d}/{d}\n", .{ e.key_ptr.*, e.value_ptr.have, e.value_ptr.want });
    std.debug.print("total: {d}/{d}\n", .{ done, total });
    if (list) for (missing.items) |m| std.debug.print("missing {s}\n", .{m});
}
