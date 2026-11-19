#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
#sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#修改WIFI加密
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config

#主题附带的配置页/仪表盘，各主题包名不统一，不能一律拼成 luci-app-<theme>-config
#  aurora / kucat : luci-app-<theme>-config
#  vantage        : luci-app-vantage（仪表盘），另带中文本地化包
case "$WRT_THEME" in
	aurora|kucat)
		echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config
		;;
	vantage)
		echo "CONFIG_PACKAGE_luci-app-vantage=y" >> ./.config
		echo "CONFIG_PACKAGE_luci-i18n-vantage-theme-zh-cn=y" >> ./.config
		echo "CONFIG_PACKAGE_luci-i18n-vantage-zh-cn=y" >> ./.config
		;;
	*)
		echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config
		;;
esac

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#nn6000-v1 专用：单设备构建 + 回补被 GENERAL.txt 覆盖的 USB 工具
if [ "$WRT_CONFIG" = "IPQ60XX-LINK-NN6000V1-NSS-USB-NOWIFI" ]; then
	#GENERAL.txt 在机型配置之后追加，其中的 CONFIG_TARGET_MULTI_PROFILE=y
	#会把整个平台的全部设备都编译进来，这里改回只编译 nn6000-v1
	echo "CONFIG_TARGET_MULTI_PROFILE=n" >> ./.config
	echo "CONFIG_TARGET_PER_DEVICE_ROOTFS=n" >> ./.config
	echo "CONFIG_TARGET_PROFILE=\"DEVICE_link_nn6000-v1\"" >> ./.config
	#GENERAL.txt 把 usbutils 置为 n，但接 U 盘/移动硬盘需要 lsusb 排查设备，补回
	echo "CONFIG_PACKAGE_usbutils=y" >> ./.config
fi

#无WIFI配置标志
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
	echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#设置NSS版本
	echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
	echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
	#其他调整
	echo "CONFIG_PACKAGE_kmod-usb-serial-qualcomm=y" >> ./.config
fi

# NN6000 v1 专用内核瘦身：修改真正参与合并的 target 内核配置，
# 不向 OpenWrt .config 写入不存在的 CONFIG_KERNEL_PHY_* 选项。
# 保留 QMP_USB / QUSB2 / QMP_PCIE；不关闭 BTF、BPF、KPROBES、
# PERF_EVENTS、FTRACE、KALLSYMS、NSS、MMC 或 USB 存储。
if [ "$WRT_CONFIG" = "IPQ60XX-LINK-NN6000V1-NSS-USB-NOWIFI" ]; then
	python3 - <<'PY' || exit 1
from pathlib import Path
import re

root = Path('target/linux/qualcommax')
configs = sorted(root.glob('config-*')) + sorted((root / 'ipq60xx').glob('config-*'))
configs = [path for path in configs if path.is_file()]
if not configs:
    raise SystemExit('NN6000 kernel trim: target kernel config not found; refusing to continue')

def disable(text, symbol):
    pattern = r'^(?:' + re.escape(symbol) + r'=.*|# ' + re.escape(symbol) + r' is not set)\n?'
    text = re.sub(pattern, '', text, flags=re.MULTILINE)
    return text.rstrip('\n') + '\n# ' + symbol + ' is not set\n'

# IPQ6000 不使用 UFS、USB/DP combo PHY 或 MSM8996 专用 PCIe PHY。
# 不裁剪 IPQ60xx 使用的 USB/PCIe PHY 驱动。
# 第二轮：Cortex-A53 不支持 SVE/SME，关闭相关寄存器上下文处理代码；
# DEBUG_BUGVERBOSE 只去掉 BUG 报告的源码文件名/行号，保留 BUG 检测、
# printk、符号表和栈回溯。不关闭 DEBUG_INFO，避免破坏 BTF。
# 实际 FIT 压缩收益必须由下一次构建测量，不以未压缩节省量代替。
symbols = (
    'CONFIG_PHY_QCOM_QMP_UFS',
    'CONFIG_PHY_QCOM_QMP_COMBO',
    'CONFIG_PHY_QCOM_QMP_PCIE_8996',
    'CONFIG_ARM64_BRBE',
    'CONFIG_ARM64_SVE',
    'CONFIG_ARM64_SME',
    'CONFIG_DEBUG_BUGVERBOSE',
)
for path in configs:
    text = path.read_text()
    for symbol in symbols:
        text = disable(text, symbol)
    path.write_text(text)
    written = path.read_text()
    for symbol in symbols:
        if ('# ' + symbol + ' is not set') not in written.splitlines():
            raise SystemExit(f'NN6000 kernel trim verification failed: {path}: {symbol}')
    print(f'NN6000 kernel trim applied: {path}: {", ".join(symbols)}')

# BRBE 有真实的 OpenWrt 配置入口，且在 PERF_EVENTS 打开时默认 y。
# 同时关闭该入口，避免后续 make defconfig 再将它打开。
path = Path('.config')
path.write_text(disable(path.read_text(), 'CONFIG_KERNEL_ARM64_BRBE'))
print('NN6000: BTF/BPF/NSS/USB storage preserved; final kernel size still requires a build')
PY
fi
