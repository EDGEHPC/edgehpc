#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the CI toolchain into a new directory; never modify a shell profile.
set -euo pipefail

if [[ $# != 1 ]]; then
  printf 'Usage: %s NEW_TOOLCHAIN_DIRECTORY\n' "$0" >&2
  exit 2
fi

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)
    arch=x86_64
    tool_sha=80d987523308fa490eba9f1baf98df996a5a7891e118357553b7c2608c0597c5
    ;;
  Linux/aarch64)
    arch=aarch64
    tool_sha=8eaf1e2bd633bc6ab480d86ebeeef2d40248b7c8b5317dc287d77ad01f165727
    ;;
  *)
    printf 'Only Linux x86_64 and aarch64 are supported by this CI installer.\n' >&2
    exit 2
    ;;
esac

version=0.10.20%2B65efd5b93
core_sha=8ec2a2c01335501d703867bb4eef5f92d3cd7e1ae1ee5f7f14d54d16d2c7c2b5
base=https://cli.moonbitlang.com
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fetch() {
  curl --proto '=https' --proto-redir '=https' --fail --silent --show-error \
    --location --retry 3 --max-time 120 -o "$2" "$1"
  printf '%s  %s\n' "$3" "$2" | sha256sum --check
}

fetch "$base/binaries/$version/moonbit-linux-$arch.tar.gz" "$tmp/moon.tar.gz" "$tool_sha"
fetch "$base/cores/core-$version.tar.gz" "$tmp/core.tar.gz" "$core_sha"
mkdir -- "$1"
tar --extract --gzip --file "$tmp/moon.tar.gz" --directory "$1" --no-same-owner --no-same-permissions
tar --extract --gzip --file "$tmp/core.tar.gz" --directory "$1/lib" --no-same-owner --no-same-permissions
find "$1/bin" -type f -exec chmod u+x {} +
