#!/usr/bin/env python3
"""check_regmap.py -- does regmap.yaml still agree with the specification?

`scripts/regmap.yaml` generates the RTL's parameters, the RAL model and
`docs/register_map.md`, so those three cannot drift from each other. This
checks the one edge that generation cannot protect: the edge between the
YAML and **docs/dut_spec.md section 5**, which is the actual source of
truth.

The spec wins. If this reports a difference, the YAML is what is wrong --
unless the spec was revised, in which case dut_spec.md section 10 should
have a row for it and the YAML follows.

Compared, per register: offset, name, access, reset value, and the set of
implemented bits.
"""

import pathlib
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("check_regmap: PyYAML missing -- run 'make setup'")

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = ROOT / "docs" / "dut_spec.md"
YAML_PATH = ROOT / "scripts" / "regmap.yaml"

# | 0x00 | `CTRL` | RW | 0x0000_0000 | [1:0] |
ROW = re.compile(
    r"^\|\s*(0x[0-9A-Fa-f]+)\s*\|\s*`?(\w+)`?\s*\|\s*(\w+)\s*\|"
    r"\s*`?([0-9A-Fa-fx_]+)`?\s*\|\s*\*{0,2}\[?([0-9]+)(?::([0-9]+))?\]?\*{0,2}\s*\|")


def num(text):
    return int(str(text).replace("_", "").replace("`", ""), 0)


def spec_table():
    """Pull the register table out of section 5 of the specification."""
    text = SPEC.read_text()
    start = text.find("## 5. Register-file slave")
    if start < 0:
        raise SystemExit("check_regmap: section 5 not found in dut_spec.md")
    end = text.find("\n## ", start + 1)
    section = text[start:end if end > 0 else len(text)]

    rows = {}
    for line in section.splitlines():
        m = ROW.match(line.strip())
        if not m:
            continue
        offset, name, access, reset, msb, lsb = m.groups()
        msb = int(msb)
        lsb = int(lsb) if lsb is not None else msb
        rows[name] = dict(
            offset=num(offset), access=access, reset=num(reset),
            mask=((1 << (msb - lsb + 1)) - 1) << lsb,
            bits=f"[{msb}:{lsb}]" if msb != lsb else f"[{msb}]",
        )
    return rows


def yaml_table():
    doc = yaml.safe_load(YAML_PATH.read_text())
    rows = {}
    for r in doc["registers"]:
        mask = reset = 0
        for f in r["fields"]:
            bits = str(f["bits"])
            if ":" in bits:
                msb, lsb = (int(p, 0) for p in bits.split(":", 1))
            else:
                msb = lsb = int(bits, 0)
            width = msb - lsb + 1
            mask |= ((1 << width) - 1) << lsb
            reset |= num(f.get("reset", 0)) << lsb
        rows[r["name"]] = dict(
            offset=num(r["offset"]), access=r["access"], reset=reset, mask=mask)
    return rows


def main():
    spec, ymlr = spec_table(), yaml_table()
    if not spec:
        sys.exit("check_regmap: parsed 0 rows from dut_spec.md section 5 -- "
                 "the table format changed and this parser needs updating")

    problems = []
    for name in sorted(set(spec) | set(ymlr)):
        if name not in spec:
            problems.append(f"{name}: in regmap.yaml, absent from dut_spec.md section 5")
            continue
        if name not in ymlr:
            problems.append(f"{name}: in dut_spec.md section 5, absent from regmap.yaml")
            continue
        s, y = spec[name], ymlr[name]
        for key, fmt in (("offset", "0x{:02X}"), ("reset", "0x{:08X}"), ("mask", "0x{:08X}")):
            if s[key] != y[key]:
                problems.append(
                    f"{name}.{key}: spec {fmt.format(s[key])} != yaml {fmt.format(y[key])}")
        if s["access"] != y["access"]:
            problems.append(f"{name}.access: spec {s['access']} != yaml {y['access']}")

    print(f"  {len(spec)} registers in dut_spec.md section 5, {len(ymlr)} in regmap.yaml")
    if problems:
        print("\ncheck_regmap: regmap.yaml disagrees with the specification.")
        print("The SPEC is the source of truth -- fix the YAML, or revise the")
        print("spec first and add a row to its section 10.\n")
        for p in problems:
            print(f"  {p}")
        return 1
    print("check_regmap: regmap.yaml agrees with dut_spec.md section 5")
    return 0


if __name__ == "__main__":
    sys.exit(main())
