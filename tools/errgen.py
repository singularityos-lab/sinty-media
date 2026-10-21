import sys

rows = [line.rstrip("\n").split("\t", 2) for line in open(sys.argv[1]) if line.strip()]


def zstr(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


out = ["pub const Entry = struct { domain: []const u8, code: c_int, text: ?[:0]const u8 };", "", "pub const entries = [_]Entry{"]
for domain, code, text in rows:
    generic = text.startswith("No standard error message")
    out.append("    .{ .domain = %s, .code = %s, .text = %s }," % (zstr(domain), code, "null" if generic else zstr(text)))
out.append("};")
open(sys.argv[2], "w").write("\n".join(out) + "\n")
