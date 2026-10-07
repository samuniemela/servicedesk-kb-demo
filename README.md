# Service Desk -tietopankkidemo

Ratkaistuista tiketeistä syntyy tietopankkiartikkeleita tekoälyn avulla, eikä yksikään henkilötieto lähde koneelta.

> Työnäyte. Kaikki data on keksittyä.

## Työnkulku

1. **Anonymisointi** – nimet (myös taivutetut muodot), sähköpostit, puhelinnumerot, IP-osoitteet, sarjanumerot ja organisaatiot korvataan merkinnöillä. *(valmis)*
2. **Tarkistusportti** – jos henkilötietoja jää, mitään ei tallenneta eikä lähetetä eteenpäin. *(valmis)*
3. **Artikkeliluonnos** – AI kirjoittaa anonymisoidusta tiketistä ohjeen. AI-mallille lähtee vain tarkistusportin läpäissyt teksti ilman työlokia, ja myös vastaus tarkistetaan. *(valmis)*
4. **Hyväksyntä** – luonnos päätyy tietopankkiin vasta, kun ihminen hyväksyy sen. *(valmis)*
5. **Ratkaisuehdotus** – uutta tikettiä verrataan hyväksyttyihin artikkeleihin, ja käsittelijä saa 1–3 parasta osumaa pisteineen. Vertailu tehdään paikallisesti ja se ymmärtää suomen taivutusmuodot sekä suomen- ja englanninkieliset termit ("postilaatikko" ↔ "mailbox"). *(valmis)*

AI-taustajärjestelmä on vaihdettava: testitila toimii ilman verkkoyhteyttä ja API-avainta, Claude API ottaa avaimen ympäristömuuttujasta `ANTHROPIC_API_KEY`.

## Käyttö

Avaa repo GitHub Codespacesissa – PowerShell ja Pester asentuvat automaattisesti.

Nopein tapa nähdä koko idea:

```powershell
./scripts/Show-Demo.ps1
```

Vaiheittain:

```powershell
Invoke-Pester ./tests -Output Detailed
./scripts/Invoke-Anonymization.ps1
./scripts/New-KBDrafts.ps1

Import-Module ./src/KnowledgeBase.psm1
Get-KBArticle -Path ./output/kb -Status Luonnos | Format-Table id, title
Set-KBArticleStatus -Path ./output/kb -Id KB-1001 -Status Hyväksytty -Reviewer Samu
Get-KnowledgeBase -Path ./output/kb

Import-Module ./src/Suggestion.psm1
Find-KBSuggestion -Text 'Jaettu laatikko ei näy Outlookissa' -KbPath ./output/kb
```

## Rajoitukset

Nimet tunnistetaan tiketin pyytäjä- ja yhteyshenkilökentistä. Vapaassa tekstissä mainittu ulkopuolinen henkilö, jota kentissä ei ole, ei tunnistu automaattisesti. Siksi artikkelit hyväksyy aina ihminen ennen julkaisua, eikä demoa ole tarkoitettu oikealle asiakasdatalle sellaisenaan.
