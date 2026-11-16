#!/bin/bash
# SPDX-License-Identifier: MIT
# 将 NaiLink 运行包与 dae / sing-box / mihomo 三个内核直接打包进固件。
# 说明：NaiLink 官方 openwrt Makefile 需要预先准备好的架构二进制，
# 因此这里直接取官方发布包，解包后并入 base-files，随固件一起生成。

set -euo pipefail

NAILINK_REPO="slobys/NaiLink"
NAILINK_TAG="openwrt-v0.6.84"
NAILINK_VERSION="0.6.84"

# IPQ60XX (Cortex-A53) 对应 aarch64_cortex-a53
NAILINK_ARCH="aarch64_cortex-a53"

PKG_DIR="${GITHUB_WORKSPACE}/wrt/package"
BASE_DIR="${PKG_DIR}/base-files/files"
WORK_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo " "
echo "NaiLink: fetching release assets for ${NAILINK_TAG}"

ASSETS="$(curl -fsSL --retry 3 --retry-delay 5 \
	-H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
	-H "Accept: application/vnd.github+json" \
	"https://api.github.com/repos/${NAILINK_REPO}/releases/tags/${NAILINK_TAG}" |
	jq -r '.assets[].browser_download_url')"

if [ -z "${ASSETS}" ]; then
	echo "NaiLink: 无法获取发布资产列表" >&2
	exit 1
fi

# 按优先级挑选发布资产，避免依赖单一命名
select_asset() {
	local pattern url
	for pattern in "$@"; do
		url="$(printf '%s\n' "${ASSETS}" | grep -E "${pattern}" | head -n 1 || true)"
		if [ -n "${url}" ]; then
			printf '%s\n' "${url}"
			return 0
		fi
	done
	return 1
}

RUNTIME_URL="$(select_asset \
	"daed-router-${NAILINK_VERSION}-${NAILINK_ARCH}\.ipk$" \
	"daed-router-${NAILINK_VERSION}-aarch64_generic\.ipk$" \
	"daed-router-${NAILINK_VERSION}-aarch64\.ipk$" \
	"daed-router-[0-9.]+-aarch64[^/]*\.ipk$")" ||
	{ echo "NaiLink: 未找到 daed-router 的 aarch64 运行包" >&2; exit 1; }

LUCI_URL="$(select_asset "luci-app-daed-router-${NAILINK_VERSION}\.ipk$")" ||
	{ echo "NaiLink: 未找到 luci-app-daed-router 安装包" >&2; exit 1; }

SINGBOX_URL="$(select_asset "nailink-sing-box-[0-9.]+-nailink\.[0-9]+-arm64\.tar\.gz$")" ||
	{ echo "NaiLink: 未找到 sing-box arm64 内核" >&2; exit 1; }

MIHOMO_URL="$(select_asset "nailink-mihomo-[0-9.]+-arm64\.tar\.gz$")" ||
	{ echo "NaiLink: 未找到 mihomo arm64 内核" >&2; exit 1; }

download() {
	local url="$1"
	local out="${WORK_DIR}/$(basename "${url}")"
	curl -fsSL --retry 3 --retry-delay 5 -o "${out}" "${url}"
	printf '%s\n' "${out}"
}

# ipk = 外层 tar.gz，内含 data.tar.gz
unpack_ipk() {
	local file="$1"
	local dir="${WORK_DIR}/ipk.$$.$RANDOM"

	mkdir -p "${dir}"
	tar -xzf "${file}" -C "${dir}" data.tar.gz
	mkdir -p "${BASE_DIR}"
	tar -xzf "${dir}/data.tar.gz" -C "${BASE_DIR}" --no-same-owner
	rm -rf "${dir}"
}

# sing-box / mihomo 发布包同样是 外层 tar.gz + data.tar.gz
unpack_core() {
	local file="$1"
	local target="$2"
	local name dir

	name="$(basename "${target}")"
	dir="${WORK_DIR}/core.$$.$RANDOM"

	mkdir -p "${dir}/root"
	tar -xzf "${file}" -C "${dir}" data.tar.gz
	tar -xzf "${dir}/data.tar.gz" -C "${dir}/root" --no-same-owner

	if [ ! -f "${dir}/root/usr/bin/${name}" ]; then
		echo "NaiLink: ${file} 中缺少 usr/bin/${name}" >&2
		exit 1
	fi

	mkdir -p "$(dirname "${BASE_DIR}${target}")"
	cp -f "${dir}/root/usr/bin/${name}" "${BASE_DIR}${target}"
	chmod 0755 "${BASE_DIR}${target}"
	rm -rf "${dir}"
}

RUNTIME_FILE="$(download "${RUNTIME_URL}")"
LUCI_FILE="$(download "${LUCI_URL}")"
SINGBOX_FILE="$(download "${SINGBOX_URL}")"
MIHOMO_FILE="$(download "${MIHOMO_URL}")"

echo "NaiLink: unpacking runtime packages"
unpack_ipk "${RUNTIME_FILE}"
unpack_ipk "${LUCI_FILE}"

echo "NaiLink: installing built-in cores"
unpack_core "${SINGBOX_FILE}" "/usr/libexec/daed/cores/sing-box"
unpack_core "${MIHOMO_FILE}" "/usr/libexec/daed/cores/mihomo"

# 关键文件校验，缺任何一个都直接失败，避免产出没有插件或缺少内核的固件
for FILE in \
	usr/bin/daed \
	usr/libexec/daed/btf-probe \
	usr/libexec/daed/luci-proxy \
	usr/libexec/daed/check \
	usr/libexec/daed/subscription-proxy \
	usr/sbin/nailink \
	etc/init.d/daed \
	usr/share/luci/menu.d/luci-app-daed-router.json \
	usr/libexec/daed/cores/sing-box \
	usr/libexec/daed/cores/mihomo; do
	if [ ! -f "${BASE_DIR}/${FILE}" ]; then
		echo "NaiLink: 缺少 ${FILE}" >&2
		exit 1
	fi
done

# 内核与脚本必须可执行
chmod 0755 \
	"${BASE_DIR}/usr/bin/daed" \
	"${BASE_DIR}/usr/libexec/daed/btf-probe" \
	"${BASE_DIR}/usr/libexec/daed/luci-proxy" \
	"${BASE_DIR}/usr/libexec/daed/check" \
	"${BASE_DIR}/usr/libexec/daed/subscription-proxy" \
	"${BASE_DIR}/usr/libexec/daed/nailink-maintenance" \
	"${BASE_DIR}/usr/libexec/daed/network-check" \
	"${BASE_DIR}/usr/sbin/nailink" \
	"${BASE_DIR}/usr/sbin/daed-router-setup" \
	"${BASE_DIR}/etc/init.d/daed" \
	"${BASE_DIR}/usr/libexec/rpcd/daed-router" \
	"${BASE_DIR}/www/cgi-bin/daed-router" \
	"${BASE_DIR}/usr/libexec/daed/cores/sing-box" \
	"${BASE_DIR}/usr/libexec/daed/cores/mihomo"

# dae 依赖的 GeoSite / GeoIP 由 v2ray-geoip、v2ray-geosite 提供，此处补齐软链接
mkdir -p "${BASE_DIR}/usr/share/daed"
ln -sf ../v2ray/geosite.dat "${BASE_DIR}/usr/share/daed/geosite.dat"
ln -sf ../v2ray/geoip.dat "${BASE_DIR}/usr/share/daed/geoip.dat"

echo "NaiLink: daed + sing-box + mihomo bundled into firmware"