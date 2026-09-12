# Restores the HaaS Apex classes/triggers captured from the Ascend pilot sandbox
# on 2026-09-11 12:11:29 UTC, exactly as they were before the de-amortisation change.
#
#   .\RESTORE.ps1              # dry run - compiles, deploys nothing
#   .\RESTORE.ps1 -Execute     # deploys the backed-up versions to the org
#
# Verified byte-identical to the live org at capture time.

param(
    [switch]$Execute,
    [string]$Org = 'Ascend'
)

$ErrorActionPreference = 'Stop'
$backupDir = $PSScriptRoot
$stage     = Join-Path $env:TEMP "haas-restore-$(Get-Date -Format yyyyMMddHHmmss)"
$classDir  = Join-Path $stage 'force-app\main\default\classes'
$trigDir   = Join-Path $stage 'force-app\main\default\triggers'

New-Item -ItemType Directory -Force -Path $classDir, $trigDir | Out-Null

# sf requires the deploy to run from inside a DX project
@'
{
  "packageDirectories": [ { "path": "force-app", "default": true } ],
  "sourceApiVersion": "67.0"
}
'@ | Set-Content -Path (Join-Path $stage 'sfdx-project.json') -Encoding ascii

$classMeta = @'
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>67.0</apiVersion>
    <status>Active</status>
</ApexClass>
'@

$trigMeta = @'
<?xml version="1.0" encoding="UTF-8"?>
<ApexTrigger xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>67.0</apiVersion>
    <status>Active</status>
</ApexTrigger>
'@

# UTF-8 without BOM - a BOM makes Apex fail to compile ("Invalid identifier")
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Stage-File($src, $destDir, $meta) {
    $name = Split-Path $src -Leaf
    $body = [System.IO.File]::ReadAllText($src).TrimStart([char]0xFEFF)
    [System.IO.File]::WriteAllText((Join-Path $destDir $name), $body, $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $destDir "$name-meta.xml"), $meta, $utf8NoBom)
    Write-Host "  staged $name"
}

Write-Host "Restoring from: $backupDir"
Get-ChildItem $backupDir -Filter *.cls     | ForEach-Object { Stage-File $_.FullName $classDir $classMeta }
Get-ChildItem $backupDir -Filter *.trigger | ForEach-Object { Stage-File $_.FullName $trigDir  $trigMeta }

Push-Location $stage
try {
    if ($Execute) {
        Write-Host "`nDEPLOYING to org '$Org'..." -ForegroundColor Yellow
        sf project deploy start -o $Org --source-dir force-app `
            --test-level RunSpecifiedTests `
            --tests QuoteMarginRollupPostHookTest --tests HaasPricingTriggerHandlerTest --tests JTLPreHookTest `
            --wait 30
    } else {
        Write-Host "`nDRY RUN against org '$Org' (nothing will be deployed)..." -ForegroundColor Cyan
        sf project deploy start -o $Org --source-dir force-app --dry-run --test-level NoTestRun --wait 30
        Write-Host "`nDry run complete. Re-run with -Execute to actually restore." -ForegroundColor Cyan
    }
} finally {
    Pop-Location
}
