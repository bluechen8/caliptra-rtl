#!/usr/bin/env python3
"""Rung 5: extract the shipped SEAL golden vectors for the full encode+encrypt
(fullEnc.h) and decrypt+decode (fullDec.h) flows into flat hex files the
SystemVerilog round-trip TB can $readmemh.

Every `type name[]... = { v0, v1, ... };` C array becomes <name>.txt with one
hex value per line. Pointer arrays (e.g. `uint64_t* pk0[] = {pk_0_mod0,...}`)
are skipped (their targets are emitted directly). Scalars (`type name = v;`)
are collected into scalars.txt as `name = 0xVALUE` lines.

Usage: extract_full.py <fullEnc.h|fullDec.h> [more.h ...] <out_dir>
"""
import re
import sys
import os

# C integer-array definition:  [type] [*] name [attr] = { ... } ;
ARRAY_RE = re.compile(
    r'\b(?:uint64_t|uint32_t|int32_t|int64_t|double)\s*(\*?)\s*'
    r'([A-Za-z_]\w*)\s*\[\s*\]\s*'
    r'(?:__attribute__\s*\(\([^={]*\)\)\s*)?'
    r'=\s*\{([^}]*)\}\s*;',
    re.DOTALL)

# Scalar definition:  type name = value ;
SCALAR_RE = re.compile(
    r'\b(?:uint64_t|uint32_t|int32_t|int64_t)\s+'
    r'([A-Za-z_]\w*)\s*=\s*([^;]+);')

HEXTOK_RE = re.compile(r'0x[0-9a-fA-F]+|-?\d+')


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    text = re.sub(r'//[^\n]*', '', text)
    return text


def is_pointer_list(body):
    # pointer arrays hold identifiers (and NULL), not numeric literals.
    # Strip numeric tokens (0x.. / decimal) and NULL; if any word chars remain,
    # the body names other arrays => it's a pointer list.
    rest = HEXTOK_RE.sub('', body)
    rest = re.sub(r'\bNULL\b', '', rest)
    return bool(re.search(r'[A-Za-z_]', rest))


def to_hex(tok):
    v = int(tok, 0)
    if v < 0:
        v &= (1 << 64) - 1
    return f'{v:016x}'


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    *headers, out_dir = sys.argv[1:]
    os.makedirs(out_dir, exist_ok=True)

    scalars = {}
    arrays = {}
    for h in headers:
        with open(h) as f:
            text = strip_comments(f.read())
        for m in ARRAY_RE.finditer(text):
            name, body = m.group(2), m.group(3)
            if is_pointer_list(body):
                continue
            toks = HEXTOK_RE.findall(body)
            arrays[name] = [to_hex(t) for t in toks]
        # remove array bodies before scanning scalars to avoid matching inside
        text_noarr = ARRAY_RE.sub('', text)
        for m in SCALAR_RE.finditer(text_noarr):
            name, val = m.group(1), m.group(2).strip()
            if HEXTOK_RE.fullmatch(val):
                scalars[name] = int(val, 0)

    for name, vals in arrays.items():
        with open(os.path.join(out_dir, name + '.txt'), 'w') as f:
            f.write('\n'.join(vals) + '\n')
        print(f'  {name}.txt: {len(vals)} words')

    with open(os.path.join(out_dir, 'scalars.txt'), 'w') as f:
        for name, v in scalars.items():
            f.write(f'{name} = 0x{v:x}\n')
    print(f'  scalars.txt: {len(scalars)} scalars -> {list(scalars)}')


if __name__ == '__main__':
    main()
