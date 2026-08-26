#!/usr/bin/env bash
# Runs verify.mjs against the running stack in a throwaway Playwright container,
# so this needs no local node or browser install.
#
# --network host is what lets the browser reach both localhost:8090 (portal) and
# localhost:8081 (bundle), exactly as a human's browser would.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
set -a && . ./.env && set +a

# The image ships the browsers but not the npm package. Cache it in a volume so
# only the first run pays for the install.
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
           # ESM ignores NODE_PATH, so the package has to be resolvable from
           # the script directory.
           ln -sfn /pw/node_modules /work/node_modules;
           node verify.mjs'
