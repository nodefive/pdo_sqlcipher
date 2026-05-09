# PDO SQLCipher

A [PDO](http://php.net/manual/en/book.pdo.php) driver for [SQLCipher](http://sqlcipher.net) that coexists with the standard PDO SQLite extension. It is based on the PDO SQLite source code, built by replacing the SQLite library with the SQLCipher amalgamation so that encrypted databases are accessible only to applications that explicitly use this driver.

## Build scripts

`build.sh` is the only tool needed. It downloads the PHP source automatically
via `apt-get source`, clones SQLCipher from GitHub, and produces either a `.so`
module or a `.deb` package depending on what you select.

## Requirements

```bash
sudo apt install build-essential git libssl-dev libicu-dev
```

For `.deb` output, also install:

```bash
sudo apt install fakeroot lintian
```

Replace `php-dev` below with the version-specific package for the PHP you are
targeting (e.g. `php8.4-dev`, `php8.3-dev`, `php7.4-dev`):

```bash
sudo apt install php-dev
```

Source packages must be enabled so that `apt-get source` can fetch the PHP
source. If they are not, `build.sh` will detect this and print the exact
command to enable them (the format differs between Ubuntu 24.04+ DEB822
`.sources` files and the legacy `sources.list` format).

## Supported PHP versions

| Version | Zend API |
|---|---|
| 7.4 | 20190902 |
| 8.0 | 20200930 |
| 8.1 | 20210902 |
| 8.2 | 20220829 |
| 8.3 | 20230831 |
| 8.4 | 20240924 |
| 8.5 | 20250925 |

## Building

```bash
./build.sh
```

The interactive menu guides you through two selections:

1. **Output type** — `.so` module only, or `.so` + `.deb` package
2. **PHP version** — autodetect installed versions or pick from the full list

If multiple PHP versions are installed, autodetect will list them and ask
which one to build for.

All output is written to `release/phpX.Y/` — both the `.so` and the `.deb`
(when selected).

## Installation

Replace `X.Y` with the PHP version you built for (e.g. `8.3`, `8.4`, `8.5`).
The build summary printed at the end of `build.sh` shows the exact paths.

### Manual (.so)

```bash
sudo cp release/phpX.Y/pdo_sqlcipher.so $(php-configX.Y --extension-dir)/
```

Add to `php.ini` or a drop-in file:

```ini
extension=pdo_sqlcipher.so
```

### Via .deb package

```bash
sudo dpkg -i release/phpX.Y/phpX.Y-sqlcipher.deb
sudo phpenmod pdo_sqlcipher
```

`phpenmod` symlinks the ini from `mods-available` into every SAPI's `conf.d`
(cli, fpm, apache2, cgi, etc.) in one step.

## Verification

```bash
php -m | grep -i sqlcipher
```
