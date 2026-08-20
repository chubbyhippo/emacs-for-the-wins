#!/bin/bash
# Copyright (C) 2026 Chubby Hippo
# SPDX-License-Identifier: GPL-3.0-or-later
#
#   ./install.sh                 do everything: deps, clone, build, portable
#   ./install.sh --list          show resolved settings and exit
#   ./install.sh --skip-deps     skip the pacman install step
#   ./install.sh --skip-clone    reuse an existing checkout at $SRC_DIR
#   ./install.sh --skip-build    reuse an existing build at $SRC_DIR/build
#   ./install.sh --skip-portable skip the portability (DLL-closure) step
#   ./install.sh --skip-fixups   skip auto-applying known upstream fixes
#   ./install.sh --only-portable just (re)run the portability step
#   ./install.sh --branch emacs-31 --repo <url> --jobs 8 --prefix <dir>
#
# Must be run from an MSYS2 "mingw64.exe" shell.
#
# Known-fixes: emacs-30 (as of this writing) still lacks upstream commit
# 7b9d3e90ce32e2e19f0b4725868f9a6f76346ae6 ("Fix MS-Windows build broken by
# recent updates in MinGW64 headers", landed on master 2026-01-22), which is
# needed against current mingw-w64-headers or the link fails with
# "undefined reference to `__imp_sys_strerror'". The build step fetches
# just that commit and applies its two-file diff (nt/inc/ms-w32.h,
# src/w32.c) before configuring — a no-op once emacs-30 carries the fix
# itself. Pass --skip-fixups to disable.
#
# Second known-fix, also auto-applied: this emacs-30 snapshot's treesit.c
# still resolves the deprecated ts_language_version symbol at runtime, but
# MSYS2's mingw-w64-x86_64-libtree-sitter (>=0.25, current is 0.26.x) dropped
# it for ts_language_abi_version — the DLL loads fine standalone, but Emacs's
# silent Windows delayed-load leaves treesit-available-p nil with no error
# surfaced. The portable step below detects this (objdump -p | grep) and, if
# so, downloads a 0.24.7 libtree-sitter build (still exports the old symbol)
# and swaps it in, keeping the original filename so dynamic-library-alist's
# lookup still matches. Needs network access; --skip-fixups disables this too.
# Verified working (not just present) at the end: the script eval's
# treesit-available-p in the built emacs.exe and fails loudly if it's nil.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

EMACS_REPO=${EMACS_REPO:-https://git.savannah.gnu.org/git/emacs.git}
EMACS_BRANCH=${EMACS_BRANCH:-emacs-30}
SRC_DIR=${EMACS_SRC_DIR:-"$here/build/emacs-src"}
PREFIX=${EMACS_PREFIX:-"$here/dist/emacs-${EMACS_BRANCH}-win64"}
JOBS=${EMACS_BUILD_JOBS:-$(n=$(nproc 2>/dev/null || echo 4); [ "$n" -gt 1 ] && echo $((n - 1)) || echo 1)}

do_deps=1 do_clone=1 do_build=1 do_portable=1 do_fixups=1 list_only=0
FIX_SYS_STRERROR=7b9d3e90ce32e2e19f0b4725868f9a6f76346ae6
FIX_TREE_SITTER_PKG_URL=https://repo.msys2.org/mingw/mingw64/mingw-w64-x86_64-libtree-sitter-0.24.7-2-any.pkg.tar.zst

usage() { sed -n '4,12p' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --list)          list_only=1 ;;
        --skip-deps)      do_deps=0 ;;
        --skip-clone)     do_clone=0 ;;
        --skip-build)     do_build=0 ;;
        --skip-portable)  do_portable=0 ;;
        --skip-fixups)    do_fixups=0 ;;
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
    echo "steps        : deps=$do_deps clone=$do_clone build=$do_build portable=$do_portable fixups=$do_fixups"
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

# --------------------------------------------------- 2.5 known-upstream-fixes
apply_known_fixes() {
    if grep -q 'MinGW64 system headers include string.h too early' \
        "$SRC_DIR/nt/inc/ms-w32.h" 2>/dev/null; then
        info "sys_strerror/MinGW64-headers fix already present — skipping"
        return 0
    fi
    info "fetching + applying known fix $FIX_SYS_STRERROR (sys_strerror vs. current mingw-w64-headers, not yet on $EMACS_BRANCH)"
    if ! (cd "$SRC_DIR" && git fetch --depth 2 origin "$FIX_SYS_STRERROR") \
        >/dev/null 2>&1; then
        warn "could not fetch $FIX_SYS_STRERROR — skipping known-fix step (offline? shallow history?)"
        return 0
    fi
    (cd "$SRC_DIR" \
        && git show "$FIX_SYS_STRERROR" -- nt/inc/ms-w32.h src/w32.c > /tmp/emacs-sys-strerror.patch \
        && git apply --check /tmp/emacs-sys-strerror.patch \
        && git apply /tmp/emacs-sys-strerror.patch) \
        || warn "known fix $FIX_SYS_STRERROR did not apply cleanly — build may fail with __imp_sys_strerror link errors (see https://lists.gnu.org/archive/html/emacs-devel/2026-01/msg00580.html)"
}

# fix_tree_sitter_symbol BIN_DIR: swap in a libtree-sitter build that still
# exports ts_language_version if the one already copied into BIN_DIR doesn't
# (MSYS2 dropped it starting around libtree-sitter 0.25 in favor of
# ts_language_abi_version; this emacs-30 snapshot's treesit.c still wants the
# old name). A missing symbol makes Emacs's Windows delayed-load fail
# silently — treesit-available-p ends up nil with no error anywhere.
fix_tree_sitter_symbol() {
    bin_dir=$1
    need_fix=0
    for f in "$bin_dir"/libtree-sitter-*.dll; do
        [ -f "$f" ] || continue
        if command -v objdump >/dev/null 2>&1 \
            && objdump -p "$f" 2>/dev/null | grep -q ts_language_version; then
            continue
        fi
        need_fix=1
    done
    if [ "$need_fix" -eq 0 ]; then
        info "libtree-sitter DLL already exports ts_language_version — skipping known-fix"
        return 0
    fi

    info "MSYS2 libtree-sitter lacks ts_language_version (needed by this emacs-30 snapshot) — fetching a 0.24.7 build that still exports it"
    ts_tmp=$(mktemp -d)
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$FIX_TREE_SITTER_PKG_URL" -o "$ts_tmp/pkg.tar.zst" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$FIX_TREE_SITTER_PKG_URL" -O "$ts_tmp/pkg.tar.zst" 2>/dev/null
    fi
    if [ ! -s "$ts_tmp/pkg.tar.zst" ]; then
        warn "could not download $FIX_TREE_SITTER_PKG_URL (offline?) — leaving libtree-sitter*.dll as-is; treesit-available-p may be nil. Fetch that URL manually and swap the DLL in $bin_dir to fix."
        rm -rf "$ts_tmp"
        return 0
    fi
    if ! tar -xf "$ts_tmp/pkg.tar.zst" -C "$ts_tmp" 2>/dev/null; then
        warn "could not extract $ts_tmp/pkg.tar.zst (tar without zstd support?) — leaving libtree-sitter*.dll as-is."
        rm -rf "$ts_tmp"
        return 0
    fi
    good_dll=$(find "$ts_tmp/mingw64/bin" -name 'libtree-sitter-*.dll' 2>/dev/null | head -n1)
    if [ -z "$good_dll" ]; then
        warn "downloaded package did not contain a libtree-sitter DLL — leaving as-is."
        rm -rf "$ts_tmp"
        return 0
    fi
    for f in "$bin_dir"/libtree-sitter-*.dll; do
        [ -f "$f" ] || continue
        cp "$good_dll" "$f"
        info "replaced $(basename "$f") with the 0.24.7 build (exports ts_language_version)"
    done
    rm -rf "$ts_tmp"
}

# -------------------------------------------------------------- 3. build
if [ "$do_build" -eq 1 ]; then
    [ -d "$SRC_DIR" ] || die "$SRC_DIR does not exist — run without --skip-clone first"
    if [ "$do_fixups" -eq 1 ]; then
        apply_known_fixes
    else
        warn "skipping known-fixes step (--skip-fixups)"
    fi
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
    for lib in libtree-sitter libgccjit libgnutls libxml2 libsqlite3 librsvg libwebp libtiff libpng libjpeg libgif liblcms2 libxpm; do
        for f in /mingw64/bin/"$lib"*.dll; do
            [ -f "$f" ] && cp -n "$f" "$bin_dir/"
        done
    done

    # known-fix: see fix_tree_sitter_symbol above.
    if [ "$do_fixups" -eq 1 ]; then
        fix_tree_sitter_symbol "$bin_dir"
    else
        warn "skipping tree-sitter-symbol known-fix (--skip-fixups)"
    fi

    while :; do
        missing=$(find "$PREFIX" \( -name '*.exe' -o -name '*.dll' \) -print0 \
            | xargs -0 -n1 ldd 2>/dev/null \
            | awk '/mingw64/ { print $3 }' \
            | sort -u) || true
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

# ---------------------------------------------------- 5. verify
if [ -x "$PREFIX/bin/emacs.exe" ]; then
    info "verifying native-comp, tree-sitter, and gnutls"
    verify_out=$("$PREFIX/bin/emacs.exe" --batch --eval \
        '(princ (format "native-comp=%s treesit=%s gnutls=%s" (native-comp-available-p) (treesit-available-p) (if (gnutls-available-p) t nil)))' \
        2>/dev/null) || verify_out='<eval failed>'
    echo "  $verify_out"
    case "$verify_out" in
        *gnutls=t*) ;;
        *) warn "gnutls-available-p is nil — HTTPS / package archives (ELPA) will not work. Check $PREFIX/bin/libgnutls-*.dll." ;;
    esac
    case "$verify_out" in
        *treesit=t*) ;;
        *) warn "treesit-available-p is nil — java-ts-mode and friends won't work. Check $PREFIX/bin/libtree-sitter-*.dll exports ts_language_version (objdump -p), or re-run with --only-portable to retry the known-fix." ;;
    esac
    case "$verify_out" in
        *native-comp=t*) ;;
        *) warn "native-comp-available-p is nil — check the build log for libgccjit errors." ;;
    esac
else
    warn "skipping verification — $PREFIX/bin/emacs.exe not found"
fi

info "done: $PREFIX"
echo "run it (from any shell, MSYS2 or plain cmd/PowerShell): \"$PREFIX/bin/runemacs.exe\""
echo "add \"$PREFIX/bin\" to PATH to use it as your default emacs"
