# Post-deployment: agents, OPNsense, and dashboard basics

Everything in this file applies once Wazuh's manager and dashboard are up
and reachable — it doesn't matter whether that came from `terraform-vm/`
or `docker-compose/`. Only the manager's IP/hostname changes between the
two paths; everything below is the same either way.

## 1. Deploy Wazuh agents to monitored hosts

**Status: three agents active**, all reporting to `docker-compose/`'s
manager (`192.168.20.10`) — currently the only live manager, since
`terraform-vm/` is torn down. From the dashboard: **Agents summary →
Deploy new agent**. This generates an install command specific to the
target OS, pre-filled with this manager's address — copy/paste and run
on each host you want monitored.

| Agent | Host | OS | Segment | Notes |
|---|---|---|---|---|
| `win11-vm` | `192.168.10.11` | Windows 11 Enterprise | PC | KVM VM on the Pop!_OS host |
| `popos-hypervisor` | `192.168.10.10` | Pop!_OS 22.04 LTS | PC | The actual daily-driver/hypervisor host — heavier initial FIM baseline scan (~700MB RAM during first `syscheckd` run), settles after |
| `OPNsense.home.arpa` | `192.168.20.1` | BSD 15.1 | NAS-reachable | Installed via the `os-wazuh-agent` community plugin, not a generic agent — see section 2 |

Each agent needs outbound reachability to the manager on:
- **TCP/UDP 1514** — event/log data
- **TCP 1515** — agent registration/enrollment
- **TCP 55000** — Wazuh API

All three targets above turned out to already be reachable without any
new OPNsense firewall rule — confirmed via `Test-NetConnection` (Windows)
and `nc -zv` (Pop!_OS) before installing, rather than assumed. PC segment
rules were already permissive enough. If a future target needs a rule
added, the `terraform-vm/README.md` Troubleshooting section has real
examples of what that looked like for that deployment.

**Deliberately deferred, not forgotten:** Synology NAS and the ParrotOS
pentesting VM. NAS was investigated and set aside — Wazuh's official
Docker agent image explicitly cannot monitor its host system (only its
own container), and DSM has no native Wazuh package; worth revisiting
only if a genuinely DSM-compatible install path turns up. ParrotOS
wasn't pursued because it's a dedicated, non-persistent pentesting
environment — not running long enough for continuous monitoring to add
much value. Neither is planned work right now; add them later if that
changes.

## 2. Install the `os-wazuh-agent` OPNsense plugin

**Status: done.** This is a community plugin (`System → Firmware →
Plugins → "Click to view the community plugins"` — not in the core
plugin list), maintained closely enough with OPNsense's own docs
(`docs.opnsense.org/manual/wazuh-agent.html`) to be a reasonable trust
level, distinct from a random unmaintained third-party addon.

**Real install notes:**
- Installed version was `wazuh-agent 4.14.6` — one patch version behind
  the manager's `4.14.7`. OPNsense's own package repo, not something
  configurable at install time. Shows as a red-dot version mismatch
  indicator in the dashboard's agent list — cosmetic, agent still
  reports `active` and functions normally.
- The install output showed `Reloading template OPNsense/WazuhAgent: ERR`
  during the post-install reload — looked alarming but turned out to be
  a one-time hiccup; **Services → Wazuh Agent → Settings** loaded and
  saved cleanly afterward with no further issues.
- Ignore the generic FreeBSD post-install message about manually editing
  `ossec.conf.sample` / `client.keys.sample` — that's boilerplate for
  installing the base `wazuh-agent` package standalone. The plugin's own
  GUI (`Services → Wazuh Agent → Settings`) handles all of that
  configuration instead; hand-editing those files would fight the
  plugin, not complement it.

**Configuration actually used:**
- **Manager hostname:** `192.168.20.10`
- **Enrollment password:** left blank — the manager runs open/
  unauthenticated enrollment (confirmed by both other agents enrolling
  without one; the four rotated Wazuh passwords from earlier are a
  completely separate mechanism — dashboard/API/indexer auth, not agent
  registration)
- **Applications selected:** `firewall`, `filter` (filterlog), `resolver`
  (unbound), `kernel`, `dhcpd` — matched to what's actually running on
  this box (ISC DHCP, not Kea; no Suricata/IDS actively enabled yet, no
  VPN). Re-visit this list if any of those services' status changes
  (e.g. Suricata gets turned on, or a future migration to Kea).
- **Intrusion detection events:** enabled — currently a no-op since
  Suricata/IDS isn't active, but will start working automatically
  whenever that's turned on, with nothing to come back and toggle.
- **Active response:** enabled, with **repeated offenders** escalation
  set to `30,60,120` (minutes) — deliberately conservative given this
  protects a home network with family devices on it, not a lab with only
  disposable targets. A misfire that escalates a block on a real
  device's IP is a worse outcome here than in a typical SOC lab. Revisit
  after a week or two of real false-positive-rate data if longer
  escalation feels warranted.

Confirm events are actually flowing under **Threat Intelligence → Threat
Hunting** or the relevant dashboard module — installed and configured
isn't the same confirmation as "actually forwarding data."

## 3. OPNsense generic syslog forwarding — considered, not pursued

OPNsense also has a separate, generic syslog forwarder
(`System → Settings → Logging/Syslog`) that can send raw syslog over
UDP/TCP 514 to any external receiver — a different mechanism from the
`os-wazuh-agent` plugin configured above, which sends parsed,
application-tagged logs over the agent's own connection (port 1514).

**Deliberately not used here, for two concrete reasons:**

1. Host port `514:514/udp` was dropped entirely from `docker-compose/`'s
   manager (see that path's README) specifically because the telemetry
   stack's Alloy container already owns port 514 for its own OPNsense
   syslog forwarding. The manager doesn't have this port open to receive
   anything even if this were configured.
2. It would be redundant with what's already flowing. The plugin's
   Applications selection (`firewall`, `filter`, `resolver`, `dhcpd`,
   `kernel`) already covers the same underlying log sources — just
   delivered via the agent connection instead of raw syslog. Turning
   this on too would mean sending the same data twice through two
   different pipes.

Revisit only if a specific log source turns out to *not* be covered by
the plugin's Applications list and genuinely needs raw syslog instead —
not as a default "more coverage is better" addition.

## 4. Dashboard basics — where things live

- **Agents summary** (Overview) — registered agent count and status.
- **Endpoint Security** section — Configuration Assessment, Malware
  Detection, File Integrity Monitoring (this is what would have caught
  the OPNsense API key exposure from an earlier project, in real time,
  had Wazuh already been running).
- **Threat Intelligence** section — Threat Hunting (browse alerts),
  Vulnerability Detection (CVEs tied to actually-installed packages),
  MITRE ATT&CK mapping.
- **Security Operations** section — IT Hygiene, PCI DSS, GDPR, HIPAA —
  compliance-framework views, useful as a hardening checklist even
  without a formal compliance requirement driving it.

## 5. Verifying remediation: forcing a rescan after patching

**Why this matters:** Vulnerability Detection shows CVEs tied to
*currently installed* package versions. Patching a flagged package
doesn't update the dashboard instantly — the pipeline has two separate
stages that both need to complete first:

1. **Syscollector (on the agent) needs to re-inventory the host.** By
   default this runs on its own interval, but it also runs on agent
   start (`scan_on_start`). Fastest way to force it on demand:
   restarting the agent service, or — more reliably, at least on
   Windows — restarting the whole VM. A Windows Services-panel restart
   of the Wazuh agent was seen to leave the service stopped rather than
   restarted once (had to be started manually afterward); a full VM
   restart worked cleanly and is the more dependable option if that
   happens again.
2. **The manager's correlation cycle needs to re-run separately**, using
   the freshly reported inventory against the CVE feed. This is not
   instant after step 1 — expect roughly the same interval seen between
   feed-update log entries (`grep -i vulnerab wazuh-manager/logs/ossec.log`
   shows real timestamps to gauge this against).

**Confirming the agent actually came back after a restart**, from the
manager:
```bash
sudo docker exec wazuh.manager /var/ossec/bin/agent_control -i <agent_id>
```
Check for `Status: Active` and a recent `Last keep alive` — don't assume
a restart succeeded without checking, given the Windows service quirk
above.

**Real example — win11-vm, Aug 9, 2026:** starting point was 29 High /
25 Medium severity findings, driven largely by outdated Foxit PDF
Reader, Notepad++, 7-Zip, and a few Microsoft components. Two rounds of
patching were verified end-to-end through this exact loop:

- Manually updating Foxit PDF Reader and Notepad++ dropped High severity
  to 5 and cleared both packages from the Top 5 list.
- `winget upgrade --all` (PowerShell) cleared 7-Zip, App Installer,
  K-Lite Codec Pack, Microsoft Teams, VC++ Redistributable, VSTOR, and
  QEMU Guest Agent in one pass — worth noting `winget upgrade --all`
  silently *doesn't* surface every installed package (IrfanView didn't
  appear at all, despite being flagged in the dashboard); Microsoft
  Store's own "Get updates" button is the fallback check for anything
  winget doesn't see.
- One update in that batch (QEMU Guest Agent, `7.4.5 → 110.0.2`) looked
  like a suspicious version-numbering jump at a glance. Checking the
  actual install source (Fedora's official virtio-win distribution,
  `fedorapeople.org/.../archive-qemu-ga/`) confirmed it was legitimate —
  just a different upstream versioning scheme, not a mismatched package.
  Worth checking the source URL before trusting a big/odd version jump,
  rather than assuming winget picked the wrong thing.
- Post-update check: `QEMU-GA` service confirmed `Running`; the
  `QEMU Guest Agent VSS Provider` service showed `Stopped` / `Manual`
  startup — this is expected, on-demand behavior (only starts when a
  snapshot request actually comes in), not a broken update.

This is a reusable loop for any future flagged CVE: patch → force a
rescan → wait for correlation → re-check the dashboard for the same
agent, rather than trusting "patched" without confirming the tool
actually saw it.

### Residual findings after patching: not everything is a real vuln

After the patching round above, win11-vm still showed 10 findings across
3 packages — worth triaging individually rather than assuming they're
all real, since not every flagged CVE survives scrutiny:

- **7-Zip 26.02 / `CVE-2026-58052`, Low severity** — the CVE's own
  description states the affected range as "7-Zip for Windows through
  26.01," and the installed version is 26.02. Likely already resolved;
  low priority either way given Low severity. Worth re-checking after
  the feed's next update in case the affected-version boundary was
  still being finalized at disclosure time.
- **IrfanView 64-bit App / 7 CVEs (all pre-2013)** — **confirmed false
  positive.** Checked the actual installed version via Help → About:
  `4.72` (Wazuh's inventory reports it as `4.7.2.0`). Every flagged CVE's
  stated affected range ("before 4.27," "before 4.32," "before 4.33,"
  "before 4.37") is well below the real installed version. Most likely
  cause: the correlation engine doing a naive/lexicographic version
  comparison rather than proper semantic comparison, or misparsing the
  four-segment `4.7.2.0` string against the vendor's actual two-segment
  ("4.72") versioning. No action needed on the host — nothing to patch,
  since the installed version is already current. If Wazuh exposes a
  false-positive/suppress action on findings, use it here with a note
  referencing this section; otherwise this doc entry is the record.
- **QEMU guest agent 110.0.2 / `CVE-2023-1386` (High), `CVE-2021-20255`
  (Medium)** — **suspected false positive, not yet independently
  confirmed.** Same suspected root cause as IrfanView: `110.0.2` is a
  Fedora virtio-win build number (see the QEMU version-jump note above),
  not a QEMU core version, so a feed comparing against QEMU's real
  version history may be matching incorrectly. Not yet verified the way
  IrfanView was — next step is checking which actual QEMU/virtio-win
  release build `110.0.2` corresponds to, and confirming whether
  CVE-2023-1386 and CVE-2021-20255 were already fixed well before that
  release. Treat as unresolved/unconfirmed until that check is done —
  don't assume false positive on this one without doing the legwork.

**Takeaway for future findings:** a CVE showing up doesn't automatically
mean action is needed. Always check the CVE's own stated affected-version
range against the real, human-readable version of the software (About
dialog, vendor changelog) before assuming it's real — non-standard or
multi-segment version strings are a known source of false positives in
automated correlation.

## 6. First-week checklist

- [x] All target hosts show as "Active" agents, not just "Registered" —
      `win11-vm`, `popos-hypervisor`, `OPNsense.home.arpa` all confirmed
      active.
- [x] At least one FIM alert confirmed — validated Aug 12, 2026 on
      `popos-hypervisor` via `/etc/fim-test.txt`.

      **First attempt looked like a failure, wasn't:** created the test
      file, then restarted the agent to force a scan. The file showed up
      in the agent's local FIM database (`fim.db`, confirmed via
      `sqlite3`) with a full baseline checksum record, but no alert fired
      in `alerts.json` or the dashboard. Same result after a follow-up
      on-demand scan via the API (`PUT /syscheck?agents_list=<id>`).

      **Root cause:** the scan that first observes a file after an agent
      (re)start is a *baseline* scan — new files get silently absorbed
      into the database to establish the starting state, not reported as
      alerts. Only *differential* scans (comparing against an already-
      established baseline) generate alerts. Creating a file and
      restarting in the same step puts creation and first-observation in
      the same scan, which looks like baseline-building rather than a
      detected change — a real gotcha worth knowing before assuming FIM
      isn't working during future testing.

      **Confirmed real detection** by modifying the already-baselined
      test file and triggering a scan via the API *without* restarting:
      rule `550` ("Integrity checksum changed") fired correctly, with
      full before/after detail on size, mtime, and all three hashes
      (md5/sha1/sha256). Verified independently at three layers — the
      manager's raw `alerts.json`, the dashboard Events tab, and the
      agent-side `fim.db` record.

      **Takeaway for future validation or troubleshooting:** to test FIM
      cleanly, modify a file that's already part of an established
      baseline and trigger a scan without restarting the agent. Don't
      create-then-restart in the same step — that exercises baseline
      logic, not detection.
- [x] OPNsense plugin confirmed forwarding events, not just installed —
      confirmed Aug 9, 2026 via rule `87702` ("Multiple pfSense firewall
      blocks events from same source") firing repeatedly across a full
      overnight window on real, varied `filterlog` block events, not
      merely agent status. Two concrete examples pulled and correctly
      attributed: an external TCP SYN probe against the WAN interface
      (`199.45.155.72 → 98.151.66.213:80`, repeated blocked SYNs — routine
      internet background scanning), and an internal NBNS broadcast block
      from the HP OfficeJet Pro 8028 printer (`192.168.1.20 → 
      192.168.1.255:137/udp`, benign local chatter). Both distinguishable
      at a glance once `data.srcip`/`data.dstip`/`data.dstport`/
      `data.protocol` are added as columns in the Events table.
- [x] Vulnerability Detection module has completed at least one scan
      cycle per agent — confirmed Aug 9, 2026. Full pipeline verified via
      manager logs (CVE feed pulling successfully), indexer document
      counts (2,724 packages indexed via Syscollector; 62 real
      vulnerabilities correlated), and Discover queries against
      `wazuh-states-vulnerabilities-*`. Results currently isolated to
      `win11-vm` (agent 001) — includes flagged CVEs for 7-Zip, Foxit PDF
      Reader, and Visual Studio Tools for Office Runtime. `popos-hypervisor`
      (agent 002) legitimately shows zero matches — consistent with a
      well-patched Ubuntu-based system, not a detection gap (confirmed via
      `agent.id:002` returning 0 hits in Discover). `OPNsense.home.arpa`
      (agent 003) doesn't participate in this module — the plugin doesn't
      report a package inventory in a format Syscollector/Vulnerability
      Detection can consume; both its Dashboard and Inventory tabs are
      empty by design, not by error.
