#!/usr/bin/env bash
# Git Bash entry point for the existing native Windows Make/Ninja build.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
case "$(uname -s)" in
    MINGW*|MSYS*)
        bin="$root/.deps/ucrt64/bin"
        if [[ ! -f "$bin/mingw32-make.exe" ]]; then
            printf '%s\n' 'Native build dependencies are missing. Run in Git Bash:' >&2
            printf '  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s/tools/bootstrap.ps1"\n' "$(cygpath -m "$root")" >&2
            exit 127
        fi
        export PATH="$bin:$PATH"
        # Keep MSYS argument conversion enabled for user-supplied /c/... paths.
        exec "$bin/mingw32-make.exe" -C "$(cygpath -m "$root")" "$@"
        ;;
    *)
        printf '%s\n' 'The current Makefile targets native Windows. Linux build support is planned separately.' >&2
        exit 2
        ;;
esac
