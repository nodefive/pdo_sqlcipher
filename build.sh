#!/bin/bash
# =============================================================================
#  pdo_sqlcipher — multi-version PHP PDO build tool
#  Supports PHP 7.4 through 8.5 (.so module and .deb package)
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
#
#  PHP_API_MAP    : Zend module API number — determines the extension dir path
#                   and the phpapi-XXXXXXXX dependency in the .deb control file.
#
#  HAS_SQL_PARSER : PHP 8.4 split the PDO SQL scanner out of sqlite_driver.c
#                   into a separate sqlite_sql_parser.c.  config.m4 checks for
#                   the renamed file at configure time, so this map is for
#                   documentation / future per-version overrides only.
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

# Cap parallel jobs so the compiler doesn't exhaust RAM and trigger the OOM killer.
# Each GCC instance on the 8 MB SQLCipher amalgamation can use ~1 GB; half of nproc
# keeps the build responsive without starving the desktop.
MAKE_JOBS=$(( $(nproc) > 4 ? 4 : $(nproc) ))

# Globals set during build_so(), consumed by build_deb() and print_summary()
PHP_EXT_DIR=""
PHP_DEB_VER=""
PHP_PKG_NAME=""
PHP_MAJOR=""
PHP_MINOR=""
PHP_API_BUILT=""
PHP_SRC_DIR=""

# =============================================================================
#  Utility functions
# =============================================================================

die()  { echo ""; echo "  ERROR: $*" >&2; exit 1; }
info() { echo "      $*"; }

hr()   { echo "  ---------------------------------------------"; }

pkg_ver() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

# Print the correct command to enable deb-src for apt-get source.
# Handles both legacy one-line format (/etc/apt/sources.list) and the
# modern DEB822 format (*.sources files used by Ubuntu 24.04+).
deb_src_hint() {
    # DEB822 format (Ubuntu 24.04+): prefer the main ubuntu.sources file,
    # then fall back to the first other .sources file that has 'Types: deb'.
    local deb822=""
    local f
    for f in \
        /etc/apt/sources.list.d/ubuntu.sources \
        /etc/apt/sources.list.d/*.sources; do
        [ -f "${f}" ] || continue
        grep -qE '^Types:.*\bdeb\b'     "${f}" 2>/dev/null || continue
        grep -qE '^Types:.*\bdeb-src\b' "${f}" 2>/dev/null && continue  # already enabled
        deb822="${f}"
        break
    done
    if [ -n "${deb822}" ]; then
        echo "  Enable source packages (DEB822 format detected):"
        echo "    sudo sed -i 's/^Types: deb\$/Types: deb deb-src/' \"${deb822}\""
        echo "    sudo apt-get update"
        return
    fi
    # Legacy one-line format: commented-out deb-src lines
    if [ -f /etc/apt/sources.list ]; then
        echo "  Enable source packages:"
        echo "    sudo sed -i 's/^# deb-src/deb-src/' /etc/apt/sources.list"
        echo "    sudo apt-get update"
    fi
}

# Return the php-config binary for a given X.Y version string, or empty.
# Always returns 0 — "not found" is empty output, not an error.
# Checks version-specific names first, then scans known prefix locations so that
# a source-built PHP in /usr/local is not shadowed by an apt alternatives symlink.
php_config_bin() {
    local ver="$1"
    # 1. Version-specific binary (apt-installed: php-config8.4, php-config8.5 …)
    if command -v "php-config${ver}" >/dev/null 2>&1; then
        echo "php-config${ver}"
        return 0
    fi
    # 2. Search every php-config candidate; report the first one for this version.
    #    Explicit prefix list covers source builds (/usr/local) and apt alternatives.
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
# Always returns 0 — "not found" is empty output, not an error.
phpize_bin() {
    local ver="$1"
    # 1. Version-specific binary
    if command -v "phpize${ver}" >/dev/null 2>&1; then
        echo "phpize${ver}"
        return 0
    fi
    # 2. Scan known locations; use php-config to verify the version.
    local cfg
    cfg=$(php_config_bin "${ver}")
    [ -z "${cfg}" ] && return 0
    local candidate
    for candidate in \
            "$(command -v phpize 2>/dev/null)" \
            /usr/local/bin/phpize \
            /usr/bin/phpize; do
        [ -x "${candidate}" ] || continue
        # phpize and php-config are always co-installed; trust the version we
        # already verified via php_config_bin.
        local pz_dir
        pz_dir=$(dirname "${candidate}")
        cfg_dir=$(dirname "${cfg}")
        [ "${pz_dir}" = "${cfg_dir}" ] && echo "${candidate}" && return 0
    done
    # Last resort: any phpize in PATH if it lives alongside the right php-config
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

# Prints one installed version per line (may be empty)
detect_installed_versions() {
    local found=()
    for ver in "${SUPPORTED_VERSIONS[@]}"; do
        # Primary: version-specific binaries
        if command -v "php-config${ver}" >/dev/null 2>&1; then
            found+=("${ver}"); continue
        fi
        # Secondary: any php-config (including source-build locations) for this version
        if [ -n "$(php_config_bin "${ver}")" ]; then
            found+=("${ver}"); continue
        fi
        # Tertiary: dpkg (handles cases where binary isn't in PATH yet)
        if dpkg-query -W -f='${Status}' "php${ver}-dev" 2>/dev/null \
                | grep -q "install ok installed"; then
            found+=("${ver}"); continue
        fi
        # Quaternary: update-alternatives
        if update-alternatives --list phpize 2>/dev/null \
                | grep -qF "${ver}"; then
            found+=("${ver}"); continue
        fi
        # Quinary: versioned php binary (e.g. php8.4) — dev tools may be separate
        if command -v "php${ver}" >/dev/null 2>&1; then
            found+=("${ver}"); continue
        fi
        # Senary: plain php binary reporting this version
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
    echo "  ============================================="
    echo ""
}

# Prompt for a number in [min..max]; result in $MENU_CHOICE
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
#  Menu 1: output type
# =============================================================================

menu_output_type() {
    echo "  What do you want to build?"
    echo ""
    echo "    1)  Module only"
    echo "    2)  Module and Package (deb)"
    echo ""
    read_choice 1 2
    BUILD_TYPE="${MENU_CHOICE}"    # 1 = module, 2 = deb
}

# =============================================================================
#  Menu 2: PHP version selection
# =============================================================================

menu_php_version() {
    echo ""
    hr
    echo ""
    echo "  Select PHP version to build for:"
    echo ""

    local idx=1
    local -a menu_map=()    # parallel array: menu index -> version string

    # Entry 1: autodetect
    printf "    %d)  Autodetect installed version(s)\n" "${idx}"
    menu_map+=("__auto__")
    idx=$((idx + 1))

    # One entry per supported version
    for ver in "${SUPPORTED_VERSIONS[@]}"; do
        local cfg
        cfg=$(php_config_bin "${ver}")
        if [ -n "${cfg}" ]; then
            local extdir
            extdir=$("${cfg}" --extension-dir 2>/dev/null || echo "unknown")
            printf "    %d)  PHP %-5s  \033[0;32m[installed]\033[0m  %s\n" \
                   "${idx}" "${ver}" "${extdir}"
        else
            # Check if at least the PHP runtime is present (dev tools may be separate)
            local php_found=0
            if command -v "php${ver}" >/dev/null 2>&1; then
                php_found=1
            elif command -v php >/dev/null 2>&1; then
                local pv
                pv=$(php --version 2>/dev/null | head -1 | sed 's/^PHP \([0-9]*\.[0-9]*\).*/\1/')
                [ "${pv}" = "${ver}" ] && php_found=1
            fi
            if [ "${php_found}" -eq 1 ]; then
                printf "    %d)  PHP %-5s  \033[0;33m[runtime found — needs php%s-dev to build]\033[0m\n" \
                       "${idx}" "${ver}" "${ver}"
            else
                printf "    %d)  PHP %-5s  \033[0;90m[not installed — needs php%s-dev]\033[0m\n" \
                       "${idx}" "${ver}" "${ver}"
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
        # Verify dev tools are present
        local cfg
        cfg=$(php_config_bin "${TARGET_VERSION}")
        if [ -z "${cfg}" ]; then
            echo ""
            echo "  PHP ${TARGET_VERSION} dev tools not found."
            echo "  Install with:  sudo apt install php${TARGET_VERSION}-dev"
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
        echo "  Install one of:"
        echo "    sudo apt install php7.4-dev php8.0-dev php8.1-dev php8.2-dev"
        echo "    sudo apt install php8.3-dev php8.4-dev php8.5-dev"
        exit 1
    fi

    if [ "${#found[@]}" -eq 1 ]; then
        TARGET_VERSION="${found[0]}"
        echo "  Detected: PHP ${TARGET_VERSION}"
        return
    fi

    # Multiple versions — let the user pick one
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
    local type_label
    [ "${BUILD_TYPE}" -eq 1 ] \
        && type_label="Module (.so)  →  release/php${TARGET_VERSION}/pdo_sqlcipher.so" \
        || type_label="Package (deb)  →  release/php${TARGET_VERSION}/php${TARGET_VERSION}-sqlcipher.deb"

    echo ""
    hr
    echo ""
    echo "  Build plan"
    echo "    PHP version : ${TARGET_VERSION}  (API ${PHP_API_MAP[${TARGET_VERSION}]})"
    echo "    Output      : ${type_label}"
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
#  Dependency check — run after version + output type are confirmed
# =============================================================================

check_build_deps() {
    local ver="$1"        # e.g. 8.4
    local build_deb="$2"  # 1 = deb output requested

    local missing=()
    local missing_soft=()

    # PHP dev tools
    if ! command -v "phpize${ver}"    >/dev/null 2>&1 && \
       ! command -v  phpize           >/dev/null 2>&1; then
        missing+=("php${ver}-dev")
    fi

    # Core build tools
    command -v gcc      >/dev/null 2>&1 || missing+=("gcc  (package: build-essential)")
    command -v make     >/dev/null 2>&1 || missing+=("make  (package: build-essential)")
    command -v autoconf >/dev/null 2>&1 || missing+=("autoconf")
    command -v git      >/dev/null 2>&1 || missing+=("git")

    # Required libraries
    dpkg-query -W -f='${Status}' libssl-dev 2>/dev/null \
        | grep -q "install ok installed" \
        || missing+=("libssl-dev")

    dpkg-query -W -f='${Status}' libicu-dev 2>/dev/null \
        | grep -q "install ok installed" \
        || missing+=("libicu-dev")

    # apt-get source needs deb-src lines (or DEB822 Types: deb deb-src)
    local has_src=0
    grep -rqE '^\s*deb-src\s' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
        && has_src=1
    grep -rqE '^Types:.*\bdeb-src\b' /etc/apt/sources.list.d/*.sources 2>/dev/null \
        && has_src=1
    if [ "${has_src}" -eq 0 ]; then
        missing+=("__deb_src__")
    fi

    # Packaging tools (only needed for .deb output)
    if [ "${build_deb}" -eq 2 ]; then
        command -v fakeroot >/dev/null 2>&1 || missing+=("fakeroot")
        dpkg-query -W -f='${Status}' dpkg-dev 2>/dev/null \
            | grep -q "install ok installed" \
            || missing+=("dpkg-dev")
        command -v lintian >/dev/null 2>&1 || missing_soft+=("lintian")
    fi

    # Non-critical warnings
    if [ "${#missing_soft[@]}" -gt 0 ]; then
        echo ""
        echo "  Warning: optional tool(s) not found:"
        for pkg in "${missing_soft[@]}"; do
            printf "    \033[0;33m• %s\033[0m\n" "${pkg}"
        done
        echo "    sudo apt install ${missing_soft[*]}"
    fi

    # Hard stop on missing critical deps
    if [ "${#missing[@]}" -gt 0 ]; then
        echo ""
        echo "  Missing build dependencies:"
        local apt_pkgs=()
        local need_deb_src=0
        for pkg in "${missing[@]}"; do
            if [ "${pkg}" = "__deb_src__" ]; then
                need_deb_src=1
                printf "    \033[0;31m• apt source packages not enabled\033[0m\n"
            else
                printf "    \033[0;31m• %s\033[0m\n" "${pkg}"
                apt_pkgs+=("${pkg%% *}")
            fi
        done
        echo ""
        if [ "${#apt_pkgs[@]}" -gt 0 ]; then
            echo "  Install packages:"
            echo "    sudo apt install ${apt_pkgs[*]}"
            echo ""
        fi
        if [ "${need_deb_src}" -eq 1 ]; then
            deb_src_hint
            echo ""
        fi
        exit 1
    fi
}

# =============================================================================
#  Step 1 — Clone and build the SQLCipher amalgamation (once per session)
# =============================================================================

prepare_sqlcipher() {
    echo ""
    hr
    echo "  [1/4]  SQLCipher amalgamation"
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
#  Step 2 — Fetch PHP source via apt-get source
# =============================================================================

get_php_source() {
    local pkg_name="$1"   # e.g. php8.5
    local src_ver="$2"    # e.g. 8.5.4

    echo ""
    hr
    echo "  [2/4]  PHP ${pkg_name} source"
    hr
    echo ""

    cd "${SCRIPT_DIR}"

    local src_dir="${pkg_name}-${src_ver}"

    if [ -d "${src_dir}" ]; then
        info "Source directory ${src_dir} already present — skipping."
        PHP_SRC_DIR="${src_dir}"
        return
    fi

    if ! apt-get source "${pkg_name}" 2>/dev/null \
            && ! apt-get source "${pkg_name}-common" 2>/dev/null; then
        # apt-get source unavailable (no deb-src for this version, or PPA-only build).
        # Fall back to downloading the tarball directly from php.net.
        local tarball="php-${src_ver}.tar.gz"
        local phpnet_url="https://www.php.net/distributions/${tarball}"
        echo ""
        echo "  apt-get source unavailable for ${pkg_name} — downloading from php.net..."
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
    fi

    # The extracted directory name might not exactly match our expectation.
    # apt-get source produces  php8.4-8.4.21/   (pkg-name prefix)
    # php.net tarball produces php-8.4.21/       (plain php- prefix)
    if [ ! -d "${src_dir}" ]; then
        src_dir=$(find . -maxdepth 1 -type d \( -name "php[0-9]*" -o -name "php-[0-9]*" \) \
                  | sort | tail -1 | sed 's|^\./||')
        [ -z "${src_dir}" ] && die "Could not find extracted PHP source directory."
        info "Using source directory: ${src_dir}"
    fi

    PHP_SRC_DIR="${src_dir}"
}

# =============================================================================
#  Step 3 — Patch pdo_sqlite sources → pdo_sqlcipher
# =============================================================================

patch_pdo_sources() {
    local build_dir="$1"
    local pdo_dir="$2"

    # Copy .c and .h files; also .re (re2c sources, present in PHP 8.4+)
    cp "${pdo_dir}"/*.c "${pdo_dir}"/*.h "${build_dir}/"
    cp "${pdo_dir}"/*.re "${build_dir}/" 2>/dev/null || true

    # Rename sqlite → sqlcipher in file contents and filenames
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

    # Inject SQLCipher amalgamation and fix symbol names
    # (sqlite3 → sqlcipher3, then restore names that must stay as sqlite3:
    #  string literals, standard-library wrappers, OS constants)
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
    php_cfg=$(php_config_bin "${ver}")   || true
    phpize=$(phpize_bin "${ver}")        || true

    [ -z "${php_cfg}" ] && die "php-config for PHP ${ver} not found." \
                                "Install: sudo apt install php${ver}-dev"
    [ -z "${phpize}"  ] && die "phpize for PHP ${ver} not found." \
                                "Install: sudo apt install php${ver}-dev"

    # Resolve version metadata from php-config (ground truth)
    local full_ver api
    full_ver=$("${php_cfg}" --version)
    # --phpapi is a Debian patch; source-built php-config lacks it.
    # Fall back to extracting the 8-digit API stamp from the extension-dir path.
    api=$("${php_cfg}" --phpapi 2>/dev/null | grep -E '^[0-9]{8}$' || true)
    if [ -z "${api}" ]; then
        api=$("${php_cfg}" --extension-dir 2>/dev/null | grep -oE '[0-9]{8}$' || true)
    fi
    [ -z "${api}" ] && die "Cannot determine PHP API version for PHP ${ver}."

    PHP_PKG_NAME="php${ver}"
    PHP_EXT_DIR=$("${php_cfg}" --extension-dir)
    PHP_MAJOR="${full_ver%%.*}"
    PHP_MINOR=$(echo "${full_ver}" | cut -d. -f2)
    PHP_API_BUILT="${api}"

    # Debian package version (used in .deb control file)
    PHP_DEB_VER=$(pkg_ver "${PHP_PKG_NAME}")
    [ -z "${PHP_DEB_VER}" ] && PHP_DEB_VER=$(pkg_ver "${PHP_PKG_NAME}-common")
    # php-common is intentionally excluded: Ondrej's PPA version it carries
    # (e.g. 2:101~+ubuntu24.04.1+deb.sury.org+1) is a repo revision, not a
    # PHP upstream version, and would corrupt the source download URL.
    [ -z "${PHP_DEB_VER}" ] && PHP_DEB_VER="${full_ver}"

    # Derive upstream source version (strip epoch + packaging suffix)
    local src_ver="${PHP_DEB_VER##*:}"
    src_ver="${src_ver%%-*}"

    # Guard: if stripping produced something that doesn't look like X.Y.Z
    # (e.g. a PPA revision slipped through), fall back to the version reported
    # by php-config which is always the exact upstream release number.
    if ! echo "${src_ver}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        src_ver="${full_ver}"
    fi

    # Validate API number consistency
    local expected_api="${PHP_API_MAP[${ver}]}"
    if [ "${api}" != "${expected_api}" ]; then
        echo "  WARNING: API mismatch for PHP ${ver}: got ${api}, expected ${expected_api}."
        echo "  Proceeding with reported API ${api}."
    fi

    get_php_source "${PHP_PKG_NAME}" "${src_ver}"

    local pdo_dir="${SCRIPT_DIR}/${PHP_SRC_DIR}/ext/pdo_sqlite"
    if [ ! -d "${pdo_dir}" ]; then
        pdo_dir=$(find "${SCRIPT_DIR}/${PHP_SRC_DIR}" -type d -name "pdo_sqlite" | head -1)
        [ -z "${pdo_dir}" ] && die "pdo_sqlite directory not found in ${PHP_SRC_DIR}"
    fi

    echo ""
    hr
    echo "  [3/4]  Compiling pdo_sqlcipher.so"
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
    # --with-php-config ensures the right PHP is targeted when multiple versions coexist
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
#  Step 4 — Package .deb
# =============================================================================

build_deb() {
    local ver="$1"
    local so_path="${SCRIPT_DIR}/release/php${ver}/pdo_sqlcipher.so"
    [ -f "${so_path}" ] || die "Expected ${so_path} — .so build must succeed first."

    echo ""
    hr
    echo "  [4/4]  Building .deb package"
    hr
    echo ""

    # Detect libssl (Ubuntu 24.04+ ships libssl3t64 for 64-bit time_t ABI)
    local libssl_pkg libssl_ver
    libssl_pkg=$(dpkg-query -W -f='${Package}\n' libssl3t64 2>/dev/null | head -1 || true)
    [ -z "${libssl_pkg}" ] && \
        libssl_pkg=$(dpkg-query -W -f='${Package}\n' libssl3 2>/dev/null | head -1 || true)
    [ -z "${libssl_pkg}" ] && libssl_pkg="libssl3"
    libssl_ver=$(pkg_ver "${libssl_pkg}")
    libssl_ver="${libssl_ver##*:}"; libssl_ver="${libssl_ver%%-*}"
    [ -z "${libssl_ver}" ] && libssl_ver="3.0.0"

    # Detect libicu
    local libicu libicu_ver
    libicu=$(dpkg-query -W -f='${Package}\n' 'libicu[0-9]*' 2>/dev/null \
             | grep -v '-' | head -1 || true)
    [ -z "${libicu}" ] && libicu="libicu74"
    libicu_ver=$(pkg_ver "${libicu}")
    libicu_ver="${libicu_ver##*:}"; libicu_ver="${libicu_ver%%-*}"
    [ -z "${libicu_ver}" ] && libicu_ver="0"

    local pkg_name="${PHP_PKG_NAME}-sqlcipher"
    local pkg_dir="${SCRIPT_DIR}/package"
    local ext_subdir="${PHP_EXT_DIR#/}"   # strip leading /

    # Wipe dynamic content from any previous run
    rm -rf "${pkg_dir}/usr" "${pkg_dir}/etc"
    rm -f  "${pkg_dir}/DEBIAN/md5sums"

    # Generate DEBIAN/control
    cat > "${pkg_dir}/DEBIAN/control" << EOF
Package: ${pkg_name}
Version: ${PHP_DEB_VER}
Architecture: amd64
Maintainer: Mach7Seven
Installed-Size: 350
Depends: libc6 (>= 2.35), ${libssl_pkg} (>= ${libssl_ver}), ${libicu} (>= ${libicu_ver}), phpapi-${PHP_API_BUILT}, ${PHP_PKG_NAME}-common (= ${PHP_DEB_VER})
Section: php
Priority: optional
Homepage: https://github.com/abbat/pdo_sqlcipher
Description: sqlcipher module for PHP ${PHP_MAJOR}.${PHP_MINOR}
 SQLCipher is an SQLite extension that provides transparent
 256-bit AES encryption of database files.
EOF

    # Extension .so
    mkdir -p "${pkg_dir}/${ext_subdir}"
    cp "${so_path}" "${pkg_dir}/${ext_subdir}/pdo_sqlcipher.so"

    # sqlcipher CLI binary (produced by make in SQLCIPHER_SRC)
    local cli="${SCRIPT_DIR}/${SQLCIPHER_SRC}/sqlcipher"
    if [ -f "${cli}" ]; then
        mkdir -p "${pkg_dir}/usr/bin"
        cp "${cli}" "${pkg_dir}/usr/bin/sqlcipher"
        strip "${pkg_dir}/usr/bin/sqlcipher"
        chmod 0755 "${pkg_dir}/usr/bin/sqlcipher"
    else
        info "sqlcipher CLI binary not found — omitting from package."
    fi

    # INI in mods-available (phpenmod / phpdismod compatible)
    local conf_dir="/etc/php/${PHP_MAJOR}.${PHP_MINOR}/mods-available"
    mkdir -p "${pkg_dir}${conf_dir}"
    echo "extension=pdo_sqlcipher.so" > "${pkg_dir}${conf_dir}/pdo_sqlcipher.ini"
    echo "${conf_dir}/pdo_sqlcipher.ini" > "${pkg_dir}/DEBIAN/conffiles"

    # copyright
    local doc_dir="${pkg_dir}/usr/share/doc/${pkg_name}"
    mkdir -p "${doc_dir}"
    cat > "${doc_dir}/copyright" << 'COPY'
pdo_sqlite under PHP License (http://www.php.net/license/3_0.txt)
sqlcipher under BSD-style open source license (http://sqlcipher.net/license)
COPY

    # lintian overrides
    local lintian_dir="${pkg_dir}/usr/share/lintian/overrides"
    mkdir -p "${lintian_dir}"
    cat > "${lintian_dir}/${pkg_name}" << EOF
${pkg_name}: debian-changelog-file-missing
${pkg_name}: hardening-no-relro
${pkg_name}: copyright-without-copyright-notice
${pkg_name}: binary-or-shlib-defines-rpath
${pkg_name}: embedded-library
${pkg_name}: hardening-no-fortify-functions
${pkg_name}: binary-without-manpage
EOF

    # md5sums
    ( cd "${pkg_dir}" && find etc usr -type f -exec md5sum {} \; \
        > DEBIAN/md5sums 2>/dev/null || true )

    local out_dir="${SCRIPT_DIR}/release/php${ver}"
    fakeroot dpkg-deb -z9 -b "${pkg_dir}"
    mv "${pkg_dir}.deb" "${out_dir}/${pkg_name}.deb"
    lintian "${out_dir}/${pkg_name}.deb" \
        || info "lintian reported issues (non-fatal; see above)"

    # Clean package staging area for next run
    rm -rf "${pkg_dir}/usr" "${pkg_dir}/etc"
    rm -f  "${pkg_dir}/DEBIAN/md5sums"

    info "Output: release/php${ver}/${pkg_name}.deb"
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
    find . -maxdepth 1 \( -name "*.dsc" -o -name "*.tar.*" -o -name "*.diff.*" \) \
        -delete 2>/dev/null || true

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
    if [ "${BUILD_TYPE}" -eq 2 ]; then
        echo "    release/php${ver}/${PHP_PKG_NAME}-sqlcipher.deb"
    fi
    echo ""

    if [ "${BUILD_TYPE}" -eq 1 ]; then
        echo "  Install (manual):"
        echo "    sudo cp release/php${ver}/pdo_sqlcipher.so ${PHP_EXT_DIR}/"
        echo "    # then add  extension=pdo_sqlcipher.so  to your php.ini"
    else
        echo "  Install (.deb):"
        echo "    sudo dpkg -i release/php${ver}/${PHP_PKG_NAME}-sqlcipher.deb"
        echo "    sudo phpenmod pdo_sqlcipher"
    fi

    echo ""
    hr
    echo ""
}

# =============================================================================
#  Optional deep clean
# =============================================================================

prompt_source_cleanup() {
    local ver="$1"
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

BUILD_TYPE="${BUILD_TYPE:-}"
TARGET_VERSION="${TARGET_VERSION:-}"

if [ "${CI:-}" = "1" ]; then
    [ -z "${TARGET_VERSION}" ] && die "CI mode requires TARGET_VERSION env var (e.g. 8.4)"
    [ -z "${BUILD_TYPE}" ]     && die "CI mode requires BUILD_TYPE env var (1 = .so, 2 = .deb)"
    echo "  CI build: PHP ${TARGET_VERSION}, type ${BUILD_TYPE}"
else
    print_header
    menu_output_type
    menu_php_version
fi

confirm_build
check_build_deps "${TARGET_VERSION}" "${BUILD_TYPE}"

prepare_sqlcipher
build_so "${TARGET_VERSION}"

if [ "${BUILD_TYPE}" -eq 2 ]; then
    build_deb "${TARGET_VERSION}"
fi

cleanup "${TARGET_VERSION}"
print_summary "${TARGET_VERSION}"
prompt_source_cleanup "${TARGET_VERSION}"
