# Funkmodule und multimacd: alle Einstellungen

*Deutsch — die englische Fassung ist [radio.en.md](radio.en.md).*

Diese Seite führt alle Einstellungen auf, die bestimmen, welches Funkmodul die Schnittstellenprozesse nutzen, und
was jede Kombination startet. Sie ist die einzige vollständige Liste; die anderen Dokumente verweisen hierher.

Die Schnittstellenprozesse:

- **rfd** - BidCos-RF (klassischer Homematic-Funk), auf einem lokalen Funkmodul, einem HM-CFG-USB-2 und/oder
  BidCos-LAN-Gateways.
- **hmipserver** - ein Java-Prozess, der einen von zwei Servern betreibt:
  - **HMIPServer.jar** - HmIP-RF (Homematic-IP-Funk, HmIP-HAPs und DRAPs, HmIP Wired) *und* die virtuellen Geräte
    (Heizungsgruppen und Ähnliches, `VirtualDevices`, Port 39292);
  - **HMServer.jar** - nur die virtuellen Geräte.
- **multimacd** - der Multiplexer: Er öffnet ein Funkmodul an seinem UART und stellt es rfd (`/dev/mmd_bidcos`) und
  hmipserver (`/dev/mmd_hmip`) gleichzeitig zur Verfügung.
- **hs485d** - BidCos-Wired (klassisches Homematic Wired), über ein HMW-LGW Wired-LAN-Gateway.
- **hmlangw** - nur im LAN-Gateway-Modus (siehe unten): Das System arbeitet dann selbst als BidCos-LAN-Gateway für
  eine andere Zentrale.

Das System erkennt die Funkmodule bei jedem Start und bei jedem Ein- und Ausstecken und erstellt dann aus der Hardware
und den Einstellungen unten einen Plan. *System → Schnittstellen → Verbindungen* zeigt den Plan (was läuft, auf welchem
Funkmodul und warum) und ändert die Einstellungen.

## Die Einstellungen

| Einstellung | Wo | Werte | Standard |
| --- | --- | --- | --- |
| **HmIP-RF-Funkmodul** | *Schnittstellen → Verbindungen → HmIP-RF*; gespeichert als `occulite.hmip.adapter=` in `/etc/config/crRFD/hmip_user.conf` | **Automatisch** (keine Zeile): das Funkmodul, das OpenCCU wählen würde (ein RPI-RF-MOD vor einem HM-MOD-RPI-PCB), und danach das Funkmodul, auf dem das HmIP-Netzwerk zuletzt lief; **ein Funkmodul** (seine Seriennummer oder SGTIN): genau dieses; **Keins** (`none`): gar kein HmIP | Automatisch |
| **HmIP-Weg** | dieselbe Auswahlliste: ein Eintrag je Funkmodul und Weg; gespeichert als `occulite.hmip.path=` in derselben Datei | **automatisch** (keine Zeile); **direkt** - hmipserver öffnet den UART des Funkmoduls selbst; **multimacd** - über `/dev/mmd_hmip` | automatisch |
| **BidCos-RF-Funkmodul** | *Schnittstellen → Verbindungen → BidCos-RF*; gespeichert als erste Zeile `# occulite.bidcos.module=` in `/etc/config/rfd.conf` | **Automatisch** (keine Zeile): ein HM-CFG-USB-2, wenn eines eingesteckt ist, sonst das Funkmodul, das OpenCCU wählen würde (ein HM-MOD-RPI-PCB vor einem RPI-RF-MOD); **ein Funkmodul** (seine Seriennummer); **Keins** (`none`): rfd ohne lokales Funkmodul - *Aus (nur HmIP)* ohne LAN-Gateway, *Kein lokales Funkmodul (nur LAN-Gateway)* mit einem | Automatisch |
| **BidCos-LAN-Gateways** | *Schnittstellen → LAN-Geräte*; Abschnitte in `/etc/config/rfd.conf` | beliebig viele HM-LGW-O-TW-W-EU / HM-CFG-LAN | keine |
| **HB-RF-ETH** | *Schnittstellen → LAN-Geräte*; seine Adresse | eine Funkplatine im Netzwerk; ihr Funkmodul erscheint dann wie ein Funkmodul auf der Stiftleiste | keine |
| **BidCos-Wired** | *Schnittstellen → LAN-Geräte*; ein Abschnitt in `/etc/config/hs485d.conf` | ein HMW-LGW-O-DR-GS-EU | keins |
| **LAN-Gateway-Modus** | die Datei `/usr/local/HMLGW` (keine Seite) | vorhanden: Das System ist ein BidCos-LAN-Gateway für eine andere Zentrale | nicht vorhanden |

Eine Einstellung wird in die eigenen Dateien der Dienste geschrieben, flasht nie Firmware und bleibt bestehen, wenn ihr
Funkmodul fehlt: Kein Prozess wird jemals ohne die Wahl des Benutzers auf ein anderes Funkmodul verlegt.

## Was läuft

**HMServer.jar läuft nur, wenn HmIP auf Keins steht.** Mit Automatisch oder einem gewählten Funkmodul betreibt
hmipserver immer HMIPServer.jar - mit seinem Funkmodul oder, wenn keines gefunden wird oder das gewählte fehlt, ohne
es. HMIPServer.jar kann ohne sein Funkmodul nicht starten (es wartet darauf und öffnet weder HmIP-RF noch die virtuellen
Geräte). Das System startet hmipserver dann gar nicht und sagt das: *Status* (die Warnung „HmIP-RF und die virtuellen
Geräte sind ausgefallen“) und *Schnittstellen → Verbindungen* nennen den Ausweg - das Funkmodul anschließen oder HmIP-RF
auf Keins stellen. Nichts wechselt von selbst zu HMServer.jar. (OpenCCU betreibt HMServer.jar immer dann, wenn es kein
HmIP-Funkmodul findet.)

| HmIP-RF | BidCos-RF | Hardware | multimacd | rfd | hmipserver | Angebotene Schnittstellen |
| --- | --- | --- | --- | --- | --- | --- |
| Automatisch / ein Funkmodul | Automatisch / dasselbe Funkmodul | ein Funkmodul, das beides trägt (RPI-RF-MOD, HmIP-RFUSB, HM-MOD-RPI-PCB), auf der Stiftleiste, ein HB-RF-USB(-2) oder HB-RF-ETH, oder ein HmIP-RFUSB mit Dual-Firmware | auf dem Funkmodul | über `/dev/mmd_bidcos` (+ LAN-Gateways) | HMIPServer.jar über `/dev/mmd_hmip` | BidCos-RF, HmIP-RF, VirtualDevices |
| Automatisch / ein Funkmodul | **Keins** | dasselbe | nicht für ein RPI-RF-MOD oder HmIP-RFUSB (hmipserver öffnet es direkt); **ja** für ein HM-MOD-RPI-PCB (Regel 1) | nicht ohne LAN-Gateway; mit einem nur auf den LAN-Gateways | HMIPServer.jar auf dem Funkmodul | HmIP-RF, VirtualDevices (+ BidCos-RF mit einem Gateway) |
| **Keins** | Automatisch / ein Funkmodul | ein Funkmodul, das beides trägt | auf dem Funkmodul (rfd erreicht ein Funkmodul an einem UART nur darüber) | über `/dev/mmd_bidcos` (+ LAN-Gateways) | **HMServer.jar** | BidCos-RF, VirtualDevices |
| **Keins** | Automatisch | ein HM-CFG-USB-2 | nein | auf dem HM-CFG-USB-2 (+ LAN-Gateways) | **HMServer.jar** | BidCos-RF, VirtualDevices |
| **Keins** | **Keins** | beliebig | nein | nur auf den LAN-Gateways, oder aus ohne eines | **HMServer.jar** | VirtualDevices (+ BidCos-RF mit einem Gateway) |
| Automatisch / ein Funkmodul | Automatisch | ein HM-CFG-USB-2 neben einem Funkmodul (oder einem HmIP-RFUSB) | nein | auf dem HM-CFG-USB-2 (+ LAN-Gateways) | HMIPServer.jar direkt auf dem Funkmodul (ein HM-MOD-RPI-PCB: über multimacd, Regel 1) | BidCos-RF, HmIP-RF, VirtualDevices |
| Automatisch / ein Funkmodul | Automatisch / ein Funkmodul | zwei Funkmodule (z. B. ein RPI-RF-MOD auf der Stiftleiste und ein HB-RF-USB mit einem HM-MOD-RPI-PCB) | auf dem BidCos-RF-Funkmodul | über `/dev/mmd_bidcos` | HMIPServer.jar direkt auf dem anderen Funkmodul | BidCos-RF, HmIP-RF, VirtualDevices |
| Automatisch / ein Funkmodul | beliebig | ein reines HmIP-Funkmodul (HmIP-RFUSB-TK, ein HmIP-RFUSB mit der reinen HmIP-Firmware, ein Funkmodul ohne BidCos-Adresse) | nur, wenn BidCos-RF ein eigenes Funkmodul an einem UART hat | auf diesem Funkmodul, dem HM-CFG-USB-2 oder den Gateways; ohne sie aus | HMIPServer.jar direkt auf dem reinen HmIP-Funkmodul (Regel 2) | HmIP-RF, VirtualDevices (+ BidCos-RF) |
| Automatisch | beliebig | **kein HmIP-Funkmodul gefunden** | nur, wenn BidCos-RF ein Funkmodul an einem UART hat | wie oben | **nicht gestartet** (HMIPServer.jar braucht sein Funkmodul; Warnung) | BidCos-RF, wo rfd läuft |
| ein Funkmodul, das **fehlt** | beliebig | - | wie oben | wie oben | **nicht gestartet** (Warnung mit dem Namen des Funkmoduls) | BidCos-RF, wo rfd läuft |

**Der HmIP-Weg** ändert nur, wie hmipserver sein Funkmodul erreicht: *automatisch* nimmt multimacd, wenn BidCos-RF das
Funkmodul mitbenutzt, und sonst das Funkmodul direkt; *direkt* und *multimacd* erzwingen einen Weg, soweit die Hardware
das zulässt (die Auswahlliste bietet nur diese an). Eine Wahl, die nicht bedient werden kann, wird abgelehnt, bevor
sich etwas ändert: *direkt*, während BidCos-RF dasselbe Funkmodul über multimacd nutzt, und *multimacd*, während
multimacd schon ein anderes Funkmodul für BidCos-RF bedient. Steht HmIP auf Keins, gibt es keinen Weg zu wählen.

**hs485d** läuft genau dann, wenn ein HMW-LGW eingerichtet ist, unabhängig von den Funkeinstellungen; BidCos-Wired
steht dann in der Liste der Schnittstellen.

**Der LAN-Gateway-Modus** (`/usr/local/HMLGW`) übergeht alle Einstellungen oben: multimacd auf dem BidCos-Funkmodul und
hmlangw laufen, rfd, hmipserver und hs485d nicht, und auf diesem System wird keine Schnittstelle angeboten.

## Die festen Regeln

1. **Ein HM-MOD-RPI-PCB trägt HmIP nur über multimacd**: Direkt geöffnet hängt hmipserver nach jedem Reset des
   Funkmoduls. multimacd bedient ein Funkmodul, daher können HmIP auf einem PCB und BidCos-RF auf einem anderen
   Funkmodul, das multimacd braucht, nicht zusammen laufen; die Seite lehnt diese Wahl ab.
2. **Ein reines HmIP-Funkmodul wird direkt geöffnet**: rfd kann es nicht nutzen, und multimacd lehnt seinen
   Koprozessor ab. Der Bereich Funk-Firmware flasht die Dual-Firmware auf ein HmIP-RFUSB.
3. **HMServer.jar nur, wenn HmIP auf Keins steht** - nie als Ersatz für ein fehlendes Funkmodul.
4. **Kein Funkmodul wird ungefragt ersetzt:** Ein gewähltes Funkmodul, das fehlt, bleibt gewählt, und auf Automatisch
   bleibt HmIP-RF auf dem Funkmodul, das das HmIP-Netzwerk hält; der Umzug auf ein anderes Funkmodul ist ein
   Adaptertausch und braucht die Bestätigung des Benutzers.
5. Nur ein lokales Funkmodul je Prozess; LAN-Gateways, HmIP-HAPs und DRAPs werden hier nicht gewählt, und es können
   mehrere sein.

Wird HmIP auf Keins gestellt, fällt HmIP-RF weg: Angelernte HmIP-Geräte sind nicht erreichbar, bis HmIP wieder
eingestellt ist, aber ihre Anlernungen, Schlüssel und das HmIP-Netzwerk bleiben auf dem System (die Seite fragt vor der
Änderung nach). Zurück auf Automatisch oder das Funkmodul bringt sie wieder. Keins spart hmipserver etwa die Hälfte
seines Speichers: etwa 155 MB gegenüber etwa 300-330 MB für HMIPServer.jar, gemessen auf einem Pi 4.

Die API hinter der Seite ist `GET`/`PUT /api/system/v1/radio/connections` in `docs/system-api.md` von occulited.
