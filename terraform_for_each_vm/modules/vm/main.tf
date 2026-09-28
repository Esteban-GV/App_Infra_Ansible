resource "azurerm_public_ip" "devops_ip" {
    for_each = var.servers
    name                = "${each.value}-public-ip"
    location            = var.location
    resource_group_name = var.resource_group_name
    allocation_method   = "Static"
}

resource "azurerm_network_interface" "devops_nic" {
    for_each = var.servers
    name                = "${each.value}-nic"
    location            = var.location
    resource_group_name = var.resource_group_name

    ip_configuration {
    name                          = "${each.value}-configuration"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.devops_ip[each.value].id
    }
}

resource "azurerm_network_security_group" "devops_sg" {
    name                = "${var.prefix_name}-sg"
    location            = var.location
    resource_group_name = var.resource_group_name

    security_rule {
        name                       = "SSH"
        priority                   = 1001
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "22"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }
    security_rule {
        name                       = "HTTP"
        priority                   = 1002
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "80"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }
    security_rule {
        name                       = "Sonar"
        priority                   = 1003
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "9000"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }
}

resource "azurerm_network_interface_security_group_association" "devops_association" {
    for_each = var.servers
    network_interface_id      = azurerm_network_interface.devops_nic[each.value].id
    network_security_group_id = azurerm_network_security_group.devops_sg.id
}

resource "azurerm_linux_virtual_machine" "vm_devops" {
    for_each = var.servers
    name = "${each.value}-machine"
    resource_group_name = var.resource_group_name
    location = var.location
    size = lookup(var.server_sizes, each.value, var.size_servers)
    network_interface_ids = [azurerm_network_interface.devops_nic[each.value].id]
    disable_password_authentication = false
    admin_username = var.user
    admin_password = var.password

    source_image_reference {
        publisher = "Canonical"
        offer = "0001-com-ubuntu-server-jammy"
        sku = "22_04-lts-gen2"
        version = "latest"
    }


    os_disk {
        caching = "ReadWrite"
        storage_account_type = "Standard_LRS"
    }

    depends_on = [azurerm_network_interface_security_group_association.devops_association]

}