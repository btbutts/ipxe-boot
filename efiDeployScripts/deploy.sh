#!/usr/bin/env bash
#
# deploy.sh — Deploy iPXE boot scripts to the web hosting server output directory.
#             Optionally builds the iPXE .efi binary via make first.
#
# Compatible with bash 3.2+ (macOS default) and bash 5.x (Ubuntu).
# Paths are resolved relative to this script's location — no hardcoded
# home directories, no tildes.
#
# Usage: ./deploy.sh [OPTIONS]
#   -B, --build-efi          Build the iPXE .efi binary via make before deploying
#   --embed [path|none]      EMBED script for make (see --help for details)
#   --debug [args]           DEBUG value for make  (default when present: "iscsi:3,tcp")
#   --output <name>          .efi output filename  (default: snponly.efi)
#   --overwrite-credentials  Re-prompt for iSCSI credentials, overwrite credential.temp.env
#   -h, --help               Show this help and exit
#
# The resulting .efi (if built) is always deployed as:
#   $OUTPUT_DIR/snponly-bootScript.efi

set -uo pipefail
# Note: -e is intentionally omitted so per-file copy errors are tracked
# explicitly without aborting the entire deploy run.

# Save original argv before parsing — needed for the --pager re-exec below.
ORIGINAL_ARGS=("$@")

# ── Resolve paths relative to this script ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src/bootScripts"
IPXE_SRC_DIR="$PROJECT_ROOT/src"
OUTPUT_DIR="/mnt/QNAP-Public/PXE"
CALLER_CWD="$PWD"        # working directory of whoever invoked this script

# ── Credential file paths ─────────────────────────────────────────────────────
CRED_ENV="$SCRIPT_DIR/credential.temp.env"
CRED_SRC_IPXE="$SRC_DIR/iscsiChapCredential.ipxe"
CRED_SRC_CMD="$SRC_DIR/winSys32-Scripts/iscsi-creds.cmd"
CRED_SRC_DIRECT="$SRC_DIR/direct.ipxe"
CRED_SRC_INSTALL="$SRC_DIR/install.ipxe"
CRED_SRC_INSTALL_MANUAL="$SRC_DIR/installManual.ipxe"
CRED_SRC_BOOT2="$SRC_DIR/boot2.ipxe"
CRED_TMP_IPXE="$SCRIPT_DIR/iscsiChapCredential.temp.ipxe"
CRED_TMP_CMD="$SCRIPT_DIR/iscsi-creds.temp.cmd"
CRED_TMP_DIRECT="$SCRIPT_DIR/direct.temp.ipxe"
CRED_TMP_INSTALL="$SCRIPT_DIR/install.temp.ipxe"
CRED_TMP_INSTALL_MANUAL="$SCRIPT_DIR/installManual.temp.ipxe"
CRED_TMP_BOOT2="$SCRIPT_DIR/boot2.temp.ipxe"

# Parallel arrays pairing each credential source file with its temp copy.
# Used by the substitution loop in Step 2,3 and the cleanup trap.
CRED_SRCS=(
    "$CRED_SRC_IPXE"           "$CRED_SRC_CMD"
    "$CRED_SRC_DIRECT"         "$CRED_SRC_INSTALL"
    "$CRED_SRC_INSTALL_MANUAL" "$CRED_SRC_BOOT2"
)
CRED_TMPS=(
    "$CRED_TMP_IPXE"           "$CRED_TMP_CMD"
    "$CRED_TMP_DIRECT"         "$CRED_TMP_INSTALL"
    "$CRED_TMP_INSTALL_MANUAL" "$CRED_TMP_BOOT2"
)

# ── Argument defaults ─────────────────────────────────────────────────────────
BUILD=0
EMBED="$PROJECT_ROOT/src/bootScripts/boot.ipxe"
EMBED_EXPLICIT=0
DEBUG_ARGS=""
OUTPUT_NAME="snponly.efi"
OUTPUT_EXPLICIT=0
OVERWRITE_CREDS=0
DRY_RUN=0
# Dry-run tracking — populated during deploy steps, consumed by the analysis section
DRY_NEW_FILES=()
DRY_UPDATE_FILES=()
DRY_EMBED_RAW=""
DRY_EMBED_RESOLVED=""
DRY_MAKE_TARGET_RESULT=""
DRY_MAKE_CMD=""
# Ignore support — populated from .deployignore and --ignore-files
IGNORE_FILES_RAW=()      # raw values from --ignore-files before path resolution
IGNORED_BY_PATH=()       # "resolved_path|||file_label" entries (path-based ignores)
IGNORED_BY_PATTERN=()    # "pattern|||file_label" entries (.deployignore pattern matches)
_IGNORE_REASON=""        # set by is_ignored(); read immediately after each call
USE_PAGER=1              # default on; pass --no-pager to write directly to stdout
WITH_ANSI=0              # set by hidden --_with-ansi in the pager re-exec run

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

  -B, --build-efi          Build the iPXE .efi binary via make, then deploy it
  --embed [path|none]      EMBED script path for make — three behaviours:
                             (omitted)       No boot script embedded in the .efi
                             --embed         Bare flag — embed the default boot script:
                                             $PROJECT_ROOT/src/bootScripts/boot.ipxe
                             --embed none    Explicit no-embed (same as omitting --embed)
                             --embed <path>  Embed the script at the given path
  --debug [args]           DEBUG value passed to make
                           Default when flag is present: "iscsi:3,tcp"
                           Override: --debug "net,3,tcp"
  --output <name>          .efi filename under bin-x86_64-efi/
                           Default: snponly.efi
  --overwrite-credentials  Re-prompt for all iSCSI credentials, overwrite
                           credential.temp.env, and re-deploy credential scripts
  --no-pager               Disable the default pager and write directly to stdout.
                           By default all output is piped through less -S -R for
                           horizontal scrolling (arrow keys) when stdout is a
                           terminal. Pass --no-pager to suppress this — useful
                           for CI, log capture, or plain terminal output.
                           The pager is automatically skipped when stdout is not
                           a terminal (e.g. piped or redirected), so --no-pager
                           is rarely needed outside of scripted contexts.
  --ignore-files <path...> Skip one or more files or directories during deploy.
                           Pass multiple paths as space-separated arguments after
                           the flag — path consumption stops at the next flag:
                             --ignore-files a.cmd b.ipxe dir/ --dry-run
                           Each path is resolved the same way as --embed (relative
                           to the caller's working directory, ~ supported).
                           A directory path matches all source files under it.
                           Skipped files show IGNORE in Steps 1, 2, and 3 output.
                           Does NOT affect the compiled .efi (Steps 4 and 5).
  -n, --dry-run            Simulate the full run without making any changes:
                             - unix2dos conversions are skipped
                             - No files are copied to \$OUTPUT_DIR
                             - The make command is constructed and printed but
                               not executed
                             - A detailed analysis section is printed at the end
                               showing all resolved options, paths, and what
                               would have changed, including any ignored files
  -h, --help               Show this help and exit

.deployignore  (efiDeployScripts/.deployignore — optional, not tracked by git)
  A gitignore-style file listing source files to skip. Lines beginning with #
  are comments. Blank lines are ignored. Pattern matching rules:
    No /   Pattern matched against the file basename only   (e.g. *.log)
    With / Matched against the path relative to \$PROJECT_ROOT as a suffix
           (e.g. setupManual/*.cmd matches .../.../setupManual/foo.cmd)
    /...   Leading / anchors the pattern to \$PROJECT_ROOT
    **     Treated the same as * (bash pattern matching: * matches any chars,
           including path separators, so ** adds no extra power here)
  .deployignore only affects Steps 1–3 (script deployment). It does NOT affect
  the .efi compile-and-deploy in Steps 4–5.

The deployed .efi is always written to:
  $OUTPUT_DIR/snponly-bootScript.efi

Credentials are stored locally in:
  $CRED_ENV
This file is gitignored and never committed.

Examples:
  # Deploy boot scripts only — no build
  $(basename "$0")

  # Build .efi with no embedded boot script
  $(basename "$0") --build-efi

  # Build .efi with the default boot script embedded
  $(basename "$0") --build-efi --embed

  # Build with iSCSI debug output enabled and default embed
  $(basename "$0") --build-efi --embed --debug "iscsi:3,tcp"

  # Build with a custom EMBED script and a different output filename
  $(basename "$0") --build-efi --embed /path/to/custom.ipxe --output myboot.efi

  # Explicitly build without embedding (same as omitting --embed)
  $(basename "$0") --build-efi --embed none

  # Re-enter credentials (e.g. after rotating passwords)
  $(basename "$0") --overwrite-credentials

  # Skip a single file during deploy
  $(basename "$0") --ignore-files src/bootScripts/boot2.ipxe

  # Skip multiple files — space-separated, stops consuming at the next flag
  $(basename "$0") --ignore-files src/bootScripts/boot2.ipxe src/bootScripts/install.ipxe

  # Skip an entire directory (all source files under it are ignored)
  $(basename "$0") --ignore-files src/bootScripts/winSys32-Scripts/setupManual/

  # Combine with other flags — --ignore-files must come before the next flag
  $(basename "$0") --ignore-files src/bootScripts/boot2.ipxe --dry-run
  $(basename "$0") --ignore-files src/bootScripts/boot2.ipxe src/bootScripts/install.ipxe --dry-run

  # Disable the pager and write directly to stdout (useful for CI or log capture)
  $(basename "$0") --no-pager
  $(basename "$0") --no-pager --dry-run

  # Dry-run: see what would change without touching anything
  $(basename "$0") --dry-run
  $(basename "$0") --build-efi --embed --dry-run
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -B|--build-efi)
            BUILD=1
            shift
            ;;
        --embed)
            EMBED_EXPLICIT=1
            # Consume next token only if it is a non-flag, non-empty value.
            # Bare --embed (no argument) → keep default path; "none" → no embed.
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
                EMBED="$2"; shift 2
            else
                shift 1
            fi
            ;;
        --debug)
            # Argument is optional — defaults to "iscsi:3,tcp" if omitted.
            # A value is consumed only if the next token exists and is not another flag.
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
                DEBUG_ARGS="$2"; shift 2
            else
                DEBUG_ARGS="iscsi:3,tcp"; shift 1
            fi
            ;;
        --output)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --output requires a filename argument." >&2; exit 1
            fi
            OUTPUT_NAME="$2"; OUTPUT_EXPLICIT=1; shift 2
            ;;
        --ignore-files)
            shift
            # Consume all remaining non-flag tokens as file/directory paths.
            while [[ $# -gt 0 && "${1:-}" != -* ]]; do
                IGNORE_FILES_RAW+=("$1"); shift
            done
            if [[ ${#IGNORE_FILES_RAW[@]} -eq 0 ]]; then
                echo "ERROR: --ignore-files requires at least one file or directory path." >&2
                exit 1
            fi
            ;;
        --overwrite-credentials)
            OVERWRITE_CREDS=1
            shift
            ;;
        --no-pager)
            USE_PAGER=0
            shift
            ;;
        --_with-ansi)
            # Internal flag injected by the --pager re-exec so the re-run
            # forces ANSI codes on even though stdout is a pipe to less.
            WITH_ANSI=1
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage; exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo
            usage >&2
            exit 1
            ;;
    esac
done

# ── Derived settings (post-arg-parse) ────────────────────────────────────────

# Guard: --embed, --output, and --debug only have meaning when --build-efi is
# also passed. Catch the case where a user configures the build but forgets
# --build-efi — without this check the flags are silently ignored.
if [[ "$BUILD" -eq 0 ]]; then
    _build_only_flags=()
    [[ "$EMBED_EXPLICIT"  -eq 1 ]] && _build_only_flags+=("--embed")
    [[ "$OUTPUT_EXPLICIT" -eq 1 ]] && _build_only_flags+=("--output")
    [[ -n "$DEBUG_ARGS"        ]] && _build_only_flags+=("--debug")
    if [[ ${#_build_only_flags[@]} -gt 0 ]]; then
        echo "ERROR: The following flag(s) require --build-efi:" >&2
        for _f in "${_build_only_flags[@]}"; do
            echo "         $_f" >&2
        done
        echo "       Add --build-efi to build and deploy the .efi, or remove the" >&2
        echo "       above flag(s) to deploy boot scripts only." >&2
        exit 1
    fi
    unset _build_only_flags _f
fi

# Steps 1, 2, 3 always run; steps 4 and 5 only run with --build.
if [[ "$BUILD" -eq 1 ]]; then
    TOTAL_STEPS=5
else
    TOTAL_STEPS=3
fi

# ANSI bold/reset — on when stdout is a terminal, or when the hidden
# --_with-ansi flag was injected by the --pager re-exec (stdout is then a
# pipe to less -R, which renders the escape sequences correctly).
if [[ -t 1 || "$WITH_ANSI" -eq 1 ]]; then
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    BOLD=''
    RESET=''
fi

# ── Pager activation ──────────────────────────────────────────────────────────
# Re-exec the script without --pager and pipe its stdout through less -S -R.
# This makes less the right-hand process of a normal shell pipeline, giving it
# full terminal ownership: keyboard input (arrow keys, q, etc.) works correctly
# and the terminal is properly restored on exit.
# Only stdout is piped — stderr stays on the terminal so errors are immediately
# visible without having to exit the pager.
# --_with-ansi is injected so the re-exec forces ANSI codes on despite stdout
# being a pipe (where -t 1 would otherwise be false).
if [[ "$USE_PAGER" -eq 1 && "$WITH_ANSI" -eq 0 ]]; then
    # WITH_ANSI=1 means we are already inside the re-exec'd run piped to less;
    # skip this block entirely to avoid a spurious "not a terminal" warning.
    if ! command -v less &>/dev/null; then
        echo "WARNING: 'less' not found — falling back to plain stdout output." >&2
        USE_PAGER=0
    elif [[ ! -t 1 ]]; then
        USE_PAGER=0  # stdout is a pipe/redirect; skip pager silently
    else
        _pager_args=()
        for _a in "${ORIGINAL_ARGS[@]}"; do
            [[ "$_a" == "--pager" ]] || _pager_args+=("$_a")
        done
        # bash builds the pipeline first: a child is forked for the left side,
        # exec replaces that child with the re-run of this script, and less runs
        # on the right. The current (parent) process waits for both to finish.
        # exit $? immediately follows so the parent does not fall through and
        # execute the rest of this script a second time on the same terminal.
        exec bash "$0" "${_pager_args[@]}" --_with-ansi | less -S -R
        exit $?
    fi
fi
unset _pager_args _a

# Path column width for the Step 2,3 table (chars). Sized to fit the longest
# source path (bootScripts/winSys32-Scripts/setupDefault/iscsi-connect.cmd = 59).
PATH_COL=62

# ── Separator widths ──────────────────────────────────────────────────────────
# Two widths are used: narrow (no hashes visible) and wide (sha256 rows present).
#   Narrow: columns  ACTION(9) + gap(2) + PATHS(PATH_COL) + gap(2) + "SHASUM (HASH)"(13)
#   Wide:   same but rightmost column = sha256 output (always exactly 64 hex chars)
# SECTION_SEP / TABLE_DASH are initialised here to the narrow width so that
# prompt_credentials() (called before the pre-scan) gets consistent borders.
# The pre-scan after credential load upgrades them to wide if needed.
SHA256_LEN=64
SHASUM_HDR_LEN=13                                              # "SHASUM (HASH)"
DASH_COUNT=$(( 9 + 2 + PATH_COL + 2 + SHASUM_HDR_LEN ))       # 88 initially
TOTAL_WIDTH=$(( 2 + DASH_COUNT ))                              # 90 initially
SECTION_SEP="$(printf '═%.0s' $(seq 1 $TOTAL_WIDTH))"
TABLE_DASH="$(printf '─%.0s' $(seq 1 $DASH_COUNT))"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
# Always remove populated temp credential files on exit (normal or error).
cleanup() {
    rm -f "${CRED_TMPS[@]}"
}
trap cleanup EXIT

# ── Platform detection ────────────────────────────────────────────────────────
# sha256 — Linux uses sha256sum; macOS ships shasum (part of Digest::SHA).
if command -v sha256sum &>/dev/null; then
    sha_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum &>/dev/null; then
    sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    echo "ERROR: Neither sha256sum nor shasum found. Cannot compare checksums." >&2
    exit 1
fi

# CPU count — Linux uses nproc (reserve 1 core), macOS uses sysctl hw.logicalcpu
# (reserve 2 cores). One or two threads are left free so the build doesn't
# starve the rest of the system. JOBS_FORMULA records the derivation so it can
# be shown alongside the make command in console output.
if command -v nproc &>/dev/null; then
    _jobs_raw=$(nproc)
    JOBS=$(( _jobs_raw - 1 ))
    (( JOBS < 1 )) && JOBS=1
    JOBS_FORMULA="nproc($_jobs_raw) - 1 = $JOBS"
elif command -v sysctl &>/dev/null; then
    _jobs_raw=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
    JOBS=$(( _jobs_raw - 2 ))
    (( JOBS < 1 )) && JOBS=1
    JOBS_FORMULA="sysctl hw.logicalcpu($_jobs_raw) - 2 = $JOBS"
else
    JOBS=2
    JOBS_FORMULA="default = $JOBS"
fi
unset _jobs_raw

# ── Preflight checks ──────────────────────────────────────────────────────────
preflight_ok=1

if ! command -v unix2dos &>/dev/null; then
    echo "ERROR: unix2dos not found." >&2
    echo "       Ubuntu: sudo apt install dos2unix" >&2
    echo "       macOS:  brew install dos2unix" >&2
    preflight_ok=0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: Source directory not found: $SRC_DIR" >&2
    preflight_ok=0
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "ERROR: Output directory not accessible: $OUTPUT_DIR" >&2
    echo "       Is the web hosting server share mounted?" >&2
    preflight_ok=0
fi

if [[ "$BUILD" -eq 1 ]] && ! command -v make &>/dev/null; then
    echo "ERROR: make not found. Install build-essential (Ubuntu) or Xcode tools (macOS)." >&2
    preflight_ok=0
fi

[[ "$preflight_ok" -eq 0 ]] && exit 1

# ── Destination path resolver ─────────────────────────────────────────────────
# Translates a source path under $SRC_DIR to its output destination path.
#
# Mapping rules:
#   src/bootScripts/<file>                  → $OUTPUT_DIR/<file>
#   src/bootScripts/winSys32-Scripts/<path> → $OUTPUT_DIR/System32-Scripts/<path>
dest_for() {
    local rel="${1#$SRC_DIR/}"
    if [[ "$rel" == winSys32-Scripts/* ]]; then
        echo "$OUTPUT_DIR/System32-Scripts/${rel#winSys32-Scripts/}"
    else
        echo "$OUTPUT_DIR/$rel"
    fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Collapse . and .. components in an absolute path without touching the
# filesystem. This is the fallback for path_finder when the directory does
# not yet exist (e.g. a first-time build output dir). Pure string processing —
# no realpath/readlink required, works on bash 3.2+.
_normalize_abs_path() {
    local stack=() part
    # Strip the leading / then append a trailing / so read -d '/' captures
    # every component including the last one.
    while IFS= read -r -d '/' part; do
        case "$part" in
            ""|".")  ;;                          # skip empty segments and .
            "..")    [[ ${#stack[@]} -gt 0 ]] \
                         && stack=("${stack[@]:0:${#stack[@]}-1}") ;;
            *)       stack+=("$part") ;;
        esac
    done <<< "${1#/}/"
    local IFS='/'
    [[ ${#stack[@]} -eq 0 ]] && printf '/\n' || printf '/%s\n' "${stack[*]}"
}

# Resolves a user-supplied path to an absolute, normalized path.
# Handles ~ expansion and relative paths anchored to CALLER_CWD.
# Primary resolution: cd into the directory component so that symlinks and
# ../ traversal are resolved by the kernel (most accurate).
# Fallback (directory does not yet exist): _normalize_abs_path collapses
# . and .. purely via string manipulation, so the result is always clean —
# no .. components ever reach the caller.
# Strips any trailing slash before resolving. Never returns non-zero.
path_finder() {
    local p="${1%/}"                         # strip trailing slash
    p="${p/#\~/$HOME}"                       # expand leading ~
    [[ "$p" != /* ]] && p="$CALLER_CWD/$p"  # anchor relative paths to caller CWD
    local abs_dir
    abs_dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd)"
    if [[ -n "$abs_dir" ]]; then
        printf '%s/%s\n' "$abs_dir" "$(basename "$p")"
    else
        # Directory doesn't exist — normalize without filesystem access
        _normalize_abs_path "$p"
    fi
}

# Escape characters special in a sed replacement string (delimiter |, &, \).
sed_escape() {
    printf '%s' "$1" | sed 's/[\\|&]/\\&/g'
}

# Write a single KEY='value' line to credential.temp.env.
# Single quotes wrap the value; any ' inside is escaped as '\''
cred_line() {
    local key="$1" val="$2"
    val="${val//\'/\'\\\'\'}"
    printf "%s='%s'\n" "$key" "$val"
}

# Returns 0 if $1 is a credential source file (handled via temp copy).
is_cred_src() {
    local f="$1" s
    for s in "${CRED_SRCS[@]}"; do
        [[ "$f" == "$s" ]] && return 0
    done
    return 1
}

# Create a populated temp copy of a credential source file.
# All %%TOKEN%% placeholders are substituted with values from credential.temp.env.
make_cred_tmp() {
    local src="$1" tmp="$2"
    case "$src" in
        "$CRED_SRC_IPXE")
            sed \
                -e "s|%%ISCSI_USER%%|$(sed_escape "$ISCSI_USER")|g" \
                -e "s|%%ISCSI_PASS%%|$(sed_escape "$ISCSI_PASS")|g" \
                -e "s|%%IPXE_CHAP_USERNAME%%|$(sed_escape "$IPXE_CHAP_USERNAME")|g" \
                -e "s|%%ISCSI_CHAP_SECRET%%|$(sed_escape "$ISCSI_CHAP_SECRET")|g" \
                "$src" > "$tmp"
            ;;
        "$CRED_SRC_CMD")
            sed \
                -e "s|%%ISCSI_PORTAL%%|$(sed_escape "$ISCSI_PORTAL")|g" \
                -e "s|%%ISCSI_PORT%%|$(sed_escape "$ISCSI_PORT")|g" \
                -e "s|%%ISCSI_IQN%%|$(sed_escape "$ISCSI_IQN")|g" \
                -e "s|%%ISCSI_USER%%|$(sed_escape "$ISCSI_USER")|g" \
                -e "s|%%ISCSI_PASS%%|$(sed_escape "$ISCSI_PASS")|g" \
                -e "s|%%ISCSI_CHAP_SECRET%%|$(sed_escape "$ISCSI_CHAP_SECRET")|g" \
                -e "s|%%INSTALL_PORTAL%%|$(sed_escape "$INSTALL_PORTAL")|g" \
                -e "s|%%INSTALL_PORT%%|$(sed_escape "$INSTALL_PORT")|g" \
                -e "s|%%INSTALL_IQN%%|$(sed_escape "$INSTALL_IQN")|g" \
                -e "s|%%INSTALL_USER%%|$(sed_escape "$INSTALL_USER")|g" \
                -e "s|%%INSTALL_PASS%%|$(sed_escape "$INSTALL_PASS")|g" \
                -e "s|%%INSTALL_CHAP_SECRET%%|$(sed_escape "$INSTALL_CHAP_SECRET")|g" \
                "$src" > "$tmp"
            ;;
        "$CRED_SRC_INSTALL"|"$CRED_SRC_INSTALL_MANUAL")
            sed \
                -e "s|%%ISCSI_IQN%%|$(sed_escape "$ISCSI_IQN")|g" \
                -e "s|%%INITIATOR_SYSNAME%%|$(sed_escape "$INITIATOR_SYSNAME")|g" \
                "$src" > "$tmp"
            ;;
        *)
            # direct.ipxe and boot2.ipxe — target IQN only
            sed \
                -e "s|%%ISCSI_IQN%%|$(sed_escape "$ISCSI_IQN")|g" \
                "$src" > "$tmp"
            ;;
    esac
}

# Copy (or simulate copying) a single file to its deploy destination.
# In dry-run mode the copy is skipped; the row is still printed and the
# file label is appended to DRY_NEW_FILES / DRY_UPDATE_FILES for the
# analysis section. Increments n_new, n_update, or n_err as appropriate.
deploy_file() {
    local file="$1" dst="$2" action="$3" label="$4" dst_rel="$5" hash="$6"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf "  %-9s  %-${PATH_COL}s  %s\n" "$action" "$label" "$hash"
        printf "               └──▶ \$OUTPUT_DIR/%s\n" "$dst_rel"
        if [[ "$action" == "UPDATE" ]]; then
            n_update=$((n_update+1))
            DRY_UPDATE_FILES+=("$label")
        else
            n_new=$((n_new+1))
            DRY_NEW_FILES+=("$label")
        fi
    elif cp "$file" "$dst" 2>/dev/null; then
        printf "  %-9s  %-${PATH_COL}s  %s\n" "$action" "$label" "$hash"
        printf "               └──▶ \$OUTPUT_DIR/%s\n" "$dst_rel"
        if [[ "$action" == "UPDATE" ]]; then n_update=$((n_update+1)); else n_new=$((n_new+1)); fi
    else
        printf "  %-9s  %s  (copy failed)\n" "ERROR" "$label" >&2
        n_err=$((n_err+1))
    fi
}

# Returns 0 if the given absolute path should be skipped during deploy.
# Checks --ignore-files entries first (exact path or directory prefix), then
# .deployignore patterns. On return, _IGNORE_REASON is set to one of:
#   "path:<matched_ignore_path>"     — matched via --ignore-files
#   "pattern:<matched_pattern>"      — matched via .deployignore
# Pattern matching notes:
#   Patterns with no /  → matched against the file basename only
#   Patterns with /     → matched as a path suffix against the $PROJECT_ROOT-
#                         relative path (bash [[ ]] where * matches any chars)
#   Leading /           → anchored to $PROJECT_ROOT (match from the start)
#   ** is normalized to * (equivalent in bash [[ ]] pattern matching)
is_ignored() {
    local abs_path="$1"
    local rel_path="${abs_path#$PROJECT_ROOT/}"
    local base_name
    base_name="$(basename "$abs_path")"
    _IGNORE_REASON=""

    # ── --ignore-files: exact file or directory prefix ────────────────────────
    local ip
    for ip in ${IGNORE_PATHS[@]+"${IGNORE_PATHS[@]}"}; do
        if [[ "$abs_path" == "$ip" || "$abs_path" == "$ip/"* ]]; then
            _IGNORE_REASON="path:$ip"
            return 0
        fi
    done

    # ── .deployignore patterns ────────────────────────────────────────────────
    local pat expanded stripped
    for pat in ${IGNORE_PATTERNS[@]+"${IGNORE_PATTERNS[@]}"}; do
        expanded="${pat//\*\*/*}"   # ** and * are equivalent in bash [[ ]] matching
        if [[ "$expanded" == /* ]]; then
            stripped="${expanded#/}"
            # shellcheck disable=SC2254  # glob on right side of == is intentional
            [[ "$rel_path" == $stripped ]] && { _IGNORE_REASON="pattern:$pat"; return 0; }
        elif [[ "$expanded" != */* ]]; then
            # No / in pattern — match basename only
            # shellcheck disable=SC2254
            [[ "$base_name" == $expanded ]] && { _IGNORE_REASON="pattern:$pat"; return 0; }
        else
            # Contains / but no leading / — match as a path suffix anywhere in the tree.
            # Four cases: exact, suffix (*/pat), prefix (pat/*), interior (*/pat/*)
            # shellcheck disable=SC2254
            [[ "$rel_path" == $expanded      ]] && { _IGNORE_REASON="pattern:$pat"; return 0; }
            # shellcheck disable=SC2254
            [[ "$rel_path" == */$expanded    ]] && { _IGNORE_REASON="pattern:$pat"; return 0; }
            # shellcheck disable=SC2254
            [[ "$rel_path" == $expanded/*    ]] && { _IGNORE_REASON="pattern:$pat"; return 0; }
            # shellcheck disable=SC2254
            [[ "$rel_path" == */$expanded/*  ]] && { _IGNORE_REASON="pattern:$pat"; return 0; }
        fi
    done

    return 1
}

# ── Load .deployignore and resolve --ignore-files paths ───────────────────────
DEPLOYIGNORE_FILE="$SCRIPT_DIR/.deployignore"
IGNORE_PATTERNS=()
if [[ -f "$DEPLOYIGNORE_FILE" ]]; then
    while IFS= read -r _di_line || [[ -n "$_di_line" ]]; do
        # Trim leading and trailing whitespace
        _di_line="${_di_line#"${_di_line%%[![:space:]]*}"}"
        _di_line="${_di_line%"${_di_line##*[![:space:]]}"}"
        # Skip blank lines and comment lines (lines starting with #)
        [[ -z "$_di_line" || "$_di_line" == \#* ]] && continue
        IGNORE_PATTERNS+=("$_di_line")
    done < "$DEPLOYIGNORE_FILE"
    unset _di_line
fi

# Resolve --ignore-files raw paths to absolute paths via path_finder.
IGNORE_PATHS=()
for _raw_path in ${IGNORE_FILES_RAW[@]+"${IGNORE_FILES_RAW[@]}"}; do
    IGNORE_PATHS+=("$(path_finder "$_raw_path")")
done
unset _raw_path

# ── Credential prompting ──────────────────────────────────────────────────────
prompt_credentials() {
    echo
    echo "$SECTION_SEP"
    echo " ${BOLD}Credentials Setup — iSCSI Connection Parameters${RESET}"
    echo "$SECTION_SEP"
    echo
    echo "  Values are saved to: $CRED_ENV"
    echo "  This file is gitignored and never committed."
    echo

    # ── Initiator IQN sysname ─────────────────────────────────────────────────
    echo "  ${BOLD}── Initiator IQN sysname ───────────────────────────────────────${RESET}"
    echo "     Appended to form the iPXE initiator IQN:"
    echo "     iqn.2010-04.org.ipxe:{mac}-{sysname}"
    echo "     Use lowercase alphanumerics and hyphens (max 185 chars)."
    echo
    read -r -p "  Sysname (e.g. lvrgamingpc):                            " _sysname_raw
    INITIATOR_SYSNAME="$(printf '%s' "$_sysname_raw" | tr '[:upper:]' '[:lower:]')"
    unset _sysname_raw
    echo

    # ── Boot LUN (Windows OS disk) ────────────────────────────────────────────
    echo "  ${BOLD}── Windows boot LUN ────────────────────────────────────────────${RESET}"
    echo "     The iSCSI disk Windows boots from and is installed to."
    echo
    read -r -p    "  Target IP/hostname:                                    " ISCSI_PORTAL
    read -r -p    "  Target port (default 3260):                            " ISCSI_PORT
    ISCSI_PORT="${ISCSI_PORT:-3260}"
    read -r -p    "  Target IQN:                                            " ISCSI_IQN
    read -r -p    "  CHAP username (initiator → target):                    " ISCSI_USER
    read -r -s -p "  CHAP password:                                         " ISCSI_PASS; echo
    read -r -p    "  Mutual CHAP username (name the target calls itself):    " IPXE_CHAP_USERNAME
    read -r -s -p "  Mutual CHAP secret (target authenticates back):        " ISCSI_CHAP_SECRET; echo
    echo

    # ── Installer LUN (Windows ISO source for DISM) ───────────────────────────
    echo "  ${BOLD}── Windows installer LUN (DISM path) ───────────────────────────${RESET}"
    echo "     The read-only LUN holding the extracted Windows 11 ISO."
    echo
    read -r -p "  Is this LUN on a different iSCSI server or port than the boot LUN? [y/N]: " _diff_server
    case "$_diff_server" in
        [yY]|[yY][eE][sS])
            read -r -p "  Installer LUN target IP/hostname:         " INSTALL_PORTAL
            read -r -p "  Installer LUN port (default 3260):        " INSTALL_PORT
            INSTALL_PORT="${INSTALL_PORT:-3260}"
            ;;
        *)
            INSTALL_PORTAL=""
            INSTALL_PORT=""
            ;;
    esac
    echo
    read -r -p    "  Installer LUN target IQN:                              " INSTALL_IQN
    read -r -p    "  Installer LUN CHAP username:                           " INSTALL_USER
    read -r -s -p "  Installer LUN CHAP password:                           " INSTALL_PASS; echo
    read -r -s -p "  Installer LUN Mutual CHAP secret:                      " INSTALL_CHAP_SECRET; echo
    echo

    # Write credential.temp.env
    {
        cred_line INITIATOR_SYSNAME     "$INITIATOR_SYSNAME"
        cred_line ISCSI_PORTAL          "$ISCSI_PORTAL"
        cred_line ISCSI_PORT            "$ISCSI_PORT"
        cred_line ISCSI_IQN             "$ISCSI_IQN"
        cred_line ISCSI_USER            "$ISCSI_USER"
        cred_line ISCSI_PASS            "$ISCSI_PASS"
        cred_line ISCSI_CHAP_SECRET     "$ISCSI_CHAP_SECRET"
        cred_line IPXE_CHAP_USERNAME    "$IPXE_CHAP_USERNAME"
        cred_line INSTALL_PORTAL        "$INSTALL_PORTAL"
        cred_line INSTALL_PORT          "$INSTALL_PORT"
        cred_line INSTALL_IQN           "$INSTALL_IQN"
        cred_line INSTALL_USER          "$INSTALL_USER"
        cred_line INSTALL_PASS          "$INSTALL_PASS"
        cred_line INSTALL_CHAP_SECRET   "$INSTALL_CHAP_SECRET"
    } > "$CRED_ENV"
    chmod 600 "$CRED_ENV"

    echo "  Credentials saved."
    echo
}

# ── Credential check / load ───────────────────────────────────────────────────
if [[ ! -f "$CRED_ENV" || "$OVERWRITE_CREDS" -eq 1 ]]; then
    prompt_credentials
fi

# shellcheck source=/dev/null
. "$CRED_ENV"

# Validate all required keys are populated (INSTALL_PORTAL/PORT are optional)
_cred_missing=0
for _k in INITIATOR_SYSNAME \
           ISCSI_PORTAL ISCSI_PORT ISCSI_IQN ISCSI_USER ISCSI_PASS \
           ISCSI_CHAP_SECRET IPXE_CHAP_USERNAME \
           INSTALL_IQN INSTALL_USER INSTALL_PASS INSTALL_CHAP_SECRET; do
    if [[ -z "${!_k:-}" ]]; then
        echo "ERROR: '$_k' is missing from $CRED_ENV" >&2
        _cred_missing=1
    fi
done
if [[ "$_cred_missing" -eq 1 ]]; then
    echo "       Re-run with --overwrite-credentials to re-enter all values." >&2
    exit 1
fi
unset _k _cred_missing

# ── Pre-scan: determine if any file will produce a SHASUM row ─────────────────
# A NEW or UPDATE row includes a sha256 hash (64 chars), making the row wider
# than SKIP/IGNORE rows. If at least one such row exists, the section separators
# are widened to match. We break at the first changed file to minimise SHA work.
_prescan_found=0
while IFS= read -r -d '' _psf; do
    is_cred_src "$_psf" && continue
    is_ignored "$_psf" && continue
    _psd="$(dest_for "$_psf")"
    if [[ ! -f "$_psd" ]] || [[ "$(sha_of "$_psf")" != "$(sha_of "$_psd")" ]]; then
        _prescan_found=1; break
    fi
done < <(find "$SRC_DIR" \( -name "*.ipxe" -o -name "*.cmd" -o -name "*.ini" \) -print0)

if [[ "$_prescan_found" -eq 0 ]]; then
    for _psi in "${!CRED_SRCS[@]}"; do
        _pssrc="${CRED_SRCS[$_psi]}"
        _pstmp="${CRED_TMPS[$_psi]}"
        is_ignored "$_pssrc" && continue
        make_cred_tmp "$_pssrc" "$_pstmp"
        _psd="$(dest_for "$_pssrc")"
        if [[ ! -f "$_psd" ]] || [[ "$(sha_of "$_pstmp")" != "$(sha_of "$_psd")" ]]; then
            _prescan_found=1; break
        fi
    done
fi

if [[ "$_prescan_found" -eq 1 ]]; then
    DASH_COUNT=$(( 9 + 2 + PATH_COL + 2 + SHA256_LEN ))   # wide: 139 with PATH_COL=62
    TOTAL_WIDTH=$(( 2 + DASH_COUNT ))                       # wide: 141 with PATH_COL=62
    SECTION_SEP="$(printf '═%.0s' $(seq 1 $TOTAL_WIDTH))"
    TABLE_DASH="$(printf '─%.0s' $(seq 1 $DASH_COUNT))"
fi
unset _prescan_found _psf _psd _psi _pssrc _pstmp

# ─────────────────────────────────────────────────────────────────────────────
echo "$SECTION_SEP"
echo " ${BOLD}Step 1 of $TOTAL_STEPS  unix2dos — normalize line endings${RESET}"
echo "$SECTION_SEP"

while IFS= read -r -d '' f; do
    _s1_label="${f#$PROJECT_ROOT/}"
    if is_ignored "$f"; then
        printf "  %-6s  %s\n" "IGNORE" "$_s1_label"
    elif [[ "$DRY_RUN" -eq 1 ]]; then
        printf "  %-6s  %s\n" "SKIP" "$_s1_label  (dry run)"
    elif unix2dos "$f" 2>/dev/null; then
        printf "  %-6s  %s\n" "OK" "$_s1_label"
    else
        printf "  %-6s  %s\n" "WARN" "Could not convert: $_s1_label" >&2
    fi
done < <(find "$SRC_DIR" \( -name "*.ipxe" -o -name "*.cmd" -o -name "*.ini" \) -print0)
unset _s1_label

echo

# ─────────────────────────────────────────────────────────────────────────────
echo "$SECTION_SEP"
echo " ${BOLD}Step 2,3 of $TOTAL_STEPS  Check and deploy scripts → $OUTPUT_DIR${RESET}"
echo "$SECTION_SEP"
echo "  \$OUTPUT_DIR   = $OUTPUT_DIR"
echo "  \$IPXE_SRC_DIR = $IPXE_SRC_DIR"
echo

# Column headers
printf "  ${BOLD}%-9s${RESET}  ${BOLD}%-${PATH_COL}s${RESET}  ${BOLD}%s${RESET}\n" "ACTION" "PATHS" "SHASUM (HASH)"
echo "  $TABLE_DASH"
[[ "$DRY_RUN" -eq 1 ]] && echo "  [DRY RUN — files analysed but not copied]"

n_new=0; n_update=0; n_skip=0; n_err=0; n_ignored=0

# ── Non-credential files ──────────────────────────────────────────────────────
while IFS= read -r -d '' src; do
    # Credential source files are handled separately below
    if is_cred_src "$src"; then
        continue
    fi

    # Check .deployignore and --ignore-files
    if is_ignored "$src"; then
        _ig_label="${src#$IPXE_SRC_DIR/}"
        printf "  %-9s  %s\n" "IGNORE" "$_ig_label"
        n_ignored=$((n_ignored+1))
        case "$_IGNORE_REASON" in
            path:*)    IGNORED_BY_PATH+=("${_IGNORE_REASON#path:}|||$_ig_label") ;;
            pattern:*) IGNORED_BY_PATTERN+=("${_IGNORE_REASON#pattern:}|||$_ig_label") ;;
        esac
        unset _ig_label
        continue
    fi

    dst="$(dest_for "$src")"
    dst_dir="$(dirname "$dst")"
    src_label="${src#$IPXE_SRC_DIR/}"
    dst_rel="${dst#$OUTPUT_DIR/}"

    if [[ ! -d "$dst_dir" ]]; then
        if ! mkdir -p "$dst_dir" 2>/dev/null; then
            printf "  %-9s  %s  (cannot create %s)\n" "ERROR" "$src_label" "$dst_dir" >&2
            n_err=$((n_err+1))
            continue
        fi
    fi

    if [[ -f "$dst" ]]; then
        src_hash="$(sha_of "$src")"
        dst_hash="$(sha_of "$dst")"
        if [[ "$src_hash" == "$dst_hash" ]]; then
            printf "  %-9s  %s\n" "SKIP" "$src_label"
            n_skip=$((n_skip+1))
            continue
        fi
        action="UPDATE"
    else
        action="NEW"
        src_hash="$(sha_of "$src")"
    fi

    deploy_file "$src" "$dst" "$action" "$src_label" "$dst_rel" "$src_hash"
done < <(find "$SRC_DIR" \( -name "*.ipxe" -o -name "*.cmd" -o -name "*.ini" \) -print0)

# ── Credential files (substituted from credential.temp.env) ──────────────────
# Temp copies are created with real values substituted in, used for the sha
# comparison and copy, then removed by the EXIT trap. The src/bootScripts
# paths are shown in the output — the temp files are invisible to the user.
for i in "${!CRED_SRCS[@]}"; do
    src="${CRED_SRCS[$i]}"
    tmp="${CRED_TMPS[$i]}"

    # Check .deployignore and --ignore-files
    if is_ignored "$src"; then
        _ig_label="${src#$IPXE_SRC_DIR/}"
        printf "  %-9s  %s\n" "IGNORE" "$_ig_label"
        n_ignored=$((n_ignored+1))
        case "$_IGNORE_REASON" in
            path:*)    IGNORED_BY_PATH+=("${_IGNORE_REASON#path:}|||$_ig_label") ;;
            pattern:*) IGNORED_BY_PATTERN+=("${_IGNORE_REASON#pattern:}|||$_ig_label") ;;
        esac
        unset _ig_label
        continue
    fi

    make_cred_tmp "$src" "$tmp"

    dst="$(dest_for "$src")"
    dst_dir="$(dirname "$dst")"
    src_label="${src#$IPXE_SRC_DIR/}"
    dst_rel="${dst#$OUTPUT_DIR/}"

    if [[ ! -d "$dst_dir" ]]; then
        if ! mkdir -p "$dst_dir" 2>/dev/null; then
            printf "  %-9s  %s  (cannot create %s)\n" "ERROR" "$src_label" "$dst_dir" >&2
            n_err=$((n_err+1))
            continue
        fi
    fi

    if [[ -f "$dst" ]]; then
        src_hash="$(sha_of "$tmp")"
        dst_hash="$(sha_of "$dst")"
        if [[ "$src_hash" == "$dst_hash" ]]; then
            printf "  %-9s  %s\n" "SKIP" "$src_label"
            n_skip=$((n_skip+1))
            continue
        fi
        action="UPDATE"
    else
        action="NEW"
        src_hash="$(sha_of "$tmp")"
    fi

    deploy_file "$tmp" "$dst" "$action" "$src_label" "$dst_rel" "$src_hash"
done

echo
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  would-be-new=$n_new  would-be-updated=$n_update  ignored=$n_ignored  skipped=$n_skip  errors=$n_err  (dry run — no files copied)"
else
    echo "  new=$n_new  updated=$n_update  ignored=$n_ignored  skipped=$n_skip  errors=$n_err"
fi
echo

# ─────────────────────────────────────────────────────────────────────────────
if [[ "$BUILD" -eq 1 ]]; then
    echo "$SECTION_SEP"
    echo " ${BOLD}Step 4 of $TOTAL_STEPS  Build iPXE .efi${RESET}"
    echo "$SECTION_SEP"

    # Determine whether to embed a boot script in this build.
    # Embed only when --embed was explicitly passed AND the value is not "none".
    USE_EMBED=0
    if [[ "$EMBED_EXPLICIT" -eq 1 && "$EMBED" != "none" ]]; then
        USE_EMBED=1

        echo "  Verifying EMBED script ..."
        printf "  %-12s : %s\n" "Supplied" "$EMBED"

        DRY_EMBED_RAW="$EMBED"
        _embed_resolved="$(path_finder "$EMBED")"
        [[ "$_embed_resolved" != "$EMBED" ]] && printf "  %-12s : %s\n" "Resolved" "$_embed_resolved"
        EMBED="$_embed_resolved"
        DRY_EMBED_RESOLVED="$EMBED"
        unset _embed_resolved

        if [[ -d "$EMBED" ]]; then
            echo "ERROR: --embed expects a file path, not a directory: $EMBED" >&2
            exit 1
        fi
        if [[ ! -f "$EMBED" ]]; then
            echo "ERROR: EMBED script not found: $EMBED" >&2
            exit 1
        fi
        echo "  OK — file verified."
        echo
    fi

    # ── Resolve OUTPUT path → MAKE_TARGET ────────────────────────────────────
    echo "  Verifying OUTPUT path ..."
    printf "  %-12s : %s\n" "Supplied" "$OUTPUT_NAME"

    # A value is treated as a *path* when it contains '/' or starts with '~'.
    # A bare name with no separator is treated as a plain filename and the
    # default iPXE output directory (bin-x86_64-efi/) is prepended — unless
    # that name resolves to an existing directory, in which case it is treated
    # as a directory and the default filename (snponly.efi) is appended.
    if [[ "$OUTPUT_NAME" == */* || "$OUTPUT_NAME" == ~* ]]; then
        # Path mode — remember whether the user explicitly indicated a directory
        _out_trailing_slash=0
        [[ "$OUTPUT_NAME" == */ ]] && _out_trailing_slash=1

        _out_resolved="$(path_finder "$OUTPUT_NAME")"

        # Append default filename if a directory was specified
        if [[ "$_out_trailing_slash" -eq 1 || -d "$_out_resolved" ]]; then
            echo "  Directory path detected — appending default filename: snponly.efi"
            _out_resolved="$_out_resolved/snponly.efi"
        fi

        [[ "$_out_resolved" != "$OUTPUT_NAME" ]] && printf "  %-12s : %s\n" "Resolved" "$_out_resolved"

        # Make target must be a path relative to IPXE_SRC_DIR
        if [[ "$_out_resolved" != "$IPXE_SRC_DIR/"* ]]; then
            echo "ERROR: Output path must resolve to a location under the iPXE source directory." >&2
            echo "       Expected under : $IPXE_SRC_DIR/" >&2
            echo "       Got            : $_out_resolved" >&2
            exit 1
        fi
        MAKE_TARGET="${_out_resolved#$IPXE_SRC_DIR/}"
        unset _out_resolved _out_trailing_slash
    else
        # Bare name mode — check if it resolves to an existing directory
        if [[ -d "$CALLER_CWD/$OUTPUT_NAME" ]]; then
            echo "  Directory name detected — appending default filename: snponly.efi"
            _out_resolved="$(path_finder "$OUTPUT_NAME/snponly.efi")"
            [[ "$_out_resolved" != "$OUTPUT_NAME/snponly.efi" ]] && printf "  %-12s : %s\n" "Resolved" "$_out_resolved"
            if [[ "$_out_resolved" != "$IPXE_SRC_DIR/"* ]]; then
                echo "ERROR: Output path must resolve to a location under the iPXE source directory." >&2
                echo "       Expected under : $IPXE_SRC_DIR/" >&2
                echo "       Got            : $_out_resolved" >&2
                exit 1
            fi
            MAKE_TARGET="${_out_resolved#$IPXE_SRC_DIR/}"
            unset _out_resolved
        else
            # Plain filename — prepend the default iPXE output directory
            MAKE_TARGET="bin-x86_64-efi/$OUTPUT_NAME"
        fi
    fi

    # Guard: iPXE's Makefile only recognises targets matching bin, bin/%, or
    # bin-*. A target with .. components or a wrong prefix (e.g. src/bin-…)
    # will produce a cryptic "No rule to make target" error from make.
    if [[ "$MAKE_TARGET" != "bin" \
       && "$MAKE_TARGET" != bin/* \
       && "$MAKE_TARGET" != bin-* ]]; then
        echo "ERROR: Resolved make target does not match iPXE's required pattern." >&2
        echo "       iPXE's Makefile only accepts:  bin  |  bin/<name>  |  bin-<arch>/<name>" >&2
        echo "       Got : $MAKE_TARGET" >&2
        echo "       Check the path supplied to --output — it must resolve to a location" >&2
        echo "       under $IPXE_SRC_DIR/bin-*/ or $IPXE_SRC_DIR/bin/" >&2
        exit 1
    fi

    printf "  %-12s : %s\n" "Make target" "$MAKE_TARGET"
    echo "  OK"
    echo
    DRY_MAKE_TARGET_RESULT="$MAKE_TARGET"

    printf "  %-12s : %s\n" "Workdir" "$IPXE_SRC_DIR"
    printf "  %-12s : %s\n" "Target" "$MAKE_TARGET"
    if [[ "$USE_EMBED" -eq 1 ]]; then
        printf "  %-12s : %s\n" "EMBED" "$EMBED"
    else
        printf "  %-12s : %s\n" "EMBED" "(none — no boot script embedded)"
    fi
    [[ -n "$DEBUG_ARGS" ]] && printf "  %-12s : %s\n" "DEBUG" "$DEBUG_ARGS"
    printf "  %-12s : %s  (%s)\n" "Jobs" "$JOBS" "$JOBS_FORMULA"
    echo

    make_args=("$MAKE_TARGET")
    [[ "$USE_EMBED" -eq 1 ]] && make_args+=("EMBED=$EMBED")
    [[ -n "$DEBUG_ARGS" ]] && make_args+=("DEBUG=$DEBUG_ARGS")
    make_args+=("-j$JOBS")
    DRY_MAKE_CMD="make ${make_args[*]}"

    echo "  Executing:"
    echo "    cd $IPXE_SRC_DIR && \\"
    echo "    $DRY_MAKE_CMD"
    echo "    # -j$JOBS derived from: $JOBS_FORMULA"
    echo

    EFI_BUILT="$IPXE_SRC_DIR/$MAKE_TARGET"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [DRY RUN — make command not executed]"
        echo
    else
        if ! ( cd "$IPXE_SRC_DIR" && make "${make_args[@]}" ); then
            echo "ERROR: make failed. See output above." >&2
            exit 1
        fi
        if [[ ! -f "$EFI_BUILT" ]]; then
            echo "ERROR: make exited cleanly but output not found: $EFI_BUILT" >&2
            exit 1
        fi
    fi

    echo
    echo "$SECTION_SEP"
    echo " ${BOLD}Step 5 of $TOTAL_STEPS  Deploy .efi → web hosting server${RESET}"
    echo "$SECTION_SEP"

    EFI_DEST="$OUTPUT_DIR/snponly-bootScript.efi"
    printf "  %-12s : %s\n" "Source" "$EFI_BUILT"
    printf "  %-12s : %s\n" "Dest" "$EFI_DEST"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [DRY RUN — .efi not copied]"
    elif cp "$EFI_BUILT" "$EFI_DEST"; then
        echo "  OK"
    else
        echo "ERROR: Failed to copy .efi to web hosting server output directory." >&2
        exit 1
    fi
    echo
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "$SECTION_SEP"
echo " Done."
echo "$SECTION_SEP"

if [[ "$n_err" -gt 0 ]]; then
    echo "WARNING: $n_err file(s) had errors during deployment." >&2
    [[ "$DRY_RUN" -eq 0 ]] && exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "$SECTION_SEP"
    echo " ${BOLD}Dry-run analysis — no changes were made${RESET}"
    echo "$SECTION_SEP"
    echo

    # ── Invocation ────────────────────────────────────────────────────────────
    echo "  ${BOLD}Script invocation:${RESET}"
    printf "    %-28s : %s\n" "Called from" "$CALLER_CWD"
    printf "    %-28s : %s\n" "Script" "$SCRIPT_DIR/$(basename "$0")"
    echo

    # ── Options as resolved ───────────────────────────────────────────────────
    echo "  ${BOLD}Options:${RESET}"
    printf "    %-28s : %s\n" "--build-efi" \
        "$( [[ "$BUILD" -eq 1 ]] && echo "yes" || echo "no" )"

    if [[ "$EMBED_EXPLICIT" -eq 0 ]]; then
        printf "    %-28s : %s\n" "--embed" "(not passed — no boot script embedded)"
    elif [[ "$EMBED" == "none" ]]; then
        printf "    %-28s : %s\n" "--embed" "none  (explicit no-embed)"
    else
        printf "    %-28s : %s\n" "--embed" "$DRY_EMBED_RAW"
    fi

    printf "    %-28s : %s\n" "--debug" \
        "$( [[ -n "$DEBUG_ARGS" ]] && echo "\"$DEBUG_ARGS\"" || echo "(not set)" )"

    if [[ "$OUTPUT_EXPLICIT" -eq 1 ]]; then
        printf "    %-28s : %s\n" "--output" "$OUTPUT_NAME"
    else
        printf "    %-28s : %s\n" "--output" "(default: $OUTPUT_NAME)"
    fi

    printf "    %-28s : %s\n" "--overwrite-credentials" \
        "$( [[ "$OVERWRITE_CREDS" -eq 1 ]] && echo "yes" || echo "no" )"

    if [[ ${#IGNORE_FILES_RAW[@]} -gt 0 ]]; then
        printf "    %-28s : %s\n" "--ignore-files" "${IGNORE_FILES_RAW[*]}"
        for _ip in ${IGNORE_PATHS[@]+"${IGNORE_PATHS[@]}"}; do
            printf "    %-28s     resolved: %s\n" "" "$_ip"
        done
    else
        printf "    %-28s : %s\n" "--ignore-files" "(not passed)"
    fi

    if [[ -f "$DEPLOYIGNORE_FILE" ]]; then
        printf "    %-28s : %s  (%d pattern(s) loaded)\n" \
            ".deployignore" "$DEPLOYIGNORE_FILE" "${#IGNORE_PATTERNS[@]}"
        for _dp in ${IGNORE_PATTERNS[@]+"${IGNORE_PATTERNS[@]}"}; do
            printf "    %-28s     %s\n" "" "$_dp"
        done
    else
        printf "    %-28s : %s\n" ".deployignore" "(not found — $DEPLOYIGNORE_FILE)"
    fi
    echo

    # ── Path resolution (only when --build-efi was passed) ────────────────────
    if [[ "$BUILD" -eq 1 ]]; then
        echo "  ${BOLD}Path resolution  (CALLER_CWD: $CALLER_CWD):${RESET}"

        if [[ "$USE_EMBED" -eq 1 ]]; then
            printf "    %-28s : %s\n" "EMBED supplied" "$DRY_EMBED_RAW"
            printf "    %-28s : %s" "EMBED resolved" "$DRY_EMBED_RESOLVED"
            [[ -f "$DRY_EMBED_RESOLVED" ]] && echo "  [file found ✓]" || echo "  [NOT FOUND ✗]"
        else
            printf "    %-28s : %s\n" "EMBED" "(no boot script embedded)"
        fi

        printf "    %-28s : %s\n" "OUTPUT supplied" \
            "$( [[ "$OUTPUT_EXPLICIT" -eq 1 ]] && echo "$OUTPUT_NAME" || echo "(default) $OUTPUT_NAME" )"
        printf "    %-28s : %s\n" "Make target" "$DRY_MAKE_TARGET_RESULT"
        echo
    fi

    # ── Script deployment summary ─────────────────────────────────────────────
    echo "  ${BOLD}Script deployment  (→ $OUTPUT_DIR):${RESET}"
    printf "    %-28s : %d\n" "Would be new" "$n_new"
    if [[ "${#DRY_NEW_FILES[@]}" -gt 0 ]]; then
        for _f in "${DRY_NEW_FILES[@]}"; do
            printf "                                   %s\n" "$_f"
        done
    fi
    printf "    %-28s : %d\n" "Would be updated" "$n_update"
    if [[ "${#DRY_UPDATE_FILES[@]}" -gt 0 ]]; then
        for _f in "${DRY_UPDATE_FILES[@]}"; do
            printf "                                   %s\n" "$_f"
        done
    fi
    printf "    %-28s : %d\n" "Ignored" "$n_ignored"
    printf "    %-28s : %d\n" "Unchanged (skip)" "$n_skip"
    printf "    %-28s : %d\n" "Errors" "$n_err"
    echo

    # ── Ignored files detail ──────────────────────────────────────────────────
    if [[ ${#IGNORE_PATHS[@]} -gt 0 || ${#IGNORE_PATTERNS[@]} -gt 0 ]]; then
        echo "  ${BOLD}Ignored files detail:${RESET}"

        if [[ ${#IGNORE_PATHS[@]} -gt 0 ]]; then
            echo "    From --ignore-files:"
            _any_path_match=0
            for _ip in "${IGNORE_PATHS[@]}"; do
                _any_path_match=0
                for _entry in ${IGNORED_BY_PATH[@]+"${IGNORED_BY_PATH[@]}"}; do
                    [[ "${_entry%%|||*}" == "$_ip" ]] || continue
                    printf "      IGNORE  %s\n" "${_entry##*|||}"
                    printf "              (matched: %s)\n" "$_ip"
                    _any_path_match=1
                done
                if [[ "$_any_path_match" -eq 0 ]]; then
                    printf "      (no source files matched: %s)\n" "$_ip"
                fi
            done
            echo
        fi

        if [[ ${#IGNORE_PATTERNS[@]} -gt 0 ]]; then
            echo "    From .deployignore:"
            _any_pat_match=0
            for _pat in "${IGNORE_PATTERNS[@]}"; do
                _any_pat_match=0
                for _entry in ${IGNORED_BY_PATTERN[@]+"${IGNORED_BY_PATTERN[@]}"}; do
                    [[ "${_entry%%|||*}" == "$_pat" ]] || continue
                    if [[ "$_any_pat_match" -eq 0 ]]; then
                        printf "      Pattern: %s\n" "$_pat"
                    fi
                    printf "        IGNORE  %s\n" "${_entry##*|||}"
                    _any_pat_match=1
                done
                if [[ "$_any_pat_match" -eq 0 ]]; then
                    printf "      Pattern: %s  (no source files matched)\n" "$_pat"
                fi
            done
            echo
        fi
    fi

    # ── Make command ──────────────────────────────────────────────────────────
    if [[ "$BUILD" -eq 1 ]]; then
        echo "  ${BOLD}Make command  (not executed):${RESET}"
        echo "    cd $IPXE_SRC_DIR && \\"
        echo "    $DRY_MAKE_CMD"
        echo "    # -j$JOBS derived from: $JOBS_FORMULA"
        echo
    fi
fi

exit 0
