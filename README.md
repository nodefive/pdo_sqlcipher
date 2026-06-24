# PDO SQLCipher

A [PDO](http://php.net/manual/en/book.pdo.php) driver for [SQLCipher](http://sqlcipher.net) that coexists with the standard PDO SQLite extension. It is based on the PDO SQLite source code, built by replacing the SQLite library with the SQLCipher amalgamation so that encrypted databases are accessible only to applications that explicitly use this driver.

## Build scripts

| Script | Target |
|---|---|
| `build_debian.sh` | Debian / Ubuntu |
| `build_arch.sh` | Arch Linux |

Both scripts clone SQLCipher from GitHub, download the PHP source automatically, and produce a `.so` module. `build_debian.sh` additionally offers a `.deb` package output.

## Requirements

### Debian / Ubuntu

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
source. If they are not, `build_debian.sh` will detect this and print the exact
command to enable them (the format differs between Ubuntu 24.04+ DEB822
`.sources` files and the legacy `sources.list` format).

### Arch Linux

```bash
sudo pacman -S base-devel git openssl icu php autoconf
```

For older PHP versions not in the official repos, install from the AUR
(e.g. `yay -S php74`, `yay -S php83`).

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

### Debian / Ubuntu

```bash
./build_debian.sh
```

The interactive menu guides you through two selections:

1. **Output type** — `.so` module only, or `.so` + `.deb` package
2. **PHP version** — autodetect installed versions or pick from the full list

### Arch Linux

```bash
./build_arch.sh
```

The interactive menu asks for the PHP version — autodetect installed versions
or pick from the full list. Output is always a `.so` module.

If multiple PHP versions are installed, autodetect will list them and ask
which one to build for.

All output is written to `release/phpX.Y/`.

## Installation

Replace `X.Y` with the PHP version you built for (e.g. `8.3`, `8.4`, `8.5`).

### Manual (.so) — all distros

```bash
sudo cp release/phpX.Y/pdo_sqlcipher.so $(php-configX.Y --extension-dir)/
```

Add to `php.ini` or a drop-in file:

```ini
extension=pdo_sqlcipher.so
```

On Arch Linux, drop-in files live in `/etc/php/conf.d/`:

```bash
echo 'extension=pdo_sqlcipher.so' | sudo tee /etc/php/conf.d/pdo_sqlcipher.ini
```

### Via .deb package (Debian / Ubuntu only)

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

## Download Per-Compiled

You can download the pre-compiled versions of `pdo_sqlcipher` from the official releases page:

[Download Compiled pdo_sqlcipher Versions](https://github.com/nodefive/pdo_sqlcipher/releases)

## License

MIT License — Copyright (c) 2025 nodefive

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
