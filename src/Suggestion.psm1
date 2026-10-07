#Requires -Version 7.0
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ServiceDeskKB.psm1')
Import-Module (Join-Path $PSScriptRoot 'KnowledgeBase.psm1')

# Käsitteet: suomen- ja englanninkieliset sanat (sanan alku, jotta taivutusmuodot osuvat)
# yhdistetään samaan käsitteeseen. "postilaatikkoon" ja "mailbox" -> #mailbox.
$script:Concepts = [ordered]@{
    mailbox    = 'postilaatik', 'laatikko', 'laatikk', 'mailbox', 'shared'
    outlook    = 'outlook'
    missing    = 'puuttu', 'missing', 'näy', 'näkyy', 'näkyi', 'visible', 'show', 'löydä', 'hukassa', 'katos'
    mfa        = 'mfa', 'authenticator', 'vahvistu', 'todennu', 'kaksivaih', '2fa'
    phone      = 'puhelin', 'puhelim', 'phone', 'kännykk'
    bitlocker  = 'bitlocker', 'palautusavain', 'recovery', 'avainta'
    autopilot  = 'autopilot', 'käyttöönot', 'enrollment', '0x80180014'
    recording  = 'tallenne', 'tallennet', 'nauhoit', 'recording'
    meeting    = 'kokou', 'palaveri', 'meeting'
    scan       = 'skann', 'scan', 'monitoimi', 'kopiokon', 'tulostin', 'printer'
    email      = 'sähköpost', 'email', 'smtp'
    share      = 'jaett', 'jakami', 'jaoin', 'jako', 'share', 'sharing', 'kumppani', 'alihankk', 'vieras', 'guest', 'ulkoi', 'external'
    compliance = 'yhteensop', 'compliant', 'compliance', 'vaatimuks'
    password   = 'salasan', 'password', 'sspr'
    laptop     = 'läppär', 'kannettav', 'laptop', 'kone'
    newuser    = 'työntekij', 'aloitta', 'onboard', 'tunnukse'
    change     = 'vaihto', 'vaihtu', 'vaihd', 'vaihta', 'replac', 'switch'
    access     = 'pääse', 'pääsy', 'access', 'oikeu'
}

$script:StopWords = [System.Collections.Generic.HashSet[string]]::new([string[]](
    'ei', 'en', 'ja', 'on', 'se', 'että', 'mutta', 'nyt', 'jo', 'the', 'not', 'in', 'to', 'is', 'of', 'an', 'my', 'it',
    'but', 'was', 'and', 'for', 'mitä', 'miten', 'jotain', 'vaikka', 'enää', 'eilen', 'kun', 'myös', 'sen', 'hän'))

function Get-TextToken {
    <#
    .SYNOPSIS
    Muuttaa tekstin painotetuksi sanajoukoksi. Käsiteosumat (paino 2) merkitään #-alkuisina,
    muut sanat lyhennetään kuuteen merkkiin taivutusmuotojen yhdistämiseksi (paino 1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyString()][AllowNull()][string]$Text)

    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Text)) { return $result }

    foreach ($m in [regex]::Matches($Text.ToLowerInvariant(), '[\p{L}\p{N}]+')) {
        $w = $m.Value
        if ($w.Length -lt 3 -or $script:StopWords.Contains($w)) { continue }

        $concept = $null
        foreach ($name in $script:Concepts.Keys) {
            foreach ($stem in $script:Concepts[$name]) {
                if ($w.StartsWith($stem, [System.StringComparison]::Ordinal)) { $concept = $name; break }
            }
            if ($concept) { break }
        }

        if ($concept) { $result["#$concept"] = 2 }
        elseif ($w.Length -ge 4) { $result[$w.Substring(0, [Math]::Min(6, $w.Length))] = 1 }
    }
    return $result
}

function Get-TokenSimilarity {
    param([hashtable]$A, [hashtable]$B)
    if ($A.Count -eq 0 -or $B.Count -eq 0) { return 0.0 }
    $inter = 0
    foreach ($k in $A.Keys) { if ($B.ContainsKey($k)) { $inter += [Math]::Min($A[$k], $B[$k]) } }
    $sumA = ($A.Values | Measure-Object -Sum).Sum
    $sumB = ($B.Values | Measure-Object -Sum).Sum
    return $inter / [Math]::Sqrt($sumA * $sumB)
}

function Find-KBSuggestion {
    <#
    .SYNOPSIS
    Ehdottaa uudelle tiketille ratkaisuja hyväksytyistä tietopankkiartikkeleista.
    .DESCRIPTION
    Vertailu tehdään paikallisesti, eikä mitään lähetetä ulos. Uuden tiketin tekstistä
    poistetaan silti yhteystiedot ennen käsittelyä. Vain ihmisen hyväksymät artikkelit
    ovat mukana; luonnoksia ei koskaan ehdoteta.
    .EXAMPLE
    Find-KBSuggestion -Text 'Jaettu laatikko ei näy Outlookissa' -KbPath ./output/kb
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$KbPath,
        [ValidateRange(1, 10)][int]$Top = 3,
        [ValidateRange(0.0, 1.0)][double]$MinScore = 0.25
    )

    $clean = Protect-TicketText -Text $Text
    $query = Get-TextToken -Text $clean

    $scored = foreach ($a in @(Get-KnowledgeBase -Path $KbPath)) {
        $articleText = (@($a.title, $a.symptoms, $a.cause, $a.category) + @($a.steps) + @($a.keywords)) -join ' '
        $s = Get-TokenSimilarity -A $query -B (Get-TextToken -Text $articleText)
        if ($s -ge $MinScore) {
            [pscustomobject]@{
                Id     = $a.id
                Title  = $a.title
                Score  = [Math]::Round($s, 2)
                Cause  = $a.cause
                Steps  = @($a.steps)
            }
        }
    }

    if (-not $scored) { return }
    @($scored) | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, Id | Select-Object -First $Top
}

Export-ModuleMember -Function Find-KBSuggestion, Get-TextToken
