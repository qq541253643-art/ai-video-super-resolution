param(
  [bool]$InstallCodeFormer = $true,
  [switch]$BasicToolsOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$runtimeDir = Join-Path $projectRoot '.runtime'
$depsDir = Join-Path $projectRoot '.deps'
$venvDir = Join-Path $projectRoot '.venv'
$ncnnDir = Join-Path $runtimeDir 'realesrgan'
$codeFormerDir = Join-Path $depsDir 'CodeFormer'
$codeFormerCommit = 'b33cc7d639d6545bfcccc7e0bc6ae51f24e79c2b'
$ncnnUrl = 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip'
. (Join-Path $projectRoot 'runtime-windows.ps1')

function Write-Step([string]$Message) {
  Write-Host "`n==> $Message" -ForegroundColor Green
}

function Download-Zip([string]$Uri, [string]$Destination) {
  $temporary = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $temporary -Force | Out-Null
  try {
    $zip = "$Destination.zip"
    Get-VerifiedDownload $Uri $zip
    if ((Get-Item $zip).Length -eq 0) { throw "下载文件为空：$Uri" }
    $expanded = Join-Path $temporary 'expanded'
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force
    $rootItems = @(Get-ChildItem -LiteralPath $expanded)
    $source = if ($rootItems.Count -eq 1 -and $rootItems[0].PSIsContainer) { $rootItems[0].FullName } else { $expanded }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $Destination -Recurse -Force
  }
  finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
  }
}

function Invoke-UvInstall([string[]]$Arguments) {
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    & uv @Arguments
    if ($LASTEXITCODE -eq 0) { return }
    if ($attempt -eq 3) { throw 'Python 依赖安装失败；下载缓存已保留，请重跑安装命令。' }
    Write-Warning "依赖下载失败，保留 uv 缓存并重试（$attempt/3）"
    Start-Sleep -Seconds 2
  }
}

Write-Step '检测 NVIDIA 显卡'
$smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
if (-not (Test-Path -LiteralPath $smi)) { throw '未检测到 NVIDIA 驱动，请先安装或更新 NVIDIA Studio Driver。' }
$gpu = & $smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits | Select-Object -First 1
Write-Host "GPU: $gpu"

Write-Step '检测并安装 uv、FFmpeg（无需 winget）'
Ensure-BasicTools $runtimeDir

Write-Step '创建 Python 3.11 本机环境'
$savedPythonMirror = $env:UV_PYTHON_INSTALL_MIRROR
try {
  # Use the same official GitHub release host as the other dependencies.
  # Preserve an explicit mirror chosen by the user.
  if (-not $env:UV_PYTHON_INSTALL_MIRROR) {
    $env:UV_PYTHON_INSTALL_MIRROR = 'https://github.com/astral-sh/python-build-standalone/releases/download'
  }
  uv python install 3.11
}
finally { $env:UV_PYTHON_INSTALL_MIRROR = $savedPythonMirror }
if ($LASTEXITCODE -ne 0) { throw 'Python 3.11 下载失败。' }
if (-not (Test-Path -LiteralPath (Join-Path $venvDir 'Scripts\python.exe'))) {
  uv venv $venvDir --python 3.11
  if ($LASTEXITCODE -ne 0) { throw 'Python 虚拟环境创建失败。' }
}
$python = Join-Path $venvDir 'Scripts\python.exe'
if ($BasicToolsOnly) {
  Write-Step '基础依赖与 Python 已就绪（仅依赖检测模式）'
  return
}
$runtimeMarker = Join-Path $runtimeDir 'runtime-version.txt'
if (Test-Path -LiteralPath $runtimeMarker) { Remove-Item -LiteralPath $runtimeMarker -Force }

if (-not (Test-Path -LiteralPath (Join-Path $ncnnDir 'realesrgan-ncnn-vulkan.exe'))) {
  Write-Step '部署 Real-ESRGAN NCNN Vulkan 模型'
  New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
  Download-Zip $ncnnUrl $ncnnDir
}

if ($InstallCodeFormer) {
  if (-not (Test-Path -LiteralPath (Join-Path $codeFormerDir 'inference_codeformer.py'))) {
    Write-Step '部署 CodeFormer 源码'
    New-Item -ItemType Directory -Path $depsDir -Force | Out-Null
    Download-Zip "https://codeload.github.com/sczhou/CodeFormer/zip/$codeFormerCommit" $codeFormerDir
  }

  Write-Step '安装 CodeFormer GPU 依赖（首次下载较大）'
  # Fetch only CUDA wheels here. Resolve ordinary dependencies from PyPI below,
  # rather than routing all small packages through the CUDA download server.
  Invoke-UvInstall @('pip', 'install', '--python', $python, 'torch==2.7.1+cu128', 'torchvision==0.22.1+cu128', '--no-deps', '--index-url', 'https://download.pytorch.org/whl/cu128')
  Invoke-UvInstall @('pip', 'install', '--python', $python, 'torch==2.7.1+cu128', 'torchvision==0.22.1+cu128', 'numpy<2', 'opencv-python', 'pillow', 'pyyaml', 'requests', 'scipy', 'scikit-image', 'tqdm', 'addict', 'future', 'lmdb', 'yapf', 'lpips', 'gdown', 'filterpy', 'numba', '--index-url', 'https://pypi.org/simple')
  & $python -c "import sys, torch; print('PyTorch CUDA:', torch.__version__, torch.cuda.is_available()); sys.exit(0 if torch.cuda.is_available() else 1)"
  if ($LASTEXITCODE -ne 0) { throw 'PyTorch 无法调用显卡，请更新 NVIDIA Studio Driver 后重试。' }

  $degradation = Join-Path $codeFormerDir 'basicsr\data\degradations.py'
  if (Test-Path -LiteralPath $degradation) {
    $content = [IO.File]::ReadAllText($degradation, [Text.Encoding]::UTF8)
    $content = $content.Replace('from torchvision.transforms.functional_tensor import rgb_to_grayscale', 'from torchvision.transforms.functional import rgb_to_grayscale')
    [IO.File]::WriteAllText($degradation, $content, (New-Object Text.UTF8Encoding($false)))
  }

  Write-Step '下载 CodeFormer 与人脸检测模型'
  Get-VerifiedDownload 'https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth' (Join-Path $codeFormerDir 'weights\CodeFormer\codeformer.pth') '1009E537E0C2A07D4CABCE6355F53CB66767CD4B4297EC7A4A64CA4B8A5684B7'
  Get-VerifiedDownload 'https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/detection_mobilenet0.25_Final.pth' (Join-Path $codeFormerDir 'weights\facelib\detection_mobilenet0.25_Final.pth') '2979B33FFAFDA5D74B6948CD7A5B9A7A62F62B949CEF24E95FD15D2883A65220'
  Get-VerifiedDownload 'https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/parsing_parsenet.pth' (Join-Path $codeFormerDir 'weights\facelib\parsing_parsenet.pth') '3D558D8D0E42C20224F13CF5A29C79EBA2D59913419F945545D8CF7B72920DE2'
  Write-Step '部署 Real-ESRGAN CUDA 备用模型（约 64 MB）'
  Get-VerifiedDownload 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth' (Join-Path $ncnnDir 'RealESRGAN_x4plus.pth') '4FA0D38905F75AC06EB49A7951B426670021BE3018265FD191D2125DF9D682F1'
}

Write-Step '实际运行模型、编码与面板自检（通过后才创建快捷方式）'
Push-Location $projectRoot
try {
  $checkArgs = @('-m', 'ai_video_restore.selftest')
  if (-not $InstallCodeFormer) { $checkArgs += '--skip-face' }
  & $python @checkArgs
  if ($LASTEXITCODE -ne 0) { throw '安装自检未通过。请保留日志并重跑安装命令。' }
} finally { Pop-Location }

$manifest = Join-Path $projectRoot 'manifest.json'
if (Test-Path -LiteralPath $manifest) {
  $runtimeVersion = ([IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8) | ConvertFrom-Json).runtime_version
  if ($runtimeVersion) { Set-Content -LiteralPath (Join-Path $runtimeDir 'runtime-version.txt') -Encoding ascii -Value $runtimeVersion }
}

Write-Step '环境部署完成'
Write-Host 'Real-ESRGAN、FFmpeg 与本机服务已就绪。' -ForegroundColor Green
if ($InstallCodeFormer) { Write-Host 'CodeFormer 已安装，面板中仍默认关闭。' }
