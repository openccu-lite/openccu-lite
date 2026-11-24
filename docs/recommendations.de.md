# Empfehlungen

Was sich im Betrieb von openccu-lite bewährt hat: die Hardware, VM oder eigene Hardware, der Funk, ungenutzte
Funkstandards, der Schlüssel des HmIP-Netzes und die Sicherungen.

## Hardware

Am zuverlässigsten läuft openccu-lite auf einer **originalen CCU3** oder einem **ELV „Charly“** – also einem
**Raspberry Pi 3 B (nicht 3 B+) mit [RPI-RF-MOD](https://de.elv.com/search?q=rpi-rf-mod&ms=true)** auf der GPIO-Leiste.
Das Funkmodul hängt dort ohne USB- oder Netzwerkschicht direkt am System, und der Pi 3 B stört den 868-MHz-Funk am
wenigsten.

* Gute Erfahrungen mit einem **PoE-Splitter**, ähnlich z. B. [dieser](https://de.aliexpress.com/item/1005008712707676.html). 
* **Gehäuse** für Pi und RPI-RF-MOD [„Raspberrymatic CCU3 Case Upgrade RPI-RF-MOD“](https://www.thingiverse.com/thing:4146052) von raabi91 und moclub.

## Virtuelle Maschine oder eigene Hardware

**Empfehlung: für ein Produktivsystem eigene Hardware statt einer VM.** openccu-lite gibt es als VM-Image (OVA), und
dieses Image wird unterstützt: Es wird vor jeder Veröffentlichung getestet, und Fehler darin werden behoben. Viele
betreiben ihre Zentrale so, und zwar erfolgreich und stabil. Für ein System, auf das sich das Haus verlässt, ist der
Betrieb auf eigener Hardware aber die ruhigere Wahl:

* **Der Funk ist zeitkritisch.** Auf einer CCU3 oder einem Charly hängt das Funkmodul direkt an der seriellen
  Schnittstelle des Systems. In einer VM liegen dazwischen der Hypervisor und je nach Funkmodul USB-Durchreichung oder
  das Netzwerk zu einem HB-RF-ETH. Jede dieser Schichten kann kurz hängen, etwa wenn der Host ausgelastet ist, ein
  Backup läuft oder ein USB-Gerät kurz verschwindet. Bei BidCos bleibt für die Bestätigung eines Telegramms nur ein
  Zeitfenster von Millisekunden. Was zu spät kommt, wiederholt das Gerät oder meldet es als nicht erreichbar.
* **Strom und Standort sprechen nicht für die VM.** Wer die VM mit einem HB-RF-ETH betreibt, hat ohnehin ein eigenes
  Gerät mit Funkmodul im Haus. An dessen Stelle kann genauso gut ein Raspberry Pi 3 B mit RPI-RF-MOD stehen, also die
  ganze Zentrale. Der Unterschied im Stromverbrauch ist aus meiner Sicht nicht wesentlich, und der Ort, der für den Funk
  günstig ist, bleibt derselbe.

Wer trotzdem eine VM betreibt: das Funkmodul möglichst per Netzwerk (HB-RF-ETH) oder per USB fest durchgereicht
anbinden und der VM eigene CPU-Anteile geben.

## Funk

**Bei vielen Geräten: HmIP und BidCos auf getrennte Funkmodule legen.** Standardmäßig bedient das RPI-RF-MOD beide
Funkstandards, und die teilen sich dann seinen Duty Cycle. Das reicht für die meisten Installationen. Wer viele Geräte
hat und merkt, dass der Duty Cycle zum Problem wird, gibt BidCos ein zweites Funkmodul. Dann hat jeder Funkstandard
sein eigenes Modul und seinen eigenen Duty Cycle, und das RPI-RF-MOD bedient HmIP direkt, ohne multimacd.

Das ist ein Kompromiss: Das zweite Funkmodul hängt wieder per USB oder Netzwerk am System, mit genau den Schichten, die
der Abschnitt oben bei der VM nennt. Für BidCos empfehle ich ein **HM-MOD-RPI-PCB** auf einem **HB-RF-USB** (USB) oder
**HB-RF-ETH** (Netzwerk). Vorhandene HM-LGW-O-TW-W-EU (Funk-LAN-Gateway) oder HM-CFG-USB-2 (mit der Firmware von
Michael Gernoth) funktionieren ebenso, sind aber nur noch gebraucht zu bekommen.

**Raspberry Pi 4 oder 5: bei gestörtem Funk das Ethernet auf 100 Mbit/s begrenzen.** Gigabit-Ethernet kann auf diesen
Boards den 868-MHz-Funk stören: Der Netzwerkchip und sein Kabel strahlen in diesem Bereich ab, bei 100 Mbit/s nicht.
*System → Netzwerk → Ethernet-Geschwindigkeit* stellt die Schnittstelle von „automatisch“ auf „100 Mbit/s“; sie handelt
die Verbindung weiter mit dem Switch aus, bietet aber nichts Schnelleres an. Für eine Zentrale reichen 100 Mbit/s. Die
Einstellung gibt es nur an einer Schnittstelle, die Gigabit kann.

## Ungenutztes Funkprotokoll abschalten

**Empfehlung: einen Funkstandard, den keines der Geräte nutzt, abschalten.** Wer kein BidCos-Gerät hat, stellt
*Schnittstellen → BidCos-RF* auf „Aus (nur HmIP)“. Das RPI-RF-MOD bedient dann nur HmIP, und multimacd fällt weg:
hmipserver spricht das Funkmodul direkt an, eine Schicht weniger, die Fehler einführen könnte. (Ein HM-MOD-RPI-PCB
braucht multimacd auch für HmIP allein.)

Umgekehrt schaltet *HmIP-RF* → „Keins (nur virtuelle Geräte)“ HmIP ab, wenn es kein HmIP-Gerät gibt: hmipserver läuft
dann als HMServer.jar mit etwa halb so viel Speicher. Ohne HmIP-Funkmodul ist das nötig, denn HMIPServer.jar startet
ohne sein Modul nicht. Alle Einstellungen: [radio.md](radio.md).

## Lokaler Schlüsselmodus

**Empfehlung: auf einer Neuinstallation den lokalen Schlüsselmodus für HmIP einschalten** – im Willkommensassistenten
oder später auf der Seite Schlüssel. Der Netzwerkschlüssel des HmIP-Netzes gehört dann dem System statt dem Funkmodul:
HmIP funktioniert ohne Internet, und ein Tausch des Funkmoduls braucht den Schlüsselserver von eQ-3 nicht, der einen
solchen Tausch auch ablehnen kann.

Am besten gleich zu Beginn, solange noch kein HmIP-Gerät angelernt ist: dann kostet der Modus nichts. Eine bestehende
Installation muss beim Umstieg jedes HmIP-Gerät einmal neu anlernen. Die Geräteschlüssel (QR-Code bzw. KEY vom
Aufkleber) am besten gleich beim Anlernen auf der Seite Schlüssel erfassen; ohne Schlüsselserver nimmt das System ein
Gerät nur mit seinem Schlüssel an.

Das Risiko: der Schlüssel steht im Klartext in jeder Sicherung – Sicherungen deshalb verschlüsselt anlegen und sicher
aufbewahren. Außerdem ist der lokale Schlüsselmodus kein von eQ-3 offiziell unterstützter Betriebsmodus. Alles Weitere
in [lokaler-schluesselmodus.md](lokaler-schluesselmodus.md).

## Sicherungen

**Empfehlung: nächtlich, verschlüsselt und außerhalb des Systems sichern.** Die Seite Sicherung legt die nächtliche
Sicherung auf einem Sicherungsziel ab – einem USB-Stick oder einer Freigabe im Netz, nicht auf dem System selbst, mit dem
sie sonst zusammen verloren geht. Die *Verschlüsselung* auf derselben Seite schützt, was in einer Sicherung steht: die
Funkschlüssel, die Zugangsdaten und die Zertifikate. Den Wiederherstellungsschlüssel (Notfallkit) getrennt vom System
aufbewahren, etwa in einem Passwort-Manager: ohne ihn lässt sich eine verschlüsselte Sicherung auf keinem anderen
System einspielen, und auf diesem nicht mehr, sobald sein Speicher verloren ist.

**Von einem anderen Rechner abholen:** Wer die Sicherung lieber von einem Server oder NAS aus holt (cron, systemd-Timer,
Synology, QNAP), nimmt [occulite-backup](https://github.com/openccu-lite/occulite-backup): ein Shell-Skript, das mit
einem API-Token, das nur Sicherungen darf, eine frische Sicherung herunterlädt, sie prüft und die neuesten N behält;
eine verschlüsselte Sicherung bleibt verschlüsselt.
