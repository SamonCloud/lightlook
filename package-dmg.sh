#!/bin/zsh
set -eu
cd -- "${0:A:h}"
app_dir="${1:-$PWD/build/轻览.app}"
[[ -d "$app_dir" ]] || { print -u2 '请先运行 zsh build.sh 构建应用。'; exit 1; }
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_dir/Contents/Info.plist")
architecture=$(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/LightLook")
[[ "$architecture" == "arm64" || "$architecture" == "x86_64" ]] || { print -u2 '请检查应用架构后打包。'; exit 1; }
/usr/bin/codesign --verify --strict "$app_dir"
stage_dir=$(/usr/bin/mktemp -d "$PWD/build/dmg-stage.XXXXXX")
trap '/bin/rm -rf -- "$stage_dir"' EXIT
/usr/bin/ditto "$app_dir" "$stage_dir/轻览.app"
/bin/ln -s /Applications "$stage_dir/Applications"
cat > "$stage_dir/安装说明.txt" <<TEXT
轻览 LightLook $version

安装方法：将“轻览.app”拖入旁边的 Applications 文件夹。
安装完成后可以推出此磁盘映像，再从“应用程序”打开轻览。

本镜像内应用架构：$architecture，最低系统目标为 macOS 13。
实际功能验证环境为 macOS 27.0.1。
本版本采用本机临时签名，未进行 Developer ID 签名和 Apple 公证。

应用直接读取图片和视频，不修改原文件。
联网地名和地图默认关闭，可在右侧“地点与地图”中自行开启。
TEXT
output="$PWD/build/轻览-$version-macOS-$architecture.dmg"
/usr/bin/hdiutil create -srcfolder "$stage_dir" -volname "轻览 $version" -format UDZO -fs HFS+ -ov "$output"
/usr/bin/hdiutil verify "$output"
print "已打包：$output"
