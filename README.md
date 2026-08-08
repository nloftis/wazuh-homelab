# wazuh-homelab

A Wazuh SIEM/XDR homelab deployment, built as two independent, interchangeable
deployment paths — pick whichever fits your infrastructure, or compare both.
Everything after Wazuh is reachable (agent enrollment, OPNsense integration,
dashboard usage) is identical regardless of which path stood it up.

## Deployment paths

| Path | Status | What it demonstrates |
|---|---|---|
| [`terraform-vm/`](./terraform-vm/) | ✅ Working, fully deployed | Terraform/libvirt IaC — a KVM VM provisioned end-to-end with cloud-init, no manual OS install |
| [`docker-compose/`](./docker-compose/) | ✅ Working, fully deployed | Lightweight always-on deployment on existing NAS hardware, alongside existing telemetry stack |

**Why two paths, not one:** `terraform-vm/` proved out real IaC skills but
only runs when its hypervisor host is powered on — a real gap for a tool
whose value depends on continuous monitoring. `docker-compose/` targets
always-on hardware instead. Rather than choosing one and discarding the
other's demonstrated skill, both are kept as independently valid,
independently documented approaches to the same goal — different
infrastructure patterns, same end result.

**Versions are independent and will drift.** Each path pins its own Wazuh
image/package versions and is upgraded manually, on its own schedule —
neither auto-updates, and nothing keeps them in sync. Both happen to be on
**4.14.7** as of this writing, matched deliberately when `docker-compose/`
was built, but don't assume that stays true without checking each path's
own README. (`docker-compose/` deliberately sets `pull_policy: never` on
every container specifically to prevent an unplanned version jump via
Container Manager or DSM — upgrades there require manually pulling new
image tags and editing `docker-compose.yml`, mirroring `terraform-vm/`'s
already-pinned-by-Terraform discipline.)

## After either path: agent deployment and dashboard usage

See [`docs/post-deployment.md`](./docs/post-deployment.md) — deploying
agents to monitored hosts, installing the `os-wazuh-agent` OPNsense
plugin, and a tour of what's actually useful in the dashboard. This is
the same regardless of which deployment path got you here, and is the
current next step for both paths — neither has agents enrolled yet.

## Repo structure

```
wazuh-homelab/
├── README.md                  # This file
├── terraform-vm/              # Path 1: Terraform + libvirt VM (working)
│   ├── main.tf / variables.tf / providers.tf / outputs.tf
│   ├── cloud-init/*.tftpl
│   ├── README.md              # Architecture, every real problem hit and
│   │                          # how it was resolved
│   └── WAZUH-CONFIG.md        # Application-layer install narrative
├── docker-compose/            # Path 2: Docker on Synology (working)
│   ├── docker-compose.yml
│   ├── generate-indexer-certs.yml
│   ├── config/                # From official wazuh-docker v4.14.7,
│   │                          # unmodified except docker-compose.yml itself
│   └── README.md              # Architecture, every adaptation from the
│                              # official file and why, every problem hit
└── docs/
    └── post-deployment.md     # Deployment-agnostic: agents, OPNsense, dashboard
```
