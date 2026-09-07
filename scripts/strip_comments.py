#!/usr/bin/env python3
"""strip_comments.py -- shrink a generated bundle to fit a paste box.

    python3 scripts/strip_comments.py in.sv out.sv

EDA Playground caps each pane at 100,000 characters. This project's
sources are 43% comment by volume -- deliberately, because the reasoning
is the point -- and the generated bundle is 233 KB, which does not fit.

The comments stay in the repository. What gets pasted is a transient
artifact for one tool, so it is the artifact that gives way.

WHAT IS KEPT, AND WHY EACH ONE MATTERS

  file-boundary markers    `//====== tb/agent/axi_driver.sv ======`
                           emitted by the bundler. Without them a
                           Xcelium error at line 2,847 is unlocatable:
                           the line numbers no longer match any file in
                           the repo, and these are the only way back.

  `verilator lint_off/on   pragmas, not comments. Stripping them turns a
                           waived warning into a build failure the next
                           time the design pane is linted.

  string literals          a `//` inside "..." is not a comment. Handled
                           by scanning rather than by regex, because
                           $sformatf("a//b") is real and a regex that
                           gets it wrong corrupts the source silently.

The stripper is deliberately a small state machine over characters
rather than a set of regexes. Comment removal that is 99% right produces
source that compiles and means something else.
"""

import pathlib
import re
import sys

# Emitted by the Makefile's playground target. The only comments worth
# their bytes in a pasted bundle.
KEEP = re.compile(r"^\s*//=+\s|^\s*//\s{3}\S|^// GENERATED|^// Paste into|"
                  r"^// Simulator:|^//\s*$|verilator\s+(lint_off|lint_on|coverage)")


def strip(text):
    out = []
    i, n = 0, len(text)
    line_start = 0
    line_had_code = False

    while i < n:
        c = text[i]

        # String literal: copied verbatim, comments inside it are not
        # comments.
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            out.append(text[i:j + 1])
            line_had_code = True
            i = j + 1
            continue

        # Line comment.
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            eol = text.find('\n', i)
            eol = n if eol < 0 else eol
            comment = text[i:eol]
            # The whole line, so KEEP can match on a line-leading marker.
            whole = text[line_start:eol]
            if KEEP.search(whole) or KEEP.search(comment):
                out.append(comment)
                line_had_code = True
            i = eol
            continue

        # Block comment.
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            end = text.find('*/', i)
            end = n if end < 0 else end + 2
            block = text[i:end]
            if 'verilator' in block:
                out.append(block)
                line_had_code = True
            i = end
            continue

        if c == '\n':
            out.append('\n')
            line_start = i + 1
            line_had_code = False
        elif not c.isspace():
            out.append(c)
            line_had_code = True
        else:
            out.append(c)
        i += 1

    text = "".join(out)

    # Trailing whitespace, then runs of blank lines down to one. A file
    # boundary keeps a blank line either side so the bundle is still
    # skimmable.
    text = "\n".join(ln.rstrip() for ln in text.split("\n"))
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: strip_comments.py <in.sv> <out.sv>")
    src = pathlib.Path(sys.argv[1])
    dst = pathlib.Path(sys.argv[2])
    original = src.read_text()
    stripped = strip(original)
    dst.write_text(stripped)
    print(f"{len(original):>8,} -> {len(stripped):>8,} chars "
          f"({100 - len(stripped) * 100 // len(original)}% smaller)  {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
