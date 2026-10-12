# AI 视频高清修复

Windows 本机批量视频 AI 超分工具。浏览器只负责操作，Real-ESRGAN、CodeFormer 和 FFmpeg 全部在当前电脑运行，素材不会上传云端。

当前版本：**v0.1.0**

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
2. 安装缺失的 `uv` 和 FFmpeg；
3. 部署 Real-ESRGAN NCNN Vulkan、CodeFormer 与模型权重；
4. 安装到“文档\AI Video Restore”（使用英文运行路径，兼容模型引擎）；
5. 在桌面创建“AI 视频高清修复”快捷方式。

首次安装需下载数 GB 的 PyTorch 与模型文件，耗时取决于网络。以后双击桌面快捷方式会先检查仓库更新；断网或检查失败时继续使用本地版本。

## 手动启动

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
