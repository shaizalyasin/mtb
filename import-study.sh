#!/usr/bin/env bash
# Imports the downloaded study. cBioPortal refuses to render a portal with no
# studies, so this must succeed before the demo tab can be reached.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
set -a && . ./.env && set +a

STUDY="${1:-${DATAHUB_STUDY}}"

docker compose exec -T cbioportal \
    metaImport.py -s "/study/${STUDY}" -o -n

echo
echo "Imported ${STUDY}. Restarting the portal to clear its caches..."
docker compose restart cbioportal
