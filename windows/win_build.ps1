# ==============================================================================
# Complete Auto-Setup & Compilation Script for PHP PDO SQLCipher on Windows
# Supported PHP Versions: 8.0, 8.1, 8.2, 8.3, 8.4, 8.5
# ==============================================================================

$ErrorActionPreference = "Stop"

# Set encoding to UTF8 to support Unicode checkmarks/crosses in console
[System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Default configuration values
[string]$PHP_VERSION = "8.5"
$BUILD_FLAG = $false
$CHECK_FLAG = $false
$CLEAN_FLAG = $false

# ------------------------------------------------------------------------------
# 1. Custom Argument Parsing
# ------------------------------------------------------------------------------
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq "-b") {
        $BUILD_FLAG = $true
        # Check if next argument is a version string
        if ($i + 1 -lt $args.Count -and $args[$i+1] -match "^8\.[0-5]$") {
            $PHP_VERSION = [string]$args[$i+1]
            $i++
        }
    } elseif ($args[$i] -eq "-k") {
        $CHECK_FLAG = $true
    } elseif ($args[$i] -eq "-c") {
        $CLEAN_FLAG = $true
    }
}

# If no flags are passed, show usage guide
if (-not $BUILD_FLAG -and -not $CHECK_FLAG -and -not $CLEAN_FLAG) {
    Write-Host "PHP PDO SQLCipher Windows Build Script" -ForegroundColor Cyan
    Write-Host "Usage: .\win_build.ps1 [-b [version]] [-k] [-c]" -ForegroundColor Cyan
    Write-Host "  -b [version]  Build the pdo_sqlcipher extension (versions: 8.0 to 8.5, default: 8.5)" -ForegroundColor Gray
    Write-Host "  -k            Verify system dependencies and attempt auto-installation" -ForegroundColor Gray
    Write-Host "  -c            Clean temporary build files, SDK, and caches" -ForegroundColor Gray
    exit 0
}

# ------------------------------------------------------------------------------
# 2. Clean Environment Function (-c flag)
# ------------------------------------------------------------------------------
function Cleanup-Environment {
    Write-Host "=== Cleaning Build Environment ===" -ForegroundColor Cyan
    $sdkDir = Join-Path $PSScriptRoot "php-sdk"
    if (Test-Path $sdkDir) {
        Write-Host "Removing existing php-sdk folder..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force $sdkDir -ErrorAction SilentlyContinue
    }
    
    $phpInstallDir = Join-Path $PSScriptRoot "php$($PHP_VERSION.Replace('.', ''))"
    if (Test-Path $phpInstallDir) {
        Write-Host "Removing existing PHP installation folder $phpInstallDir..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force $phpInstallDir -ErrorAction SilentlyContinue
    }
    Write-Host "Cleanup completed successfully." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 3. Dependency Checking and Installation (-k flag)
# ------------------------------------------------------------------------------
function Check-Dependencies {
    $missing = @()
    
    # Declare checkmark and cross dynamically to prevent parser issues on ANSI hosts
    $checkmark = [char]0x2713
    $cross = [char]0x2717

    # Determine MSVC compiler version based on selected PHP version
    # PHP 8.0-8.3 compiled with VS16 (Visual Studio 2019), PHP 8.4+ with VS17 (Visual Studio 2022)
    $vs_ver_tag = "vs17"
    if ($PHP_VERSION -match "^8\.[0-3]$") {
        $vs_ver_tag = "vs16"
    }

    # Check MSVC C++ compiler tools using vswhere
    $vswherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsToolsFound = $false

    if (Test-Path $vswherePath) {
        if ($vs_ver_tag -eq "vs16") {
            # Check for VS 2019 with C++ Tools, or VS 2022 with MSVC v142 build tools
            $check2019 = [string]::IsNullOrEmpty((& $vswherePath -nologo -products * -version "[16.0,17.0)" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64)) -eq $false
            $check2022Compat = [string]::IsNullOrEmpty((& $vswherePath -nologo -products * -version "[17.0,18.0)" -requires Microsoft.VisualStudio.Component.VC.14.29.16.9.Lx)) -eq $false
            # Fallback check: Allow default VS 2022 tools to build legacy versions as well
            $check2022Default = [string]::IsNullOrEmpty((& $vswherePath -nologo -products * -version "[17.0,18.0)" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64)) -eq $false
            if ($check2019 -or $check2022Compat -or $check2022Default) {
                $vsToolsFound = $true
            }
        } else {
            # Check for VS 2022 with C++ Tools
            $vsToolsFound = [string]::IsNullOrEmpty((& $vswherePath -nologo -products * -version "[17.0,18.0)" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64)) -eq $false
        }
    }

    if ($vsToolsFound) {
        Write-Host "  $checkmark MSVC C++ Compiler Tools ($vs_ver_tag)" -ForegroundColor Green
    } else {
        Write-Host "  $cross MSVC C++ Compiler Tools ($vs_ver_tag) (Visual Studio C++ build tools)" -ForegroundColor Red
        $missing += "MSVC C++ Compiler Tools ($vs_ver_tag)"
    }

    # Check Git
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Host "  $checkmark Git" -ForegroundColor Green
    } else {
        Write-Host "  $cross Git (https://git-scm.com/)" -ForegroundColor Red
        $missing += "Git (https://git-scm.com/)"
    }

    # Check WSL
    $wslAvailable = $false
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        Write-Host "  $checkmark WSL (Windows Subsystem for Linux)" -ForegroundColor Green
        $wslAvailable = $true
    } else {
        Write-Host "  $cross WSL (Windows Subsystem for Linux)" -ForegroundColor Red
        $missing += "WSL (Windows Subsystem for Linux)"
    }

    # Check WSL Distro
    if ($wslAvailable) {
        $distroWorking = $false
        try {
            $wslTest = wsl -e echo "test" 2>$null
            if ($wslTest -eq "test") {
                $distroWorking = $true
            }
        } catch {}

        if ($distroWorking) {
            Write-Host "  $checkmark Working WSL Linux Distribution" -ForegroundColor Green
        } else {
            Write-Host "  $cross Working WSL Linux Distribution (e.g. Ubuntu)" -ForegroundColor Red
            $missing += "Working WSL Linux Distribution (e.g. Ubuntu)"
        }
    } else {
        Write-Host "  $cross Working WSL Linux Distribution" -ForegroundColor Red
        $missing += "Working WSL Linux Distribution (e.g. Ubuntu)"
    }

    return $missing
}

function Print-ManualGuide($missing) {
    Write-Host "=========================================================================" -ForegroundColor Yellow
    Write-Host "                     MANUAL INSTALLATION GUIDE" -ForegroundColor Yellow
    Write-Host "=========================================================================" -ForegroundColor Yellow
    Write-Host "Please install the following missing dependencies manually:" -ForegroundColor Yellow
    foreach ($dep in $missing) {
        Write-Host "  - $dep" -ForegroundColor Yellow
    }
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Instructions:" -ForegroundColor Yellow
    
    $hasMsvc = $false
    foreach ($dep in $missing) {
        if ($dep -like "*MSVC*") { $hasMsvc = $true }
    }
    if ($hasMsvc) {
        Write-Host "  1. MSVC Compiler: Install Visual Studio Build Tools and select the" -ForegroundColor Yellow
        Write-Host "     'Desktop development with C++' workload." -ForegroundColor Yellow
    }
    Write-Host "  2. Git: Download and install from https://git-scm.com/download/win" -ForegroundColor Yellow
    Write-Host "  3. WSL: Open PowerShell as Administrator and run: wsl --install" -ForegroundColor Yellow
    Write-Host "     After installation, restart your computer and install a Linux distro (e.g., Ubuntu)." -ForegroundColor Yellow
    Write-Host "=========================================================================" -ForegroundColor Yellow
}

function Install-Dependencies {
    Write-Host "Checking system dependencies and tools:" -ForegroundColor Cyan
    $missing = Check-Dependencies
    if ($missing.Count -eq 0) {
        Write-Host ""
        return
    }

    Write-Host ""
    Write-Host "Missing dependencies detected. Attempting to install them automatically..." -ForegroundColor Yellow
    
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] Windows Package Manager (winget) is not available. Please install manually." -ForegroundColor Red
        Print-ManualGuide $missing
        exit 0
    }

    Write-Host "Attempting to install missing dependencies automatically using winget..." -ForegroundColor Cyan

    foreach ($dep in $missing) {
        if ($dep -like "*MSVC*") {
            if ($dep -like "*vs16*") {
                Write-Host "Installing Visual Studio 2019 Build Tools (C++ Workload)..." -ForegroundColor Cyan
                Start-Process "winget" -ArgumentList "install --id Microsoft.VisualStudio.2019.BuildTools --override `"--passive --add Microsoft.VisualStudio.Workload.VCTools`" --accept-source-agreements --accept-package-agreements" -NoNewWindow -Wait
            } else {
                Write-Host "Installing Visual Studio 2022 Build Tools (C++ Workload)..." -ForegroundColor Cyan
                Start-Process "winget" -ArgumentList "install --id Microsoft.VisualStudio.2022.BuildTools --override `"--passive --add Microsoft.VisualStudio.Workload.VCTools`" --accept-source-agreements --accept-package-agreements" -NoNewWindow -Wait
            }
        } elseif ($dep -like "*Git*") {
            Write-Host "Installing Git..." -ForegroundColor Cyan
            Start-Process "winget" -ArgumentList "install --id Git.Git -e --silent --accept-source-agreements --accept-package-agreements" -NoNewWindow -Wait
        } elseif ($dep -like "*WSL*") {
            Write-Host "Installing WSL (requires administrator elevation)..." -ForegroundColor Cyan
            # Elevate to install WSL
            Start-Process "powershell" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command wsl --install --no-distribution" -Verb RunAs -Wait
        }
    }

    # Re-verify
    Write-Host "Re-verifying dependencies:" -ForegroundColor Cyan
    $missingAfter = Check-Dependencies
    if ($missingAfter.Count -eq 0) {
        Write-Host "All dependencies successfully installed!" -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host "[ERROR] Could not install all dependencies automatically." -ForegroundColor Red
        Print-ManualGuide $missingAfter
        exit 0
    }
}

# ------------------------------------------------------------------------------
# 4. Core Build & Compilation Logic
# ------------------------------------------------------------------------------
function Build-Extension {
    # Ensure dependencies are met
    Install-Dependencies

    Write-Host "=== Starting Setup and Compilation for PHP $PHP_VERSION ===" -ForegroundColor Cyan

    # Establish localized SDK directory
    $sdkDir = Join-Path $PSScriptRoot "php-sdk"

    # Determine compiler version based on PHP version
    # PHP 8.0-8.3 compiled with VS16 (Visual Studio 2019), PHP 8.4+ with VS17 (Visual Studio 2022)
    $vs_version = "vs17"
    if ($PHP_VERSION -match "^8\.[0-3]$") {
        $vs_version = "vs16"
        
        # Fallback to vs17 if vs16 compiler tools are not installed
        $vswherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path $vswherePath) {
            $check2019 = [string]::IsNullOrEmpty((& $vswherePath -nologo -products * -version "[16.0,17.0)" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64)) -eq $false
            $check2022Compat = [string]::IsNullOrEmpty((& $vswherePath -nologo -products * -version "[17.0,18.0)" -requires Microsoft.VisualStudio.Component.VC.14.29.16.9.Lx)) -eq $false
            if (-not $check2019 -and -not $check2022Compat) {
                # vs16 compiler tools not found. Check if vs17 (VS 2022) tools are available
                $check2022Default = [string]::IsNullOrEmpty((& $vswherePath -nologo -products * -version "[17.0,18.0)" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64)) -eq $false
                if ($check2022Default) {
                    Write-Host "VS 2019 (vs16) compiler tools not found. Falling back to VS 2022 (vs17) compiler..." -ForegroundColor Yellow
                    $vs_version = "vs17"
                }
            }
        }
    }

    # Clone PHP SDK if missing (check for crucial files to verify completeness)
    if (-not (Test-Path $sdkDir) -or -not (Test-Path (Join-Path $sdkDir "phpsdk-starter.bat"))) {
        Write-Host "Cloning PHP SDK Binary Tools..." -ForegroundColor Cyan
        if (Test-Path $sdkDir) {
            Remove-Item -Recurse -Force $sdkDir -ErrorAction SilentlyContinue
        }
        git clone https://github.com/php/php-sdk-binary-tools.git $sdkDir
    }

    $buildTreeDir = Join-Path $sdkDir "phpmaster\$vs_version\x64"
    $phpSrcDir = Join-Path $buildTreeDir "php-src-$PHP_VERSION"
    $depsDir = Join-Path $buildTreeDir "deps"
    $tempDir = Join-Path $buildTreeDir "deps-temp"

    # Create directories
    New-Item -ItemType Directory -Force $buildTreeDir | Out-Null
    New-Item -ItemType Directory -Force $depsDir | Out-Null
    New-Item -ItemType Directory -Force $tempDir | Out-Null

    # Clone PHP Source Code
    if (-not (Test-Path $phpSrcDir)) {
        Write-Host "Cloning PHP source code (depth 1)..." -ForegroundColor Cyan
        
        # Determine target branch. Fallback to master if version-specific branch does not exist
        $branch = "PHP-$PHP_VERSION"
        Write-Host "Checking if branch $branch exists on remote..." -ForegroundColor Cyan
        $branchExists = git ls-remote --heads https://github.com/php/php-src.git $branch
        if (-not $branchExists) {
            Write-Host "Branch $branch not found. Falling back to master branch." -ForegroundColor Yellow
            $branch = "master"
        }

        git clone --depth 1 --branch $branch https://github.com/php/php-src.git $phpSrcDir
    }

    # Download OpenSSL & Zlib Dependencies dynamically from windows.php.net
    $opensslPkg = $null
    $zlibPkg = $null

    try {
        $baseUrl = "https://windows.php.net/downloads/php-sdk/deps/$vs_version/x64/"
        Write-Host "Querying $baseUrl for latest packages..." -ForegroundColor Cyan
        
        $html = Invoke-WebRequest -Uri $baseUrl -UseBasicParsing -UserAgent "Mozilla/5.0" -TimeoutSec 10
        $links = $html.Links | Where-Object { $_.href -match "\.zip$" } | Select-Object -ExpandProperty href

        # Find latest OpenSSL
        if ($vs_version -eq "vs16") {
            $opensslPkg = $links | Where-Object { $_ -match "^openssl-1\..*-x64\.zip$" } | Sort-Object | Select-Object -Last 1
        } else {
            $opensslPkg = $links | Where-Object { $_ -match "^openssl-3\..*-x64\.zip$" } | Sort-Object | Select-Object -Last 1
        }
        
        # Find latest Zlib 1.x
        $zlibPkg = $links | Where-Object { $_ -match "^zlib-1\..*-x64\.zip$" } | Sort-Object | Select-Object -Last 1
    } catch {
        Write-Host "Warning: Failed to fetch latest package names from windows.php.net ($($_.Exception.Message)). Using default stable versions." -ForegroundColor Yellow
    }

    # Fallbacks in case scraping fails or times out
    if (-not $opensslPkg) {
        if ($vs_version -eq "vs16") {
            $opensslPkg = "openssl-1.1.1q-vs16-x64.zip"
        } else {
            $opensslPkg = "openssl-3.5.6-vs17-x64.zip"
        }
    }
    if (-not $zlibPkg) {
        if ($vs_version -eq "vs16") {
            $zlibPkg = "zlib-1.2.12-vs16-x64.zip"
        } else {
            $zlibPkg = "zlib-1.3.2-vs17-x64.zip"
        }
    }

    $packages = @($opensslPkg, $zlibPkg)
    foreach ($pkg in $packages) {
        $url = "https://windows.php.net/downloads/php-sdk/deps/$vs_version/x64/" + $pkg
        $dest = Join-Path $tempDir $pkg
        Write-Host "Downloading $pkg..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $dest -UserAgent "Mozilla/5.0"
        
        Write-Host "Extracting $pkg..." -ForegroundColor Green
        Expand-Archive -Path $dest -DestinationPath $depsDir -Force
    }
    Remove-Item -Recurse -Force $tempDir

    # Generate SQLCipher Amalgamation using WSL
    Write-Host "Running WSL to generate SQLCipher amalgamation..." -ForegroundColor Cyan
    # Install build tools in WSL only if they are not already present (run as root to prevent sudo password prompt).
    wsl -u root -e bash -c 'if ! command -v autoconf >/dev/null || ! command -v libtool >/dev/null || ! command -v make >/dev/null || ! command -v tclsh >/dev/null; then apt-get update && apt-get install -y autoconf libtool make tclsh tcl libssl-dev; fi'
    if ($LASTEXITCODE -ne 0) { throw "WSL package installation failed." }

    # Clean previous build if any
    wsl -e bash -c 'rm -rf /tmp/sqlcipher'
    if ($LASTEXITCODE -ne 0) { throw "Failed to clean SQLCipher build directory in WSL." }

    # Clone SQLCipher
    wsl -e bash -c 'git clone --depth 1 --branch v4.16.0 https://github.com/sqlcipher/sqlcipher.git /tmp/sqlcipher'
    if ($LASTEXITCODE -ne 0) { throw "Failed to clone SQLCipher in WSL." }

    # Configure SQLCipher (using single quotes for CFLAGS to prevent parameter stripping)
    wsl -e bash -c "cd /tmp/sqlcipher && ./configure --disable-shared CFLAGS='-DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 -DSQLCIPHER_CRYPTO_OPENSSL' LDFLAGS='-lcrypto'"
    if ($LASTEXITCODE -ne 0) { throw "Failed to configure SQLCipher in WSL." }

    # Compile SQLCipher sqlite3.c amalgamation
    wsl -e bash -c 'cd /tmp/sqlcipher && make sqlite3.c'
    if ($LASTEXITCODE -ne 0) { throw "Failed to generate sqlite3.c amalgamation in WSL." }

    # Get WSL path of sdkDir dynamically
    $cleanPath = $sdkDir.Replace('\', '/')
    $wslSdkDirRaw = wsl -e bash -c "wslpath -u '$cleanPath'"
    if ($wslSdkDirRaw) {
        $wslSdkDir = "$wslSdkDirRaw".Trim()
    } else {
        throw "wslpath failed to convert path $sdkDir"
    }

    # Copy Amalgamation files from WSL
    Write-Host "Copying amalgamation files from WSL to Windows..." -ForegroundColor Cyan
    $extDir = Join-Path $phpSrcDir "ext\pdo_sqlcipher"
    New-Item -ItemType Directory -Force $extDir | Out-Null

    wsl -e bash -c "cp /tmp/sqlcipher/sqlite3.c $wslSdkDir/phpmaster/$vs_version/x64/php-src-$PHP_VERSION/ext/pdo_sqlcipher/sqlcipher3.c"
    wsl -e bash -c "cp /tmp/sqlcipher/sqlite3.h $wslSdkDir/phpmaster/$vs_version/x64/php-src-$PHP_VERSION/ext/pdo_sqlcipher/sqlcipher3.h"

    # Copy and Rename pdo_sqlite files to pdo_sqlcipher
    Write-Host "Copying and renaming pdo_sqlite files..." -ForegroundColor Cyan
    $src = Join-Path $phpSrcDir "ext\pdo_sqlite"
    Copy-Item "$src\*.c", "$src\*.h", "$src\*.re", "$src\*.w32", "$src\*.frag", "$src\CREDITS" -Destination $extDir -Force -ErrorAction SilentlyContinue

    # Process files for renaming
    $files = Get-ChildItem $extDir -File | Where-Object { $_.Name -notin @("sqlcipher3.c", "sqlcipher3.h", "config.w32") }

    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f.FullName)

        $text = $text -creplace 'PDO_SQLITE',  'PDO_SQLCIPHER'
        $text = $text -creplace 'pdo_sqlite',  'pdo_sqlcipher'
        $text = $text -creplace 'SQLite3',     'SQLCipher3'
        $text = $text -creplace 'SQLite',      'SQLCipher'
        $text = $text -creplace 'Sqlite',      'SQLCipher'
        $text = $text -creplace 'sqlite_',     'sqlcipher_'
        $text = $text -creplace 'sqlite3.h',   'sqlcipher3.h'
        $text = $text -creplace 'PDO_DRIVER_HEADER\(sqlite\)', 'PDO_DRIVER_HEADER(sqlcipher)'

        [IO.File]::WriteAllText($f.FullName, $text)
    }

    # Fix inclusion inside the SQLCipher amalgamation source file itself
    $amalgC = Join-Path $extDir "sqlcipher3.c"
    if (Test-Path $amalgC) {
        $text = [IO.File]::ReadAllText($amalgC)
        $text = $text -creplace '#include "sqlite3.h"', '#include "sqlcipher3.h"'
        [IO.File]::WriteAllText($amalgC, $text)
    }

    # Rename files on disk
    $renames = @{
        "pdo_sqlite.c"             = "pdo_sqlcipher.c"
        "sqlite_driver.c"          = "sqlcipher_driver.c"
        "sqlite_statement.c"       = "sqlcipher_statement.c"
        "sqlite_sql_parser.re"     = "sqlcipher_sql_parser.re"
        "sqlite_sql_parser.c"      = "sqlcipher_sql_parser.c"
        "php_pdo_sqlite_int.h"     = "php_pdo_sqlcipher_int.h"
        "php_pdo_sqlite.h"         = "php_pdo_sqlcipher.h"
        "pdo_sqlite_arginfo.h"     = "pdo_sqlcipher_arginfo.h"
        "sqlite_driver_arginfo.h"  = "sqlcipher_driver_arginfo.h"
    }

    foreach ($old in $renames.Keys) {
        $oldPath = Join-Path $extDir $old
        if (Test-Path $oldPath) {
            Rename-Item $oldPath (Join-Path $extDir $renames[$old]) -Force -ErrorAction SilentlyContinue
        }
    }

    # Fix standard library helpers compilation issues if present
    $fragPath = Join-Path $phpSrcDir "ext\standard\Makefile.frag.w32"
    if (Test-Path $fragPath) {
        $text = [IO.File]::ReadAllText($fragPath)
        $text = $text -replace '(?m)cd \$\(PHP_SRC_DIR\)\\ext\\standard\\tests\\helpers\r?\n\t\$\(PHP_CL\) /nologo bad_cmd\.c', '$(PHP_CL) /nologo /Fo$(PHP_SRC_DIR)\ext\standard\tests\helpers\bad_cmd.obj /Fe$(PHP_SRC_DIR)\ext\standard\tests\helpers\bad_cmd.exe $(PHP_SRC_DIR)\ext\standard\tests\helpers\bad_cmd.c'
        [IO.File]::WriteAllText($fragPath, $text)
    }

    # Write config.w32 (wrapped in standard single quotes to avoid parser errors)
    Write-Host "Writing config.w32..." -ForegroundColor Cyan
    
    $parserFile = ""
    if ($PHP_VERSION -match "^8\.[4-5]$") {
        $parserFile = "sqlcipher_sql_parser.c "
    }

    $configContent = '// vim:ft=javascript

ARG_ENABLE("pdo_sqlcipher", "PDO: SQLCipher driver (bundled)", "no");

if (PHP_PDO_SQLCIPHER != "no") {
    if (PHP_PDO == "no" && PHP_PDO_SQLCIPHER == "yes") {
        ERROR("pdo_sqlcipher requires PDO; add --enable-pdo to configure");
    }

    var CIPHER_FLAGS = [
        "/DSQLITE_HAS_CODEC",
        "/DSQLCIPHER_CRYPTO_OPENSSL",
        "/DSQLITE_EXTRA_INIT=sqlcipher_extra_init",
        "/DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown",
        "/DSQLITE_ENABLE_FTS3",
        "/DSQLITE_ENABLE_FTS3_PARENTHESIS",
        "/DSQLITE_ENABLE_FTS5",
        "/DSQLITE_ENABLE_JSON1",
        "/DSQLITE_ENABLE_RTREE",
        "/DSQLITE_ENABLE_COLUMN_METADATA",
        "/DSQLITE_ENABLE_UPDATE_DELETE_LIMIT",
        "/DSQLITE_SECURE_DELETE",
        "/DSQLITE_DEFAULT_FOREIGN_KEYS=1",
        "/DSQLITE_TEMP_STORE=2",
        "/DSQLITE_THREADSAFE=1",
        "/DZEND_ENABLE_STATIC_TSRMLS_CACHE=1",
        "/I " + configure_module_dirname,
    ].join(" ");

    EXTENSION(
        "pdo_sqlcipher",
        "pdo_sqlcipher.c sqlcipher_driver.c sqlcipher_statement.c " +
        "%%PARSER_FILE%%sqlcipher3.c",
        PHP_PDO_SQLCIPHER_SHARED,
        CIPHER_FLAGS
    );

    ADD_EXTENSION_DEP("pdo_sqlcipher", "pdo");
    ADD_FLAG("LIBS", "libcrypto.lib Bcrypt.lib");

    AC_DEFINE("HAVE_SQLITE3_COLUMN_TABLE_NAME", 1, "sqlite3_column_table_name is available");
    AC_DEFINE("HAVE_SQLITE3_CLOSE_V2", 1, "sqlite3_close_v2 is available");
    AC_DEFINE("HAVE_PDO_SQLCIPHER", 1, "PDO: SQLCipher driver");

    ADD_MAKEFILE_FRAGMENT();
}'
    $configContent = $configContent.Replace("%%PARSER_FILE%%", $parserFile)
    $configPath = Join-Path $extDir "config.w32"
    [IO.File]::WriteAllText($configPath, $configContent)

    # Compile and Install PHP
    Write-Host "Compiling and installing PHP (this will take a few minutes)..." -ForegroundColor Cyan
    $phpInstallDir = Join-Path $PSScriptRoot "php$($PHP_VERSION.Replace('.', ''))"
    $buildScriptPath = Join-Path $phpSrcDir "build_task.bat"
    $buildScriptContent = "@echo off
cd $phpSrcDir
call buildconf --force
call configure --disable-all --enable-cli --enable-pdo --enable-pdo_sqlcipher=shared --disable-zts --with-prefix=`"$phpInstallDir`"
nmake
nmake install"
    [IO.File]::WriteAllText($buildScriptPath, $buildScriptContent)

    # Run build in PHP SDK shell environment initializer
    $sdk_bat = Join-Path $sdkDir "phpsdk-$vs_version-x64.bat"
    if (-not (Test-Path $sdk_bat)) {
        if ($vs_version -eq "vs16" -and (Test-Path (Join-Path $sdkDir "phpsdk-vs17-x64.bat"))) {
            Write-Host "phpsdk-vs16-x64.bat not found. Attempting fallback compiler vs17..." -ForegroundColor Yellow
            $vs_version = "vs17"
            $sdk_bat = Join-Path $sdkDir "phpsdk-vs17-x64.bat"
        } else {
            throw "PHP SDK environment initializer $sdk_bat was not found."
        }
    }
    
    $cmdLine = "$sdk_bat -t `"$buildScriptPath`""
    cmd.exe /c $cmdLine
    $exitCode = $LASTEXITCODE
    Remove-Item -Force $buildScriptPath -ErrorAction SilentlyContinue

    if ($exitCode -ne 0) {
        throw "NMake compilation and install failed with exit code $exitCode."
    }

    # Copy OpenSSL runtime DLLs to PHP folder so extension can be loaded
    Write-Host "Copying OpenSSL runtime DLLs to $phpInstallDir..." -ForegroundColor Cyan
    $depsBin = Join-Path $sdkDir "phpmaster\$vs_version\x64\deps\bin"
    if (Test-Path $phpInstallDir) {
        Copy-Item (Join-Path $depsBin "libcrypto-*-x64.dll") -Destination $phpInstallDir -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $depsBin "libssl-*-x64.dll") -Destination $phpInstallDir -Force -ErrorAction SilentlyContinue
        
        # Copy built dll to ./release/phpV/
        $releaseDir = Join-Path $PSScriptRoot "release\php$PHP_VERSION"
        New-Item -ItemType Directory -Force $releaseDir | Out-Null
        $dllSrcPath = Join-Path $phpInstallDir "ext\php_pdo_sqlcipher.dll"
        if (Test-Path $dllSrcPath) {
            Copy-Item $dllSrcPath -Destination (Join-Path $releaseDir "php_pdo_sqlcipher.dll") -Force
        }

        Write-Host "=== Auto-Setup & Compilation Completed Successfully ===" -ForegroundColor Green
        Write-Host "PHP $PHP_VERSION NTS x64 has been installed to $phpInstallDir" -ForegroundColor Green
        Write-Host "php_pdo_sqlcipher.dll is installed to $phpInstallDir\ext\php_pdo_sqlcipher.dll" -ForegroundColor Green
        if (Test-Path (Join-Path $releaseDir "php_pdo_sqlcipher.dll")) {
            Write-Host "php_pdo_sqlcipher.dll has been copied to: $releaseDir\php_pdo_sqlcipher.dll" -ForegroundColor Green
        }
        Write-Host "You can test it by running: $phpInstallDir\php.exe -m" -ForegroundColor Cyan
    } else {
        throw "Compilation finished but target installation directory $phpInstallDir was not created."
    }
}

# ==============================================================================
# 5. Execution Flow
# ==============================================================================
try {
    if ($CLEAN_FLAG) {
        Cleanup-Environment
        if (-not $BUILD_FLAG -and -not $CHECK_FLAG) { exit 0 }
    }

    if ($CHECK_FLAG) {
        Install-Dependencies
        if (-not $BUILD_FLAG) { exit 0 }
    }

    if ($BUILD_FLAG) {
        Build-Extension
    }
} catch {
    Write-Error "CRITICAL FAILURE: $_"
    exit 1
}
