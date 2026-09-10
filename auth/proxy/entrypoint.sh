#!/bin/sh
# The proxy must listen on the same port the browser uses: OIDC discovery and
# the token endpoint are both resolved from PUBLIC_URL, and the proxy calls
# them itself. Deriving the listen port from PUBLIC_URL stops the two drifting.
set -eu

PORT=$(printf '%s' "${PUBLIC_URL:-http://localhost:9090}" | sed -n 's|.*:\([0-9][0-9]*\)$|\1|p')
: "${PORT:=80}"

sed -i "s/^\( *\)listen [0-9][0-9]*;/\1listen ${PORT};/" /etc/nginx/conf.d/default.conf
echo "cbioproxy listening on ${PORT} (PUBLIC_URL=${PUBLIC_URL:-unset})"

exec /usr/local/openresty/bin/openresty -g 'daemon off;'
