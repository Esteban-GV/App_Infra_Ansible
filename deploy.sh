#!/usr/bin/env bash
# ==============================================================================
# Script de Despliegue y Orquestación Automatizada
# Proyecto: Infraestructura Azure con Terraform y Aprovisionamiento con Ansible
# ==============================================================================

set -euo pipefail

# Colores para salida de terminal
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # Sin color

# Rutas del proyecto
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TF_DIR="${SCRIPT_DIR}/terraform_for_each_vm"
readonly ANSIBLE_DIR="${SCRIPT_DIR}/ansible-pipeline"
readonly INVENTORY_FILE="${ANSIBLE_DIR}/inventory.ini"
readonly TF_VARS_FILE="${TF_DIR}/terraform.tfvars"

# Configuración de tiempos de espera (segundos)
readonly SSH_TIMEOUT=300
readonly SSH_RETRY_INTERVAL=10

# Banderas de control
FORCE_TERRAFORM=false


# ------------------------------------------------------------------------------
# Funciones de Logging
# ------------------------------------------------------------------------------
log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✔ ÉXITO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠ ADVERTENCIA]${NC} $1"
}

log_error() {
    echo -e "${RED}[✖ ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "\n${BOLD}${PURPLE}======================================================================${NC}"
    echo -e "${BOLD}${PURPLE}▶ $1${NC}"
    echo -e "${BOLD}${PURPLE}======================================================================${NC}"
}

# ------------------------------------------------------------------------------
# Ayuda y Uso
# ------------------------------------------------------------------------------
show_help() {
    cat <<EOF
Uso: $(basename "$0") [OPCIONES]

Orquesta el ciclo de vida completo de la infraestructura y aprovisionamiento:
  1. Verificaciones previas de dependencias y credenciales
  2. Despliegue de infraestructura con Terraform (VMs en Azure)
  3. Extracción de IPs y generación dinámica del inventario de Ansible
  4. Verificación activa de disponibilidad SSH en las máquinas
  5. Ejecución del playbook de Ansible (Nginx, Docker, Jenkins, SonarQube)
  6. Comprobaciones de salud post-despliegue (HTTP/Puertos)

Opciones:
  -h, --help            Muestra este mensaje de ayuda.
  -c, --check-only      Solo ejecuta las verificaciones previas sin desplegar nada.
  -t, --terraform-only  Ejecuta únicamente el aprovisionamiento de Terraform.
  -a, --ansible-only    Ejecuta únicamente el aprovisionamiento de Ansible (requiere VMs activas).
  -f, --force           Fuerza la ejecución de 'terraform apply' aunque no se detecten cambios.
  -d, --destroy         Destruye toda la infraestructura creada por Terraform.
EOF
}

# ------------------------------------------------------------------------------
# Verificaciones Previas (Pre-flight checks)
# ------------------------------------------------------------------------------
check_dependencies() {
    log_step "PASO 0: Verificaciones del Entorno y Requisitos Previos"

    local missing_tools=()

    for tool in terraform ansible ansible-playbook sshpass curl; do
        if command -v "$tool" &>/dev/null; then
            log_success "Herramienta encontrada: $(which "$tool")"
        else
            missing_tools+=("$tool")
        fi
    done

    # Validar jq o python3 para parseo JSON
    if command -v jq &>/dev/null; then
        log_success "Herramienta encontrada: $(which jq)"
    elif command -v python3 &>/dev/null; then
        log_warn "'jq' no está instalado, se utilizará 'python3' como alternativa para parsear JSON."
    else
        missing_tools+=("jq o python3")
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Faltan las siguientes herramientas obligatorias en el sistema:"
        for t in "${missing_tools[@]}"; do
            echo "   - $t"
        done
        echo ""
        log_info "En Ubuntu/Debian puedes instalarlas con:"
        echo "   sudo apt-get update && sudo apt-get install -y terraform ansible sshpass jq curl"
        exit 1
    fi

    # Comprobar existencia de archivos esenciales
    local required_files=(
        "$TF_DIR/main.tf"
        "$TF_VARS_FILE"
        "$ANSIBLE_DIR/playbook.yml"
        "$ANSIBLE_DIR/docker-compose.yml"
    )

    for file in "${required_files[@]}"; do
        if [[ -f "$file" ]]; then
            log_success "Archivo requerido presente: $(basename "$file")"
        else
            log_error "Archivo obligatorio no encontrado: $file"
            exit 1
        fi
    done

    # Comprobación de autenticación en Azure
    log_info "Comprobando credenciales de Azure..."
    if [[ -n "${ARM_SUBSCRIPTION_ID:-}" && -n "${ARM_CLIENT_ID:-}" && -n "${ARM_CLIENT_SECRET:-}" && -n "${ARM_TENANT_ID:-}" ]]; then
        log_success "Credenciales de Azure detectadas mediante variables de entorno (Service Principal)."
    elif command -v az &>/dev/null && az account show &>/dev/null 2>&1; then
        local sub_name
        sub_name=$(az account show --query "name" -o tsv 2>/dev/null || echo "Desconocida")
        log_success "Sesión de Azure CLI activa. Suscripción: ${sub_name}"
    else
        log_warn "No se detectaron variables ARM_* ni sesión activa en Azure CLI ('az login')."
        log_warn "Si Terraform no tiene credenciales configuradas, la ejecución podría fallar al conectar con Azure."
    fi
}

# ------------------------------------------------------------------------------
# Lectura de Variables de Terraform
# ------------------------------------------------------------------------------
get_tf_credentials() {
    # Extrae el usuario y contraseña del archivo terraform.tfvars
    SSH_USER=$(grep -E '^[[:space:]]*user[[:space:]]*=' "$TF_VARS_FILE" | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || echo "guarinve")
    SSH_PASS=$(grep -E '^[[:space:]]*password[[:space:]]*=' "$TF_VARS_FILE" | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || echo "mypassw0rd")

    if [[ -z "$SSH_USER" || -z "$SSH_PASS" ]]; then
        log_error "No se pudieron obtener 'user' o 'password' desde $TF_VARS_FILE"
        exit 1
    fi

    log_info "Credenciales extraídas de terraform.tfvars -> Usuario: ${SSH_USER}"
}

# ------------------------------------------------------------------------------
# Fase 1: Despliegue con Terraform
# ------------------------------------------------------------------------------
run_terraform() {
    log_step "PASO 1: Aprovisionamiento de Infraestructura con Terraform"

    cd "$TF_DIR"

    # Liberar lock local huérfano si existe y no hay ningún proceso de terraform activo
    if [[ -f ".terraform.tfstate.lock.info" ]] && ! pgrep -x terraform &>/dev/null; then
        log_warn "Se detectó un archivo de lock huérfano (.terraform.tfstate.lock.info). Liberándolo..."
        rm -f ".terraform.tfstate.lock.info"
    fi

    if [[ ! -d ".terraform" ]]; then
        log_info "Inicializando Terraform (terraform init)..."
        terraform init
    fi

    log_info "Validando configuración de Terraform..."
    terraform validate

    # Si se solicitó forzar la ejecución con --force
    if [[ "$FORCE_TERRAFORM" = true ]]; then
        log_info "Modo forzado activo (--force). Aplicando cambios en Azure..."
        terraform apply -auto-approve
        log_success "Infraestructura aplicada exitosamente en Azure."
        cd "$SCRIPT_DIR"
        return 0
    fi

    # 1. Comprobar si las dos máquinas ya están registradas en el estado
    local state_list
    state_list=$(terraform state list 2>/dev/null || true)

    local has_jenkins=false
    local has_nginx=false

    if echo "$state_list" | grep -qE "azurerm_linux_virtual_machine.*jenkins"; then
        has_jenkins=true
    fi
    if echo "$state_list" | grep -qE "azurerm_linux_virtual_machine.*nginx"; then
        has_nginx=true
    fi

    if [[ "$has_jenkins" != true || "$has_nginx" != true ]]; then
        log_info "Aún no existen ambas máquinas virtuales en el estado (Jenkins: $has_jenkins, Nginx: $has_nginx)."
        log_info "Aplicando cambios en Azure (terraform apply)..."
        terraform apply -auto-approve
        log_success "Infraestructura desplegada exitosamente en Azure."
    else
        log_info "Las 2 máquinas virtuales ('jenkins' y 'nginx') ya existen en el estado local."
        log_info "Verificando si existen cambios pendientes en Azure (terraform plan)..."

        # terraform plan con -detailed-exitcode:
        # 0 = Éxito, sin cambios (empty diff)
        # 1 = Error
        # 2 = Éxito, hay cambios pendientes (non-empty diff)
        local plan_code=0
        set +e
        terraform plan -detailed-exitcode -compact-warnings >/dev/null 2>&1
        plan_code=$?
        set -e

        if [[ $plan_code -eq 0 ]]; then
            log_success "Las 2 máquinas virtuales ya están creadas en Azure y NO hay cambios pendientes en la infraestructura."
            log_info "Omitiendo 'terraform apply' (usa './deploy.sh --force' si deseas forzar la ejecución)."
        elif [[ $plan_code -eq 2 ]]; then
            log_info "Se detectaron cambios pendientes en la infraestructura. Aplicando cambios (terraform apply)..."
            terraform apply -auto-approve
            log_success "Infraestructura actualizada exitosamente en Azure."
        else
            log_warn "terraform plan devolvió código $plan_code. Procediendo con terraform apply para sincronizar..."
            terraform apply -auto-approve
            log_success "Infraestructura sincronizada en Azure."
        fi
    fi

    cd "$SCRIPT_DIR"
}

# ------------------------------------------------------------------------------
# Fase 2: Extracción de IPs
# ------------------------------------------------------------------------------
extract_ips() {
    log_step "PASO 2: Extracción de IPs Públicas"

    cd "$TF_DIR"
    local raw_output
    raw_output=$(terraform output -json 2>/dev/null || echo "{}")

    local nginx_ip=""
    local jenkins_ip=""

    # Intento 1: A través del output structured vm_ips
    if command -v jq &>/dev/null; then
        nginx_ip=$(echo "$raw_output" | jq -r '.vm_ips.value.nginx // empty' 2>/dev/null || true)
        jenkins_ip=$(echo "$raw_output" | jq -r '.vm_ips.value.jenkins // empty' 2>/dev/null || true)

        # Fallback a través del array ip_servers si vm_ips está vacío
        if [[ -z "$nginx_ip" || -z "$jenkins_ip" ]]; then
            nginx_ip=$(echo "$raw_output" | jq -r '.ip_servers.value[]? | select(.name | contains("nginx")) | .ip' 2>/dev/null | head -n1 || true)
            jenkins_ip=$(echo "$raw_output" | jq -r '.ip_servers.value[]? | select(.name | contains("jenkins")) | .ip' 2>/dev/null | head -n1 || true)
        fi
    elif command -v python3 &>/dev/null; then
        nginx_ip=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('vm_ips', {}).get('value', {}).get('nginx', ''))
except:
    pass
" 2>/dev/null || true)

        jenkins_ip=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('vm_ips', {}).get('value', {}).get('jenkins', ''))
except:
    pass
" 2>/dev/null || true)
    fi

    # Fallback directo al state si los outputs aún no están renderizados
    if [[ -z "$nginx_ip" || -z "$jenkins_ip" ]]; then
        log_warn "Consultando state de Terraform para localizar IPs públicas..."
        if command -v jq &>/dev/null; then
            nginx_ip=$(terraform show -json | jq -r '.values.root_module.child_modules[]?.resources[]? | select(.type=="azurerm_public_ip" and (.index=="nginx" or (.values.name | contains("nginx")))) | .values.ip_address' 2>/dev/null | head -n1 || true)
            jenkins_ip=$(terraform show -json | jq -r '.values.root_module.child_modules[]?.resources[]? | select(.type=="azurerm_public_ip" and (.index=="jenkins" or (.values.name | contains("jenkins")))) | .values.ip_address' 2>/dev/null | head -n1 || true)
        fi
    fi

    cd "$SCRIPT_DIR"

    # Validar que las IPs tengan un formato válido
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ ! "$nginx_ip" =~ $ip_regex || ! "$jenkins_ip" =~ $ip_regex ]]; then
        log_error "No se pudieron obtener IPs públicas válidas desde Terraform."
        echo "   - Nginx IP detectada:   '${nginx_ip}'"
        echo "   - Jenkins IP detectada: '${jenkins_ip}'"
        echo ""
        log_info "Verifica el estado ejecutando: cd $TF_DIR && terraform output"
        exit 1
    fi

    NGINX_IP="$nginx_ip"
    JENKINS_IP="$jenkins_ip"

    log_success "IPs obtenidas correctamente:"
    echo -e "   ${BOLD}Nginx VM:${NC}   ${GREEN}${NGINX_IP}${NC}"
    echo -e "   ${BOLD}Jenkins VM:${NC} ${GREEN}${JENKINS_IP}${NC}"
}

# ------------------------------------------------------------------------------
# Fase 3: Generación del Inventario de Ansible
# ------------------------------------------------------------------------------
generate_inventory() {
    log_step "PASO 3: Generación Dinámica del Inventario de Ansible"

    mkdir -p "$ANSIBLE_DIR"

    cat > "$INVENTORY_FILE" <<EOF
# Generado automáticamente por deploy.sh - $(date)
[nginx]
nginx-server ansible_host=${NGINX_IP}

[jenkins]
jenkins-server ansible_host=${JENKINS_IP}

[all:vars]
ansible_user=${SSH_USER}
ansible_password=${SSH_PASS}
ansible_ssh_pass=${SSH_PASS}
ansible_become_password=${SSH_PASS}
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10'
EOF

    log_success "Inventario generado en: ${INVENTORY_FILE}"
}

# ------------------------------------------------------------------------------
# Fase 4: Verificación de Disponibilidad SSH (Polling)
# ------------------------------------------------------------------------------
wait_for_ssh() {
    log_step "PASO 4: Verificación de Conectividad SSH a las Máquinas Virtuales"

    log_info "Las VMs recién creadas en Azure pueden tardar entre 30 y 90 segundos en iniciar sshd."
    log_info "Comprobando conexión SSH con usuario '${SSH_USER}'..."

    local hosts_to_check=("nginx:${NGINX_IP}" "jenkins:${JENKINS_IP}")

    for target in "${hosts_to_check[@]}"; do
        local name="${target%%:*}"
        local ip="${target##*:}"
        local elapsed=0
        local connected=false

        echo -n -e "${CYAN}[ESPERANDO]${NC} Conectando a ${name} (${ip}:22)... "

        while [[ $elapsed -lt $SSH_TIMEOUT ]]; do
            # Intentar conexión SSH autenticada con sshpass
            if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no \
                                          -o UserKnownHostsFile=/dev/null \
                                          -o ConnectTimeout=5 \
                                          -o BatchMode=no \
                                          "${SSH_USER}@${ip}" "echo ok" &>/dev/null; then
                connected=true
                break
            fi

            echo -n "."
            sleep "$SSH_RETRY_INTERVAL"
            elapsed=$((elapsed + SSH_RETRY_INTERVAL))
        done

        echo ""

        if [[ "$connected" = true ]]; then
            log_success "Servidor ${name} (${ip}) listo y respondiendo por SSH."
        else
            log_error "Tiempo de espera agotado (${SSH_TIMEOUT}s) intentando conectar a ${name} (${ip}:22)."
            log_error "Verifica las reglas de Network Security Group (NSG) o el estado de la VM en Azure Portal."
            exit 1
        fi
    done
}

# ------------------------------------------------------------------------------
# Fase 5: Ejecución de Ansible Playbook
# ------------------------------------------------------------------------------
run_ansible() {
    log_step "PASO 5: Aprovisionamiento con Ansible Playbook"

    cd "$ANSIBLE_DIR"

    # Ping de verificación de Ansible
    # log_info "Ejecutando ping de Ansible a todos los hosts..."
    # ansible all -i "$INVENTORY_FILE" -m ping

    log_info "Ejecutando playbook.yml..."
    ansible-playbook -i "$INVENTORY_FILE" playbook.yml

    log_success "Playbook de Ansible ejecutado con éxito."
    cd "$SCRIPT_DIR"
}

# ------------------------------------------------------------------------------
# Fase 6: Verificaciones Posteriores (Post-deploy checks)
# ------------------------------------------------------------------------------
post_deploy_checks() {
    log_step "PASO 6: Comprobaciones de Salud Post-Despliegue"

    log_info "Verificando respuesta del servidor Nginx (HTTP puerto 80)..."
    local nginx_status
    nginx_status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 "http://${NGINX_IP}" || echo "ERR")
    if [[ "$nginx_status" == "200" || "$nginx_status" == "301" || "$nginx_status" == "302" ]]; then
        log_success "Nginx está activo y respondiendo (Código HTTP: ${nginx_status})"
    else
        log_warn "Nginx devolvió código '${nginx_status}'. Podría estar terminando de iniciar o requerir unos segundos adicionales."
    fi

    log_info "Verificando servicio Jenkins (HTTP puerto 80)..."
    local jenkins_status
    jenkins_status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 "http://${JENKINS_IP}" || echo "ERR")
    if [[ "$jenkins_status" != "ERR" && "$jenkins_status" != "000" ]]; then
        log_success "Jenkins está respondiendo (Código HTTP: ${jenkins_status})"
    else
        log_warn "Jenkins está iniciando sus contenedores Docker. Puede tomar 1 a 2 minutos adicionales."
    fi

    log_info "Verificando SonarQube (HTTP puerto 9000)..."
    local sonar_status
    sonar_status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 "http://${JENKINS_IP}:9000" || echo "ERR")
    if [[ "$sonar_status" != "ERR" && "$sonar_status" != "000" ]]; then
        log_success "SonarQube está respondiendo (Código HTTP: ${sonar_status})"
    else
        log_warn "SonarQube suele tardar entre 1 y 3 minutos en inicializar su base de datos y estar listo."
    fi

    echo -e "\n${BOLD}${GREEN}======================================================================${NC}"
    echo -e "${BOLD}${GREEN}🎉 ¡DESPLIEGUE COMPLETADO EXITOSAMENTE!${NC}"
    echo -e "${BOLD}${GREEN}======================================================================${NC}"
    echo -e "${BOLD}Resumen de Acceso a Servicios:${NC}"
    echo -e "   • Nginx Web:      ${CYAN}http://${NGINX_IP}${NC}"
    echo -e "   • Jenkins CI:     ${CYAN}http://${JENKINS_IP}${NC}"
    echo -e "   • SonarQube:      ${CYAN}http://${JENKINS_IP}:9000${NC}"
    echo -e "   • Credenciales:   Usuario: ${BOLD}${SSH_USER}${NC} | Password: ${BOLD}${SSH_PASS}${NC}"
    echo -e "   • Acceso SSH:     ${CYAN}ssh ${SSH_USER}@${NGINX_IP}${NC}"
    echo -e "                     ${CYAN}ssh ${SSH_USER}@${JENKINS_IP}${NC}"
    echo -e "${BOLD}${GREEN}======================================================================${NC}\n"
}

# ------------------------------------------------------------------------------
# Opción Destruir Infraestructura
# ------------------------------------------------------------------------------
destroy_infrastructure() {
    log_step "DESTRUCCIÓN DE INFRAESTRUCTURA"
    log_warn "Esta acción eliminará TODOS los recursos creados en Azure por Terraform."
    read -p "¿Estás seguro de que deseas destruir la infraestructura? (escribe 'si' para confirmar): " -r confirm

    if [[ "$confirm" != "si" && "$confirm" != "yes" ]]; then
        log_info "Operación de destrucción cancelada."
        exit 0
    fi

    cd "$TF_DIR"
    log_info "Ejecutando terraform destroy..."
    terraform destroy -auto-approve
    log_success "Infraestructura destruida correctamente."

    if [[ -f "$INVENTORY_FILE" ]]; then
        rm -f "$INVENTORY_FILE"
        log_info "Inventario ${INVENTORY_FILE} eliminado."
    fi
    cd "$SCRIPT_DIR"
}

# ------------------------------------------------------------------------------
# Flujo Principal
# ------------------------------------------------------------------------------
main() {
    local action="all"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--check-only)
                action="check"
                shift
                ;;
            -t|--terraform-only)
                action="terraform"
                shift
                ;;
            -a|--ansible-only)
                action="ansible"
                shift
                ;;
            -f|--force)
                FORCE_TERRAFORM=true
                shift
                ;;
            -d|--destroy)
                action="destroy"
                shift
                ;;
            *)
                log_error "Opción no reconocida: $1"
                show_help
                exit 1
                ;;
        esac
    done

    check_dependencies
    get_tf_credentials

    case "$action" in
        check)
            log_success "Todas las comprobaciones previas finalizaron satisfactoriamente."
            ;;
        destroy)
            destroy_infrastructure
            ;;
        terraform)
            run_terraform
            extract_ips
            generate_inventory
            log_info "Proceso de Terraform finalizado. Puedes continuar con Ansible usando: ./deploy.sh --ansible-only"
            ;;
        ansible)
            extract_ips
            generate_inventory
            wait_for_ssh
            run_ansible
            post_deploy_checks
            ;;
        all)
            run_terraform
            extract_ips
            generate_inventory
            wait_for_ssh
            run_ansible
            post_deploy_checks
            ;;
    esac
}

main "$@"
