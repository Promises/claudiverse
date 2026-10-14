# procargs.py <pid>: a process's exact argv and environment on macOS, as JSON
# {"argv": [...], "env": ["NAME=value", ...]}, read with sysctl
# KERN_PROCARGS2 (ps joins argv with spaces, so an argument with a space in
# it cannot be told apart there). Only this user's processes. Exit 1 if the
# process cannot be read.
import ctypes
import json
import sys

CTL_KERN, KERN_ARGMAX, KERN_PROCARGS2 = 1, 8, 49

libc = ctypes.CDLL(None)
pid = int(sys.argv[1])
argmax = ctypes.c_int()
size = ctypes.c_size_t(ctypes.sizeof(argmax))
if libc.sysctl((ctypes.c_int * 2)(CTL_KERN, KERN_ARGMAX), 2, ctypes.byref(argmax), ctypes.byref(size), None, 0) != 0:
    sys.exit(1)
buf = ctypes.create_string_buffer(argmax.value)
size = ctypes.c_size_t(argmax.value)
if libc.sysctl((ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid), 3, buf, ctypes.byref(size), None, 0) != 0:
    sys.exit(1)
raw = buf.raw[: size.value]
argc = int.from_bytes(raw[:4], "little")
# After argc: the executable's path, NUL padding, then argv and the environment.
rest = raw[4:]
rest = rest[rest.index(b"\0"):].lstrip(b"\0")
parts = rest.split(b"\0")
print(json.dumps({"argv": [a.decode("utf-8", "replace") for a in parts[:argc]],
                  "env": [e.decode("utf-8", "replace") for e in parts[argc:] if b"=" in e]}))
