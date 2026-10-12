# ASCII-only entry point for irm | iex in Windows PowerShell 5.1.
param(
  [string]$InstallDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AI Video Restore'),
  [string]$DesktopDir = [Environment]::GetFolderPath('Desktop')
)
$ErrorActionPreference = 'Stop'
$repairTemp = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-shortcut-' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $repairTemp -Force | Out-Null
  $repairFile = Join-Path $repairTemp 'repair-shortcut-windows.ps1'
  $uri = 'https://raw.githubusercontent.com/qq541253643-art/ai-video-super-resolution/main/repair-shortcut-windows.ps1?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri $uri -OutFile $repairFile
  & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $repairFile -InstallDir $InstallDir -DesktopDir $DesktopDir
  if ($LASTEXITCODE -ne 0) { throw 'Shortcut repair stopped. See the installation status above.' }
}
finally {
  if (Test-Path -LiteralPath $repairTemp) { Remove-Item -LiteralPath $repairTemp -Recurse -Force }
}
