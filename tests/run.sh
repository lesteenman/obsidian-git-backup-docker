#!/bin/sh
# =============================================================================
# run.sh — Build the image and run the test suite
#
# Unit tests (tests/unit/*.sh) run inside the image, so they use the same
# BusyBox and git versions as production. They source the scripts from the
# checkout (mounted read-only at /src), not the copies baked into the image.
#
# Container tests (tests/container/*.sh) run on the host and start the image
# with a stub obsidian-headless (no network, no Obsidian account needed).
#
# Usage: tests/run.sh [test-file ...]
#   TEST_IMAGE=name   image tag to build/use (default obsidian-git-backup:test)
#   SKIP_BUILD=1      reuse an existing TEST_IMAGE
# =============================================================================
set -eu

cd "$(dirname "$0")/.."
IMAGE="${TEST_IMAGE:-obsidian-git-backup:test}"
STUB_IMAGE="${IMAGE}-stub"

if [ "${SKIP_BUILD:-}" != 1 ]; then
  echo "Building ${IMAGE}..."
  docker build -q -t "${IMAGE}" . >/dev/null
fi
docker build -q -t "${STUB_IMAGE}" --build-arg "BASE=${IMAGE}" tests/container/stub >/dev/null

if [ "$#" -eq 0 ]; then
  set -- tests/unit/*.sh tests/container/*.sh
fi

failed=""
for t in "$@"; do
  echo "=== ${t}"
  case "${t}" in
    tests/unit/*)
      docker run --rm -v "${PWD}:/src:ro" --entrypoint sh "${IMAGE}" "/src/${t}" || failed="${failed} ${t}"
      ;;
    tests/container/*)
      sh "${t}" "${STUB_IMAGE}" || failed="${failed} ${t}"
      ;;
  esac
done

if [ -n "${failed}" ]; then
  echo "FAILED:${failed}"
  exit 1
fi
echo "All test files passed."
