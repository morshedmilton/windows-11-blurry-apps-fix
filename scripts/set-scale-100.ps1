<#
.SYNOPSIS
    Set the display scaling of the primary display to a specific step, then
    restart explorer so the taskbar/desktop actually pick up the new DPI.

.DESCRIPTION
    ADVANCED / OPTIONAL.

    The recommended way to change scaling is the Settings app:
        Settings > System > Display > Scale
    Windows restarts the shell itself when you do it there.

    If you change scaling programmatically (which is what this script does,
    via the undocumented DisplayConfig DPI-scale API), Windows does NOT
    restart explorer.exe. explorer keeps rendering the taskbar at the old DPI
    and the taskbar stays blurry until the shell restarts. That is exactly the
    trap this script handles for you.

    Always run the verification the script prints at the end.

.PARAMETER Rel
    Scale step relative to the recommended value. 0 = recommended,
    -1 = one step below recommended (= 100 % on a 1920x1080 15.6" panel).
    Clamped to the range the display reports.

.PARAMETER Restore
    Go back to the recommended scaling.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\set-scale-100.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\set-scale-100.ps1 -Restore
#>
[CmdletBinding()]
param(
    [int]$Rel = -1,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

if ($Restore) { $Rel = 0 }

Write-Host ''
Write-Host 'Display scaling - advanced setter' -ForegroundColor Cyan
Write-Host ('=' * 46)
Write-Host 'NOTE: Settings > System > Display > Scale is the safer route.' -ForegroundColor DarkGray
Write-Host ''

Add-Type -Language CSharp @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DpiScale
{
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Lo; public int Hi; }
    [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint N; public uint D; }
    [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID a; public uint id; public uint m; public uint s; }
    [StructLayout(LayoutKind.Sequential)] public struct TGT {
        public LUID a; public uint id; public uint m; public uint ot; public uint rot; public uint sc;
        public RATIONAL r; public uint slo; public int avail; public uint st; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC src; public TGT tgt; public uint f; }
    [StructLayout(LayoutKind.Sequential)] public struct MODE {
        public uint it; public uint id; public LUID a; public uint i2; public uint p; public uint q; public RATIONAL r; public uint s; }

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint f, ref uint np, [Out] PATH[] p, ref uint nm, [Out] MODE[] m, IntPtr t);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(IntPtr p);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(IntPtr p);

    static IntPtr Packet(int type, int size, LUID luid, uint id, int? body)
    {
        IntPtr buf = Marshal.AllocHGlobal(64);
        for (int i = 0; i < 64; i++) Marshal.WriteByte(buf, i, 0);
        Marshal.WriteInt32(buf, 0, type);
        Marshal.WriteInt32(buf, 4, size);
        Marshal.WriteInt32(buf, 8, unchecked((int)luid.Lo));
        Marshal.WriteInt32(buf, 12, luid.Hi);
        Marshal.WriteInt32(buf, 16, unchecked((int)id));
        if (body.HasValue) Marshal.WriteInt32(buf, 20, body.Value);
        return buf;
    }

    public static string Apply(int wanted)
    {
        uint np = 0, nm = 0;
        int r = GetDisplayConfigBufferSizes(2, out np, out nm);
        if (r != 0) return "GetDisplayConfigBufferSizes failed (" + r + ")";

        var paths = new PATH[np];
        var modes = new MODE[nm];
        r = QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero);
        if (r != 0) return "QueryDisplayConfig failed (" + r + ")";

        var sb = new StringBuilder();
        bool done = false;

        for (int i = 0; i < np; i++)
        {
            var si = paths[i].src;

            IntPtr g = Packet(-3, 32, si.a, si.id, null);
            int gr = DisplayConfigGetDeviceInfo(g);
            if (gr != 0) { Marshal.FreeHGlobal(g); continue; }

            int min = Marshal.ReadInt32(g, 20);
            int cur = Marshal.ReadInt32(g, 24);
            int max = Marshal.ReadInt32(g, 28);
            Marshal.FreeHGlobal(g);

            sb.AppendLine("  display source " + si.id + ": min=" + min + "  current=" + cur + "  max=" + max);

            int target = wanted;
            if (target < min) target = min;
            if (target > max) target = max;

            IntPtr s = Packet(-4, 24, si.a, si.id, target);
            int sr = DisplayConfigSetDeviceInfo(s);
            Marshal.FreeHGlobal(s);

            sb.AppendLine("  requested step " + target + " -> result " + (sr == 0 ? "OK" : "error " + sr));
            if (sr == 0) done = true;
        }

        sb.AppendLine(done ? "  change accepted" : "  nothing was changed");
        return sb.ToString();
    }
}
"@

$report = [DpiScale]::Apply($Rel)
Write-Host $report

if ($report -notmatch 'change accepted') {
    Write-Host 'Could not apply. Use Settings > System > Display > Scale instead.' -ForegroundColor Yellow
    exit 1
}

# ------------------------------------------------ restart the shell properly
Write-Host 'Restarting explorer so the taskbar redraws at the new DPI...' -ForegroundColor Yellow
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

Write-Host 'Clearing icon cache (bitmaps rasterised at the old DPI)...' -ForegroundColor Yellow
$exp = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
Get-ChildItem $exp -Filter 'iconcache*.db' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 1
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
    Start-Process 'C:\Windows\explorer.exe'
}
Start-Sleep -Seconds 4

# ------------------------------------------------------------- verify state
$tmp = Join-Path $env:TEMP ('_dpi_' + [guid]::NewGuid().ToString('N') + '.txt')
$code = 'Add-Type -AssemblyName System.Windows.Forms;' +
        '$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;' +
        'Set-Content -Path "' + $tmp + '" -Value ($b.Width.ToString()+"x"+$b.Height.ToString()) -Encoding ascii'
Start-Process 'powershell.exe' -ArgumentList '-NoProfile','-Command',$code -Wait -WindowStyle Hidden
$logical = Get-Content $tmp -ErrorAction SilentlyContinue
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('  logical desktop now: ' + $logical + '   (1920x1080 = 100 %, 1536x864 = 125 %)') -ForegroundColor Green
Get-ChildItem 'HKCU:\Control Panel\Desktop\PerMonitorSettings' | ForEach-Object {
    $d = Get-ItemProperty $_.PSPath
    Write-Host ('  ' + $_.PSChildName.Substring(0, [Math]::Min(38, $_.PSChildName.Length)) + '... DpiValue=' + $d.DpiValue) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host 'Open Task Manager and Device Manager to confirm they look crisp.' -ForegroundColor Cyan
