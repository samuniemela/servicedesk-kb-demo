<#
.SYNOPSIS
Luo anonymisoiduista tiketeistä tietopankkiluonnokset.
.EXAMPLE
./scripts/New-KBDrafts.ps1                    # testitila, ei API-avainta
./scripts/New-KBDrafts.ps1 -Provider Claude   # vaatii $env:ANTHROPIC_API_KEY
#>
[CmdletBinding()]
param(
    [ValidateSet('Mock', 'Claude')][string]$Provider = 'Mock',
    [string]$InputPath = "$PSScriptRoot/../output/tickets.anonymized.json",
    [string]$KbPath    = "$PSScriptRoot/../output/kb"
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/KnowledgeBase.psm1" -Force

if (-not (Test-Path $InputPath)) {
    & "$PSScriptRoot/Invoke-Anonymization.ps1" -OutputPath $InputPath
}

$ai = if ($Provider -eq 'Claude') { New-ClaudeAIProvider } else { New-MockAIProvider }
$tickets = Get-Content $InputPath -Raw -Encoding utf8 | ConvertFrom-Json

$ok = 0
foreach ($t in $tickets) {
    try {
        $null = $t | New-KBArticleDraft -Provider $ai | Save-KBArticle -Path $KbPath
        $ok++
    }
    catch {
        Write-Warning $_.Exception.Message
    }
}

Write-Host "Luotu $ok luonnosta ($($ai.Name)) -> $KbPath" -ForegroundColor Green
Write-Host 'Hyväksy:  Set-KBArticleStatus -Path ./output/kb -Id KB-1001 -Status Hyväksytty -Reviewer <nimi>'
