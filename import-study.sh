#!/usr/bin/env bash
# Imports studies. cBioPortal refuses to render a portal with no studies, so
# this must succeed before the demo tab can be reached.
#
#   ./import-study.sh                  # every study in DATAHUB_STUDY
#   ./import-study.sh <id> [<id> ...]  # only the ones named
#
# Importing several is normal: the portal lists them all on its home page and
# each patient page carries the same tabs, so one portal can hold a small study
# and a fully annotated one at the same time.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
set -a && . ./.env && set +a

if [ "$#" -gt 0 ]; then
    STUDIES="$*"
else
    STUDIES="${DATAHUB_STUDY}"
fi
PORT="${CBIOPORTAL_PORT:-9090}"

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

failed=""
for study in ${STUDIES}; do
    if [ ! -d "study/${study}" ]; then
        echo "study/${study} is not present. Run ./init.sh, or add it to" >&2
        echo "DATAHUB_STUDY in .env and run ./init.sh again." >&2
        failed="${failed} ${study}"
        continue
    fi

    echo
    echo "=== Importing ${study} ==="
    # A failure on one study should not abandon the rest, so the loop records
    # it and carries on rather than letting set -e end the script.
    if docker compose exec -T cbioportal metaImport.py -s "/study/${study}" -o -n; then
        echo "Imported ${study}."
    else
        echo "Import of ${study} FAILED." >&2
        failed="${failed} ${study}"
    fi
done

echo
echo "Restarting the portal to clear its caches..."
docker compose restart cbioportal

if [ -n "${failed}" ]; then
    echo
    echo "These studies did not import:${failed}" >&2
    exit 1
fi

echo
echo "Studies now in the portal:"
curl -sf "http://localhost:${PORT}/api/studies" 2>/dev/null \
    | tr ',' '\n' | grep '"studyId"' | cut -d'"' -f4 | sed 's/^/  /' || true
