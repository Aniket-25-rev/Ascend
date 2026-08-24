# Daily git backup for the Ascend repo.
# Registered as the Windows scheduled task "Ascend Daily Git Backup" (23:50 daily).
# Commits everything not covered by .gitignore, and pushes if a remote is configured.

$ErrorActionPreference = 'Stop'

$repo = 'C:\Users\Aniket Shinde\OneDrive\Desktop\Ascend'
$log  = Join-Path $repo 'scripts\backup\backup.log'

function Write-Log([string]$message) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $message" | Add-Content -Path $log -Encoding utf8
}

try {
    Set-Location $repo

    if (-not (git status --porcelain)) {
        Write-Log 'No changes - nothing to back up.'
        exit 0
    }

    git add -A
    $files = (git diff --cached --name-only | Measure-Object -Line).Lines
    if ($files -eq 0) {
        Write-Log 'Only ignored changes - nothing to back up.'
        exit 0
    }

    git commit -m "Automated daily backup $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git commit failed with exit code $LASTEXITCODE" }
    Write-Log "Committed $files file(s)."

    if (git remote) {
        git push origin HEAD 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'Pushed to remote.'
        } else {
            Write-Log 'WARNING: push failed - the commit exists locally only.'
        }
    } else {
        Write-Log 'No git remote configured - the commit exists locally only.'
    }
}
catch {
    Write-Log "ERROR: $_"
    exit 1
}
