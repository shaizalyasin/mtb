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

# Smallest first. cBioPortal renders as soon as one study is in, and a large
# study can take hours, so this is the difference between a usable portal in
# ten minutes and one in three hours. Nothing here depends on import order.
order_by_size() {
    local study size
    for study in "$@"; do
        size=0
        [ -d "study/${study}" ] && size=$(du -sm "study/${study}" | cut -f1)
        printf '%s\t%s\n' "${size}" "${study}"
    done | sort -n | cut -f2
}
STUDIES="$(order_by_size ${STUDIES} | tr '\n' ' ')"

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

# A study's gene panel matrix references panels that must already exist in the
# database, and the seed ships none. Without this, importing a study that uses
# panels dies partway through with "Gene panel cannot be found in database".
# Safe to re-run: it imports only what is missing.
echo
echo "=== Gene panels ==="
./import-gene-panels.sh ${STUDIES}

# cBioPortal's segment importer inserts one row per database round trip, and a
# large .seg file is millions of rows: msk_chord_2024 spends about two and a
# half hours in that single step, printing nothing at all while it does. It is
# indistinguishable from a hang unless we say so first.
warn_if_slow() {
    local study="$1" seg mb
    seg=$(ls "study/${study}"/*.seg 2>/dev/null | head -1) || return 0
    [ -n "${seg}" ] || return 0
    mb=$(du -m "${seg}" | cut -f1)
    [ "${mb}" -ge 20 ] || return 0
    echo "    $(basename "${seg}") is ${mb} MB. Segment data loads one row per"
    echo "    round trip, so expect hours, most of it with no output at all."
    echo "    That is normal. Nothing is hung."
}

# Proof of life during the silent stretches.
heartbeat() {
    local started
    started=$(date +%s)
    while sleep 120; do
        echo "    ... still importing, $(( ($(date +%s) - started) / 60 )) min elapsed" >&2
    done
}

failed=""
imported=""
for study in ${STUDIES}; do
    if [ ! -d "study/${study}" ]; then
        echo "study/${study} is not present. Run ./init.sh, or add it to" >&2
        echo "DATAHUB_STUDY in .env and run ./init.sh again." >&2
        failed="${failed} ${study}"
        continue
    fi

    echo
    echo "=== Importing ${study} ==="
    warn_if_slow "${study}"

    # The portal renders as soon as it has one study, so there is no need to
    # wait at the terminal for a long one to finish.
    if [ -n "${imported}" ]; then
        echo "    The portal is already usable at http://localhost:${PORT}"
        echo "    with:${imported}"
    fi

    heartbeat &
    hb=$!

    # A failure on one study should not abandon the rest, so the loop records
    # it and carries on rather than letting set -e end the script.
    if docker compose exec -T cbioportal metaImport.py -s "/study/${study}" -o -n; then
        echo "Imported ${study}."
        imported="${imported} ${study}"
    else
        echo "Import of ${study} FAILED." >&2
        failed="${failed} ${study}"
    fi

    kill "${hb}" 2>/dev/null || true
    wait "${hb}" 2>/dev/null || true
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
