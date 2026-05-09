#!/bin/bash
# =============================================================================
#  pdo_sqlcipher — dev environment manager
#
#  Compiles pdo_sqlcipher.so for multiple PHP versions via Docker, then builds
#  and manages a multi-PHP dev container for local testing.
#
#  Run: ./dev.sh help   for full reference
# =============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# -----------------------------------------------------------------------------
#  ANSI colours
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
DIM='\033[2m'
NC='\033[0m'

# -----------------------------------------------------------------------------
#  Output helpers
# -----------------------------------------------------------------------------
hr()     { printf "  %s\n" "─────────────────────────────────────────────"; }
banner() { echo ""; hr; printf "  PHP %s — %s\n" "$1" "$2"; hr; echo ""; }
info()   { printf "  ${GRN}→${NC}  %s\n" "$*"; }
warn()   { printf "  ${YEL}⚠${NC}  %s\n" "$*" >&2; }
err()    { printf "  ${RED}ERROR:${NC}  %s\n" "$*" >&2; }
die()    { err "$*"; exit 1; }
hint()   { printf "  ${DIM}»${NC}  %s\n" "$*"; }

# -----------------------------------------------------------------------------
#  Constants
# -----------------------------------------------------------------------------
ALL_VERSIONS=(7.4 8.0 8.1 8.2 8.3 8.4 8.5)
declare -A PHP_API_MAP=(
    [7.4]="20190902"
    [8.0]="20200930"
    [8.1]="20210902"
    [8.2]="20220829"
    [8.3]="20230831"
    [8.4]="20240924"
    [8.5]="20250925"
)
IMAGE_BASE="pdo_sqlcipher_test"
DEV_SERVICE="pdo-dev"
DEV_PORT=10000
LOG_DIR="${SCRIPT_DIR}/docker-logs"
RELEASE_DIR="${SCRIPT_DIR}/../release"

# -----------------------------------------------------------------------------
#  Dependency check — Docker + Docker Compose
# -----------------------------------------------------------------------------
check_deps() {
    local missing=0
    local id=""

    if [ -f /etc/os-release ]; then
        id=$(. /etc/os-release && echo "${ID}")
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo ""
        err "'docker' not found."
        case "${id}" in
            ubuntu|debian|linuxmint|pop)
                echo ""
                hint "Install Docker on ${id^}:"
                hint "  sudo apt install docker.io docker-compose-v2"
                hint "  sudo usermod -aG docker \$USER && newgrp docker"
                ;;
            fedora|rhel|centos|almalinux|rocky)
                echo ""
                hint "Install Docker on ${id^}:"
                hint "  sudo dnf install docker docker-compose-plugin"
                hint "  sudo systemctl enable --now docker"
                hint "  sudo usermod -aG docker \$USER"
                ;;
            arch|manjaro)
                echo ""
                hint "Install Docker on ${id^}:"
                hint "  sudo pacman -S docker docker-compose"
                hint "  sudo systemctl enable --now docker"
                hint "  sudo usermod -aG docker \$USER"
                ;;
            *)
                echo ""
                hint "See: https://docs.docker.com/engine/install/"
                ;;
        esac
        missing=1
    elif ! docker info >/dev/null 2>&1; then
        echo ""
        err "Docker daemon is not running."
        hint "sudo systemctl start docker"
        missing=1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo ""
        err "Docker Compose v2 plugin not found ('docker compose' unavailable)."
        case "${id}" in
            ubuntu|debian|linuxmint|pop)
                echo ""
                hint "Install on ${id^}:"
                hint "  sudo apt install docker-compose-v2"
                ;;
            fedora|rhel|centos|almalinux|rocky)
                echo ""
                hint "Install on ${id^}:"
                hint "  sudo dnf install docker-compose-plugin"
                ;;
            arch|manjaro)
                echo ""
                hint "Install on ${id^}:"
                hint "  sudo pacman -S docker-compose"
                ;;
            *)
                echo ""
                hint "See: https://docs.docker.com/compose/install/"
                ;;
        esac
        missing=1
    fi

    if [ "${missing}" -eq 1 ]; then
        echo ""
        exit 1
    fi
}

check_deps

# -----------------------------------------------------------------------------
#  State helpers
# -----------------------------------------------------------------------------

# compiled_versions — echoes space-separated list of versions that have a .so in compiled_tests/
compiled_versions() {
    local found=()
    for ver in "${ALL_VERSIONS[@]}"; do
        if [ -f "${SCRIPT_DIR}/compiled_tests/php${ver}/pdo_sqlcipher.so" ]; then
            found+=("${ver}")
        fi
    done
    if [ "${#found[@]}" -gt 0 ]; then
        echo "${found[*]}"
    fi
}

# image_exists — returns 0 if the dev image exists locally, 1 otherwise
image_exists() {
    local img
    img=$(docker compose config --images 2>/dev/null | head -1)
    if [ -z "${img}" ]; then
        return 1
    fi
    if docker image inspect "${img}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# container_running — returns 0 if the dev container is running, 1 otherwise
container_running() {
    if docker compose ps --status running 2>/dev/null | grep -q "${DEV_SERVICE}"; then
        return 0
    fi
    return 1
}

# validate_versions VER... — dies on any version not in ALL_VERSIONS
validate_versions() {
    for ver in "$@"; do
        local ok=0
        for v in "${ALL_VERSIONS[@]}"; do
            if [ "${ver}" = "${v}" ]; then
                ok=1
                break
            fi
        done
        if [ "${ok}" -eq 0 ]; then
            die "Unknown PHP version '${ver}'. Valid: ${ALL_VERSIONS[*]}"
        fi
    done
}

# -----------------------------------------------------------------------------
#  Usage
# -----------------------------------------------------------------------------
usage() {
    local compiled running_status compiled_display

    echo ""
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║        pdo_sqlcipher — dev environment        ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo ""
    echo "  USAGE"
    echo "    ./dev.sh <command> [options]"
    echo ""
    echo "  COMMANDS"
    echo ""
    echo "    build [ver...]"
    echo "      Compile pdo_sqlcipher.so for the given PHP version(s), then build"
    echo "      the dev Docker image.  Prompts for version selection if no args given."
    echo "      Examples:"
    echo "        ./dev.sh build              # interactive version picker"
    echo "        ./dev.sh build 8.3 8.4      # build specific versions"
    echo "        ./dev.sh build 8.5          # single version"
    echo ""
    echo "    up"
    echo "      Start the dev container in the background (port ${DEV_PORT})."
    echo "      Pre-flight: image must exist (run build first)."
    echo ""
    echo "    down"
    echo "      Stop and remove the running dev container."
    echo ""
    echo "    bash"
    echo "      Open an interactive shell in the running container."
    echo "      Pre-flight: container must be running (run up first)."
    echo ""
    echo "    run-bash"
    echo "      Start a fresh container and open an interactive shell."
    echo "      Pre-flight: image must exist (run build first)."
    echo ""
    echo "    php <version>"
    echo "      Switch the active PHP version inside the running container."
    echo "      Example:  ./dev.sh php 8.4"
    echo ""
    echo "    test [ver...]"
    echo "      Sanity-build pdo_sqlcipher.so for all or specific PHP versions"
    echo "      using the test Dockerfile.  Does NOT update release/ or the dev image."
    echo "      Examples:"
    echo "        ./dev.sh test               # all versions"
    echo "        ./dev.sh test 8.1 8.2       # specific versions"
    echo ""
    echo "    clean"
    echo "      Delete all compiled .so files, build logs, generated Dockerfiles,"
    echo "      and the pdo_sqlcipher_test:php* build images."
    echo "      The dev container and dev image are left intact."
    echo ""
    echo "    nuke"
    echo "      Everything clean does, plus: stop and remove the dev container,"
    echo "      the dev Docker image, and all project volumes and networks."
    echo "      Leaves the project as if it was never run."
    echo ""
    echo "    help"
    echo "      Show this help."
    echo ""
    hr
    echo "  STATUS"
    echo ""

    compiled=$(compiled_versions 2>/dev/null || true)
    if [ -n "${compiled}" ]; then
        compiled_display="${GRN}${compiled}${NC}"
        printf "    Compiled .so versions : ${compiled_display}\n"
    else
        printf "    Compiled .so versions : ${DIM}none — run build first${NC}\n"
    fi

    if container_running 2>/dev/null; then
        printf "    Container             : ${GRN}running${NC} → http://localhost:${DEV_PORT}\n"
    else
        printf "    Container             : ${DIM}stopped${NC}\n"
    fi

    printf "    Dev port              : %s\n" "${DEV_PORT}"
    printf "    Logs                  : %s/\n" "${LOG_DIR}"

    echo ""
}

# -----------------------------------------------------------------------------
#  docker_tee — stream docker output live and append to log file
#  Returns docker's exit code without triggering set -e.
# -----------------------------------------------------------------------------
docker_tee() {
    local log="$1"; shift
    local rc=0
    set +e
    "$@" 2>&1 | tee -a "${log}"
    rc=${PIPESTATUS[0]}
    set -e
    return "${rc}"
}

# -----------------------------------------------------------------------------
#  run_test — docker build + run for one PHP version
#  Populates dynamic-scope arrays: result[], elapsed[], skip_reason[]
# -----------------------------------------------------------------------------
run_test() {
    local ver="$1"
    local out_dir="${2:-${SCRIPT_DIR}/compiled_tests/php${ver}}"
    local image="${IMAGE_BASE}:php${ver}"
    local log="${LOG_DIR}/php${ver}.log"
    local t0 t1 rc

    : > "${log}"
    t0=$(date +%s)

    banner "${ver}" "docker build"
    rc=0
    docker_tee "${log}" docker build \
        --build-arg "PHP_VER=${ver}" \
        --build-arg "CACHEBUST=$(date +%Y%m%d)" \
        --tag "${image}" \
        --file "${SCRIPT_DIR}/Dockerfile.test" \
        "${SCRIPT_DIR}/.." || rc=$?

    if [ "${rc}" -ne 0 ]; then
        if grep -qiE "unable to locate package php${ver}" "${log}"; then
            result[$ver]="SKIP"
            skip_reason[$ver]="php${ver}-dev not available in PPA"
        else
            result[$ver]="FAIL"
            warn "Build log: ${log}"
            tail -10 "${log}" | sed 's/^/    /' >&2
        fi
        t1=$(date +%s)
        elapsed[$ver]=$(( t1 - t0 ))
        return
    fi

    mkdir -p "${out_dir}"

    banner "${ver}" "docker run — compile"
    rc=0
    docker_tee "${log}" docker run --rm \
        -v "${out_dir}:/build/release/php${ver}" \
        "${image}" || rc=$?

    t1=$(date +%s)
    elapsed[$ver]=$(( t1 - t0 ))

    if [ "${rc}" -eq 0 ]; then
        result[$ver]="PASS"
    else
        result[$ver]="FAIL"
        warn "Build log: ${log}"
        tail -10 "${log}" | sed 's/^/    /' >&2
    fi
}

# -----------------------------------------------------------------------------
#  generate_dockerfile AVAILABLE_VER...
#  Writes Dockerfile.dev.generated containing only the given PHP versions.
# -----------------------------------------------------------------------------
generate_dockerfile() {
    local -a avail=("$@")
    python3 - "${SCRIPT_DIR}/Dockerfile.dev" "${avail[@]}" << 'PYEOF'
import sys, re

src      = sys.argv[1]
available = sys.argv[2:]

api_map = {
    '7.4': '20190902', '8.0': '20200930', '8.1': '20210902',
    '8.2': '20220829', '8.3': '20230831', '8.4': '20240924', '8.5': '20250925',
}
all_vers  = ['7.4', '8.0', '8.1', '8.2', '8.3', '8.4', '8.5']
avail_set = set(available)
avail_apis = {api_map[v] for v in available if v in api_map}

with open(src) as f:
    lines = f.readlines()

out = []
i = 0
while i < len(lines):
    line = lines[i]

    # Drop COPY lines for unavailable versions
    m = re.match(r'^COPY release/php(\d+\.\d+)/', line)
    if m:
        if m.group(1) not in avail_set:
            i += 1
            continue

    # Rebuild the chmod block, keeping only available paths
    if re.match(r'^RUN chmod 644', line):
        i += 1
        chmod_paths = []
        while i < len(lines) and 'pdo_sqlcipher.so' in lines[i]:
            m2 = re.search(r'/usr/lib/php/(\d+)/pdo_sqlcipher\.so', lines[i])
            if m2 and m2.group(1) in avail_apis:
                chmod_paths.append('        /usr/lib/php/{}/pdo_sqlcipher.so'.format(m2.group(1)))
            i += 1
        if chmod_paths:
            out.append('RUN chmod 644 \\\n')
            for j, p in enumerate(chmod_paths):
                out.append(p + (' \\\n' if j < len(chmod_paths) - 1 else '\n'))
        continue

    # Replace version lists inside for-loops and VERSIONS=() arrays
    line = re.sub(r'(for ver in )' + re.escape(' '.join(all_vers)),
                  r'\g<1>' + ' '.join(available), line)
    line = re.sub(r'VERSIONS=\(' + re.escape(' '.join(all_vers)) + r'\)',
                  'VERSIONS=(' + ' '.join(available) + ')', line)

    out.append(line)
    i += 1

sys.stdout.write(''.join(out))
PYEOF
}

# -----------------------------------------------------------------------------
#  menu_build_versions — interactive numbered picker, sets SELECTED_VERSIONS
# -----------------------------------------------------------------------------
menu_build_versions() {
    echo ""
    echo "  Select PHP version(s) to build:"
    echo ""
    echo "    0)  All versions"
    local i=1
    for ver in "${ALL_VERSIONS[@]}"; do
        local so_path="${SCRIPT_DIR}/compiled_tests/php${ver}/pdo_sqlcipher.so"
        if [ -f "${so_path}" ]; then
            printf "    %d)  PHP %-5s  ${GRN}(already compiled)${NC}\n" "${i}" "${ver}"
        else
            printf "    %d)  PHP %-5s  ${DIM}(not compiled)${NC}\n" "${i}" "${ver}"
        fi
        i=$(( i + 1 ))
    done
    echo ""
    printf "  Choice(s) [0 = all, space-separated for multiple]: "
    read -r choices

    if [ -z "${choices}" ] || echo " ${choices} " | grep -qw "0"; then
        SELECTED_VERSIONS=("${ALL_VERSIONS[@]}")
        return
    fi

    SELECTED_VERSIONS=()
    for choice in ${choices}; do
        if [[ "${choice}" =~ ^[0-9]+$ ]] \
                && [ "${choice}" -ge 1 ] \
                && [ "${choice}" -le "${#ALL_VERSIONS[@]}" ]; then
            SELECTED_VERSIONS+=("${ALL_VERSIONS[$(( choice - 1 ))]}")
        else
            warn "Ignoring invalid choice: ${choice}"
        fi
    done

    if [ "${#SELECTED_VERSIONS[@]}" -eq 0 ]; then
        info "No valid selection — building all versions."
        SELECTED_VERSIONS=("${ALL_VERSIONS[@]}")
    fi
}

# -----------------------------------------------------------------------------
#  cmd_build — compile .so(s) then docker compose build
# -----------------------------------------------------------------------------
cmd_build() {
    local VERSIONS=()
    if [ "$#" -eq 0 ]; then
        menu_build_versions
        VERSIONS=("${SELECTED_VERSIONS[@]}")
    else
        validate_versions "$@"
        VERSIONS=("$@")
    fi

    declare -A result=()
    declare -A elapsed=()
    declare -A skip_reason=()

    mkdir -p "${LOG_DIR}"

    echo ""
    echo "  pdo_sqlcipher — step 1/2: compile .so for selected PHP versions"
    hr
    info "Versions : ${VERSIONS[*]}"
    info "Output   : release/php<ver>/pdo_sqlcipher.so"
    info "Logs     : ${LOG_DIR}/"
    hr

    for ver in "${VERSIONS[@]}"; do
        run_test "${ver}"
        echo ""
        case "${result[$ver]}" in
            PASS) printf "  PHP %-5s  ${GRN}✓ compiled${NC}  (%ds)\n" \
                      "${ver}" "${elapsed[$ver]}" ;;
            SKIP) printf "  PHP %-5s  ${YEL}– SKIP${NC}  (%ds)  %s\n" \
                      "${ver}" "${elapsed[$ver]}" "${skip_reason[$ver]:-}" ;;
            *)    printf "  PHP %-5s  ${RED}✗ FAIL${NC}  (%ds)  →  %s/php%s.log\n" \
                      "${ver}" "${elapsed[$ver]}" "${LOG_DIR}" "${ver}" ;;
        esac
    done

    echo ""; hr; echo ""

    # Report failures and abort if any
    local -a failed_vers=()
    for ver in "${VERSIONS[@]}"; do
        if [ "${result[$ver]}" = "FAIL" ]; then
            failed_vers+=("${ver}")
        fi
    done

    if [ "${#failed_vers[@]}" -gt 0 ]; then
        err "Compilation failed for: ${failed_vers[*]}"
        echo "" >&2
        for ver in "${failed_vers[@]}"; do
            hint "Retry with: ./dev.sh build ${ver}" >&2
        done
        echo "" >&2
        die "Fix the errors above and re-run."
    fi

    # Collect every version compiled in compiled_tests/ and stage into release/
    local -a available_so=()
    for ver in "${ALL_VERSIONS[@]}"; do
        local src="${SCRIPT_DIR}/compiled_tests/php${ver}/pdo_sqlcipher.so"
        if [ -f "${src}" ]; then
            mkdir -p "${RELEASE_DIR}/php${ver}"
            cp "${src}" "${RELEASE_DIR}/php${ver}/pdo_sqlcipher.so"
            available_so+=("${ver}")
        fi
    done

    if [ "${#available_so[@]}" -eq 0 ]; then
        die "No compiled .so files found in compiled_tests/ — run './dev.sh build' first."
    fi

    echo "  step 2/2: docker compose build"
    hr
    info "Staging versions: ${available_so[*]}"
    echo ""

    # If some versions are missing their .so, generate a trimmed Dockerfile
    local need_gen=0
    if [ "${#available_so[@]}" -lt "${#ALL_VERSIONS[@]}" ]; then
        need_gen=1
    fi

    local override_yml="${SCRIPT_DIR}/docker-compose.override.yml"
    local gen_df="${SCRIPT_DIR}/Dockerfile.dev.generated"

    if [ "${need_gen}" -eq 1 ]; then
        info "Generating Dockerfile for: ${available_so[*]}"
        echo ""
        generate_dockerfile "${available_so[@]}" > "${gen_df}"
        printf 'services:\n  pdo-dev:\n    build:\n      dockerfile: tests/Dockerfile.dev.generated\n' \
            > "${override_yml}"
    else
        # All versions present — use the canonical Dockerfile.dev; remove any stale generated override.
        rm -f "${override_yml}" "${gen_df}"
    fi

    local build_rc=0
    docker compose build || build_rc=$?

    if [ "${build_rc}" -ne 0 ]; then
        die "docker compose build failed (exit ${build_rc})."
    fi

    echo ""
    info "Dev image built."
    hint "Run './dev.sh up' to start the container."
    echo ""
}

# -----------------------------------------------------------------------------
#  cmd_test — sanity-build pdo_sqlcipher.so (does NOT update release/)
# -----------------------------------------------------------------------------
cmd_test() {
    local -a VERSIONS
    if [ "$#" -gt 0 ]; then
        validate_versions "$@"
        VERSIONS=("$@")
    else
        VERSIONS=("${ALL_VERSIONS[@]}")
    fi

    declare -A result=()
    declare -A elapsed=()
    declare -A skip_reason=()

    mkdir -p "${LOG_DIR}"

    echo ""
    echo "  pdo_sqlcipher — Docker build sanity test"
    hr
    info "Versions : ${VERSIONS[*]}"
    info "Image    : ${IMAGE_BASE}:php<ver>"
    info "Output   : ${SCRIPT_DIR}/compiled_tests/php<ver>/"
    info "Logs     : ${LOG_DIR}/"
    hr

    for ver in "${VERSIONS[@]}"; do
        run_test "${ver}"
        echo ""
        case "${result[$ver]}" in
            PASS) printf "  PHP %-5s  ${GRN}✓ PASS${NC}  (%ds)\n" \
                      "${ver}" "${elapsed[$ver]}" ;;
            SKIP) printf "  PHP %-5s  ${YEL}– SKIP${NC}  (%ds)  %s\n" \
                      "${ver}" "${elapsed[$ver]}" "${skip_reason[$ver]:-}" ;;
            *)    printf "  PHP %-5s  ${RED}✗ FAIL${NC}  (%ds)  →  %s/php%s.log\n" \
                      "${ver}" "${elapsed[$ver]}" "${LOG_DIR}" "${ver}" ;;
        esac
    done

    echo ""; hr; echo ""

    # Summary
    local fail=0
    for ver in "${VERSIONS[@]}"; do
        case "${result[$ver]}" in
            PASS) printf "  PHP %-5s  ${GRN}✓ PASS${NC}\n" "${ver}" ;;
            SKIP) printf "  PHP %-5s  ${YEL}– SKIP${NC}  %s\n" \
                      "${ver}" "${skip_reason[$ver]:-}" ;;
            *)    printf "  PHP %-5s  ${RED}✗ FAIL${NC}\n" "${ver}"
                  fail=1 ;;
        esac
    done

    echo ""
    exit "${fail}"
}

# -----------------------------------------------------------------------------
#  cmd_up — start dev container
# -----------------------------------------------------------------------------
cmd_up() {
    if ! image_exists; then
        die "Dev image not found. Run './dev.sh build' first."
    fi

    if container_running; then
        info "Container is already running → http://localhost:${DEV_PORT}"
        return
    fi

    local rc=0
    docker compose up -d || rc=$?

    if [ "${rc}" -ne 0 ]; then
        die "docker compose up failed (exit ${rc})."
    fi

    echo ""
    info "Container started → http://localhost:${DEV_PORT}"
    echo ""
    hint "Test app  →  http://localhost:${DEV_PORT}/           (db key: password)"
    hint "PHP info  →  http://localhost:${DEV_PORT}/info.php"
    echo ""
    hint "Switch PHP:  ./dev.sh php <version>"
    hint "Open shell:  ./dev.sh bash"
    hint "Stop:        ./dev.sh down"
    echo ""
}

# -----------------------------------------------------------------------------
#  cmd_down — stop dev container
# -----------------------------------------------------------------------------
cmd_down() {
    if ! container_running; then
        info "Nothing running."
        return
    fi

    docker compose down
}

# -----------------------------------------------------------------------------
#  cmd_bash — interactive shell in the running container
# -----------------------------------------------------------------------------
cmd_bash() {
    if ! container_running; then
        die "Container is not running. Run './dev.sh up' first."
    fi

    docker compose exec "${DEV_SERVICE}" bash
}

# -----------------------------------------------------------------------------
#  cmd_run_bash — start a fresh container and open a shell
# -----------------------------------------------------------------------------
cmd_run_bash() {
    if ! image_exists; then
        die "Dev image not found. Run './dev.sh build' first."
    fi

    docker compose run --rm "${DEV_SERVICE}" bash
}

# -----------------------------------------------------------------------------
#  cmd_php VER — switch active PHP version inside the running container
# -----------------------------------------------------------------------------
cmd_php() {
    local ver="${1:-}"

    if [ -z "${ver}" ]; then
        die "Usage: ./dev.sh php <version>   (e.g. ./dev.sh php 8.4)"
    fi

    validate_versions "${ver}"

    if ! container_running; then
        die "Container is not running. Run './dev.sh up' first."
    fi

    local rc=0
    docker compose exec "${DEV_SERVICE}" switch-php "${ver}" || rc=$?

    if [ "${rc}" -ne 0 ]; then
        die "switch-php ${ver} failed (exit ${rc})."
    fi

    info "Active PHP: ${ver}"
}

# -----------------------------------------------------------------------------
#  _perform_clean — shared cleanup logic (no prompt)
# -----------------------------------------------------------------------------
_perform_clean() {
    local targets=(
        "${SCRIPT_DIR}/compiled_tests"
        "${RELEASE_DIR}"
        "${LOG_DIR}"
        "${SCRIPT_DIR}/Dockerfile.dev.generated"
        "${SCRIPT_DIR}/docker-compose.override.yml"
    )

    for t in "${targets[@]}"; do
        if [ -e "${t}" ]; then
            info "Removing $(realpath --relative-to="${SCRIPT_DIR}/.." "${t}") ..."
            rm -rf "${t}"
        fi
    done

    # Remove per-version test build images
    for ver in "${ALL_VERSIONS[@]}"; do
        local img="${IMAGE_BASE}:php${ver}"
        if docker image inspect "${img}" >/dev/null 2>&1; then
            info "Removing Docker image ${img} ..."
            docker rmi "${img}" 2>/dev/null \
                || warn "Could not remove ${img} — it may be in use by a running container."
        fi
    done
}

# -----------------------------------------------------------------------------
#  cmd_clean — remove compiled artifacts and build images, keep dev container
# -----------------------------------------------------------------------------
cmd_clean() {
    echo ""
    echo "  The following will be permanently deleted:"
    echo ""
    echo "    • compiled_tests/              all compiled .so files"
    echo "    • release/                     staged .so files"
    echo "    • docker-logs/                 build logs"
    echo "    • Dockerfile.dev.generated"
    echo "    • docker-compose.override.yml"
    echo "    • Docker images: ${IMAGE_BASE}:php*"
    echo ""
    echo "  The dev container and dev image are NOT touched."
    echo ""
    printf "  Proceed? [y/N]: "
    read -r confirm
    echo ""
    case "${confirm}" in
        [yY]*) ;;
        *) info "Aborted."; echo ""; return ;;
    esac

    _perform_clean

    echo ""
    info "Clean complete."
    hint "Run './dev.sh build' to recompile."
    echo ""
}

# -----------------------------------------------------------------------------
#  cmd_nuke — clean + full Docker project teardown
# -----------------------------------------------------------------------------
cmd_nuke() {
    echo ""
    echo "  The following will be permanently deleted:"
    echo ""
    echo "    • Everything removed by 'clean'"
    echo "    • Dev container (stopped and removed)"
    echo "    • Dev Docker image"
    echo "    • Docker volumes and networks for this project"
    echo ""
    printf "  ${RED}This cannot be undone.${NC} Proceed? [y/N]: "
    read -r confirm
    echo ""
    case "${confirm}" in
        [yY]*) ;;
        *) info "Aborted."; echo ""; return ;;
    esac

    info "Tearing down Docker project resources ..."
    docker compose down --volumes --rmi all 2>/dev/null \
        || warn "docker compose down reported errors — project may already be clean."
    echo ""

    _perform_clean

    echo ""
    info "Nuke complete. Project state has been fully reset."
    hint "Run './dev.sh build' to start fresh."
    echo ""
}

# -----------------------------------------------------------------------------
#  Main
# -----------------------------------------------------------------------------
case "${1:-}" in
    build)
        shift
        cmd_build "$@"
        ;;
    up)
        cmd_up
        ;;
    down)
        cmd_down
        ;;
    bash)
        cmd_bash
        ;;
    run-bash)
        cmd_run_bash
        ;;
    php)
        cmd_php "${2:-}"
        ;;
    test)
        shift
        cmd_test "$@"
        ;;
    clean)
        cmd_clean
        ;;
    nuke)
        cmd_nuke
        ;;
    help|--help|-h|"")
        usage
        ;;
    *)
        err "Unknown command: '${1}'"
        hint "Run './dev.sh help'"
        echo ""
        exit 1
        ;;
esac
