#!/bin/bash
set -euo pipefail

# Kernel banner identity: fixed author, host taken from the build distro
# (e.g. Sissiogamer1@ubuntu-26.04, auto-updating with the runner image).
export KBUILD_BUILD_USER="Sissiogamer1"

ID="" VERSION_ID=""
if [ -r /etc/os-release ]; then
    . /etc/os-release
fi
if [ -n "$ID" ]; then
    if [ -n "$VERSION_ID" ]; then
        export KBUILD_BUILD_HOST="${ID}-${VERSION_ID}"
    else
        export KBUILD_BUILD_HOST="${ID}"
    fi
else
    export KBUILD_BUILD_HOST="ubuntu"
fi
unset ID VERSION_ID

# Positional arguments kept compatible with the old workflow:
#   $1 = defconfig
#   $2 = build label (e.g. Next-susfs-nomount)
#   $3 = use ccache for legacy Make build (true/false)
KERNEL_DEFCONFIG="${1:?defconfig is required}"
BUILD_LABEL="${2:?build label is required}"
USING_CCACHE="${3:-false}"

DIR="$(readlink -f .)"
MAIN="$(readlink -f "${DIR}/..")"
KERNEL_DIR="$DIR"
OUT_DIR="$MAIN/out"
ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
CLANG_DIR="$MAIN/toolchains/clang"
BUILD_START="$(date +%s)"

BUILD_WITH_BAZEL="${BUILD_WITH_BAZEL:-false}"
BAZEL_TARGET="${BAZEL_TARGET:-//common:kernel_aarch64_dist}"
BAZEL_ARGS="${BAZEL_ARGS:-}"
BAZEL_DISK_CACHE_DIR="${BAZEL_DISK_CACHE_DIR:-}"
DIST_DIR="${DIST_DIR:-$MAIN/dist}"
KERNEL_VERSION="${KERNEL_VERSION:-6.6}"

write_image_env() {
    local image="$1"
    if [ -n "${GITHUB_ENV:-}" ]; then
        echo "KERNEL_IMAGE=$image" >> "$GITHUB_ENV"
    fi
    echo "Kernel image: $image"
}

find_kernel_image() {
    local root="$1"
    local candidate
    for candidate in Image.gz-dtb Image.gz Image; do
        if [ -f "$root/$candidate" ]; then
            readlink -f "$root/$candidate"
            return 0
        fi
    done
    return 1
}

build_with_kleaf() {
    echo "**** Building with Bazel/Kleaf ****"
    echo "**** Target: $BAZEL_TARGET ****"

    cd "$MAIN"

    if [ ! -x "./tools/bazel" ]; then
        echo "ERROR: $MAIN/tools/bazel was not found or is not executable." >&2
        echo "A complete Kleaf workspace must be prepared before the build." >&2
        exit 1
    fi

    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    local -a bazel_cmd
    bazel_cmd=("./tools/bazel" run)

    if [ -n "$BAZEL_DISK_CACHE_DIR" ]; then
        mkdir -p "$BAZEL_DISK_CACHE_DIR"
        bazel_cmd+=("--disk_cache=$BAZEL_DISK_CACHE_DIR")
        echo "Bazel disk cache: $BAZEL_DISK_CACHE_DIR"
    fi

    # Extra flags are intended for simple whitespace-separated Bazel flags.
    # Keep values that themselves contain spaces out of BAZEL_ARGS.
    if [ -n "$BAZEL_ARGS" ]; then
        local -a extra_args
        read -r -a extra_args <<< "$BAZEL_ARGS"
        bazel_cmd+=("${extra_args[@]}")
    fi

    bazel_cmd+=("$BAZEL_TARGET" -- "--destdir=$DIST_DIR")

    printf 'Running:'
    printf ' %q' "${bazel_cmd[@]}"
    printf '\n'
    "${bazel_cmd[@]}"

    local image
    if ! image="$(find_kernel_image "$DIST_DIR")"; then
        echo "ERROR: No Image/Image.gz/Image.gz-dtb found in $DIST_DIR" >&2
        echo "Dist contents:" >&2
        find "$DIST_DIR" -maxdepth 2 -type f -print >&2 || true
        exit 1
    fi

    write_image_env "$image"
}

check_clang() {
    if [ -d "$CLANG_DIR" ] && [ -f "$CLANG_DIR/bin/clang" ]; then
        export PATH="$CLANG_DIR/bin:$PATH"
        KBUILD_COMPILER_STRING="$($CLANG_DIR/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
        export KBUILD_COMPILER_STRING
        echo "Found existing Clang: $KBUILD_COMPILER_STRING"
        return 0
    fi
    return 1
}

build_with_make() {
    echo "$MAIN"
    echo "$CLANG_DIR"

    if ! check_clang; then
        echo "Clang not found :(" >&2
        exit 1
    fi

    export LD=ld.lld
    export ARCH=arm64
    export SUBARCH=arm64
    export CROSS_COMPILE=aarch64-linux-gnu-
    export KERNEL_SRC="$KERNEL_DIR"

    local -a make_opts
    if [ "$USING_CCACHE" = "true" ]; then
        make_opts=(
            CC="ccache clang"
            STRIP=llvm-strip
            LD=ld.lld
            AR=llvm-ar
            NM=llvm-nm
            OBJCOPY=llvm-objcopy
            OBJDUMP=llvm-objdump
            HOSTCC="ccache clang"
            HOSTCXX="ccache clang++"
            HOSTAR=llvm-ar
            HOSTLD=ld.lld
            LLVM=1
            LLVM_IAS=1
            KCFLAGS="-w"
        )
    else
        make_opts=(
            CC=clang
            STRIP=llvm-strip
            LD=ld.lld
            AR=llvm-ar
            NM=llvm-nm
            OBJCOPY=llvm-objcopy
            OBJDUMP=llvm-objdump
            HOSTCC=clang
            HOSTCXX=clang++
            HOSTAR=llvm-ar
            HOSTLD=ld.lld
            LLVM=1
            LLVM_IAS=1
            KCFLAGS="-w"
        )
    fi

    echo "Applying YYLLOC workaround..."
    local yyll1="$KERNEL_DIR/scripts/dtc/dtc-lexer.lex.c_shipped"
    local yyll2="$KERNEL_DIR/scripts/dtc/dtc-lexer.l"
    [ -f "$yyll1" ] && sed -i 's/extern YYLTYPE yylloc/YYLTYPE yylloc/g;s/YYLTYPE yylloc/extern YYLTYPE yylloc/g' "$yyll1"
    [ -f "$yyll2" ] && sed -i 's/extern YYLTYPE yylloc/YYLTYPE yylloc/g;s/YYLTYPE yylloc/extern YYLTYPE yylloc/g' "$yyll2"

    echo "**** Building with $KBUILD_COMPILER_STRING ****"
    echo "**** Defconfig: $KERNEL_DEFCONFIG ****"

    make O="$OUT_DIR" "$KERNEL_DEFCONFIG" "${make_opts[@]}"
    make -j"$(nproc --all)" O="$OUT_DIR" "${make_opts[@]}"

    [ -d "$KERNEL_DIR/.git" ] && git restore "$yyll1" "$yyll2" 2>/dev/null || true

    local image
    if ! image="$(find_kernel_image "$ZIMAGE_DIR")"; then
        echo "ERROR: No Image/Image.gz/Image.gz-dtb found in $ZIMAGE_DIR" >&2
        exit 1
    fi
    write_image_env "$image"
}

if [ "$BUILD_WITH_BAZEL" = "true" ]; then
    build_with_kleaf
else
    build_with_make
fi

BUILD_END="$(date +%s)"
DIFF=$((BUILD_END - BUILD_START))
echo -e "\nBuild completed in $((DIFF / 60))m $((DIFF % 60))s"
echo "Build label: $BUILD_LABEL"
echo "Kernel version: $KERNEL_VERSION"
