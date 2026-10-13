#Requires -Version 7.0
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ServiceDeskKB.psm1')

$script:GraphRoot       = 'https://graph.microsoft.com/v1.0'
$script:RequiredColumns = @('Title', 'Oire', 'Ratkaisu', 'Kategoria', 'Lahdetiketti', 'Tila')

# ---------------------------------------------------------------------------
# Kirjautuminen (app registration, client credentials)
# ---------------------------------------------------------------------------

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-ClientAssertion {
    <#
    .SYNOPSIS
    Varmenteella allekirjoitettu JWT (client assertion) Entra ID:n tokenpyyntöön.
    Varmenteen yksityinen avain ei lähde koneelta; tokenpalvelu saa vain allekirjoituksen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [int]$LifetimeSeconds = 600
    )

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'Varmenteessa ei ole RSA-yksityisavainta.' }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-Base64Url $Certificate.GetCertHash()) }
    $payload = @{
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now
        exp = $now + $LifetimeSeconds
    }

    $enc = [System.Text.Encoding]::UTF8
    $unsigned = (ConvertTo-Base64Url $enc.GetBytes(($header | ConvertTo-Json -Compress))) + '.' +
                (ConvertTo-Base64Url $enc.GetBytes(($payload | ConvertTo-Json -Compress)))
    $signature = $rsa.SignData($enc.GetBytes($unsigned),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

    "$unsigned.$(ConvertTo-Base64Url $signature)"
}

function Connect-SPGraph {
    <#
    .SYNOPSIS
    Hakee sovellustokenin Microsoft Graphiin (client credentials).
    .DESCRIPTION
    Tunnukset luetaan ympäristömuuttujista, ei koskaan tiedostosta tai repoista:
      GRAPH_TENANT_ID, GRAPH_CLIENT_ID ja joko
      GRAPH_CERT_PATH (+ GRAPH_CERT_PASSWORD)   suositeltu
      GRAPH_CLIENT_SECRET                       vaihtoehto
    Testeissä -Invoker korvaa kaikki HTTP-kutsut, jolloin verkkoa ei tarvita.
    #>
    [CmdletBinding()]
    param(
        [string]$TenantId          = $env:GRAPH_TENANT_ID,
        [string]$ClientId          = $env:GRAPH_CLIENT_ID,
        [string]$CertificatePath   = $env:GRAPH_CERT_PATH,
        [string]$CertificatePassword = $env:GRAPH_CERT_PASSWORD,
        [string]$ClientSecret      = $env:GRAPH_CLIENT_SECRET,
        [scriptblock]$Invoker
    )

    if ($Invoker) {
        return [pscustomobject]@{ Mode = 'Test'; Token = 'test-token'; Invoker = $Invoker }
    }

    foreach ($p in @{ GRAPH_TENANT_ID = $TenantId; GRAPH_CLIENT_ID = $ClientId }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($p.Value)) { throw "Ympäristömuuttuja $($p.Key) puuttuu." }
    }

    $form = @{
        client_id  = $ClientId
        scope      = 'https://graph.microsoft.com/.default'
        grant_type = 'client_credentials'
    }

    if (-not [string]::IsNullOrWhiteSpace($CertificatePath)) {
        if (-not (Test-Path $CertificatePath)) { throw "Varmennetta ei löydy: $CertificatePath" }
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            (Resolve-Path $CertificatePath).Path, $CertificatePassword)
        $form.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $form.client_assertion      = New-ClientAssertion -TenantId $TenantId -ClientId $ClientId -Certificate $cert
        $mode = 'Varmenne'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ClientSecret)) {
        $form.client_secret = $ClientSecret
        $mode = 'Salaisuus'
    }
    else {
        throw 'Tunnus puuttuu. Aseta GRAPH_CERT_PATH (suositeltu) tai GRAPH_CLIENT_SECRET.'
    }

    try {
        $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body $form -ContentType 'application/x-www-form-urlencoded'
    }
    catch {
        # Virheviestiin ei tulosteta pyynnön sisältöä, koska siinä on tunnus.
        throw "Tokenin haku epäonnistui: $(Get-GraphErrorMessage $_)"
    }

    [pscustomobject]@{ Mode = $mode; Token = $r.access_token; Invoker = $null }
}

function Get-GraphErrorMessage {
    param($ErrorRecord)
    $detail = if ($ErrorRecord.ErrorDetails) { $ErrorRecord.ErrorDetails.Message } else { $null }
    if ($detail) {
        try {
            $j = $detail | ConvertFrom-Json -ErrorAction Stop
            if ($j.PSObject.Properties.Name -contains 'error') {
                if ($j.error -is [string]) { return "$($j.error): $($j.error_description)" }
                return "$($j.error.code): $($j.error.message)"
            }
        }
        catch { }
        return $detail
    }
    $ErrorRecord.Exception.Message
}

function Invoke-SPGraph {
    <#
    .SYNOPSIS
    Yksi Graph-kutsu. Uusii pyynnön kerran, jos Graph palauttaa 429/503 (Retry-After).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [ValidateSet('GET', 'POST', 'PATCH')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [object]$Body,
        [hashtable]$Headers = @{}
    )

    $uri = if ($Path -match '^https://') { $Path } else { "$script:GraphRoot$Path" }
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 6 -Compress } else { $null }

    if ($Connection.Invoker) {
        return (& $Connection.Invoker $Method $uri $json $Headers)
    }

    $h = @{ Authorization = "Bearer $($Connection.Token)" } + $Headers
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $params = @{ Method = $Method; Uri = $uri; Headers = $h }
            if ($json) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json); $params.ContentType = 'application/json; charset=utf-8' }
            return Invoke-RestMethod @params
        }
        catch {
            $resp = if ($_.Exception.PSObject.Properties.Name -contains 'Response') { $_.Exception.Response } else { $null }
            $status = if ($resp) { [int]$resp.StatusCode } else { 0 }
            if ($attempt -eq 1 -and $status -in 429, 503) {
                $wait = 5
                $ra = $resp.Headers.RetryAfter
                if ($ra -and $ra.Delta) { $wait = [int][Math]::Ceiling($ra.Delta.TotalSeconds) }
                Start-Sleep -Seconds ([Math]::Min($wait, 60))
                continue
            }
            $code = if ($status) { " ($status)" } else { '' }
            throw "Graph $Method $uri epäonnistui${code}: $(Get-GraphErrorMessage $_)"
        }
    }
}

# ---------------------------------------------------------------------------
# Kohdelista
# ---------------------------------------------------------------------------

function Get-SPKBListTarget {
    <#
    .SYNOPSIS
    Selvittää sivuston ja listan tunnisteet sekä tarkistaa, että listalla on tarvittavat sarakkeet.
    Sarakkeiden tyypit (luku/teksti, rich text, valinnat) luetaan listalta, jotta kirjoitus vastaa niitä.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$SiteUrl,
        [string]$ListName = 'KB-luonnokset'
    )

    $u = [uri]$SiteUrl
    $site = Invoke-SPGraph -Connection $Connection -Path "/sites/$($u.Host):$($u.AbsolutePath.TrimEnd('/'))"

    $lists = Invoke-SPGraph -Connection $Connection -Path "/sites/$($site.id)/lists?`$select=id,displayName,name"
    $list = @($lists.value | Where-Object { $_.displayName -eq $ListName -or $_.name -eq $ListName }) | Select-Object -First 1
    if (-not $list) { throw "Listaa '$ListName' ei löytynyt sivustolta $SiteUrl." }

    $cols = Invoke-SPGraph -Connection $Connection -Path "/sites/$($site.id)/lists/$($list.id)/columns"
    $byName = @{}
    foreach ($c in $cols.value) { $byName[$c.name] = $c }

    $missing = @($script:RequiredColumns | Where-Object { -not $byName.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "Listalta '$ListName' puuttuu sarakkeita (sisäinen nimi): $($missing -join ', ')"
    }

    $columns = @{}
    foreach ($name in $script:RequiredColumns) {
        $columns[$name] = ConvertTo-SPColumnInfo $byName[$name]
    }

    [pscustomobject]@{
        SiteId   = $site.id
        ListId   = $list.id
        ListName = $list.displayName
        Columns  = $columns
    }
}

function ConvertTo-SPColumnInfo {
    param([object]$Column)
    $names = @($Column.PSObject.Properties.Name)
    $info = [ordered]@{ Name = $Column.name; Kind = 'Other'; RichText = $false; MultiLine = $false; MaxLength = 0; Choices = @(); AllowFillIn = $true }

    if ($names -contains 'number' -and $Column.number) { $info.Kind = 'Number' }
    elseif ($names -contains 'choice' -and $Column.choice) {
        $info.Kind = 'Choice'
        $info.Choices = @($Column.choice.choices)
        $info.AllowFillIn = [bool]$Column.choice.allowTextEntry
    }
    elseif ($names -contains 'text' -and $Column.text) {
        $t = $Column.text
        $tn = @($t.PSObject.Properties.Name)
        $info.Kind      = 'Text'
        $info.MultiLine = ($tn -contains 'allowMultipleLines') -and [bool]$t.allowMultipleLines
        $info.RichText  = ($tn -contains 'textType') -and $t.textType -eq 'richText'
        $info.MaxLength = if ($tn -contains 'maxLength' -and $t.maxLength) { [int]$t.maxLength } else { 0 }
    }
    [pscustomobject]$info
}

# ---------------------------------------------------------------------------
# Luonnos -> listan kentät
# ---------------------------------------------------------------------------

function Format-SPText {
    param([string]$Text, [object]$Column)
    if ($Column.Kind -eq 'Text' -and -not $Column.MultiLine) {
        $Text = ($Text -replace '\s*\r?\n\s*', ' ').Trim()
    }
    if ($Column.MaxLength -gt 0 -and $Text.Length -gt $Column.MaxLength) {
        $Text = $Text.Substring(0, $Column.MaxLength - 1) + '…'
    }
    $Text
}

function ConvertTo-SPKBFields {
    <#
    .SYNOPSIS
    Muuntaa artikkeliluonnoksen KB-luonnokset-listan kentiksi (sisäiset nimet).
    .DESCRIPTION
    Ratkaisu = syy + numeroidut vaiheet. Rich text -sarakkeeseen kirjoitetaan HTML, tavalliseen tekstiä.
    Lahdetiketti kirjoitetaan lukuna (1001), jos sarake on lukutyyppinen, muuten tekstinä (T-1001).
    Hyvaksyja jätetään tyhjäksi: sen asettaa hyväksyntä-flow.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Article,
        [Parameter(Mandatory)][object]$Target
    )

    $cols = $Target.Columns
    $steps = @($Article.steps | ForEach-Object { [string]$_ })

    if ($cols.Ratkaisu.RichText) {
        $e = { param($s) [System.Net.WebUtility]::HtmlEncode($s) }
        $items = ($steps | ForEach-Object { "<li>$(& $e $_)</li>" }) -join ''
        $ratkaisu = "<p><strong>Syy:</strong> $(& $e $Article.cause)</p><p><strong>Toimenpiteet:</strong></p><ol>$items</ol>"
    }
    else {
        $i = 0
        $lines = $steps | ForEach-Object { $i++; "$i. $_" }
        $ratkaisu = "Syy: $($Article.cause)`n`nToimenpiteet:`n$($lines -join "`n")"
        $ratkaisu = Format-SPText $ratkaisu $cols.Ratkaisu
    }

    $source = [string]$Article.sourceTicket
    $lahde = if ($cols.Lahdetiketti.Kind -eq 'Number') {
        $digits = $source -replace '\D', ''
        if (-not $digits) { throw "Lähdetiketin '$source' numero-osaa ei voitu lukea." }
        [int]$digits
    }
    else { $source }

    $fields = [ordered]@{
        Title        = Format-SPText ([string]$Article.title) ([pscustomobject]@{ Kind = 'Text'; MultiLine = $false; MaxLength = 255 })
        Oire         = Format-SPText ([string]$Article.symptoms) $cols.Oire
        Ratkaisu     = $ratkaisu
        Lahdetiketti = $lahde
        Tila         = 'Luonnos'
    }

    $category = [string]$Article.category
    $k = $cols.Kategoria
    if ($k.Kind -eq 'Choice' -and -not $k.AllowFillIn -and $k.Choices -notcontains $category) {
        Write-Warning "Kategoria '$category' ei ole listan valinnoissa ($($k.Choices -join ', ')). Kenttä jätetään tyhjäksi."
    }
    elseif ($category) {
        $fields.Kategoria = Format-SPText $category $k
    }

    $fields
}

# ---------------------------------------------------------------------------
# Kirjoitus listalle
# ---------------------------------------------------------------------------

function Find-SPKBDraft {
    <#
    .SYNOPSIS
    Hakee listalta luonnokset, joiden Lahdetiketti vastaa annettua arvoa (kaksoiskappaleiden esto).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$SourceTicket
    )

    $value = if ($SourceTicket -is [int]) { "$SourceTicket" } else { "'$($SourceTicket -replace "'", "''")'" }
    $filter = [uri]::EscapeDataString("fields/Lahdetiketti eq $value")
    $path = "/sites/$($Target.SiteId)/lists/$($Target.ListId)/items?`$expand=fields(`$select=Title,Lahdetiketti,Tila)&`$filter=$filter"
    # Lahdetiketti ei ole indeksoitu sarake; pienellä listalla suodatus on silti sallittu tällä otsakkeella.
    $r = Invoke-SPGraph -Connection $Connection -Path $path -Headers @{ Prefer = 'HonorNonIndexedQueriesWarningMayFailRandomly' }
    @($r.value)
}

function Publish-SPKBDraft {
    <#
    .SYNOPSIS
    Kirjoittaa yhden artikkeliluonnoksen KB-luonnokset-listaan.
    .DESCRIPTION
    - Vain tilassa 'Luonnos' olevat artikkelit julkaistaan.
    - Henkilötietotarkistus ajetaan uudelleen juuri ennen lähetystä (luonnosta on voitu muokata käsin).
    - Jos samasta tiketistä on jo luonnos listalla, mitään ei kirjoiteta.
    Palauttaa tulosrivin: Id, Tulos (Luotu / Ohitettu / Esto), ItemId, Syy.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][object]$Article,
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][object]$Target,
        [string[]]$KnownValues = @()
    )

    process {
        $result = { param($tulos, $itemId, $syy) [pscustomobject]@{ Id = $Article.id; Tulos = $tulos; ItemId = $itemId; Syy = $syy } }

        if ($Article.status -ne 'Luonnos') {
            return (& $result 'Ohitettu' $null "Tila on $($Article.status), vain luonnokset julkaistaan.")
        }

        $text = (@($Article.title, $Article.symptoms, $Article.cause) + @($Article.steps)) -join "`n"
        $findings = @(Find-PersonalData -Text $text -KnownValues $KnownValues)
        if ($findings.Count -gt 0) {
            $types = ($findings.Type | Select-Object -Unique) -join ', '
            return (& $result 'Esto' $null "Henkilötietoja löytyi ($types). Mitään ei lähetetty.")
        }

        $fields = ConvertTo-SPKBFields -Article $Article -Target $Target

        $existing = @(Find-SPKBDraft -Connection $Connection -Target $Target -SourceTicket $fields.Lahdetiketti)
        if ($existing.Count -gt 0) {
            return (& $result 'Ohitettu' $existing[0].id "Lähdetiketistä $($fields.Lahdetiketti) on jo luonnos listalla.")
        }

        if (-not $PSCmdlet.ShouldProcess("$($Target.ListName): $($fields.Title)", 'Luo luonnos')) {
            return (& $result 'Ohitettu' $null 'WhatIf')
        }

        $created = Invoke-SPGraph -Connection $Connection -Method POST `
            -Path "/sites/$($Target.SiteId)/lists/$($Target.ListId)/items" -Body @{ fields = $fields }
        & $result 'Luotu' $created.id $null
    }
}

Export-ModuleMember -Function Connect-SPGraph, New-ClientAssertion, Invoke-SPGraph, Get-SPKBListTarget,
    ConvertTo-SPKBFields, Find-SPKBDraft, Publish-SPKBDraft
