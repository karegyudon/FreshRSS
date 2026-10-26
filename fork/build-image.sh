#!/usr/bin/env bash
# Build a patched FreshRSS Docker image from any upstream ref.
#
# Applies fork/retry-after-per-url.patch (per-URL Retry-After for all hosts)
# onto a detached worktree of the requested ref, then builds the Debian image
# tagged ghcr.io/karegyudon/freshrss:<FRESHRSS_VERSION>-patched.
#
# Usage: fork/build-image.sh <upstream-ref> [--push] [--check-only]
#   <upstream-ref>  any git rev: tag (1.30.4), branch (upstream/edge), commit
#   --push          push the image to ghcr (docker push, skopeo fallback)
#   --check-only    resolve ref + apply patch + print image name, no build
#
# On patch conflict the script exits non-zero with regeneration guidance:
# never force-apply with fuzz.
#
# Note: this build context includes the worktree's .git pointer file (64 bytes,
# a path string), because .dockerignore only excludes .git/ directories.
# This mirrors how official images ship a tiny amount of path metadata; harmless.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$REPO_ROOT/fork/retry-after-per-url.patch"
REGISTRY_IMAGE="ghcr.io/karegyudon/freshrss"

REF="${1:-}"
if [ -z "$REF" ]; then
	echo "Usage: $0 <upstream-ref> [--push] [--check-only]" >&2
	exit 2
fi
shift || true

DO_PUSH=0
CHECK_ONLY=0
for flag in "$@"; do
	case "$flag" in
		--push) DO_PUSH=1 ;;
		--check-only) CHECK_ONLY=1 ;;
		*) echo "Unknown flag: $flag" >&2; exit 2 ;;
	esac
done

# Resolve the ref to a commit, fetching from upstream if missing (blobs are
# required for git apply --3way).
resolve_sha() {
	local rev
	for rev in "$REF" "$REF^{commit}" "refs/tags/$REF" "upstream/$REF" "origin/$REF"; do
		if git -C "$REPO_ROOT" rev-parse -q --verify "${rev}^{commit}" >/dev/null 2>&1; then
			git -C "$REPO_ROOT" rev-parse "${rev}^{commit}"
			return 0
		fi
	done
	echo "Ref $REF not found locally; fetching upstream tags…" >&2
	git -C "$REPO_ROOT" fetch --tags --quiet upstream
	for rev in "$REF" "refs/tags/$REF"; do
		if git -C "$REPO_ROOT" rev-parse -q --verify "${rev}^{commit}" >/dev/null 2>&1; then
			git -C "$REPO_ROOT" rev-parse "${rev}^{commit}"
			return 0
		fi
	done
	return 1
}

if ! SHA="$(resolve_sha)"; then
	echo "ERROR: cannot resolve ref '$REF' (checked local, refs/tags, upstream/, origin/ after fetch)." >&2
	exit 1
fi

WT="$(mktemp -d /tmp/freshrss-build-XXXXXX)"
cleanup() {
	git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
	git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT

git -C "$REPO_ROOT" worktree add --detach "$WT" "$SHA" >/dev/null

# Apply the fork patch (3-way: uses blob indexes from the patch; conflicts fail loudly).
if ! git -C "$WT" apply --3way "$PATCH"; then
	echo "ERROR: fork/retry-after-per-url.patch does not apply to $SHA ('git apply --3way' failed)." >&2
	echo "Do NOT apply with fuzz. Regenerate the patch instead:" >&2
	echo "  1. git worktree add --detach /tmp/regen $SHA" >&2
	echo "  2. In app/Utils/httpUtil.php getRetryAfterFile(): drop the \$domainWide / serverIsPublic" >&2
	echo "     decision so the Retry-After file name is always '<host[:port]>_<sha256(url)>[<proxy>].txt'" >&2
	echo "  3. In tests/app/Utils/httpUtilTest.php flip the 'public server' case to false" >&2
	echo "  4. git commit, git format-patch -1, replace fork/retry-after-per-url.patch, re-test" >&2
	exit 1
fi

VERSION="$(sed -n "s/^const FRESHRSS_VERSION = '\(.*\)'.*/\1/p" "$WT/constants.php")"
if [ -z "$VERSION" ]; then
	echo "ERROR: could not parse FRESHRSS_VERSION from $WT/constants.php" >&2
	exit 1
fi
IMAGE="$REGISTRY_IMAGE:${VERSION}-patched"
echo "PATCH APPLIED OK for $SHA"
echo "IMAGE would be: $IMAGE"

if [ "$CHECK_ONLY" = "1" ]; then
	exit 0
fi

# The Docker daemon may lack the proxy configured for the shell, so pulls go
# through skopeo + docker load when a direct pull fails.
ensure_base_image() {
	local base="$1"
	if docker image inspect "$base" >/dev/null 2>&1; then
		return 0
	fi
	echo "Fetching base image $base…" >&2
	if docker pull "$base" >/dev/null 2>&1; then
		return 0
	fi
	local tmp
	tmp="$(mktemp /tmp/freshrss-base-XXXXXX).tar"
	skopeo copy --override-os linux --override-arch amd64 \
		"docker://$base" "docker-archive:$tmp:$base" >&2
	docker load -i "$tmp" >/dev/null
	rm -f "$tmp"
}

BASE_TAG="$(awk '$1 == "FROM" { print $2; exit }' "$WT/Docker/Dockerfile")"
[ -n "$BASE_TAG" ] && ensure_base_image "$BASE_TAG"

# Forward proxy settings to the build (apt-get inside the image), and use the
# host network because a loopback proxy is unreachable from a bridge network.
BUILD_ARGS=()
NETWORK_ARGS=()
PROXY_VALUE="${HTTPS_PROXY:-${https_proxy:-}}"
if [ -n "$PROXY_VALUE" ]; then
	for v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy; do
		if [ -n "${!v:-}" ]; then
			BUILD_ARGS+=(--build-arg "$v=${!v}")
		fi
	done
	NETWORK_ARGS=(--network=host)
fi

docker build --platform linux/amd64 "${NETWORK_ARGS[@]}" \
	-f "$WT/Docker/Dockerfile" \
	--build-arg FRESHRSS_VERSION="$VERSION" \
	--build-arg SOURCE_COMMIT="$SHA" \
	"${BUILD_ARGS[@]}" \
	-t "$IMAGE" "$WT"

if [ "$DO_PUSH" = "1" ]; then
	if ! docker push "$IMAGE" 2>/tmp/freshrss-push-err.log; then
		echo "docker push failed: $(tail -n 1 /tmp/freshrss-push-err.log)" >&2
		echo "Retrying via skopeo through the shell proxy…" >&2
		tmp="$(mktemp /tmp/freshrss-push-XXXXXX).tar"
		docker save -o "$tmp" "$IMAGE"
		skopeo copy --override-os linux --override-arch amd64 \
			"docker-archive:$tmp:$IMAGE" "docker://$IMAGE" >&2
		rm -f "$tmp"
	fi
fi

echo "DONE: $IMAGE"
docker image inspect --format 'digest={{.Id}} size={{.Size}}' "$IMAGE"
