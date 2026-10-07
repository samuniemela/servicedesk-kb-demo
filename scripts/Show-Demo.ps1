<#
.SYNOPSIS
Koko putki yhdellä komennolla: anonymisointi, artikkeliluonnokset, hyväksyntä ja ratkaisuehdotukset.
Demo hyväksyy kaikki luonnokset automaattisesti; oikeassa käytössä hyväksyjä on aina ihminen.
.EXAMPLE
./scripts/Show-Demo.ps1
./scripts/Show-Demo.ps1 -Query 'Outlook ei näytä jaettua postilaatikkoa'
#>
[CmdletBinding()]
param(
    [string[]]$Query = @(
        'Jaettu laatikko ei näy Outlookissa'
        'Puhelin vaihtui, en saa MFA-vahvistusta'
        'Tulostin ei lähetä skannattua dokumenttia sähköpostiin'
        'Kahvinkeitin rikki toimistolla'
    )
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/ServiceDeskKB.psm1" -Force
Import-Module "$PSScriptRoot/../src/KnowledgeBase.psm1" -Force
Import-Module "$PSScriptRoot/../src/Suggestion.psm1" -Force

$kb = Join-Path $PSScriptRoot '../output/demo-kb'
if (Test-Path $kb) { Remove-Item $kb -Recurse -Force }

$tickets = Get-Content "$PSScriptRoot/../data/tickets.json" -Raw -Encoding utf8 | ConvertFrom-Json
$drafts  = @($tickets | ConvertTo-AnonymizedTicket | New-KBArticleDraft -Provider (New-MockAIProvider))
$drafts | Save-KBArticle -Path $kb | Out-Null
$drafts | ForEach-Object { $null = Set-KBArticleStatus -Path $kb -Id $_.id -Status 'Hyväksytty' -Reviewer 'Demo' }

Write-Host "`n$($tickets.Count) tikettiä anonymisoitu, $($drafts.Count) artikkelia hyväksytty tietopankkiin.`n" -ForegroundColor Green

foreach ($q in $Query) {
    Write-Host "Uusi tiketti: $q" -ForegroundColor Cyan
    $s = @(Find-KBSuggestion -Text $q -KbPath $kb)
    if ($s.Count -eq 0) {
        Write-Host '  Ei ehdotuksia – käsittelijä ratkaisee itse.' -ForegroundColor DarkGray
    }
    else {
        foreach ($x in $s) { Write-Host ('  {0}  {1,4:0.00}  {2}' -f $x.Id, $x.Score, $x.Title) }
        Write-Host "  Paras osuma, ratkaisu: $($s[0].Steps -join ' ')" -ForegroundColor DarkGray
    }
    Write-Host ''
}
