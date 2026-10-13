#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module "$PSScriptRoot/../src/SharePointGraph.psm1" -Force

    # Keksitty sivusto ja lista. Kaikki HTTP-kutsut kulkevat tämän väärennöksen kautta.
    function New-FakeGraph {
        param(
            [string]$LahdetikettiType = 'text',
            [switch]$RichText,
            [string[]]$Choices,
            [object[]]$ExistingItems = @(),
            [string[]]$OmitColumns = @()
        )
        $state = @{ Calls = [System.Collections.Generic.List[object]]::new(); Created = [System.Collections.Generic.List[object]]::new() }

        $cols = @(
            @{ name = 'Title'; text = @{ allowMultipleLines = $false; maxLength = 255 } }
            @{ name = 'Oire'; text = @{ allowMultipleLines = $true; textType = 'plain' } }
            @{ name = 'Ratkaisu'; text = @{ allowMultipleLines = $true; textType = $(if ($RichText) { 'richText' } else { 'plain' }) } }
            $(if ($Choices) { @{ name = 'Kategoria'; choice = @{ choices = $Choices; allowTextEntry = $false } } }
              else { @{ name = 'Kategoria'; text = @{ allowMultipleLines = $false; maxLength = 255 } } })
            $(if ($LahdetikettiType -eq 'number') { @{ name = 'Lahdetiketti'; number = @{ decimalPlaces = 'none' } } }
              else { @{ name = 'Lahdetiketti'; text = @{ allowMultipleLines = $false; maxLength = 255 } } })
            @{ name = 'Tila'; choice = @{ choices = @('Luonnos', 'Hyväksytty', 'Hylätty'); allowTextEntry = $false } }
            @{ name = 'Hyvaksyja'; personOrGroup = @{} }
        ) | Where-Object { $OmitColumns -notcontains $_.name }

        $json = { param($o) $o | ConvertTo-Json -Depth 8 | ConvertFrom-Json }
        $existing = $ExistingItems

        $invoker = {
            param($Method, $Uri, $Body, $Headers)
            $state.Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body; Headers = $Headers })
            switch -Regex ($Uri) {
                '/sites/contoso\.sharepoint\.com:/sites/ServiceDesk$' { return (& $json @{ id = 'site-1' }) }
                '/lists\?\$select=' { return (& $json @{ value = @(@{ id = 'list-kb'; displayName = 'KB-luonnokset'; name = 'KBluonnokset' }, @{ id = 'list-t'; displayName = 'Tukipyynnöt'; name = 'Tukipyynnot' }) }) }
                '/columns$' { return (& $json @{ value = $cols }) }
                '/items\?' { return (& $json @{ value = $existing }) }
                '/items$' {
                    $state.Created.Add(($Body | ConvertFrom-Json))
                    return (& $json @{ id = "$(100 + $state.Created.Count)" })
                }
                default { throw "Odottamaton kutsu: $Method $Uri" }
            }
        }.GetNewClosure()

        [pscustomobject]@{ Connection = (Connect-SPGraph -Invoker $invoker); State = $state }
    }

    function New-Draft([hashtable]$Override = @{}) {
        $a = [ordered]@{
            id           = 'KB-1001'
            title        = 'Jaettu postilaatikko ei näy Outlookissa'
            symptoms     = 'Jaettu postilaatikko ei näy enää Outlookissa.'
            cause        = 'FullAccess-oikeus oli lisätty ryhmän kautta, jolloin automapping ei toimi.'
            steps        = @('Poista ryhmäpohjainen oikeus', 'Lisää suora FullAccess-oikeus AutoMappingilla')
            keywords     = @('Outlook')
            category     = 'Exchange Online'
            sourceTicket = 'T-1001'
            status       = 'Luonnos'
        }
        foreach ($k in $Override.Keys) { $a[$k] = $Override[$k] }
        [pscustomobject]$a
    }

    $script:SiteUrl = 'https://contoso.sharepoint.com/sites/ServiceDesk'
}

Describe 'Get-SPKBListTarget' {

    It 'löytää sivuston ja listan näkyvällä nimellä' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $t.SiteId | Should -Be 'site-1'
        $t.ListId | Should -Be 'list-kb'
    }

    It 'tunnistaa sarakkeiden tyypit' {
        $g = New-FakeGraph -LahdetikettiType number -RichText
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $t.Columns.Lahdetiketti.Kind | Should -Be 'Number'
        $t.Columns.Ratkaisu.RichText | Should -BeTrue
        $t.Columns.Tila.Kind         | Should -Be 'Choice'
    }

    It 'kertoo puuttuvat sarakkeet sisäisellä nimellä' {
        $g = New-FakeGraph -OmitColumns 'Lahdetiketti'
        { Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl } | Should -Throw '*Lahdetiketti*'
    }

    It 'antaa selvän virheen, jos listaa ei ole' {
        $g = New-FakeGraph
        { Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl -ListName 'Puuttuva' } | Should -Throw "*'Puuttuva'*"
    }
}

Describe 'ConvertTo-SPKBFields' {

    It 'käyttää sisäisiä nimiä ja asettaa tilaksi Luonnos' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $f = ConvertTo-SPKBFields -Article (New-Draft) -Target $t
        @($f.Keys) | Should -Be @('Title', 'Oire', 'Ratkaisu', 'Lahdetiketti', 'Tila', 'Kategoria')
        $f.Tila | Should -Be 'Luonnos'
    }

    It 'ei aseta hyväksyjää' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        (ConvertTo-SPKBFields -Article (New-Draft) -Target $t).Keys | Should -Not -Contain 'Hyvaksyja'
    }

    It 'kokoaa ratkaisun syystä ja numeroiduista vaiheista' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $r = (ConvertTo-SPKBFields -Article (New-Draft) -Target $t).Ratkaisu
        $r | Should -Match '^Syy: FullAccess'
        $r | Should -Match "`n1\. Poista ryhmäpohjainen oikeus`n2\. Lisää suora"
    }

    It 'kirjoittaa rich text -sarakkeeseen HTML:ää ja koodaa erikoismerkit' {
        $g = New-FakeGraph -RichText
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $r = (ConvertTo-SPKBFields -Article (New-Draft @{ steps = @('Aja Get-Mailbox <nimi> & tarkista') }) -Target $t).Ratkaisu
        $r | Should -Match '<ol><li>Aja Get-Mailbox &lt;nimi&gt; &amp; tarkista</li></ol>'
    }

    It 'kirjoittaa lähdetiketin tekstinä tekstisarakkeeseen' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        (ConvertTo-SPKBFields -Article (New-Draft) -Target $t).Lahdetiketti | Should -Be 'T-1001'
    }

    It 'kirjoittaa lähdetiketin lukuna lukusarakkeeseen' {
        $g = New-FakeGraph -LahdetikettiType number
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $v = (ConvertTo-SPKBFields -Article (New-Draft) -Target $t).Lahdetiketti
        $v | Should -Be 1001
        $v | Should -BeOfType [int]
    }

    It 'jättää kategorian pois, jos valintasarakkeessa ei ole arvoa' {
        $g = New-FakeGraph -Choices 'Intune', 'Teams'
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $f = ConvertTo-SPKBFields -Article (New-Draft) -Target $t -WarningAction SilentlyContinue
        $f.Keys | Should -Not -Contain 'Kategoria'
    }

    It 'katkaisee otsikon 255 merkkiin' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        (ConvertTo-SPKBFields -Article (New-Draft @{ title = 'x' * 300 }) -Target $t).Title.Length | Should -Be 255
    }
}

Describe 'Publish-SPKBDraft' {

    It 'luo luonnoksen listalle' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $r = New-Draft | Publish-SPKBDraft -Connection $g.Connection -Target $t
        $r.Tulos  | Should -Be 'Luotu'
        $r.ItemId | Should -Be '101'
        $g.State.Created.Count | Should -Be 1
        $g.State.Created[0].fields.Title | Should -Be 'Jaettu postilaatikko ei näy Outlookissa'
        $g.State.Created[0].fields.Tila  | Should -Be 'Luonnos'
    }

    It 'tarkistaa kaksoiskappaleen lähdetiketillä ennen kirjoitusta' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $null = New-Draft | Publish-SPKBDraft -Connection $g.Connection -Target $t
        $q = $g.State.Calls | Where-Object { $_.Uri -match '/items\?' } | Select-Object -First 1
        [uri]::UnescapeDataString($q.Uri) | Should -Match "fields/Lahdetiketti eq 'T-1001'"
        $q.Headers.Prefer | Should -Be 'HonorNonIndexedQueriesWarningMayFailRandomly'
    }

    It 'käyttää lukuvertailua lukusarakkeessa' {
        $g = New-FakeGraph -LahdetikettiType number
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $null = New-Draft | Publish-SPKBDraft -Connection $g.Connection -Target $t
        $q = $g.State.Calls | Where-Object { $_.Uri -match '/items\?' } | Select-Object -First 1
        [uri]::UnescapeDataString($q.Uri) | Should -Match 'fields/Lahdetiketti eq 1001(&|$)'
    }

    It 'ohittaa, jos samasta tiketistä on jo luonnos' {
        $g = New-FakeGraph -ExistingItems @(@{ id = '7'; fields = @{ Lahdetiketti = 'T-1001'; Tila = 'Luonnos' } })
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $r = New-Draft | Publish-SPKBDraft -Connection $g.Connection -Target $t
        $r.Tulos  | Should -Be 'Ohitettu'
        $r.ItemId | Should -Be '7'
        $g.State.Created.Count | Should -Be 0
    }

    It 'ei julkaise hyväksyttyä tai hylättyä artikkelia' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $r = New-Draft @{ status = 'Hyväksytty' } | Publish-SPKBDraft -Connection $g.Connection -Target $t
        $r.Tulos | Should -Be 'Ohitettu'
        $g.State.Created.Count | Should -Be 0
    }

    It 'pysäyttää luonnoksen, johon on lisätty henkilötietoja, eikä tee yhtään kutsua' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $before = $g.State.Calls.Count
        $r = New-Draft @{ symptoms = 'Soita numeroon 040 123 4567 tai matti.virtanen@kuusirinne.fi' } |
            Publish-SPKBDraft -Connection $g.Connection -Target $t
        $r.Tulos | Should -Be 'Esto'
        $r.Syy   | Should -Match 'Email'
        $g.State.Calls.Count | Should -Be $before
    }

    It 'pysäyttää tunnetun nimen' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $r = New-Draft @{ cause = 'Matti Virtanen lisäsi oikeuden ryhmän kautta.' } |
            Publish-SPKBDraft -Connection $g.Connection -Target $t -KnownValues 'Matti Virtanen'
        $r.Tulos | Should -Be 'Esto'
    }

    It 'ei kirjoita mitään -WhatIf-tilassa' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $r = New-Draft | Publish-SPKBDraft -Connection $g.Connection -Target $t -WhatIf
        $r.Syy | Should -Be 'WhatIf'
        $g.State.Created.Count | Should -Be 0
    }

    It 'julkaisee repon esimerkkiartikkelin ilman henkilötietolöydöksiä' {
        $g = New-FakeGraph
        $t = Get-SPKBListTarget -Connection $g.Connection -SiteUrl $script:SiteUrl
        $a = Get-Content "$PSScriptRoot/../examples/KB-1001.json" -Raw -Encoding utf8 | ConvertFrom-Json
        $a.status = 'Luonnos'
        ($a | Publish-SPKBDraft -Connection $g.Connection -Target $t).Tulos | Should -Be 'Luotu'
    }
}

Describe 'Connect-SPGraph' {

    BeforeEach {
        $script:saved = @{}
        foreach ($n in 'GRAPH_TENANT_ID', 'GRAPH_CLIENT_ID', 'GRAPH_CERT_PATH', 'GRAPH_CERT_PASSWORD', 'GRAPH_CLIENT_SECRET') {
            $script:saved[$n] = [Environment]::GetEnvironmentVariable($n)
            [Environment]::SetEnvironmentVariable($n, $null)
        }
    }
    AfterEach {
        foreach ($k in $script:saved.Keys) { [Environment]::SetEnvironmentVariable($k, $script:saved[$k]) }
    }

    It 'vaatii tenantin ja sovelluksen tunnisteen' {
        { Connect-SPGraph } | Should -Throw '*GRAPH_*'
    }

    It 'vaatii varmenteen tai salaisuuden' {
        $env:GRAPH_TENANT_ID = '00000000-0000-0000-0000-000000000001'
        $env:GRAPH_CLIENT_ID = '00000000-0000-0000-0000-000000000002'
        { Connect-SPGraph } | Should -Throw '*GRAPH_CERT_PATH*'
    }
}

Describe 'New-ClientAssertion' {

    BeforeAll {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=servicedesk-kb-test', $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $script:Cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))

        function ConvertFrom-B64Url([string]$s) {
            $s = $s.Replace('-', '+').Replace('_', '/')
            switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
            [Convert]::FromBase64String($s)
        }
        $script:FromB64Url = ${function:ConvertFrom-B64Url}
    }

    It 'tuottaa JWT:n, jonka allekirjoitus täsmää varmenteen julkiseen avaimeen' {
        $jwt = New-ClientAssertion -TenantId 'tenant-1' -ClientId 'app-1' -Certificate $script:Cert
        $parts = $jwt.Split('.')
        $parts.Count | Should -Be 3

        $pub = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($script:Cert)
        $ok = $pub.VerifyData([System.Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])"),
            (& $script:FromB64Url $parts[2]),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $ok | Should -BeTrue
    }

    It 'sisältää oikean yleisön, myöntäjän ja voimassaolon' {
        $jwt = New-ClientAssertion -TenantId 'tenant-1' -ClientId 'app-1' -Certificate $script:Cert
        $p = [System.Text.Encoding]::UTF8.GetString((& $script:FromB64Url $jwt.Split('.')[1])) | ConvertFrom-Json
        $p.aud | Should -Be 'https://login.microsoftonline.com/tenant-1/oauth2/v2.0/token'
        $p.iss | Should -Be 'app-1'
        $p.sub | Should -Be 'app-1'
        ($p.exp - $p.nbf) | Should -Be 600
    }

    It 'merkitsee otsakkeeseen varmenteen tunnisteen (x5t)' {
        $jwt = New-ClientAssertion -TenantId 'tenant-1' -ClientId 'app-1' -Certificate $script:Cert
        $h = [System.Text.Encoding]::UTF8.GetString((& $script:FromB64Url $jwt.Split('.')[0])) | ConvertFrom-Json
        $h.alg | Should -Be 'RS256'
        (& $script:FromB64Url $h.x5t) | Should -Be $script:Cert.GetCertHash()
    }
}
