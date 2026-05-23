# Simple Video

[English](README.md)

Simple Video 是一个原生 macOS 应用，为常见的视频和音频处理提供简单的图形界面。应用使用 **SwiftUI** 构建，底层由 `ffmpeg` 和 `whisper.cpp` 提供能力。

## 功能

- **裁剪视频**：可视化调整裁剪区域，支持拖动边缘/角点、固定比例预设、自动检测黑边、独立全屏裁剪窗口，以及可预览并可选择导出或移除的起止时间范围
- **裁剪音频**：支持预览、设置起止时间范围、按播放倍率导出，并可选择导出或移除选中范围
- **转换**：在同一页面通过类型选择器进行视频/音频格式转换（视频：mp4、mov、mkv、webm、avi、flv、m4v、ts；音频：mp3、aac、wav、flac、ogg、m4a、wma、aiff、opus）
- **合并音视频**：把单独的视频轨和音频轨合并成一个文件
- **拼接文件**：拼接多个视频或音频文件
- **按时间戳分割**：根据时间戳列表把一个视频切成多个片段
- **语音转文字**：使用 Whisper 将音频/视频转写成文本
- 设置页支持 English / 简体中文切换、日志面板显示开关、仅图标按钮，以及第三方许可链接
- 可折叠实时日志、实时进度条，以及取消正在运行的任务

## 要求

对于打包后的应用：

- macOS 14+
- 如果要做成自包含应用，需要在应用内打包 `ffmpeg`、`ffprobe` 和 `whisper-cli`
- Whisper 模型由用户在应用内按需下载

对于本地开发或打包：

- Swift 5.9+，可通过 Xcode 或 Command Line Tools 安装：`xcode-select --install`
- `ffmpeg` / `ffprobe` 位于 `Resources/bin/`，或通过 `SIMPLE_VIDEO_FFMPEG_BIN` / `SIMPLE_VIDEO_FFPROBE_BIN` 环境变量指定，或安装在常见本地路径
- 来自 `whisper.cpp` 的 `whisper-cli` 位于 `Resources/bin/`，或通过 `SIMPLE_VIDEO_WHISPER_BIN` 指定，或安装在常见本地路径

## 构建

```sh
./build.sh
```

这会在 `Package.swift` 旁边生成 `Simple Video.app`。你可以在 Finder 中双击打开，或运行：

```sh
open "Simple Video.app"
```

也可以像普通 Mac 应用一样把它移动到 `/Applications`。

## DMG 安装包

创建一个拖拽安装式 DMG：

```sh
./dist.sh
```

这会构建应用并生成：

```text
dist/Simple Video-1.0.dmg
```

用户打开 DMG 后，把 `Simple Video.app` 拖到 `Applications - drop here` 即可。DMG 里也包含 `INSTALL - read me.txt`，为不熟悉技术操作的用户提供相同的安装说明。

如果要制作**自包含的可分发应用**，请在运行 `./build.sh` 之前或过程中打包运行时可执行文件：

- 把可执行文件放到 `Resources/bin/`：
  - `ffmpeg`
  - `ffprobe`
  - `whisper-cli`

`build.sh` 会把这些文件复制到 `Simple Video.app/Contents/Resources/`，把它们依赖的非系统动态库打包到 `Contents/Frameworks`，并对结果进行 ad-hoc 签名。如果 `Resources/bin/` 中没有这些工具，脚本也会尝试使用上面提到的环境变量和常见本地安装路径。

使用 Homebrew / 本地 whisper.cpp checkout 的示例：

```sh
mkdir -p Resources/bin
cp /opt/homebrew/bin/ffmpeg Resources/bin/
cp /opt/homebrew/bin/ffprobe Resources/bin/
cp /path/to/whisper.cpp/build/bin/whisper-cli Resources/bin/
./build.sh
```

运行时，应用会优先使用 `.app` 内打包的工具，然后才回退到系统中安装的工具。因此开发时仍然可以使用 `swift run`，而发布给用户的构建也可以在没有全局安装 ffmpeg 或 whisper.cpp 的机器上运行。

Whisper 模型**默认不会打包进应用**。用户打开 Transcribe / 语音转文字后，可以选择模型并点击 **Download / 下载**。模型会保存在每个用户自己的目录中：

```text
~/Library/Application Support/Simple Video/whisper-models/
```

这样可以减小应用下载体积，避免修改已签名的 `.app` 包，也让用户自行选择模型大小和准确率之间的取舍。

## 开发

```sh
swift run                 # 从终端运行，便于快速开发
swift build -c release    # release 构建，不生成 .app 包
```
