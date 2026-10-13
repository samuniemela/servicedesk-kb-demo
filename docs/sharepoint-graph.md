# PowerShell → SharePoint: luonnokset KB-luonnokset-listaan Microsoft Graphin kautta

PowerShell-demo tuottaa anonymisoidun ja Clauden kirjoittaman luonnoksen. Tämä osa vie luonnoksen SharePointin **KB-luonnokset**-listaan, jossa Power Automate -flow lähettää sen hyväksyjälle. Hyväksyntä tapahtuu siis Microsoft 365:ssä, ei skriptissä.

```
tickets.json → anonymisointi → tarkistusportti → Claude API → luonnos (output/kb)
                                                                 │
                                         Publish-KBDrafts.ps1 ───┘  Microsoft Graph, Sites.Selected
                                                                 ▼
                                          SharePoint: KB-luonnokset (Tila = Luonnos)
                                                                 │  flow: When an item is created
                                                                 ▼
                                          Hyväksyntäpyyntö → Tila = Hyväksytty / Hylätty
```

## Oikeudet: Sites.Selected

Sovellus saa kirjoittaa vain yhdelle sivustolle. Microsoft Graphin sovellusoikeus `Sites.Selected` ei yksinään anna pääsyä mihinkään; ylläpitäjä myöntää pääsyn sivustokohtaisesti. Vertailuksi `Sites.ReadWrite.All` antaisi kirjoitusoikeuden tenantin kaikille sivustoille.

| Vaihe | Kuka | Mitä |
| --- | --- | --- |
| 1. App registration | Ylläpitäjä | Entra ID → App registrations → New registration, nimi esim. *ServiceDesk KB Publisher*, single tenant, ei redirect URI:a. |
| 2. API-oikeus | Ylläpitäjä | API permissions → Microsoft Graph → **Application permissions** → `Sites.Selected` → Grant admin consent. |
| 3. Tunnus | Ylläpitäjä | Certificates & secrets → lataa varmenteen julkinen osa (suositeltu) tai luo client secret. |
| 4. Sivustokohtainen pääsy | Ylläpitäjä | `./scripts/Grant-SiteAccess.ps1` antaa sovellukselle roolin `write` ServiceDesk-sivustolle. |

### Varmenne (suositeltu)

Varmenteella kirjautuessa tokenpalvelulle lähtee vain allekirjoitettu JWT, ei salaisuutta. Varmenne luodaan Codespacesissa, ja yksityinen avain jää sinne:

```bash
mkdir -p ~/.certs && cd ~/.certs
openssl req -x509 -newkey rsa:2048 -sha256 -days 180 -nodes \
  -keyout kb-publisher.key -out kb-publisher.cer -subj "/CN=ServiceDesk KB Publisher"
openssl pkcs12 -export -inkey kb-publisher.key -in kb-publisher.cer -out kb-publisher.pfx
```

Entra ID:hen ladataan vain `kb-publisher.cer`. Avaintiedostot ovat kotihakemistossa repon ulkopuolella, ja `.gitignore` estää varmuuden vuoksi `.pfx`-, `.key`- ja `.pem`-tiedostot.

### Sivustokohtainen pääsy

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
./scripts/Grant-SiteAccess.ps1 -SiteUrl https://<tenant>.sharepoint.com/sites/ServiceDesk -ClientId <sovelluksen client id>
```

Skripti kirjautuu ylläpitäjän tunnuksilla laitekoodilla (delegoitu `Sites.FullControl.All`), tarkistaa, onko oikeus jo olemassa, ja luo sen tarvittaessa. Ylläpitäjän oikeutta tarvitaan vain tähän kertaan; julkaisuskripti käyttää sovelluksen omaa, rajattua oikeutta.

## Ajo

Tunnukset ympäristömuuttujiin. Codespacesissa ne voi tallentaa Codespaces-salaisuuksiksi (GitHub → Settings → Codespaces → Secrets), jolloin ne eivät päädy tiedostoihin eikä komentohistoriaan.

| Muuttuja | Arvo |
| --- | --- |
| `GRAPH_TENANT_ID` | Tenantin ID |
| `GRAPH_CLIENT_ID` | Sovelluksen (client) ID |
| `GRAPH_CERT_PATH` | Polku `.pfx`-tiedostoon, esim. `~/.certs/kb-publisher.pfx` |
| `GRAPH_CERT_PASSWORD` | `.pfx`-tiedoston salasana, jos sellainen annettiin |
| `GRAPH_CLIENT_SECRET` | Vaihtoehto varmenteelle |
| `SP_SITE_URL` | `https://<tenant>.sharepoint.com/sites/ServiceDesk` |

```powershell
./scripts/Invoke-Anonymization.ps1
./scripts/New-KBDrafts.ps1 -Provider Claude      # vaatii ANTHROPIC_API_KEY
./scripts/Publish-KBDrafts.ps1 -Id KB-1001 -WhatIf
./scripts/Publish-KBDrafts.ps1 -Id KB-1001
```

Esimerkkituloste:

```
Kohde: KB-luonnokset (https://<tenant>.sharepoint.com/sites/ServiceDesk), kirjautuminen: Varmenne

Id      Tulos  ItemId Syy
--      -----  ------ ---
KB-1001 Luotu  12

Luotu 1 / 1. Hyväksyntäpyyntö lähtee flow'sta 1–5 minuutin kuluessa.
```

Toinen ajo samalla luonnoksella antaa tuloksen *Ohitettu*, koska lähdetiketistä on jo luonnos listalla.

## Mitä skripti tekee

1. Lukee paikallisesta kansiosta vain tilassa *Luonnos* olevat artikkelit.
2. Ajaa henkilötietotarkistuksen uudelleen juuri ennen lähetystä. Luonnosta on voitu muokata käsin anonymisoinnin jälkeen. Jos löydöksiä on, mitään ei lähetetä (tulos *Esto*).
3. Lukee listan sarakkeet Graphista ja muotoilee kentät niiden mukaan:
   - *Ratkaisu* = syy ja numeroidut vaiheet. Rich text -sarakkeeseen HTML, tavalliseen tekstinä.
   - *Lahdetiketti* kirjoitetaan lukuna (1001), jos sarake on lukutyyppinen, muuten tekstinä (T-1001).
   - *Kategoria* jätetään tyhjäksi varoituksen kanssa, jos sarake on valintasarake eikä arvoa ole valinnoissa.
   - *Tila* = Luonnos. *Hyvaksyja* jää tyhjäksi; sen asettaa flow.
4. Tarkistaa kaksoiskappaleet suodattimella `fields/Lahdetiketti eq ...`. Sarake ei ole indeksoitu, joten pyyntöön lisätään otsake `Prefer: HonorNonIndexedQueriesWarningMayFailRandomly`. Pienellä listalla tämä riittää; yli 5 000 kohteen listalla sarake kannattaa indeksoida.
5. Luo kohteen: `POST /sites/{site-id}/lists/{list-id}/items`.

Graph-kutsut on eristetty niin, että testit (`tests/SharePointGraph.Tests.ps1`) ajavat koko julkaisun väärennettyä Graphia vasten ilman verkkoa ja tunnuksia. Testit tarkistavat myös, että varmenteella allekirjoitettu JWT täsmää julkiseen avaimeen.

## Rajoitukset

- Lähdetiketit tulevat demon `data/tickets.json`-tiedostosta (T-1001 …), eivät Tukipyynnöt-listalta. Jos *Lahdetiketti* on lukusarake, arvo 1001 ei siis viittaa Tukipyynnöt-listan kohteeseen.
- Tokenia ei tallenneta. Jokainen ajo hakee uuden (voimassa noin tunnin).
- Hyväksytyt artikkelit eivät palaa automaattisesti paikalliseen tietopankkiin, jota ratkaisuehdotukset käyttävät.
