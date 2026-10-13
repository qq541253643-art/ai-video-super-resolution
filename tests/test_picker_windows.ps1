param([string]$PickerScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'pick-videos-windows.ps1'), [switch]$SelectFiles)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'fixtures\picker-window-probe.ps1')
[void][PickerWindows]::SetThreadDpiAwarenessContext([IntPtr](-4))
$taskRoot=Join-Path $env:LOCALAPPDATA ('Temp\ai-video-picker-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskRoot | Out-Null
$output=Join-Path $taskRoot 'stdout.txt'
$errorLog=Join-Path $taskRoot 'stderr.txt'
$process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$PickerScript+'"')) -RedirectStandardOutput $output -RedirectStandardError $errorLog -PassThru
$processHandle=$process.Handle
try {
  $dialog=$null
  for($i=0;$i -lt 100;$i++) {
    $dialog=@([PickerWindows]::Find($process.Id) | Where-Object {$_.Class -eq '#32770' -and $_.Visible}) | Select-Object -First 1
    if($dialog){break}
    $process.Refresh()
    if($process.HasExited){throw ('Picker exited before showing: '+(Get-Content $errorLog -Raw))}
    Start-Sleep -Milliseconds 100
  }
  if(-not $dialog){throw 'Dialog not found'}
  $dialog | ConvertTo-Json -Depth 4 -Compress
  if($dialog.DpiAwareness -ne 2){throw 'Not per-monitor DPI aware'}
  if(-not $dialog.TopMost){throw 'Dialog is not topmost'}
  if($SelectFiles) {
    $files=@((Join-Path $taskRoot ([string][char]0x6D4B+[char]0x8BD5+' 1.mp4')), (Join-Path $taskRoot 'second.mp4'))
    foreach($file in $files){New-Item -ItemType File -Path $file | Out-Null}
    $edit=$null
    for($i=0;$i -lt 50;$i++) {
      $edit=[PickerWindows]::Children([IntPtr]$dialog.Handle) | Where-Object {$_.Class -eq 'Edit' -and $_.Id -eq 1148} | Select-Object -First 1
      if($edit){break}
      Start-Sleep -Milliseconds 100
    }
    if(-not $edit){throw 'Filename input is not ready'}
    [void][PickerWindows]::SendMessage([IntPtr]$edit.Handle,0x0C,[IntPtr]::Zero,('"'+($files -join '" "')+'"'))
    [void][PickerWindows]::PostMessage([IntPtr]$dialog.Handle,0x111,[IntPtr]1,[IntPtr]::Zero)
  } else { [void][PickerWindows]::PostMessage([IntPtr]$dialog.Handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
  if(-not $process.WaitForExit(10000)){throw 'Picker did not exit'}
  if($process.ExitCode -ne 0){throw (Get-Content $errorLog -Raw)}
  $actual=@(Get-Content $output -Encoding UTF8)
  if($SelectFiles -and (($actual -join '|') -ne ($files -join '|'))){throw "Unicode output mismatch: $actual"}
  if(-not $SelectFiles -and $actual.Count){throw 'Cancel returned files'}
  Write-Output 'PASS: native picker DPI, topmost, clean exit, and UTF-8 result'
} finally {
  $process.Refresh()
  if(-not $process.HasExited){$process.Kill(); $process.WaitForExit()}
  Write-Output "TEST_ARTIFACTS=$taskRoot"
}
