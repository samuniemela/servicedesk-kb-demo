#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module "$PSScriptRoot/../src/ServiceDeskKB.psm1" -Force
    Import-Module "$PSScriptRoot/../src/KnowledgeBase.psm1" -Force

    $raw = Get-Content "$PSScriptRoot/../data/tickets.json" -Raw -Encoding utf8 | ConvertFrom-Json
    $script:Raw        = @($raw)
    $script:Anonymized = @($raw | ConvertTo-AnonymizedTicket)
    $script:Mock       = New-MockAIProvider

    function New-FixedProvider([string]$Response) {
        $calls = @{ Count = 0; Prompt = $null }
        $sb = { param($Prompt, $Ticket) $calls.Count++; $calls.Prompt = $Prompt; $Response }.GetNewClosure()
        [pscustomobject]@{ Provider = (New-CustomAIProvider -Name 'Testi' -ScriptBlock $sb); Calls = $calls }
    }

    $script:ValidJson = '{"title":"Otsikko","symptoms":"Oire","cause":"Syy","steps":["Vaihe 1","Vaihe 2"],"keywords":["Exchange"]}'
}

Describe 'New-KBArticleDraft' {

    Context 'Testitila' {

        It 'luo luonnoksen jokaisesta anonymisoidusta tiketistä' {
            $drafts = @($script:Anonymized | New-KBArticleDraft -Provider $script:Mock)
            $drafts.Count | Should -Be $script:Anonymized.Count
        }

        It 'merkitsee luonnoksen tilaan Luonnos eikä hyväksyjää ole' {
            $d = $script:Anonymized[0] | New-KBArticleDraft -Provider $script:Mock
            $d.status     | Should -Be 'Luonnos'
            $d.reviewedBy | Should -BeNullOrEmpty
        }

        It 'säilyttää lähdetiketin ja kategorian' {
            $d = $script:Anonymized[2] | New-KBArticleDraft -Provider $script:Mock
            $d.sourceTicket | Should -Be 'T-1003'
            $d.id           | Should -Be 'KB-1003'
            $d.category     | Should -Be 'Intune / Autopilot'
        }

        It 'ei jätä anonymisointimerkintöjä artikkeliin' {
            foreach ($t in $script:Anonymized) {
                $d = $t | New-KBArticleDraft -Provider $script:Mock
                $text = (@($d.title, $d.symptoms, $d.cause) + @($d.steps)) -join "`n"
                $text | Should -Not -Match '\[(HENKILÖ-\d+|ORGANISAATIO|SÄHKÖPOSTI|PUHELIN)\]'
            }
        }
    }

    Context 'Tarkistusportti' {

        It 'pysäyttää anonymisoimattoman tiketin eikä kutsu AI-mallia' {
            $p = New-FixedProvider $script:ValidJson
            { $script:Raw[0] | New-KBArticleDraft -Provider $p.Provider } | Should -Throw '*henkilötietoja*'
            $p.Calls.Count | Should -Be 0
        }

        It 'pysäyttää tiketin, jossa on tunnettu nimi' {
            $p = New-FixedProvider $script:ValidJson
            $t = $script:Anonymized[0].PSObject.Copy()
            $t.description = 'Soitin Matille aamulla.'
            { $t | New-KBArticleDraft -Provider $p.Provider -KnownValues 'Matille' } | Should -Throw
            $p.Calls.Count | Should -Be 0
        }

        It 'lähettää AI-mallille vain tarvittavat kentät (ei työlokia)' {
            $p = New-FixedProvider $script:ValidJson
            $t = $script:Anonymized[0].PSObject.Copy()
            $t.worklog = 'SISÄINEN-LOKI-MERKINTÄ'
            $null = $t | New-KBArticleDraft -Provider $p.Provider
            $p.Calls.Count  | Should -Be 1
            $p.Calls.Prompt | Should -Not -Match 'SISÄINEN-LOKI-MERKINTÄ'
            $p.Calls.Prompt | Should -Match 'T-1001'
        }
    }

    Context 'AI-vastauksen validointi' {

        It 'hylkää vastauksen, joka ei ole JSONia' {
            $p = New-FixedProvider 'Tässä artikkeli: ...'
            { $script:Anonymized[0] | New-KBArticleDraft -Provider $p.Provider } | Should -Throw '*JSON*'
        }

        It 'hylkää vastauksen, josta puuttuu ratkaisuvaiheet' {
            $p = New-FixedProvider '{"title":"A","symptoms":"B","cause":"C"}'
            { $script:Anonymized[0] | New-KBArticleDraft -Provider $p.Provider } | Should -Throw "*steps*"
        }

        It 'hylkää vastauksen, johon AI on lisännyt henkilötietoja' {
            $p = New-FixedProvider '{"title":"A","symptoms":"Ota yhteys matti@example.fi","cause":"C","steps":["D"]}'
            { $script:Anonymized[0] | New-KBArticleDraft -Provider $p.Provider } | Should -Throw '*henkilötietoja*'
        }

        It 'hyväksyy JSONin koodilohkon sisällä' {
            $p = New-FixedProvider ("``````json`n" + $script:ValidJson + "`n``````")
            $d = $script:Anonymized[0] | New-KBArticleDraft -Provider $p.Provider
            $d.title | Should -Be 'Otsikko'
            $d.steps.Count | Should -Be 2
        }
    }
}

Describe 'Hyväksyntä ja tietopankki' {

    BeforeEach {
        $script:KbPath = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Anonymized[0..2] | New-KBArticleDraft -Provider $script:Mock | Save-KBArticle -Path $script:KbPath | Out-Null
    }

    It 'ei päästä luonnoksia tietopankkiin' {
        @(Get-KBArticle -Path $script:KbPath).Count | Should -Be 3
        @(Get-KnowledgeBase -Path $script:KbPath).Count | Should -Be 0
    }

    It 'hyväksytty artikkeli päätyy tietopankkiin hyväksyjän tiedoilla' {
        $a = Set-KBArticleStatus -Path $script:KbPath -Id 'KB-1001' -Status 'Hyväksytty' -Reviewer 'Tukihenkilö'
        $a.reviewedBy | Should -Be 'Tukihenkilö'
        $a.reviewedAt | Should -Not -BeNullOrEmpty
        $kb = @(Get-KnowledgeBase -Path $script:KbPath)
        $kb.Count | Should -Be 1
        $kb[0].id | Should -Be 'KB-1001'
    }

    It 'hylätty artikkeli ei päädy tietopankkiin' {
        $null = Set-KBArticleStatus -Path $script:KbPath -Id 'KB-1002' -Status 'Hylätty' -Reviewer 'Tukihenkilö'
        @(Get-KnowledgeBase -Path $script:KbPath).Count | Should -Be 0
        @(Get-KBArticle -Path $script:KbPath -Status 'Hylätty').Count | Should -Be 1
    }

    It 'ei salli jo käsitellyn artikkelin uudelleenkäsittelyä' {
        $null = Set-KBArticleStatus -Path $script:KbPath -Id 'KB-1001' -Status 'Hylätty' -Reviewer 'A'
        { Set-KBArticleStatus -Path $script:KbPath -Id 'KB-1001' -Status 'Hyväksytty' -Reviewer 'B' } | Should -Throw '*käsitelty*'
    }

    It 'antaa virheen tuntemattomasta artikkelista' {
        { Set-KBArticleStatus -Path $script:KbPath -Id 'KB-9999' -Status 'Hyväksytty' -Reviewer 'A' } | Should -Throw '*ei löydy*'
    }
}

Describe 'New-ClaudeAIProvider' {

    It 'vaatii API-avaimen' {
        { New-ClaudeAIProvider -ApiKey '' } | Should -Throw '*ANTHROPIC_API_KEY*'
    }
}
