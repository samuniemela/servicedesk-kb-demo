<#
.SYNOPSIS
Kirjoittaa tietopankkiluonnokset SharePointin KB-luonnokset-listaan Microsoft Graphin kautta.
Hyväksyntä tapahtuu listalla Power Automate -flow'ssa, ei tässä skriptissä.
.DESCRIPTION
Tunnukset ympäristömuuttujista (ks. docs/sharepoint-graph.md):
  GRAPH_TENANT_ID, GRAPH_CLIENT_ID, GRAPH_CERT_PATH (+ GRAPH_CERT_PASSWORD) tai GRAPH_CLIENT_SECRET
  SP_SITE_URL, esim. https://<tenant>.sharepoint.com/sites/ServiceDesk
.EXAMPLE
./scripts/New-KBDrafts.ps1 -Provider Claude
./scripts/Publish-KBDrafts.ps1 -WhatIf          # näyttää, mitä kirjoitettaisiin
./scripts/Publish-KBDrafts.ps1 -Id KB-1001      # yksi luonnos
./scripts/Publish-KBDrafts.ps1                  # kaikki luonnokset
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$KbPath   = "$PSScriptRoot/../output/kb",
    [string]$SiteUrl  = $env:SP_SITE_URL,
    [string]$ListName = 'KB-luonnokset',
    [string[]]$Id
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/KnowledgeBase.psm1" -Force
Import-Module "$PSScriptRoot/../src/SharePointGraph.psm1" -Force

if ([string]::IsNullOrWhiteSpace($SiteUrl)) {
    throw 'Sivuston osoite puuttuu. Anna -SiteUrl tai aseta ympäristömuuttuja SP_SITE_URL.'
}

$drafts = @(Get-KBArticle -Path $KbPath -Status Luonnos)
if ($Id) { $drafts = @($drafts | Where-Object { $Id -contains $_.id }) }
if ($drafts.Count -eq 0) {
    Write-Host "Ei julkaistavia luonnoksia kansiossa $KbPath." -ForegroundColor Yellow
    return
}

$conn   = Connect-SPGraph
$target = Get-SPKBListTarget -Connection $conn -SiteUrl $SiteUrl -ListName $ListName
Write-Host "Kohde: $($target.ListName) ($SiteUrl), kirjautuminen: $($conn.Mode)"

$results = foreach ($d in $drafts) {
    try {
        $d | Publish-SPKBDraft -Connection $conn -Target $target -WhatIf:$WhatIfPreference
    }
    catch {
        [pscustomobject]@{ Id = $d.id; Tulos = 'Virhe'; ItemId = $null; Syy = $_.Exception.Message }
    }
}

$results | Format-Table Id, Tulos, ItemId, Syy -AutoSize -Wrap
$created = @($results | Where-Object Tulos -eq 'Luotu').Count
Write-Host "Luotu $created / $($drafts.Count). Hyväksyntäpyyntö lähtee flow'sta 1–5 minuutin kuluessa." -ForegroundColor Green
