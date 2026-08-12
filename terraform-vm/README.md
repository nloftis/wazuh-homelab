# terraform-vm — Wazuh via Terraform + libvirt

**Status: proven, reproducible on demand — currently torn down.** This
path was deliberately destroyed (`terraform destroy`) once
`docker-compose/` proved out as the always-on path — running two live
managers doing the same job made no operational sense, and this VM only
ever ran when its hypervisor host was powered on anyway. Nothing below
was lost by destroying it: every `.tf` file, the version-pinned provider
config, and the full troubleshooting history are still git-tracked and
reproducible on demand (`terraform apply`) — this documents the real
deployment that happened, not a live one you'd currently reach at the
IPs referenced below.

One of two deployment paths in this repo — see the [top-level
README](../README.md) for how this relates to the `docker-compose/`
path and what comes after either one. This document covers the
Terraform/libvirt VM path specifically: full architecture, every real
problem hit during deployment, and how each was resolved.

Terraform-provisioned Wazuh SIEM/XDR deployment, deployed as a
KVM/libvirt VM on a Pop!_OS host — same macvtap-bridged VM pattern used
elsewhere in this homelab. Parallel to, not merged with, the existing
Grafana/Loki/Alloy observability stack on the Synology NAS.

## Architecture

- **Topology:** Monolithic single-node (manager + indexer + dashboard on one
  VM). Chosen over a distributed multi-node layout for faster time-to-value;
  single-node comfortably supports homelab-scale agent counts.
- **VM sizing:** 4 vCPU / 8GB RAM / 100GB disk — sized around the OpenSearch
  indexer's resource needs, the heaviest component of the stack.
- **OS:** Ubuntu Server 24.04 LTS (cloud image), provisioned via cloud-init —
  no manual console install.
- **Disk location:** `/mnt/data/VMs/` via the existing `default` libvirt pool
  (confirmed via `virsh pool-dumpxml default` to already target this exact
  path) — same location other VMs on this host already store their disks.
  Referenced by name only (`var.libvirt_pool_name`, a plain string); this
  provider has no data source for looking up an existing pool, so Terraform
  never creates, owns, or could accidentally destroy the `default` pool
  itself — it only places new volumes inside it.
- **Network:** macvtap in bridge mode against the host's physical NIC,
  landing the VM on OPNsense's **PC** segment via real DHCP — the same
  bridging pattern already used by other VMs on this host. NAS segment was
  the original preference (groups this with other "infra" services rather
  than trusted personal devices) but isn't physically reachable from this
  host: PC/NAS/LAN/WAN are separate physical ports on the router, not VLANs
  on a shared trunk, and the host only has one NIC. Revisit if a second NIC
  gets added to the host.

## Prerequisites

1. `tenv` will pick up `.terraform-version` (`1.15.8`) automatically.
2. `genisoimage` must be installed — the libvirt provider shells out to its
   `mkisofs` binary to build the cloud-init seed ISO:
   ```
   sudo apt install genisoimage
   ```
3. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in your SSH
   public key (already gitignored, safe to leave real values in it).
4. Confirm libvirt group membership works without sudo:
   ```
   virsh list --all
   ```
5. **Have a second device ready to SSH from.** Macvtap in bridge mode
   (used here — see "Network" above) typically cannot reach the VM
   directly from the Pop!_OS host itself, even though the VM is fully
   reachable from everything else on the network — confirmed via OPNsense
   ping (0% loss) succeeding while `ssh` from the host fails with "No
   route to host." This isn't a bug to fix before deploying; it's a
   structural property of macvtap. Line up access from another machine
   (phone, laptop, or another VM on this same host via Spice console —
   see "Troubleshooting" below) before you need to actually log in, rather
   than discovering it after `apply`.

## Deploy

```
terraform init
terraform plan
terraform apply
```

Running this now would create a fresh VM — there's currently nothing
live to connect to until `apply` completes. Expect a new IP on the PC
segment (not necessarily matching any IP referenced below, which
reflects the last real deployment, not a guaranteed-stable address).

## After apply — manual steps (not managed by Terraform)

1. **Find the VM's IP.** With `wait_for_lease = true` now set (see "Known
   limitations" below), `terraform apply` blocks until the IP is known and
   surfaces it directly — no manual DHCP-lease lookup needed. If it's ever
   needed anyway: `terraform output mac_address`, then check OPNsense's
   DHCP leases for that MAC.
2. **Add an OPNsense firewall rule for SSH admin access.** Needed for
   basic administration in the first place (see "Troubleshooting" below —
   direct Pop!_OS-to-VM access doesn't work at all due to macvtap): SSH
   TCP 22, at minimum from NAS (or whichever segment you'll actually
   administer from), scoped to this VM's specific IP.

   Agent traffic ports, syslog forwarding, and the rest of what's needed
   to make this VM actually function as a SIEM — not just reachable —
   are deployment-agnostic and documented once in
   [`../docs/post-deployment.md`](../docs/post-deployment.md), not
   repeated here.
3. **Install Wazuh.** Cloud-init only prepares the base OS (user, SSH key,
   qemu-guest-agent, package updates). Wazuh itself installs via SSH once
   the VM is reachable — not yet scripted into this Terraform config. See
   "Troubleshooting" below for the actual working SSH access path (direct
   access from the Pop!_OS host does not work), and
   [`WAZUH-CONFIG.md`](./WAZUH-CONFIG.md) for the actual install steps
   and what to expect.

## Known limitations / deferred decisions

- **`wait_for_lease` was initially disabled**, then re-enabled once
  confirmed working. At first, automated IP detection via
  `qemu-guest-agent` hadn't been tested in this environment over macvtap,
  so `apply` was kept from potentially hanging indefinitely. Once the VM
  was up and cloud-init had run, `virsh domifaddr wazuh-manager --source
  agent` correctly returned the guest's real IP — confirming agent-based
  detection works here. `wait_for_lease = true` is now set in `main.tf`,
  so `apply` will block until the IP is known rather than requiring a
  manual OPNsense DHCP-lease lookup afterward. If a future `apply` ever
  hangs here (e.g. guest-agent fails to install/start), the manual lookup
  via `terraform output mac_address` + OPNsense's DHCP leases still works
  as a fallback.

## Temporary changes made outside this repo — RESOLVED

**Update:** the Synology jump-host workaround below was needed only until
it was confirmed that other VMs on this same host (e.g. Windows11) *can*
reach `wazuh-manager` directly over macvtap — guest-to-guest traffic
isn't subject to the same host-isolation limitation that blocks the
Pop!_OS host itself (see Troubleshooting below). Once that was confirmed,
all six items below were reverted, in the correct order (config revert
before disabling SSH, so access wasn't cut before the revert could be
made):

1. ✅ `ssh-keygen -R 192.168.10.12` run on Synology — stale `known_hosts`
   entry removed.
2. ✅ `AllowTcpForwarding` reverted `yes` → `no` in
   `/etc/ssh/sshd_config`, `sshd` restarted to apply it.
3. ✅ SSH service disabled again on Synology (DSM Control Panel →
   Terminal & SNMP).
4. ✅ Both OPNsense firewall rules deleted (NAS → `192.168.10.12` TCP/22
   and TCP/443).

**Current working access path:** SSH and dashboard access now go through
another VM on this same host (e.g. Windows11 → `192.168.10.12` directly,
guest-to-guest over the shared macvtap interface) instead of through
Synology. Synology is back to its normal, hardened configuration —
SSH disabled, no forwarding permitted, no lingering firewall holes.

<details>
<summary>Original workaround steps (kept for reference, no longer active)</summary>

Not managed by Terraform, not undone by `terraform destroy`, and not
visible anywhere in this repo's files.

### Synology (NAS)

1. **SSH service enabled** — DSM Control Panel → Terminal & SNMP → "Enable
   SSH service" checked.
2. **`AllowTcpForwarding` changed `no` → `yes`** in `/etc/ssh/sshd_config`,
   to permit the port-forwarding tunnel to the dashboard.
3. **`sshd` restarted** to apply the above.
4. **`known_hosts` entry for `192.168.10.12`** added to `synadmin`'s
   `~/.ssh/known_hosts`.

### OPNsense

5. **Firewall rule: NAS → `192.168.10.12` TCP/22 (SSH)** — the one
   actually required, since SSH was the only way to run the Wazuh
   installer at all.
6. **Firewall rule: NAS → `192.168.10.12` TCP/443 (HTTPS)** — not
   required to stand up Wazuh itself, only used for one dashboard
   verification session via the Synology tunnel, before Windows11's
   direct guest-to-guest access was discovered and became the real path.

</details>

## Troubleshooting

Issues actually hit during the first deploy, in case they recur (e.g. on a
fresh host, or after an OS/libvirt upgrade):

### Provider pinned to `~> 0.8.0`, not latest — do not "helpfully" bump this

`providers.tf` deliberately constrains the libvirt provider to the 0.8.x
line. This was not the original intent — the first draft of this project
used `version = "~> 0.8"` (two version components), which was assumed to
mean "any 0.8.x release." It doesn't: Terraform's `~>` operator only locks
the *rightmost given component*, so a two-component constraint like
`~> 0.8` actually means "≥0.8.0, <1.0.0" — any 0.x release. `terraform
init` correctly (if unhelpfully) resolved that to `0.9.8`, the newest
version satisfying the constraint as written.

`0.9.0` turned out to be a deliberate, ground-up rewrite of the provider —
the maintainer's own release notes open with *"⚠️ This version of the
provider breaks compatibility ⚠️."* Every resource schema changed: nested
blocks (`network_interface { }`, `disk { }`, etc.) became list-of-object
arguments, a required `type` argument appeared on `libvirt_domain`, IP
address lookup moved to a separate data source, and so on. Running
`terraform validate` against 0.9.8 produced a long list of "unsupported
argument" / "unsupported block type" errors on config that was actually
correct for the 0.8.x schema it was written against.

By the maintainer's own admission in the release discussion, 0.9.x still
had open bugs and thin documentation as of this writing. Given this is a
learning project already juggling several new concepts (libvirt,
cloud-init, macvtap) at once, the decision was to pin to the last stable
0.8.x release (`~> 0.8.0`, three components, correctly constraining to
"≥0.8.0, <0.9.0") rather than rewrite everything against a newer,
less-proven schema. Revisit this once 0.9.x has matured, if there's a
specific reason to (e.g. a libvirt feature only the new schema exposes).

### `Could not open '.../ubuntu-24.04-base.qcow2': Permission denied`

**Looks like** a plain Unix file-permissions problem, but check AppArmor
first — it produces the identical generic "Permission denied" message.
Confirm which one you're actually dealing with:

```
sudo dmesg | grep -i apparmor | tail -20
```

If you see a line like:
```
apparmor="DENIED" operation="open" ... name="/mnt/data/VMs/..." comm="qemu-system-x86"
```
that's decisive — it's AppArmor, not standard `chmod`/`chown` permissions.
(In this case, plain Unix permissions on the file were already correct —
`-rw-r--r-- libvirt-qemu kvm`, confirmed via `namei -l` — the block was
happening at the AppArmor/MAC layer on top of otherwise-valid permissions.)

**Root cause:** Debian/Ubuntu-family systems confine each QEMU process with
a dynamically generated AppArmor profile that only allows access to paths
it already knows about — typically just the default
`/var/lib/libvirt/images`. A custom pool path like `/mnt/data/VMs` isn't
automatically included.

**Fix** — add the custom pool path to libvirt's AppArmor local override:
```
sudo nano /etc/apparmor.d/local/abstractions/libvirt-qemu
```
Add (note the trailing comma — required AppArmor rule syntax):
```
/mnt/data/VMs/** rwk,
```
Then reload:
```
sudo systemctl reload apparmor
```
One-time fix — covers every future VM using this same pool, not just this
one.

### `domain 'wazuh-manager' already exists with uuid ...`

Happens if `libvirt_domain` creation fails *after* libvirt has already
registered the domain definition but *before* Terraform could save its ID
to state (e.g. the AppArmor denial above happening mid-creation). Result:
libvirt has an orphaned domain definition; Terraform's state doesn't know
about it, so `plan` still shows `1 to add` instead of recognizing it
already exists.

**Fix** — remove the orphaned definition so Terraform can create it fresh:
```
virsh undefine wazuh-manager --nvram
```
The `--nvram` flag matters specifically because this VM boots UEFI (its
`libvirt_domain` config shows `nvram = (known after apply)`, not legacy
BIOS) — a stray NVRAM variable file can get created alongside the domain
definition, and omitting `--nvram` leaves that file behind to cause a
similar conflict later. Safe to do since a domain that failed this early
never actually finished booting — there's no real VM state to lose.

### SSH from the host itself fails: `No route to host`

**Status: confirmed — macvtap host-isolation, not a firewall or config
problem.**

`virsh domifaddr wazuh-manager --source agent` correctly returns a real
DHCP-assigned IP on the PC segment, and `ssh` from the Pop!_OS host to that
IP fails with "No route to host." Pinging the same IP **from OPNsense
itself** (Interfaces → Diagnostics → Ping) succeeds with 0% packet loss —
confirming the VM is genuinely up, correctly networked, and reachable from
the rest of the network. The failure is isolated specifically to
host-to-guest communication on this one interface.

This matches a known macvtap limitation, and virt-manager's own UI warns on
this exact interface type — *"In most configurations, macvtap does not
work for host to guest communication."* Macvtap in bridge mode gives a VM
its own identity directly on the physical link, but by design typically
excludes the host's own network stack from that same bridge.

**Practical implication:** administer this VM (and any future macvtap-
bridged VM on this host) from another device on the network — a laptop,
phone, or via OPNsense's own tools — not directly from the Pop!_OS host
itself. If host-to-guest access from Pop!_OS is ever needed, the fix isn't
a firewall rule; it requires a different interface type (e.g. a libvirt
bridge device instead of macvtap), which is a separate, deliberate network
reconfiguration, not something to change casually given the other VMs on
this host already depend on the current macvtap setup.

**Current working access path: from another VM on this same host.**
Confirmed directly: Windows11 (also macvtap-bridged on this host) can
reach `wazuh-manager` over SSH and HTTPS at `192.168.10.12` with no
issues. Guest-to-guest traffic on a shared macvtap interface isn't
subject to the host-isolation limitation that blocks the Pop!_OS
hypervisor host specifically — this is genuinely the simplest fix, since
it requires zero new firewall rules and zero credential handling on a
third device.

<details>
<summary>Earlier workaround (Synology jump host via SSH agent forwarding)
— superseded, kept for reference</summary>

Before Windows11 access was confirmed, Synology was used as a temporary
jump host. Rather than copying the primary private key onto Synology's
disk (a real option, but leaves a second copy of a key that's also used
for other things — e.g. OPNsense admin access — sitting on a second
machine), the key was forwarded from Pop!_OS's already-unlocked
`ssh-agent` session instead:

```bash
# From Pop!_OS — forwards the local agent's unlocked key into the session:
ssh -A synadmin@synology

# Now from inside that Synology session — authenticates using the
# forwarded key, no passphrase prompt, no key file on Synology's disk:
ssh wazuhadmin@192.168.10.12
```

What this required on Synology's end, and the full revert record, are in
"Temporary changes made outside this repo" above. Worth returning to
this pattern only if Windows11 (or another guest on this host) isn't
available as an access path in the future.

</details>

## Files

| File | Purpose |
|---|---|
| `providers.tf` | Terraform + libvirt provider requirements |
| `variables.tf` | All configurable inputs (sizing, network, identity) |
| `main.tf` | Storage pool, disks, cloud-init disk, VM domain |
| `outputs.tf` | VM name, MAC address, SSH connection hint |
| `cloud-init/*.tftpl` | cloud-init templates (user-data, meta-data, network-config) |
| `terraform.tfvars.example` | Template for required/optional variable values |
