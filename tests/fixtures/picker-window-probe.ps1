Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class PickerWindows {
  public delegate bool Callback(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback f, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, Callback f, IntPtr p);
  [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr window);
  [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr window);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);
  [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, uint id);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  [DllImport("shcore.dll")] public static extern int GetProcessDpiAwareness(IntPtr h, out int awareness);
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  public class Row { public long Handle; public string Title; public string Class; public bool Visible; public bool Foreground; public int ZOrder; public Rect Bounds; public int DpiAwareness; public uint Dpi; public bool TopMost; }
  public static List<Row> Find(uint process) {
    var rows = new List<Row>(); int order = 0;
    EnumWindows((h, p) => { uint id; GetWindowThreadProcessId(h, out id); int z = order++;
      if (id == process) { var title = new StringBuilder(512); var name = new StringBuilder(256); Rect bounds;
        GetWindowText(h, title, title.Capacity); GetClassName(h, name, name.Capacity); GetWindowRect(h, out bounds);
        rows.Add(new Row { Handle=h.ToInt64(), Title=title.ToString(), Class=name.ToString(), Visible=IsWindowVisible(h), Foreground=h==GetForegroundWindow(), ZOrder=z, Bounds=bounds, DpiAwareness=GetAwarenessFromDpiAwarenessContext(GetWindowDpiAwarenessContext(h)), Dpi=GetDpiForWindow(h), TopMost=(GetWindowLong(h,-20)&8)!=0 }); }
      return true; }, IntPtr.Zero);
    return rows;
  }
  public class Child { public long Handle; public int Id; public string Class; public string Title; }
  public static List<Child> Children(IntPtr parent) {
    var rows=new List<Child>();
    EnumChildWindows(parent,(h,p)=>{var name=new StringBuilder(256);var title=new StringBuilder(512);GetClassName(h,name,name.Capacity);GetWindowText(h,title,title.Capacity);
      if(name.ToString()=="Edit" || name.ToString()=="Button" || name.ToString().Contains("Combo")) rows.Add(new Child{Handle=h.ToInt64(),Id=GetDlgCtrlID(h),Class=name.ToString(),Title=title.ToString()}); return true;},IntPtr.Zero);
    return rows;
  }
}
'@
