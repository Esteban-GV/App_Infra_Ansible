variable "region" {
    type = string
    description = "region de despliegue"
}

variable "prefix_name" {
    type = string
    description = "prefijo para nombres de recursos"
}

variable "user" {
    type = string
    description = "usuario ssh"
}

variable "password" {
    type = string
    description = "password ssh"
}

variable "servers" {
    type = set(string)
    description = "nombre de los servidores que se van a desplegar"
}

variable "size_servers" {
    type        = string
    description = "tamaño por defecto de las maquinas virtuales"
    default     = "Standard_B2s"
}

variable "server_sizes" {
    type        = map(string)
    description = "tamaño especifico por servidor (ej: { nginx = \"Standard_B1s\", jenkins = \"Standard_B2s\" })"
    default     = {}
}