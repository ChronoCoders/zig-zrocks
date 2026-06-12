#!/usr/bin/env bash
set -euo pipefail

ROCKSDB_VERSION="9.7.4"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$HERE/rocksdb-src"
BUILD_DIR="$SRC_DIR/build"
LIB="$BUILD_DIR/librocksdb.a"
TARBALL="$HERE/rocksdb.tar.gz"
URL="https://github.com/facebook/rocksdb/archive/refs/tags/v${ROCKSDB_VERSION}.tar.gz"

if [[ -f "$LIB" ]]; then
    echo "vendor: librocksdb.a already present, nothing to do"
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "vendor: downloading RocksDB v${ROCKSDB_VERSION}"
    curl -fSL --retry 3 -o "$TARBALL" "$URL"
    tar xzf "$TARBALL" -C "$HERE"
    mv "$HERE/rocksdb-${ROCKSDB_VERSION}" "$SRC_DIR"
    rm -f "$TARBALL"
fi

echo "vendor: configuring RocksDB static library"
mkdir -p "$BUILD_DIR"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DROCKSDB_BUILD_SHARED=OFF \
    -DWITH_TESTS=OFF \
    -DWITH_BENCHMARK_TOOLS=OFF \
    -DWITH_TOOLS=OFF \
    -DWITH_CORE_TOOLS=OFF \
    -DWITH_GFLAGS=OFF \
    -DWITH_SNAPPY=ON \
    -DWITH_BZ2=ON \
    -DWITH_LZ4=ON \
    -DWITH_ZSTD=ON \
    -DWITH_ZLIB=ON \
    -DUSE_RTTI=1 \
    -DPORTABLE=1 \
    -DFAIL_ON_WARNINGS=OFF

echo "vendor: compiling (this takes a while)"
cmake --build "$BUILD_DIR" --target rocksdb -j "$(nproc)"

echo "vendor: built $LIB"
