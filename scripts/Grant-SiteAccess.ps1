<#
.SYNOPSIS
Kertaluonteinen ylläpitäjän toimenpide: antaa sovellukselle kirjoitusoikeuden yhdelle SharePoint-sivustolle (Sites.Selected).
.DESCRIPTION
Sovelluksen API-oikeus Sites.Selected ei yksinään anna pääsyä mihinkään. Pääsy myönnetään sivustokohtaisesti
tällä skriptillä, jolloin sovellus näkee vain ServiceDesk-sivuston eikä muita tenantin sivustoja.

Ajaja kirjautuu omilla tunnuksillaan (delegoitu oikeus Sites.FullControl.All, vaatii ylläpitäjän suostumuksen).
Vaatii moduulin Microsoft.Graph.Authentication:
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
.EXAMPLE
./scripts/Grant-SiteAccess.ps1 -SiteUrl https://<tenant>.sharepoint.com/sites/ServiceDesk -ClientId <sovelluksen client id>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SiteUrl,
    [Parameter(Mandatory)][string]$ClientId,
    [string]$DisplayName = 'ServiceDesk KB Publisher',
    [ValidateSet('read', 'write')][string]$Role = 'write'
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication

# Codespacesissa ei ole selainta, joten kirjautuminen laitekoodilla.
Connect-MgGraph -Scopes 'Sites.FullControl.All' -UseDeviceCode -NoWelcome

$u = [uri]$SiteUrl
$site = Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$($u.Host):$($u.AbsolutePath.TrimEnd('/'))"

$existing = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$($site.id)/permissions").value |
    Where-Object { $_.grantedToIdentitiesV2.application.id -contains $ClientId -or $_.grantedToIdentities.application.id -contains $ClientId }

if ($existing) {
    Write-Host "Sovelluksella on jo oikeus sivustoon: $($existing.roles -join ', ')" -ForegroundColor Yellow
    return
}

if ($PSCmdlet.ShouldProcess($SiteUrl, "Myönnä '$Role' sovellukselle $ClientId")) {
    $body = @{
        roles               = @($Role)
        grantedToIdentities = @(@{ application = @{ id = $ClientId; displayName = $DisplayName } })
    }
    $p = Invoke-MgGraphRequest -Method POST -Uri "v1.0/sites/$($site.id)/permissions" -Body $body
    Write-Host "Myönnetty: $($p.roles -join ', ') -> $DisplayName" -ForegroundColor Green
}
