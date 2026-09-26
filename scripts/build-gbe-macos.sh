#!/bin/bash
# Build a universal (arm64 + x86_64) gbe_fork libsteam_api.dylib for macOS.
#
# The result is a drop-in replacement for Valve's macOS libsteam_api.dylib
# (install name @loader_path/libsteam_api.dylib). See Native/GBEMac/README.md.
#
# Usage: ./scripts/build-gbe-macos.sh [--clean] [--install] [--test]
#   --clean    remove the build directory first (full rebuild of every dependency)
#   --install  copy the signed result into the SteamCore resources
#   --test     run Native/GBEMac/test/run-test.sh against the result (both archs)
#
# Environment:
#   GBE_BUILD_DIR   build tree (default: <repo>/.build/gbe-macos, which is git-ignored)
#   GBE_JOBS        parallel jobs (default: hw.ncpu)
#
# Everything the script downloads is pinned by commit or tag and checked by SHA-256.
# Third-party libraries are built from source per architecture and linked
# statically. Only libz, libcurl and libc++ come from the macOS SDK (/usr/lib).
set -euo pipefail

# ---------------------------------------------------------------------------
# Pins
# ---------------------------------------------------------------------------
# gbe_fork (https://github.com/Detanup01/gbe_fork), branch `dev`, 2026-09-25.
GBE_REPO="https://github.com/Detanup01/gbe_fork.git"
GBE_COMMIT="73a7349deb660f689d3358179b76eca039178f73"
# Upstream keeps its dependency source tarballs on the `third-party/deps/common`
# branch. This is the commit that GBE_COMMIT's submodule pointer references.
GBE_DEPS_COMMIT="92a4a130262083c4e887155cbe6bcab99baf36ea"
GBE_DEPS_RAW="https://raw.githubusercontent.com/Detanup01/gbe_fork/${GBE_DEPS_COMMIT}"

# name|url|sha256
DEPS=(
  "protobuf|${GBE_DEPS_RAW}/protobuf/protobuf.tar.gz|1f29cfcd40dbb033ebd7680e42ddefb22fdc3e5ac1c37a4f09d4931cbfae7ba1"  # protobuf v34.1
  "mbedtls|${GBE_DEPS_RAW}/mbedtls/mbedtls.tar.gz|27133c38f383738d8ba0f0d86b52226f1ef3a48da32fed1a2e306b8ded66b6d8"     # mbedtls v3.6.6
  "libssq|${GBE_DEPS_RAW}/libssq/libssq.tar.gz|e92860f8ff94e04485174b6e075fac8dd56a5ebacbb245ccee0d8104fa3074f4"        # libssq v3.0.1
  # protobuf 34.1 pins abseil-cpp 20250512.1 (cmake/dependencies.cmake). Upstream
  # gbe_fork lets CMake git-clone it at configure time; we pin the tarball instead.
  "abseil|https://github.com/abseil/abseil-cpp/archive/refs/tags/20250512.1.tar.gz|9b7a064305e9fd94d124ffa6cc358592eb42b5da588fb4e07d09254aa40086db"
)

ARCHS=(arm64 x86_64)
export MACOSX_DEPLOYMENT_TARGET=11.0

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT_DIR="$REPO_ROOT/Native/GBEMac"
BUILD_DIR="${GBE_BUILD_DIR:-$REPO_ROOT/.build/gbe-macos}"
JOBS="${GBE_JOBS:-$(sysctl -n hw.ncpu)}"
RESOURCE_DEST="$REPO_ROOT/Packages/SteamKit/Sources/SteamCore/Resources/steampipe/libsteam_api.dylib"

clean=false install=false run_test=false
for arg in "$@"; do
  case "$arg" in
    --clean) clean=true ;;
    --install) install=true ;;
    --test) run_test=true ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }

for tool in cmake git curl shasum xcrun lipo codesign; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

# Keep Homebrew (and any other user prefix) out of the compile and link: the
# shipped dylib must only reference /usr/lib and /System.
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH LDFLAGS CFLAGS CXXFLAGS CPPFLAGS
export ZERO_AR_DATE=1   # deterministic static archives
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
CC="$(xcrun --sdk macosx -f clang)"
CXX="$(xcrun --sdk macosx -f clang++)"
export CC CXX

# CMake may spell /private/tmp/... as /tmp/..., so map both spellings.
PREFIX_MAP="-ffile-prefix-map=$BUILD_DIR=/gbe-build -ffile-prefix-map=${BUILD_DIR#/private}=/gbe-build"

COMMON_CMAKE=(
  -G "Unix Makefiles"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_COMPILER="$CC"
  -DCMAKE_CXX_COMPILER="$CXX"
  -DCMAKE_OSX_SYSROOT="$SDKROOT"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local"
  -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
  -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  # Static deps are folded into the dylib; keep their symbols private.
  -DCMAKE_C_VISIBILITY_PRESET=hidden
  -DCMAKE_CXX_VISIBILITY_PRESET=hidden
  -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON
  -DBUILD_SHARED_LIBS=OFF
  # Reproducibility: no build-tree paths in the binary (__FILE__, asserts).
  -DCMAKE_C_FLAGS="$PREFIX_MAP"
  -DCMAKE_CXX_FLAGS="$PREFIX_MAP"
  -DZLIB_INCLUDE_DIR="$SDKROOT/usr/include"
  -DZLIB_LIBRARY="$SDKROOT/usr/lib/libz.tbd"
)

if $clean; then
  log "Cleaning $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"/{downloads,src,deps,out}

# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------
fetch_deps() {
  local entry name url sha file
  for entry in "${DEPS[@]}"; do
    IFS='|' read -r name url sha <<<"$entry"
    file="$BUILD_DIR/downloads/$name.tar.gz"
    if [[ ! -f "$file" ]] || ! echo "$sha  $file" | shasum -a 256 -c --status; then
      log "Downloading $name"
      curl -fsSL --retry 3 -o "$file.part" "$url"
      mv "$file.part" "$file"
    fi
    echo "$sha  $file" | shasum -a 256 -c --status || {
      echo "SHA-256 mismatch for $name ($file)" >&2; exit 1; }
    if [[ ! -f "$BUILD_DIR/src/$name/.extracted-$sha" ]]; then
      rm -rf "$BUILD_DIR/src/$name"
      mkdir -p "$BUILD_DIR/src/$name"
      tar xzf "$file" -C "$BUILD_DIR/src/$name" --strip-components 1
      touch "$BUILD_DIR/src/$name/.extracted-$sha"
    fi
  done
}

fetch_gbe() {
  local dir="$BUILD_DIR/src/gbe_fork"
  if [[ ! -d "$dir/.git" ]]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "$GBE_REPO"
  fi
  if ! git -C "$dir" cat-file -e "$GBE_COMMIT^{commit}" 2>/dev/null; then
    log "Fetching gbe_fork $GBE_COMMIT"
    git -C "$dir" fetch -q --depth 1 origin "$GBE_COMMIT"
  fi
  # Reset the build copy to the pinned commit, then apply our patches.
  git -C "$dir" -c advice.detachedHead=false checkout -q -f "$GBE_COMMIT"
  git -C "$dir" clean -q -fdx
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$GBE_COMMIT" ]]
  local patch
  for patch in "$PORT_DIR"/patches/*.patch; do
    [[ -e "$patch" ]] || continue
    echo "applying $(basename "$patch")"
    git -C "$dir" apply --whitespace=nowarn "$patch"
  done
}

# ---------------------------------------------------------------------------
# Dependencies (static, per architecture)
# ---------------------------------------------------------------------------
# cmake_dep <name> <arch> <source-dir> [cmake args...]
cmake_dep() {
  local name="$1" arch="$2" src="$3"; shift 3
  local prefix="$BUILD_DIR/deps/$arch"
  local stamp="$prefix/.built-$name"
  local sig
  sig="$(printf '%s\n' "$@" "${COMMON_CMAKE[@]}" | shasum -a 256 | cut -c1-16)"
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$sig" ]]; then
    echo "$name ($arch) up to date"
    return
  fi
  log "Building $name ($arch)"
  local bdir="$BUILD_DIR/build/$arch/$name"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  cmake -S "$src" -B "$bdir" "${COMMON_CMAKE[@]}" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_PREFIX_PATH="$prefix" \
    "$@" >"$bdir.configure.log" 2>&1 || { tail -40 "$bdir.configure.log"; exit 1; }
  cmake --build "$bdir" --parallel "$JOBS" >"$bdir.build.log" 2>&1 || { tail -60 "$bdir.build.log"; exit 1; }
  cmake --install "$bdir" >"$bdir.install.log" 2>&1 || { tail -40 "$bdir.install.log"; exit 1; }
  echo "$sig" >"$stamp"
}

build_deps() {
  local arch="$1" host_arch
  host_arch="$(uname -m)"
  local build_protoc=OFF
  [[ "$arch" == "$host_arch" ]] && build_protoc=ON

  cmake_dep libssq "$arch" "$BUILD_DIR/src/libssq"

  cmake_dep mbedtls "$arch" "$BUILD_DIR/src/mbedtls" \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DMBEDTLS_FATAL_WARNINGS=OFF \
    -DLINK_WITH_PTHREAD=ON

  # Same options as upstream premake5-deps.lua, except that abseil comes from
  # the pinned local tarball instead of a configure-time git clone.
  cmake_dep protobuf "$arch" "$BUILD_DIR/src/protobuf" \
    -DCMAKE_CXX_STANDARD=17 -DABSL_PROPAGATE_CXX_STD=ON \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DFETCHCONTENT_SOURCE_DIR_ABSL="$BUILD_DIR/src/abseil" \
    -Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON \
    -DABSL_ENABLE_INSTALL=ON \
    -Dprotobuf_BUILD_PROTOBUF_BINARIES=ON \
    -Dprotobuf_BUILD_PROTOC_BINARIES="$build_protoc" \
    -Dprotobuf_BUILD_LIBPROTOC="$build_protoc" \
    -Dprotobuf_BUILD_LIBUPB="$build_protoc" \
    -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_EXAMPLES=OFF \
    -Dprotobuf_DISABLE_RTTI=ON -Dprotobuf_BUILD_CONFORMANCE=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF -Dprotobuf_WITH_ZLIB=ON
}

# ---------------------------------------------------------------------------
# gbe_fork
# ---------------------------------------------------------------------------
generate_protos() {
  local protoc="$BUILD_DIR/deps/$(uname -m)/bin/protoc"
  local gbe="$BUILD_DIR/src/gbe_fork"
  local out="$gbe/proto_gen/macos"
  log "Generating protobuf sources with $("$protoc" --version)"
  mkdir -p "$out/tf2"
  (cd "$gbe" && "$protoc" dll/net.proto -I./dll/ --cpp_out="$out")
  (cd "$gbe" && "$protoc" dll/gc_steam/steammessages.proto -I./dll/gc_steam --cpp_out="$out")
  (cd "$gbe" && "$protoc" dll/gc_tf2/*.proto -I./dll/gc_steam -I./dll/gc_tf2 --cpp_out="$out/tf2")
}

build_gbe() {
  local arch="$1"
  local bdir="$BUILD_DIR/build/$arch/gbe"
  log "Building libsteam_api.dylib ($arch)"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  cmake -S "$PORT_DIR" -B "$bdir" "${COMMON_CMAKE[@]}" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_PREFIX_PATH="$BUILD_DIR/deps/$arch" \
    -DGBE_SOURCE_DIR="$BUILD_DIR/src/gbe_fork" \
    -DGBE_DEPS_PREFIX="$BUILD_DIR/deps/$arch" \
    -DGBE_BUILD_STRING="playden-macos-${GBE_COMMIT:0:12}" \
    >"$bdir.configure.log" 2>&1 || { tail -40 "$bdir.configure.log"; exit 1; }
  cmake --build "$bdir" --parallel "$JOBS" >"$bdir.build.log" 2>&1 || { grep -E "error|Error" "$bdir.build.log" | head -60; exit 1; }
  cp "$bdir/libsteam_api.dylib" "$BUILD_DIR/out/libsteam_api.$arch.dylib"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
fetch_deps
fetch_gbe
# Build the host architecture first: it also provides protoc.
host_arch="$(uname -m)"
ordered_archs=("$host_arch")
for a in "${ARCHS[@]}"; do [[ "$a" == "$host_arch" ]] || ordered_archs+=("$a"); done
for arch in "${ordered_archs[@]}"; do build_deps "$arch"; done
generate_protos
for arch in "${ordered_archs[@]}"; do build_gbe "$arch"; done

log "Creating universal binary"
out="$BUILD_DIR/out/libsteam_api.dylib"
thin=()
for arch in "${ARCHS[@]}"; do thin+=("$BUILD_DIR/out/libsteam_api.$arch.dylib"); done
lipo -create "${thin[@]}" -output "$out"
codesign --force --sign - "$out"

lipo -info "$out"
otool -L "$out" | sed -n '1,20p'
# Dependency lines are tab-indented; the per-arch header lines are not.
bad="$(otool -L "$out" | grep $'^\t' | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/|@loader_path/libsteam_api\.dylib$)' || true)"
if [[ -n "$bad" ]]; then
  echo "error: unexpected link dependencies:" >&2; echo "$bad" >&2; exit 1
fi

if $run_test; then
  "$PORT_DIR/test/run-test.sh" "$out"
fi

if $install; then
  cp "$out" "$RESOURCE_DEST"
  echo "installed to $RESOURCE_DEST"
fi

log "SHA-256"
shasum -a 256 "$out"
