# Post-deployment: agents, OPNsense, and dashboard basics

Everything in this file applies once Wazuh's manager and dashboard are up
and reachable — it doesn't matter whether that came from `terraform-vm/`
or `docker-compose/`. Only the manager's IP/hostname changes between the
two paths; everything below is the same either way.

## 1. Deploy Wazuh agents to monitored hosts

From the dashboard: **Agents summary → Deploy new agent**. This generates
an install command specific to the target OS, pre-filled with this
manager's address — copy/paste and run on each host you want monitored.

Planned initial targets:
- Synology NAS
- OPNsense firewall (see the dedicated plugin section below — handled
  differently from a standard agent)
- Windows 11 VM

Each agent needs outbound reachability to the manager on:
- **TCP/UDP 1514** — event/log data
- **TCP 1515** — agent registration/enrollment
- **TCP 55000** — Wazuh API

Whatever network segment each target host lives on, confirm an OPNsense
rule permits it to reach the manager on those three ports. (The
`terraform-vm/README.md` Troubleshooting section has real examples of
what this looked like for that specific deployment — same principle
applies regardless of which path stood up the manager.)

## 2. Install the `os-wazuh-agent` OPNsense plugin

OPNsense has a maintained plugin (`os-wazuh-agent`) specifically for
forwarding firewall/VPN/config-change events into Wazuh, rather than
treating OPNsense as a generic host running a standard agent.

- **System → Firmware → Plugins**, search for `os-wazuh-agent`, install.
- Configure it with the manager's IP and the ports above.
- Confirm events start appearing under **Threat Intelligence → Threat
  Hunting** or the relevant module in the dashboard.

## 3. Configure OPNsense syslog forwarding (optional, complements the plugin)

Beyond the dedicated plugin, OPNsense can also forward general syslog
data: **System → Settings → Logging/Syslog** (menu path may vary by
OPNsense version — see the note in `terraform-vm/README.md` about menu
locations shifting between versions), pointed at the manager's IP.

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

## 5. First-week checklist

- [ ] All target hosts show as "Active" agents, not just "Registered."
- [ ] At least one FIM alert confirmed (e.g. deliberately edit a
      monitored file, confirm it shows up).
- [ ] OPNsense plugin confirmed forwarding events, not just installed.
- [ ] Vulnerability Detection module has completed at least one scan
      cycle per agent.
- [ ] Resume framing reviewed: "SIEM/log analysis (Wazuh, OpenSearch)" —
      describe the capability, not just the product name.
