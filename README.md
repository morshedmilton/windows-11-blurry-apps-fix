# Windows 11 — every app looks blurry / pixelated

> **Verified diagnosis and fix.** Tested on a Dell G15 5530, 15.6″ 1920 × 1080, Windows 11 Pro build 26300.
> Symptom: text and icons look soft or "washed" in almost every app. Fixing one app by hand in its Compatibility tab works — but doing that for every app is endless, and some apps (Device Manager, installers, system dialogs) can never be reached that way.

<p>
<img alt="Windows 11" src="https://img.shields.io/badge/Windows-11-0078D4?logo=windows11&logoColor=white">
<img alt="DPI" src="https://img.shields.io/badge/DPI-virtualization-d73a49">
<img alt="PowerShell" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white">
</p>

---

## TL;DR (English)

Your display scaling is above 100 %. Apps that declare themselves **DPI-unaware** in their manifest (`<dpiAware>false</dpiAware>`) are rendered at a smaller resolution and then **bitmap-stretched** to fill the panel. That stretch is the blur. It is not a driver bug and not a broken Windows — it is the documented behaviour of DPI virtualization.

**Fix: set display scaling to 100 %.**

```
Settings → System → Display → Scale → 100 %
```

Then restart (or let Windows restart the shell). Nothing else is needed — no per-app settings, no registry hacks, no scripts. The trade-off is that the UI becomes ~20 % smaller.

---

## বাংলায় সারমর্ম

আপনার display scaling ১০০%-এর বেশি। যে অ্যাপগুলো নিজেদের ম্যানিফেস্টে **DPI-অজ্ঞ** (`<dpiAware>false</dpiAware>`) বলে ঘোষণা করে, Windows তাদের ছোট রেজল্যুশনে এঁকে **বিটম্যাপ টেনে** প্যানেল ভরায়। ওই টানাটানিটাই ঝাপসা। এটা ড্রাইভারের বাগ না, Windows-এর ভাঙাও না — এটাই DPI virtualization-এর স্বাভাবিক আচরণ।

**সমাধান: display scaling ১০০%-এ নামান।**

```
Settings → System → Display → Scale → 100 %
```

তারপর রিস্টার্ট। আর কিছু লাগবে না — per-app সেটিং না, রেজিস্ট্রি হ্যাক না, স্ক্রিপ্ট না। খরচ শুধু একটাই: UI ~২০% ছোট দেখাবে।

---

## Symptom

- Text in **Device Manager**, Event Viewer, Services, older installers looks soft.
- Task Manager, Telegram, browsers look fine — which makes it look random.
- Per-app fix works: *Right-click → Properties → Compatibility → Change high DPI settings → tick "Override high DPI scaling behavior", Scaling performed by: **Application*** → that one app becomes crisp.
- But you have to do it for every single app, and some system components cannot be fixed that way at all.

## Why the per-app trick "works but never finishes"

`mmc.exe` — the host of Device Manager, Event Viewer, Services, Disk Management — declares:

```xml
<dpiAware>false</dpiAware>
```

Meanwhile `explorer.exe` declares `PerMonitorV2` and `taskmgr.exe` declares `true`. So on the same 125 % desktop, Task Manager renders 1:1 and is crisp, while MMC is rendered at 1440 × 810 and stretched to 1920 × 1080. Hundreds of Windows components and legacy apps are in that second group. There is no global switch that flips them all — **except removing the scaling itself**.

---

## Diagnosis

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\diagnose.ps1
# and, to inspect one specific app:
powershell -ExecutionPolicy Bypass -File .\scripts\diagnose.ps1 -Exe "C:\Windows\System32\mmc.exe"
```

Expected output on an affected machine:

```
=== 2. EFFECTIVE SCALING ===
  system DPI          120  (96 = 100 %, 120 = 125 %)
  scaling             125 %
  logical desktop     1536 x 864
  -> Scaling is above 100 %. Every DPI-unaware app is being rendered at
     1536x864 and stretched to 1920x1080.

=== 4. LEGACY DPI / FONT VALUES ===
  HKCU Desktop\LogPixels        480     expected 120      <-- corrupt
  FontSmoothingGamma            0       expected 1200     <-- corrupt

=== 6. MANIFEST OF C:\Windows\System32\mmc.exe ===
  dpiAware            false
  -> This app declares itself DPI-UNWARE. It WILL be blurry above 100 %.
```

---

## The fix

### Primary — change the scaling (guaranteed)

```
Settings → System → Display → Scale → 100 %
```

Verify:

```powershell
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
```

`1920 × 1080` = 100 % (fixed). `1536 × 864` = 125 % (still blurry).

After this, Device Manager, the taskbar, installers and every future app render 1:1. No maintenance ever again.

### ⚠ The trap nobody mentions — the taskbar stays blurry

If you change scaling **programmatically** instead of through Settings, Windows does **not** restart `explorer.exe`. explorer keeps its old DPI and the taskbar remains blurry even though Task Manager is already crisp. Verified on this machine: after the change, `explorer.exe` was still the process that started *before* the scaling change.

Fix:

```powershell
Stop-Process -Name explorer -Force
Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache*.db" -Force -ErrorAction SilentlyContinue
Start-Process explorer.exe
```

Clearing `iconcache*.db` matters too — taskbar icons rasterised at the old DPI stay soft otherwise.

The script `scripts/set-scale-100.ps1` does the scaling change **and** this shell restart **and** the icon-cache clear in one go, then prints the resulting logical desktop size.

> If you use the Settings app, Windows restarts the shell for you — this trap does not apply.

### Repair the corrupted legacy values (recommended regardless)

Both were found out of range on this machine and both make text look soft even in apps that *are* DPI-aware:

```powershell
# should equal the current DPI: 96 at 100 %, 120 at 125 %
New-ItemProperty 'HKCU:\Control Panel\Desktop' -Name LogPixels -Value 96 -PropertyType DWord -Force

# default is 1200; 0 disables ClearType gamma correction and text looks washed out
New-ItemProperty 'HKCU:\Control Panel\Desktop' -Name FontSmoothingGamma -Value 1200 -PropertyType DWord -Force
```

---

## If you must keep 125 %

You can reproduce the per-app Compatibility-tab setting in bulk. Windows stores it here:

```
HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers
HKEY  = full path of the .exe
VALUE = the layer string
```

Verified flag mapping (the same values the GUI writes):

| Compatibility dialog | Registry flag |
|---|---|
| *Program DPI* → "I signed in to Windows" | `PERPROCESSSYSTEMDPIFORCEOFF` |
| *Program DPI* → "I open this program" | `PERPROCESSSYSTEMDPIFORCEON` |
| *Override* → Application | `HIGHDPIAWARE` |
| *Override* → System | `DPIUNAWARE` |
| *Override* → System (Enhanced) | `GDIDPISCALING DPIUNAWARE` |

The combination that produces the "Application" result is **both** flags:

```powershell
$key  = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$exe  = 'C:\Program Files\7-Zip\7zFM.exe'
New-ItemProperty -Path $key -Name $exe -Value '~ PERPROCESSSYSTEMDPIFORCEOFF HIGHDPIAWARE' -PropertyType String -Force
```

Restart the app (fully — including its tray icon) and it renders 1:1.

**Be honest about the limits of this approach:**

- It makes the app **smaller**, not bigger. It disables the stretch; it does not scale anything up.
- It is per executable. New app → new entry.
- It cannot reach everything (protected system binaries, apps launched through shims, unpacked portable tools outside the folders you scanned).
- `HIGHDPIAWARE` alone is **not** enough for many legacy apps — without the Program-DPI flag the virtualisation stays. If you set only half the pair, nothing changes.

That is why this repo recommends the scaling change instead.

---

## What did **not** fix it

- ❌ Reinstalling GPU drivers (Intel or NVIDIA) — blur is not a driver fault
- ❌ Changing resolution — 1920 × 1080 *is* the native mode
- ❌ Enabling/disabling "Fix scaling for apps"
- ❌ Turning HDR on/off
- ❌ `Set-ProcessDpiAwareness` style tweaks on a handful of apps — same dead end as the Compatibility tab

## Fresh Windows install — checklist

1. Install Windows and your OEM drivers.
2. `Settings → System → Display → Scale` → **100 %**.
3. Restart.
4. Check `LogPixels` and `FontSmoothingGamma` (section above) — OEM images sometimes ship them wrong.
5. Done. Nothing else is required, and every app you install later is crisp automatically.

---

## Files

| File | Purpose |
|---|---|
| `scripts/diagnose.ps1` | read-only: scaling, per-monitor DPI, legacy values, and any exe's manifest |
| `scripts/set-scale-100.ps1` | advanced: change scaling via DisplayConfig API **+** explorer restart **+** icon cache clear |

## License

MIT — see [LICENSE](LICENSE).
