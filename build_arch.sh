#!/bin/bash
# =============================================================================
#  pdo_sqlcipher — multi-version PHP PDO build tool (Arch Linux)
#  Supports PHP 7.4 through 8.5 (.so module)
# =============================================================================
set -eo pipefail

# -----------------------------------------------------------------------------
#  SQLCipher compile flags (shared across all PHP versions)
# -----------------------------------------------------------------------------

CFLAGS=" \
	-D_GNU_SOURCE \
	-DSQLITE_HAS_CODEC \
	-DSQLITE_ENABLE_UPDATE_DELETE_LIMIT \
	-DSQLITE_ENABLE_COLUMN_METADATA \
	-DSQLITE_ENABLE_RTREE \
	-DSQLITE_ENABLE_FTS3 \
	-DSQLITE_ENABLE_FTS3_PARENTHESIS \
	-DSQLITE_ENABLE_FTS4 \
	-DSQLITE_SECURE_DELETE \
	-DSQLITE_ENABLE_ICU \
	-DSQLITE_SOUNDEX \
	-DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
	-DSQLITE_TEMP_STORE=2 \
	-DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
	-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown \
	-include stdint.h \
	-I. -I/usr/local/include"

LDFLAGS="-lcrypto -licuuc -licui18n -L/usr/local/lib"

# -----------------------------------------------------------------------------
#  Per-version metadata
# -----------------------------------------------------------------------------

declare -A PHP_API_MAP=(
    [7.4]="20190902"
    [8.0]="20200930"
    [8.1]="20210902"
    [8.2]="20220829"
    [8.3]="20230831"
    [8.4]="20240924"
    [8.5]="20250925"
)

SUPPORTED_VERSIONS=(7.4 8.0 8.1 8.2 8.3 8.4 8.5)

SQLCIPHER_SRC="sqlcipher.git"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MAKE_JOBS=$(( $(nproc) > 4 ? 4 : $(nproc) ))

# Globals set during build_so(), consumed by print_summary()
PHP_EXT_DIR=""
PHP_MAJOR=""
PHP_MINOR=""
PHP_API_BUILT=""
PHP_SRC_DIR=""
PHP_PKG_NAME=""

# =============================================================================
#  Utility functions
# =============================================================================

die()  { echo ""; echo "  ERROR: $*" >&2; exit 1; }
info() { echo "      $*"; }
hr()   { echo "  ---------------------------------------------"; }

# Return installed version string for a pacman package, or empty.
pkg_ver() {
    pacman -Q "$1" 2>/dev/null | awk '{print $2}' || true
}

# Return the php-config binary for a given X.Y version string, or empty.
# Checks version-specific names first (AUR versioned packages use phpize74 etc.),
# then falls back to scanning known prefix locations.
php_config_bin() {
    local ver="$1"
    local nodot="${ver//./}"   # e.g. "84" from "8.4"

    # 1. Version-specific binary (AUR packages: php-config84, php-config8.4, etc.)
    for candidate in "php-config${ver}" "php-config${nodot}"; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            echo "${candidate}"
            return 0
        fi
    done

    # 2. Scan known locations; verify version matches.
    local candidate
    for candidate in \
            "$(command -v php-config 2>/dev/null)" \
            /usr/local/bin/php-config \
            /usr/bin/php-config; do
        [ -x "${candidate}" ] || continue
        local v
        v=$("${candidate}" --version 2>/dev/null | cut -d. -f1-2)
        [ "${v}" = "${ver}" ] && echo "${candidate}" && return 0
    done
    return 0
}

# Return the phpize binary for a given X.Y version string, or empty.
phpize_bin() {
    local ver="$1"
    local nodot="${ver//./}"

    # 1. Version-specific binary (AUR packages)
    for candidate in "phpize${ver}" "phpize${nodot}"; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            echo "${candidate}"
            return 0
        fi
    done

    # 2. Scan known locations; verify it lives alongside the right php-config.
    local cfg
    cfg=$(php_config_bin "${ver}")
    [ -z "${cfg}" ] && return 0

    local candidate
    for candidate in \
            "$(command -v phpize 2>/dev/null)" \
            /usr/local/bin/phpize \
            /usr/bin/phpize; do
        [ -x "${candidate}" ] || continue
        local pz_dir cfg_dir
        pz_dir=$(dirname "${candidate}")
        cfg_dir=$(dirname "${cfg}")
        [ "${pz_dir}" = "${cfg_dir}" ] && echo "${candidate}" && return 0
    done

    if command -v phpize >/dev/null 2>&1; then
        local pz_dir cfg_dir
        pz_dir=$(dirname "$(command -v phpize)")
        cfg_dir=$(dirname "${cfg}")
        [ "${pz_dir}" = "${cfg_dir}" ] && echo "phpize" && return 0
    fi
    return 0
}

# =============================================================================
#  Version detection
# =============================================================================

detect_installed_versions() {
    local found=()
    for ver in "${SUPPORTED_VERSIONS[@]}"; do
        local nodot="${ver//./}"

        # Version-specific binaries (AUR packages like php74, php84 …)
        if command -v "php-config${ver}" >/dev/null 2>&1 \
                || command -v "php-config${nodot}" >/dev/null 2>&1; then
            found+=("${ver}"); continue
        fi

        # Any php-config resolving to this version
        if [ -n "$(php_config_bin "${ver}")" ]; then
            found+=("${ver}"); continue
        fi

        # Versioned PHP runtime (AUR: php74, php80 …)
        if command -v "php${ver}" >/dev/null 2>&1 \
                || command -v "php${nodot}" >/dev/null 2>&1; then
            found+=("${ver}"); continue
        fi

        # Plain php binary reporting this version
        if command -v php >/dev/null 2>&1; then
            local pv
            pv=$(php --version 2>/dev/null | head -1 | sed 's/^PHP \([0-9]*\.[0-9]*\).*/\1/')
            [ "${pv}" = "${ver}" ] && { found+=("${ver}"); continue; }
        fi
    done
    [ "${#found[@]}" -gt 0 ] && printf '%s\n' "${found[@]}"
}

# =============================================================================
#  Menu helpers
# =============================================================================

print_header() {
    clear
    echo ""
    echo "  ============================================="
    echo "    pdo_sqlcipher  —  Multi-version Builder"
    echo "             (Arch Linux edition)"
    echo "  ============================================="
    echo ""
}

read_choice() {
    local min="$1" max="$2"
    while true; do
        printf "\n  Choice [%s-%s]: " "${min}" "${max}"
        read -r MENU_CHOICE
        if [[ "${MENU_CHOICE}" =~ ^[0-9]+$ ]] \
            && [ "${MENU_CHOICE}" -ge "${min}" ] \
            && [ "${MENU_CHOICE}" -le "${max}" ]; then
            return 0
        fi
        echo "  Invalid — enter a number between ${min} and ${max}."
    done
}

# =============================================================================
#  Menu: PHP version selection
# =============================================================================

menu_php_version() {
    echo ""
    hr
    echo ""
    echo "  Select PHP version to build for:"
    echo ""

    local idx=1
    local -a menu_map=()

    printf "    %d)  Autodetect installed version(s)\n" "${idx}"
    menu_map+=("__auto__")
    idx=$((idx + 1))

    for ver in "${SUPPORTED_VERSIONS[@]}"; do
        local cfg
        cfg=$(php_config_bin "${ver}")
        if [ -n "${cfg}" ]; then
            local extdir
            extdir=$("${cfg}" --extension-dir 2>/dev/null || echo "unknown")
            printf "    %d)  PHP %-5s  \033[0;32m[installed]\033[0m  %s\n" \
                   "${idx}" "${ver}" "${extdir}"
        else
            local php_found=0
            local nodot="${ver//./}"
            if command -v "php${ver}" >/dev/null 2>&1 \
                    || command -v "php${nodot}" >/dev/null 2>&1; then
                php_found=1
            elif command -v php >/dev/null 2>&1; then
                local pv
                pv=$(php --version 2>/dev/null | head -1 | sed 's/^PHP \([0-9]*\.[0-9]*\).*/\1/')
                [ "${pv}" = "${ver}" ] && php_found=1
            fi
            if [ "${php_found}" -eq 1 ]; then
                printf "    %d)  PHP %-5s  \033[0;33m[runtime found — needs php dev package to build]\033[0m\n" \
                       "${idx}" "${ver}"
            else
                printf "    %d)  PHP %-5s  \033[0;90m[not installed]\033[0m\n" \
                       "${idx}" "${ver}"
            fi
        fi
        menu_map+=("${ver}")
        idx=$((idx + 1))
    done

    read_choice 1 $((idx - 1))
    local selected="${menu_map[$((MENU_CHOICE - 1))]}"

    if [ "${selected}" = "__auto__" ]; then
        _pick_autodetected
    else
        TARGET_VERSION="${selected}"
        local cfg
        cfg=$(php_config_bin "${TARGET_VERSION}")
        if [ -z "${cfg}" ]; then
            echo ""
            echo "  PHP ${TARGET_VERSION} dev tools not found."
            echo "  Install with:  sudo pacman -S php"
            echo "  For older versions, search the AUR:  yay -S php${TARGET_VERSION//./}"
            exit 1
        fi
    fi
}

_pick_autodetected() {
    echo ""
    echo "  Scanning for installed PHP versions..."

    local -a found=()
    mapfile -t found < <(detect_installed_versions)

    if [ "${#found[@]}" -eq 0 ]; then
        echo ""
        echo "  No supported PHP version detected."
        echo "  Install one with:"
        echo "    sudo pacman -S php            # current stable"
        echo "    yay -S php74 php80 php81 ...  # older versions via AUR"
        exit 1
    fi

    if [ "${#found[@]}" -eq 1 ]; then
        TARGET_VERSION="${found[0]}"
        echo "  Detected: PHP ${TARGET_VERSION}"
        return
    fi

    echo ""
    echo "  Multiple PHP versions detected. Pick one:"
    echo ""
    local i=1
    for ver in "${found[@]}"; do
        local cfg extdir
        cfg=$(php_config_bin "${ver}")
        extdir=$("${cfg}" --extension-dir 2>/dev/null || echo "unknown")
        printf "    %d)  PHP %-5s  %s\n" "${i}" "${ver}" "${extdir}"
        i=$((i + 1))
    done

    read_choice 1 "${#found[@]}"
    TARGET_VERSION="${found[$((MENU_CHOICE - 1))]}"
}

# =============================================================================
#  Confirm
# =============================================================================

confirm_build() {
    echo ""
    hr
    echo ""
    echo "  Build plan"
    echo "    PHP version : ${TARGET_VERSION}  (API ${PHP_API_MAP[${TARGET_VERSION}]})"
    echo "    Output      : release/php${TARGET_VERSION}/pdo_sqlcipher.so"
    echo ""
    if [ "${CI:-}" = "1" ]; then
        echo "  Proceeding (CI mode)."
        return
    fi
    printf "  Proceed? [Y/n]: "
    read -r _confirm
    case "${_confirm}" in
        [nN]*) echo "  Aborted."; exit 0 ;;
    esac
}

# =============================================================================
#  Dependency check
# =============================================================================

check_build_deps() {
    local ver="$1"

    local missing=()

    # PHP dev tools (phpize + php-config)
    if [ -z "$(phpize_bin "${ver}")" ]; then
        local nodot="${ver//./}"
        missing+=("phpize not found — install php or php${nodot} (AUR)")
    fi

    # Core build tools
    command -v gcc      >/dev/null 2>&1 || missing+=("gcc  (package: base-devel)")
    command -v make     >/dev/null 2>&1 || missing+=("make  (package: base-devel)")
    command -v autoconf >/dev/null 2>&1 || missing+=("autoconf")
    command -v git      >/dev/null 2>&1 || missing+=("git")

    # Required libraries — use pacman -Qi
    pacman -Qi openssl >/dev/null 2>&1 || missing+=("openssl")
    pacman -Qi icu     >/dev/null 2>&1 || missing+=("icu")

    if [ "${#missing[@]}" -gt 0 ]; then
        echo ""
        echo "  Missing build dependencies:"
        for pkg in "${missing[@]}"; do
            printf "    \033[0;31m• %s\033[0m\n" "${pkg}"
        done
        echo ""
        echo "  Install with:"
        echo "    sudo pacman -S base-devel openssl icu php git autoconf"
        echo ""
        exit 1
    fi
}

# =============================================================================
#  Step 1 — Clone and build the SQLCipher amalgamation
# =============================================================================

prepare_sqlcipher() {
    echo ""
    hr
    echo "  [1/3]  SQLCipher amalgamation"
    hr
    echo ""

    cd "${SCRIPT_DIR}"

    if [ ! -d "${SQLCIPHER_SRC}" ]; then
        echo "  Cloning SQLCipher..."
        git clone "https://github.com/sqlcipher/sqlcipher.git" "${SQLCIPHER_SRC}"
    fi

    if [ ! -f "${SQLCIPHER_SRC}/sqlite3.c" ]; then
        echo "  Configuring and building..."
        cd "${SQLCIPHER_SRC}"
        make distclean 2>/dev/null || true
        ./configure --disable-shared CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}"
        nice -n 10 make -j"${MAKE_JOBS}"
        cd "${SCRIPT_DIR}"
    else
        info "Amalgamation already built — skipping."
    fi
}

# =============================================================================
#  Step 2 — Fetch PHP source from php.net
# =============================================================================

get_php_source() {
    local src_ver="$1"   # e.g. 8.3.21

    echo ""
    hr
    echo "  [2/3]  PHP ${src_ver} source"
    hr
    echo ""

    cd "${SCRIPT_DIR}"

    # Accept either directory naming convention (php-X.Y.Z or phpX.Y-X.Y.Z)
    local src_dir
    src_dir=$(find . -maxdepth 1 -type d \( -name "php-${src_ver}" -o -name "php[0-9]*-${src_ver}" \) \
              | sort | tail -1 | sed 's|^\./||')

    if [ -n "${src_dir}" ]; then
        info "Source directory ${src_dir} already present — skipping."
        PHP_SRC_DIR="${src_dir}"
        return
    fi

    local tarball="php-${src_ver}.tar.gz"
    local phpnet_url="https://www.php.net/distributions/${tarball}"
    echo "  Downloading from php.net..."
    echo "  URL: ${phpnet_url}"
    echo ""

    if command -v wget >/dev/null 2>&1; then
        wget --show-progress -q "${phpnet_url}" -O "${tarball}" \
            || die "Failed to download ${phpnet_url}"
    elif command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar "${phpnet_url}" -o "${tarball}" \
            || die "Failed to download ${phpnet_url}"
    else
        die "Cannot fetch PHP source: neither wget nor curl is installed."
    fi

    tar xzf "${tarball}"
    rm -f "${tarball}"

    src_dir=$(find . -maxdepth 1 -type d \( -name "php[0-9]*" -o -name "php-[0-9]*" \) \
              | sort | tail -1 | sed 's|^\./||')
    [ -z "${src_dir}" ] && die "Could not find extracted PHP source directory."

    info "Using source directory: ${src_dir}"
    PHP_SRC_DIR="${src_dir}"
}

# =============================================================================
#  Step 3 — Patch pdo_sqlite sources → pdo_sqlcipher
# =============================================================================

patch_pdo_sources() {
    local build_dir="$1"
    local pdo_dir="$2"

    cp "${pdo_dir}"/*.c "${pdo_dir}"/*.h "${build_dir}/"
    cp "${pdo_dir}"/*.re "${build_dir}/" 2>/dev/null || true

    for f in "${build_dir}"/*; do
        [ -f "${f}" ] || continue
        local tmp="${f}.tmp"
        sed -e 's/sqlite/sqlcipher/g' \
            -e 's/SQLite/SQLCipher/g' \
            -e 's/PDO_SQLITE/PDO_SQLCIPHER/g' \
            "${f}" > "${tmp}"
        local newf
        newf=$(echo "${f}" | sed 's/sqlite/sqlcipher/')
        mv "${tmp}" "${newf}"
        [ "${newf}" != "${f}" ] && rm -f "${f}"
    done

    cp "${SCRIPT_DIR}/${SQLCIPHER_SRC}/sqlite3.c" "${build_dir}/sqlcipher3.c"
    cp "${SCRIPT_DIR}/${SQLCIPHER_SRC}/sqlite3.h" "${build_dir}/sqlcipher3.h"

    for f in "${build_dir}"/sqlcipher3.*; do
        sed -i \
            -e 's/sqlite3/sqlcipher3/g' \
            -e 's/"sqlcipher3/"sqlite3/g' \
            -e "s/'sqlcipher3/'sqlite3/g" \
            -e 's/\(sqlcipher3_syscall_ptr\)sqlcipher3_pread64/\1pread64/g' \
            -e 's/\(sqlcipher3_syscall_ptr\)sqlcipher3_pwrite64/\1pwrite64/g' \
            -e 's/\(sqlcipher3_syscall_ptr\)sqlcipher3_mremap/\1mremap/g' \
            -e 's/\(size_t,\)sqlcipher3_off64_t/\1off64_t/g' \
            -e 's/sqlcipher3_MREMAP_MAYMOVE/MREMAP_MAYMOVE/g' \
            "${f}"
    done
}

# =============================================================================
#  Step 3 cont. — phpize + configure + make → pdo_sqlcipher.so
# =============================================================================

build_so() {
    local ver="$1"

    local php_cfg phpize
    php_cfg=$(php_config_bin "${ver}") || true
    phpize=$(phpize_bin "${ver}")      || true

    [ -z "${php_cfg}" ] && die "php-config for PHP ${ver} not found." \
                                "Install: sudo pacman -S php  or  yay -S php${ver//./}"
    [ -z "${phpize}"  ] && die "phpize for PHP ${ver} not found." \
                                "Install: sudo pacman -S php  or  yay -S php${ver//./}"

    local full_ver api
    full_ver=$("${php_cfg}" --version)
    api=$("${php_cfg}" --phpapi 2>/dev/null | grep -E '^[0-9]{8}$' || true)
    if [ -z "${api}" ]; then
        api=$("${php_cfg}" --extension-dir 2>/dev/null | grep -oE '[0-9]{8}$' || true)
    fi
    # Arch's php-config lacks --phpapi and doesn't embed the stamp in the ext dir path;
    # fall back to the known-good value from the map.
    if [ -z "${api}" ]; then
        api="${PHP_API_MAP[${ver}]}"
    fi
    [ -z "${api}" ] && die "Cannot determine PHP API version for PHP ${ver}."

    PHP_PKG_NAME="php${ver}"
    PHP_EXT_DIR=$("${php_cfg}" --extension-dir)
    PHP_MAJOR="${full_ver%%.*}"
    PHP_MINOR=$(echo "${full_ver}" | cut -d. -f2)
    PHP_API_BUILT="${api}"

    # Derive upstream source version from php-config (ground truth on Arch)
    local src_ver="${full_ver}"

    # Validate API number consistency
    local expected_api="${PHP_API_MAP[${ver}]}"
    if [ "${api}" != "${expected_api}" ]; then
        echo "  WARNING: API mismatch for PHP ${ver}: got ${api}, expected ${expected_api}."
        echo "  Proceeding with reported API ${api}."
    fi

    get_php_source "${src_ver}"

    local pdo_dir="${SCRIPT_DIR}/${PHP_SRC_DIR}/ext/pdo_sqlite"
    if [ ! -d "${pdo_dir}" ]; then
        pdo_dir=$(find "${SCRIPT_DIR}/${PHP_SRC_DIR}" -type d -name "pdo_sqlite" | head -1)
        [ -z "${pdo_dir}" ] && die "pdo_sqlite directory not found in ${PHP_SRC_DIR}"
    fi

    echo ""
    hr
    echo "  [3/3]  Compiling pdo_sqlcipher.so"
    hr
    echo ""
    info "PHP ${full_ver}  API ${api}  phpize: ${phpize}  php-config: ${php_cfg}"
    echo ""

    local build_dir="${SCRIPT_DIR}/build-php${ver}"
    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    patch_pdo_sources "${build_dir}" "${pdo_dir}"
    cp "${SCRIPT_DIR}/config.m4" "${build_dir}/config.m4"

    cd "${build_dir}"
    "${phpize}" --clean
    "${phpize}"
    ./configure --with-php-config="${php_cfg}" CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}"
    nice -n 10 make -j"${MAKE_JOBS}"
    cd "${SCRIPT_DIR}"

    local out_dir="${SCRIPT_DIR}/release/php${ver}"
    mkdir -p "${out_dir}"
    cp "${build_dir}/modules/pdo_sqlcipher.so" "${out_dir}/pdo_sqlcipher.so"
    strip "${out_dir}/pdo_sqlcipher.so"
    chmod 0644 "${out_dir}/pdo_sqlcipher.so"

    info "Output: ${out_dir}/pdo_sqlcipher.so"
}

# =============================================================================
#  Cleanup build artifacts
# =============================================================================

cleanup() {
    local ver="$1"
    echo ""
    hr
    echo "  Cleaning up..."
    hr
    echo ""

    cd "${SCRIPT_DIR}"

    rm -rf "build-php${ver}"
    [ -n "${PHP_SRC_DIR}" ] && rm -rf "${PHP_SRC_DIR}"
    find . -maxdepth 1 \( -name "*.tar.*" \) -delete 2>/dev/null || true

    info "Done."
}

# =============================================================================
#  Summary
# =============================================================================

print_summary() {
    local ver="$1"
    echo ""
    hr
    echo "  Build complete!"
    hr
    echo ""
    echo "    PHP ${TARGET_VERSION}  (API ${PHP_API_BUILT})"
    echo ""
    echo "  Output:"
    echo "    release/php${ver}/pdo_sqlcipher.so"
    echo ""
    echo "  Install:"
    echo "    sudo cp release/php${ver}/pdo_sqlcipher.so ${PHP_EXT_DIR}/"
    echo "    # Add to /etc/php/conf.d/pdo_sqlcipher.ini:"
    echo "    echo 'extension=pdo_sqlcipher.so' | sudo tee /etc/php/conf.d/pdo_sqlcipher.ini"
    echo ""
    hr
    echo ""
}

# =============================================================================
#  Optional deep clean
# =============================================================================

prompt_source_cleanup() {
    local to_remove=()

    [ -d "${SCRIPT_DIR}/${SQLCIPHER_SRC}" ] && to_remove+=("${SQLCIPHER_SRC}/")

    [ "${#to_remove[@]}" -eq 0 ] && return 0

    echo ""
    echo "  Remaining source files:"
    for item in "${to_remove[@]}"; do
        echo "    ${item}"
    done
    echo ""
    [ "${CI:-}" = "1" ] && return 0
    printf "  Remove them? [y/N]: "
    read -r _clean
    case "${_clean}" in
        [yY]*)
            cd "${SCRIPT_DIR}"
            rm -rf "${SQLCIPHER_SRC}"
            info "Source files removed."
            echo ""
            ;;
    esac
}

# =============================================================================
#  Main
# =============================================================================

TARGET_VERSION="${TARGET_VERSION:-}"

if [ "${CI:-}" = "1" ]; then
    [ -z "${TARGET_VERSION}" ] && die "CI mode requires TARGET_VERSION env var (e.g. 8.4)"
    echo "  CI build: PHP ${TARGET_VERSION}"
else
    print_header
    menu_php_version
fi

confirm_build
check_build_deps "${TARGET_VERSION}"

prepare_sqlcipher
build_so "${TARGET_VERSION}"

cleanup "${TARGET_VERSION}"
print_summary "${TARGET_VERSION}"
prompt_source_cleanup
