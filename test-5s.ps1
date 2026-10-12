param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string[]]$InputPath,
  [int]$Tile = 256,
  [switch]$NoFace
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$python = Join-Path $projectRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw '运行环境未安装，请先执行 setup-windows.ps1。' }
$winGetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
if (Test-Path -LiteralPath $winGetLinks) { $env:Path = "$winGetLinks;$env:Path" }
. (Join-Path $projectRoot 'runtime-windows.ps1')
Add-RuntimePath (Join-Path $projectRoot '.runtime')
$summary = Join-Path $projectRoot 'test-results\five-second-summary.json'
$arguments = @('-m', 'ai_video_restore.cli') + $InputPath + @('--limit', '5', '--tile', [string]$Tile, '--summary', $summary)
if (-not $NoFace) { $arguments += '--face' }
Set-Location $projectRoot
& $python @arguments
if ($LASTEXITCODE -ne 0) { throw '5 秒测试失败。' }
Write-Host "测试报告：$summary" -ForegroundColor Green
