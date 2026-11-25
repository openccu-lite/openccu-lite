<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/openccu-lite-dark@2x.png">
    <img src="docs/images/openccu-lite-light@2x.png" alt="openccu-lite" width="428">
  </picture>
</h1>

[![stable release](https://img.shields.io/github/v/release/openccu-lite/openccu-lite?label=stable)](https://github.com/openccu-lite/openccu-lite/releases/latest)
[![beta](https://openccu-lite.github.io/openccu-lite/beta.svg)](https://github.com/openccu-lite/openccu-lite/releases)
[![upstream versions](https://img.shields.io/endpoint?url=https://openccu-lite.github.io/openccu-lite/badge.json)](https://openccu-lite.github.io/openccu-lite/)
[![severe CVEs](https://img.shields.io/endpoint?url=https://openccu-lite.github.io/openccu-lite/cve-badge.json)](https://openccu-lite.github.io/openccu-lite/cve.html)
[![security advisories](https://img.shields.io/endpoint?url=https://openccu-lite.github.io/openccu-lite/advisory-badge.json)](https://github.com/openccu-lite/openccu-lite/security/advisories)

[:uk: English README](README.en.md)

openccu-lite ist eine Firmware für Homematic-Zentralen, ein Fork des [OpenCCU-Projekts](https://github.com/OpenCCU/OpenCCU).
Sie bringt den Funk-Stack von [OpenCCU-Base](https://github.com/OpenCCU/OpenCCU-Base) mit (rfd, hs485d, multimacd und den HMIPServer) und eine
[neu entwickelte Oberfläche](docs/walkthrough/README.md) für die Verwaltung des Systems. Alles Weitere kommt als Addon
dazu: womit die Geräte angelernt und verwaltet werden, Programme und Systemvariablen, Anbindungen und Werkzeuge.
Home Assistant, ioBroker, Node-RED und andere Software lassen sich an die Zentrale anbinden.

Die ReGaHSS und mit ihr die alte CCU-WebUI und die Homematic-Scripte gibt es in openccu-lite nicht. **Programme
(*Wenn … Dann … Sonst*) und Systemvariablen bringt das Addon [Logic](https://github.com/openccu-lite/lite-addon-logic)**, das
sie auch aus einer CCU übernimmt; es ist derzeit noch in Beta. Systeminterna wie das Init-System, das Logging oder die
Funkmodulerkennung wurden von Grund auf neu gestaltet.

## Schwerpunkte

- **Stabil.** Weniger Bestandteile heißt weniger, was ausfallen kann und gepflegt werden muss. Eine hohe Abdeckung
  durch automatisierte Tests, auch auf echter Hardware, sichert jedes Release ab.
- **Sicher.** Addons und Systemdienste laufen voneinander abgeschottet mit eingeschränkten Rechten, und jeder Dienst
  bekommt nur die Rechte, die er braucht. Die Sicherheit folgt einem [Bedrohungsmodell](docs/threat-model.md), und
  ein täglicher [CVE-Bericht](https://openccu-lite.github.io/openccu-lite/cve.html) zeigt, welche bekannten
  Schwachstellen die veröffentlichten Versionen betreffen. Gefundene Lücken stehen als
  [Security Advisories](https://github.com/openccu-lite/openccu-lite/security/advisories) mit Abhilfe bereit.
  Details: [Sicherheit](docs/security.md).
- **Privat.** Keine Telemetrie. Im [lokalen Schlüsselmodus](docs/lokaler-schluesselmodus.md) lässt sich eine Zentrale
  auch ohne Internetverbindung und ohne Abhängigkeit vom Schlüsselserver von eQ-3 betreiben, sonstige ausgehende
  Verbindungen (Update-Checks) gibt es nur mit Zustimmung des Benutzers. Details: [Datenschutz](docs/privacy.md).
- **Flexibel.** Welches Funkmodul welche Schnittstelle bedient, ist frei wählbar. Das ermöglicht
  besondere Konfigurationen, etwa getrennte Funkmodule für BidCos-RF und HmIP-RF oder einen reinen HmIP-Betrieb ohne
  BidCos oder einen reinen BidCos-Betrieb ohne HmIP. [Beispiele](docs/walkthrough/README.md#beispiele-für-funk-konfigurationen)
  zeigt der Rundgang. Eine [Übersicht](docs/radio.md) erklärt alle Einstellungen der Funkmodule und von multimacd und
  was jede davon startet.
- **Minimal.** openccu-lite bringt nur mit, was die Zentrale grundlegend braucht. Alles andere kommt als Addon dazu,
  und zwar nur das, was man wirklich nutzen möchte. So bleibt das Image klein, Updates gehen schneller und der
  Wartungsaufwand sinkt.
- **Frei.** Wie man sein System zusammenstellt und welche Software darauf läuft, entscheidet jeder selbst. Für das
  Anlernen, die Bedienung, die Anbindung an andere Systeme oder die Automation auf dem System selbst stehen jeweils
  mehrere Alternativen bereit, die sich auch nebeneinander nutzen lassen. openccu-lite ist freie Software, ausgenommen
  die Komponenten von eQ-3 unter deren Lizenz (HMSL). Beiträge und Pull Requests sind willkommen. Das System gibt
  Einblick und Kontrolle, nichts wird versteckt: Umfangreiche Konfigurationsmöglichkeiten in der Weboberfläche geben
  möglichst viel Freiheit.

## Addons: nur das, was gebraucht wird

Die Firmware selbst bleibt bewusst klein. Was darüber hinaus gebraucht wird, lässt sich als Addon aus dem
eingebauten Addon-Katalog mit einem Klick installieren.

### Geräte anlernen und verwalten: freie Wahl

Womit die Geräte angelernt und konfiguriert und die Direktverknüpfungen verwaltet werden, ist frei wählbar. Die
folgenden Programme **können** als Addon auf openccu-lite installiert werden und sind dann in die Weboberfläche
integriert, **müssen aber nicht**: Sie laufen genauso auf einem anderen Rechner.

- [Homematic Manager](https://github.com/hobbyquaker/homematic-manager) - Geräte und Direktverknüpfungen verwalten;
  auch als Anwendung für Windows, macOS und Linux
- [OpenCCU-Loom](https://github.com/SukramJ/openccu-loom) - Geräte und Direktverknüpfungen verwalten, Home Assistant,
  MQTT, Matter, MCP server, Alarmsystem und vieles mehr

### Automatisieren

Für Automationen gibt es mehrere Wege nebeneinander. Welcher passt, entscheidet jeder selbst, auch mehrere zugleich:

- **Wenn-Dann-Programme:** [Logic](https://github.com/openccu-lite/lite-addon-logic) (Addon, Beta), Bedingungen und
  Aktivitäten aus Auswahllisten wie auf der CCU; übernimmt bestehende Programme und Systemvariablen einer CCU
- **Flows in Node-RED:** [RedMatic](https://github.com/rdmtc/RedMatic) (Addon)
- **Externe Software:** Home Assistant mit [Homematic(IP) Local](https://github.com/SukramJ/homematicip_local) und
  [OpenCCU-Loom](https://github.com/SukramJ/openccu-loom), ioBroker mit [ioBroker.hm-rpc](https://github.com/ioBroker/ioBroker.hm-rpc),
  Node-RED mit [node-red-contrib-ccu](https://github.com/rdmtc/node-red-contrib-ccu#openccu-lite), …

### Weitere Addons

- [hm2mqtt.js](https://github.com/hobbyquaker/hm2mqtt.js) - MQTT-Anbindung, Home Assistant Auto Discovery, folgt der
  Spec 2.0 von [mqtt-smarthome](https://github.com/mqtt-smarthome/mqtt-smarthome)
- [ccu-addon-mui](https://github.com/firsttris/ccu-addon-mui) - Geräte und Direktverknüpfungen verwalten, moderne
  Bedienoberfläche mit Charts
- [ccu-addon-battery](https://github.com/hobbyquaker/ccu-addon-battery) - Batteriewechsel erkennen, Statistiken zu
  Batterien
- [ccu-addon-longpressdim](https://github.com/hobbyquaker/ccu-addon-longpressdim) - Dimmen mit langem Tastendruck über
  Schnittstellengrenzen hinweg
- [ccu-addon-mosquitto](https://github.com/homematic-community/ccu-addon-mosquitto) - MQTT-Broker

### Nur für openccu-lite

Diese Addons lassen sich nicht auf einer CCU3 oder auf OpenCCU installieren.

- [lite-addon-forwarder](https://github.com/openccu-lite/lite-addon-forwarder) - Events und Systemdaten an InfluxDB,
  Prometheus, Elasticsearch, SQL-Datenbanken, Syslog, Loki, Webhooks u. a. weiterleiten
- [lite-addon-nut](https://github.com/openccu-lite/lite-addon-nut) - NUT-Client: fährt das System bei Stromausfall
  rechtzeitig herunter, wenn die USV es meldet
- [lite-addon-shell](https://github.com/openccu-lite/lite-addon-shell) - Root-Shell und Dateien des Systems im Browser,
  über den SSH-Server des Systems mit Anmeldung pro Sitzung
- [lite-addon-snmp](https://github.com/openccu-lite/lite-addon-snmp) - SNMP-Agent mit Daten der Homematic-Geräte und
  -Schnittstellen, Traps
- [lite-addon-sync](https://github.com/openccu-lite/lite-addon-sync) - Cloud-Konten (OneDrive, Google Drive, Dropbox, S3,
  WebDAV) als verschlüsselte Sicherungsziele, dazu Ordner des Systems in ein Konto oder auf einen SSH-Server kopieren
- [lite-addon-tailscale](https://github.com/openccu-lite/lite-addon-tailscale) - Fernzugriff auf das System über ein
  Tailscale-Netz, auch mit eigenem Headscale
- [lite-addon-tools](https://github.com/openccu-lite/lite-addon-tools) - Werkzeuge für die Fehlersuche und Verwaltung auf
  der Kommandozeile (SSH): tcpdump, nmap, strace, htop, mtr, socat, tmux, nano u. a.
- [lite-addon-wireguard](https://github.com/openccu-lite/lite-addon-wireguard) - Fernzugriff auf das System per
  WireGuard-VPN

Weitere Addons stehen im Katalog. Wie Addons auf openccu-lite funktionieren und wie sich ein bestehendes CCU-Addon
anpassen lässt, steht unter [Addons](docs/addons.md).

## Installation

Die Releases liegen unter [github.com/openccu-lite/openccu-lite/releases](https://github.com/openccu-lite/openccu-lite/releases).

- **Raspberry Pi 3/4:** die `.zip` des Releases entpacken und die `.img` darin auf die SD-Karte schreiben.
- **Virtuelle Maschine:** die `.ova` importieren (Proxmox, VMware, VirtualBox usw.). Das Image startet mit BIOS, so
  richtet die `.ova` die VM ein, und mit UEFI; für UEFI Secure Boot ausschalten (der Bootloader ist nicht signiert).
  Eine bestehende VM lässt sich auf UEFI umstellen, sobald sie eine Version mit UEFI-Unterstützung hat: ein Update
  bringt den UEFI-Bootloader mit. Unter Proxmox belässt `qm importovf` die Disk bei der Größe des Images, mit kaum
  Platz für Daten: vor dem ersten Start vergrößern, z. B. `qm resize <vmid> sata0 8G` (die Datenpartition übernimmt
  den Platz beim nächsten Start), oder die VM mit dem Skript unten anlegen, das das erledigt.
- **Proxmox per Skript:** als root auf dem Proxmox-VE-Host legt ein Skript die VM in einem Schritt an (`--help` zeigt
  die Optionen; `--bios ovmf` legt sie mit UEFI statt SeaBIOS an):
  `bash -c "$(wget -qLO - https://raw.githubusercontent.com/openccu-lite/openccu-lite/main/scripts/install-proxmox.sh)"`

## Wechsel von (Open)CCU zu openccu-lite

Der empfohlene Weg ist ein Update über das bestehende System.

- **Update:** In der WebUI unter *Einstellungen → Systemsteuerung → Zentralen-Wartung → Software-Update durchführen*
  die `openccu-lite-<produkt>-<version>.zip` hochladen, auf einer originalen CCU3 die `-ccu3.tgz`.
- **Kommt mit:** Anlernungen, Schlüssel, Addons, Namen, Räume und Gewerke. Programme und Systemvariablen übernimmt das
  Addon [Logic](https://github.com/openccu-lite/lite-addon-logic).
- **Entfällt:** Homematic-Scripte und Addons, die die ReGa brauchen, etwa CUxD.
- **Vorher sichern:** unbedingt ein Backup, für den schnellen Weg zurück zusätzlich ein Snapshot der VM oder eine Kopie
  der SD-Karte ([wie](docs/switching.de.md#zuerst-eine-kopie-des-ganzen-systems)).
- **Neue Hardware:** neu installieren und das Backup des alten Systems importieren.

Alles Weitere, auch der Weg zurück: [Wechsel von und zu OpenCCU](docs/switching.de.md).

## Updates

### So wird aktualisiert

Auf der Seite *Updates* der Weboberfläche: *Jetzt prüfen*, *Herunterladen und bereitstellen*, *Neu starten und
installieren*. Vor der Installation wird eine Sicherung auf die eingerichteten Sicherungsziele geschrieben und die
Prüfsumme kontrolliert. Per SSH geht dasselbe mit `occulited update check` und `occulited update install`
([Befehle und Optionen](https://github.com/openccu-lite/occulited/blob/master/docs/config.md)). Ohne Klick und ohne
Konsole, etwa aus Ansible oder mit Renovate, geht es über die HTTP-API:
[Updates aus einer Pipeline](docs/update-pipeline.de.md).

Welche Versionen angeboten werden, ist einstellbar: **stable** (nur fertige Releases, die Voreinstellung), **beta** (dazu
Beta- und Release-Candidate-Versionen) oder **dev** (alles, auch Entwicklungsstände).

### Was geplant ist

- **Mit jedem neuen HMIPServer von eQ-3 erscheint ein neues Release** von openccu-lite, damit neue HmIP-Geräte und
  Fehlerbehebungen von eQ-3 schnell ankommen. Ein neuer HMIPServer erhöht immer die Hauptversion (Major).
- **Die Schnittstellenprozesse rfd, hs485d und multimacd** kommen aus einem
  [eigenen Fork von OpenCCU-Base](https://github.com/openccu-lite/OpenCCU-Base). Er soll möglichst nah an OpenCCU bleiben;
  welche Änderungen von OpenCCU schon übernommen sind, zeigt ein [Abgleich](https://openccu-lite.github.io/OpenCCU-Base/).
- **Die Treiber für die Funkmodule aus piVCCU** (etwa `generic_raw_uart` und `hb_rf_eth`) kommen aus einem
  [eigenen Fork](https://github.com/openccu-lite/piVCCU). Er soll immer möglichst nah am Original von
  [Alexander Reinert](https://github.com/alexreinert/piVCCU) bleiben.
- **Ab Buildroot 2027.02 basiert openccu-lite auf den LTS-Versionen von Buildroot.** Sie werden länger mit
  Sicherheitsupdates versorgt; dazwischen bleibt das System auf einer gepflegten Basis, und deren Point-Releases
  lassen sich mit wenig Aufwand übernehmen.
- Ob die Bestandteile aktuell sind (Buildroot, Kernel, Firmware, Java, HMIPServer, OpenCCU-Base), zeigt eine täglich
  erneuerte [Übersicht](https://openccu-lite.github.io/openccu-lite/).

## Dokumentation

**Erste Schritte**
- [Rundgang durch die Weboberfläche](docs/walkthrough/README.md): jede Seite mit Bild
- [Wechsel von und zu OpenCCU](docs/switching.de.md)
- [Logic: Programme und Systemvariablen](https://github.com/openccu-lite/lite-addon-logic/blob/main/docs/de/handbuch.md),
  mit einem Kapitel für den Umstieg von einer CCU (Beta)
- [ioBroker: von einer CCU zu openccu-lite](docs/iobroker.de.md): der openccu-lite-Modus von hm-rpc, die Objekte bleiben
- [Empfehlungen](docs/recommendations.de.md)
- [Was sich gegenüber OpenCCU ändert](docs/aenderungen.md)
- [Funkmodule und multimacd: alle Einstellungen](docs/radio.md)

**Betrieb**
- [Lokaler Schlüsselmodus für HmIP](docs/lokaler-schluesselmodus.md): offlinefähig, Funkmodultausch ohne den
  Schlüsselserver von eQ-3
- [Zertifikate](docs/tls-acme.md) (eigene oder automatisch per ACME)
- [Updates aus einer Pipeline](docs/update-pipeline.de.md): API-Token, Shell-Skript, Ansible-Playbook, Renovate
- [occulite-backup](https://github.com/openccu-lite/occulite-backup): Sicherungen eines oder mehrerer Systeme per Cron
  oder Timer herunterladen

**Sicherheit und Datenschutz**
- [Sicherheit](docs/security.md) und [Bedrohungsmodell](docs/threat-model.md) (englisch)
- [Datenschutz](docs/privacy.md): was das System nach außen sendet (englisch)

**Für Addon-Entwickler und eigene Programme**
- [Addons auf openccu-lite](docs/addons.md) (englisch)
- [Portierungs-Kit: von ReGa zu openccu-lite](docs/porting-from-rega.md) (englisch)
- [ccu-addon-kit](https://github.com/hobbyquaker/ccu-addon-kit): Einstellungsseite, Dienststeuerung und Go-Bausteine
  für Addons
- [occulite-client](https://github.com/openccu-lite/occulite-client): der Client für die APIs von openccu-lite (npm)
- [occulited](https://github.com/openccu-lite/occulited): der Systemdienst; seine
  [Dokumentation](https://github.com/openccu-lite/occulited/tree/master/docs) beschreibt die Metadaten-, System- und
  Auth-API, `occulited.json`, das Addon-Manifest und den Katalog

## Fehler und Hilfe

Fehler und Wünsche, für die Firmware wie für occulited: der
[Issue-Tracker](https://github.com/openccu-lite/openccu-lite/issues) dieses Repositorys ([SUPPORT.md](SUPPORT.md));
Sicherheitsprobleme wie in [SECURITY.md](SECURITY.md) beschrieben. Tracker und Forumsbereich von OpenCCU sind für
OpenCCU da, Probleme mit openccu-lite bitte nicht dort melden.

## Danksagung

openccu-lite steht auf der Arbeit anderer. Danke an:

- **[eQ-3](https://www.eq-3.de/)**, dafür, dass sie rfd, hs485d und multimacd im Quelltext veröffentlicht haben.
- **[Jens Maus](https://github.com/jens-maus)** für seine Arbeit an [OpenCCU](https://github.com/OpenCCU/OpenCCU),
  ohne die openccu-lite nicht möglich gewesen wäre.
- **[Alexander Reinert](https://github.com/alexreinert)** für seine Treiber aus
  [piVCCU](https://github.com/alexreinert/piVCCU).
- **[Mathias Dzionsko](https://github.com/mdzio)** für das Go-Modul
  [go-hmccu](https://github.com/mdzio/go-hmccu).
- **Michael Gernoth** für [hmcfgusb](https://git.zerfleddert.de/cgi-bin/gitweb.cgi/hmcfgusb), mit dem sich die Firmware
  des HM-CFG-USB aktualisieren lässt.

## Lizenz

Apache-2.0 für alles hier Geschriebene; die `occu`-Bestandteile behalten die Bedingungen von eQ-3.

## Haftungsausschluss

openccu-lite wird OHNE JEDE AUSDRÜCKLICHE ODER IMPLIZIERTE GARANTIE bereitgestellt, einschließlich der Garantie zur
Benutzung für den vorgesehenen oder einem bestimmten Zweck sowie jeglicher Rechtsverletzung, jedoch nicht darauf
beschränkt. IN KEINEM FALL sind die Autoren oder Copyrightinhaber für jeglichen Schaden oder sonstige Ansprüche haftbar
zu machen, ob infolge der Erfüllung eines Vertrages, eines Deliktes oder anders im Zusammenhang mit der Software oder
sonstiger Verwendung der Software entstanden.
