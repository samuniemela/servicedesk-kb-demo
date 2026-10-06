\xef\xbb\xbf#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeDiscovery {
    $tickets = Get-Content "$PSScriptRoot/../data/tickets.json" -Raw -Encoding utf8 | ConvertFrom-Json
    $script:TicketCases = $tickets | ForEach-Object {
        @{
            Id    = $_.id
            Names = @($_.requester.name) + @($_.contacts | ForEach-Object { $_.name })
        }
    }
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/ServiceDeskKB.psm1" -Force

    $raw = Get-Content "$PSScriptRoot/../data/tickets.json" -Raw -Encoding utf8 | ConvertFrom-Json
    $script:Original   = @{}
    $script:Anonymized = @{}
    foreach ($t in $raw) {
        $script:Original[$t.id]   = $t
        $a = $t | ConvertTo-AnonymizedTicket
        $script:Anonymized[$t.id] = $a
    }

    function Get-AllText($ticket) {
        (@($ticket.title, $ticket.description, $ticket.resolution, $ticket.worklog) | Where-Object { $_ }) -join "`n"
    }

    $script:WordBoundary = { param($word) "(?<![\p{L}\p{N}])$([regex]::Escape($word))(?![\p{L}\p{N}])" }
}

Describe 'ConvertTo-AnonymizedTicket' {

    Context 'Tiketti <Id>' -ForEach $TicketCases {

        It 'ei sisällä sähköposti-, puhelin- tai IP-tietoja' {
            $text = Get-AllText $script:Anonymized[$Id]
            Find-PersonalData -Text $text | Should -BeNullOrEmpty
        }

        It 'ei sisällä pyytäjän tai yhteyshenkilöiden nimiä' {
            $text = Get-AllText $script:Anonymized[$Id]
            foreach ($part in ($Names -split '\s+' | Where-Object { $_.Length -ge 3 })) {
                $text | Should -Not -Match (& $script:WordBoundary $part) -Because "nimi '$part' ei saa jäädä tekstiin"
            }
        }

        It 'säilyttää tiketin tunnisteen ja kategorian' {
            $script:Anonymized[$Id].id       | Should -Be $script:Original[$Id].id
            $script:Anonymized[$Id].category | Should -Be $script:Original[$Id].category
        }
    }

    Context 'Taivutetut nimet ja organisaatiot' {

        It 'poistaa taivutetun muodon <_>' -ForEach @(
            'Matille', 'Matin', 'Sarille', 'Sarin', 'Pekan', 'Annen', 'Annelle', 'Juhalle', 'Juhan',
            'Villen', 'Mikolle', 'Emilian', 'Lauran', 'Karille', 'Virtasen', 'Koskisen', 'Niemisen',
            'Korhoselle', 'Lehtoselle', 'Anderssonille'
        ) {
            $all = ($script:Anonymized.Values | ForEach-Object { Get-AllText $_ }) -join "`n"
            $all | Should -Not -Match (& $script:WordBoundary $_)
        }

        It 'poistaa organisaation nimen <_>' -ForEach @('Kuusirinne', 'Merivaara', 'Pohjolan Tilitoimisto') {
            $all = ($script:Anonymized.Values | ForEach-Object { Get-AllText $_ }) -join "`n"
            $all | Should -Not -Match (& $script:WordBoundary $_)
        }

        It 'poistaa sarjanumerot ja IP-osoitteet' {
            $all = ($script:Anonymized.Values | ForEach-Object { Get-AllText $_ }) -join "`n"
            foreach ($v in '5CG3341XYZ', 'PF3KQ2LM', '5CG2219ABC', '85.76.120.44', '10.20.4.15') {
                $all | Should -Not -Match ([regex]::Escape($v))
            }
        }
    }

    Context 'Tekninen sisältö säilyy' {

        It 'säilyttää virhekoodin 0x80180014' {
            $script:Anonymized['T-1003'].description | Should -Match '0x80180014'
            $script:Anonymized['T-1012'].description | Should -Match '0x80180014'
        }

        It 'säilyttää teknisen ratkaisun sanaston' {
            $script:Anonymized['T-1001'].resolution | Should -Match 'AutoMapping'
            $script:Anonymized['T-1011'].resolution | Should -Match 'aka\.ms/sspr'
            $script:Anonymized['T-1009'].resolution | Should -Match 'Temporary Access Pass'
        }
    }

    Context 'Johdonmukaiset merkinnät' {

        It 'antaa pyytäjälle ja yhteyshenkilölle eri merkinnät' {
            $d = $script:Anonymized['T-1003'].description
            $d | Should -Match '\[HENKILÖ-1\]'
            $d | Should -Match '\[HENKILÖ-2\]'
        }

        It 'käyttää samaa merkintää saman henkilön taivutetuille muodoille' {
            # T-1013: "Emilia Lehtonen" ja "Emilian" ovat sama henkilö.
            $d = $script:Anonymized['T-1013'].description
            ([regex]::Matches($d, '\[HENKILÖ-2\]')).Count | Should -Be 2
        }
    }
}

Describe 'Find-PersonalData' {

    It 'löytää henkilötiedot alkuperäisestä tekstistä' {
        $findings = Find-PersonalData -Text $script:Original['T-1001'].description
        $findings.Type | Should -Contain 'Email'
        $findings.Type | Should -Contain 'Phone'
    }

    It 'löytää tunnetun nimen' {
        $findings = Find-PersonalData -Text 'Soitin Matti Virtaselle.' -KnownValues 'Matti'
        $findings.Type | Should -Contain 'KnownValue'
    }

    It 'ei tulkitse virhekoodia puhelinnumeroksi' {
        Find-PersonalData -Text 'Virhe 0x80180014 ja #818' | Should -BeNullOrEmpty
    }
}
