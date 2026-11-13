#!/bin/bash
# Builds a minimal PHP CLI (curl + sockets only) from official source for one
# architecture, linked statically against OpenSSL and curl built here.
# Usage: build-php.sh arm64|x86_64
# Output: vendor/out/php-<arch>
#
# Sources (checksums verified before this script runs):
#   php-8.4.27.tar.xz      php.net
#   openssl-3.5.9.tar.gz   github.com/openssl/openssl releases
#   curl-8.23.0.tar.xz     curl.se
set -euo pipefail

ARCH="${1:?usage: build-php.sh arm64|x86_64}"
V="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$V/src"
WORK="$V/work/$ARCH"
PREFIX="$V/prefix/$ARCH"
OUT="$V/out"
MIN=13.0
JOBS="$(sysctl -n hw.ncpu)"

case "$ARCH" in
  arm64)  SSL_TARGET=darwin64-arm64-cc;  HOST=aarch64-apple-darwin ;;
  x86_64) SSL_TARGET=darwin64-x86_64-cc; HOST=x86_64-apple-darwin ;;
  *) echo "unknown arch $ARCH"; exit 1 ;;
esac

export MACOSX_DEPLOYMENT_TARGET="$MIN"
# Homebrew provides only build tools (pkgconf, automake...). Its libraries must
# never be picked up, so pkg-config is limited to our own prefix.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CC_ARCH="clang -arch $ARCH"
CFLAGS_COMMON="-O2 -mmacosx-version-min=$MIN"

rm -rf "$WORK" "$PREFIX"
mkdir -p "$WORK" "$PREFIX" "$OUT"

echo "=== [$ARCH] OpenSSL"
tar -xzf "$SRC/openssl-dl/openssl-3.5.9.tar.gz" -C "$WORK"
( cd "$WORK/openssl-3.5.9"
  ./Configure "$SSL_TARGET" no-shared no-tests no-docs \
      --prefix="$PREFIX" --openssldir=/etc/ssl -mmacosx-version-min=$MIN
  make -j"$JOBS"
  make install_sw )

echo "=== [$ARCH] curl"
tar -xJf "$SRC/curl-dl/curl-8.23.0.tar.xz" -C "$WORK"
( cd "$WORK/curl-8.23.0"
  CC="$CC_ARCH" CFLAGS="$CFLAGS_COMMON" LDFLAGS="-arch $ARCH" \
  ./configure --host="$HOST" --prefix="$PREFIX" \
      --disable-shared --enable-static \
      --with-openssl="$PREFIX" --with-ca-bundle=/etc/ssl/cert.pem \
      --without-libpsl --without-brotli --without-zstd --without-nghttp2 \
      --without-libidn2 --without-libssh2 --without-librtmp \
      --without-ngtcp2 --without-nghttp3 \
      --disable-ldap --disable-ldaps --disable-manual --disable-docs
  make -j"$JOBS"
  make install )

# libcurl.pc lists zlib as a requirement. macOS ships zlib itself (/usr/lib/libz),
# so describe it for pkg-config rather than building another copy.
cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<'EOF'
Name: zlib
Description: zlib from macOS
Version: 1.2.12
Libs: -lz
Cflags:
EOF

echo "=== [$ARCH] PHP"
tar -xJf "$SRC/php-dl/php-8.4.27.tar.xz" -C "$WORK"
( cd "$WORK/php-8.4.27"
  CURL_CFLAGS="-I$PREFIX/include" \
  CURL_LIBS="$(pkg-config --static --libs libcurl)" \
  CC="$CC_ARCH" CFLAGS="$CFLAGS_COMMON" LDFLAGS="-arch $ARCH -L$PREFIX/lib -framework CoreFoundation -framework CoreServices -framework SystemConfiguration" \
  ./configure --host="$HOST" --prefix="$PREFIX/php" \
      --disable-all --disable-cgi --disable-phpdbg --enable-cli \
      --with-curl --enable-sockets --without-pear --without-iconv
  make -j"$JOBS"
  cp sapi/cli/php "$OUT/php-$ARCH"
  strip -x "$OUT/php-$ARCH" )

echo "=== [$ARCH] done: $OUT/php-$ARCH"
