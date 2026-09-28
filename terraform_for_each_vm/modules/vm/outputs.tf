output "ip_servers" {
    description = "IP de los servidores"
    value = [for server in azurerm_public_ip.devops_ip : {"name": server.id,"ip" : server.ip_address}]
}

output "vm_ips" {
    description = "Mapa de servidor a direccion IP publica"
    value = { for server_name, pip in azurerm_public_ip.devops_ip : server_name => pip.ip_address }
}