# Tests

Two separate workflows live here: a **dev environment** for manual testing and a **sanity build test** for verifying the extension compiles correctly across all PHP versions.

## Requirements

- Docker
- Docker Compose

## Dev environment

A single container running Apache + PHP-FPM for all supported versions (7.4–8.5) simultaneously. Apache proxies requests through a symlinked socket so you can switch the active PHP version on the fly without restarting anything.

**Requires pre-built `.so` files** in `release/phpX.Y/` (one per version) before building the image. Run `build.sh` from the project root first.

### Commands

All commands are run from the `tests/` directory:

```bash
./dev.sh build              # Build the dev image
./dev.sh up                 # Start the container on http://localhost:10000
./dev.sh down               # Stop and remove the container
./dev.sh php <version>      # Switch active PHP version (e.g. ./dev.sh php 8.4)
./dev.sh bash               # Shell into the running container
./dev.sh run-bash           # Start a fresh container and drop into a shell
```

The `www/` directory is mounted as the web root, so changes to PHP files are reflected immediately without rebuilding.

### Useful URLs

| URL | Purpose |
|---|---|
| `http://localhost:10000/` | Main app (Guardian Vault) |
| `http://localhost:10000/info.php` | `phpinfo()` — confirms active PHP version and loaded extensions |

### Switching PHP versions

```bash
./dev.sh php 8.3
./dev.sh php 7.4
```

This runs `switch-php` inside the container, which repoints the Apache FPM socket symlink and does a graceful Apache reload. No container restart needed.

## Sanity build test

Uses `Dockerfile.test` to build `pdo_sqlcipher.so` for each PHP version inside a clean Docker container, verifying the full build pipeline works end to end.

```bash
# Test all versions
./dev.sh test

# Test specific versions
./dev.sh test 8.4 8.5
```

Compiled `.so` files are saved to `tests/compiled_tests/phpX.Y/` and build logs to `tests/docker-logs/phpX.Y.log`.

Results are printed as `PASS`, `FAIL`, or `SKIP` (skip means the PHP version is not yet available in the ondrej PPA).
