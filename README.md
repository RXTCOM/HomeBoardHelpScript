# Home Board-server zelf draaien

Met een eigen server bewaart Home Board alles bij jou thuis: taken, sterren, zakgeld, foto's als bewijs en het weekmenu. Alle apparaten van het gezin delen zo één bord, en ouders krijgen meldingen op hun telefoon.

Deze handleiding zet een **InfluxDB 2**-database op een **Raspberry Pi** of een **NAS**. Het werk zit vooral in de eerste keer instellen. Daarna houdt de server zichzelf bij:

| Wat | Wanneer | Wat er gebeurt |
|---|---|---|
| Controle | elke 10 minuten | Ligt de database eruit of reageert hij niet meer, dan start hij hem opnieuw. Ook als de schijf bijna vol raakt, merkt hij dat. |
| Backup | elke nacht | Maakt een volledige backup en bewaart de laatste 14. Op wens zet hij er ook een kopie van op een USB-schijf of NAS. |
| Update database | elke zondagnacht | Maakt eerst een backup en installeert dan de nieuwste InfluxDB 2.x. Start die niet goed op, dan gaat hij vanzelf terug naar de vorige versie, met de gegevens van vlak voor de update. |
| Update systeem | elke dag | Installeert beveiligings- en Docker-updates. Moet het systeem daarvoor opnieuw starten, dan doet het dat om 04:00. *(Raspberry Pi; een NAS werkt zichzelf bij via de eigen instellingen)* |
| Stroomstoring | – | Komt de stroom terug, dan start alles weer vanzelf op. |

Verder blijven de logboeken klein, zodat de schijf niet volloopt.

> **Draai je al InfluxDB 2**, bijvoorbeeld voor energie- of sensorgegevens? Dan hoef je niets te installeren. Maak er een extra bucket bij en Home Board werkt daar gewoon mee. Zie [9. Je hebt al een InfluxDB 2](#9-je-hebt-al-een-influxdb-2).

---

## 1. Wat heb je nodig

**Raspberry Pi**
- Een Raspberry Pi 4 of 5 met minimaal 2 GB geheugen. Een Pi 3 werkt in theorie, maar is erg krap.
- De officiële voeding.
- Het liefst een **SSD via USB** (of een NVMe-kaartje op de Pi 5) in plaats van een SD-kaart. Een database schrijft de hele dag door, en daar slijt een SD-kaart van. Lukt dat niet, neem dan een goede SD-kaart van het type "High Endurance".
- Een netwerkkabel naar de router. Wifi werkt ook, maar een kabel is betrouwbaarder.

**Of een NAS**
- Een NAS die Docker ondersteunt: **Synology** met Container Manager of **QNAP** met Container Station.
- Hij moet een 64-bit processor hebben (Intel/AMD of 64-bit ARM). Oudere 32-bit NAS-modellen kunnen InfluxDB 2 niet draaien.

**Of een InfluxDB 2-server die je al hebt**
- Een bestaande InfluxDB **2.x**-server, bijvoorbeeld in Docker, op je NAS of in InfluxDB Cloud. InfluxDB 1.x en 3 werken niet.
- Je hoeft dan niets te installeren: je maakt er alleen een extra bucket en een token bij. Ga direct naar [9. Je hebt al een InfluxDB 2](#9-je-hebt-al-een-influxdb-2).

---

## 2. Installeren op een Raspberry Pi

### 2.1 Het systeem op de SSD of SD-kaart zetten
1. Installeer **Raspberry Pi Imager** op je computer (raspberrypi.com/software).
2. Kies je Pi-model en als besturingssysteem **Raspberry Pi OS Lite (64-bit)**, onder "Raspberry Pi OS (other)". Kies als opslag je SSD of SD-kaart.
3. Klik op **Instellingen bewerken** en vul in:
   - hostnaam: `homeboard`
   - een gebruikersnaam en een sterk wachtwoord
   - (alleen bij wifi) je wifi-naam en -wachtwoord
   - op het tabblad *Services*: **SSH inschakelen**
4. Schrijf de schijf, sluit hem aan op de Pi en zet de Pi aan. Wacht een paar minuten.

### 2.2 Een vast adres geven
Open de instellingen van je router en zoek "DHCP-reservering" of "vast IP-adres". Geef het apparaat `homeboard` daar een vast adres, bijvoorbeeld `192.168.1.20`. De apps onthouden dit adres. Verandert het, dan kunnen ze de server niet meer vinden.

### 2.3 Home Board-server installeren
Log vanaf je computer in op de Pi. Op Windows gaat dat met PowerShell, op Mac met Terminal:

```
ssh jouwnaam@homeboard.local
```

Download en installeer daarna de server:

```
mkdir -p ~/homeboard && cd ~/homeboard
wget -qO homeboard-server.tar.gz https://github.com/RXTCOM/HomeBoardHelpScript/releases/latest/download/homeboard-server.tar.gz
wget -qO SHA256SUMS https://github.com/RXTCOM/HomeBoardHelpScript/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS && tar -xzf homeboard-server.tar.gz && sudo ./install.sh
```

`sha256sum -c` controleert eerst of het pakket precies is wat wij hebben gepubliceerd. Klopt het niet, dan stopt de regel en wordt er niets geïnstalleerd; laat het ons dan weten.

Het script doet de rest:
- Docker en InfluxDB 2 installeren
- willekeurige wachtwoorden en tokens maken
- een apart token maken voor de app, dat alleen bij de gegevens van het bord kan
- de automatische controles, backups en updates inplannen

Aan het eind toont het script een **QR-code** en de **koppelcode**.

> Het duurt de eerste keer een paar minuten. Je kunt `sudo ./install.sh` gerust nog een keer uitvoeren: het vult alleen aan wat ontbreekt.

Ga verder met [4. De app koppelen](#4-de-app-koppelen).

---

## 3. Installeren op een NAS

### 3.1 Synology
1. Installeer **Container Manager** via het Pakketcentrum.
2. Ga naar **Configuratiescherm → Terminal en SNMP** en zet **SSH** aan.
3. Maak in File Station de map `docker/homeboard` aan.
4. Log vanaf je computer in met een beheerdersaccount, bijvoorbeeld `ssh admin@192.168.1.10`, en voer uit:
   ```
   cd /volume1/docker/homeboard
   wget -qO homeboard-server.tar.gz https://github.com/RXTCOM/HomeBoardHelpScript/releases/latest/download/homeboard-server.tar.gz
   wget -qO SHA256SUMS https://github.com/RXTCOM/HomeBoardHelpScript/releases/latest/download/SHA256SUMS
   sha256sum -c SHA256SUMS && tar -xzf homeboard-server.tar.gz && sudo ./install.sh
   ```
5. Op een NAS plant het script het onderhoud niet zelf in. Maak daarom in **Configuratiescherm → Taakplanner** drie taken aan via **Maken → Geplande taak → Door gebruiker gedefinieerd script**. Kies bij elke taak gebruiker **root**:

   | Taak | Schema | Script |
   |---|---|---|
   | Home Board controle | dagelijks, elke 10 minuten herhalen | `/volume1/docker/homeboard/onderhoud.sh check` |
   | Home Board backup | dagelijks om 03:15 | `/volume1/docker/homeboard/onderhoud.sh backup` |
   | Home Board update | wekelijks, zondag 04:30 | `/volume1/docker/homeboard/onderhoud.sh update` |

6. Zet onder **Configuratiescherm → Bijwerken en herstellen** het automatisch installeren van belangrijke DSM-updates aan.
7. Zet SSH daarna gerust weer uit.

### 3.2 QNAP
1. Installeer **Container Station** via het App Center en zet SSH aan (**Configuratiescherm → Netwerk- en bestandsservices → Telnet/SSH**).
2. Log in met SSH en voer uit:
   ```
   mkdir -p /share/Container/homeboard && cd /share/Container/homeboard
   wget -qO homeboard-server.tar.gz https://github.com/RXTCOM/HomeBoardHelpScript/releases/latest/download/homeboard-server.tar.gz
   wget -qO SHA256SUMS https://github.com/RXTCOM/HomeBoardHelpScript/releases/latest/download/SHA256SUMS
   sha256sum -c SHA256SUMS && tar -xzf homeboard-server.tar.gz && sudo ./install.sh
   ```
3. Plan het onderhoud in. Zet deze drie regels onderaan in `/etc/config/crontab`:
   ```
   */10 * * * * /share/Container/homeboard/onderhoud.sh check
   15 3 * * * /share/Container/homeboard/onderhoud.sh backup
   30 4 * * 0 /share/Container/homeboard/onderhoud.sh update
   ```
   Laad de planning daarna opnieuw met `crontab /etc/config/crontab && /etc/init.d/crond.sh restart`.
4. Zet automatische firmware-updates aan onder **Configuratiescherm → Firmware-update**.

> Toont het script een verkeerd adres, bijvoorbeeld van een intern Docker-netwerk? Zet dan in het bestand `.env` de regel `SERVER_URL=http://192.168.1.10:8086`, met het adres van je NAS. Vraag daarna met `sudo ./onderhoud.sh koppelcode` een nieuwe koppelcode op.

---

## 4. De app koppelen

1. Open Home Board op de **tablet aan de muur** en kies bij de eerste start **Met mijn eigen server** → **📷 QR-code scannen**.
2. Scan de QR-code die het installatiescript liet zien. Daarmee krijgt het gezinsbord ook het **beheer**: het kan apparaten toevoegen en ontkoppelen.

   Kun je niet scannen? Kopieer dan de koppelcode, de regel die begint met `{"kb":1`, en plak hem in het veld **Serveradres**.
3. Telefoons van ouders en tablets van kinderen voeg je daarna toe vanuit de app: **Ouders → Apparaat toevoegen**. Kies wie het apparaat gebruikt, geef het een naam en tik op **QR-code maken**. Elk apparaat krijgt zo een eigen toegang.

### Apparaat kwijt of gestolen?
Open **Ouders → Apparaten** op het gezinsbord of de telefoon van een ouder en tik bij het apparaat op **Ontkoppelen**. Het kan dan meteen niet meer bij het bord, en wist de gegevens van het gezin zodra het weer verbinding zoekt.

Apparaten die je vóór app-versie 1.44 koppelde, delen één toegang en staan bij **Gedeelde toegang**. Die kun je niet los ontkoppelen. Koppel ze één voor één opnieuw via **Apparaat toevoegen**, en trek daarna onderaan **Gedeelde toegang** in.

> Had je de server al vóór scripts-versie 1.2? Download de nieuwe versie zoals in stap 2.3 en voer `sudo ./install.sh` opnieuw uit. Het maakt dan alleen het beheertoken aan en toont een nieuwe QR-code. Scan die op het gezinsbord via **Ouders → Server → Serververbinding wijzigen**. Je gegevens blijven gewoon staan.

Geen QR-code bij de hand? Bij de eerste start zoekt de app zelf naar de server op het netwerk thuis (vanaf app-versie 1.23). Hij vult dan het adres, de organisatie en de bucket in. Alleen het token vul je nog zelf in: dat staat in de koppelcode, en `sudo ./onderhoud.sh koppelcode` laat die opnieuw zien.

Gebruikte je de app al zonder server? Kies dan in de app **Ouders → Instellingen → Overstappen naar eigen server** (bij Opslag) en scan dezelfde code. Alles wat je al had, gaat mee naar de server.

De QR-code later nog eens nodig? Voer dan uit:
```
sudo ~/homeboard/onderhoud.sh koppelcode
```

---

## 5. Gewaarschuwd worden als er iets mis is (optioneel)

De server lost de meeste problemen zelf op. Wil je toch een e-mail krijgen als hij langer dan een half uur niets van zich laat horen, of als een backup mislukt? Gebruik dan het gratis **healthchecks.io**:

1. Maak een account aan en daarna een check met *Period* **10 minuten** en *Grace* **30 minuten**.
2. Kopieer de ping-URL en zet hem in het bestand `.env`:
   ```
   HEALTHCHECK_URL=https://hc-ping.com/jouw-code
   ```

Je krijgt dan ook een e-mail als de stroom of het internet thuis langere tijd uitvalt.

---

## 6. Backups

- Elke nacht komt er een backup in de map `backups/`. Daarin zit ook het bestand `.env` met de tokens. **Bewaar de backups dus net zo zorgvuldig als een wachtwoord.**
- Een tweede kopie buiten de Pi is verstandig, want valt de SSD uit, dan ben je anders ook je backups kwijt. Zet een USB-stick of een gedeelde map van de NAS in `.env`:
  ```
  BACKUP_COPY_TO=/mnt/usb/homeboard-backups
  ```
- Op een NAS kun je de map `homeboard` ook meenemen in je gewone NAS-backup, zoals Hyper Backup bij Synology.

### Terugzetten
Op **dezelfde** server, bijvoorbeeld als er per ongeluk iets is gewist:
```
sudo ./onderhoud.sh restore backups/homeboard-2026-10-11-031500.tar.gz
```

Op **nieuwe hardware**, bijvoorbeeld een nieuwe Pi, SSD of NAS: volg stap 2 of 3, maar installeer met de backup erbij:
```
sudo ./install.sh --herstel /pad/naar/homeboard-2026-10-11-031500.tar.gz
```
Alle tokens komen dan terug. Tablets en telefoons blijven gekoppeld en versleutelde foto's blijven leesbaar. Geef de nieuwe server in de router wel hetzelfde vaste adres als de oude.

---

## 7. Wat je beter niet doet

- **Het token van de app niet met de hand vervangen of verwijderen.** Dan kan geen enkel apparaat meer bij het bord. Een kwijtgeraakt apparaat ontkoppel je in de app.
- **Niet overstappen op InfluxDB 3.** Versie 3 werkt niet met de taal die Home Board gebruikt (Flux). Het update-script blijft daarom bewust bij versie 2.
- **Geen bewaartermijn instellen op de bucket.** Instellingen en gespaard zakgeld moeten altijd bewaard blijven.
- **Poort 8086 niet openzetten naar internet.** Dan kan iedereen op internet proberen bij je gegevens te komen.

---

## 8. Handige commando's

Voer deze uit vanuit de map van de server, bijvoorbeeld `~/homeboard`:

| Commando | Wat het doet |
|---|---|
| `sudo ./onderhoud.sh status` | Toont of alles draait, de versie, de laatste backup, de vrije ruimte en de laatste meldingen. |
| `sudo ./onderhoud.sh koppelcode` | Toont de QR-code en koppelcode opnieuw. |
| `sudo ./onderhoud.sh backup` | Maakt nu meteen een backup. |
| `sudo ./onderhoud.sh update` | Werkt InfluxDB nu meteen bij. |
| `docker logs homeboard-influxdb` | Toont het logboek van de database. |

**De app zegt "De server is niet bereikbaar"**
- Staat de Pi of NAS aan? Kijk met `status`.
- Heeft de server nog hetzelfde adres? Zie stap 2.2.
- Ben je buitenshuis? De server is alleen bereikbaar op het netwerk thuis.

**De app zegt "De server weigert het token"**
- Is de server opnieuw geïnstalleerd zonder `--herstel`? Zet dan de backup terug (zie stap 6) of koppel de apparaten opnieuw.

**Inloggen op de database zelf** (niet nodig voor Home Board)
- Ga naar `http://<adres>:8086`.
- Log in met `INFLUX_USER` en `INFLUX_PASSWORD` uit `.env`.

---

## 9. Je hebt al een InfluxDB 2

Draait er bij jou al een InfluxDB 2-server, bijvoorbeeld in Docker, op je NAS of in InfluxDB Cloud? Dan kan Home Board daar gewoon in. Je maakt alleen een extra bucket en een token aan. Het installatiescript uit deze handleiding heb je dan niet nodig.

### 9.1 Bucket en token maken
In de webpagina van InfluxDB, meestal `http://<adres>:8086`:

1. Ga naar **Load Data → Buckets → Create Bucket**.
   - Noem de bucket bijvoorbeeld `homeboard`.
   - Kies bij **Delete Data** voor **Never**. Instellingen en gespaard zakgeld moeten altijd bewaard blijven.
2. Ga naar **Load Data → API Tokens → Generate API Token → Custom API Token**.
   - Zet bij **Buckets** voor `homeboard` zowel **Read** als **Write** aan, en verder niets.
   - Geef het token een naam, zoals "Home Board app", en kopieer het. InfluxDB laat het maar één keer zien.

Werk je liever met de opdrachtregel? Dan kan het ook zo:
```
influx bucket create --name homeboard --org <jouw-organisatie>
influx bucket list --name homeboard        # noteer het ID
influx auth create --org <jouw-organisatie> --read-bucket <ID> --write-bucket <ID> --description "Home Board app"
```

Gebruik voor Home Board niet je beheerderstoken. Het token hierboven kan alleen bij de bucket van Home Board, niet bij je andere gegevens.

### 9.2 De app koppelen
1. Open Home Board op de tablet aan de muur en vul de velden in:
   - **Serveradres**: tik op **🔍 Zoek op het netwerk**, dan vindt de app je server zelf. Of vul het adres in, bijvoorbeeld `http://192.168.1.10:8086`.
   - **Organisatie**: de naam van je organisatie in InfluxDB (hoofdletters tellen mee)
   - **Bucket**: `homeboard`
   - **API-token**: het token uit stap 9.1
2. Tik op **Verbinding testen** en daarna op **Opslaan**.
3. Ga door met 9.3: dan kun je de andere apparaten toevoegen met een QR-code en een kwijtgeraakt apparaat ontkoppelen.

### 9.3 Apparaten toevoegen en ontkoppelen (app 1.44 of nieuwer)
Om vanuit de app apparaten toe te voegen en te ontkoppelen, heeft het gezinsbord een **beheertoken** nodig. Dat maak je één keer zelf.

1. **Beheertoken maken.** Ga naar **Load Data → API Tokens → Generate API Token → Custom API Token**:
   - bij **Buckets**: `homeboard` **Read** en **Write**;
   - bij **Other Resources** (of **Resources**): **Authorizations** en **Users**, allebei **Read** en **Write**;
   - noem het precies **Home Board beheer** en kopieer het.

   Of met de opdrachtregel:
   ```
   influx auth create --org <jouw-organisatie> --read-bucket <ID> --write-bucket <ID> \
     --read-authorizations --write-authorizations --read-users --write-users --description "Home Board beheer"
   ```
   Dit token kan alleen toegang geven tot de bucket van Home Board, niet tot je andere gegevens.
2. **Naam van het app-token controleren.** Heet het token uit 9.1 niet precies **Home Board app**? Klik in **API Tokens** op de naam en pas hem aan. Daaraan herkent de app de gedeelde toegang.
3. **Koppelcode maken.** Zet deze regel in een teksteditor, met je eigen gegevens:
   ```
   {"kb":1,"u":"http://192.168.1.10:8086","o":"<organisatie>","b":"homeboard","t":"<app-token>","m":"<beheertoken>","r":"board"}
   ```
4. **Op het gezinsbord:** **Ouders → Server → Serververbinding wijzigen**, en plak de regel in het veld **Serveradres**. De app test de verbinding, slaat alles op en start opnieuw. Je gegevens blijven gewoon staan.
5. Voeg daarna telefoons en tablets toe via **Ouders → Apparaat toevoegen**. Elk apparaat krijgt een eigen toegang, die je bij **Ouders → Apparaten** kunt ontkoppelen. Apparaten die al gekoppeld waren, staan bij **Gedeelde toegang**: koppel ze opnieuw en trek daarna de gedeelde toegang in.

### 9.4 Waar je zelf op let
- Het automatische onderhoud uit deze handleiding geldt niet voor je eigen server. Neem de bucket mee in de backups die je al maakt.
- Bij een eigen backup en restore blijven de tokens gewoon bewaard.
- Het moet InfluxDB **2.x** zijn, of InfluxDB Cloud met Flux. InfluxDB 1.x en InfluxDB 3 werken niet. Let op: de InfluxDB-add-on van Home Assistant is versie 1.8 en werkt dus niet.
- Gebruik `influxdb:2`, niet `latest`. Die tag wijst sinds september 2026 naar InfluxDB 3.
- Houd InfluxDB 2 bij. Alleen de nieuwste twee versies (nu 2.9 en 2.8) krijgen beveiligingsupdates. Draait je server een oudere versie, dan meldt de app dat bij **Ouders → Server**.
- Meerdere gezinnen op één server? Geef elk gezin een eigen bucket met een eigen token. Ze kunnen dan niet bij elkaars gegevens.

### 9.5 Zelf al een InfluxDB 2 in Docker?
Werk je zelf bij naar de nieuwste 2.x, bijvoorbeeld van 2.7 naar 2.9? Doe dan eerst dit.

**Stap 1. Zoek de naam van het volume** waar de gegevens in staan:
```
docker inspect <container> --format '{{range .Mounts}}{{.Name}}{{end}}'
```
Komt er niets uit, dan staan de gegevens in een gewone map. Die vind je met `--format '{{range .Mounts}}{{.Source}}{{end}}'`. Kopieer die map dan zelf, met de container gestopt.

**Stap 2. Maak een kopie van het volume**, met de container gestopt:
```
docker stop <container>
docker run --rm -v <volume>:/d -v "$PWD":/b alpine tar czf /b/influxdb-voor-update.tar.gz -C /d .
docker start <container>
```

**Stap 3. Bewaar je tokens.** Vanaf 2.9 bewaart InfluxDB tokens versleuteld, en daarna kun je ze niet meer bekijken:
```
docker exec <container> influx auth list > tokens-voor-update.txt
```
Bewaar dit bestand veilig: wie het heeft, kan bij je gegevens.

**Stap 4. Werk daarna pas bij**, met `influxdb:2` als image.

Terug van 2.9 naar 2.7 kan alleen met die kopie. InfluxDB 2.9 past de database aan bij de eerste start, en 2.7 start daarna niet meer op die gegevens.

---

## Licentie

Deze scripts en de handleiding vallen onder de [MIT-licentie](https://github.com/RXTCOM/HomeBoardHelpScript/blob/main/LICENSE): je mag ze vrij gebruiken, aanpassen en delen, zolang de copyrightvermelding erbij blijft. De Home Board-app zelf valt daar niet onder; daarvoor gelden de [gebruiksvoorwaarden](https://home-board.nl/voorwaarden).
