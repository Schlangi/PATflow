# PATflow BENNING ST750A Automation

PATflow automates the temporary SD-card workflow for a BENNING ST750A / PC-Win ST 750-760 workstation.

## Current PATflow Flow

This is the currently implemented workflow. It does **not** automate the PC-Win "merge database" dialog yet.

1. `Watch-SdCardAndRunDirectDatabaseWorkflow.ps1` runs continuously, normally every 10 seconds.
2. If no SD card or device database is present, this is treated as normal idle state.
3. When a device database appears or changes, `Copy-DeviceDatabaseFromSdToIncoming.ps1` copies it from the SD card into `Incoming`.
4. The copied file keeps its original file name, for example:

```text
D:\Device-001.sdf
C:\PATflow\Incoming\Device-001.sdf
```

5. `Move-IncomingDatabaseToDbStartPcWinAndWriteBackToSd.ps1` moves the file from `Incoming` to `DB`.
6. BENNING PC-Win is started only after the database file is in `DB`.
7. The user works on the database in PC-Win.
8. PATflow waits until PC-Win has locked and then released the database file.
9. The original SD-card database is moved to `Archive`.
10. The changed database from `DB` is copied back to the SD card.
11. The changed `DB` working file is moved to `Archive`.

This gives a direct interim workflow while Power Automate Desktop GUI import is not implemented.

## What Is Not Implemented Yet

- No automated PC-Win `File -> Database -> Merge database` flow.
- No direct reverse-engineering merge of BENNING databases.
- No hidden bidirectional live sync.
- No blind overwrite of changed SD-card data.

## Database Model

- The PC master database remains the leading database conceptually.
- The SD card is the device working database.
- Current interim mode works directly on a copied SD database in `DB`.
- Later PAD mode can still use BENNING's official merge workflow.

## Important Folders

- `Config`: central configuration
- `Incoming`: fresh copies from SD, original file names preserved
- `DB`: active working database for PC-Win
- `Archive`: archived SD originals and changed PC-Win working databases
- `Backups`: master database backups for future merge workflow
- `Logs`: technical log file
- `State`: hashes and metadata used to skip unchanged databases safely

## Main Scripts

- `Shared-BenningAutomationFunctions.ps1`: shared helper functions only. Do not start directly.
- `Watch-SdCardAndRunDirectDatabaseWorkflow.ps1`: long-running SD-card watcher. Starts the current direct workflow.
- `Copy-DeviceDatabaseFromSdToIncoming.ps1`: copies a changed SD database to `Incoming`. Does not start PC-Win.
- `Move-IncomingDatabaseToDbStartPcWinAndWriteBackToSd.ps1`: moves `Incoming` to `DB`, starts PC-Win, waits for release, writes back to SD, archives files.
- `Write-MasterDatabaseToSdIfUnchanged.ps1`: protected checkout from master database to SD. Only writes if the SD database still matches the last imported hash.
- `Watch-PdfExportAndPrintNewPdfs.ps1`: watches exported PDFs and prints/archives them.
- `PATflow-RegistrationOnLogon.ps1`: registers SD workflow and PDF print watchers as Windows logon tasks for a specific user.

## Launchers

- `PATflow_Start_SD_Watcher.bat`: start the normal watcher.
- `PATflow_Copy_SD_Database_To_Incoming.bat`: copy SD database to `Incoming` once.
- `PATflow_Run_Direct_Database_Workflow.bat`: process an already copied file from `Incoming`.
- `PATflow_Write_Master_Database_To_SD.bat`: protected write from master database to SD.
- `PATflow_Start_PDF_Print_Watcher.bat`: start PDF print watcher.

## Configuration

Check `Config\config.json` before running:

- `BasePath`
- `MasterDbPath`
- `BenningProgramPath`
- `BenningProgramArguments`
- `BenningProcessName`
- `FileAccessTimeoutSeconds`
- `ImportWatcher.PollSeconds`
- `ImportWatcher.ProcessIncomingDirectly`
- `DeviceDatabase.CandidateFileNames`
- `DeviceDatabase.SearchRoots`
- `Pdf.ExportPath`
- `Pdf.ArchivePath`
- `Pdf.QueuePath`
- `Pdf.PrinterName`

If PC-Win supports opening a database path from the command line, set `BenningProgramArguments` and use `{DatabasePath}` as placeholder. If it is empty, PC-Win is started without arguments and the user or PC-Win configuration must open the DB file from the `DB` folder.

## Start Watcher

```powershell
C:\PATflow\Launchers\PATflow_Start_SD_Watcher.bat
```

Or directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\PATflow\Scripts\Watch-SdCardAndRunDirectDatabaseWorkflow.ps1"
```

One cycle only:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\PATflow\Scripts\Watch-SdCardAndRunDirectDatabaseWorkflow.ps1" -Once
```

## Register Watcher At User Logon

Run PowerShell as administrator:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\PATflow\Scripts\PATflow-RegistrationOnLogon.ps1" -UserId ".\Testa"
```

The helper registers two scheduled tasks:

- `PATflow SD Card Workflow Watcher`
- `PATflow PDF Print Watcher`

The helper normalizes local `.\UserName` values to `COMPUTERNAME\UserName` and verifies that Windows can resolve the account.

## PDF Printing

BENNING PC-Win should export reports as PDF into the folder configured by `Pdf.ExportPath`, for example:

```text
C:\PATflow\PDF_Export
```

`Watch-PdfExportAndPrintNewPdfs.ps1` watches that folder. For every new PDF it:

1. waits until the PDF file size is stable,
2. copies the PDF into `Pdf.QueuePath`,
3. prints it,
4. moves the original exported PDF into `Pdf.ArchivePath`.

Start the watcher with:

```powershell
C:\PATflow\Launchers\PATflow_Start_PDF_Print_Watcher.bat
```

Or directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\PATflow\Scripts\Watch-PdfExportAndPrintNewPdfs.ps1"
```

For a safe one-time test run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\PATflow\Scripts\Watch-PdfExportAndPrintNewPdfs.ps1" -Once
```

Printer selection:

- If `Pdf.PrinterName` is empty, Windows uses the default PDF print handler/default printer.
- If `Pdf.PrinterName` is set, the script uses `PrintTo` with that printer name.

The PDFs remain archived after printing. PATflow does not delete archived PDFs automatically.

## Safety Notes

- Missing SD card is normal idle state.
- Database file access is checked with a short timeout.
- Unchanged SD databases are skipped by file metadata first.
- Full hashing is only done when metadata indicates a change.
- Original SD databases are archived before write-back.
- If write-back fails after archiving the original SD file, PATflow restores the original file to the SD card.
- PDF printing keeps exported PDFs in `Pdf.ArchivePath` after printing.
