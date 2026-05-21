# BENNING ST750A Automation

This package is a workstation automation template for BENNING ST750A / PC-Win ST 750-760.

## Database Model

- The PC master database is the leading database.
- The SD card is the device working database.
- Checkout: the PC master database is written to the SD card.
- Checkin: the SD working database is merged into the master database in PC-Win by using "Merge database".
- Do not use a permanent bidirectional live-sync model.

## Files

- `Config/config.json`: central configuration
- `Scripts/Common-BenningAutomation.ps1`: shared functions
- `Scripts/Prepare-BenningMerge.ps1`: import preparation for Power Automate Desktop
- `Scripts/Write-BenningDbToDevice.ps1`: protected write-back to the SD card
- `Scripts/Print-NewBenningPdfs.ps1`: PDF printing and archiving
- `Launchers/*.bat`: simple launcher files for desktop shortcuts

## Installation

1. Copy this folder to `C:\BenningAutomation`.
2. Check `Config\config.json`:
   - `MasterDbPath`
   - `BenningProgramPath`
   - `FileAccessTimeoutSeconds`
   - `DeviceDatabase.PreferExactCandidateMatch`
   - `DeviceDatabase.SearchRoots`
   - SD card database file names and extensions
   - PDF export folder and printer
3. Place the PC master database at `C:\BenningAutomation\DB\BENNING_Master.db` or adjust `MasterDbPath`.
4. Create desktop shortcuts to the files in `Launchers`.

## Flow 1: Import Results

Power Automate Desktop should run this first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\BenningAutomation\Scripts\Prepare-BenningMerge.ps1"
```

The last output line is the local path to the working database. The original SD card database file name is preserved, for example:

```text
C:\BenningAutomation\Incoming\Device-001.sdf
```

Then in PC-Win:

1. Start the program and wait for the main window.
2. Open the master database.
3. Select `File -> Database -> Merge database`.
4. Enter the path returned by PowerShell in the file dialog.
5. Start the merge.
6. Detect the completion dialog.
7. On success, show a simple message: `Results were imported successfully.`

Power Automate Desktop should use UI elements and window titles. Mouse coordinates should only be used as a documented emergency fallback.

## Flow 2: Write Test Data To Device

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\BenningAutomation\Scripts\Write-BenningDbToDevice.ps1"
```

The script writes to the SD card only if the current hash of the SD database matches the last imported hash for that database file name. If the hash differs, the write is aborted to protect test results that have not been imported yet.

Before hashing, copying, or overwriting database files, the scripts check whether the file is locked. The default timeout is 3 seconds and can be changed with `FileAccessTimeoutSeconds` in `Config\config.json`.

For fast SD card detection, list the real BENNING database file name first in `DeviceDatabase.CandidateFileNames`. With `DeviceDatabase.PreferExactCandidateMatch` enabled, the first exact match is used immediately and the script skips the slower fallback scan for additional `.sdf` or `.db` files. If the SD card uses a stable drive letter, set `DeviceDatabase.SearchRoots`, for example `[ "D:\\" ]`, to skip automatic drive discovery entirely.

## Flow 3: PDF Printing

BENNING exports PDFs to `PDF.ExportPath` from the configuration. The script watches that folder, prints new PDFs, and then moves them to `PDF.ArchivePath`.

One-time run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\BenningAutomation\Scripts\Print-NewBenningPdfs.ps1" -Once
```

Continuous watcher:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\BenningAutomation\Scripts\Print-NewBenningPdfs.ps1"
```

## Workstation Notes

- Set Windows display scaling to 100 percent.
- Start the BENNING window maximized.
- Assign a fixed SD card volume label such as `BENNING`.
- Verify the BENNING database extension before production use: `.sdf` or `.db`.
- Enable `AllowExtensionMismatchOnWrite` only when the database format is known to be compatible.
