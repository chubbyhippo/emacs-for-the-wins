# emacs-for-the-wins

Self-compiled, portable, native-comp GNU Emacs for Windows via MSYS2.

| | |
|---|---|
| Shell required | `mingw64.exe` from an MSYS2 install (not `msys2.exe`, not `ucrt64.exe`) |
| Source | `git.savannah.gnu.org/git/emacs.git`, `emacs-30` branch, depth 1 |
| Output | `dist/emacs-<branch>-win64/` — runs standalone, no MSYS2 needed on the target machine |

## First-time MSYS2 setup (once per machine)

| Install method | Extra step before `install.sh` |
|---|---|
| MSYS2 installer (msys2.org) | none — the installer's first run already does this |
| `scoop install msys2` | run `msys2.exe` **once** (not `mingw64.exe`) and let it finish; it bootstraps the pacman keyring (`pacman-key --init`/`--populate`) and prints "restart shell to apply necessary actions" — restart the shell, then proceed |

Symptom if skipped: `pacman -S` fails or `etc/pacman.d/gnupg/` is missing/empty.

## Install

```sh
./install.sh
```

| Flag | Effect |
|---|---|
| `--list` | print resolved settings, do nothing |
| `--skip-deps` | skip `pacman` package install |
| `--skip-clone` | reuse an existing checkout at `$SRC_DIR` |
| `--skip-build` | reuse an existing build at `$SRC_DIR/build` |
| `--skip-portable` | skip the portability (DLL-closure) step |
| `--skip-fixups` | skip auto-applying the known upstream fixes (see below) |
| `--only-portable` | just (re)run the portability + verify steps |
| `--branch <name>` | git branch to build (default `emacs-30`) |
| `--repo <url>` | git remote to clone (default the Savannah mirror above) |
| `--src-dir <path>` | checkout location (default `build/emacs-src`) |
| `--prefix <path>` | install location (default `dist/emacs-<branch>-win64`) |
| `--jobs <n>` | parallel build jobs (default `nproc`) |

Env var overrides: `EMACS_REPO`, `EMACS_BRANCH`, `EMACS_SRC_DIR`, `EMACS_PREFIX`, `EMACS_BUILD_JOBS`.

## What it does

| Step | Action |
|---|---|
| 1. Dependencies | `pacman -S` the `mingw-w64-x86_64-*` toolchain + libgccjit + image/xml/gnutls/tree-sitter libs, plus `git`/`autoconf`/`automake`/`texinfo` |
| 2. Clone | `git clone --branch <branch> --depth 1 <repo>` |
| 3. Build | `autogen.sh` → `configure --with-native-compilation=aot --with-tree-sitter --with-gnutls --with-xpm` → `make bootstrap` → `make install` (a known-fix cherry-picks an unreleased upstream commit first if `nt/inc/ms-w32.h` needs it — see Known issues) |
| 4. Portable | copies `as.exe`/`ld.exe`/CRT objects/static archives into `lib/gcc`, then closes the DLL dependency graph (`ldd`-driven, iterative) into `bin/`; also auto-swaps in a working `libtree-sitter` build if the one `pacman` installed is missing a symbol this Emacs snapshot needs (see Known issues) |
| 5. Verify | evals `native-comp-available-p` and `treesit-available-p` in the built `emacs.exe`, warning (not failing the whole run) if either is nil |

## Verify

`install.sh` runs this automatically at the end and prints the result; to check by hand:

```sh
"$PREFIX/bin/emacs.exe" --batch --eval '(princ (format "native-comp=%s treesit=%s" (native-comp-available-p) (treesit-available-p)))'
```

Both should print `t`.

## Known issues

| Symptom | Cause | Fix |
|---|---|---|
| `treesit-available-p` is `nil` despite `--with-tree-sitter` | current MSYS2 `mingw-w64-x86_64-libtree-sitter` (≥0.25) dropped the `ts_language_version` symbol this Emacs snapshot's `treesit.c` still resolves; Windows' delayed-load fails silently, with no error surfaced anywhere in Lisp | auto-fixed by `install.sh`'s portable step (downloads a 0.24.7 build that still exports the symbol and swaps it in); re-run with `--only-portable` to retry, or pass `--skip-fixups` to disable and fix manually |
| link fails with `undefined reference to '__imp_sys_strerror'` | `emacs-30` predates an upstream MinGW64-headers fix | auto-fixed by the build step (cherry-picks the two-file diff); `--skip-fixups` disables |

## Run

```sh
"$PREFIX/bin/runemacs.exe"
```

Or add `$PREFIX/bin` to `PATH`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
