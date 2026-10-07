#Requires -Version 7.0
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ServiceDeskKB.psm1')

$script:Statuses       = @('Luonnos', 'Hyväksytty', 'Hylätty')
$script:RequiredFields = @('title', 'symptoms', 'cause', 'steps')
$script:Placeholder    = '\s*\[(HENKILÖ-\d+|ORGANISAATIO|SÄHKÖPOSTI|PUHELIN|IP-OSOITE|SARJANUMERO)\]'

# ---------------------------------------------------------------------------
# AI-taustajärjestelmät
# ---------------------------------------------------------------------------

function New-MockAIProvider {
    <#
    .SYNOPSIS
    Testitila: tuottaa artikkeliluonnoksen ilman verkkoyhteyttä ja ilman API-avainta.
    #>
    [pscustomobject]@{ Type = 'Mock'; Name = 'Testitila' }
}

function New-ClaudeAIProvider {
    <#
    .SYNOPSIS
    Claude API. Avain luetaan ympäristömuuttujasta ANTHROPIC_API_KEY, ei koskaan tiedostosta.
    #>
    [CmdletBinding()]
    param(
        [string]$ApiKey = $env:ANTHROPIC_API_KEY,
        [string]$Model = 'claude-haiku-4-5-20251001',
        [int]$MaxTokens = 1500
    )
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'Claude API -avain puuttuu. Aseta ympäristömuuttuja ANTHROPIC_API_KEY.'
    }
    [pscustomobject]@{ Type = 'Claude'; Name = "Claude ($Model)"; Model = $Model; MaxTokens = $MaxTokens; ApiKey = $ApiKey }
}

function New-CustomAIProvider {
    <#
    .SYNOPSIS
    Oma taustajärjestelmä skriptilohkona (testit ja laajennukset).
    Skriptilohko saa parametrit $Prompt ja $Ticket ja palauttaa tekstin.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    [pscustomobject]@{ Type = 'Custom'; Name = $Name; ScriptBlock = $ScriptBlock }
}

function Remove-Placeholder {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    ($Text -replace $script:Placeholder, '').Trim(' ', ',', '/', '-')
}

function Get-MockArticleJson {
    param([object]$Ticket)

    $sentences = @($Ticket.resolution -split '(?<=\.)\s+' | Where-Object { $_ })
    $cause = if ($sentences.Count -gt 0) { $sentences[0] } else { '' }
    $steps = if ($sentences.Count -gt 1) { $sentences[1..($sentences.Count - 1)] } else { $sentences }

    @{
        title    = Remove-Placeholder $Ticket.title
        symptoms = Remove-Placeholder $Ticket.description
        cause    = Remove-Placeholder $cause
        steps    = @($steps | ForEach-Object { Remove-Placeholder $_ })
        keywords = @($Ticket.category -split '\s*/\s*')
    } | ConvertTo-Json -Depth 4
}

function Invoke-AIProvider {
    param([object]$Provider, [string]$Prompt, [object]$Ticket)

    switch ($Provider.Type) {
        'Mock' { return Get-MockArticleJson -Ticket $Ticket }
        'Custom' { return (& $Provider.ScriptBlock $Prompt $Ticket) }
        'Claude' {
            $body = @{
                model      = $Provider.Model
                max_tokens = $Provider.MaxTokens
                messages   = @(@{ role = 'user'; content = $Prompt })
            } | ConvertTo-Json -Depth 5
            $headers = @{ 'x-api-key' = $Provider.ApiKey; 'anthropic-version' = '2023-06-01' }
            $response = Invoke-RestMethod -Method Post -Uri 'https://api.anthropic.com/v1/messages' `
                -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body
            $text = @($response.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1)
            if ($text.Count -eq 0) { return $null }
            return $text[0].text
        }
        default { throw "Tuntematon AI-taustajärjestelmä: $($Provider.Type)" }
    }
}

# ---------------------------------------------------------------------------
# Artikkeliluonnos
# ---------------------------------------------------------------------------

function Get-KBPrompt {
    param([object]$Ticket)

    # Tietojen minimointi: vain artikkeliin tarvittavat kentät, ei työlokia.
    $payload = $Ticket | Select-Object id, category, title, description, resolution | ConvertTo-Json -Depth 3

    @"
Olet Service Desk -tietopankin kirjoittaja. Kirjoita alla olevasta ratkaistusta tiketistä yleiskäyttöinen ohjeartikkeli, jota toinen tukihenkilö voi seurata.

Säännöt:
- Älä mainitse henkilöitä, organisaatioita tai yhteystietoja. Jätä merkinnät kuten [HENKILÖ-1] ja [ORGANISAATIO] kokonaan pois.
- Kirjoita yleisessä muodossa ("käyttäjä", "laite"), suomeksi.
- Vastaa pelkkänä JSON-objektina ilman muuta tekstiä. Kentät:
  title (string), symptoms (string), cause (string), steps (taulukko merkkijonoja), keywords (taulukko merkkijonoja)

Tiketti:
$payload
"@
}

function ConvertFrom-AIArticleResponse {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'AI-vastaus oli tyhjä.' }

    $clean = $Text.Trim() -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
    try {
        $obj = $clean | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'AI-vastaus ei ollut kelvollista JSONia.'
    }

    $names = @($obj.PSObject.Properties.Name)
    foreach ($field in $script:RequiredFields) {
        if ($names -notcontains $field) { throw "AI-vastauksesta puuttuu kenttä '$field'." }
    }
    foreach ($field in 'title', 'symptoms', 'cause') {
        if ([string]::IsNullOrWhiteSpace([string]$obj.$field)) { throw "AI-vastauksesta puuttuu kentän '$field' sisältö." }
    }
    if (@($obj.steps).Count -eq 0) { throw "AI-vastauksesta puuttuu kentän 'steps' sisältö." }

    return $obj
}

function New-KBArticleDraft {
    <#
    .SYNOPSIS
    Luo anonymisoidusta tiketistä artikkeliluonnoksen.
    .DESCRIPTION
    1. Tarkistusportti: jos tiketissä on henkilötietoja, mitään ei lähetetä AI-mallille.
    2. AI kirjoittaa luonnoksen.
    3. Vastaus validoidaan ja tarkistetaan uudelleen henkilötietojen varalta.
    Tulos on aina tilassa 'Luonnos', kunnes ihminen hyväksyy sen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][object]$Ticket,
        [Parameter(Mandatory)][object]$Provider,
        [string[]]$KnownValues = @()
    )

    process {
        $inputText = @($Ticket.title, $Ticket.description, $Ticket.resolution, $Ticket.worklog) -join "`n"
        $findings = @(Find-PersonalData -Text $inputText -KnownValues $KnownValues)
        if ($findings.Count -gt 0) {
            $types = ($findings.Type | Select-Object -Unique) -join ', '
            throw "Tiketti $($Ticket.id): henkilötietoja löytyi ($types). Mitään ei lähetetty AI-mallille."
        }

        $prompt   = Get-KBPrompt -Ticket $Ticket
        $response = Invoke-AIProvider -Provider $Provider -Prompt $prompt -Ticket $Ticket
        $obj      = ConvertFrom-AIArticleResponse -Text $response

        $keywords = if ($obj.PSObject.Properties.Name -contains 'keywords') { @($obj.keywords) } else { @() }
        $outputText = (@($obj.title, $obj.symptoms, $obj.cause) + @($obj.steps)) -join "`n"
        if (@(Find-PersonalData -Text $outputText -KnownValues $KnownValues).Count -gt 0) {
            throw "Tiketti $($Ticket.id): AI-vastaus sisälsi henkilötietoja. Luonnosta ei tallennettu."
        }

        [pscustomobject]@{
            id           = 'KB-' + ($Ticket.id -replace '^T-', '')
            title        = [string]$obj.title
            symptoms     = [string]$obj.symptoms
            cause        = [string]$obj.cause
            steps        = @($obj.steps | ForEach-Object { [string]$_ })
            keywords     = @($keywords)
            category     = $Ticket.category
            sourceTicket = $Ticket.id
            status       = 'Luonnos'
            provider     = $Provider.Name
            createdAt    = (Get-Date).ToString('s')
            reviewedBy   = $null
            reviewedAt   = $null
        }
    }
}

# ---------------------------------------------------------------------------
# Tietopankki: tallennus ja hyväksyntä
# ---------------------------------------------------------------------------

function Save-KBArticle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][object]$Article,
        [Parameter(Mandatory)][string]$Path
    )
    process {
        $null = New-Item -ItemType Directory -Path $Path -Force
        $file = Join-Path $Path "$($Article.id).json"
        $Article | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding utf8
        Get-Item $file
    }
}

function Get-KBArticle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Luonnos', 'Hyväksytty', 'Hylätty')][string]$Status
    )
    if (-not (Test-Path $Path)) { return }
    Get-ChildItem -Path $Path -Filter '*.json' | Sort-Object Name | ForEach-Object {
        $a = Get-Content $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json
        if (-not $Status -or $a.status -eq $Status) { $a }
    }
}

function Get-KnowledgeBase {
    <#
    .SYNOPSIS
    Palauttaa vain ihmisen hyväksymät artikkelit. Luonnokset ja hylätyt eivät koskaan päädy tänne.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Get-KBArticle -Path $Path -Status 'Hyväksytty'
}

function Set-KBArticleStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Hyväksytty', 'Hylätty')][string]$Status,
        [Parameter(Mandatory)][string]$Reviewer
    )
    $file = Join-Path $Path "$Id.json"
    if (-not (Test-Path $file)) { throw "Artikkelia $Id ei löydy." }

    $a = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    if ($a.status -ne 'Luonnos') { throw "Artikkeli $Id on jo käsitelty ($($a.status))." }

    $a.status     = $Status
    $a.reviewedBy = $Reviewer
    $a.reviewedAt = (Get-Date).ToString('s')
    $a | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding utf8
    $a
}

Export-ModuleMember -Function New-MockAIProvider, New-ClaudeAIProvider, New-CustomAIProvider,
    New-KBArticleDraft, Save-KBArticle, Get-KBArticle, Get-KnowledgeBase, Set-KBArticleStatus
