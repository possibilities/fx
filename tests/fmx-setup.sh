#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# These are literal workflow guards; expansion here would defeat the test.
# shellcheck disable=SC2016
grep -F '[[ "$GITHUB_REF" != "refs/heads/integration" ]]' "$root/.github/workflows/fmx-release.yml" >/dev/null
# shellcheck disable=SC2016
grep -F '[[ "$GITHUB_SHA" != "$integration_sha"' "$root/.github/workflows/fmx-release.yml" >/dev/null
scratch="$(mktemp -d "${TMPDIR:-/tmp}/fmx-fx-setup-test.XXXXXX")"
cleanup() {
  rm -rf "$scratch"
}
trap cleanup EXIT

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) exit 0 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=aarch64 ;;
  *) exit 0 ;;
esac

commit="0123456789abcdef0123456789abcdef01234567"
release="$scratch/public/releases/$commit"
payload="$scratch/payload"
install="$scratch/install"
mkdir -p "$release" "$payload"
# This is the literal body of the fake executable.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' \
  '[ "$1" = --fxnk-version ] || exit 0' \
  "printf 'fxnk 0.5.0 (fx 0.0.6)\\n'" > "$payload/fmx-fx"
chmod 0755 "$payload/fmx-fx"
printf 'license\n' > "$payload/LICENSE"
printf 'notices\n' > "$payload/THIRD_PARTY_NOTICES.md"

archive="fmx-fx-$os-$arch.tar.gz"
tar -czf "$release/$archive" -C "$payload" fmx-fx LICENSE THIRD_PARTY_NOTICES.md
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$release/$archive" | awk -v archive="$archive" '{ print $1 "  " archive }' > "$release/$archive.sha256"
else
  shasum -a 256 "$release/$archive" | awk -v archive="$archive" '{ print $1 "  " archive }' > "$release/$archive.sha256"
fi
printf '%s' "$commit" > "$scratch/public/latest.txt"
sed "s|__FMX_FX_RELEASE_BASE_URL__|file://$scratch/public|g" \
  "$root/fmx-setup.sh" > "$scratch/setup.sh"

PATH_WITHOUT_XZ="$scratch/path"
mkdir -p "$PATH_WITHOUT_XZ"
for command in awk bash chmod cp curl gzip mkdir mktemp mv rm shasum tar uname; do
  resolved="$(command -v "$command")"
  ln -s "$resolved" "$PATH_WITHOUT_XZ/$command"
done
PATH="$PATH_WITHOUT_XZ" FMX_FX_INSTALL_DIR="$install" FMX_FX_VERSION="$commit" \
  bash "$scratch/setup.sh"
test -x "$install/fmx-fx"
test "$("$install/fmx-fx" --fxnk-version)" = 'fxnk 0.5.0 (fx 0.0.6)'

printf '0%.0s' {1..64} > "$release/$archive.sha256"
rejected="$scratch/rejected"
if PATH="$PATH_WITHOUT_XZ" FMX_FX_INSTALL_DIR="$rejected" FMX_FX_VERSION="$commit" \
  bash "$scratch/setup.sh" >"$scratch/rejected.stdout" 2>"$scratch/rejected.stderr"; then
  printf 'fmx-fx setup test: corrupt checksum was accepted\n' >&2
  exit 1
fi
grep -F 'SHA-256 mismatch' "$scratch/rejected.stderr" >/dev/null
test ! -e "$rejected/fmx-fx"

printf 'fmx-fx setup test: pass\n'
