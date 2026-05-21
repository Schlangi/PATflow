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

    Copy-Item -LiteralPath $PdfFile.FullName -Destination $queueFile -Force

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

    do {
        $pdfs = Get-ChildItem -LiteralPath $config.Pdf.ExportPath -Filter "*.pdf" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime

        foreach ($pdf in $pdfs) {
            try {
                Print-BenningPdf -PdfFile $pdf -Config $config
            } catch {
                Write-BenningLog -Config $config -Level "ERROR" -Message "PDF printing failed for $($pdf.FullName): $($_.Exception.Message)"
            }
        }

        if (!$Once) {
            Start-Sleep -Seconds $config.Pdf.PollSeconds
        }
    } while (!$Once)
} catch {
    if ($config) {
        Write-BenningLog -Config $config -Level "ERROR" -Message $_.Exception.Message
    }

    throw
}
