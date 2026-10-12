# Downloaded and executed with -File by the ASCII install.ps1 bootstrap.
param(
  [string]$InstallDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AI Video Restore'),
  [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
  [string]$Repository = 'qq541253643-art/ai-video-super-resolution',
  [string]$Branch = 'main',
  [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-install-' + [Guid]::NewGuid().ToString('N'))
$cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

function Test-RelativePath([string]$Relative) {
  if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains('..')) {
    throw "安装清单路径不安全：$Relative"
  }
}

try {
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  New-Item -ItemType Directory -Path $DesktopDir -Force | Out-Null
  $uri = "https://codeload.github.com/$Repository/zip/refs/heads/$([Uri]::EscapeDataString($Branch))`?t=$cacheBuster"
  $archive = Join-Path $tempDir 'repository.zip'
  $expanded = Join-Path $tempDir 'repository'
  Write-Host '正在下载 AI 视频高清修复…' -ForegroundColor Green
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'AI-Video-Restorer-Installer' } -Uri $uri -OutFile $archive
  Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
  $snapshot = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
  if ($null -eq $snapshot) { throw '安装包无法打开。' }
  $manifestPath = Join-Path $snapshot.FullName 'manifest.json'
  $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  foreach ($file in $manifest.files) {
    $relative = [string]$file.path
    Test-RelativePath $relative
    $source = Join-Path $snapshot.FullName $relative
    $target = Join-Path $InstallDir $relative
    if (-not (Test-Path -LiteralPath $source)) { throw "安装包缺少文件：$relative" }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne ([string]$file.sha256).ToUpperInvariant()) { throw "文件校验失败：$relative" }
    $targetDir = Split-Path -Parent $target
    if ($targetDir) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $target -Force
  }
  Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $InstallDir 'manifest.json') -Force

  & (Join-Path $InstallDir 'setup-windows.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'AI 环境部署失败。' }

  $shortcutPath = Join-Path $DesktopDir 'AI 视频高清修复.lnk'
  & (Join-Path $InstallDir 'repair-shortcut-windows.ps1') -InstallDir $InstallDir -DesktopDir $DesktopDir

  Write-Host "安装完成：$InstallDir" -ForegroundColor Green
  Write-Host "桌面快捷方式：$shortcutPath"
  if (-not $NoOpen) { Start-Process -FilePath $shortcutPath }
}
catch {
  Write-Error "安装失败：$($_.Exception.Message)"
  exit 1
}
finally {
  if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}
