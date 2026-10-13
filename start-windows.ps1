param(
  [string]$Repository = 'qq541253643-art/ai-video-super-resolution',
  [string]$Branch = 'main',
  [switch]$NoOpen,
  [ValidateRange(1024, 65535)][int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
$installDir = $PSScriptRoot
$statusPath = Join-Path $installDir 'update-status.txt'
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-update-' + [Guid]::NewGuid().ToString('N'))
$cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$panelUrl = "http://127.0.0.1:$Port"
$didUpdate = $false
$logDir = Join-Path $installDir '.runtime\logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$launcherLog = Join-Path $logDir 'launcher.log'
Start-Transcript -LiteralPath $launcherLog -Append | Out-Null

trap {
  $failure = "启动失败：$($_.Exception.Message)`r`n日志目录：$logDir"
  Write-Host $failure -ForegroundColor Red
  try { Stop-Transcript | Out-Null } catch { }
  if (-not $NoOpen) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($failure, 'AI 视频高清修复')
  }
  exit 1
}

function Get-RepositorySnapshot {
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
  $encodedBranch = [Uri]::EscapeDataString($Branch)
  $uri = "https://codeload.github.com/$Repository/zip/refs/heads/$encodedBranch`?t=$cacheBuster"
  $archive = Join-Path $tempDir 'repository.zip'
  $expanded = Join-Path $tempDir 'repository'
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'AI-Video-Restorer-Updater' } -Uri $uri -OutFile $archive
  Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
  $snapshot = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
  if ($null -eq $snapshot) { throw '更新包无法打开。' }
  return $snapshot.FullName
}

function Test-RelativePath([string]$Relative) {
  if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains('..')) {
    throw "更新清单路径不安全：$Relative"
  }
}

function Get-PanelHealth {
  $health = Invoke-RestMethod -UseBasicParsing -TimeoutSec 2 -Uri "$panelUrl/health"
  if (-not $health.ok) { throw '端口未运行 AI 视频高清修复服务。' }
  if ($health.app -ne 'ai-video-restore') {
    # Older releases have no app ID. Verify their application-specific fields
    # before reusing or shutting down a service on a shared localhost port.
    $status = Invoke-RestMethod -UseBasicParsing -TimeoutSec 2 -Uri "$panelUrl/api/status"
    $names = @($status.PSObject.Properties.Name)
    if ('realesrgan' -notin $names -or 'codeformer' -notin $names -or 'gpu' -notin $names) {
      throw '端口被其他程序占用；不会停止该程序。'
    }
  }
  return $health
}

# Opening another browser tab must not update/restart a busy background worker.
try {
  Get-PanelHealth | Out-Null
  $jobs = Invoke-RestMethod -UseBasicParsing -TimeoutSec 2 -Uri "$panelUrl/api/jobs"
  if (@($jobs.jobs | Where-Object { $_.status -in @('running', 'queued') }).Count) {
    Write-Host '正在处理视频，继续使用当前服务；空闲时重新打开可检查更新。'
    if (-not $NoOpen) { Start-Process $panelUrl }
    Stop-Transcript | Out-Null
    exit 0
  }
} catch { }

try {
  $snapshot = Get-RepositorySnapshot
  $manifestPath = Join-Path $snapshot 'manifest.json'
  $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $updated = New-Object System.Collections.Generic.List[string]
  foreach ($file in $manifest.files) {
    $relative = [string]$file.path
    Test-RelativePath $relative
    $source = Join-Path $snapshot $relative
    $target = Join-Path $installDir $relative
    if (-not (Test-Path -LiteralPath $source)) { throw "更新包缺少文件：$relative" }
    $expected = ([string]$file.sha256).ToUpperInvariant()
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne $expected) { throw "更新文件校验失败：$relative" }
    $current = if (Test-Path -LiteralPath $target) { (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash } else { '' }
    if ($current -eq $expected) { continue }
    $targetDir = Split-Path -Parent $target
    if ($targetDir) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $target -Force
    $updated.Add($relative)
  }
  $didUpdate = $updated.Count -gt 0
  Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $installDir 'manifest.json') -Force
  $message = if ($updated.Count) { "已更新到 v$($manifest.version)：$($updated.Count) 个文件" } else { "已是最新版本 v$($manifest.version)" }
  Set-Content -LiteralPath $statusPath -Encoding utf8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n$message"
}
catch {
  Set-Content -LiteralPath $statusPath -Encoding utf8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n更新检查失败，继续使用已安装版本：$($_.Exception.Message)"
}
finally {
  if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}

$runtimeMarker = Join-Path $installDir '.runtime\runtime-version.txt'
$manifest = [IO.File]::ReadAllText((Join-Path $installDir 'manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$installedRuntime = if (Test-Path -LiteralPath $runtimeMarker) { (Get-Content -LiteralPath $runtimeMarker -Raw).Trim() } else { '' }
if ($installedRuntime -ne [string]$manifest.runtime_version) {
  & (Join-Path $installDir 'setup-windows.ps1')
  if ($LASTEXITCODE -ne 0) { throw '运行环境更新失败。' }
}

# A panel left running in the background still has the previous Python code in
# memory. Ask it to exit after a successful update so this launch uses the new
# version immediately. Older installations without this endpoint simply keep
# running and will pick up the endpoint after their next normal restart.
$needsRestart = $didUpdate
$running = $null
try {
  $running = Get-PanelHealth
  $needsRestart = $needsRestart -or ($running.version -ne $manifest.version)
} catch { }
if ($needsRestart -and $running) {
  try {
    Invoke-RestMethod -UseBasicParsing -Method Post -TimeoutSec 2 -Uri "$panelUrl/api/shutdown" -ContentType 'application/json' -Body '{}' | Out-Null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
      Start-Sleep -Milliseconds 200
      try { Get-PanelHealth | Out-Null }
      catch { break }
    }
  }
  catch { }
}

$winGetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
if (Test-Path -LiteralPath $winGetLinks) { $env:Path = "$winGetLinks;$env:Path" }
. (Join-Path $installDir 'runtime-windows.ps1')
Add-RuntimePath (Join-Path $installDir '.runtime')
$python = Join-Path $installDir '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw 'Python 环境不存在，请重新运行安装命令。' }

try {
  $health = Get-PanelHealth
  if ($health.ok) {
    if (-not $NoOpen) { Start-Process $panelUrl }
    Stop-Transcript | Out-Null
    exit 0
  }
}
catch { }

$pythonw = Join-Path $installDir '.venv\Scripts\pythonw.exe'
if (-not (Test-Path -LiteralPath $pythonw)) { throw '缺少后台启动程序 pythonw.exe，请重新运行安装命令。' }
$service = Start-Process -FilePath $pythonw -ArgumentList @('-m', 'ai_video_restore.background', '--port', $Port) -WorkingDirectory $installDir -PassThru
$healthy = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
  Start-Sleep -Milliseconds 500
  $service.Refresh()
  if ($service.HasExited) { break }
  try {
    $health = Get-PanelHealth
    if ($health.ok) { $healthy = $true; break }
  } catch { }
}
if (-not $healthy) { throw "后台服务未通过启动检查。请查看 $logDir\server.log" }
Write-Host "后台服务已启动：$panelUrl"
if (-not $NoOpen) { Start-Process $panelUrl }
Stop-Transcript | Out-Null
