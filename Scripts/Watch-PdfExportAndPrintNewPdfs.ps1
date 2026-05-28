param(
    [string]$ConfigPath,
    [switch]$Once
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Shared-BenningAutomationFunctions.ps1"

function Wait-ForStableFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$StableSeconds
    )

    $previousLength = -1
    $stableSince = Get-Date

    while ($true) {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.Length -eq $previousLength) {
            if (((Get-Date) - $stableSince).TotalSeconds -ge $StableSeconds) {
                return
            }
        } else {
            $previousLength = $item.Length
            $stableSince = Get-Date
        }

        Start-Sleep -Seconds 1
    }
}

function Print-BenningPdf {
    param(
        [Parameter(Mandatory = $true)]$PdfFile,
        $Config
    )

    Wait-ForStableFile -Path $PdfFile.FullName -StableSeconds $Config.Pdf.StableFileSeconds

    $queueFile = Join-Path $Config.Pdf.QueuePath $PdfFile.Name
    $archiveFile = Join-Path $Config.Pdf.ArchivePath ("{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), $PdfFile.Name)

    Copy-BenningFile -Config $Config -SourcePath $PdfFile.FullName -DestinationPath $queueFile -Purpose "PDF print queue copy"

    if ([string]::IsNullOrWhiteSpace($Config.Pdf.PrinterName)) {
        Start-Process -FilePath $queueFile -Verb Print -WindowStyle Hidden
    } else {
        Start-Process -FilePath $queueFile -Verb PrintTo -ArgumentList $Config.Pdf.PrinterName -WindowStyle Hidden
    }

    Move-Item -LiteralPath $PdfFile.FullName -Destination $archiveFile -Force
    Write-BenningLog -Config $Config -Message "PDF printed and archived: $archiveFile"
}

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    Initialize-BenningFolders -Config $config | Out-Null
    Write-BenningLog -Config $config -Message "Starting PDF print watcher"
    Set-BenningStatus -Config $config -Workflow "Pdf" -State "WaitingForPrintData" -Message "Waiting for new print data."
    Show-PatflowWorkflowToast -Config $config -Workflow "Pdf" -Title "PATflow PDF Druck" -Message "Warte auf neue Druckdaten"
    $waitingForPrintDataNotified = $true
    $lastPdfBatchSignature = ""
    $shownPdfErrorSignatures = @{}

    do {
        $pdfs = Get-ChildItem -LiteralPath $config.Pdf.ExportPath -Filter "*.pdf" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime

        $pdfCount = @($pdfs).Count
        if ($pdfCount -gt 0) {
            $pdfBatchSignature = (@($pdfs) | ForEach-Object { "{0}|{1}|{2}" -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join ";;"
            if ($pdfBatchSignature -ne $lastPdfBatchSignature) {
                Set-BenningStatus -Config $config -Workflow "Pdf" -State "PrintingStarted" -Message ("Print started for {0} file(s)." -f $pdfCount)
                Show-PatflowWorkflowToast -Config $config -Workflow "Pdf" -Title "PATflow PDF Druck" -Message ("Druck für {0} Dateien gestartet" -f $pdfCount)
                $lastPdfBatchSignature = $pdfBatchSignature
            }

            $waitingForPrintDataNotified = $false
        } elseif (!$waitingForPrintDataNotified) {
            Set-BenningStatus -Config $config -Workflow "Pdf" -State "WaitingForPrintData" -Message "Waiting for new print data."
            Show-PatflowWorkflowToast -Config $config -Workflow "Pdf" -Title "PATflow PDF Druck" -Message "Warte auf neue Druckdaten"
            $waitingForPrintDataNotified = $true
            $lastPdfBatchSignature = ""
        }

        foreach ($pdf in $pdfs) {
            try {
                Print-BenningPdf -PdfFile $pdf -Config $config
            } catch {
                Write-BenningLog -Config $config -Level "ERROR" -Message "PDF printing failed for $($pdf.FullName): $($_.Exception.Message)"
                Set-BenningStatus -Config $config -Workflow "Pdf" -State "Error" -Message "PDF printing failed." -ErrorMessage $_.Exception.Message
                $pdfErrorSignature = "{0}|{1}" -f $pdf.FullName, $_.Exception.Message
                if (!$shownPdfErrorSignatures.ContainsKey($pdfErrorSignature)) {
                    Show-PatflowWorkflowToast -Config $config -Workflow "Pdf" -Title "PATflow PDF Druck Fehler" -Message "Fehler beim PDF-Druck. Details stehen im Log." -Error
                    $shownPdfErrorSignatures[$pdfErrorSignature] = $true
                }
            }
        }

        if (!$Once) {
            Start-Sleep -Seconds $config.Pdf.PollSeconds
        }
    } while (!$Once)
} catch {
    if ($config) {
        Write-BenningLog -Config $config -Level "ERROR" -Message $_.Exception.Message
        Set-BenningStatus -Config $config -Workflow "Pdf" -State "Error" -Message "PDF watcher failed." -ErrorMessage $_.Exception.Message
        Show-PatflowWorkflowToast -Config $config -Workflow "Pdf" -Title "PATflow PDF Druck Fehler" -Message "Fehler im PDF-Watcher. Details stehen im Log." -Error
    }

    throw
}
