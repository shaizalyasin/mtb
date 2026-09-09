#!/usr/bin/env bash
# Imports a study. cBioPortal refuses to render a portal with no studies, so
# this must succeed before the demo tab can be reached.
#
#   ./import-study.sh [study-id]     # defaults to DATAHUB_STUDY from .env
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
set -a && . ./.env && set +a

STUDY="${1:-${DATAHUB_STUDY}}"
PORT="${CBIOPORTAL_PORT:-8090}"

# `docker compose up -d` returns within seconds, but the database spends several
# minutes loading the seed and the portal does not answer until that finishes.
# Without this wait, running the documented steps back to back fails.
echo "Waiting for cBioPortal on :${PORT} (first boot takes a few minutes)..."
for _ in $(seq 1 180); do
    if curl -sf "http://localhost:${PORT}/api/studies" >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

if ! curl -sf "http://localhost:${PORT}/api/studies" >/dev/null 2>&1; then
    echo "cBioPortal did not come up within 15 minutes." >&2
    echo "Check: docker compose logs cbioportal" >&2
    exit 1
fi

docker compose exec -T cbioportal \
    metaImport.py -s "/study/${STUDY}" -o -n

echo
echo "Imported ${STUDY}. Restarting the portal to clear its caches..."
docker compose restart cbioportal
