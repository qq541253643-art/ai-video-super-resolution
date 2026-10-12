# Keep this irm | iex entry point ASCII-only and without a UTF-8 BOM.
param(
  [string]$InstallDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AI Video Restore'),
  [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
  [string]$Repository = 'qq541253643-art/ai-video-super-resolution',
  [string]$Branch = 'main',
  [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$bootstrapDir = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-bootstrap-' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null
  $installer = Join-Path $bootstrapDir 'install-windows.ps1'
  $encodedBranch = [Uri]::EscapeDataString($Branch)
  $cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $uri = "https://raw.githubusercontent.com/$Repository/$encodedBranch/install-windows.ps1?t=$cacheBuster"
  Write-Host 'Downloading AI Video Restore installer...' -ForegroundColor Green
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri $uri -OutFile $installer
      break
    } catch {
      if ($attempt -eq 3) { throw }
      Start-Sleep -Seconds 2
    }
  }
  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $installerArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer,
    '-InstallDir', $InstallDir, '-DesktopDir', $DesktopDir,
    '-Repository', $Repository, '-Branch', $Branch
  )
  if ($NoOpen) { $installerArguments += '-NoOpen' }
  & $powershell @installerArguments
  if ($LASTEXITCODE -ne 0) { throw "Installation failed (exit code $LASTEXITCODE)." }
}
finally {
  if (Test-Path -LiteralPath $bootstrapDir) { Remove-Item -LiteralPath $bootstrapDir -Recurse -Force }
}
