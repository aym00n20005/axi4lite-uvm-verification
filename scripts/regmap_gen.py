#!/usr/bin/env python3
"""regmap_gen.py -- one YAML register map, three generated consumers.

    scripts/regmap.yaml
        |
        +--> rtl/gen/axi4lite_reg_pkg.sv    indices, widths, resets, masks
        +--> tb/ral/axi_reg_block.sv        the UVM RAL model
        +--> docs/register_map.md           the documentation table

docs/automation_plan.md T4. The point is not the code saved -- it is that
these three cannot drift apart, because there is nothing to keep in sync.

WHAT IS DELIBERATELY NOT GENERATED

The register slave's BEHAVIOUR. W1C set-beats-clear, CTRL[1]'s
self-clearing pulse, STATUS.error's transparency rule and COUNTER's
reset-over-increment priority are each a paragraph of dut_spec.md
section 5, and the hand-written always_ff blocks that cite those
paragraphs are a better expression of them than any template. T4's own
scope note says the same thing: a generator that handles four access
types and refuses the fifth is finishable; one that handles everything
is not.

AND WHAT IS DELIBERATELY NOT GENERATED FROM THIS FILE EITHER

tb/env/axi_scoreboard.sv. The reference model re-derives the decode and
the register semantics from the specification independently, and it must
stay that way: a model generated from the same source as the DUT's
parameters agrees with the DUT by construction, which is the failure
BUG-007 was. The RAL is generated because a RAL's whole job is to be the
machine-readable map; the scoreboard is not, because its job is to
disagree.

Emitting a package rather than an include file is not a style choice.
EDA Playground has no file list -- multi-file source arrives as one
concatenated paste (see the Makefile's playground target) -- so an
`include of a separate .svh would land at the wrong scope. A package
survives both a real file list and a concatenation.
"""

import argparse
import pathlib
import sys

try:
    import yaml
except ImportError:
    sys.exit("regmap_gen: PyYAML missing -- run 'make setup'")
try:
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
except ImportError:
    sys.exit("regmap_gen: Jinja2 missing -- run 'make setup'")

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Four access types, and anything else is an error rather than a guess.
# Adding a fifth means deciding what the RTL, the RAL and the docs each
# do with it -- three decisions, not one -- so the refusal is the honest
# behaviour. automation_plan.md T4.
SUPPORTED_ACCESS = {
    "RW":  "read-write",
    "RO":  "read-only, writes accepted and discarded",
    "W1C": "write-1-to-clear",
    "WC":  "write clears; the bit always reads 0",
}


class RegmapError(Exception):
    pass


def parse_bits(spec):
    """'7:0' or 3 -> (msb, lsb)."""
    if isinstance(spec, int):
        return spec, spec
    text = str(spec).strip()
    if ":" in text:
        msb, lsb = (int(p, 0) for p in text.split(":", 1))
    else:
        msb = lsb = int(text, 0)
    if msb < lsb:
        raise RegmapError(f"bits '{spec}': msb {msb} below lsb {lsb}")
    return msb, lsb


def load(path):
    doc = yaml.safe_load(pathlib.Path(path).read_text())
    block = doc["block"]
    dw = block["data_width"]

    regs = []
    seen_offsets = {}
    for r in doc["registers"]:
        name = r["name"]
        offset = int(str(r["offset"]), 0)
        if offset in seen_offsets:
            raise RegmapError(f"{name}: offset 0x{offset:X} already used by {seen_offsets[offset]}")
        seen_offsets[offset] = name
        if offset % (dw // 8):
            raise RegmapError(f"{name}: offset 0x{offset:X} is not word-aligned")

        if r["access"] not in SUPPORTED_ACCESS:
            raise RegmapError(
                f"{name}: unsupported access type '{r['access']}' "
                f"(supported: {', '.join(sorted(SUPPORTED_ACCESS))})")

        fields, mask, reset = [], 0, 0
        for f in r["fields"]:
            if f["access"] not in SUPPORTED_ACCESS:
                raise RegmapError(
                    f"{name}.{f['name']}: unsupported access type '{f['access']}' "
                    f"(supported: {', '.join(sorted(SUPPORTED_ACCESS))})")
            msb, lsb = parse_bits(f["bits"])
            if msb >= dw:
                raise RegmapError(f"{name}.{f['name']}: bit {msb} outside a {dw}-bit register")
            width = msb - lsb + 1
            fmask = ((1 << width) - 1) << lsb
            if fmask & mask:
                raise RegmapError(f"{name}.{f['name']}: bits [{msb}:{lsb}] overlap another field")
            freset = int(str(f.get("reset", 0)), 0)
            if freset >= (1 << width):
                raise RegmapError(
                    f"{name}.{f['name']}: reset 0x{freset:X} does not fit in {width} bit(s)")
            mask |= fmask
            reset |= freset << lsb
            fields.append(dict(
                name=f["name"], msb=msb, lsb=lsb, width=width,
                access=f["access"], reset=freset,
                volatile=bool(f.get("volatile", False)),
                check=bool(f.get("check", True)),
                desc=" ".join(str(f.get("desc", "")).split()),
            ))

        span = max((f["msb"] for f in fields), default=-1) + 1
        regs.append(dict(
            name=name, offset=offset, access=r["access"],
            index=offset >> block["index_lsb"],
            fields=fields, mask=mask, reset=reset, span=span,
            reserved=((1 << dw) - 1) & ~mask,
            desc=" ".join(str(r.get("desc", "")).split()),
        ))

    idx_bits = block["index_msb"] - block["index_lsb"] + 1
    if len(regs) > (1 << idx_bits):
        raise RegmapError(
            f"{len(regs)} registers do not fit in a {idx_bits}-bit index "
            f"(ADDR[{block['index_msb']}:{block['index_lsb']}])")

    block["index_width"] = idx_bits
    block["reg_count"] = len(regs)
    return block, regs


def svcomment(text, indent=8, width=72):
    """Wrap a field description into an aligned SystemVerilog comment block.

    Descriptions in the YAML are prose and some run to four lines. Emitted
    verbatim they produce 300-column comments that no one reads, which
    defeats the purpose of carrying the rationale into the generated file
    at all.
    """
    import textwrap
    pad = " " * indent
    body = " ".join(str(text).split())
    if not body:
        return ""
    lines = textwrap.wrap(body, width=width - indent - 3)
    return ("\n").join(f"{pad}// {ln}" for ln in lines).lstrip()


def render(env, template, out_path, **ctx):
    text = env.get_template(template).render(**ctx)
    if not text.endswith("\n"):
        text += "\n"
    out = ROOT / out_path
    out.parent.mkdir(parents=True, exist_ok=True)
    changed = (not out.exists()) or out.read_text() != text
    if changed:
        out.write_text(text)
    return out_path, changed


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--regmap", default=str(ROOT / "scripts" / "regmap.yaml"))
    ap.add_argument("--check", action="store_true",
                    help="fail if any output would change (for CI)")
    args = ap.parse_args()

    try:
        block, regs = load(args.regmap)
    except (RegmapError, KeyError) as e:
        sys.exit(f"regmap_gen: {e}")

    env = Environment(
        loader=FileSystemLoader(str(ROOT / "scripts" / "templates")),
        undefined=StrictUndefined,
        trim_blocks=True, lstrip_blocks=True, keep_trailing_newline=True,
    )
    env.globals["access_desc"] = SUPPORTED_ACCESS
    env.filters["svcomment"] = svcomment

    outputs = [
        ("reg_pkg.sv.j2",       "rtl/gen/axi4lite_reg_pkg.sv"),
        ("ral_block.sv.j2",     "tb/ral/axi_reg_block.sv"),
        ("register_map.md.j2",  "docs/register_map.md"),
    ]

    stale = []
    for tmpl, dest in outputs:
        path, changed = render(env, tmpl, dest, block=block, regs=regs,
                               source=pathlib.Path(args.regmap).name)
        print(f"  {'write ' if changed else 'ok    '} {path}")
        if changed:
            stale.append(path)

    if args.check and stale:
        print("\nregmap_gen: outputs are stale -- run 'make regmap' and commit:")
        for p in stale:
            print(f"  {p}")
        return 1
    print(f"regmap_gen: {len(regs)} registers from {pathlib.Path(args.regmap).name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
