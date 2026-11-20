# Updates aus einer Pipeline

*Deutsch — die englische Fassung ist [update-pipeline.md](update-pipeline.md).*

openccu-lite lässt sich ohne Klick in der Weboberfläche und ohne Konsole aktualisieren: Ein Skript, ein
Ansible-Playbook oder ein CI-Job ruft mit einem API-Token die HTTP-API des Systems auf. Zusammen mit einem Bot wie
[Renovate](https://docs.renovatebot.com/) ergibt das den im Homelab üblichen Ablauf: Die Version steht in einem
Git-Repository, der Bot öffnet einen Pull Request, sobald ein neues Release erscheint, und dessen Merge spielt das
Release aus.

Die API macht dasselbe wie die Seite *Updates*: Sie lädt das Release von GitHub, prüft es gegen seine veröffentlichte
SHA-256-Prüfsumme und startet das Wiederherstellungssystem, das das neue Image schreibt und die Benutzerpartition
behält (Einstellungen, Anlernungen, Addons, Sicherungen).

- [Das Token](#das-token)
- [Die Schritte](#die-schritte)
- [Ältere Versionen und Update-Kanäle](#ältere-versionen-und-update-kanäle)
- [Beispiel: ein Shell-Skript](#beispiel-ein-shell-skript)
- [Beispiel: ein Ansible-Playbook](#beispiel-ein-ansible-playbook)
- [Beispiel: Renovate](#beispiel-renovate)

## Das Token

Unter **System → Fernzugriff → API-Tokens** ein API-Token mit diesen Scopes anlegen:

| Scope | Nötig für |
| --- | --- |
| `system:read` | das Lesen der laufenden Version und der Sicherungsziele |
| `power` | den Download und die Installation |
| `backup` | die Sicherung vor der Installation (entfällt, wenn die Pipeline keine anlegt) |

Das Geheimnis (`olt_…`) wird nur einmal angezeigt. Es geht bei jeder Anfrage als `Authorization: Bearer <token>` mit.
Beim Anlegen am besten ein Ablaufdatum und den Adressbereich des Rechners setzen, auf dem die Pipeline läuft, und das
Token im Geheimnisspeicher ablegen (Ansible Vault, die Secrets der CI), nie im Repository. Eine Anfrage mit Token
braucht keinen weiteren Header; der Header `X-Occulite-Request` gilt nur für die Cookie-Sitzungen des Browsers.

Das System liefert HTTPS mit einem selbstsignierten Zertifikat aus, solange kein eigenes oder eines von einer
ACME-CA eingerichtet ist ([Zertifikate](tls-acme.md)). Den Client auf dieses Zertifikat verweisen (`curl --cacert`,
Ansibles `ca_path`), statt die Prüfung abzuschalten.

## Die Schritte

Alle Routen liegen unter `https://<system>/api/system/v1`. Jeder POST braucht einen Body; `{}`, wenn es nichts zu
sagen gibt. Fehler kommen als `{"error": "<code>", "message": "…"}`; ein `403` nennt den fehlenden Scope in `scope`.

**1. Laufende Version lesen.** `GET /system-update` → `running.lite` ist die Version von openccu-lite (`"2.0.0"`).
Ist es schon die festgelegte, gibt es nichts zu tun.

**2. Sichern (optional, empfohlen).** `POST /backup/run` startet eine Sicherung auf alle eingeschalteten
Sicherungsziele (Seite *Sicherung*) und antwortet sofort mit `202 {"started": true, "instance": "all"}`; `409 busy`,
solange eine Sicherung läuft. Es antwortet auch dann `202`, wenn kein Ziel eingeschaltet ist; deshalb vorher
`GET /backup/targets` prüfen: `targets[]` mit `enabled`. Danach `GET /backup/targets` abfragen, bis kein
eingeschaltetes Ziel mehr `state.state` `"running"` hat und bei jedem `last_backup.at` neuer ist als vor dem Start;
`last_backup.ok` sagt, ob die Datei dort angekommen ist. Eine Sicherung dauert je nach Größe von `/usr/local` unter
einer bis einige Minuten.

**3. Herunterladen.** `POST /system-update/download` mit `{"version": "2.0.0"}` lädt genau dieses veröffentlichte
Release für dieses System von GitHub, prüft es gegen seine veröffentlichte `.sha256` und stellt es bereit. Die Anfrage
kehrt zurück, wenn die Datei bereitliegt (je nach Leitung eine halbe bis einige Minuten; dem Client ein langes Timeout
geben): `200 {"version": "2.0.0", "sha256": "…", …}`. Fehler:

| Antwort | Bedeutung |
| --- | --- |
| `404 not_found` | GitHub führt diese Version für dieses System nicht |
| `502 download-failed` | der Download ist fehlgeschlagen, oder die `.sha256` des Releases war nicht lesbar (ungeprüft wird nichts bereitgestellt) |
| `502 feed-unreachable` | GitHub hat nicht geantwortet |
| `409 busy` | ein Download, ein Upload oder eine Installation läuft (`detail.phase`) |
| `422 no-space` | auf der Benutzerpartition ist kein Platz für die Datei |

`{"version": "latest"}` nimmt statt einer festen Version das neueste Release des Update-Kanals des Systems.

**4. Installieren.** `POST /system-update/install` → `200 {"armed": true, "rebooting": true}`. Das System startet ins
Wiederherstellungssystem, schreibt das neue Image und startet erneut. `409 nothing-staged` ohne Schritt 3, `409 busy`,
solange ein Download läuft oder eine Installation schon begonnen hat.

**5. Warten.** Die API ist einige Minuten nicht erreichbar oder antwortet mit `503`; beides heißt „noch nicht“.
`GET /system-update` alle paar Sekunden abfragen, bis es wieder antwortet und `running.lite` die festgelegte Version
ist. Auf einem Raspberry Pi 4 hat die ganze Installation etwa acht Minuten gedauert; 20 Minuten einplanen.

## Ältere Versionen und Update-Kanäle

**Ältere Versionen:** Schritt 3 nimmt jede veröffentlichte Version, auch eine ältere. Das ist der Weg zurück: die
vorige Version festlegen und dieselben Schritte ausführen. Einstellungen, die nur die neuere Version kennt, können
dabei verloren gehen; dafür ist die Sicherung aus Schritt 2 da.

**Update-Kanäle:** Eine festgelegte Version wird unabhängig vom Update-Kanal des Systems geladen, auch eine Beta. Der
Kanal (**stable**: nur Releases, die Voreinstellung; **beta**: auch Beta- und Release-Candidate-Versionen; **dev**:
alles) zählt für `"latest"` und für die Seite *Updates*; er wird dort eingestellt oder mit
`PUT /system-update/settings {"channel": "beta"}` (`power`).

## Beispiel: ein Shell-Skript

`openccu-lite-update.sh 2.0.0` aktualisiert ein System mit `curl` und `jq` und bricht beim ersten Fehler ab; aufrufen
aus einem CI-Job oder einem Timer.

```sh
#!/bin/sh
# Update an openccu-lite system to a pinned version through its HTTP API.
#   OCCU_URL=https://ccu.example OCCU_TOKEN=olt_... ./openccu-lite-update.sh 2.0.0
# Needs curl and jq. OCCU_BACKUP=0 skips the backup; OCCU_CURL_OPTS adds curl options,
# e.g. "--cacert /path/to/ccu.pem" for the system's own certificate.
set -eu

VERSION=${1:?usage: $0 <version, e.g. 2.0.0>}
VERSION=${VERSION#v}
API="${OCCU_URL:?set OCCU_URL}/api/system/v1"
: "${OCCU_TOKEN:?set OCCU_TOKEN}"
BACKUP=${OCCU_BACKUP:-1}

api() { # method path [json body]; prints the answer, fails on an HTTP error
  body=${3:-'{}'}
  # shellcheck disable=SC2086
  curl -sS --fail-with-body ${OCCU_CURL_OPTS:-} -X "$1" \
    -H "Authorization: Bearer $OCCU_TOKEN" -H 'Content-Type: application/json' \
    --data "$body" --max-time "${MAXTIME:-60}" "$API$2"
}
get() { # path
  # shellcheck disable=SC2086
  curl -sS --fail-with-body ${OCCU_CURL_OPTS:-} -H "Authorization: Bearer $OCCU_TOKEN" \
    --max-time 20 "$API$1"
}
running() { get /system-update | jq -r '.running.lite'; }

now=$(running)
if [ "$now" = "$VERSION" ]; then
  echo "already on $VERSION"
  exit 0
fi
echo "running $now, installing $VERSION"

if [ "$BACKUP" = 1 ]; then
  # POST /backup/run answers 202 even when no target is enabled: check first.
  before=$(get /backup/targets | jq -c '[.targets[] | select(.enabled) | {id, at: .last_backup.at}]')
  [ "$before" != "[]" ] || { echo "no backup target is enabled (Backup page), or set OCCU_BACKUP=0" >&2; exit 1; }
  api POST /backup/run >/dev/null
  echo "backup started"
  i=0
  while :; do
    sleep 5
    i=$((i + 5))
    [ "$i" -le 1800 ] || { echo "backup not done after 30 minutes" >&2; exit 1; }
    # done when no enabled target is running and each has a newer result than before
    get /backup/targets | jq -e --argjson before "$before" '
      [.targets[] | select(.enabled)] as $t
      | ($t | all(.state.state != "running"))
        and ($t | all(. as $x | .last_backup.at != null
              and .last_backup.at != ($before[] | select(.id == $x.id) | .at)))' >/dev/null || continue
    break
  done
  get /backup/targets | jq -e '[.targets[] | select(.enabled) | .last_backup | select(.ok)] | length > 0' >/dev/null \
    || { echo "no target holds the new backup, nothing installed" >&2; exit 1; }
  echo "backup done"
fi

# Downloads the release from GitHub and checks it against its published .sha256 (minutes on a slow line).
MAXTIME=1800 api POST /system-update/download "{\"version\": \"$VERSION\"}" | jq -c '{version, sha256}'
api POST /system-update/install >/dev/null
echo "installing, the system reboots"

sleep 60
i=60
until [ "$(running 2>/dev/null || true)" = "$VERSION" ]; do
  sleep 10
  i=$((i + 10))
  [ "$i" -le 1200 ] || { echo "not on $VERSION after 20 minutes" >&2; exit 1; }
done
echo "running $VERSION after ${i}s"
```

## Beispiel: ein Ansible-Playbook

Das Playbook läuft auf dem Steuerrechner (`delegate_to: localhost`); die Systeme brauchen nur ihre API. Das Inventar
nennt jedes System mit URL, Token und festgelegter Version:

```yaml
# inventory.yml
openccu_lite:
  hosts:
    ccu:
      openccu_lite_url: https://ccu.example
      openccu_lite_token: "{{ vault_openccu_lite_token }}"
```

```yaml
# group_vars/openccu_lite.yml
# renovate: datasource=github-releases depName=openccu-lite/openccu-lite
openccu_lite_version: 2.0.0
```

```yaml
# openccu-lite-update.yml
# Update openccu-lite systems to the version pinned in openccu_lite_version.
#   ansible-playbook -i inventory.yml openccu-lite-update.yml
# Per host: openccu_lite_url (https://ccu.example), openccu_lite_token (an API token with
# system:read, power and backup - keep it in Ansible Vault), openccu_lite_version, and
# openccu_lite_ca (optional) for the system's own certificate.
- name: Update openccu-lite
  hosts: openccu_lite
  gather_facts: false
  serial: 1
  vars:
    api: "{{ openccu_lite_url }}/api/system/v1"
    headers:
      Authorization: "Bearer {{ openccu_lite_token }}"
    validate_certs: true
    backup: true
  tasks:
    - name: Read the running version
      delegate_to: localhost
      ansible.builtin.uri:
        url: "{{ api }}/system-update"
        headers: "{{ headers }}"
        validate_certs: "{{ validate_certs }}"
        ca_path: "{{ openccu_lite_ca | default(omit) }}"
      register: state

    - name: Update when the pinned version differs
      when: state.json.running.lite != openccu_lite_version
      delegate_to: localhost
      block:
        - name: Read the backup targets
          when: backup | bool
          ansible.builtin.uri:
            url: "{{ api }}/backup/targets"
            headers: "{{ headers }}"
            validate_certs: "{{ validate_certs }}"
            ca_path: "{{ openccu_lite_ca | default(omit) }}"
          register: before

        - name: Note each enabled target's last result
          when: backup | bool
          ansible.builtin.set_fact:
            old_ats: "{{ before.json.targets | selectattr('enabled') | map(attribute='last_backup.at', default='') | list }}"

        - name: Require an enabled backup target
          when: backup | bool
          ansible.builtin.assert:
            that: before.json.targets | selectattr('enabled') | list | length > 0
            fail_msg: No backup target is enabled (Backup page); set backup=false to skip the backup.

        - name: Start a backup to every enabled target
          when: backup | bool
          ansible.builtin.uri:
            url: "{{ api }}/backup/run"
            method: POST
            headers: "{{ headers }}"
            body_format: json
            body: {}
            status_code: 202
            validate_certs: "{{ validate_certs }}"
            ca_path: "{{ openccu_lite_ca | default(omit) }}"

        - name: Wait until every enabled target has a new result
          when: backup | bool
          ansible.builtin.uri:
            url: "{{ api }}/backup/targets"
            headers: "{{ headers }}"
            validate_certs: "{{ validate_certs }}"
            ca_path: "{{ openccu_lite_ca | default(omit) }}"
          register: after
          vars:
            enabled: "{{ after.json.targets | selectattr('enabled') | list }}"
            new_ats: "{{ enabled | map(attribute='last_backup.at', default='') | list }}"
          until: >-
            enabled | selectattr('state.state', 'eq', 'running') | list | length == 0
            and '' not in new_ats and new_ats | intersect(old_ats) | length == 0
          retries: 360
          delay: 5

        - name: Require that a target holds the new backup
          when: backup | bool
          ansible.builtin.assert:
            that: after.json.targets | selectattr('enabled') | map(attribute='last_backup.ok') | select | list | length > 0
            fail_msg: No target holds the new backup; nothing installed.

        - name: Download and verify the release
          ansible.builtin.uri:
            url: "{{ api }}/system-update/download"
            method: POST
            headers: "{{ headers }}"
            body_format: json
            body:
              version: "{{ openccu_lite_version }}"
            timeout: 1800
            validate_certs: "{{ validate_certs }}"
            ca_path: "{{ openccu_lite_ca | default(omit) }}"
          register: staged

        - name: Install it (the system reboots)
          ansible.builtin.uri:
            url: "{{ api }}/system-update/install"
            method: POST
            headers: "{{ headers }}"
            body_format: json
            body: {}
            validate_certs: "{{ validate_certs }}"
            ca_path: "{{ openccu_lite_ca | default(omit) }}"

        - name: Give the system time to go down
          ansible.builtin.pause:
            seconds: 60

        - name: Wait until the pinned version runs
          ansible.builtin.uri:
            url: "{{ api }}/system-update"
            headers: "{{ headers }}"
            timeout: 10
            validate_certs: "{{ validate_certs }}"
            ca_path: "{{ openccu_lite_ca | default(omit) }}"
          register: now
          until: now.json is defined and now.json.running.lite == openccu_lite_version
          retries: 120
          delay: 10
```

`ansible-playbook -i inventory.yml openccu-lite-update.yml -e backup=false` lässt die Sicherung weg. Für das
selbstsignierte Zertifikat des Systems `openccu_lite_ca` auf eine Kopie davon setzen (oder beim Ausprobieren
`-e validate_certs=false`).

## Beispiel: Renovate

Renovate hält `openccu_lite_version` aktuell. Der Kommentar über der Variable nennt die Datenquelle: die Releases von
`openccu-lite/openccu-lite` auf GitHub. Ein eigener Regex-Manager in `renovate.json` liest ihn:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "customManagers": [
    {
      "customType": "regex",
      "description": "openccu-lite version pinned in Ansible vars",
      "managerFilePatterns": ["/(^|/)(group|host)_vars/.+\\.ya?ml$/"],
      "matchStrings": [
        "# renovate: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)\\s+\\S+:\\s*\"?(?<currentValue>[^\\s\"]+)\"?"
      ],
      "versioningTemplate": "semver",
      "extractVersionTemplate": "^v(?<version>.+)$"
    }
  ]
}
```

- **Das Präfix `v`:** Die Release-Tags heißen `v2.0.0`; `extractVersionTemplate` entfernt das `v`, die Variable trägt
  also `2.0.0`, wie die API es erwartet.
- **Vorabversionen** (Betas, Release Candidates) erscheinen auf GitHub als Pre-Release und mit einem Vorabteil in der
  Version (`2.0.0-beta.10`). Renovate überspringt sie standardmäßig (`ignoreUnstable`). Wer den Betas folgen will,
  ergänzt:

  ```json
  "packageRules": [
    {
      "matchDepNames": ["openccu-lite/openccu-lite"],
      "ignoreUnstable": false
    }
  ]
  ```

- **Ältere Renovate-Versionen** nennen das Dateimuster `fileMatch` (ein einfacher Regex-String) statt
  `managerFilePatterns`.
- Nach dem Merge des Pull Requests führt die Pipeline das Playbook (oder das Skript) mit der neuen Version aus.

Die Renovate-Konfiguration ist ein Beispiel: Regex und JSON sind geprüft, ein Lauf von Renovate damit nicht.
