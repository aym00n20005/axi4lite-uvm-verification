#!/usr/bin/env bash
#=====================================================================
# make_onepager.sh -- docs/one_pager.html -> docs/one_pager.pdf
#
#   make onepager
#
# Headless Chrome, because it is the only PDF renderer on this machine
# and because the HTML was written against a browser's print stylesheet
# in the first place -- wkhtmltopdf uses an old WebKit and reflows it.
#
# The PDF is COMMITTED, unlike every other generated file here, because
# it is the artifact somebody hands to a person. Everything else is
# regenerated on demand; a printable brief is not much use if it only
# exists after you run make.
#
# Regenerate it whenever the numbers change. A one-pager with stale
# figures is worse than no one-pager -- it is the only document in this
# repository that gets read away from the repository, where nobody can
# check it against a run.
#=====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

[[ -x "$CHROME" ]] || { echo "onepager: Google Chrome not found at $CHROME"; exit 2; }

cd "$ROOT"
"$CHROME" --headless --disable-gpu --no-pdf-header-footer \
    --print-to-pdf="$ROOT/docs/one_pager.pdf" \
    "file://$ROOT/docs/one_pager.html" 2>/dev/null

if [[ -f docs/one_pager.pdf ]]; then
    echo "  docs/one_pager.pdf  ($(wc -c < docs/one_pager.pdf) bytes)"
else
    echo "onepager: Chrome produced no output"; exit 1
fi
