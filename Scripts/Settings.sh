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