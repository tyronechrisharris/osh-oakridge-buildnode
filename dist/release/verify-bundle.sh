#!/usr/bin/env bash
set -Eeuo pipefail
script_path=${BASH_SOURCE[0]}
case $script_path in */*) script_parent=${script_path%/*} ;; *) script_parent=. ;; esac
script_dir=$(CDPATH= cd -- "$script_parent" && pwd)
cd "$script_dir"
[[ -f SHA256SUMS ]] || { printf 'ERROR: SHA256SUMS is missing.\n' >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check --strict SHA256SUMS
    manifest_hash=$(sha256sum SHA256SUMS | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    sed 's/ \*/  /' SHA256SUMS | shasum --algorithm 256 --check
    manifest_hash=$(shasum --algorithm 256 SHA256SUMS | awk '{print $1}')
else
    printf 'ERROR: sha256sum or shasum is required.\n' >&2
    exit 1
fi
temporary_receipt="$script_dir/.bundle-verified.tmp"
printf '%s\n' "$manifest_hash" >"$temporary_receipt"
chmod 644 "$temporary_receipt"
mv -f "$temporary_receipt" "$script_dir/.bundle-verified"
printf 'Bundle integrity verified.\n'
