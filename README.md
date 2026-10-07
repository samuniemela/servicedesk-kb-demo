# Service Desk -tietopankkidemo

Ratkaistuista tiketeistä syntyy tietopankkiartikkeleita tekoälyn avulla, ja uusi tiketti saa ratkaisuehdotuksen hyväksytyistä artikkeleista. Yksikään henkilötieto ei lähde koneelta.

> Työnäyte. Kaikki data on keksittyä. PowerShell 7 + Pester, yli 130 testiä.

## Miksi tämä?

Service Deskissä sama ongelma ratkaistaan usein moneen kertaan, koska hyvä ratkaisu jää yksittäisen tiketin muistiinpanoihin. Tietopankkiartikkelin kirjoittaminen jälkikäteen jää kiireessä tekemättä.

Tekoäly voisi kirjoittaa artikkelin valmiiksi, mutta tiketit ovat täynnä henkilötietoja: nimiä taivutettuina ("soitin Matille"), puhelinnumeroita, sähköposteja ja sarjanumeroita. Tämä demo näyttää yhden tavan tehdä se turvallisesti:

- **Automatisoi** se, minkä voi tehdä turvallisesti: anonymisointi, luonnos ja ratkaisuehdotus.
- **Pidä ihmisellä** se, mikä vaatii harkintaa: mikään ei päädy tietopankkiin ilman hyväksyntää.

## Esimerkki

```
PS> ./scripts/Show-Demo.ps1

20 tikettiä anonymisoitu, 20 artikkelia hyväksytty tietopankkiin.

Uusi tiketti: Jaettu laatikko ei näy Outlookissa
  KB-1001  0.53  Jaettu postilaatikko ei näy Outlookissa
  KB-1007  0.39  Asiakaspalvelu-postilaatikko puuttuu Outlookista
  KB-1014  0.39  Shared mailbox not visible in Outlook
  Paras osuma, ratkaisu: Poistettiin ryhmäpohjainen oikeus ja lisättiin suora FullAccess-oikeus AutoMapping-asetuksella. ...

Uusi tiketti: Kahvinkeitin rikki toimistolla
  Ei ehdotuksia – käsittelijä ratkaisee itse.
```

Suomenkielinen tiketti löytää myös englanninkielisen artikkelin (KB-1014), ja asiaan liittymätön tiketti ei saa keksittyjä ehdotuksia.

Oikean AI:n (Claude) kirjoittamia ja ihmisen tarkistamia esimerkkiartikkeleita on kansiossa [examples/](examples/). Tarkistuksessa KB-1003:sta korjattiin vaiheiden järjestys ja KB-1004:stä puuttuva SMTP-osoite ja SPF-tietue.

## Työnkulku

1. **Anonymisointi** – nimet (myös taivutetut muodot), sähköpostit, puhelinnumerot, IP-osoitteet, sarjanumerot ja organisaatiot korvataan merkinnöillä.
2. **Tarkistusportti** – jos henkilötietoja jää, mitään ei tallenneta eikä lähetetä eteenpäin.
3. **Artikkeliluonnos** – AI kirjoittaa anonymisoidusta tiketistä ohjeen. AI-mallille lähtee vain tarkistusportin läpäissyt teksti ilman työlokia, ja myös vastaus tarkistetaan.
4. **Hyväksyntä** – luonnos päätyy tietopankkiin vasta, kun ihminen hyväksyy sen.
5. **Ratkaisuehdotus** – uutta tikettiä verrataan hyväksyttyihin artikkeleihin paikallisesti. Vertailu ymmärtää suomen taivutusmuodot ja astevaihtelun sekä suomen- ja englanninkieliset termit ("postilaatikko" ↔ "mailbox").

AI-taustajärjestelmä on vaihdettava: testitila toimii ilman verkkoyhteyttä ja API-avainta, Claude API ottaa avaimen ympäristömuuttujasta `ANTHROPIC_API_KEY`.

## Käyttö

Avaa repo GitHub Codespacesissa (Code → Codespaces) – PowerShell ja Pester asentuvat automaattisesti. Kirjoita terminaaliin `pwsh` ja sitten:

```powershell
./scripts/Show-Demo.ps1
Invoke-Pester ./tests -Output Detailed
```

Vaiheittain:

```powershell
./scripts/Invoke-Anonymization.ps1
./scripts/New-KBDrafts.ps1

Import-Module ./src/KnowledgeBase.psm1
Get-KBArticle -Path ./output/kb -Status Luonnos | Format-Table id, title
Set-KBArticleStatus -Path ./output/kb -Id KB-1001 -Status Hyväksytty -Reviewer Samu
Get-KnowledgeBase -Path ./output/kb

Import-Module ./src/Suggestion.psm1
Find-KBSuggestion -Text 'Jaettu laatikko ei näy Outlookissa' -KbPath ./output/kb
```

## Rakenne

| Tiedosto | Tehtävä |
| --- | --- |
| `src/ServiceDeskKB.psm1` | Anonymisointi ja henkilötietojen tarkistus |
| `src/KnowledgeBase.psm1` | AI-taustajärjestelmät, luonnokset, hyväksyntä |
| `src/Suggestion.psm1` | Ratkaisuehdotukset |
| `data/tickets.json` | 20 keksittyä tikettiä, joissa tahallisia henkilötietoja |
| `tests/` | Pester-testit |

## Rajoitukset

- Nimet tunnistetaan tiketin pyytäjä- ja yhteyshenkilökentistä. Vapaassa tekstissä mainittu ulkopuolinen henkilö, jota kentissä ei ole, ei tunnistu automaattisesti. Siksi artikkelit hyväksyy aina ihminen.
- Ratkaisuehdotus perustuu sanastoon, ei semanttiseen hakuun. Laajempaan käyttöön sen voisi korvata upotusvektoreilla (embeddings).
- Demoa ei ole tarkoitettu oikealle asiakasdatalle sellaisenaan.
