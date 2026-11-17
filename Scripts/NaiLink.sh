#!/bin/bash
# SPDX-License-Identifier: MIT
# 将 NaiLink 运行包与 dae / sing-box / mihomo 三个内核直接打包进固件。
# 资产名取自 NaiLink 发布校验脚本 scripts/publish-openwrt.py 的固定清单。

set -euo pipefail

NAILINK_REPO="slobys/NaiLink"
NAILINK_TAG="openwrt-v0.6.84"
VERSION="0.6.84"
SINGBOX_VER="1.14.3-nailink.1"
MIHOMO_VER="1.19.33"

BASE_URL="https://github.com/${NAILINK_REPO}/releases/download/${NAILINK_TAG}"
BASE_DIR="${GITHUB_WORKSPACE}/wrt/package/base-files/files"
WORK="$(mktemp -d)"

cleanup() {
	rm -rf "${WORK}"
}
trap cleanup EXIT

echo " "
echo "NaiLink: 开始下载 ${NAILINK_TAG} 资产"

# 依次尝试候选地址，第一个成功的生效
fetch_first() {
	local out="$1"
	shift
	local url

	for url in "$@"; do
		if curl -fsSL --retry 3 --retry-delay 5 -o "${out}" "${url}"; then
			echo "NaiLink: 已下载 $(basename "${url}")"
			return 0
		fi
		echo "NaiLink: 下载失败 ${url}" >&2
	done

	return 1
}

# dae 运行包：按目标架构优先匹配 cortex-a53，其次通用 aarch64
if ! fetch_first "${WORK}/runtime.ipk" \
	"${BASE_URL}/daed-router-${VERSION}-aarch64_cortex-a53.ipk" \
	"${BASE_URL}/daed-router-${VERSION}-aarch64_cortex-a35.ipk" \
	"${BASE_URL}/daed-router-${VERSION}-aarch64_generic.ipk" \
	"${BASE_URL}/daed-router-${VERSION}-aarch64.ipk"; then
	echo "NaiLink: 未取到 daed-router 的 aarch64 运行包" >&2
	exit 1
fi

if ! fetch_first "${WORK}/luci.ipk" \
	"${BASE_URL}/luci-app-daed-router-${VERSION}.ipk"; then
	echo "NaiLink: 未取到 luci-app-daed-router 安装包" >&2
	exit 1
fi

if ! fetch_first "${WORK}/sing-box.tar.gz" \
	"${BASE_URL}/nailink-sing-box-${SINGBOX_VER}-arm64.tar.gz"; then
	echo "NaiLink: 未取到 sing-box arm64 内核" >&2
	exit 1
fi

if ! fetch_first "${WORK}/mihomo.tar.gz" \
	"${BASE_URL}/nailink-mihomo-${MIHOMO_VER}-arm64.tar.gz"; then
	echo "NaiLink: 未取到 mihomo arm64 内核" >&2
	exit 1
fi

# ipk 外层是 tar.gz，成员为 ./debian-binary、./control.tar.gz、./data.tar.gz，
# 整体解压后再取 data.tar.gz，避免成员名前缀导致匹配失败
unpack_ipk() {
	local file="$1"
	local dir="${WORK}/ipk.$$.$RANDOM"

	mkdir -p "${dir}"
	tar -xzf "${file}" -C "${dir}"

	if [ ! -f "${dir}/data.tar.gz" ]; then
		echo "NaiLink: $(basename "${file}") 中缺少 data.tar.gz" >&2
		exit 1
	fi

	mkdir -p "${BASE_DIR}"
	tar -xzf "${dir}/data.tar.gz" -C "${BASE_DIR}" --no-same-owner
	rm -rf "${dir}"
}

# sing-box / mihomo 发布包同样是外层 tar.gz，内含 data.tar.gz
unpack_core() {
	local file="$1"
	local target="$2"
	local name dir

	name="$(basename "${target}")"
	dir="${WORK}/core.$$.$RANDOM"

	mkdir -p "${dir}/root"
	tar -xzf "${file}" -C "${dir}"

	if [ ! -f "${dir}/data.tar.gz" ]; then
		echo "NaiLink: $(basename "${file}") 中缺少 data.tar.gz" >&2
		exit 1
	fi

	tar -xzf "${dir}/data.tar.gz" -C "${dir}/root" --no-same-owner

	if [ ! -f "${dir}/root/usr/bin/${name}" ]; then
		echo "NaiLink: $(basename "${file}") 中缺少 usr/bin/${name}" >&2
		exit 1
	fi

	mkdir -p "$(dirname "${BASE_DIR}${target}")"
	cp -f "${dir}/root/usr/bin/${name}" "${BASE_DIR}${target}"
	chmod 0755 "${BASE_DIR}${target}"
	rm -rf "${dir}"
}

echo "NaiLink: 解包运行包"
unpack_ipk "${WORK}/runtime.ipk"
unpack_ipk "${WORK}/luci.ipk"

echo "NaiLink: 写入内置内核"
unpack_core "${WORK}/sing-box.tar.gz" "/usr/libexec/daed/cores/sing-box"
unpack_core "${WORK}/mihomo.tar.gz" "/usr/libexec/daed/cores/mihomo"

# 关键文件校验，缺任何一个都直接失败
MISSING=0
for FILE in \
	usr/bin/daed \
	usr/libexec/daed/btf-probe \
	usr/libexec/daed/luci-proxy \
	usr/libexec/daed/check \
	usr/libexec/daed/subscription-proxy \
	usr/libexec/daed/nailink-maintenance \
	usr/libexec/daed/network-check \
	usr/sbin/nailink \
	usr/sbin/daed-router-setup \
	etc/init.d/daed \
	usr/share/luci/menu.d/luci-app-daed-router.json \
	usr/libexec/rpcd/daed-router \
	www/cgi-bin/daed-router \
	usr/libexec/daed/cores/sing-box \
	usr/libexec/daed/cores/mihomo; do
	if [ -f "${BASE_DIR}/${FILE}" ]; then
		chmod 0755 "${BASE_DIR}/${FILE}"
	else
		echo "NaiLink: 缺少 ${FILE}" >&2
		MISSING=1
	fi
done

if [ "${MISSING}" != "0" ]; then
	exit 1
fi

# /etc/init.d/daed 的 start_service 第一件事就是：
#   config_load daed; config_get_bool enabled main enabled 0
#   [ "$enabled" = 1 ] || return 0
# 也就是说没有 /etc/config/daed（或 enabled 不为 1）时，启动是"成功返回但什么都不做"，
# procd 报 active with no instances，LuCI 显示启动失败且日志为空，极难排查。
# 运行包本身不带这个文件（它由 daed-router-setup 交互式安装时才生成），
# 而我们是解包直装、从不执行安装器，所以这里补一份最小可用的默认值。
# 只在该文件缺失时写入，不覆盖用户已有配置（sysupgrade 会保留 /etc/config）。
if [ ! -f "${BASE_DIR}/etc/config/daed" ]; then
	mkdir -p "${BASE_DIR}/etc/config"
	cat > "${BASE_DIR}/etc/config/daed" <<-'EOF'
		config main 'main'
			option enabled '1'
	EOF
	echo "NaiLink: 已写入默认 /etc/config/daed (enabled=1)"
fi

# dae 依赖的 GeoSite / GeoIP 由 v2ray-geoip、v2ray-geosite 提供
mkdir -p "${BASE_DIR}/usr/share/daed"
ln -sf ../v2ray/geosite.dat "${BASE_DIR}/usr/share/daed/geosite.dat"
ln -sf ../v2ray/geoip.dat "${BASE_DIR}/usr/share/daed/geoip.dat"

echo "NaiLink: 已内建 daed + sing-box + mihomo"
ls -l "${BASE_DIR}/usr/libexec/daed/cores/"