import ctypes
import re
import sys

header, libname, out = sys.argv[1], sys.argv[2], sys.argv[3]
names = re.findall(r'GType\s+(\w+_get_type)\s*\(void\)', open(header).read())

gobject = ctypes.CDLL("libgobject-2.0.so.0")
core = ctypes.CDLL("libgstreamer-1.0.so.0")
lib = ctypes.CDLL(libname)
core.gst_init(None, None)
gobject.g_type_fundamental.restype = ctypes.c_size_t
gobject.g_type_fundamental.argtypes = [ctypes.c_size_t]
gobject.g_type_class_ref.restype = ctypes.c_void_p
gobject.g_type_class_ref.argtypes = [ctypes.c_size_t]
gobject.g_type_name.restype = ctypes.c_char_p
gobject.g_type_name.argtypes = [ctypes.c_size_t]

class EnumValue(ctypes.Structure):
    _fields_ = [("value", ctypes.c_int), ("name", ctypes.c_char_p), ("nick", ctypes.c_char_p)]

class EnumClass(ctypes.Structure):
    _fields_ = [("g_type", ctypes.c_size_t), ("minimum", ctypes.c_int), ("maximum", ctypes.c_int), ("n_values", ctypes.c_uint), ("values", ctypes.POINTER(EnumValue))]

class FlagsValue(ctypes.Structure):
    _fields_ = [("value", ctypes.c_uint), ("name", ctypes.c_char_p), ("nick", ctypes.c_char_p)]

class FlagsClass(ctypes.Structure):
    _fields_ = [("g_type", ctypes.c_size_t), ("mask", ctypes.c_uint), ("n_values", ctypes.c_uint), ("values", ctypes.POINTER(FlagsValue))]

def zstr(b):
    return '"' + b.decode().replace('\\', '\\\\').replace('"', '\\"') + '"'

missing = []
lines = ['const c = @import("c.zig").c;', 'const gtype = @import("gtype.zig");', '']
for fn in names:
    try:
        f = getattr(lib, fn)
    except AttributeError:
        missing.append(fn)
        continue
    f.restype = ctypes.c_size_t
    t = f()
    fund = gobject.g_type_fundamental(t) >> 2
    tname = gobject.g_type_name(t).decode()
    klass = gobject.g_type_class_ref(t)
    if fund == 12:
        k = ctypes.cast(klass, ctypes.POINTER(EnumClass)).contents
        vals = [k.values[i] for i in range(k.n_values)]
        kind, vt, reg = 'enum', 'c.GEnumValue', 'g_enum_register_static'
    elif fund == 13:
        k = ctypes.cast(klass, ctypes.POINTER(FlagsClass)).contents
        vals = [k.values[i] for i in range(k.n_values)]
        kind, vt, reg = 'flags', 'c.GFlagsValue', 'g_flags_register_static'
    else:
        continue
    base = fn[:-len('_get_type')]
    lines.append(f'var {base}_values = [_]{vt}{{')
    for v in vals:
        val = v.value
        lines.append(f'    .{{ .value = {val}, .value_name = {zstr(v.name)}, .value_nick = {zstr(v.nick)} }},')
    lines.append('    .{ .value = 0, .value_name = null, .value_nick = null },')
    lines.append('};')
    lines.append(f'var {base}_once: gtype.Once = .{{}};')
    lines.append(f'fn {base}_register() c.GType {{')
    lines.append(f'    return c.{reg}("{tname}", &{base}_values);')
    lines.append('}')
    lines.append(f'pub export fn {fn}() c.GType {{')
    lines.append(f'    return {base}_once.get({base}_register);')
    lines.append('}')
    lines.append('')
open(out, 'w').write('\n'.join(lines))
print(len(names), 'types, missing:', ' '.join(missing))
