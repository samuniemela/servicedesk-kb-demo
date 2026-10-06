\xef\xbb\xbf<#
.SYNOPSIS
Anonymisoi suljetut tiketit ja tarkistaa, ettei henkilötietoja jäänyt.
.EXAMPLE
./scripts/Invoke-Anonymization.ps1
#>
[CmdletBinding()]
param(
    [string]$InputPath  = "$PSScriptRoot/../data/tickets.json",
    [string]$OutputPath = "$PSScriptRoot/../output/tickets.anonymized.json"
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/ServiceDeskKB.psm1" -Force

$tickets    = Get-Content $InputPath -Raw -Encoding utf8 | ConvertFrom-Json
$anonymized = @($tickets | ConvertTo-AnonymizedTicket)

# Tarkistusportti: mitään ei kirjoiteta, jos henkilötietoja jäi.
$problems = foreach ($t in $anonymized) {
    $text = @($t.title, $t.description, $t.resolution, $t.worklog) -join "`n"
    Find-PersonalData -Text $text | ForEach-Object {
        [pscustomobject]@{ Ticket = $t.id; Type = $_.Type; Value = $_.Value }
    }
}

if ($problems) {
    $problems | Format-Table -AutoSize | Out-String | Write-Host
    throw "Anonymisointi pysäytetty: $(@($problems).Count) löydöstä. Mitään ei tallennettu."
}

$null = New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force
$anonymized | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding utf8

Write-Host "Anonymisoitu $($anonymized.Count) tikettiä -> $OutputPath" -ForegroundColor Green
