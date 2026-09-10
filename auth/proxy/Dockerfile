# OpenResty with lua-resty-openidc -- the same building block as the
# `cbioproxy` service in the MTB-cBioPortal deployment, built from upstream
# images so this repo stays self-contained.
# The OpenSSL version matters and is not obvious. lua-resty-session 4.x derives
# its key with HKDF through lua-resty-openssl's kdf.new(), which only exists
# when the linked OpenSSL provides the EVP_KDF API -- that is OpenSSL 3.
# OpenResty 1.25 still bundles 1.1.1w, and the failure is a bare
# "attempt to call field 'new' (a nil value)" from inside the session library,
# with nothing to connect it to OpenSSL. 1.27 bundles OpenSSL 3.
FROM openresty/openresty:1.27.1.2-alpine-fat

RUN apk add --no-cache git curl \
    && /usr/local/openresty/luajit/bin/luarocks install lua-resty-openidc \
    && /usr/local/openresty/luajit/bin/luarocks install lua-resty-jwt

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY conf.d/ /etc/nginx/conf.d/

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
