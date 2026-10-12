param(
  [bool]$InstallCodeFormer = $true
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

function Write-Step([string]$Message) {
  Write-Host "`n==> $Message" -ForegroundColor Green
}

function Refresh-Path {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machine;$user;$env:LOCALAPPDATA\Microsoft\WinGet\Links"
}

function Ensure-WingetPackage([string]$Command, [string]$PackageId) {
  if (Get-Command $Command -ErrorAction SilentlyContinue) { return }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "系统缺少 $Command，也找不到 winget。请先安装 Windows 应用安装程序。"
  }
  Write-Step "安装 $PackageId"
  winget install --id $PackageId --exact --accept-package-agreements --accept-source-agreements --silent
  if ($LASTEXITCODE -ne 0) { throw "$PackageId 安装失败，退出码 $LASTEXITCODE" }
  Refresh-Path
}

function Download-Zip([string]$Uri, [string]$Destination) {
  $temporary = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $temporary -Force | Out-Null
  try {
    $zip = Join-Path $temporary 'download.zip'
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'AI-Video-Restorer-Setup' } -Uri $Uri -OutFile $zip
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

function Download-File([string]$Uri, [string]$Destination) {
  if (Test-Path -LiteralPath $Destination) { return }
  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $partial = "$Destination.download"
  try {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 900 -Headers @{ 'User-Agent' = 'AI-Video-Restorer-Setup' } -Uri $Uri -OutFile $partial
    if ((Get-Item $partial).Length -eq 0) { throw "下载文件为空：$Uri" }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
  }
  finally {
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
  }
}

Write-Step '检测 NVIDIA 显卡'
$smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
if (-not (Test-Path -LiteralPath $smi)) { throw '未检测到 NVIDIA 驱动，请先安装或更新 NVIDIA Studio Driver。' }
$gpu = & $smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits | Select-Object -First 1
Write-Host "GPU: $gpu"

Ensure-WingetPackage 'uv' 'astral-sh.uv'
Ensure-WingetPackage 'ffmpeg' 'Gyan.FFmpeg'

Write-Step '创建 Python 3.11 本机环境'
uv python install 3.11
if ($LASTEXITCODE -ne 0) { throw 'Python 3.11 下载失败。' }
if (-not (Test-Path -LiteralPath (Join-Path $venvDir 'Scripts\python.exe'))) {
  uv venv $venvDir --python 3.11
  if ($LASTEXITCODE -ne 0) { throw 'Python 虚拟环境创建失败。' }
}
$python = Join-Path $venvDir 'Scripts\python.exe'

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
  uv pip install --python $python torch==2.7.1 torchvision==0.22.1 --index-url https://download.pytorch.org/whl/cu128
  if ($LASTEXITCODE -ne 0) { throw 'PyTorch CUDA 依赖安装失败。' }
  uv pip install --python $python 'numpy<2' opencv-python pillow pyyaml requests scipy scikit-image tqdm addict future lmdb yapf lpips gdown filterpy numba
  if ($LASTEXITCODE -ne 0) { throw 'CodeFormer Python 依赖安装失败。' }
  & $python -c "import sys, torch; print('PyTorch CUDA:', torch.__version__, torch.cuda.is_available()); sys.exit(0 if torch.cuda.is_available() else 1)"
  if ($LASTEXITCODE -ne 0) { throw 'PyTorch 无法调用显卡，请更新 NVIDIA Studio Driver 后重试。' }

  $degradation = Join-Path $codeFormerDir 'basicsr\data\degradations.py'
  if (Test-Path -LiteralPath $degradation) {
    $content = [IO.File]::ReadAllText($degradation, [Text.Encoding]::UTF8)
    $content = $content.Replace('from torchvision.transforms.functional_tensor import rgb_to_grayscale', 'from torchvision.transforms.functional import rgb_to_grayscale')
    [IO.File]::WriteAllText($degradation, $content, (New-Object Text.UTF8Encoding($false)))
  }

  Write-Step '下载 CodeFormer 与人脸检测模型'
  Download-File 'https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth' (Join-Path $codeFormerDir 'weights\CodeFormer\codeformer.pth')
  Download-File 'https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/detection_mobilenet0.25_Final.pth' (Join-Path $codeFormerDir 'weights\facelib\detection_mobilenet0.25_Final.pth')
  Download-File 'https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/parsing_parsenet.pth' (Join-Path $codeFormerDir 'weights\facelib\parsing_parsenet.pth')
}

$manifest = Join-Path $projectRoot 'manifest.json'
if (Test-Path -LiteralPath $manifest) {
  $runtimeVersion = ([IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8) | ConvertFrom-Json).runtime_version
  if ($runtimeVersion) { Set-Content -LiteralPath (Join-Path $runtimeDir 'runtime-version.txt') -Encoding ascii -Value $runtimeVersion }
}

Write-Step '环境部署完成'
Write-Host 'Real-ESRGAN、FFmpeg 与本机服务已就绪。' -ForegroundColor Green
if ($InstallCodeFormer) { Write-Host 'CodeFormer 已安装，面板中仍默认关闭。' }
