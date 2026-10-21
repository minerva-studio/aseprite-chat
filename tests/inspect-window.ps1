param([Parameter(Mandatory)][int]$ProcessId, [string]$ImagePath)
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class ChatTestWindow {
 public delegate bool E(IntPtr h,IntPtr l);
 public struct Rect {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] public static extern bool EnumWindows(E f,IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h,E f,IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 public static string Text(IntPtr h) {var b=new StringBuilder(4096);GetWindowText(h,b,4096);return b.ToString();}
 public static IntPtr Find(uint pid) {IntPtr found=IntPtr.Zero;long area=0;EnumWindows((h,l)=>{uint p;GetWindowThreadProcessId(h,out p);if(p==pid){Rect r;GetWindowRect(h,out r);Console.WriteLine(h+" visible="+IsWindowVisible(h)+" title="+Text(h));EnumChildWindows(h,(c,x)=>{Console.WriteLine("  "+Text(c));return true;},IntPtr.Zero);long a=(long)(r.Right-r.Left)*(r.Bottom-r.Top);if(a>area && IsWindowVisible(h)){found=h;area=a;}}return true;},IntPtr.Zero);return found;}
}
'@
$windowHandle = [ChatTestWindow]::Find([uint32]$ProcessId)
if ($ImagePath -and $windowHandle -ne [IntPtr]::Zero) {
  $windowRect = New-Object ChatTestWindow+Rect
  [ChatTestWindow]::GetWindowRect($windowHandle, [ref]$windowRect) | Out-Null
  $bitmap = New-Object System.Drawing.Bitmap(($windowRect.Right - $windowRect.Left), ($windowRect.Bottom - $windowRect.Top))
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $deviceContext = $graphics.GetHdc()
  try { [ChatTestWindow]::PrintWindow($windowHandle, $deviceContext, 2) | Out-Null }
  finally { $graphics.ReleaseHdc($deviceContext) }
  $bitmap.Save($ImagePath, [System.Drawing.Imaging.ImageFormat]::Png)
  $graphics.Dispose(); $bitmap.Dispose()
}
