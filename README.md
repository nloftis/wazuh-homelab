# wazuh-homelab

A Wazuh SIEM/XDR homelab deployment, built as two independent, interchangeable
deployment paths — pick whichever fits your infrastructure, or compare both.
Everything after Wazuh is reachable (agent enrollment, OPNsense integration,
dashboard usage) is identical regardless of which path stood it up.

## Deployment paths

| Path | Status | What it demonstrates |
|---|---|---|
| [`terraform-vm/`](./terraform-vm/) | 🔁 Proven, reproducible on demand — currently torn down | Terraform/libvirt IaC — a KVM VM provisioned end-to-end with cloud-init, no manual OS install |
| [`docker-compose/`](./docker-compose/) | ✅ Working, fully deployed — primary always-on path | Lightweight always-on deployment on existing NAS hardware, alongside existing telemetry stack |

**Why two paths, not one:** `terraform-vm/` proved out real IaC skills but
only runs when its hypervisor host is powered on — a real gap for a tool
whose value depends on continuous monitoring. `docker-compose/` targets
always-on hardware instead. Once `docker-compose/` was working, running
`terraform-vm/` continuously alongside it stopped making operational
sense — duplicate resource cost (4 vCPU/8GB/100GB) for a second manager
doing the same job as the one that's actually always-on. `terraform-vm/`
was deliberately torn down (`terraform destroy`) rather than left
running: the demonstrated IaC skill isn't lost by destroying the
instance — every `.tf` file, the version-pinned provider config, and the
full troubleshooting history in `terraform-vm/README.md` are still
git-tracked and reproducible on demand (`terraform apply`), verifiable by
anyone without paying the ongoing cost of running it 24/7 for no
operational reason.

**Versions are independent and will drift.** Each path pins its own Wazuh
image/package versions and is upgraded manually, on its own schedule —
neither auto-updates, and nothing keeps them in sync. `terraform-vm/` was
last deployed on **4.14.7**, matched deliberately to `docker-compose/` at
the time — but since it's currently torn down, treat that as a snapshot
of what it *was* running, not a live fact; check `terraform-vm/README.md`
before assuming anything about its version if it's ever redeployed.
(`docker-compose/` deliberately sets `pull_policy: never` on every
container specifically to prevent an unplanned version jump via
Container Manager or DSM — upgrades there require manually pulling new
image tags and editing `docker-compose.yml`, mirroring `terraform-vm/`'s
already-pinned-by-Terraform discipline.)

## After either path: agent deployment and dashboard usage

See [`docs/post-deployment.md`](./docs/post-deployment.md) — deploying
agents to monitored hosts, installing the `os-wazuh-agent` OPNsense
plugin, and a tour of what's actually useful in the dashboard. This is
the same regardless of which deployment path got you here. Three agents
are active against `docker-compose/`'s manager (the only one currently
running): Windows 11, the Pop!_OS hypervisor host, and OPNsense itself
via its dedicated plugin. `terraform-vm/`'s manager would need a fresh
`terraform apply` before any of this applies to it again.

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
