# Integration test: downloads real binaries and builds a real Python venv.
# Run with Windows PowerShell 5.1; no models or desktop shortcuts are installed.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-no-winget-' + [Guid]::NewGuid().ToString('N'))
$savedPath = $env:Path
$savedPythonDir = $env:UV_PYTHON_INSTALL_DIR
$cleanPath = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
  Copy-Item -LiteralPath (Join-Path $root 'setup-windows.ps1') -Destination $testRoot
  Copy-Item -LiteralPath (Join-Path $root 'runtime-windows.ps1') -Destination $testRoot
  $env:Path = $cleanPath
  $env:UV_PYTHON_INSTALL_DIR = Join-Path $testRoot 'python'
  foreach ($tool in @('uv.exe', 'ffmpeg.exe', 'ffprobe.exe', 'winget.exe')) {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { throw "Test environment unexpectedly exposes $tool" }
  }
  Write-Host 'PASS: no uv, FFmpeg, FFprobe or winget on PATH'
  & (Join-Path $testRoot 'setup-windows.ps1') -BasicToolsOnly
  if ($LASTEXITCODE -ne 0) { throw 'Basic dependency setup failed.' }

  $freshCheck = Join-Path $testRoot 'fresh-check.ps1'
  $checkText = @'
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime-windows.ps1')
Add-RuntimePath (Join-Path $PSScriptRoot '.runtime')
$python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
& $python -c "import shutil; assert shutil.which('ffmpeg'); assert shutil.which('ffprobe'); print('PASS: Python discovers portable FFmpeg and FFprobe')"
if ($LASTEXITCODE -ne 0) { throw 'Python could not discover dependencies.' }
$sample = Join-Path $PSScriptRoot 'sample.mp4'
ffmpeg -v error -y -f lavfi -i testsrc2=size=64x64:rate=10 -t 0.2 -c:v libx264 -pix_fmt yuv420p $sample
if ($LASTEXITCODE -ne 0) { throw 'Portable FFmpeg could not encode H.264.' }
$codec = ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 $sample
if ($LASTEXITCODE -ne 0 -or $codec -ne 'h264') { throw 'Portable FFprobe could not validate the encoded video.' }
Write-Host 'PASS: fresh process encodes and probes real H.264 using portable tools'
# A second setup must reuse downloads even with networking unavailable.
function Invoke-WebRequest { throw 'Repeat setup must not download installed tools.' }
Ensure-BasicTools (Join-Path $PSScriptRoot '.runtime')
Write-Host 'PASS: repeat basic-tool setup reuses installed binaries offline'
'@
  [IO.File]::WriteAllText($freshCheck, $checkText, [Text.Encoding]::ASCII)
  $env:Path = $cleanPath
  & $powershell -NoProfile -ExecutionPolicy Bypass -File $freshCheck
  if ($LASTEXITCODE -ne 0) { throw 'Fresh-process validation failed.' }
  Write-Host 'PASS: no-winget integration test complete'
}
finally {
  $env:Path = $savedPath
  $env:UV_PYTHON_INSTALL_DIR = $savedPythonDir
  Write-Host "Test environment retained at: $testRoot"
}
