# Power Automate -versio: ratkaistusta tiketistä hyväksyttyyn ohjeeseen

Sama periaate kuin PowerShell-demossa, toteutettuna Microsoft 365:n vakiotyökaluilla: ratkaistusta tiketistä syntyy tietopankkiluonnos, ja se päätyy tietopankkiin vasta, kun ihminen hyväksyy sen.

> Rakennettu omaan Microsoft 365 -testiympäristöön. Kaikki data on keksittyä. Vain vakioliittimet (SharePoint, Approvals), ei premium-lisenssejä.

## Työnkulku

1. **Tukipyynnöt**-listan tiketin tilaksi vaihdetaan *Ratkaistu*.
2. Flow tarkistaa, onko tiketistä jo luonnos (suodatus lähdetiketin numerolla). Jos on, mitään ei tehdä.
3. **KB-luonnokset**-listaan luodaan luonnos: otsikko, oire, ratkaisu, kategoria ja lähdetiketti.
4. Hyväksyjälle lähtee hyväksyntäpyyntö (sähköposti / Teams / Power Automate), jossa on linkki luonnokseen.
5. Päätöksen mukaan luonnoksen tila päivittyy *Hyväksytty* tai *Hylätty*, ja hyväksyjä tallentuu luonnokseen.

![Hyväksyntäpyyntö hyväksyjän näkymässä](01-hyvaksyntapyynto.png)

![KB-luonnokset-lista: kaksi luonnosta odottaa, yksi hyväksytty ja yksi hylätty](02-kb-luonnokset.png)

![Hyväksytty luonnos ja hyväksyjä](03-luonnos-hyvaksytty.png)

![Flow'n rakenne](05-flow.png)

![Onnistunut ajo: luonnos hyväksyttiin ja tila päivittyi, hylkäyshaara ohitettiin](04-ajo-onnistui.png)

## Rakenne

| Osa | Toteutus |
| --- | --- |
| Tukipyynnöt | SharePoint-lista: otsikko, kuvaus, ratkaisu, kategoria, tila (Avoin / Työn alla / Ratkaistu) |
| KB-luonnokset | SharePoint-lista: otsikko, oire, ratkaisu, kategoria, lähdetiketti, tila (Luonnos / Hyväksytty / Hylätty), hyväksyjä |
| Flow 1 | When an item is created or modified → Condition → Get items → Condition → Create item → Start and wait for an approval → Condition → Update item |
| Flow 2 | When an item is created (KB-luonnokset) → Start and wait for an approval → Condition → Update item |

## Huomioita toteutuksesta

- **Kaksoiskappaleiden esto.** Trigger laukeaa jokaisesta muokkauksesta. Ilman tarkistusta jo ratkaistun tiketin muokkaus loisi uuden luonnoksen. Flow hakee luonnokset suodattimella `Lahdetiketti eq <tiketin ID>` ja jatkaa vain, jos tuloksia on nolla.
- **Sarakkeiden sisäiset nimet ilman ääkkösiä.** SharePoint muodostaa sisäisen nimen luontihetkellä, ja ä muuttuu muotoon `_x00e4_`. Sarakkeet luotiin nimillä *Lahdetiketti* ja *Hyvaksyja*, ja näkyvä nimi vaihdettiin jälkikäteen. Suodattimet ja lausekkeet pysyvät luettavina.
- **Viittaukset lausekkeina.** Luonnoksen tunniste, otsikko ja hyväksyjän sähköposti annetaan lausekkeina (esim. `outputs('Create_item')?['body/ID']`). Kun kenttä valitaan Get items -vaiheen dynaamisesta sisällöstä, editori lisää automaattisesti For each -silmukan, eikä luonnosta luoda lainkaan, kun aiempia luonnoksia ei ole.
- **Luku vs. teksti vertailussa.** Ehto `length(...) = 0` toimii vain, kun myös `0` annetaan lausekkeena. Tekstinä annettu "0" ei ole sama kuin luku 0.

## Rajoitukset

- Ensimmäisessä flow'ssa ei ole AI-vaihetta: tekoälyn käyttö Power Automatessa vaatisi premium-liittimen tai AI Builder -krediittejä. AI-luonnokset tuodaan listalle PowerShellistä (ks. alla), jolloin Power Automatessa riittävät vakioliittimet.
- SharePoint-trigger tarkistaa muutokset ajoittain, joten flow käynnistyy 1–5 minuutin viiveellä.
- Hyväksyntä odottaa enintään 30 päivää, minkä jälkeen ajo päättyy aikakatkaisuun.

## Versio 2: AI-luonnos PowerShellistä, hyväksyntä Power Automatessa

PowerShell kirjoittaa anonymisoidun, Clauden tuottaman luonnoksen **KB-luonnokset**-listaan Microsoft Graphin kautta ([ohje](../sharepoint-graph.md)). Erillinen flow käynnistyy uudesta luonnoksesta ja hoitaa hyväksynnän. Hyväksyntä on näin yhdessä paikassa riippumatta siitä, mistä luonnos tulee.

![PowerShell kirjoittaa luonnoksen listalle](06-powershell-julkaisu.png)

![Hyväksyntä-flow'n rakenne](07-hyvaksynta-flow.png)

![AI-luonnos KB-luonnokset-listalla, luojana sovellus](08-ai-luonnos-listalla.png)

### Flow "KB-luonnoksen hyväksyntä"

| Vaihe | Asetukset |
| --- | --- |
| **When an item is created** (SharePoint) | Sivusto ServiceDesk, lista KB-luonnokset. Settings → Trigger conditions: `@equals(triggerOutputs()?['body/Tila/Value'], 'Luonnos')` |
| **Start and wait for an approval** | Approve/Reject – First to respond. Title: `concat('KB-luonnos: ', triggerOutputs()?['body/Title'])`. Assigned to: hyväksyjän osoite. Details: oire, ratkaisu ja lähdetiketti. Item link: `triggerOutputs()?['body/{Link}']` |
| **Condition** | `outputs('Start_and_wait_for_an_approval')?['body/outcome']` is equal to `Approve` |
| **Update item** (kummassakin haarassa) | Id: `triggerOutputs()?['body/ID']`. Title: `triggerOutputs()?['body/Title']`. Tila: Hyväksytty / Hylätty. Hyvaksyja Claims: `first(outputs('Start_and_wait_for_an_approval')?['body/responses'])?['responder']?['email']` |

### Huomioita

- **Trigger condition.** Flow ei käynnisty kohteista, joiden tila on jo muu kuin *Luonnos* (esim. käsin lisätty valmis artikkeli). Ehto tarkistetaan ennen ajoa, joten ohitetut kohteet eivät näy epäonnistuneina ajoina.
- **Ei silmukkaa.** Update item muokkaa kohdetta, mutta trigger reagoi vain uusiin kohteisiin.
- **Kaksi flow'ta samalla listalla.** Ensimmäinen flow käynnistää oman hyväksyntänsä luomalleen luonnokselle. Jos molemmat ovat päällä sellaisenaan, samasta luonnoksesta lähtee kaksi pyyntöä. Ratkaisuksi ensimmäisestä flow'sta poistetaan hyväksyntävaiheet (se päättyy Create item -vaiheeseen) tai se poistetaan käytöstä.
- **Title Update item -vaiheessa.** SharePointin Update item vaatii pakolliset sarakkeet, joten otsikko annetaan uudelleen triggerin arvosta.
- **Luoja.** Graphin kautta luodun kohteen luojana näkyy sovellus, ei käyttäjä. Näin listalta näkee, mitkä luonnokset tulivat AI-putkesta.
