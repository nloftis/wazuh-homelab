variable "vm_name" {
  description = "libvirt domain name for the Wazuh VM"
  type        = string
  default     = "wazuh"
}

variable "vm_hostname" {
  description = "Hostname set inside the guest via cloud-init"
  type        = string
  default     = "wazuh"
}

variable "vcpu" {
  description = "Number of vCPUs allocated to the Wazuh VM"
  type        = number
  default     = 4
}

variable "memory_mb" {
  description = "RAM in MiB allocated to the Wazuh VM (8192 = 8GB)"
  type        = number
  default     = 8192
}

variable "disk_size_bytes" {
  description = "Root disk size in bytes (100GB)"
  type        = number
  default     = 107374182400
}

variable "libvirt_pool_name" {
  description = "Name of the existing libvirt storage pool to place VM disks in — 'default' already targets /mnt/data/VMs (confirmed via virsh pool-dumpxml), the same location other VMs on this host already use"
  type        = string
  default     = "default"
}

variable "ubuntu_cloud_image_url" {
  description = "URL of the Ubuntu 24.04 LTS (Noble) cloud image (qcow2)"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "network_interface" {
  description = "Physical host interface to bind macvtap to (PC segment, same interface other bridged VMs on this host use)"
  type        = string
  default     = "enp4s0"
}

variable "ssh_public_key" {
  description = "SSH public key injected via cloud-init for the admin user"
  type        = string
  # No default on purpose — pass via terraform.tfvars (gitignored) or -var
}

variable "admin_username" {
  description = "Username created inside the guest via cloud-init"
  type        = string
  default     = "wazuhadmin"
}

variable "admin_password_hash" {
  description = "SHA-512 password hash for the VM admin user"
  type        = string
  sensitive   = true
}

variable "timezone" {
  description = "Guest timezone"
  type        = string
  default     = "Pacific/Honolulu"
}
