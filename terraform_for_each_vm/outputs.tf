output "ip_servers" {
    value = module.vm.ip_servers
}

output "vm_ips" {
    description = "Mapa de servidores y sus direcciones IP publicas"
    value       = module.vm.vm_ips
}