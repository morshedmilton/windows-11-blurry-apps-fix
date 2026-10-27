<#
.SYNOPSIS
    Diagnose "all apps look blurry" on Windows 10/11.

.DESCRIPTION
    Prints the data that separates the two possible causes:

      A) DPI virtualization   - display scaling > 100 % and the app is DPI-unaware
      B) corrupted values     - LogPixels / FontSmoothingGamma out of range

    Read-only. Changes nothing.

.PARAMETER Exe
    Optional path to an executable. Its manifest is inspected so you can see
    whether the app declares DPI awareness itself.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\diagnose.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\diagnose.ps1 -Exe "C:\Windows\System32\mmc.exe"
#>
[CmdletBinding()]
param(
    [string]$Exe
)

$ErrorActionPreference = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms

Add-Type -Language CSharp @"
using System;
using System.Runtime.InteropServices;
public static class DpiProbe {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr h, int t, out uint dx, out uint dy);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint f);
}
"@

function Write-Section { param([string]$T) Write-Host ''; Write-Host ('=== ' + $T + ' ' + ('=' * [Math]::Max(0, 58 - $T.Length))) -ForegroundColor Cyan }
function Write-Item    { param([string]$N, $V) Write-Host ('  {0,-32} {1}' -f $N, $V) }

# --------------------------------------------------------------- display
Write-Section '1. DISPLAY'
$vc = Get-CimInstance Win32_VideoController | Where-Object { $_.Status -eq 'OK' -and $_.CurrentHorizontalResolution } | Select-Object -First 1
$physW = $vc.CurrentHorizontalResolution
$physH = $vc.CurrentVerticalResolution
Write-Item 'GPU'        $vc.Name
Write-Item 'resolution' ($physW.ToString() + ' x ' + $physH.ToString() + ' @ ' + $vc.CurrentRefreshRate + ' Hz')

# ------------------------------------------------------- effective scaling
Write-Section '2. EFFECTIVE SCALING  (this is the number that matters)'
[DpiProbe]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$sysDpi = [DpiProbe]::GetDpiForSystem()

$pt = New-Object DpiProbe+POINT; $pt.x = 10; $pt.y = 10
$hmon = [DpiProbe]::MonitorFromPoint($pt, 2)
$dx = 0; $dy = 0
[DpiProbe]::GetDpiForMonitor($hmon, 0, [ref]$dx, [ref]$dy) | Out-Null

$scale = [Math]::Round($sysDpi / 96 * 100)
Write-Item 'system DPI'      ($sysDpi.ToString() + '  (96 = 100 %, 120 = 125 %, 144 = 150 %)')
Write-Item 'monitor DPI'     $dx
Write-Item 'scaling'         ($scale.ToString() + ' %')
Write-Item 'logical desktop' ([Math]::Round($physW * 96 / $sysDpi).ToString() + ' x ' + [Math]::Round($physH * 96 / $sysDpi).ToString())

if ($scale -gt 100) {
    Write-Host ''
    Write-Host ('  -> Scaling is above 100 %. Every DPI-unaware app is being rendered at ' +
                [Math]::Round($physW * 96 / $sysDpi) + 'x' + [Math]::Round($physH * 96 / $sysDpi) +
                ' and stretched to ' + $physW + 'x' + $physH + '.') -ForegroundColor Yellow
    Write-Host '  -> That stretch is the blur. See README, "The fix".' -ForegroundColor Yellow
}

# ------------------------------------------------------- per-monitor values
Write-Section '3. PER-MONITOR SETTINGS  (-1 = one step below recommended = 100 %)'
$pm = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
if (Test-Path $pm) {
    Get-ChildItem $pm | ForEach-Object {
        $d = Get-ItemProperty $_.PSPath
        $name = $_.PSChildName
        if ($name.Length -gt 40) { $name = $name.Substring(0, 40) + '...' }
        Write-Item $name ('DpiValue = ' + $d.DpiValue)
    }
} else { Write-Host '  (key absent)' }

# ----------------------------------------------------------- legacy values
Write-Section '4. LEGACY DPI / FONT VALUES  (compare against the expected column)'
$desk = Get-ItemProperty 'HKCU:\Control Panel\Desktop'
$win  = Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics'
$hp   = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Hardware Profiles\Current\Software\Fonts'
$fdpi = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontDPI'

$rows = @(
    @{ n = 'HKCU Desktop\LogPixels';        v = $desk.LogPixels;        exp = '96 at 100 %, 120 at 125 %' },
    @{ n = 'HKCU WindowMetrics\AppliedDPI'; v = $win.AppliedDPI;        exp = 'same as LogPixels' },
    @{ n = 'HKLM HardwareProfiles\LogPixels'; v = $hp.LogPixels;        exp = 'same as LogPixels' },
    @{ n = 'HKLM FontDPI\LogPixels';        v = $fdpi.LogPixels;        exp = 'same as LogPixels' },
    @{ n = 'FontSmoothingGamma';            v = $desk.FontSmoothingGamma; exp = '1200' },
    @{ n = 'FontSmoothing';                 v = $desk.FontSmoothing;     exp = '2 (on)' },
    @{ n = 'FontSmoothingType';             v = $desk.FontSmoothingType; exp = '2 (ClearType)' }
)
foreach ($r in $rows) {
    $bad = $false
    # Only the HKCU values are actually consulted on a per-monitor DPI system.
    # The two HKLM entries are profile defaults and are informational only.
    if ($r.n -like 'HKCU*' -and $r.n -match 'LogPixels|AppliedDPI') {
        if ($r.v -ne $sysDpi) { $bad = $true }
    }
    if ($r.n -eq 'FontSmoothingGamma' -and $r.v -ne 1200 -and $r.v -ne 1000) { $bad = $true }
    $line = ('  {0,-38} {1,-8} expected {2}' -f $r.n, $r.v, $r.exp)
    if ($bad) {
        Write-Host $line -ForegroundColor Red
    } elseif ($r.n -like 'HKLM*') {
        Write-Host $line -ForegroundColor DarkGray
    } else {
        Write-Host $line -ForegroundColor Gray
    }
}
Write-Host ''
Write-Host '  Red = out of range and actually used. Grey HKCU rows = fine.' -ForegroundColor DarkGray
Write-Host '  The two HKLM rows are defaults for new profiles; Windows ignores them' -ForegroundColor DarkGray
Write-Host '  once per-monitor DPI is active, so they are shown for reference only.' -ForegroundColor DarkGray

# --------------------------------------------------------- per-app overrides
Write-Section '5. PER-APP HIGH-DPI OVERRIDES ALREADY SET'
foreach ($k in @('HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers',
                 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers')) {
    $props = (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }
    Write-Item $k ($props.Count.ToString() + ' entries')
}

# ------------------------------------------------------------ app manifest
if ($Exe) {
    Write-Section ('6. MANIFEST OF ' + $Exe)
    if (Test-Path $Exe) {
        $bytes = [IO.File]::ReadAllBytes($Exe)
        $text  = [Text.Encoding]::ASCII.GetString($bytes)
        $aware = [regex]::Match($text, '<dpiAware[^>]*>([^<]*)</dpiAware>')
        $awrn  = [regex]::Match($text, '<dpiAwareness[^>]*>([^<]*)</dpiAwareness>')
        Write-Item 'dpiAware'     $(if ($aware.Success) { $aware.Groups[1].Value } else { '(not declared)' })
        Write-Item 'dpiAwareness' $(if ($awrn.Success) { $awrn.Groups[1].Value } else { '(not declared)' })
        if ($aware.Success -and $aware.Groups[1].Value -eq 'false') {
            Write-Host '  -> This app declares itself DPI-UNWARE. Windows stretches it. It WILL be blurry above 100 %.' -ForegroundColor Yellow
        } elseif ($awrn.Success -and $awrn.Groups[1].Value -match 'PerMonitor') {
            Write-Host '  -> Per-monitor aware. Renders crisply at any scaling.' -ForegroundColor Green
        }
    } else {
        Write-Host '  file not found'
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
