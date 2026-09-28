variable "servers" {
    type = set(string)
    description = "lista de servidores que vamos a desplegar"
}

variable "size_servers" {
    type        = string
    default     = "Standard_B2s"
    description = "tamaño por defecto de instancia de los servidores"
}

variable "server_sizes" {
    type        = map(string)
    default     = {}
    description = "tamaño especifico por servidor"
}


variable "resource_group_name" {
    type = string
    description = "grupo de recursos de las vm"
}

variable "location" {
    type = string
    description = "region"
}

variable "subnet_id" {
    type = string
    description = "id de la subnet de los servidores"
}

variable "user" {
    type = string
    description = "usuario ssh"
}

variable "password" {
    type = string
    description = "password ssh"
}

variable "prefix_name" {
    type = string
    description = "prefijo de los recursos"
}