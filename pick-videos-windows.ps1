# Run in a dedicated STA process: DPI context must be set before any window exists.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VideoPickerWindow {
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
}
'@
try {
  if ([VideoPickerWindow]::SetThreadDpiAwarenessContext([IntPtr](-4)) -eq [IntPtr]::Zero) {
    [void][VideoPickerWindow]::SetProcessDPIAware()
  }
} catch [System.Management.Automation.MethodInvocationException] {
  [void][VideoPickerWindow]::SetProcessDPIAware()
}
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
$owner = New-Object System.Windows.Forms.Form
$dialog = New-Object System.Windows.Forms.OpenFileDialog
try {
  # An owned topmost dialog remains above the browser even when the background
  # process is not allowed to steal keyboard focus. Dispose the owner on exit.
  $owner.ShowInTaskbar = $false
  $owner.TopMost = $true
  $owner.Opacity = 0
  $owner.FormBorderStyle = 'None'
  $owner.Size = New-Object Drawing.Size(1, 1)
  $owner.StartPosition = 'Manual'
  $area = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
  $owner.Location = New-Object Drawing.Point(($area.Left + [int]($area.Width / 2)), ($area.Top + [int]($area.Height / 2)))
  $owner.Show()
  $owner.Activate()
  [void][VideoPickerWindow]::SetForegroundWindow($owner.Handle)
  $dialog.Multiselect = $true
  $dialog.Filter = '视频文件|*.mp4;*.mov;*.mkv;*.avi;*.m4v;*.webm|所有文件|*.*'
  $dialog.Title = '选择需要 AI 高清修复的视频'
  if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
    $dialog.FileNames | ForEach-Object { [Console]::Out.WriteLine($_) }
  }
} finally {
  $dialog.Dispose()
  $owner.Dispose()
}
