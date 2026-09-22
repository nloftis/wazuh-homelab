# terraform-vm — Wazuh via Terraform + libvirt

Terraform-provisioned Wazuh SIEM/XDR deployment running as a KVM/libvirt VM on a Pop!_OS host.

This is one of two deployment paths in the repository. See the top-level [`README.md`](../README.md) for how this relates to the `docker-compose/` deployment and for deployment-independent Wazuh configuration.

The Terraform deployment is fully automated:

```text
terraform apply
      │
      ├── Creates the Ubuntu 24.04 VM
      ├── Configures the guest with cloud-init
      ├── Creates the wazuhadmin account
      ├── Configures SSH key authentication
      ├── Configures console password authentication
      ├── Installs required packages
      ├── Enables the QEMU guest agent
      │
      ▼
cloud-init
      │
      ├── Downloads the official Wazuh 4.14 installer
      └── Runs wazuh-install.sh -a
                │
                ├── Wazuh indexer
                ├── Wazuh manager
                └── Wazuh dashboard
```

No manual Wazuh installation is required after `terraform apply`.

---

## Architecture

### Wazuh topology

The deployment uses a monolithic single-node Wazuh architecture:

* Wazuh indexer
* Wazuh manager
* Wazuh dashboard

All three components run on the same VM.

This is appropriate for the homelab environment and avoids the additional complexity and resource requirements of a distributed Wazuh cluster.

### VM specifications

| Component          | Configuration           |
| ------------------ | ----------------------- |
| VM name            | `wazuh`                 |
| Guest hostname     | `wazuh`                 |
| OS                 | Ubuntu Server 24.04 LTS |
| vCPU               | 4                       |
| RAM                | 8 GB                    |
| Disk               | 100 GB                  |
| CPU mode           | host-passthrough        |
| Network            | macvtap bridge          |
| Guest provisioning | cloud-init              |
| Admin user         | `wazuhadmin`            |
| Wazuh install mode | all-in-one (`-a`)       |

The VM disk is stored in the existing libvirt `default` pool under:

```text
/mnt/data/VMs/
```

Terraform references the existing pool by name. It does not create or own the pool itself.

---

## Network Architecture

The VM uses a macvtap interface in bridge mode against the Pop!_OS host's physical NIC.

This places the VM directly on the OPNsense PC network and allows it to obtain an address through normal DHCP.

This is the same general networking pattern used by other VMs in the homelab.

### macvtap host isolation

An important property of this configuration is that the Pop!_OS hypervisor normally cannot communicate directly with the VM through the macvtap interface.

For example, this may fail from Pop!_OS:

```bash
ssh wazuhadmin@<wazuh-ip>
```

even though the VM is reachable from other systems on the network.

This is a macvtap host-isolation limitation, not a Wazuh, SSH, or OPNsense problem.

Other systems on the network — including other VMs — can communicate with the Wazuh VM normally.

For administration directly from the Pop!_OS hypervisor, use the libvirt console:

```bash
virsh console wazuh
```

This is the preferred host-side troubleshooting and first-boot monitoring path.

---

## Prerequisites

### Terraform

The project pins Terraform using:

```text
.terraform-version
```

Current version:

```text
1.15.8
```

When using `tenv`, entering this directory automatically selects the configured Terraform version.

Verify with:

```bash
terraform version
```

### libvirt

Verify that libvirt can be accessed without `sudo`:

```bash
virsh list --all
```

### genisoimage

The libvirt provider uses `mkisofs` to create the cloud-init seed ISO.

Install it with:

```bash
sudo apt install genisoimage
```

### AppArmor

The libvirt storage pool uses:

```text
/mnt/data/VMs/
```

On Ubuntu/Pop!_OS systems, QEMU may require an AppArmor override before it can access a custom libvirt storage path.

See the Troubleshooting section below.

---

## Repository Layout

```text
terraform-vm/
├── cloud-init/
│   ├── meta-data.yaml.tftpl
│   ├── network-config.yaml.tftpl
│   └── user-data.yaml.tftpl
├── .gitignore
├── .terraform-version
├── main.tf
├── outputs.tf
├── providers.tf
├── README.md
├── terraform.tfvars.example
└── variables.tf
```

### File responsibilities

| File                                   | Purpose                                                      |
| -------------------------------------- | ------------------------------------------------------------ |
| `providers.tf`                         | Terraform and provider requirements                          |
| `variables.tf`                         | VM, network, account, and provisioning inputs                |
| `main.tf`                              | VM disk, cloud-init disk, networking, and libvirt domain     |
| `outputs.tf`                           | VM name, IP address, MAC address, and connection information |
| `cloud-init/user-data.yaml.tftpl`      | Guest configuration and automated Wazuh installation         |
| `cloud-init/meta-data.yaml.tftpl`      | cloud-init instance metadata                                 |
| `cloud-init/network-config.yaml.tftpl` | Guest network configuration                                  |
| `terraform.tfvars.example`             | Example local configuration                                  |
| `.terraform-version`                   | Terraform version pin                                        |

---

## Configuration

Create the local Terraform variables file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit:

```bash
nano terraform.tfvars
```

At minimum, configure the SSH public key and console password hash required by the deployment.

`terraform.tfvars` contains machine-specific and potentially sensitive configuration and is intentionally excluded from Git.

---

## Console Password Configuration

The `wazuhadmin` account supports password login through the VM's libvirt console.

This is particularly useful because macvtap prevents normal Pop!_OS host-to-guest SSH access.

The plaintext password is **not** stored in Terraform.

Instead, generate a SHA-512 password hash on the Pop!_OS host:

```bash
openssl passwd -6
```

Enter the password that should be used for the `wazuhadmin` Linux account.

The command returns a value beginning with:

```text
$6$...
```

Store the complete hash in the local `terraform.tfvars` file:

```hcl
admin_password_hash = "$6$..."
```

The value flows through the configuration as:

```text
terraform.tfvars
        │
        ▼
var.admin_password_hash
        │
        ▼
main.tf
        │
        ▼
cloud-init user-data
        │
        ▼
wazuhadmin
```

The Terraform variable is declared sensitive.

cloud-init configures the account with:

```yaml
lock_passwd: false
passwd: ${admin_password_hash}
```

### Console versus SSH authentication

Password authentication is provided specifically for local console access.

SSH password authentication remains disabled:

```yaml
ssh_pwauth: false
```

Therefore:

| Access method         | Authentication      |
| --------------------- | ------------------- |
| `virsh console wazuh` | Username + password |
| SSH                   | Public key only     |

This allows convenient console troubleshooting without enabling password-based remote SSH access.

### Console login

From the Pop!_OS host:

```bash
virsh console wazuh
```

Log in with:

```text
login: wazuhadmin
Password: <configured password>
```

To exit the libvirt console:

```text
Ctrl+]
```

---

## SSH Configuration

cloud-init installs the SSH public key supplied through Terraform for the `wazuhadmin` account.

SSH remains public-key-only:

```yaml
ssh_pwauth: false
```

Because of macvtap host isolation, SSH from the Pop!_OS hypervisor to the Wazuh VM normally does not work.

SSH from other systems on the network can be used when appropriate.

The libvirt console is the preferred administration path directly from the hypervisor.

---

## Provisioning Workflow

The complete deployment is driven by Terraform and cloud-init.

### 1. Terraform creates the infrastructure

Running:

```bash
terraform apply
```

creates:

* Ubuntu 24.04 base volume
* Wazuh VM disk
* cloud-init seed ISO
* libvirt domain
* macvtap network interface

The VM is named:

```text
wazuh
```

### 2. cloud-init configures Ubuntu

During first boot, cloud-init:

* Sets the hostname
* Creates `wazuhadmin`
* Configures the console password hash
* Installs the SSH public key
* Keeps SSH password authentication disabled
* Updates the guest
* Installs prerequisite packages
* Enables `qemu-guest-agent`

### 3. cloud-init creates the Wazuh provisioning wrapper

The cloud-init configuration writes:

```text
/usr/local/sbin/install-wazuh.sh
```

inside the guest.

This is a small provisioning wrapper used to launch the official Wazuh installer.

### 4. The official Wazuh installer is downloaded

The wrapper downloads:

```text
https://packages.wazuh.com/4.14/wazuh-install.sh
```

using:

```bash
curl -sO https://packages.wazuh.com/4.14/wazuh-install.sh
```

### 5. Wazuh is installed

The installer runs in all-in-one mode:

```bash
bash wazuh-install.sh -a
```

The `-a` installation includes:

* Wazuh indexer
* Wazuh manager
* Filebeat integration
* Wazuh dashboard

### 6. Services are verified

The provisioning wrapper verifies:

```bash
systemctl is-active --quiet wazuh-indexer
systemctl is-active --quiet wazuh-manager
systemctl is-active --quiet wazuh-dashboard
```

Because the wrapper uses:

```bash
set -euo pipefail
```

an inactive Wazuh service causes the provisioning command to fail rather than silently reporting success.

---

## Deploy

Initialize Terraform:

```bash
terraform init
```

Format the configuration:

```bash
terraform fmt -recursive
```

Validate it:

```bash
terraform validate
```

Review the deployment:

```bash
terraform plan
```

Create the VM:

```bash
terraform apply
```

Review the plan and approve it when prompted.

---

## Terraform Apply vs. Wazuh Provisioning

`terraform apply` completing does **not** necessarily mean Wazuh has finished installing.

Terraform manages the infrastructure lifecycle.

Once the VM exists and has booted successfully, Terraform may complete while cloud-init continues provisioning software inside the guest.

The sequence is therefore:

```text
terraform apply
      │
      ▼
VM created
      │
      ├── Terraform may finish here
      │
      ▼
cloud-init continues
      │
      ▼
Wazuh installation
      │
      ▼
Wazuh services active
```

Allow several additional minutes after the VM is created for the Wazuh installation to complete.

---

## Monitoring First-Boot Provisioning

The preferred method from the Pop!_OS host is:

```bash
virsh console wazuh
```

Log in as:

```text
wazuhadmin
```

### Check cloud-init

Inside the VM:

```bash
cloud-init status --long
```

While provisioning is underway, expect:

```text
status: running
```

When provisioning has completed successfully, expect:

```text
status: done
extended_status: done
errors: []
recoverable_errors: {}
```

### Monitor the Wazuh installer

Wazuh's installer writes its installation log to:

```text
/var/log/wazuh-install.log
```

Monitor it with:

```bash
sudo tail -f /var/log/wazuh-install.log
```

Press:

```text
Ctrl+C
```

to stop following the log.

The final Wazuh installer summary contains the generated dashboard credentials.

---

## Wazuh Dashboard Credentials

The Wazuh installer generates the initial `admin` password automatically.

At the end of installation, `/var/log/wazuh-install.log` contains a summary similar to:

```text
--- Summary ---
You can access the web interface https://<wazuh-dashboard-ip>:443
    User: admin
    Password: <generated-password>
Installation finished.
```

Retrieve it with:

```bash
sudo tail -30 /var/log/wazuh-install.log
```

Store the generated password in an appropriate password manager.

Do not commit it to Git.

The Wazuh dashboard password is independent of the Linux `wazuhadmin` console password.

---

## Verify Wazuh

After cloud-init reports `done`, verify all three Wazuh services:

```bash
systemctl is-active \
  wazuh-indexer \
  wazuh-manager \
  wazuh-dashboard
```

Expected output:

```text
active
active
active
```

For more detail:

```bash
systemctl status wazuh-indexer
systemctl status wazuh-manager
systemctl status wazuh-dashboard
```

---

## Dashboard Access

The dashboard listens on HTTPS port 443.

Use the IP reported by Terraform:

```bash
terraform output ip_address
```

Then browse from a system that can reach the VM:

```text
https://<wazuh-ip>
```

Log in with:

```text
User: admin
Password: <installer-generated password>
```

The browser may display a certificate warning because the Wazuh installer generates certificates for the deployment.

---

## QEMU Guest Agent

The VM includes and enables:

```text
qemu-guest-agent
```

Terraform/libvirt can therefore retrieve the VM's DHCP address through the guest agent.

For example:

```bash
virsh domifaddr wazuh --source agent
```

The guest agent can also be checked with:

```bash
virsh qemu-agent-command wazuh \
  '{"execute":"guest-ping"}'
```

Expected response:

```json
{"return":{}}
```

`wait_for_lease = true` allows Terraform to wait for and report the guest's address during deployment.

---

## Terraform Outputs

After deployment:

```bash
terraform output
```

provides information including:

* VM name
* IP address
* MAC address
* SSH connection hint

The IP address is DHCP-assigned and may change after a destroy/recreate cycle.

Do not assume an address from a previous deployment will be reused.

---

## Destroy and Recreate

The deployment is designed to be reproducible.

Destroy the current VM:

```bash
terraform destroy
```

Review the plan and approve it.

Then recreate the entire deployment:

```bash
terraform apply
```

A clean rebuild performs the complete process again:

```text
terraform apply
      │
      ▼
new Ubuntu VM
      │
      ▼
cloud-init
      │
      ▼
new wazuhadmin account
      │
      ▼
Wazuh installer downloaded
      │
      ▼
new Wazuh installation
      │
      ▼
new dashboard credentials
```

No manual Wazuh installation is required after recreation.

The dashboard `admin` password is generated by the Wazuh installer and therefore changes with a fresh installation.

---

## Post-Deployment Configuration

This README covers the Terraform/libvirt deployment itself.

Configuration that applies regardless of whether Wazuh was deployed through Terraform or Docker is documented separately in:

```text
../docs/post-deployment.md
```

That includes topics such as:

* Agent enrollment
* OPNsense Wazuh integration
* Syslog forwarding
* Firewall requirements
* Dashboard usage

Keeping those steps deployment-independent avoids duplicating the same configuration in both deployment paths.

---

## Troubleshooting

### SSH from Pop!_OS reports `No route to host`

This is expected with the current macvtap architecture.

The VM can be correctly networked and reachable from other systems while remaining unreachable directly from the hypervisor through its macvtap interface.

Use:

```bash
virsh console wazuh
```

for host-side administration.

This is preferable to changing firewall rules or copying SSH private keys to another system solely to work around macvtap host isolation.

---

### Check provisioning status

From the console:

```bash
cloud-init status --long
```

If provisioning is still running:

```text
status: running
```

Wait for it to complete.

For Wazuh-specific progress:

```bash
sudo tail -f /var/log/wazuh-install.log
```

For general cloud-init output:

```bash
sudo tail -f /var/log/cloud-init-output.log
```

---

### Wazuh installation completed but a service is not active

Check all services:

```bash
systemctl status \
  wazuh-indexer \
  wazuh-manager \
  wazuh-dashboard
```

Then inspect the Wazuh installation log:

```bash
sudo less /var/log/wazuh-install.log
```

Also check the relevant systemd journal, for example:

```bash
sudo journalctl -u wazuh-manager
```

---

### `Could not open '.../ubuntu-24.04-base.qcow2': Permission denied`

A generic permission error against:

```text
/mnt/data/VMs/
```

may actually be caused by AppArmor rather than Unix file permissions.

Check:

```bash
sudo dmesg | grep -i apparmor | tail -20
```

If the output shows QEMU being denied access to `/mnt/data/VMs/`, edit:

```bash
sudo nano /etc/apparmor.d/local/abstractions/libvirt-qemu
```

Add:

```text
/mnt/data/VMs/** rwk,
```

Then reload AppArmor:

```bash
sudo systemctl reload apparmor
```

This is a host-level fix and applies to future VMs using the same libvirt pool.

---

### `domain 'wazuh' already exists`

If libvirt creates the domain but Terraform fails before recording it in state, an orphaned domain definition may remain.

Check:

```bash
virsh list --all
```

If Terraform does not own the domain and it is safe to remove, undefine it with:

```bash
virsh undefine wazuh --nvram
```

Then retry:

```bash
terraform apply
```

The `--nvram` option is important because the VM uses UEFI.

---

### libvirt provider pinned to `~> 0.8.0`

The project deliberately constrains the libvirt provider to the 0.8.x
release line.

Do not change the constraint to:

```hcl
version = "~> 0.8"
```

Terraform's pessimistic constraint operator applies to the rightmost
specified version component. Therefore:

```text
~> 0.8.0  → >= 0.8.0, < 0.9.0
~> 0.8    → >= 0.8.0, < 1.0.0
```

The latter allowed Terraform to select libvirt provider 0.9.x during the
original deployment work.

Provider 0.9 introduced breaking schema changes. Configuration written
for the 0.8.x provider produced multiple `unsupported argument` and
`unsupported block type` validation errors when initialized against the
new provider.

The project therefore remains deliberately pinned to:

```hcl
version = "~> 0.8.0"
```

The `.terraform.lock.hcl` file should also remain committed so the
tested provider selection is reproducible.

Upgrade to a newer provider only as a deliberate migration that includes
reviewing and updating the Terraform configuration for the newer schema.

---

## Git and Repository Hygiene

The repository should contain the files required to reproduce the deployment without committing machine-specific secrets or Terraform runtime state.

### Commit

Commit files such as:

```text
.terraform-version
.terraform.lock.hcl
terraform.tfvars.example
providers.tf
variables.tf
main.tf
outputs.tf
cloud-init/
README.md
```

### Do not commit

Do not commit:

```text
terraform.tfvars
terraform.tfstate
terraform.tfstate.*
.terraform/
```

`terraform.tfvars` contains local configuration including the console password hash and SSH public key.

Terraform state is runtime data and should not be treated as source code.

---

## Validated Deployment

The automated deployment has been validated with a clean:

```text
terraform destroy
terraform apply
```

cycle.

The resulting VM successfully completed cloud-init with:

```text
status: done
extended_status: done
errors: []
recoverable_errors: {}
```

Console authentication was verified using:

```bash
virsh console wazuh
```

with the `wazuhadmin` account.

The automated Wazuh installation completed successfully, and all three primary services were verified:

```text
wazuh-indexer     active
wazuh-manager     active
wazuh-dashboard   active
```

The deployment can therefore be destroyed and recreated from the Terraform configuration without manually installing Wazuh inside the VM.
