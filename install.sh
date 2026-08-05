#!/bin/bash
# Copyright (C) 2026 Chubby Hippo
# SPDX-License-Identifier: GPL-3.0-or-later
#
#   ./install.sh                 do everything: deps, clone, build, portable
#   ./install.sh --list          show resolved settings and exit
#   ./install.sh --skip-deps     skip the pacman install step
#   ./install.sh --skip-clone    reuse an existing checkout at $SRC_DIR
#   ./install.sh --skip-build    reuse an existing build at $SRC_DIR/build
#   ./install.sh --only-portable just (re)run the portability step
#   ./install.sh --branch emacs-31 --repo <url> --jobs 8 --prefix <dir>
#
# Must be run from an MSYS2 "mingw64.exe" shell.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

EMACS_REPO=${EMACS_REPO:-https://git.savannah.gnu.org/git/emacs.git}
EMACS_BRANCH=${EMACS_BRANCH:-emacs-30}
SRC_DIR=${EMACS_SRC_DIR:-"$here/build/emacs-src"}
PREFIX=${EMACS_PREFIX:-"$here/dist/emacs-${EMACS_BRANCH}-win64"}
JOBS=${EMACS_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}

do_deps=1 do_clone=1 do_build=1 do_portable=1 list_only=0

usage() { sed -n '4,11p' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --list)          list_only=1 ;;
        --skip-deps)      do_deps=0 ;;
        --skip-clone)     do_clone=0 ;;
        --skip-build)     do_build=0 ;;
        --only-portable)  do_deps=0; do_clone=0; do_build=0 ;;
        --branch)         EMACS_BRANCH=$2; shift ;;
        --repo)           EMACS_REPO=$2; shift ;;
        --src-dir)        SRC_DIR=$2; shift ;;
        --prefix)         PREFIX=$2; shift ;;
        --jobs)           JOBS=$2; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [ "$list_only" -eq 1 ]; then
    echo "MSYSTEM      : ${MSYSTEM:-<unset>}"
    echo "repo/branch  : $EMACS_REPO ($EMACS_BRANCH)"
    echo "source dir   : $SRC_DIR"
    echo "install dir  : $PREFIX"
    echo "build jobs   : $JOBS"
    echo "steps        : deps=$do_deps clone=$do_clone build=$do_build portable=$do_portable"
    exit 0
fi

# --------------------------------------------------------------- 0. environment
if [ "${MSYSTEM:-}" != "MINGW64" ]; then
    die "run this from the MSYS2 'mingw64.exe' shell (found MSYSTEM=${MSYSTEM:-<unset>}). Launch mingw64.exe from the MSYS2 install directory and re-run."
fi

# ---------------------------------------------------------- 1. required tools
if [ "$do_deps" -eq 1 ]; then
    info "installing build dependencies via pacman"
    pacman -S --needed --noconfirm \
        base-devel \
        git \
        autoconf \
        automake \
        texinfo \
        mingw-w64-x86_64-toolchain \
        mingw-w64-x86_64-xpm-nox \
        mingw-w64-x86_64-gmp \
        mingw-w64-x86_64-gnutls \
        mingw-w64-x86_64-libtiff \
        mingw-w64-x86_64-giflib \
        mingw-w64-x86_64-libpng \
        mingw-w64-x86_64-libjpeg-turbo \
        mingw-w64-x86_64-librsvg \
        mingw-w64-x86_64-libwebp \
        mingw-w64-x86_64-lcms2 \
        mingw-w64-x86_64-libxml2 \
        mingw-w64-x86_64-zlib \
        mingw-w64-x86_64-harfbuzz \
        mingw-w64-x86_64-libgccjit \
        mingw-w64-x86_64-sqlite3 \
        mingw-w64-x86_64-libtree-sitter
else
    warn "skipping dependency install (--skip-deps)"
fi

# -------------------------------------------------------------- 2. clone
if [ "$do_clone" -eq 1 ]; then
    if [ -d "$SRC_DIR/.git" ]; then
        warn "$SRC_DIR already a git checkout — kept (remove it or pass --skip-clone to reuse)"
    else
        git config --global core.autocrlf false
        info "cloning $EMACS_REPO ($EMACS_BRANCH, depth 1) -> $SRC_DIR"
        mkdir -p "$(dirname "$SRC_DIR")"
        git clone --branch "$EMACS_BRANCH" --depth 1 "$EMACS_REPO" "$SRC_DIR"
    fi
else
    warn "skipping clone (--skip-clone)"
fi

# -------------------------------------------------------------- 3. build
if [ "$do_build" -eq 1 ]; then
    [ -d "$SRC_DIR" ] || die "$SRC_DIR does not exist — run without --skip-clone first"
    info "running autogen.sh"
    (cd "$SRC_DIR" && ./autogen.sh)

    build_dir="$SRC_DIR/build"
    mkdir -p "$build_dir"
    info "configuring (prefix=$PREFIX)"
    (cd "$build_dir" && ../configure "prefix=$PREFIX" \
        --with-native-compilation=aot \
        --with-tree-sitter \
        --with-gnutls \
        --with-xpm \
        --without-dbus \
        --without-pop)

    info "building (make bootstrap -j$JOBS)"
    (cd "$build_dir" && make bootstrap -j"$JOBS")
    info "installing -> $PREFIX"
    (cd "$build_dir" && make install)
else
    warn "skipping build (--skip-build)"
fi

# ---------------------------------------------------- 4. make it portable
if [ "$do_portable" -eq 1 ]; then
    [ -x "$PREFIX/bin/emacs.exe" ] || die "$PREFIX/bin/emacs.exe not found — build it first"
    info "making $PREFIX portable outside MSYS2"

    gcc_dir="$PREFIX/lib/gcc"
    mkdir -p "$gcc_dir"

    cp /mingw64/lib/{crtbegin,crtend,dllcrt2}.o "$gcc_dir/"
    cp /mingw64/lib/lib{advapi32,gcc_s,mingw32,msvcrt,shell32,kernel32,mingwex,pthread,user32}.a "$gcc_dir/"
    gcc_ver=$(gcc -dumpversion)
    cp "/mingw64/lib/gcc/x86_64-w64-mingw32/$gcc_ver/libgcc.a" "$gcc_dir/"
    cp /mingw64/bin/{as,ld}.exe "$gcc_dir/"

    bin_dir="$PREFIX/bin"
    for lib in libtree-sitter libgccjit; do
        for f in /mingw64/bin/"$lib"-*.dll; do
            [ -f "$f" ] && cp -n "$f" "$bin_dir/"
        done
    done

    while :; do
        missing=$(find "$PREFIX" \( -name '*.exe' -o -name '*.dll' \) -print0 \
            | xargs -0 ldd 2>/dev/null \
            | awk '/mingw64/ { print $3 }' \
            | sort -u)
        new=0
        for dll in $missing; do
            base=$(basename "$dll")
            [ -f "$bin_dir/$base" ] && continue
            cp "$dll" "$bin_dir/"
            new=1
        done
        [ "$new" -eq 1 ] || break
    done
else
    warn "skipping portability step (--skip-portable / prior failure)"
fi

info "done: $PREFIX"
echo "verify native-comp:  \"$PREFIX/bin/emacs.exe\" --batch --eval '(princ (native-comp-available-p))'"
echo "run it (from any shell, MSYS2 or plain cmd/PowerShell): \"$PREFIX/bin/runemacs.exe\""
echo "add \"$PREFIX/bin\" to PATH to use it as your default emacs"
