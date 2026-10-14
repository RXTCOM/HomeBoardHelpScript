# Home Board-server zelf draaien

Met een eigen server bewaart Home Board alles bij jou thuis: taken, sterren, zakgeld, foto's als bewijs en het weekmenu. Alle apparaten van het gezin delen zo één bord, en ouders krijgen meldingen op hun telefoon.

Deze handleiding zet een **InfluxDB 2**-database op een **Raspberry Pi** of een **NAS**. Het werk zit vooral in de eerste keer instellen. Daarna houdt de server zichzelf bij:

| Wat | Wanneer | Wat er gebeurt |
|---|---|---|
| Controle | elke 10 minuten | Ligt de database eruit of reageert hij niet meer, dan start hij hem opnieuw. Ook als de schijf bijna vol raakt, merkt hij dat. |
| Backup | elke nacht | Maakt een volledige backup en bewaart de laatste 14. Op wens zet hij er ook een kopie van op een USB-schijf of NAS. |
| Update database | elke zondagnacht | Maakt eerst een backup en installeert dan de nieuwste InfluxDB 2.x. Start die niet goed op, dan gaat hij vanzelf terug naar de vorige versie. |
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

1. Open Home Board op de **tablet aan de muur** en tik op **📷 QR-code scannen**.
2. Scan de QR-code die het installatiescript liet zien.

   Kun je niet scannen? Kopieer dan de koppelcode, de regel die begint met `{"kb":1`, en plak hem in het veld **Serveradres**.
3. Telefoons van ouders en tablets van kinderen voeg je daarna toe vanuit de app: **Ouders → Instellingen → Apparaat toevoegen met QR-code**.

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

## Apparaat kwijt of gestolen?

Elk gekoppeld apparaat kan met het token bij de gegevens van het bord. Raak je een tablet of telefoon kwijt, maak dan een nieuw token. Het oude werkt meteen niet meer:

```
cd ~/homeboard
sudo ./onderhoud.sh nieuw-token
```

Het script toont daarna een nieuwe QR-code. Scan die op elk apparaat dat je houdt: **Ouders → Server → Serververbinding wijzigen → 📷 QR-code scannen**. Foto's en de koppeling met Home Assistant blijven gewoon leesbaar, want die zijn versleuteld met een gezinssleutel die op je eigen apparaten staat en niet in het token.

> Werk eerst alle apparaten die je houdt bij naar app-versie **1.43** of nieuwer. Oudere versies halen hun sleutel nog uit het token en kunnen na een nieuw token de foto's en de Home Assistant-koppeling niet meer openen.

---

## 7. Wat je beter niet doet

- **Het token van de app niet met de hand vervangen.** Gebruik daarvoor `sudo ./onderhoud.sh nieuw-token` (zie [Apparaat kwijt of gestolen?](#apparaat-kwijt-of-gestolen)).
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
3. Voeg de andere apparaten daarna toe met een QR-code via **Ouders → Instellingen → Apparaat toevoegen met QR-code**. Dan hoef je het token maar één keer over te typen.

### 9.3 Waar je zelf op let
- Het automatische onderhoud uit deze handleiding geldt niet voor je eigen server. Neem de bucket mee in de backups die je al maakt.
- Een token vervangen kan hier ook: maak in InfluxDB een nieuw token zoals in stap 9.1, koppel de apparaten die je houdt opnieuw (app 1.43 of nieuwer) en verwijder daarna het oude token. Bij een eigen backup en restore blijven de tokens gewoon bewaard.
- Het moet InfluxDB **2.x** zijn, of InfluxDB Cloud met Flux. InfluxDB 1.x en InfluxDB 3 werken niet. Let op: de InfluxDB-add-on van Home Assistant is versie 1.8 en werkt dus niet.
- Meerdere gezinnen op één server? Geef elk gezin een eigen bucket met een eigen token. Ze kunnen dan niet bij elkaars gegevens.

---

## Licentie

Deze scripts en de handleiding vallen onder de [MIT-licentie](https://github.com/RXTCOM/HomeBoardHelpScript/blob/main/LICENSE): je mag ze vrij gebruiken, aanpassen en delen, zolang de copyrightvermelding erbij blijft. De Home Board-app zelf valt daar niet onder; daarvoor gelden de [gebruiksvoorwaarden](https://home-board.nl/voorwaarden).
