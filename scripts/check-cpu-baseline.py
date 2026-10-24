#!/usr/bin/env python3
"""Fail if an x86-64 binary uses instructions beyond its intended CPU baseline.

Usage:
  scripts/check-cpu-baseline.py [--profile x86-64|core2] BINARY...

REAPER loads the extension into its own process, so a single instruction the
user's CPU lacks raises #UD and takes REAPER down at startup (SIGILL on
Linux/macOS, 0xc000001d STATUS_ILLEGAL_INSTRUCTION on Windows). Zig compiles
for the build machine's CPU unless given an explicit target, which on CI means
whatever extensions the runner happens to have. This check makes that
regression impossible to ship.

Profiles:
  x86-64  The original AMD64 baseline (SSE2). Zig's baseline for Linux/Windows.
  core2   x86-64 + SSE3/SSSE3/CMPXCHG16B/LAHF-SAHF. Zig's baseline for macOS,
          and the oldest CPU any Intel Mac shipped with.

The disassembler is LLVM's (`llvm-objdump`, or $LLVM_OBJDUMP), which reads ELF,
PE and Mach-O alike. The architecture is read from the file header rather than
trusted to the disassembler: for a universal Mach-O the x86_64 slice is cut out
here and disassembled on its own, because Apple's llvm-objdump ignores
--arch-name and silently disassembles the host slice instead.

`tzcnt` is deliberately allowed: it is encoded F3 0F BC (`rep bsf`), which
pre-BMI CPUs execute as BSF. LLVM emits it on baseline targets only where the
two agree (input known non-zero, or the zero case preloaded into the output).
`lzcnt` has no such equivalence and is forbidden.
"""

import argparse
import collections
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ISA = {
    "SSE3": {"addsubpd", "addsubps", "haddpd", "haddps", "hsubpd", "hsubps",
             "lddqu", "movddup", "movshdup", "movsldup", "fisttp", "monitor", "mwait"},
    "SSSE3": {"pabsb", "pabsw", "pabsd", "palignr", "phaddw", "phaddd", "phaddsw",
              "phsubw", "phsubd", "phsubsw", "pmaddubsw", "pmulhrsw", "pshufb",
              "psignb", "psignw", "psignd"},
    "SSE4.1": {"blendpd", "blendps", "blendvpd", "blendvps", "dppd", "dpps",
               "extractps", "insertps", "movntdqa", "mpsadbw", "packusdw", "pblendvb",
               "pblendw", "pcmpeqq", "pextrb", "pextrd", "pextrq", "phminposuw",
               "pinsrb", "pinsrd", "pinsrq", "pmaxsb", "pmaxsd", "pmaxud", "pmaxuw",
               "pminsb", "pminsd", "pminud", "pminuw", "pmuldq", "pmulld", "ptest",
               "roundpd", "roundps", "roundsd", "roundss"}
              | {f"pmov{s}x{w}" for s in "sz" for w in ("bw", "bd", "bq", "wd", "wq", "dq")},
    "SSE4.2": {"crc32", "pcmpestri", "pcmpestrm", "pcmpistri", "pcmpistrm", "pcmpgtq"},
    "POPCNT": {"popcnt"},
    "LZCNT": {"lzcnt"},
    "MOVBE": {"movbe"},
    "CX16": {"cmpxchg16b"},
    "LAHF-SAHF": {"lahf", "sahf"},
    "BMI1": {"andn", "bextr", "blsi", "blsmsk", "blsr"},
    "BMI2": {"bzhi", "mulx", "pdep", "pext", "rorx", "sarx", "shlx", "shrx"},
    "ADX": {"adcx", "adox"},
    "AES/CLMUL": {"aesenc", "aesenclast", "aesdec", "aesdeclast", "aesimc",
                  "aeskeygenassist", "pclmulqdq"},
    "SHA": {"sha1rnds4", "sha1nexte", "sha1msg1", "sha1msg2", "sha256rnds2",
            "sha256msg1", "sha256msg2"},
    "RDRAND/RDSEED": {"rdrand", "rdseed"},
}

PROFILE_ALLOWED = {
    "x86-64": set(),
    "core2": {"SSE3", "SSSE3", "CX16", "LAHF-SAHF"},
}

# Every VEX/EVEX-encoded instruction (AVX, AVX2, AVX-512, FMA, F16C) has a
# `v` mnemonic; `verr`/`verw` are the only legacy-encoded exceptions.
# AVX-512 opmask instructions are `k` mnemonics.
VEX_EXCEPTIONS = {"verr", "verw"}
KMASK = re.compile(r"^k(and|andn|or|xor|xnor|not|mov|shiftl|shiftr|test|ortest|add|unpck)[bwdq]{1,2}$")

PREFIXES = {"lock", "rep", "repe", "repz", "repne", "repnz", "rex64", "data16",
            "data32", "addr32", "notrack", "bnd", "xacquire", "xrelease",
            "cs", "ds", "es", "fs", "gs", "ss"}

INSN = re.compile(r"^\s*([0-9a-f]+):\s+(.*)$")


def classify(mnemonic):
    if mnemonic.startswith("v") and mnemonic not in VEX_EXCEPTIONS:
        return "AVX (VEX/EVEX)"
    if KMASK.match(mnemonic):
        return "AVX-512 opmask"
    for name, ops in ISA.items():
        if mnemonic in ops:
            return name
    return None


CPU_TYPE_X86_64 = 0x01000007


def x86_64_image(data):
    """Return (format, image bytes) for the x86-64 code in `data`, or None."""
    head = data[:4096]
    if head[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):  # FAT_MAGIC, FAT_MAGIC_64
        wide = head[3] == 0xBF
        entry, fmt = (32, ">iiQQI") if wide else (20, ">iiIII")
        for i in range(struct.unpack_from(">I", head, 4)[0]):
            cputype, _, offset, size, _ = struct.unpack_from(fmt, data, 8 + i * entry)
            if cputype == CPU_TYPE_X86_64:
                return x86_64_image(data[offset:offset + size])
        return None
    if head[:4] == b"\x7fELF" and len(head) >= 20:
        endian = "<" if head[5] == 1 else ">"
        return ("ELF", data) if struct.unpack_from(endian + "H", head, 18)[0] == 62 else None
    if head[:2] == b"MZ" and len(head) >= 0x40:
        pe = struct.unpack_from("<I", head, 0x3C)[0]
        if head[pe:pe + 4] == b"PE\0\0":
            return ("PE", data) if struct.unpack_from("<H", head, pe + 4)[0] == 0x8664 else None
        return None
    if head[:4] == b"\xcf\xfa\xed\xfe":  # MH_MAGIC_64, little-endian
        return ("Mach-O", data) if struct.unpack_from("<I", head, 4)[0] == CPU_TYPE_X86_64 else None
    return None


def find_objdump():
    tool = os.environ.get("LLVM_OBJDUMP") or shutil.which("llvm-objdump")
    if not tool:
        sys.exit("error: llvm-objdump not found (install LLVM or set $LLVM_OBJDUMP)")
    return tool


def scan(objdump, image, allowed):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "image")
        with open(path, "wb") as f:
            f.write(image)
        cmd = [objdump, "-d", "--no-show-raw-insn", "--x86-asm-syntax=intel", path]
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout

    total = 0
    hits = collections.defaultdict(list)
    for line in out.splitlines():
        m = INSN.match(line)
        if not m:
            continue
        tokens = m.group(2).split()
        while tokens and tokens[0] in PREFIXES:
            tokens.pop(0)
        if not tokens:
            continue
        total += 1
        isa = classify(tokens[0])
        if isa and isa not in allowed:
            hits[isa].append(f"{m.group(1)}: {' '.join(tokens)}")
    return total, hits


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--profile", choices=sorted(PROFILE_ALLOWED), default="x86-64")
    ap.add_argument("binaries", nargs="+")
    args = ap.parse_args()

    objdump = find_objdump()
    failed = False
    for path in args.binaries:
        with open(path, "rb") as f:
            found = x86_64_image(f.read())
        if found is None:
            print(f"FAIL {path}: no x86-64 code (not an x86-64 ELF, PE or Mach-O image)")
            failed = True
            continue
        kind, image = found
        label = f"{path} [{kind} x86-64]"
        total, hits = scan(objdump, image, PROFILE_ALLOWED[args.profile])
        if total == 0:
            # A misconfigured disassembler must not read as a clean binary.
            print(f"FAIL {label}: no instructions disassembled")
            failed = True
        elif hits:
            print(f"FAIL {label}: instructions beyond the {args.profile} baseline")
            for isa, examples in sorted(hits.items()):
                print(f"  {isa:16} {len(examples):6}   e.g. {examples[0]}")
            failed = True
        else:
            print(f"ok   {label}: {total} instructions, all within {args.profile}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
