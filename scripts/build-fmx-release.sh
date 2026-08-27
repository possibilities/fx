#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

platform="${1:-}"
case "$platform" in
  linux-x86_64)
    expected_os="Linux"
    expected_arch="x86_64"
    architecture_pattern="ELF 64-bit.*x86-64"
    ;;
  linux-aarch64)
    expected_os="Linux"
    expected_arch="aarch64"
    architecture_pattern="ELF 64-bit.*(ARM aarch64|aarch64)"
    ;;
  macos-x86_64)
    expected_os="Darwin"
    expected_arch="x86_64"
    architecture_pattern="Mach-O 64-bit executable x86_64"
    ;;
  macos-aarch64)
    expected_os="Darwin"
    expected_arch="arm64"
    architecture_pattern="Mach-O 64-bit executable arm64"
    ;;
  *)
    printf 'usage: %s <linux-x86_64|linux-aarch64|macos-x86_64|macos-aarch64>\n' "$0" >&2
    exit 2
    ;;
esac

if [[ "$(uname -s)" != "$expected_os" || "$(uname -m)" != "$expected_arch" ]]; then
  printf 'fmx-fx release: %s must be built natively on %s/%s (this host is %s/%s)\n' \
    "$platform" "$expected_os" "$expected_arch" "$(uname -s)" "$(uname -m)" >&2
  exit 1
fi

for command in file git gzip tar xz zig; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'fmx-fx release: required command not found: %s\n' "$command" >&2
    exit 1
  }
done

integration_commit="$(git rev-parse HEAD)"
if [[ ! "$integration_commit" =~ ^[0-9a-f]{40}$ ]] || ! git diff --quiet || ! git diff --cached --quiet; then
  printf 'fmx-fx release: build from one clean Integration commit\n' >&2
  exit 1
fi

release_dir="${FMX_FX_RELEASE_DIR:-$root_dir/dist/fmx-release}"
mkdir -p "$release_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/fmx-fx-release.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

zig build -Doptimize=ReleaseSafe
built="$root_dir/zig-out/bin/fx"
[[ -x "$built" ]] || {
  printf 'fmx-fx release: build did not produce %s\n' "$built" >&2
  exit 1
}

package_dir="$work_dir/package"
mkdir -p "$package_dir"
cp "$built" "$package_dir/fmx-fx"
cp "$root_dir/LICENSE" "$root_dir/THIRD_PARTY_NOTICES.md" "$package_dir/"
chmod 0755 "$package_dir/fmx-fx"
if [[ "$expected_os" == "Darwin" ]]; then
  codesign --force --sign - "$package_dir/fmx-fx" >/dev/null
  codesign --verify "$package_dir/fmx-fx"
fi
file "$package_dir/fmx-fx" | grep -Eq "$architecture_pattern"

probe_stderr="$work_dir/fxnk-version.stderr"
probe="$("$package_dir/fmx-fx" --fxnk-version 2>"$probe_stderr")" || {
  printf 'fmx-fx release: binary rejected --fxnk-version\n' >&2
  exit 1
}
probe_pattern='^fxnk [0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)? \(fx [^)]+\)$'
if [[ -s "$probe_stderr" ]] || [[ ! "$probe" =~ $probe_pattern ]]; then
  printf 'fmx-fx release: binary returned an invalid fxnk identity: %s\n' "$probe" >&2
  exit 1
fi

# Fixed mtimes plus gzip's no-name mode keep a rerun for the same commit
# byte-for-byte stable on the same native runner.
touch -t 198001010000 "$package_dir/fmx-fx" "$package_dir/LICENSE" "$package_dir/THIRD_PARTY_NOTICES.md"
raw_archive="$work_dir/fmx-fx-$platform.tar"
COPYFILE_DISABLE=1 tar --format ustar -cf "$raw_archive" -C "$package_dir" \
  fmx-fx LICENSE THIRD_PARTY_NOTICES.md

xz_archive="$release_dir/fmx-fx-$platform.tar.xz"
gzip_archive="$release_dir/fmx-fx-$platform.tar.gz"
xz -9 -c "$raw_archive" > "$xz_archive"
gzip -9 -n -c "$raw_archive" > "$gzip_archive"

checksum() {
  local path="$1" digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$path" | awk '{ print $1 }')"
  else
    digest="$(shasum -a 256 "$path" | awk '{ print $1 }')"
  fi
  printf '%s  %s\n' "$digest" "$(basename "$path")" > "$path.sha256"
}
checksum "$xz_archive"
checksum "$gzip_archive"

printf 'fmx-fx release: built %s at %s (%s; %s)\n' \
  "$platform" "$integration_commit" "$probe" "$release_dir"
