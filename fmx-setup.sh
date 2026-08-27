#!/usr/bin/env bash

set -euo pipefail

release_base_url="${FMX_FX_RELEASE_BASE_URL:-__FMX_FX_RELEASE_BASE_URL__}"
unconfigured_release_base_url='__FMX_FX_'"RELEASE_BASE_URL__"
install_dir="${FMX_FX_INSTALL_DIR:-$HOME/.local/bin}"
requested_version="${FMX_FX_VERSION:-}"

fail() {
  printf 'fmx-fx setup: %s\n' "$*" >&2
  exit 1
}

if [[ "$release_base_url" == "$unconfigured_release_base_url" ]]; then
  fail 'this installer has not been configured with a public release URL'
fi
release_base_url="${release_base_url%/}"

for command in curl tar gzip; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

case "$(uname -s)" in
  Linux) os="linux" ;;
  Darwin) os="macos" ;;
  *) fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac
platform="$os-$arch"

curl_get() {
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 "$@"
}

if [[ -z "$requested_version" ]]; then
  requested_version="$(curl_get "$release_base_url/latest.txt")"
fi
requested_version="${requested_version//$'\r'/}"
requested_version="${requested_version//$'\n'/}"
if [[ ! "$requested_version" =~ ^[0-9a-f]{40}$ ]]; then
  fail "invalid Integration commit: $requested_version"
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/fmx-fx-setup.XXXXXX")"
install_temp=""
cleanup() {
  rm -rf "$temp_dir"
  if [[ -n "$install_temp" ]]; then rm -f "$install_temp"; fi
}
trap cleanup EXIT

archive_stem="fmx-fx-$platform.tar"
archive=""
release_path="releases/$requested_version"
if command -v xz >/dev/null 2>&1; then
  archive="$archive_stem.xz"
  if ! curl_get "$release_base_url/$release_path/$archive" -o "$temp_dir/$archive" \
    || ! curl_get "$release_base_url/$release_path/$archive.sha256" -o "$temp_dir/$archive.sha256"; then
    printf 'fmx-fx setup: xz artifact unavailable; trying gzip\n' >&2
    archive=""
  fi
fi
if [[ -z "$archive" ]]; then
  archive="$archive_stem.gz"
  curl_get "$release_base_url/$release_path/$archive" -o "$temp_dir/$archive"
  curl_get "$release_base_url/$release_path/$archive.sha256" -o "$temp_dir/$archive.sha256"
fi

expected_checksum="$(awk 'NR == 1 { print $1 }' "$temp_dir/$archive.sha256")"
if [[ ! "$expected_checksum" =~ ^[0-9a-fA-F]{64}$ ]]; then
  fail "invalid SHA-256 file for $archive"
fi
if command -v sha256sum >/dev/null 2>&1; then
  actual_checksum="$(sha256sum "$temp_dir/$archive" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  actual_checksum="$(shasum -a 256 "$temp_dir/$archive" | awk '{ print $1 }')"
else
  fail 'SHA-256 verification requires sha256sum or shasum'
fi
if [[ "$actual_checksum" != "$expected_checksum" ]]; then
  fail "SHA-256 mismatch for $archive"
fi

extract_dir="$temp_dir/extract"
mkdir -p "$extract_dir"
case "$archive" in
  *.tar.xz) xz -dc "$temp_dir/$archive" | tar -xf - -C "$extract_dir" ;;
  *.tar.gz) gzip -dc "$temp_dir/$archive" | tar -xf - -C "$extract_dir" ;;
esac
[[ -x "$extract_dir/fmx-fx" ]] || fail 'archive does not contain an executable fmx-fx binary'

probe_stderr="$temp_dir/fxnk-version.stderr"
probe="$("$extract_dir/fmx-fx" --fxnk-version 2>"$probe_stderr")" || \
  fail 'downloaded fmx-fx rejected the fxnk compatibility probe'
probe_pattern='^fxnk [0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)? \(fx [^)]+\)$'
if [[ -s "$probe_stderr" ]] || [[ ! "$probe" =~ $probe_pattern ]]; then
  fail 'downloaded fmx-fx returned an invalid fxnk compatibility probe'
fi

mkdir -p "$install_dir"
installed="$install_dir/fmx-fx"
if [[ -e "$installed" && ! -f "$installed" ]]; then
  fail "$installed exists and is not a regular file"
fi
install_temp="$(mktemp "$install_dir/.fmx-fx.XXXXXX")"
cp "$extract_dir/fmx-fx" "$install_temp"
chmod 0755 "$install_temp"
mv -f "$install_temp" "$installed"
install_temp=""

installed_stderr="$temp_dir/installed-version.stderr"
installed_probe="$("$installed" --fxnk-version 2>"$installed_stderr")" || \
  fail 'installed fmx-fx rejected the fxnk compatibility probe'
if [[ "$installed_probe" != "$probe" || -s "$installed_stderr" ]]; then
  fail 'installed fmx-fx did not pass its compatibility check'
fi

printf 'Installed Fx Integration %s as %s (%s)\n' "${requested_version:0:12}" "$installed" "$probe"
