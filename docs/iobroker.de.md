# ioBroker: von einer CCU3 oder OpenCCU zu openccu-lite

*Deutsch — die englische Fassung ist [iobroker.md](iobroker.md).*

Diese Anleitung ist für einen ioBroker, der heute über
[ioBroker.hm-rpc](https://github.com/ioBroker/ioBroker.hm-rpc) mit einer CCU3 oder OpenCCU spricht, eine Instanz je
Schnittstelle (BidCos-RF, HmIP-RF, vielleicht BidCos-Wired, VirtualDevices oder CUxD), und meist mit
[ioBroker.hm-rega](https://github.com/ioBroker/ioBroker.hm-rega) für Namen, Räume, Systemvariablen und Programme. Es
bleibt bei einer hm-rpc-Instanz je Schnittstelle, wie gewohnt. Den Wechsel der CCU selbst beschreibt
[switching.de.md](switching.de.md); diese Seite behandelt die Seite des ioBrokers.

Kurz gesagt: **Jede bestehende hm-rpc-Instanz wird auf den Dämon *openccu-lite* umgestellt und mit dem System
gekoppelt. Ihre Objekte behalten ihre IDs und damit History-Einstellungen, Aliase, Skripte und Visualisierungen.**
hm-rega und CUxD fallen weg.

## Was sich ändert

- **hm-rpc bleibt, mit dem Dämon *openccu-lite*.** Die Instanz erreicht die Schnittstelle über *lite-rpc* auf dem
  Webport des Systems (HTTPS, 443) mit einem eigenen API-Token; die Ereignisse kommen als Datenstrom, den die Instanz
  selbst öffnet. Einen Rückkanal gibt es nicht mehr: keine Adapteradresse, kein Adapterport, kein `init` und nichts,
  was in einer Firewall zum ioBroker hin freizugeben wäre. ioBroker darf hinter einem Router oder in einem
  Docker-Container laufen.
- **hm-rega fällt weg.** openccu-lite hat keine ReGa: keine Systemvariablen, keine Programme, kein HM-Script, keine
  Favoriten, keine Diagramme. **Namen, Räume und Gewerke** kommen jetzt aus den Metadaten des Systems, über hm-rpc
  selbst (die Option *Namen, Räume und Gewerke vom System übernehmen*). Beim Wechsel der CCU werden sie aus ihrer ReGa
  übernommen.
- **CUxD fällt weg.** Es braucht die ReGa und läuft auf openccu-lite nicht; seine hm-rpc-Instanz hat nichts mehr,
  womit sie sich verbinden könnte.
- **Die Geräte bleiben.** Der Wechsel behält die Anlernungen, die Schlüssel und die Geräteadressen, also behalten die
  Objekte `hm-rpc.<n>.<Adresse>.<Kanal>.<DATENPUNKT>` ihre IDs.

## Vorher

**Versionen:**

| Komponente | Nötig | Hinweise |
| --- | --- | --- |
| ioBroker.hm-rpc | **4.3.0 oder neuer** | die erste Version mit dem Dämon *openccu-lite*; zu einem später angelernten Gerät siehe [Bekannte Grenzen](#bekannte-grenzen) |
| ioBroker.discovery | 5.4.0 oder neuer | nur für Vorschläge neuer Instanzen; zum Umstellen bestehender nicht nötig |
| js-controller | 6.0.11 oder neuer | Voraussetzung von hm-rpc |
| Admin | 7.6.20 oder neuer (8.0.0 für discovery 5.4) | |
| Node.js | 22.19.0 oder neuer | Voraussetzung von hm-rpc und discovery |

Zum Zeitpunkt dieser Anleitung (November 2026) bietet das **stabile** Repository von ioBroker noch hm-rpc 4.1.2 und
discovery 5.2.0 an; hm-rpc 4.3.0 und discovery 5.4.1 stehen im **Beta-Repository (latest)**. Zum Installieren unter
*Systemeinstellungen → Repositories* das Repository umstellen, oder warten, bis sie im stabilen ankommen.

**Sicherungen:**

- **ioBroker:** eine vollständige Sicherung (etwa mit BackItUp), damit Objekte, Zustände und Adaptereinstellungen
  zurückkommen können.
- **Die CCU:** ein Backup (`.sbk`) und eine Kopie des ganzen Systems, wie
  [switching.de.md](switching.de.md#vor-dem-wechsel-prüfen) beschreibt. Das Backup ist der Weg zurück.

## Schritt 1: die CCU umstellen

Die CCU auf openccu-lite umstellen, wie [switching.de.md](switching.de.md) beschreibt: als Update über das bestehende
System oder als Neuinstallation mit Import des CCU-Backups. In beiden Fällen bleiben die Geräte angelernt, ihre
Adressen bleiben gleich, und Namen, Räume und Gewerke werden aus der ReGa übernommen.

Gleich nach dem Wechsel:

- **Die klassischen hm-rpc-Instanzen dürfen vorerst weiterlaufen.** Ließ die Firewall der OpenCCU Clients an die
  XMLRPC-Ports, schaltet openccu-lite klassisches RPC ein (siehe
  [Was sich beim ersten Start ändert](switching.de.md#was-sich-beim-ersten-start-ändert)), und die klassischen
  Instanzen verbinden sich wie bisher. Sonst verbinden sie sich erst wieder nach der Umstellung in Schritt 2.
- **hm-rega kann sich nicht mehr verbinden.** Seine Instanz anhalten; sie wird in Schritt 3 entfernt.
- **CUxD** steht auf der Addon-Seite des Systems als *deaktiviert, inkompatibel*. Seine hm-rpc-Instanz anhalten.

## Schritt 2: jede hm-rpc-Instanz umstellen

Das für jede hm-rpc-Instanz einer Schnittstelle tun, die das System betreibt (BidCos-RF, HmIP-RF, BidCos-Wired,
VirtualDevices). **Die bestehende Instanz umstellen, keine neue anlegen:** Eine neue Instanznummer bedeutet neue
Objekt-IDs (`hm-rpc.5.…` statt `hm-rpc.1.…`), und History-Einstellungen, Aliase und Skripte zeigten weiter auf die
alten.

1. **Prüfen, dass das System Kopplungen erlaubt:** auf dem System unter *System → Fernzugriff* die Einstellung
   *Programme dürfen um Zugriff bitten* (ab Werk an). Die Kopplungsanfrage muss aus den lokalen Netzen des Systems
   kommen.
2. Im ioBroker unter *Instanzen* die Einstellungen der hm-rpc-Instanz öffnen. **Die Instanz muss laufen** (die
   Kopplung läuft in ihr; eine klassische Instanz, die ihre CCU nicht mehr erreicht, ist in Ordnung).
3. **Dämon:** *openccu-lite* wählen. Die Einstellungen für den Rückkanal (Adapteradresse, Adapterport, Protokoll)
   verschwinden.
4. **HomeMatic Adresse:** Adresse oder Name des Systems, wie bisher.
5. Unter *Zusätzliche Einstellungen* **HTTPS verwenden** ankreuzen. Der Port folgt von selbst: 443 (ohne HTTPS 80).
6. Zurück unter *Allgemeine Einstellungen*: **Interface** ist die Schnittstelle des Systems, mit der sich diese Instanz
   verbindet (`HmIP-RF`, `BidCos-RF`, `BidCos-Wired`, `VirtualDevices`), eine je Instanz. Prüfen: Eine Instanz, die
   bisher *rfd* war, ist `BidCos-RF`, *hs485d* ist `BidCos-Wired`, *Virtual Devices* ist `VirtualDevices`.
7. **Namen, Räume und Gewerke vom System übernehmen** ist ab Werk angekreuzt; vor dem Beibehalten
   [Räume und Gewerke](#räume-und-gewerke) lesen.
8. **Koppeln** drücken. Unter dem Knopf erscheint ein sechsstelliger Code, mit einem Link zur Statusseite des Systems.
9. Auf der **Statusseite** des Systems, als einer seiner Administratoren: Die Anfrage nennt das Programm
   (`ioBroker.hm-rpc`), die Instanz (`hm-rpc.<n> on <Host>`) und den erbetenen Zugriff (Geräte: konfigurieren, Namen:
   lesen). **Den Code** mit dem im ioBroker **vergleichen**, dann genehmigen.
10. ioBroker fragt *Konfiguration speichern?*: speichern. Token und Fingerabdruck des Zertifikats des Systems stehen
    dann in der Instanz, und sie startet neu, jetzt über lite-rpc. Ihr Log meldet `lite-rpc client is connecting to
    https://<Adresse> for the interface <Schnittstelle>`, dann `Connected`.

Jede Instanz koppelt für sich und bekommt einen eigenen Token (die Seite *Fernzugriff* des Systems führt sie als
gekoppelte Programme). Statt zu koppeln, lässt sich ein von Hand unter *System → Fernzugriff* angelegter API-Token mit
den Scopes `rpc:configure` und `meta:read` ins Feld *Token* eintragen. Die Kopplung ist der einfachere Weg: Sie legt
auch das Zertifikat des Systems fest, das ein von Hand eingetragener Token ebenso braucht, sofern Node.js diesem
Zertifikat nicht vertraut.

**Was bleibt** (geprüft durch die Umstellung einer klassischen HmIP-RF-Instanz mit History-Einstellungen, einem Alias
und einem Raum an ihren Objekten):

- jede Objekt-ID mit Typ, Rolle und Datentyp: Geräte, Kanäle und Datenpunkte entstehen genauso wie mit einer CCU;
- die Custom-Einstellungen an den Zuständen (History, InfluxDB, SQL und ähnliche), die Aufzeichnung läuft also weiter;
- Aliase und Skripte, die die IDs verwenden, und Visualisierungen;
- die Werte: Die Instanz schreibt beim Verbinden die Werte, die das System hält, in die Zustände.

**Was sich ändert:**

- mit eingeschalteter Namensoption die Namen: Geräte und Kanäle heißen wie auf dem System, Datenpunkte
  `<Kanalname>.<DATENPUNKT>` (wie bei hm-rega); ein Gerät ohne Namen auf dem System behält seine Adresse;
- die Räume und Gewerke der Objekte der Instanz (nächster Abschnitt);
- *Geräte neu einlesen (einmalig)* ist nicht mehr nötig: Das System schickt seine Geräteliste bei jeder Verbindung der
  Instanz, und ein später angelerntes Gerät kommt von selbst.

## Räume und Gewerke

**Mit eingeschaltetem *Namen, Räume und Gewerke vom System übernehmen* bestimmt das System die Räume und Gewerke der
Objekte der Instanz.** hm-rpc legt für jeden Raum und jedes Gewerk des Systems eine Aufzählung an und hält ihre
Mitglieder aktuell, sofort, wann immer sich auf dem System etwas ändert:

- die IDs der Aufzählungen kommen aus der Taxonomie des Systems, etwa `enum.rooms.wohnzimmer`; ein Raum, der aus den
  eingebauten der CCU übernommen wurde, kann seinen internen Namen behalten, etwa `enum.rooms.roomgarage` (angezeigt
  als *Garage*). Ein Raum in einem Raum wird eine eigene Aufzählung, benannt nach seinem Pfad (`eg/wohnzimmer` →
  `enum.rooms.eg_wohnzimmer`);
- **die Objekte der Instanz werden aus allen anderen Raum- und Gewerk-Aufzählungen entfernt**, auch aus denen, die
  hm-rega angelegt hat, und aus selbst angelegten. Mitglieder anderer Adapter bleiben;
- Räume und Gewerke der Homematic-Geräte werden also ab jetzt auf dem System gepflegt: in seiner *Bedienung* oder im
  [Homematic Manager](https://github.com/hobbyquaker/homematic-manager). Die Änderung kommt sofort im ioBroker an.

**Die Aufzählungen von hm-rega** behalten ihre IDs (`enum.rooms.<Name wie in der CCU>`, für die eingebauten Räume das
englische Wort, etwa `enum.rooms.Kitchen`), verlieren aber ihre Homematic-Mitglieder, und derselbe Raum steht im
ioBroker zweimal, einmal leer. Prüfen, ob ein Skript oder eine Visualisierung eine solche Aufzählungs-ID verwendet (eine
Auswahl nach dem *Namen* eines Raums funktioniert weiter, wenn der Name gleich ist), dann die leeren unter *Objekte*
oder *Kategorien* löschen.

**Wer Namen und Räume weiter im ioBroker pflegen will,** nimmt das Häkchen vor dem Koppeln heraus. hm-rpc lässt Namen,
Räume und Gewerke dann in Ruhe: Die Namen von hm-rega bleiben, neue Geräte heißen nach ihrer Adresse.

Wird eine Instanz gelöscht, bleiben die Aufzählungen, die sie angelegt hat, leer zurück; sie von Hand löschen.

## Schritt 3: hm-rega und CUxD entfernen

- **hm-rega:** seine Instanz löschen (*Instanzen*, das Papierkorb-Symbol). Seine Objekte gehen mit: die
  Systemvariablen und Programme unter `hm-rega.<n>`. Skripte, die sie lesen oder setzen, brauchen vorher ein neues
  Zuhause.
- **CUxD:** seine hm-rpc-Instanz löschen.

| Auf der CCU (hm-rega) | Auf openccu-lite mit ioBroker |
| --- | --- |
| Namen von Geräten, Kanälen und Datenpunkten | die Namensoption von hm-rpc (oben) |
| Räume und Gewerke | die Namensoption von hm-rpc; gepflegt auf dem System |
| Systemvariablen | eigene Zustände im ioBroker (`0_userdata.0`) |
| Programme und ReGa-Skripte | ioBroker-Skripte (JavaScript- oder Blockly-Adapter) oder Node-RED (auf dem System als [RedMatic](https://github.com/rdmtc/RedMatic) oder im ioBroker) |
| Favoriten | werden nicht übernommen; die eigenen Ansichten der Visualisierung |
| CUxD-Geräte | kein Ersatz auf openccu-lite; ihre Aufgabe übernehmen eigene ioBroker-Adapter |
| die Servicemeldungen der CCU (UNREACH, LOWBAT, CONFIG_PENDING) | die Datenpunkte auf Kanal 0 jedes Geräts, wie bisher |

[porting-from-rega.md](porting-from-rega.md) (englisch) ordnet den Aufrufen der ReGa ihren Ersatz auf openccu-lite zu,
für Skripte, die direkt mit der CCU sprachen.

## Ein neuer ioBroker oder eine weitere Schnittstelle

- **Mit discovery** (5.4.0 oder neuer): Ein Scan erkennt openccu-lite an seiner offenen Versionsantwort und schlägt
  **eine hm-rpc-Instanz je Schnittstelle** vor, die das System betreibt, im openccu-lite-Modus, nie hm-rega oder eine
  klassische Instanz. Eine Schnittstelle, die für dieselbe Adresse schon eine Instanz abdeckt (eine klassische oder
  eine openccu-lite-Instanz), wird nicht noch einmal vorgeschlagen. Danach die Einstellungen jeder neuen Instanz öffnen
  und sie koppeln (Schritt 2, ab *Koppeln*). **discovery durchsucht nur das Netz, in dem der ioBroker steht:** Ein
  System in einem anderen Subnetz wird nicht gefunden.
- **Von Hand:** unter *Adapter* je Schnittstelle eine hm-rpc-Instanz hinzufügen und wie in Schritt 2 einrichten.

## Neue Geräte anlernen

hm-rpc lernt keine Geräte an. Anlernen mit dem [Homematic Manager](https://github.com/hobbyquaker/homematic-manager)
(als Addon auf dem System oder als Desktop-Anwendung) oder einem anderen Programm zur Geräteverwaltung wie
[OpenCCU-Loom](https://github.com/SukramJ/openccu-loom). Die Objekte des neuen Geräts erscheinen von selbst im
ioBroker, mit Namen und Räumen, sobald sie auf dem System gesetzt sind. Die erste Grenze unten beachten, solange sie für
die eigene Version gilt.

## Bekannte Grenzen

- **hm-rpc 4.3.0: Ein später angelerntes Gerät löscht die Objekte der übrigen Geräte der Instanz.** Die Objekte kommen
  beim nächsten Start der Instanz zurück, aber die Einstellungen an ihnen, etwa die History-Aufzeichnung, sind
  verloren. Behoben in Versionen nach 4.3.0. Bis dahin vor dem Anlernen eines Geräts unter *Zusätzliche Einstellungen*
  **Geräte nicht löschen** ankreuzen. Objekte von Geräten, die auf dem System gelöscht werden, bleiben dann im
  ioBroker; sie von Hand löschen.
- **discovery findet Systeme nur im eigenen Subnetz;** für ein System anderswo eine Instanz von Hand anlegen.
- **Keine ReGa:** hm-rega, CUxD, Systemvariablen, Programme und HM-Script gibt es nicht mehr (siehe Schritt 3).
- **hm-rpc älter als 4.3.0** kennt den Dämon *openccu-lite* nicht; vor dem Umstellen die Version prüfen (siehe
  [Vorher](#vorher)).
