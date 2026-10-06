# Service Desk -tietopankkidemo

Ratkaistuista tiketeistä syntyy tietopankkiartikkeleita tekoälyn avulla, eikä yksikään henkilötieto lähde koneelta.

> Työnäyte. Kaikki data on keksittyä.

## Työnkulku

1. **Anonymisointi** – nimet (myös taivutetut muodot), sähköpostit, puhelinnumerot, IP-osoitteet, sarjanumerot ja organisaatiot korvataan merkinnöillä. *(valmis)*
2. **Tarkistusportti** – jos henkilötietoja jää, mitään ei tallenneta eikä lähetetä eteenpäin. *(valmis)*
3. **Artikkeliluonnos** – AI kirjoittaa anonymisoidusta tiketistä ohjeen; ihminen hyväksyy. *(tulossa)*
4. **Ratkaisuehdotus** – uutta tikettiä verrataan hyväksyttyihin artikkeleihin. *(tulossa)*

## Käyttö

Vaatii PowerShell 7:n ja Pester 5:n.

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed
./scripts/Invoke-Anonymization.ps1
```

## Rajoitukset

Nimet tunnistetaan tiketin pyytäjä- ja yhteyshenkilökentistä. Vapaassa tekstissä mainittu ulkopuolinen henkilö, jota kentissä ei ole, ei tunnistu automaattisesti. Siksi artikkelit hyväksyy aina ihminen ennen julkaisua.
