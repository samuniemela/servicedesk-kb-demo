#Requires -Version 7.0
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Asetukset
# ---------------------------------------------------------------------------

$script:RegexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                       [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

# Suomen yleisimmät taivutuspäätteet nimille (Matti -> Matille, Virtanen -> Virtaselle).
$script:FinnishSuffixes = @(
    '', 'n', 'a', 'ä', 'in', 'ia', 'iä', 'na', 'nä',
    'lle', 'ille', 'lta', 'ltä', 'lla', 'llä',
    'sta', 'stä', 'ssa', 'ssä', 'ksi', 'kin', 'nkin'
)

# Rajaus: kirjain tai numero ei saa olla osuman vieressä.
$script:Before = '(?<![\p{L}\p{N}])'
$script:After  = '(?![\p{L}\p{N}])'

$script:Patterns = @{
    Email  = '[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.\p{L}{2,}'
    # Suomalaiset numerot: +358 / 00358 / 0 -alkuiset, välilyönnit ja viivat sallittu.
    Phone  = '(?<![\p{L}\p{N}])(?:\+358|00358|0)[ -]?\d{1,3}(?:[ -]?\d){4,9}(?![\p{L}\p{N}])'
    IPv4   = '(?<!\d)(?<!\d\.)(?:\d{1,3}\.){3}\d{1,3}(?!\d)(?!\.\d)'
    # Sarjanumero tunnistetaan sitä edeltävästä sanasta, jotta virhekoodit (0x80180014) säilyvät.
    Serial = '(?<label>sarjanumero|serial(?: number)?|s/n)(?<sep>\s*:?\s*)(?<value>[A-Z0-9][A-Z0-9-]{4,})'
}

# ---------------------------------------------------------------------------
# Apufunktiot
# ---------------------------------------------------------------------------

function Get-NameStem {
    <#
    .SYNOPSIS
    Palauttaa nimen vartalot taivutusmuotojen tunnistamiseen.
    Matti -> Matti, Mati (Matin, Matille) · Virtanen -> Virtanen, Virtase (Virtasen)
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Name)

    $stems = [System.Collections.Generic.List[string]]::new()
    $stems.Add($Name)

    if ($Name -match 'nen$') {
        $stems.Add($Name.Substring(0, $Name.Length - 3) + 'se')
    }

    # Astevaihtelu viimeisessä tavussa: kk -> k, pp -> p, tt -> t (Pekka -> Pekan, Mikko -> Mikolle).
    $m = [regex]::Match($Name, '(kk|pp|tt)(?=[^kpt]*$)')
    if ($m.Success) {
        $stems.Add($Name.Remove($m.Index, 1))
    }

    return , ($stems | Select-Object -Unique)
}

function Join-Alternation {
    param([string[]]$Values)
    ($Values | Sort-Object -Property Length -Descending |
        ForEach-Object { [regex]::Escape($_) }) -join '|'
}

function New-InflectedPattern {
    param([Parameter(Mandatory)][string[]]$Stems)
    $alt = Join-Alternation $Stems
    $suf = Join-Alternation $script:FinnishSuffixes
    "$($script:Before)(?:$alt)(?:$suf)$($script:After)"
}

function New-PersonEntity {
    <#
    .SYNOPSIS
    Rakentaa henkilölle korvausmerkinnän ja tunnistuslausekkeet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Token
    )

    $parts = @($Name -split '\s+' | Where-Object { $_.Length -ge 3 })

    $partPatterns = @($parts | ForEach-Object { New-InflectedPattern -Stems (Get-NameStem $_) })

    $fullPattern = $null
    if ($parts.Count -ge 2) {
        $firstAlt = Join-Alternation (Get-NameStem $parts[0])
        $lastAlt  = Join-Alternation (Get-NameStem $parts[-1])
        $suf      = Join-Alternation $script:FinnishSuffixes
        # Etunimi taipuu harvoin koko nimessä (Tom Anderssonille), sukunimi taipuu.
        $fullPattern = "$($script:Before)(?:$firstAlt)\s+(?:$lastAlt)(?:$suf)$($script:After)"
    }

    [pscustomobject]@{
        Name         = $Name
        Parts        = $parts
        Token        = $Token
        FullPattern  = $fullPattern
        PartPatterns = $partPatterns
    }
}

function Get-OrganizationPattern {
    <#
    .SYNOPSIS
    Organisaation nimen muodot: koko nimi, nimi ilman yhtiömuotoa ja ensimmäinen sana.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $base  = $Name -replace '\s+(Oy|Oyj|Ab|Ltd|Inc)\.?$', ''
    $forms = [System.Collections.Generic.List[string]]::new()
    $forms.Add($Name)
    if ($base -ne $Name) { $forms.Add($base) }

    $first = ($base -split '\s+')[0]
    if ($first.Length -ge 5 -and $first -ne $base) { $forms.Add($first) }

    $suf = Join-Alternation $script:FinnishSuffixes
    # Pisin muoto ensin, jotta "Kuusirinne Oy" korvautuu kokonaan eikä vain "Kuusirinne".
    $forms | Sort-Object -Property Length -Descending | ForEach-Object {
        "$($script:Before)$([regex]::Escape($_))(?:$suf)$($script:After)"
    }
}

# ---------------------------------------------------------------------------
# Julkiset funktiot
# ---------------------------------------------------------------------------

function Protect-TicketText {
    <#
    .SYNOPSIS
    Poistaa tekstistä henkilötiedot ja korvaa ne merkinnöillä.
    .DESCRIPTION
    Järjestys: sähköpostit, sarjanumerot, IP-osoitteet, puhelinnumerot,
    henkilöiden koko nimet, nimen osat taivutusmuotoineen ja organisaatio.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [object[]]$People = @(),
        [string]$Organization
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $o = $script:RegexOptions
    $t = [regex]::Replace($Text, $script:Patterns.Email, '[SÄHKÖPOSTI]', $o)
    $t = [regex]::Replace($t, $script:Patterns.Serial, '${label}${sep}[SARJANUMERO]', $o)
    $t = [regex]::Replace($t, $script:Patterns.IPv4, '[IP-OSOITE]', $o)
    $t = [regex]::Replace($t, $script:Patterns.Phone, '[PUHELIN]', $o)

    foreach ($p in $People) {
        if ($p.FullPattern) { $t = [regex]::Replace($t, $p.FullPattern, $p.Token, $o) }
    }
    foreach ($p in $People) {
        foreach ($pattern in $p.PartPatterns) { $t = [regex]::Replace($t, $pattern, $p.Token, $o) }
    }

    if ($Organization) {
        foreach ($pattern in (Get-OrganizationPattern -Name $Organization)) {
            $t = [regex]::Replace($t, $pattern, '[ORGANISAATIO]', $o)
        }
    }

    return $t
}

function ConvertTo-AnonymizedTicket {
    <#
    .SYNOPSIS
    Muuntaa suljetun tiketin anonymisoiduksi. Pyytäjän ja yhteyshenkilöiden
    tiedot poistetaan; sama henkilö saa saman merkinnän koko tiketissä.
    .EXAMPLE
    Get-Content data/tickets.json -Raw | ConvertFrom-Json | ConvertTo-AnonymizedTicket
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][object]$Ticket)

    process {
        $names = @($Ticket.requester.name) + @($Ticket.contacts | ForEach-Object { $_.name })
        $people = [System.Collections.Generic.List[object]]::new()
        $i = 1
        foreach ($n in ($names | Where-Object { $_ } | Select-Object -Unique)) {
            $people.Add((New-PersonEntity -Name $n -Token "[HENKILÖ-$i]"))
            $i++
        }

        $out = [ordered]@{
            id       = $Ticket.id
            category = $Ticket.category
            created  = $Ticket.created
            closed   = $Ticket.closed
        }
        foreach ($field in 'title', 'description', 'resolution', 'worklog') {
            $out[$field] = Protect-TicketText -Text $Ticket.$field -People $people -Organization $Ticket.organization
        }
        [pscustomobject]$out
    }
}

function Find-PersonalData {
    <#
    .SYNOPSIS
    Tarkistusportti: etsii tekstistä jäljelle jääneitä henkilötietoja ennen
    kuin mitään lähetetään AI-mallille. Palauttaa löydökset; tyhjä = puhdas.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [string[]]$KnownValues = @()
    )

    if ([string]::IsNullOrEmpty($Text)) { return }

    foreach ($type in 'Email', 'Phone', 'IPv4') {
        foreach ($m in [regex]::Matches($Text, $script:Patterns[$type], $script:RegexOptions)) {
            [pscustomobject]@{ Type = $type; Value = $m.Value }
        }
    }

    foreach ($v in ($KnownValues | Where-Object { $_ -and $_.Length -ge 3 })) {
        $pattern = "$($script:Before)$([regex]::Escape($v))$($script:After)"
        if ([regex]::IsMatch($Text, $pattern, $script:RegexOptions)) {
            [pscustomobject]@{ Type = 'KnownValue'; Value = $v }
        }
    }
}

Export-ModuleMember -Function Protect-TicketText, ConvertTo-AnonymizedTicket, Find-PersonalData, Get-NameStem
