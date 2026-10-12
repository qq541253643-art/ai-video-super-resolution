# AI 视频高清修复

Windows 本机批量视频 AI 超分工具。浏览器只负责操作，Real-ESRGAN、CodeFormer 和 FFmpeg 全部在当前电脑运行，素材不会上传云端。

版本号以 [VERSION](VERSION) 和面板显示为准。

## 能做什么

- 用真实 Real-ESRGAN 模型生成“自然增强”和“高清增强”两个版本。
- 可选 CodeFormer 人脸增强，默认关闭并使用 0.9 高保真权重，尽量减少身份特征变化。
- 批量导入，顺序处理，显示当前步骤、推理帧率和预计完成时间。
- 自动识别分辨率、平均帧率、时长和音频。
- 固定输出 1080×1920，完整保留原始画面比例；主体不裁切，空余区域使用模糊背景填充。
- 保留音频并重新同步，输出 iPhone 兼容的 H.264 High / yuv420p + AAC MP4。
- 默认 tile=256，针对 RTX 2060 Super 8GB；显存不足时可在面板改为 128。

输出自动保存在源视频文件夹：

- `自然+原名.mp4`
- `高清+原名.mp4`
- `人脸+原名.mp4`（开启人脸增强时）
- `对比+原名.jpg`
- `报告+原名.json`

## 一条命令安装

在 Windows 10/11 PowerShell 中粘贴并回车：

```powershell
irm https://raw.githubusercontent.com/qq541253643-art/ai-video-super-resolution/main/install.ps1 | iex
```

安装器会：

1. 检测 NVIDIA 显卡；
2. 自动下载缺失的 `uv`、FFmpeg 和 FFprobe 到工具的 `.runtime` 目录，无需 `winget` 或 Microsoft Store；
3. 部署 Real-ESRGAN NCNN Vulkan、CodeFormer 与模型权重；
4. 安装到“文档\AI Video Restore”（使用英文运行路径，兼容模型引擎）；
5. 在桌面创建“AI 视频高清修复”快捷方式。

首次安装需下载数 GB 的 PyTorch 与模型文件，耗时取决于网络。以后双击桌面快捷方式会先检查仓库更新；断网或检查失败时继续使用本地版本。

安装日志自动保存到桌面 `AI-install-日期-时间.txt`。依赖下载失败会重试三次；Windows 自带 curl 可用时，模型和工具下载支持断点续传，失败保留 `.download` 文件，重跑原命令即可继续。没有 curl 的旧系统使用兼容下载方式重试，不支持该次下载续传。PyTorch 等 Python 包由 uv 管理下载缓存并重试，不保证单个 wheel 的字节级续传。不要删除安装目录和缓存。

CodeFormer 三个模型文件均校验固定 SHA-256。只有真实 Real-ESRGAN 推理、CodeFormer CUDA 推理与人脸检测/解析模型加载、H.264 编码和面板健康接口全部通过后，才写入完成标记并创建桌面快捷方式。小样本自检报告保存在 `.runtime/install-selftest.json`；它验证环境可运行，不替代真人视频画质测试。失败时发送桌面安装日志，无需开放远程访问。

v0.1.1 修复了 Windows PowerShell 5.1 执行一键安装时的 `InvalidLeftHandSide` 报错。入口脚本为无 BOM 的 ASCII 文本，中文安装器下载到本地后通过 `-File` 执行；执行策略仅在安装进程内使用 Bypass，不修改系统设置。

v0.1.2 支持没有 `uv`、`winget` 和 FFmpeg 的电脑：直接下载 [uv 发布包](https://github.com/astral-sh/uv/releases/tag/0.13.0) 与 [Gyan FFmpeg 发布包](https://github.com/GyanD/codexffmpeg/releases/tag/9.0.2)，校验 SHA-256 后部署。每次启动自动加载本地依赖路径，不修改系统 PATH；失败后可直接重跑安装命令。

## 手动启动

如果已经安装成功但桌面没有快捷方式，在同一台电脑的 PowerShell 中执行：

```powershell
irm https://raw.githubusercontent.com/qq541253643-art/ai-video-super-resolution/main/repair-shortcut.ps1 | iex
```

修复入口只补建快捷方式，不重新下载模型。安装中途失败或仍在进行时会提示“安装尚未完成”；请先检查原安装窗口。快捷方式按 Windows 的实际桌面位置创建，支持重定向桌面。

双击 `打开AI视频高清修复.cmd`，或运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\start-windows.ps1
```

本机面板只监听 `127.0.0.1:8765`，不会向局域网开放。

## 5 秒真实模型测试

环境部署完成后：

```powershell
.\test-5s.ps1 -InputPath 'D:\视频\视频1.mp4','D:\视频\视频2.mp4'
```

该命令会对每个视频前 5 秒实际运行 Real-ESRGAN 和 CodeFormer，不使用 Lanczos 冒充 AI 推理。自然版与高清版复用同一次 AI 推理，结果写回视频所在目录，汇总报告保存到 `test-results\five-second-summary.json`。

## 技术说明

- 高清增强：官方 `realesrgan-x4plus` 以原生 4× 模式完成 AI 推理，再高质量缩放到目标画布；原生倍率可避免官方 NCNN 程序在非原生倍率 Tile 推理时出现拼块错位。
- 自然增强：同一次真实 Real-ESRGAN 推理结果与原始画面按 78%/22% 做保真融合，减少重复推理和过度锐化；不是普通缩放冒充 AI。
- 人脸增强：高清增强背景 + CodeFormer 人脸恢复。
- 视频：FFmpeg 解码、CFR 图像序列重建、AAC 音频同步与 H.264 编码。
- GPU：Real-ESRGAN 使用官方 NCNN Vulkan 实现；CodeFormer 使用 PyTorch CUDA。

`报告+原名.json` 包含模型阶段 FPS、GPU 显存基线/峰值/增量、总耗时、输出路径和音视频校验结果。

## 开发与测试

核心服务只依赖 Python 标准库：

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
.\.venv\Scripts\python.exe -m ai_video_restore
```

模型与运行时目录（`.runtime`、`.deps`、`.venv`）、测试视频和生成结果不会提交到 GitHub。

## 开源组件

- [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)
- [Real-ESRGAN NCNN Vulkan](https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan)（模型随 Real-ESRGAN v0.2.5.0 官方发布包部署）
- [CodeFormer](https://github.com/sczhou/CodeFormer)
- [FFmpeg](https://ffmpeg.org/)

本仓库不重新训练模型；请同时遵守上述项目各自的许可证。

本项目自有代码采用 [MIT License](LICENSE)。第三方程序与模型继续适用各自许可证。
