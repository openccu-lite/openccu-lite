# Updating from a pipeline

*English — the German version is [update-pipeline.de.md](update-pipeline.de.md).*

openccu-lite can be updated without a person at the web interface or on the console: a script, an Ansible playbook
or a CI job calls the system's HTTP API with an API token. Together with a bot such as
[Renovate](https://docs.renovatebot.com/) that is the usual homelab flow: the version lives in a Git repository, the
bot opens a pull request when a new release is out, and merging it rolls the release out.

The API does what the *Updates* page does: it downloads the release from GitHub, checks it against its published
SHA-256 checksum, and reboots into the recovery system, which writes the new image and keeps the user partition
(settings, pairings, addons, backups).

- [The token](#the-token)
- [The steps](#the-steps)
- [Older versions and channels](#older-versions-and-channels)
- [Example: a shell script](#example-a-shell-script)
- [Example: an Ansible playbook](#example-an-ansible-playbook)
- [Example: Renovate](#example-renovate)

## The token

Create an API token on **System → Remote access → API tokens** with these scopes:

| Scope | Needed for |
| --- | --- |
| `system:read` | reading the running version and the backup targets |
| `power` | the download and the install |
| `backup` | the backup before the install (leave it out if the pipeline takes none) |

The secret (`olt_…`) is shown once. Send it as `Authorization: Bearer <token>` on every request. Give it an expiry and
the address range of the machine that runs the pipeline when you create it, and keep it in your secret store (Ansible
Vault, the CI's secrets), never in the repository. A request with a token needs no other header; the header
`X-Occulite-Request` is only for the browser's cookie sessions.

The system serves HTTPS with a self-signed certificate unless you set up your own or one from an ACME CA
([Certificates](tls-acme.md)). Point the client at that certificate (`curl --cacert`, Ansible's `ca_path`) instead of
switching the check off.

## The steps

All routes are under `https://<system>/api/system/v1`. Every POST needs a body; send `{}` when there is nothing to
say. Errors come as `{"error": "<code>", "message": "…"}`; a `403` names the missing scope in `scope`.

**1. Read the running version.** `GET /system-update` → `running.lite` is openccu-lite's version
(`"2.0.0"`). When it already is the pinned one, there is nothing to do.

**2. Back up (optional, recommended).** `POST /backup/run` starts a backup to every enabled backup target (Backup page)
and answers `202 {"started": true, "instance": "all"}` at once; `409 busy` while a backup is running. It also answers
`202` when no target is enabled, so check `GET /backup/targets` first: `targets[]` with `enabled`. Then poll
`GET /backup/targets` until no enabled target has `state.state` `"running"` and each one's `last_backup.at` is newer
than before the run; `last_backup.ok` says whether the file reached that target. A backup takes from under a minute to
several minutes, depending on the size of `/usr/local`.

**3. Download.** `POST /system-update/download` with `{"version": "2.0.0"}` downloads exactly that published release
for this system from GitHub, checks it against its published `.sha256`, and stages it. The request returns when the
file is staged (half a minute to several minutes, depending on the line; give the client a long timeout):
`200 {"version": "2.0.0", "sha256": "…", …}`. Errors:

| Answer | Meaning |
| --- | --- |
| `404 not_found` | GitHub lists no such version for this system |
| `502 download-failed` | the download failed, or the release's `.sha256` could not be read (nothing is staged unverified) |
| `502 feed-unreachable` | GitHub did not answer |
| `409 busy` | a download, an upload or an install is running (`detail.phase`) |
| `422 no-space` | the user partition has no room for the file |

`{"version": "latest"}` takes the newest release of the system's update channel instead of a pinned one.

**4. Install.** `POST /system-update/install` → `200 {"armed": true, "rebooting": true}`. The system reboots into the
recovery system, writes the new image and reboots again. `409 nothing-staged` without step 3, `409 busy` while a
download runs or an install has already started.

**5. Wait.** The API is unreachable for a few minutes or answers `503`; treat both as "not yet". Poll
`GET /system-update` every few seconds until it answers again and `running.lite` is the pinned version. On a
Raspberry Pi 4 the whole install took about eight minutes; allow 20.

## Older versions and channels

**Older versions:** step 3 takes any published version, an older one too. That is the rollback: pin the previous
version and run the same steps. Settings that only the newer version knows may be lost on the way back, which is what
the backup in step 2 is for.

**Channels:** a pinned version is downloaded whatever the system's update channel is, a beta too. The channel
(**stable**: releases only, the default; **beta**: also beta and release-candidate versions; **dev**: everything)
matters for `"latest"` and for the *Updates* page; it is set there or with
`PUT /system-update/settings {"channel": "beta"}` (`power`).

## Example: a shell script

`openccu-lite-update.sh 2.0.0` updates one system with `curl` and `jq` and stops at the first error; run it from a CI
job or a timer.

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

## Example: an Ansible playbook

The playbook runs on the control node (`delegate_to: localhost`); the systems need nothing but their API. The inventory
names each system with its URL, token and pinned version:

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

`ansible-playbook -i inventory.yml openccu-lite-update.yml -e backup=false` skips the backup. For the system's
self-signed certificate set `openccu_lite_ca` to a copy of it (or `-e validate_certs=false` while you try it out).

## Example: Renovate

Renovate keeps `openccu_lite_version` current. The comment above the variable names the data source: the releases of
`openccu-lite/openccu-lite` on GitHub. A custom regex manager in `renovate.json` reads it:

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

- **The `v` prefix:** the release tags are `v2.0.0`; `extractVersionTemplate` strips the `v`, so the variable carries
  `2.0.0` as the API expects it.
- **Pre-releases** (betas, release candidates) are published as GitHub pre-releases with a prerelease part in the
  version (`2.0.0-beta.10`). Renovate skips them by default (`ignoreUnstable`). To follow the betas as well, add:

  ```json
  "packageRules": [
    {
      "matchDepNames": ["openccu-lite/openccu-lite"],
      "ignoreUnstable": false
    }
  ]
  ```

- **Older Renovate versions** name the file pattern `fileMatch` (a plain regex string) instead of
  `managerFilePatterns`.
- Once the pull request is merged, the pipeline runs the playbook (or the script) with the new version.

The Renovate configuration is an example: the regex and the JSON were checked, a Renovate run against it was not.
