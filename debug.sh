#!/usr/bin/env bash
# Diagnostic counterpart to verify.sh: loads the patient page, clicks the MTB
# tab, and dumps console output, the custom_tabs config as the frontend sees
# it, the live store, the tab bar, and the rendered DOM. Writes debug-page.png.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
set -a && . ./.env && set +a

exec docker run --rm --network host \
    -v "$PWD":/work -w /work \
    -v mtb_demo_playwright:/pw \
    -e PORTAL_URL="http://localhost:${CBIOPORTAL_PORT:-8090}" \
    -e STUDY_ID="${VERIFY_STUDY_ID:-${DATAHUB_STUDY}}" \
    -e PATIENT_ID="${VERIFY_PATIENT_ID:-P01}" \
    -e PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    mcr.microsoft.com/playwright:v1.49.1-jammy \
    sh -c 'test -d /pw/node_modules/playwright ||
             npm --prefix /pw install playwright@1.49.1 --no-audit --no-fund >/dev/null 2>&1;
           ln -sfn /pw/node_modules /work/node_modules;
           node debug.mjs'
