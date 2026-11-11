#!/usr/bin/env bash
# Imports gene panel definitions, which a study's gene panel matrix depends on.
#
#   ./import-gene-panels.sh                  # panels needed by DATAHUB_STUDY
#   ./import-gene-panels.sh <study-id> ...   # panels needed by these studies
#
# cBioPortal requires a gene panel to exist in the database BEFORE importing a
# study that references it. The seed database ships none, so importing a study
# with a gene panel matrix fails with:
#
#   java.lang.RuntimeException: Gene panel cannot be found in database: IMPACT468
#
# The definitions live in the cBioPortal datahub, stored with git-lfs. A plain
# raw.githubusercontent.com request returns the 129-byte LFS pointer rather
# than the file, so they are fetched from the media endpoint instead.
#
# Which panels a study needs is read out of its own gene panel matrix rather
# than hardcoded, because the list is not predictable: msk_chord_2024 uses five
# panels, and their file names do not follow their ids (IMPACT-HEME-400 lives
# in data_gene_panel_heme400.txt). So every definition is downloaded once,
# indexed by the stable_id inside it, and only the needed ones are imported.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
set -a && . ./.env && set +a

PORT="${CBIOPORTAL_PORT:-9090}"
PANEL_DIR="study/_gene_panels"
MEDIA="https://media.githubusercontent.com/media/cBioPortal/datahub/master/reference_data/gene_panels"
LISTING="https://api.github.com/repos/cBioPortal/datahub/contents/reference_data/gene_panels"

if [ "$#" -gt 0 ]; then
    STUDIES="$*"
else
    STUDIES="${DATAHUB_STUDY}"
fi

# --- which panels do these studies reference? ------------------------------

needed=""
for study in ${STUDIES}; do
    matrix="study/${study}/data_gene_panel_matrix.txt"
    [ -f "${matrix}" ] || continue
    # Columns after SAMPLE_ID hold a panel id per molecular profile.
    found=$(tail -n +2 "${matrix}" | cut -f2- | tr '\t' '\n' | sort -u \
        | grep -vE '^(NA|na|N/A|)$' || true)
    [ -n "${found}" ] && needed="${needed} ${found}"
done
needed=$(printf '%s\n' ${needed} | sort -u)

if [ -z "${needed}" ]; then
    echo "No gene panel matrix in: ${STUDIES}. Nothing to import."
    exit 0
fi

echo "Panels referenced by the studies:"
printf '  %s\n' ${needed}

# --- which are already in the database? ------------------------------------

present=""
if curl -sf "http://localhost:${PORT}/api/gene-panels" >/dev/null 2>&1; then
    present=$(curl -sf "http://localhost:${PORT}/api/gene-panels" \
        | tr ',' '\n' | grep '"genePanelId"' | cut -d'"' -f4 | sort -u || true)
else
    echo "Warning: the portal is not answering on :${PORT}, so existing panels" >&2
    echo "cannot be listed. Every referenced panel will be attempted." >&2
fi

missing=""
for panel in ${needed}; do
    if printf '%s\n' ${present} | grep -qxF "${panel}"; then
        echo "  ${panel} already in the database, skipping"
    else
        missing="${missing} ${panel}"
    fi
done

if [ -z "${missing}" ]; then
    echo
    echo "All referenced panels are already imported."
    exit 0
fi

# --- fetch the definitions -------------------------------------------------

mkdir -p "${PANEL_DIR}"
if [ -z "$(ls -A "${PANEL_DIR}" 2>/dev/null)" ]; then
    echo
    echo "Downloading gene panel definitions from the cBioPortal datahub..."
    names=$(curl -sf "${LISTING}" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | cut -d'"' -f4)
    if [ -z "${names}" ]; then
        echo "Could not list ${LISTING}" >&2
        exit 1
    fi
    count=0
    for name in ${names}; do
        curl -fsSL -o "${PANEL_DIR}/${name}" "${MEDIA}/${name}" || continue
        # An LFS pointer means the media endpoint did not serve the real file.
        if head -1 "${PANEL_DIR}/${name}" | grep -q 'git-lfs.github.com'; then
            echo "  ${name} came back as an LFS pointer, discarding" >&2
            rm -f "${PANEL_DIR}/${name}"
            continue
        fi
        count=$((count + 1))
    done
    echo "  ${count} definitions in ${PANEL_DIR}/"
else
    echo
    echo "${PANEL_DIR}/ already populated, skipping download"
fi

# --- index by the stable_id inside each file -------------------------------

find_definition() {
    local wanted="$1"
    for file in "${PANEL_DIR}"/*.txt; do
        [ -f "${file}" ] || continue
        local id
        id=$(grep -m1 '^stable_id:' "${file}" | sed 's/^stable_id:[[:space:]]*//' | tr -d '\r')
        if [ "${id}" = "${wanted}" ]; then
            basename "${file}"
            return 0
        fi
    done
    return 1
}

# --- import ----------------------------------------------------------------

failed=""
for panel in ${missing}; do
    file=$(find_definition "${panel}" || true)
    if [ -z "${file}" ]; then
        echo "No definition found for ${panel} in the datahub." >&2
        failed="${failed} ${panel}"
        continue
    fi

    echo
    echo "=== Importing gene panel ${panel} (${file}) ==="
    if docker compose exec -T cbioportal sh -c \
        "java -Dspring.profiles.active=dbcp -cp /core/core-*.jar \
             org.mskcc.cbio.portal.scripts.ImportGenePanel \
             --data /study/_gene_panels/${file}"
    then
        echo "Imported ${panel}."
    else
        echo "Import of ${panel} FAILED." >&2
        failed="${failed} ${panel}"
    fi
done

if [ -n "${failed}" ]; then
    echo
    echo "These panels did not import:${failed}" >&2
    exit 1
fi

echo
echo "Gene panels imported. Studies referencing them can now be loaded."
