param([string]$BootstrapUrl = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-shortcut-test-' + [Guid]::NewGuid().ToString('N'))
$install = Join-Path $tempRoot ('Install ' + [char]0x6D4B + [char]0x8BD5)
$desktop = Join-Path $tempRoot 'Redirected Desktop'
$repair = Join-Path $root 'repair-shortcut-windows.ps1'
New-Item -ItemType Directory -Path $install -Force | Out-Null
try {
  $failed = $false
  try { & $repair -InstallDir $install -DesktopDir $desktop } catch { $failed = $true }
  if (-not $failed -or (Test-Path -LiteralPath $desktop)) { throw 'Missing installation must not produce a shortcut.' }
  New-Item -ItemType File -Path (Join-Path $install 'start-windows.ps1') | Out-Null
  $failed = $false
  try { & $repair -InstallDir $install -DesktopDir $desktop } catch { $failed = $true }
  if (-not $failed -or (Test-Path -LiteralPath $desktop)) { throw 'Incomplete installation must not produce a shortcut.' }
  Write-Host 'PASS: missing and incomplete installations are reported before writing a shortcut'

  # Installation markers are fixtures. Only test creation/reading of a real
  # Windows .lnk; never launch it or alter the actual user desktop.
  New-Item -ItemType Directory -Path (Join-Path $install '.venv\Scripts'), (Join-Path $install '.runtime') -Force | Out-Null
  New-Item -ItemType File -Path (Join-Path $install '.venv\Scripts\python.exe'), (Join-Path $install '.runtime\runtime-version.txt') | Out-Null
  if ($BootstrapUrl) {
    $entry = Invoke-RestMethod -UseBasicParsing -Uri $BootstrapUrl
    & ([ScriptBlock]::Create($entry)) -InstallDir $install -DesktopDir $desktop
  } else {
    & $repair -InstallDir $install -DesktopDir $desktop
  }
  $links = @(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk')
  if ($links.Count -ne 1) { throw 'Expected exactly one desktop shortcut.' }
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($links[0].FullName)
  $expectedTarget = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $expectedArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $install 'start-windows.ps1') + '"'
  if ($link.TargetPath -ne $expectedTarget -or $link.Arguments -ne $expectedArgs -or $link.WorkingDirectory -ne $install) { throw 'Shortcut launch properties are incorrect.' }
  & $repair -InstallDir $install -DesktopDir $desktop
  if (@(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk').Count -ne 1) { throw 'Repair should update, not duplicate, the shortcut.' }
  Write-Host 'PASS: real Windows shortcut, redirected desktop, Unicode/space paths and repeated repair'
}
finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
