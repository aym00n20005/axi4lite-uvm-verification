#!/usr/bin/env bash
#=====================================================================
# fetch_uvm.sh -- put the UVM 1.2 class library where slang can see it
#
# This project's UVM runs on EDA Playground with Cadence Xcelium, which
# supplies its own CDNS-UVM-1.2 via -uvmhome. Nothing here is used at
# simulation time. It exists so `make elab` can ELABORATE the testbench
# locally: slang needs the real uvm_pkg source to resolve uvm_component,
# the factory macros, uvm_reg and everything else the environment builds
# on.
#
# Version 1.2, not 2020-2.0, deliberately: matching what actually
# simulates this project is the whole point. Elaborating against a
# different UVM would report errors Xcelium will not, and miss ones it
# will.
#
# Downloaded, not vendored -- third_party/ is gitignored. The tarball is
# Accellera's own, served over TLS from accellera.org.
#=====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/third_party"
UVM_DIR="$DEST/uvm-1.2"
URL="https://www.accellera.org/images/downloads/standards/uvm/uvm-1.2.tar.gz"

if [[ -f "$UVM_DIR/src/uvm_pkg.sv" ]]; then
    echo "uvm: already present at third_party/uvm-1.2"
    exit 0
fi

mkdir -p "$DEST"
echo "uvm: fetching $URL"
curl -sSL --max-time 300 -o "$DEST/uvm-1.2.tar.gz" "$URL"
tar -xzf "$DEST/uvm-1.2.tar.gz" -C "$DEST"
rm -f "$DEST/uvm-1.2.tar.gz"

if [[ ! -f "$UVM_DIR/src/uvm_pkg.sv" ]]; then
    echo "uvm: ERROR -- uvm_pkg.sv not found after extraction" >&2
    exit 1
fi

echo "uvm: $(grep -m1 'UVM_VERSION_STRING' "$UVM_DIR/src/base/uvm_version_defines.svh" 2>/dev/null || echo 'uvm-1.2') in third_party/uvm-1.2"
