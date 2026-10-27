#!/bin/bash
# 测速台自带的静态 iperf3（对端缺 iperf3 时临时 scp 过去用，测完删除）。
#
# 二进制不进 git：构建时按固定版本 + sha256 拉取到 vendor/iperf3/，校验通过才拷进 App。
# 拉不到（离线、被墙）只告警不失败——测速台照常工作，只是不能给缺 iperf3 的对端自动部署。
#
# 用法：fetch-iperf3.sh <输出目录>
set -uo pipefail
VERSION=3.22
BASE="https://github.com/userdocs/iperf3-static/releases/download/$VERSION"
CACHE="$(cd "$(dirname "$0")" && pwd)/iperf3"
OUT="${1:?输出目录}"

# 发布资产名 → App 内文件名（按 uname -m 命名）→ sha256
ASSETS="
iperf3-amd64 linux-x86_64 ef4c89f3fc01c56cf00d34b900024c74f68e540dab452eef4fd902544d9c1c64
iperf3-arm64v8 linux-aarch64 34364466812357fe021a8647cb433c8006b0360e3b690ecda470a979a2601031
iperf3-arm64-osx-15 darwin-arm64 b314e8f62cb7ee1277f6c9fcc8b7a659c154aadd6b672d00e9e842d59a895d05
"

mkdir -p "$CACHE" "$OUT"
echo "$ASSETS" | while read -r asset name sum; do
	[ -n "$asset" ] || continue
	file="$CACHE/$asset"
	if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sum" ]; then
		curl -fsSL -m 180 -o "$file.part" "$BASE/$asset" && mv "$file.part" "$file" || {
			rm -f "$file.part"
			echo "warning: 拉取 $asset 失败，测速台将不能给缺 iperf3 的 $name 对端自动部署"
			continue
		}
	fi
	if [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sum" ]; then
		echo "warning: $asset 校验不符，已丢弃"
		rm -f "$file"
		continue
	fi
	install -m 0755 "$file" "$OUT/iperf3-$name"
done
exit 0
