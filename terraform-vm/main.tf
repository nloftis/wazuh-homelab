# Locally-administered MAC, sharing the 52:54:00 QEMU/KVM prefix already
# used by other VMs on this host, with a random 3-byte suffix to avoid
# collisions.
resource "random_id" "mac_suffix" {
  byte_length = 3
}

locals {
  mac_address = "52:54:00:${substr(random_id.mac_suffix.hex, 0, 2)}:${substr(random_id.mac_suffix.hex, 2, 2)}:${substr(random_id.mac_suffix.hex, 4, 2)}"
}

# NOTE: dmacvicar/libvirt has no data source for looking up an existing
# pool by name (confirmed: no such data source exists in any version of
# this provider). var.libvirt_pool_name is passed directly as a plain
# string to each resource below instead — libvirt resolves the existing
# "default" pool by name at apply time; Terraform never creates, owns, or
# could accidentally destroy it.

# Base Ubuntu 24.04 cloud image, downloaded once and reused as a backing
# volume for the VM disk (copy-on-write, so this doesn't consume a full
# 100GB on disk).
resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-24.04-base.qcow2"
  pool   = var.libvirt_pool_name
  source = var.ubuntu_cloud_image_url
  format = "qcow2"
}

# VM's actual root disk, backed by the base image above.
resource "libvirt_volume" "wazuh_disk" {
  name             = "${var.vm_name}.qcow2"
  pool             = var.libvirt_pool_name
  base_volume_id   = libvirt_volume.ubuntu_base.id
  size             = var.disk_size_bytes
  format           = "qcow2"
}

# cloud-init seed disk: injects hostname, SSH key, and DHCP network config
# on first boot. No manual console setup required.
resource "libvirt_cloudinit_disk" "commoninit" {
  name      = "${var.vm_name}-cloudinit.iso"
  pool             = var.libvirt_pool_name
  user_data = templatefile("${path.module}/cloud-init/user-data.yaml.tftpl", {
    hostname       = var.vm_hostname
    timezone       = var.timezone
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
  meta_data = templatefile("${path.module}/cloud-init/meta-data.yaml.tftpl", {
    hostname = var.vm_hostname
  })
  network_config = templatefile("${path.module}/cloud-init/network-config.yaml.tftpl", {
    mac_address = local.mac_address
  })
}

resource "libvirt_domain" "wazuh" {
  name   = var.vm_name
  memory = var.memory_mb
  vcpu   = var.vcpu

  cloudinit = libvirt_cloudinit_disk.commoninit.id

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.wazuh_disk.id
  }

  # macvtap in bridge mode against the host's physical PC-segment NIC —
  # same pattern already used by other VMs on this host (confirmed via
  # `virsh domiflist`: type "direct", source matching the host's physical
  # interface). Gets a real DHCP lease from OPNsense's PC segment, not
  # libvirt's isolated NAT network.
  #
  # wait_for_lease = true: confirmed working in this environment —
  # `virsh domifaddr wazuh-manager --source agent` correctly returned the
  # guest's real IP once cloud-init had installed and enabled
  # qemu-guest-agent. Safe to let `apply` block until the IP is known
  # rather than looking it up manually via OPNsense's DHCP lease table
  # afterward. If this ever hangs on a future apply (e.g. guest-agent
  # fails to start), fall back to the manual lookup: `terraform output
  # mac_address`, then check OPNsense's DHCP leases for that MAC.
  network_interface {
    macvtap        = var.network_interface
    mac            = local.mac_address
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }

  qemu_agent = true

  boot_device {
    dev = ["hd"]
  }
}
