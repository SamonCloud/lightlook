# 验证说明

当前发布版本：0.2.0。验证环境为 Apple Silicon、macOS 27.0.1、Swift 6.4，以 Swift 5 语言模式构建，最低部署目标为 macOS 13。旧系统未逐版本实机验证。

## 已完成验证

- 应用构建、Info.plist 和本机签名校验，以及 DMG 完整性校验。
- 合成 JPEG、HEIF、PNG 解码、EXIF 方向、拍摄参数、GPS 和缩略图尺寸限制。
- 公开 CC0 Sony ILCE-7S ARW 与 Canon EOS 5D Mark III 转换 DNG 的缩略图、原尺寸及元数据读取。样本来源和校验值见 `Tests/samples.json`；测试照片不随仓库分发。
- 1280 × 720 H.264 MP4 的缩略图、时长和播放加载。
- 九种实际 AppKit 网格布局中的按行导航、末行不满、原列恢复和首末边界；真实 NSClipView 的上下滚动和已可见项目不抖动。
- 标签切换、持久化、双标签独立、损坏与写入失败保护、源文件身份检查、复制/移动同名冲突、日志恢复及部分失败。
- 自建临时磁盘卷上的真实跨卷移动，SHA-256 内容校验及标签迁移。
- 独立测试文件移入真实系统废纸篓并立即恢复。测试不操作用户照片。
- 离屏 AppKit 控制器中的 S/D/Delete 映射、重复按键保护、标签控件、复核推进、批处理菜单和默认取消的二次确认。
- 合成坐标的 Apple 中文地名查询与缓存，实际小地图加载。
- 模拟 DLNA 电视的设备描述、SSDP 多播发现、SOAP 播放、JPEG 与 MP4 字节范围读取。

## 验证边界

- RAW 兼容性依赖相机机型、压缩模式及系统解码器，未逐一验证所有型号。
- DLNA 尚未完成真实电视品牌兼容性验收；AirPlay 接收设备也未逐一验证。
- 新增标签控件测试不等同于完整的实时窗口点击与全屏视觉验收。
- 尚未进行大图库、长期 NAS 浏览和长视频的性能基准测试。
- 尚未完成 Developer ID 签名和 Apple 公证。
- 标签不自动跟踪应用外的重命名、移动；恢复日志仅重放已记录成功项的标签状态，不自动执行文件操作。

## 复核命令

```sh
zsh test.sh
zsh test-navigation.sh
zsh test-file-actions.sh
zsh test-tags-ui.sh
zsh test-location.sh
# 可选：使用合成坐标联机验证
zsh test-location.sh --lookup
# 可选：仅对测试程序创建的临时文件验证废纸篓，并立即恢复
zsh test-file-actions.sh --trash
python3 Tests/network_test.py
```

HEIF 测试需要系统图像服务；网络测试需要端口监听权限。网络测试需准备 `build/测试素材/05-视频测试.mp4`，可使用自行生成的测试视频。测试与构建缓存位于被 Git 忽略的 `build/` 目录。
