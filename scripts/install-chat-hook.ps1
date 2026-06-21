$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $projectRoot

# Als MusicBrain de repo root zelf is (geen sub-project)
if (-not (Test-Path (Join-Path $repoRoot '.git'))) {
    $repoRoot = $projectRoot
}

$hookSrc = Join-Path $projectRoot 'scripts/pre-commit-chat-export'
$hookDst = Join-Path $repoRoot '.git/hooks/pre-commit'

if (-not (Test-Path $hookSrc)) {
    Write-Error "Fout: $hookSrc niet gevonden."
    exit 1
}

if (Test-Path $hookDst) {
    $existingHook = Get-Content -Raw -Path $hookDst
    if ($existingHook -match 'pre-commit-chat-export') {
        Write-Output "Hook is al geïnstalleerd in $hookDst"
        exit 0
    }

    Write-Output "Er bestaat al een pre-commit hook. Voeg deze regel toe aan ${hookDst}:"
    Write-Output '  scripts/pre-commit-chat-export'
    exit 0
}

$hookContent = Get-Content -Raw -Path $hookSrc
$hookContent = $hookContent -replace "`r`n", "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($hookDst, $hookContent, $utf8NoBom)

Write-Output "Pre-commit hook geïnstalleerd: $hookDst"
Write-Output 'De hook draait daarna bij elke git commit, ook vanuit GitHub Desktop.'
