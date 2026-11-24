#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

rev=4a440e31eda39d15086482c00a10d1b5dbb1f5ae
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git -C "$tmp" init -q
git -C "$tmp" fetch -q --depth=1 https://github.com/kenzok8/openwrt-honk.git "$rev"
git -C "$tmp" checkout -q --detach FETCH_HEAD
test "$(git -C "$tmp" rev-parse HEAD)" = "$rev"
for pkg in honk luci-app-honk; do
    test -f "$tmp/$pkg/Makefile"
    test ! -e "$pkg"
    cp -a "$tmp/$pkg" "$pkg"
done
printf 'Honk packages pinned to %s\n' "$rev"
