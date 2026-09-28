# Azure Infrastructure & Automated Provisioning with Terraform and Ansible

This repository provides an automated, end-to-end Infrastructure as Code (IaC) and configuration management pipeline. It deploys a multi-tier DevOps environment on Microsoft Azure using **Terraform** and configures all operating system dependencies and Docker-based services using **Ansible**.

---

## Architecture Overview

The deployed infrastructure consists of:

- **Networking:**
  - 1 Azure Resource Group (`${prefix_name}-rg`)
  - 1 Virtual Network (`10.0.0.0/16`) & Subnet (`10.0.1.0/24`)
  - 1 Network Security Group (NSG) opening inbound ports:
    - **22** (SSH)
    - **80** (HTTP for Nginx & Jenkins)
    - **9000** (SonarQube)
- **Virtual Machines (Ubuntu 22.04 LTS):**
  - **`nginx` VM:** Hosts the Nginx web server configured to serve web applications (such as the frontend located in `Teclado/`).
  - **`jenkins` VM:** Runs containerized DevOps tools via Docker Compose:
    - **Jenkins** (`madmilodz/jenkinsci:v3`): CI/CD automation server mapped to port `80`.
    - **SonarQube** (`sonarqube:8.2-community`): Static code quality platform mapped to port `9000`.
    - **PostgreSQL** (`postgres:12-alpine`): Dedicated database backend for SonarQube.

```
                  +----------------------------------------------+
                  |                 Azure Cloud                  |
                  |                Virtual Network               |
                  +-----------------------+----------------------+
                                          |
                   +----------------------+----------------------+
                   |                                             |
                   v                                             v
         +-------------------+                         +-------------------+
         |     Nginx VM      |                         |    Jenkins VM     |
         |  (Port 80, 22)    |                         |  (Port 80, 9000)  |
         +-------------------+                         +-------------------+
         | - Nginx Service   |                         | - Docker Engine   |
         | - /var/www/html   |                         | - Jenkins (80)    |
         |   (Teclado App)   |                         | - SonarQube (9000)|
         +-------------------+                         | - Postgres 12(db) |
                                                       +-------------------+
```

---

## Key Fixes & Troubleshooting History

The base project required several critical fixes and structural improvements to achieve seamless, automated operation:

### 1. Python Incompatibility & OS Image Upgrade (Ubuntu Xenial -> Jammy)
* **Problem:** The original Terraform configuration deployed **Ubuntu 16.04 (Xenial)**, which shipped with deprecated Python 3.5.2. Running Ansible produced the fatal error:
  ```text
  requires a minimum of Python2 version 2.7 or Python3 version 3.6. Current version 3.5.2
  ```
* **Solution:** 
  - Upgraded the VM base image in `terraform_for_each_vm/modules/vm/main.tf` to **Ubuntu 22.04 LTS** (`0001-com-ubuntu-server-jammy`, SKU `22_04-lts-gen2`).
  - Added `gather_facts: true` and standardized modern Python 3 interpreters for all playbooks.

### 2. VM Sizing & Regional Quota Restrictions (`Standard_DS1_v2`)
* **Problem:** The machine size was hardcoded to `Standard_DS1_v2`. In multiple Azure regions (such as `canadacentral`) and standard/student subscriptions, `Standard_DS1_v2` is unavailable or restricted by zero-core quotas.
* **Solution:**
  - Parameterized VM sizes in root and module `variables.tf`.
  - Defaulted to `Standard_B2s` (2 vCPUs, 4 GB RAM), providing sufficient RAM for Jenkins, Elasticsearch, and PostgreSQL without exceeding burstable quotas.
  - Added the optional `server_sizes` variable in `terraform.tfvars` allowing granular per-server size customization (e.g., `Standard_B1s` for Nginx and `Standard_B2s` for Jenkins).

### 3. SonarQube Crash & PostgreSQL Incompatibility
* **Problem:** `docker-compose.yml` specified `image: postgres` without a version tag. Docker pulled the latest release (PostgreSQL 17/18), causing:
  - Database container startup failure due to breaking changes in default directory layouts (`/var/lib/postgresql/data`).
  - Incompatibility with `sonarqube:8.2-community`'s bundled JDBC drivers and authentication methods (`scram-sha-256`), causing SonarQube to exit with code 143 (`WebServer is stopped`).
* **Solution:**
  - Pinned the database image to **`postgres:12-alpine`** (the official LTS compatible release for SonarQube 8.x).
  - Explicitly defined `POSTGRES_DB=sonar`, `container_name: db`, and `restart: unless-stopped`.
  - Consolidated data storage to a single standard volume: `postgresql_data:/var/lib/postgresql/data`.
  - Fixed file ownership (`chown`) and permissions for `docker-compose.yml` in Ansible.

### 4. Privilege Escalation (`become: true`) & Non-Interactive Docker Execution
* **Problem:**
  - Running Docker and Docker Compose commands (`docker-compose up -d`, `docker exec`) inside Ansible tasks without explicit privilege escalation caused permission issues when binding ports or interacting with the Docker daemon.
  - Tasks using interactive flags (`docker exec -it`) failed in automated Ansible sessions with:
    ```text
    the input device is not a TTY
    ```
* **Solution:**
  - Added explicit `become: true` along with `become_user: "{{ ansible_user }}"` and `become_method: su` to the Docker Compose execution and plugin installation tasks.
  - Replaced `-it` with standard non-interactive execution (`docker exec`), added a container startup pause, and enabled `ignore_errors: true` on the plugin setup task.

### 5. Unified Automation with `deploy.sh`
* **Problem:** Manual execution required switching directories, awaiting VM creation, discovering dynamic IPs, manually writing Ansible inventory files, and handling transient SSH connectivity delays.
* **Solution:** Created the root orchestrator script [deploy.sh](deploy.sh) that manages the complete lifecycle with health checks and change detection.

---

## 📋 Prerequisites

Before running the deployment script, ensure you have installed:

- **Terraform** (`>= 1.0`)
- **Ansible** & **ansible-playbook** (`>= 2.10`)
- **sshpass** (required for password-based SSH authentication)
- **curl** & **jq** (or Python 3)
- **Azure CLI (`az`)** or Azure Service Principal environment variables:
  ```bash
  # Option A: Login via Azure CLI
  az login

  # Option B: Export Service Principal credentials
  export ARM_SUBSCRIPTION_ID="<your-subscription-id>"
  export ARM_CLIENT_ID="<your-client-id>"
  export ARM_CLIENT_SECRET="<your-client-secret>"
  export ARM_TENANT_ID="<your-tenant-id>"
  ```

---

## Project Structure

```text
App_Infra_Ansible/
├── deploy.sh                     # Master orchestration script (executable)
├── alzar_todo.sh                 # Symlink alias to deploy.sh
├── .gitignore                    # Git ignore rules for state and inventory files
├── README.md                     # Project documentation
│
├── terraform_for_each_vm/        # Terraform infrastructure code
│   ├── main.tf                   # Root resources (Resource Group, VNet, Subnet)
│   ├── variables.tf              # Input variables (region, user, size_servers, etc.)
│   ├── terraform.tfvars          # Variable values and credentials
│   ├── outputs.tf                # Exported VM IPs
│   ├── providers.tf              # AzureRM provider configuration
│   └── modules/
│       └── vm/                   # VM module (NIC, Public IP, NSG, Linux VM)
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
│
├── ansible-pipeline/             # Ansible configuration management
│   ├── playbook.yml              # Plays for Nginx, Docker, Jenkins & SonarQube
│   ├── docker-compose.yml        # Multi-container setup (Jenkins, SonarQube, Postgres)
│   ├── inventory.ini             # Auto-generated by deploy.sh
│   └── requirements.txt
│
└── Teclado/                      # Sample frontend application (HTML/CSS/JS)
    ├── index.html
    ├── script.js
    └── css/
```

---
## How to Run the Deployment

### 1. Configure Variables
Inspect or adjust credentials and region in `terraform_for_each_vm/terraform.tfvars`:

```hcl
region      = "canadacentral" # or "eastus"
user        = "guarinve"
password    = "myPassw0rd"
prefix_name = "devops"
servers     = [ "jenkins", "nginx" ]

# VM instance sizing (Standard_B2s: 2 vCPUs, 4GB RAM)
size_servers = "Standard_B2s"

# Optional: custom sizes per server
# server_sizes = {
#   nginx   = "Standard_B1s"
#   jenkins = "Standard_B2s"
# }
```

### 2. Deploy Everything (Single Command)
Run the root orchestrator:

```bash
./deploy.sh
# or:
./alzar_todo.sh
```

### Command Options

| Flag | Description |
| :--- | :--- |
| *(no arguments)* | Executes the full pipeline (Checks -> Terraform -> SSH Wait -> Ansible -> Post-checks). |
| `-c`, `--check-only` | Runs pre-flight checks (binaries, files, Azure credentials) without changing anything. |
| `-t`, `--terraform-only` | Provisions only the Terraform infrastructure and generates `inventory.ini`. |
| `-a`, `--ansible-only` | Runs only Ansible playbooks (requires active VMs). |
| `-f`, `--force` | Forces `terraform apply` even if no changes are detected. |
| `-d`, `--destroy` | Safely destroys all Azure resources created by Terraform. |
| `-h`, `--help` | Displays help message and usage instructions. |

---

## How the Orchestrator (`deploy.sh`) Works

```
[Step 0: Pre-flight Checks] ──> Validates tools (terraform, ansible, sshpass, curl, jq)
            │
            v
[Step 1: Terraform Phase]   ──> Checks if VMs already exist and runs `terraform plan -detailed-exitcode`
            │                   (Skips apply automatically if no changes are detected!)
            v
[Step 2: IP Extraction]     ──> Queries Terraform outputs for Nginx & Jenkins public IPs
            │
            v
[Step 3: Inventory Gen]     ──> Creates `ansible-pipeline/inventory.ini` dynamically
            │
            v
[Step 4: SSH Polling]       ──> Probes port 22 on each VM until sshd is ready
            │
            v
[Step 5: Ansible Playbook]  ──> Runs `playbook.yml` to install Nginx & Docker services
            │
            v
[Step 6: Health Checks]     ──> Probes HTTP endpoints (Nginx:80, Jenkins:80, Sonar:9000)
```

1. **Smart Change Detection:** Before running `terraform apply`, the script checks `terraform state list` and runs `terraform plan -detailed-exitcode`. If both VMs already exist and there are no infrastructure changes, it **skips `terraform apply` completely**, saving considerable time on repeated runs.
2. **Dynamic Inventory Generation:** Generates `ansible-pipeline/inventory.ini` mapping server roles to their dynamic Azure public IPs and configuring SSH connection parameters (`ansible_user`, `ansible_password`, `StrictHostKeyChecking=no`).
3. **Active SSH Readiness Polling:** Cloud VMs often report created before `sshd` is fully initialized. The script actively polls port 22 with retry logic and timeout protection.
4. **Post-Deployment Verification:** Executes HTTP health checks against each exposed service and prints an access summary.

---

## Service Access & Credentials

Once deployment completes, the services are available at:

| Service | Protocol / Port | URL | Default Credentials |
| :--- | :--- | :--- | :--- |
| **Nginx Web Server** | HTTP / 80 | `http://<NGINX_IP>` | N/A |
| **Jenkins CI/CD** | HTTP / 80 | `http://<JENKINS_IP>` | Setup wizard disabled |
| **SonarQube Quality** | HTTP / 9000 | `http://<JENKINS_IP>:9000` | User: `admin` / Password: `admin` |
| **SSH Direct Access** | SSH / 22 | `ssh <user>@<IP>` | Configured in `terraform.tfvars` |

---

## 🧹 Infrastructure Teardown

To tear down all resources created in Azure and avoid unexpected cloud charges:

```bash
./deploy.sh --destroy
```
The script will request manual confirmation before executing `terraform destroy -auto-approve` and cleaning up local inventory files.