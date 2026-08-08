output "vm_name" {
  description = "libvirt domain name"
  value       = libvirt_domain.wazuh.name
}

output "mac_address" {
  description = "MAC address assigned to the VM's network interface (look this up in your OPNsense DHCP leases to find the IP)"
  value       = local.mac_address
}

output "ip_address" {
  description = "IP address assigned via DHCP, resolved through qemu-guest-agent (requires wait_for_lease = true)"
  value       = try(libvirt_domain.wazuh.network_interface[0].addresses[0], "not yet available")
}

output "ssh_connection_hint" {
  description = "Ready-to-use SSH command, using the resolved IP if available"
  value       = "ssh ${var.admin_username}@${try(libvirt_domain.wazuh.network_interface[0].addresses[0], "<ip-from-opnsense-dhcp-leases>")}"
}
