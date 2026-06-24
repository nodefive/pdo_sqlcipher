# Windows Build Script

Automated build script to compile the `php_pdo_sqlcipher` PHP extension for Windows (x64 NTS), targeting PHP versions **8.0 through 8.5**.

## Requirements

| Dependency | Notes |
|---|---|
| **Windows 10/11 x64** | 64-bit only |
| **PowerShell 5.1+** | Included in Windows 10/11 |
| **Git for Windows** | [git-scm.com](https://git-scm.com/download/win) |
| **WSL** (Windows Subsystem for Linux) | `wsl --install` in an admin PowerShell |
| **WSL Linux distro** (e.g. Ubuntu) | Must be functional (`wsl -e echo test`) |
| **Visual Studio 2022 Build Tools** *(PHP 8.4–8.5)* | VS17 — `Desktop development with C++` workload |
| **Visual Studio 2019 Build Tools** *(PHP 8.0–8.3)* | VS16 — `Desktop development with C++` workload; VS17 is accepted as a fallback |

> **Tip:** Run `.\win_build.ps1 -k` to automatically check and install missing dependencies via `winget`.

## Usage

```powershell
.\win_build.ps1 [-b [version]] [-k] [-c]
```

| Flag | Description |
|---|---|
| `-b [version]` | Build the `pdo_sqlcipher` extension. Optional version: `8.0` – `8.5` (default: `8.5`) |
| `-k` | Verify system dependencies and attempt automatic installation via `winget` |
| `-c` | Clean temporary build artifacts (`php-sdk/` and `php<version>/` directories) |

### Examples

```powershell
# Check and install missing dependencies
.\win_build.ps1 -k

# Build for PHP 8.4 (default)
.\win_build.ps1 -b

# Build for a specific PHP version
.\win_build.ps1 -b 8.2

# Clean build artifacts, then build for PHP 8.3
.\win_build.ps1 -c -b 8.3
```

## How It Works

1. **Dependency check** (`-k` / auto-triggered by `-b`)  
   Verifies that MSVC compiler tools, Git, WSL, and a working WSL distro are present. Attempts auto-install via `winget` for any missing item.

2. **PHP SDK clone**  
   Clones [php/php-sdk-binary-tools](https://github.com/php/php-sdk-binary-tools) into `./php-sdk/` if not already present.

3. **PHP source clone**  
   Shallow-clones the matching `PHP-<version>` branch from [php/php-src](https://github.com/php/php-src) into the SDK build tree. Falls back to `master` if the branch does not exist.

4. **Dependency download**  
   Downloads the latest **OpenSSL** and **Zlib** pre-built packages for the target compiler from `windows.php.net/downloads/php-sdk/deps/`.  
   - PHP 8.0–8.3 → OpenSSL 1.x (vs16)  
   - PHP 8.4–8.5 → OpenSSL 3.x (vs17)

5. **SQLCipher amalgamation** (via WSL)  
   Clones [sqlcipher/sqlcipher](https://github.com/sqlcipher/sqlcipher) at tag **v4.16.0**, configures with `SQLITE_HAS_CODEC` / `SQLCIPHER_CRYPTO_OPENSSL`, and generates `sqlite3.c` inside WSL.

6. **Extension preparation**  
   - Copies `pdo_sqlite` source files from the PHP tree into `ext/pdo_sqlcipher/`  
   - Performs a full symbol rename (`pdo_sqlite` → `pdo_sqlcipher`, `SQLite` → `SQLCipher`, etc.)  
   - Writes a `config.w32` build descriptor with all required SQLCipher compile-time flags

7. **Compilation**  
   Runs `buildconf`, `configure`, `nmake`, and `nmake install` inside the PHP SDK shell (`phpsdk-vs1X-x64.bat`), producing a minimal PHP NTS x64 installation with `pdo_sqlcipher` as a shared extension.

8. **Output**  
   - Release copy: `.\release\php<version>\php_pdo_sqlcipher.dll`  
   - OpenSSL DLLs (`libcrypto-*-x64.dll`, `libssl-*-x64.dll`) copied next to `php.exe`

## Output Structure

```
.
├── win_build.ps1
├── php-sdk/               ← PHP SDK binary tools (cloned)
├── php80/                 ← Full PHP 8.0 install (example)
│   ├── php.exe
│   ├── libcrypto-*.dll
└── release/
    ├── php8.0/
    │   └── php_pdo_sqlcipher.dll
    ├── php8.1/
    │   └── php_pdo_sqlcipher.dll
    └── ...
```

## Compiler Compatibility

| PHP Version | Required Compiler | Fallback |
|---|---|---|
| 8.0 – 8.3 | VS16 (Visual Studio 2019) | VS17 (Visual Studio 2022) accepted |
| 8.4 – 8.5 | VS17 (Visual Studio 2022) | — |

## License

This build script is provided as-is under the [MIT License](LICENSE).  
PHP is licensed under the [PHP License](https://www.php.net/license/).  
SQLCipher is licensed under the [BSD-style SQLCipher License](https://github.com/sqlcipher/sqlcipher/blob/master/LICENSE).  
OpenSSL is licensed under the [Apache License 2.0](https://www.openssl.org/source/license.html).
