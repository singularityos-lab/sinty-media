import subprocess
import sys

rows = [line.rstrip("\n").split("\t") for line in open(sys.argv[1]) if line.strip()]
types = {
    "gchararray": "c.G_TYPE_STRING",
    "guint": "c.G_TYPE_UINT",
    "gdouble": "c.G_TYPE_DOUBLE",
    "guint64": "c.G_TYPE_UINT64",
    "GDate": "c.g_date_get_type()",
    "GstDateTime": "c.gst_date_time_get_type()",
    "GstSample": "c.gst_sample_get_type()",
}
merges = {"none": ".none", "first": ".first", "comma": ".comma"}


def zstr(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


out = ["const c = @import(\"c.zig\").c;", "", "pub const Merge = enum { none, first, comma };", "",
       "pub const Def = struct { name: [:0]const u8, flag: c.GstTagFlag, t: *const fn () c.GType, nick: [:0]const u8, blurb: [:0]const u8, merge: Merge };", ""]
seen = {}
for name, tname, nick, blurb, flag, merge in rows:
    if tname not in seen:
        seen[tname] = "t" + str(len(seen))
        out.append("fn %s() c.GType {\n    return %s;\n}\n" % (seen[tname], types[tname]))
out.append("pub const defs = [_]Def{")
for name, tname, nick, blurb, flag, merge in rows:
    out.append("    .{ .name = %s, .flag = %s, .t = %s, .nick = %s, .blurb = %s, .merge = %s }," % (zstr(name), flag, seen[tname], zstr(nick), zstr(blurb), merges[merge]))
out.append("};")
open(sys.argv[2], "w").write("\n".join(out) + "\n")
