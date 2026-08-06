#!/usr/bin/env python3
"""
Generate a simulator-only stub implementation of the idevice Rust FFI.

Wander/idevice/libidevice_ffi.a is a DEVICE-ONLY (arm64, iOS) static archive, so
`-sdk iphonesimulator` builds fail at link time even though every Swift file
compiles cleanly. This script emits C stubs for exactly the FFI symbols the app
actually references, so the simulator can link and the UI can be exercised.

Every stub fails honestly: functions that return `IdeviceFfiError *` return a
non-NULL error, and all out-parameters are zeroed so nothing downstream reads
uninitialised memory. Nothing here is ever compiled into a device build.

Usage:  python3 SimStubs/generate_stubs.py   (writes SimStubs/idevice/idevice_ffi_sim_stubs.c)
Then:   bash SimStubs/build_stub_lib.sh      (builds SimStubs/idevice/libidevice_ffi.a)
"""
import re, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEADER = os.path.join(ROOT, "Wander", "idevice", "idevice.h")
SYMS = os.path.join(ROOT, "SimStubs", "needed_symbols.txt")
OUT = os.path.join(ROOT, "SimStubs", "idevice", "idevice_ffi_sim_stubs.c")

SCALARS = r'(bool|size_t|uintptr_t|ptrdiff_t|u?int(16|32|64)_t|int|long|float|double)'

# A `void`-returning FFI function here is always a *_free / setter: its pointer
# arguments are things the caller owns, so writing through them would corrupt
# caller memory. These two are the only void-returning genuine getters.
VOID_GETTERS = {'plist_get_string_val', 'plist_get_uint_val'}

# Single-pointer byte/string/opaque types are always inputs, never out-params.
INPUT_ONLY_POINTEES = {'char', 'uint8_t', 'unsigned char', 'void'}


def split_params(s):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur.strip()); cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def param_name_and_zero(p):
    """Return (name, zero_statement_or_None) for one parameter declaration."""
    p = ' '.join(p.split())
    if p in ('void', ''):
        return None, None
    # function pointer:  ret (*name)(args)
    m = re.search(r'\(\s*\*\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)', p)
    if m:
        return m.group(1), None
    m = re.match(r'^(.*?)([A-Za-z_][A-Za-z0-9_]*)$', p)
    if not m:
        return None, None
    typ, name = m.group(1).strip(), m.group(2)
    if 'const' in typ:
        return name, None
    stars = typ.count('*')
    base = typ.replace('*', '').replace('struct', '').replace('enum', '').strip()
    if stars >= 2:
        return name, f'    if ({name}) *{name} = NULL;'
    if stars == 1 and base not in INPUT_ONLY_POINTEES:
        if base == 'plist_t':
            return name, f'    if ({name}) *{name} = NULL;'
        if re.fullmatch(SCALARS, base):
            return name, f'    if ({name}) *{name} = 0;'
    return name, None


def main():
    needed = [l.strip() for l in open(SYMS) if l.strip() and not l.startswith('#')]
    src = open(HEADER).read()
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    src = re.sub(r'^\s*#.*$', '', src, flags=re.M)

    decls = {}
    for stmt in src.split(';'):
        stmt = ' '.join(stmt.split())
        if '(' not in stmt or stmt.startswith('typedef'):
            continue
        head = stmt[:stmt.index('(')]
        ids = re.findall(r'[A-Za-z_][A-Za-z0-9_]*', head)
        if not ids:
            continue
        name = ids[-1]
        if name in needed and name not in decls and stmt.count('(') == stmt.count(')'):
            decls[name] = stmt

    missing = [n for n in needed if n not in decls]
    if missing:
        sys.exit("Could not find declarations for: " + ", ".join(missing))

    body = []
    for name in needed:
        d = decls[name]
        open_paren = d.index('(')
        close_paren = d.rindex(')')
        ret = d[:open_paren].replace(name, '', 1).strip()
        ret = re.sub(r'\bPLIST_API\b', '', ret).strip()
        params = split_params(d[open_paren + 1:close_paren])

        # Only write through out-params when the function is not a *_free.
        may_write = (ret != 'void') or (name in VOID_GETTERS)
        zeros = []
        for p in params:
            _, z = param_name_and_zero(p)
            if z and may_write:
                zeros.append(z)

        sig = d[:close_paren + 1]
        sig = re.sub(r'\bPLIST_API\b', '', sig).strip()

        lines = [sig + ' {']
        lines += zeros
        if ret.endswith('IdeviceFfiError *'):
            lines.append('    return wander_sim_stub_error();')
        elif ret == 'plist_err_t':
            lines.append('    return PLIST_ERR_UNKNOWN;')
        elif ret == 'enum IdeviceLoggerError':
            # Logger init failing would only add noise; report success.
            lines.append('    return Success;')
        elif ret == 'void':
            for p in params:
                n, _ = param_name_and_zero(p)
                if n and not zeros:
                    lines.append(f'    (void){n};')
        elif ret.endswith('*') or ret == 'plist_t':
            lines.append('    return NULL;')
        else:
            lines.append(f'    {ret} wander_sim_zero = {{0}};')
            lines.append('    return wander_sim_zero;')
        lines.append('}')
        body.append('\n'.join(lines))

    header = '''// GENERATED by SimStubs/generate_stubs.py -- do not edit by hand.
//
// Simulator-only stand-in for the device-only Rust static library
// Wander/idevice/libidevice_ffi.a (arm64 iOS slice only). Linked ONLY when
// building with -sdk iphonesimulator, via LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*].
// Never part of a device build.
//
// Every entry point fails honestly instead of pretending to succeed:
//  * out-parameters are zeroed before returning, so callers never read garbage;
//  * IdeviceFfiError-returning functions return a non-NULL, statically
//    allocated error, which idevice_error_free() below deliberately ignores.

#include "idevice.h"
#include <stddef.h>
#include <string.h>

#if !TARGET_OS_SIMULATOR
#error "idevice_ffi_sim_stubs.c must never be compiled into a device build."
#endif

static const char kWanderSimStubMessage[] =
    "Simulator build: the idevice tunnel library is stubbed out. "
    "Device connection, tunnelling and location spoofing are unavailable here.";

// Statically allocated so idevice_error_free() can safely be a no-op.
static struct IdeviceFfiError kWanderSimStubError = {
    -9001, 0, kWanderSimStubMessage
};

static struct IdeviceFfiError *wander_sim_stub_error(void) {
    return &kWanderSimStubError;
}

'''
    with open(OUT, 'w') as f:
        f.write(header + '\n\n'.join(body) + '\n')
    print(f"wrote {OUT} ({len(needed)} stubs)")


if __name__ == '__main__':
    main()
