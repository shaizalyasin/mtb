#!/usr/bin/env bash
# Verifies the authentication overlay. Run from anywhere; paths resolve to the
# repository root so the browser container sees the same layout as ../verify.sh.
#
#   docker compose -f docker-compose.yml -f auth/docker-compose.yml up -d --build
#   ./auth/verify-auth.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a && . ./.env && set +a

# --network host lets the browser reach the portal on localhost exactly as a
# person's browser would, which matters because the OIDC redirects are built
# from that same origin.
exec docker run --rm --network host \
    -v "$PWD":/work -w /work \
    -v mtb_playwright:/pw \
    -e PORTAL_URL="http://localhost:${CBIOPORTAL_PORT:-9090}" \
    -e STUDY_ID="${VERIFY_STUDY_ID:-${DATAHUB_STUDY}}" \
    -e PATIENT_ID="${VERIFY_PATIENT_ID:-P01}" \
    -e PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    mcr.microsoft.com/playwright:v1.49.1-jammy \
    sh -c 'test -d /pw/node_modules/playwright ||
             npm --prefix /pw install playwright@1.49.1 --no-audit --no-fund >/dev/null 2>&1;
           ln -sfn /pw/node_modules /work/node_modules;
           node auth/verify-auth.mjs'
