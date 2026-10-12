param(
  [string]$Repository = 'qq541253643-art/ai-video-super-resolution',
  [string]$Branch = 'main',
  [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$installDir = $PSScriptRoot
$statusPath = Join-Path $installDir 'update-status.txt'
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-update-' + [Guid]::NewGuid().ToString('N'))
$cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$panelUrl = 'http://127.0.0.1:8765'
$didUpdate = $false

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
if ($didUpdate) {
  try {
    Invoke-RestMethod -UseBasicParsing -Method Post -TimeoutSec 2 -Uri "$panelUrl/api/shutdown" -ContentType 'application/json' -Body '{}' | Out-Null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
      Start-Sleep -Milliseconds 200
      try { Invoke-RestMethod -UseBasicParsing -TimeoutSec 1 -Uri "$panelUrl/health" | Out-Null }
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
  $health = Invoke-RestMethod -UseBasicParsing -TimeoutSec 2 -Uri "$panelUrl/health"
  if ($health.ok) {
    if (-not $NoOpen) { Start-Process $panelUrl }
    exit 0
  }
}
catch { }

$arguments = if ($NoOpen) {
  @('-c', 'from ai_video_restore.server import run; run(open_browser=False)')
}
else {
  @('-m', 'ai_video_restore')
}
Set-Location $installDir
& $python @arguments
