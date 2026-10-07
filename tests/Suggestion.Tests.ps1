#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module "$PSScriptRoot/../src/ServiceDeskKB.psm1" -Force
    Import-Module "$PSScriptRoot/../src/KnowledgeBase.psm1" -Force
    Import-Module "$PSScriptRoot/../src/Suggestion.psm1" -Force

    $tickets = Get-Content "$PSScriptRoot/../data/tickets.json" -Raw -Encoding utf8 | ConvertFrom-Json
    $mock = New-MockAIProvider

    # Tietopankki, jossa kaikki artikkelit on hyväksytty.
    $script:KbPath = Join-Path $TestDrive 'kb'
    $tickets | ConvertTo-AnonymizedTicket | New-KBArticleDraft -Provider $mock | Save-KBArticle -Path $script:KbPath | Out-Null
    Get-KBArticle -Path $script:KbPath | ForEach-Object {
        $null = Set-KBArticleStatus -Path $script:KbPath -Id $_.id -Status 'Hyväksytty' -Reviewer 'Testi'
    }

    # Tietopankki, jossa on pelkkiä luonnoksia.
    $script:DraftPath = Join-Path $TestDrive 'drafts'
    $tickets | ConvertTo-AnonymizedTicket | New-KBArticleDraft -Provider $mock | Save-KBArticle -Path $script:DraftPath | Out-Null
}

Describe 'Get-TextToken' {

    It 'yhdistää suomen- ja englanninkielisen termin samaan käsitteeseen' {
        (Get-TextToken 'postilaatikkoon').Keys | Should -Contain '#mailbox'
        (Get-TextToken 'shared mailbox').Keys  | Should -Contain '#mailbox'
    }

    It 'tunnistaa taivutetun muodon (<_>)' -ForEach @('tallenne', 'tallennetta', 'nauhoite', 'recording') {
        (Get-TextToken $_).Keys | Should -Contain '#recording'
    }

    It 'ohittaa täytesanat' {
        (Get-TextToken 'ei ja on se').Count | Should -Be 0
    }
}

Describe 'Find-KBSuggestion' {

    It 'löytää oikeat artikkelit: <Query>' -ForEach @(
        @{ Query = 'Jaettu laatikko ei näy Outlookissa';                       Expected = 'KB-1001', 'KB-1007', 'KB-1014' }
        @{ Query = 'Shared mailbox missing from Outlook';                      Expected = 'KB-1001', 'KB-1007', 'KB-1014' }
        @{ Query = 'Puhelin vaihtui, en saa MFA-vahvistusta';                  Expected = 'KB-1002', 'KB-1009', 'KB-1016' }
        @{ Query = 'Läppäri pyytää BitLocker-avainta käynnistyksessä';         Expected = 'KB-1006', 'KB-1019' }
        @{ Query = 'Tulostin ei lähetä skannattua dokumenttia sähköpostiin';  Expected = 'KB-1004', 'KB-1018' }
        @{ Query = 'Teams-palaverin tallenne ei löydy';                        Expected = 'KB-1005', 'KB-1015' }
        @{ Query = 'Asiakas ei pääse jaettuihin tiedostoihin';                 Expected = 'KB-1010', 'KB-1020' }
    ) {
        $result = @(Find-KBSuggestion -Text $Query -KbPath $script:KbPath)
        $result.Count | Should -BeGreaterThan 0
        $result[0].Id | Should -BeIn $Expected
        foreach ($id in $Expected | Select-Object -First 2) {
            $result.Id | Should -Contain $id
        }
    }

    It 'ei ehdota mitään asiaan liittymättömälle tiketille' {
        Find-KBSuggestion -Text 'Kahvinkeitin rikki toimistolla' -KbPath $script:KbPath | Should -BeNullOrEmpty
    }

    It 'ei koskaan ehdota luonnoksia' {
        Find-KBSuggestion -Text 'Jaettu laatikko ei näy Outlookissa' -KbPath $script:DraftPath | Should -BeNullOrEmpty
    }

    It 'palauttaa enintään <Top> ehdotusta' -ForEach @(@{ Top = 1 }, @{ Top = 2 }) {
        @(Find-KBSuggestion -Text 'Shared mailbox missing from Outlook' -KbPath $script:KbPath -Top $Top).Count |
            Should -BeLessOrEqual $Top
    }

    It 'järjestää ehdotukset pisteiden mukaan' {
        $scores = @(Find-KBSuggestion -Text 'Jaettu laatikko ei näy Outlookissa' -KbPath $script:KbPath).Score
        $scores | Should -Be ($scores | Sort-Object -Descending)
    }

    It 'toimii, vaikka tiketissä on yhteystietoja' {
        $r = @(Find-KBSuggestion -Text 'Jaettu laatikko ei näy, soita 040 123 4567 tai matti@example.fi' -KbPath $script:KbPath)
        $r.Count | Should -BeGreaterThan 0
    }
}
