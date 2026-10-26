---
description: FreshRSS introduction and conventions for AI agents and human contributors
---

# FreshRSS introduction and conventions

FreshRSS is an open-source news aggregator supporting RSS/ATOM/WebSub and also Web scraping.

The market segment is mostly self-hosting, although multiple user accounts are supported.
It is supposed to be installed on a modest server (mostly, but not limited to, Linux) and can be accessed through a Web UI and an API.

It is written in PHP to make it easy to deploy and easy to contribute to.

More information can be found in [README](README.md) and in the [documentation](docs/en/) published at <https://freshrss.github.io/FreshRSS/en/>

## Instruction structure for AI agents and humans

* [`.github/instructions/`](.github/instructions/) contain the instructions that primarily match filename patterns.
* [`.github/skills/`](.github/skills/) contain the skills to achieve higher-level goals, potentially combining multiple instructions.
* **`AGENTS.md`** is the entry point description for AI coding agents and contributors, referencing other documents such as instructions and skills.
* Favour standard conventions over vendor-specific ones.
* To reduce duplication, refer to enforceable configuration files instead of excessive free-text repetitions.
* **Note:** Please limit AI-assisted pull requests to **10 open at a time** per contributor.

## Code structure

* `app/Controllers/` – Controllers extend `FreshRSS_ActionController`, named as `{name}Controller.php` with class `FreshRSS_{name}_Controller`
* `app/Models/` – Domain models extend `Minz_Model`.
	* DAOs may have some database-specific inheritance, e.g.: `*DAO.php` (base or MySQL), `*DAOSQLite.php` (SQLite), `*DAOPGSQL.php` (PostgreSQL)
* `app/views/{controller}/` – View templates are `.phtml` files mixing PHP and HTML
* `app/views/helpers/` – Reusable view elements with `$this->partial('name')`
* `lib/core-extensions/` or `extensions/` – FreshRSS extensions
* `lib/Minz/` – Core framework: routing, sessions, translations, extensions, PDO abstraction
* `lib/lib_rss.php` – Contain `spl_autoload_register` and other global functions
* `p/` – Public Web root. Only the content of this folder should be exposed if possible (`p/` should not be visible in the public URL)
	* Only the `p/i/` path should be access controlled. The main entry point is `p/i/index.php`
	* `p/api/greader.php` – Primary API for mobile clients
	* `p/api/pshb.php` – Receive realtime pushes via WebSub
	* `p/themes/` – UI themes

### Configuration data

* Constants: [`constants.php`](constants.php) overridden in `constants.local.php`
* System config: [`config.default.php`](config.default.php) overridden in `data/config.php`
* User config: [`config-user.default.php`](config-user.default.php) overridden in `data/users/{username}/config.php`

> ℹ Access via `FreshRSS_Context::systemConf()` and `FreshRSS_Context::userConf()`

## Database patterns

Three database backends supported: SQLite, PostgreSQL, MySQL/MariaDB.
The SQL differences are implemented through inheritance:

```php
// Base DAO with common queries
class FreshRSS_EntryDAO extends Minz_ModelPdo { }
// Database-specific overrides
class FreshRSS_EntryDAOSQLite extends FreshRSS_EntryDAO { }
class FreshRSS_EntryDAOPGSQL extends FreshRSS_EntryDAO { }
```

A factory pattern selects the correct DAO, e.g.:

```php
FreshRSS_Factory::createEntryDao();
```

**Important**: in database, VARCHAR/TEXT fields are HTML-encoded, except `attributes` fields, which contain JSON, and which sub-strings are not HTML-encoded.

## Main development commands

> ℹ Recommended before committing

```sh
# Runs all tests: PHPUnit, PHPCS, PHPStan, typos
make test-all

# Auto-fix all trivial issues: whitespace, RTL CSS, translations, SVG image optimization
make fix-all

# See a list of commands:
make help
```

CI/CD is defined in [`.github/workflows/tests.yml`](.github/workflows/tests.yml)

A Dev Container is available under [`.devcontainer/`](.devcontainer/).

## Docker

> ℹ Check [Docker documentation](Docker/README.md).

## CLI Tools

There are scripts in `cli/` for admin tasks, such as:

```sh
./cli/list-users.php
```

> ℹ Check [CLI documentation](cli/README.md).

When possible, it is best to run as Web server user:

```sh
sudo -u www-data cli/actualize-user.php --user alice
```

or at least re-apply the file permissions after CLI operations:

```sh
cli/access-permissions.sh
```

## Fork maintenance (karegyudon patched images)

This fork keeps upstream sources untouched on `edge`; the only behavioural change lives as a replayable patch applied at image-build time.

### What this fork changes

One file pair, `app/Utils/httpUtil.php` + `tests/app/Utils/httpUtilTest.php`: Retry-After cooldowns become **per URL for every host**, instead of upstream’s per-domain policy for public hosts
(`getRetryAfterFile()` no longer calls `Minz_Request::serverIsPublic()`; the file name is always `<host[:port]>_<sha256(url)>.txt`).
Rationale: one RSSHub instance serves hundreds of feeds behind a single public host; a single `429`/`503` would otherwise freeze the whole domain for up to `retry_after_max`.
Nothing else changes: the SSRF protection, its `INTERNAL_HOST_ALLOWLIST`, and the `Retry-After` durations are exactly upstream.

### Artifacts

* `fork/retry-after-per-url.patch` — single `git format-patch` commit (never edit it by hand; regenerate).
* `fork/build-image.sh` — `fork/build-image.sh <upstream-ref> [--push] [--check-only]`; works on any tag / `upstream/edge` / SHA.

### Routine: new upstream release

```sh
git fetch upstream --tags
fork/build-image.sh 1.30.5 --push   # -> ghcr.io/karegyudon/freshrss:1.30.5-patched
```

If `git apply --3way` fails (upstream drifted around `getRetryAfterFile()`), the build aborts with guidance; regenerate the patch on that ref and commit it to `maintenance`.
Never apply with fuzz: a half-applied security-adjacent patch is worse than a failed build.

### Production swap (manual, on the production host)

Two Compose lines, keep everything else:

```yaml
image: ghcr.io/karegyudon/freshrss:1.30.4-patched
environment:
  INTERNAL_HOST_ALLOWLIST: rsshublan.zyd.cn:1200   # space-separated host:port entries; public hosts need nothing
```

* Personal GHCR packages default to **private** on first push: either set the package to public, or `docker login ghcr.io` (PAT with `write:packages` implied `read`) on the production host before `docker compose pull`.
* Rollback = previous image tag; data lives in the `freshrss_data` volume, untouched by the swap.

### License note (AGPL-3.0)

The modified corresponding source is available at this repository, branch `maintenance` (sources on `edge`/tags plus `fork/retry-after-per-url.patch`); upstream: <https://github.com/FreshRSS/FreshRSS>.

### Lessons recorded during this work

* Diffs from release notes / older versions (the 1.30.1-era snippet with `($domainWide ? '' : …)` only) do not match 1.30.4 / `edge` sources, which since gained a `retry_after_domain_wide` static cache and an `allowDnsResolve:` named argument — always re-derive the patch from the actual target ref.
* The fork has no `git tag`s (upstream remote required for `1.30.4`), and its `docker-publish.yml` push is gated by `github.repository_owner == 'FreshRSS'` — forks can build via Actions but never push; `fork/build-image.sh` is the push path here.
* Upstream `tests.yml` triggers only on `edge` pushes — a `maintenance` branch cannot borrow CI, so run PHPUnit locally.
* Local PHP 8.1 without the `curl` extension can only run targeted test files (`httpUtilTest.php` needs no curl; `FeedTest.php` does — run it inside the built image instead).
* `data/Retry-After/` and other runtime dirs are untracked empty directories: unit tests touching them must `mkdir` first (upstream CI does it implicitly; the Docker context ships none).
* The build machine reaches registries only through an HTTP proxy while the Docker daemon points at a dead one: fetch/push images via `skopeo` with the shell proxy, build with `--network=host` + proxy `--build-arg`s so in-image `apt-get` resolves.
* A `git worktree`’s `.git` is a file while `.dockerignore` excludes the `/.git/` directory, so a 64-byte gitdir pointer ends up inside the image: harmless, but do not treat image contents as path-free.
* `php -S` access lines can be absent while the handler is active: prefer response content or handler side effects (counters) over log greps as behavioural evidence.
* Behavioural evidence of the domain-vs-per-URL split on a public-class host: official 1.30.4 writes `198.51.100.7%3A8097.txt` (blocks every feed on the host after one `429`); this fork writes `…%3A8097_<sha256>.txt` and other URLs on the same host keep updating.
* Private-IP hosts (RFC1918/loopback/link-local) are already per-URL upstream (`serverIsPublic()` → false): E2E of the domain-wide bug requires a public-class address.
