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
$logStarted = $false
$environmentReady = $false
$logPath = Join-Path $DesktopDir ('AI-install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')

function Test-RelativePath([string]$Relative) {
  if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains('..')) {
    throw "安装清单路径不安全：$Relative"
  }
}

try {
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  New-Item -ItemType Directory -Path $DesktopDir -Force | Out-Null
  Start-Transcript -LiteralPath $logPath -Force | Out-Null
  $logStarted = $true
  Write-Host "安装日志：$logPath"
  $uri = "https://codeload.github.com/$Repository/zip/refs/heads/$([Uri]::EscapeDataString($Branch))`?t=$cacheBuster"
  $archive = Join-Path $tempDir 'repository.zip'
  $expanded = Join-Path $tempDir 'repository'
  Write-Host '正在下载 AI 视频高清修复…' -ForegroundColor Green
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'AI-Video-Restorer-Installer' } -Uri $uri -OutFile $archive
      break
    } catch {
      if ($attempt -eq 3) { throw }
      Write-Warning "安装包下载失败，正在重试（$attempt/3）。"
      Start-Sleep -Seconds 2
    }
  }
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
  $environmentReady = $true

  $shortcutPath = & (Join-Path $InstallDir 'repair-shortcut-windows.ps1') -InstallDir $InstallDir -DesktopDir $DesktopDir -PassThru

  Write-Host "安装完成：$InstallDir" -ForegroundColor Green
  Write-Host "桌面快捷方式：$shortcutPath"
  if (-not $NoOpen) { Start-Process -FilePath $shortcutPath }
}
catch {
  if ($environmentReady) {
    Write-Host "AI 环境已就绪，但桌面启动配置失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "无需删除模型；可以直接运行安装目录中的 start-windows.ps1：$InstallDir" -ForegroundColor Yellow
  } else {
    Write-Host "安装未完成：$($_.Exception.Message)" -ForegroundColor Red
  }
  Write-Host "安装日志：$logPath" -ForegroundColor Yellow
  Write-Host '已下载的依赖会保留。重新运行同一条安装命令即可重试。'
  if (-not $NoOpen) { [void](Read-Host '请保留日志，按 Enter 退出') }
  exit 1
}
finally {
  if ($logStarted) { Stop-Transcript | Out-Null }
  if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}
