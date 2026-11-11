#!/usr/bin/env bash
# Downloads everything the stack needs but should not be committed:
#   data/cgds.sql   -- schema, read out of the pinned cBioPortal image
#   data/seed.sql.gz -- gene/reference seed database
#   study/<study>   -- one datahub study to have a patient to look at
#
# Safe to re-run; existing files are left alone.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
set -a && . ./.env && set +a

mkdir -p data study config

# The image's entrypoint waits for the database and runs migrate_db before
# handing off to the JVM, and it reads the datasource from
# $PORTAL_HOME/application.properties -- NOT from Spring command-line
# arguments. So the connection details have to be in a properties file even
# though Spring itself would have accepted them on the command line.
#
# We take the image's own application.properties and rewrite three lines, so
# everything else stays exactly as that version shipped it.
if [ -s config/application.properties ]; then
    echo "config/application.properties exists, skipping"
else
    echo "Generating application.properties from ${DOCKER_IMAGE_CBIOPORTAL}..."
    # '&' is a backreference in sed's replacement text, and the JDBC URL
    # contains query parameters joined by '&'.
    ESCAPED_URL=$(printf '%s' "${DB_MYSQL_URL}" | sed 's/[&|]/\\&/g')
    docker run --rm -i "${DOCKER_IMAGE_CBIOPORTAL}" \
        cat /cbioportal-webapp/application.properties \
        | sed "s|^spring.datasource.url=.*|spring.datasource.url=${ESCAPED_URL}|" \
        | sed "s|^spring.datasource.username=.*|spring.datasource.username=${DB_MYSQL_USERNAME}|" \
        | sed "s|^spring.datasource.password=.*|spring.datasource.password=${DB_MYSQL_PASSWORD}|" \
        > config/application.properties
fi

# The schema comes out of the portal image rather than from a URL, so it is
# always exactly the schema that image expects. This is the official approach.
if [ -s data/cgds.sql ]; then
    echo "data/cgds.sql exists, skipping"
else
    echo "Extracting schema from ${DOCKER_IMAGE_CBIOPORTAL}..."
    docker run --rm -i "${DOCKER_IMAGE_CBIOPORTAL}" \
        cat /cbioportal/db-scripts/cgds.sql > data/cgds.sql
fi

if [ -s data/seed.sql.gz ]; then
    echo "data/seed.sql.gz exists, skipping"
else
    # The seed is versioned in lockstep with the schema, and cgds.sql states
    # which version it is. Deriving the seed name from the schema rather than
    # hardcoding it means bumping DOCKER_IMAGE_CBIOPORTAL picks up the matching
    # seed on its own. cBioPortal 6.4.4 -> DB_SCHEMA_VERSION 2.14.5.
    SCHEMA_VERSION=$(sed -n "s/.*VALUES *('\([0-9.]*\)'.*/\1/p" data/cgds.sql | head -n 1)
    if [ -z "${SCHEMA_VERSION}" ]; then
        echo "Could not read DB_SCHEMA_VERSION from data/cgds.sql" >&2
        exit 1
    fi
    SEED_FILE="seed-cbioportal_hg19_hg38_v${SCHEMA_VERSION}.sql.gz"
    echo "Schema version ${SCHEMA_VERSION}; downloading ${SEED_FILE}..."
    curl -fL --progress-bar -o data/seed.sql.gz \
        "https://github.com/cBioPortal/datahub/raw/master/seedDB/${SEED_FILE}"
fi

if [ -d "study/${DATAHUB_STUDY}" ]; then
    echo "study/${DATAHUB_STUDY} exists, skipping"
else
    echo "Downloading study ${DATAHUB_STUDY}..."
    curl -fL --progress-bar -o "study/${DATAHUB_STUDY}.tar.gz" \
        "https://datahub.assets.cbioportal.org/${DATAHUB_STUDY}.tar.gz"
    tar xzf "study/${DATAHUB_STUDY}.tar.gz" -C study
    rm -f "study/${DATAHUB_STUDY}.tar.gz"
fi

# The bundle is fetched by the *browser*, so frontend.json needs a URL that
# resolves outside the compose network. Rendering it here, rather than
# committing a fixed one, means changing MTB_TOOLS_PORT cannot leave the tab
# pointing at a dead port.
sed -e "s|__MTB_TOOLS_BASE_URL__|${MTB_TOOLS_BASE_URL}|g" \
    -e "s|__MTB_RISK_BASE_URL__|${MTB_RISK_BASE_URL:-http://localhost:9092}|g" \
    config/frontend.json.template > config/frontend.json
echo "Wrote config/frontend.json (bundle at ${MTB_TOOLS_BASE_URL})"
echo "  Prognosis tab points at ${MTB_RISK_BASE_URL:-http://localhost:9092}"

echo
echo "Done. Next:"
echo "  docker compose up -d --build     # first boot seeds the DB, takes a few minutes"
echo "  ./import-study.sh                # once the portal is healthy"
