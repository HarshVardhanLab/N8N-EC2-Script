#!/usr/bin/env bash
# =============================================================================
# setup-n8n.sh — Production-ready n8n installer for AWS EC2 Ubuntu 22.04/24.04
# Author  : DevOps Engineer
# Version : 2.0.0
# License : MIT
# =============================================================================
# Usage:
#   chmod +x setup-n8n.sh
#   ./setup-n8n.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# TRAP — run cleanup() on any unexpected exit
# -----------------------------------------------------------------------------
trap 'on_error $LINENO' ERR
trap 'cleanup' EXIT

# =============================================================================
# ANSI COLOUR CODES
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# =============================================================================
# GLOBAL DEFAULTS  (overridden by optional prompts)
# =============================================================================
N8N_PORT="${N8N_PORT:-5678}"
CONTAINER_NAME="${CONTAINER_NAME:-n8n}"
N8N_DIR="${N8N_DIR:-$HOME/n8n}"
DOMAIN_NAME=""
USE_HTTPS=false
LOG_FILE="/tmp/setup-n8n-$(date +%Y%m%d-%H%M%S).log"

# =============================================================================
# LOGGING HELPERS
# =============================================================================
log()     { echo -e "${BOLD}[$(date '+%H:%M:%S')]${RESET} $*" | tee -a "$LOG_FILE"; }
info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE" >&2; }
step()    { echo -e "\n${BLUE}${BOLD}━━━  $* ${RESET}\n" | tee -a "$LOG_FILE"; }

banner() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║          n8n  ·  Docker Installer  ·  AWS EC2            ║"
  echo "║          Ubuntu 22.04 / 24.04  —  Production Ready       ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

# =============================================================================
# ERROR HANDLER
# =============================================================================
on_error() {
  local line="${1:-unknown}"
  error "An unexpected error occurred on line ${line}."
  error "Check the full log: ${LOG_FILE}"
  error "n8n installation FAILED."
  exit 1
}

# =============================================================================
# CLEANUP — called on EXIT (success or failure)
# =============================================================================
cleanup() {
  # Nothing destructive here — just informational.
  # Extend this function to remove temp files if needed.
  :
}

# =============================================================================
# FUNCTION: check_container_exists
# Detects whether an n8n container (running OR stopped) already exists.
# Sets global flags:
#   CONTAINER_EXISTS=true/false
#   CONTAINER_RUNNING=true/false
#   OLD_WEBHOOK_URL  — the WEBHOOK_URL currently baked into the container env
# =============================================================================
check_container_exists() {
  step "Checking for existing n8n container"

  CONTAINER_EXISTS=false
  CONTAINER_RUNNING=false
  OLD_WEBHOOK_URL=""

  # Does ANY container (running or stopped) exist with this name?
  if docker ps -a --filter "name=^${CONTAINER_NAME}$" \
       --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then

    CONTAINER_EXISTS=true

    # Is it currently running?
    if docker ps --filter "name=^${CONTAINER_NAME}$" --filter "status=running" \
         --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
      CONTAINER_RUNNING=true
    fi

    # Extract current WEBHOOK_URL from container inspect (best-effort)
    OLD_WEBHOOK_URL=$(docker inspect "${CONTAINER_NAME}" 2>/dev/null \
      | grep -oP '(?<="WEBHOOK_URL=)[^"]+' | head -1 || true)

    if $CONTAINER_RUNNING; then
      info "Container '${CONTAINER_NAME}' EXISTS and is RUNNING."
    else
      info "Container '${CONTAINER_NAME}' EXISTS but is STOPPED."
    fi
    [[ -n "$OLD_WEBHOOK_URL" ]] && info "Current WEBHOOK_URL: ${OLD_WEBHOOK_URL}"

  else
    info "No existing container named '${CONTAINER_NAME}' found."
  fi
}

# =============================================================================
# FUNCTION: update_webhook_url
# Patches the WEBHOOK_URL inside docker-compose.yml to the current public IP,
# then recreates the container so the new env var takes effect immediately.
# Data volume is preserved — no data is lost.
# =============================================================================
update_webhook_url() {
  step "Updating WEBHOOK_URL with current public IP"

  local compose_file="${N8N_DIR}/docker-compose.yml"

  # Build the new webhook URL
  local new_webhook
  if [[ -n "$DOMAIN_NAME" ]]; then
    local proto="http"
    $USE_HTTPS && proto="https"
    new_webhook="${proto}://${DOMAIN_NAME}/"
  else
    new_webhook="http://${PUBLIC_IP}:${N8N_PORT}/"
  fi

  WEBHOOK_URL="$new_webhook"

  if [[ ! -f "$compose_file" ]]; then
    warn "docker-compose.yml not found at ${compose_file}."
    warn "Regenerating it now with the new IP…"
    create_compose_file
    return 0
  fi

  # Replace the WEBHOOK_URL line in the existing compose file
  # Handles both  "- WEBHOOK_URL=..."  and  "WEBHOOK_URL=..."  forms
  if grep -q "WEBHOOK_URL=" "$compose_file"; then
    sed -i "s|WEBHOOK_URL=.*|WEBHOOK_URL=${new_webhook}|g" "$compose_file"
    success "WEBHOOK_URL updated → ${new_webhook}"
  else
    warn "WEBHOOK_URL line not found in compose file — regenerating file."
    create_compose_file
  fi
}

# =============================================================================
# FUNCTION: restart_existing_container
# Stops and removes the old container (keeping the volume), then brings it
# back up with the refreshed docker-compose.yml (new IP / env vars).
# =============================================================================
restart_existing_container() {
  step "Restarting existing n8n container with updated configuration"
  cd "${N8N_DIR}"

  info "Stopping container '${CONTAINER_NAME}'…"
  docker compose down --remove-orphans >> "$LOG_FILE" 2>&1
  success "Container stopped"

  info "Pulling latest n8nio/n8n image (checking for updates)…"
  docker compose pull >> "$LOG_FILE" 2>&1
  success "Image check done"

  info "Starting container with new WEBHOOK_URL: ${WEBHOOK_URL}…"
  docker compose up -d >> "$LOG_FILE" 2>&1
  success "Container restarted successfully"

  info "Waiting 5 s for n8n to initialise…"
  sleep 5
}

# =============================================================================
# FUNCTION: check_root
# Ensures the script is run with root / sudo privileges.
# =============================================================================
check_root() {
  step "Checking privileges"
  if [[ "$EUID" -ne 0 ]]; then
    error "This script must be run as root or with sudo."
    error "Run: sudo ./setup-n8n.sh"
    exit 1
  fi
  success "Running as root — OK"
}

# =============================================================================
# FUNCTION: check_internet
# Verifies outbound internet connectivity before doing anything expensive.
# =============================================================================
check_internet() {
  step "Checking internet connectivity"
  if ! curl -fsSL --max-time 10 https://www.google.com -o /dev/null 2>/dev/null; then
    error "No internet connectivity detected. Aborting."
    exit 1
  fi
  success "Internet connectivity — OK"
}

# =============================================================================
# FUNCTION: detect_os
# Confirms we are on a supported Ubuntu release.
# =============================================================================
detect_os() {
  step "Detecting operating system"
  if [[ ! -f /etc/os-release ]]; then
    error "/etc/os-release not found. Cannot detect OS."
    exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_NAME="${NAME:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  info "Detected: ${OS_NAME} ${OS_VERSION}"

  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This script is optimised for Ubuntu. Proceeding anyway — YMMV."
  fi
  success "OS check passed"
}

# =============================================================================
# FUNCTION: detect_public_ip
# Tries several metadata / STUN endpoints to find the server's public IP.
# =============================================================================
detect_public_ip() {
  step "Detecting public IP address"
  local ip=""

  # AWS EC2 IMDSv2 (preferred on EC2)
  local token
  token=$(curl -fsSL --max-time 3 \
    -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)

  if [[ -n "$token" ]]; then
    ip=$(curl -fsSL --max-time 3 \
      -H "X-aws-ec2-metadata-token: $token" \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)
  fi

  # Fallback: public IP lookup services
  if [[ -z "$ip" ]]; then
    ip=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
      || curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
      || curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null \
      || true)
  fi

  # Ultimate fallback: local hostname
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I | awk '{print $1}')
    warn "Could not detect public IP — using local IP: ${ip}"
  fi

  PUBLIC_IP="${ip// /}"   # strip any whitespace
  success "Public IP: ${PUBLIC_IP}"
}

# =============================================================================
# FUNCTION: optional_prompts
# Interactively asks the user for optional customisations.
# =============================================================================
optional_prompts() {
  step "Optional configuration"
  echo -e "${YELLOW}Press ENTER to accept defaults shown in [brackets].${RESET}\n"

  # --- Port ---
  read -rp "  n8n port [${N8N_PORT}]: " input_port
  if [[ -n "$input_port" ]]; then
    if [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
      N8N_PORT="$input_port"
    else
      warn "Invalid port '${input_port}'. Using default ${N8N_PORT}."
    fi
  fi

  # --- Container name ---
  read -rp "  Container name [${CONTAINER_NAME}]: " input_name
  [[ -n "$input_name" ]] && CONTAINER_NAME="$input_name"

  # --- Domain name ---
  read -rp "  Domain name (leave blank to use IP) []: " input_domain
  if [[ -n "$input_domain" ]]; then
    DOMAIN_NAME="$input_domain"
    info "Domain set to: ${DOMAIN_NAME}"

    # --- HTTPS ---
    read -rp "  Prepare HTTPS/TLS config? (yes/no) [no]: " input_https
    if [[ "${input_https,,}" =~ ^(yes|y)$ ]]; then
      USE_HTTPS=true
      info "HTTPS preparation enabled. (Certbot steps will be printed at the end.)"
    fi
  fi

  # --- Working directory ---
  read -rp "  n8n project directory [${N8N_DIR}]: " input_dir
  [[ -n "$input_dir" ]] && N8N_DIR="$input_dir"

  echo ""
  success "Configuration accepted"
}

# =============================================================================
# FUNCTION: system_update
# Updates APT package lists and upgrades installed packages.
# =============================================================================
system_update() {
  step "Updating & upgrading system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y                        >> "$LOG_FILE" 2>&1
  apt-get upgrade -y                       >> "$LOG_FILE" 2>&1
  apt-get install -y \
    curl \
    wget \
    gnupg \
    lsb-release \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
    ufw                                    >> "$LOG_FILE" 2>&1
  success "System packages updated"
}

# =============================================================================
# FUNCTION: install_docker
# Installs Docker Engine via the official Docker apt repository.
# Skips installation if Docker is already present.
# =============================================================================
install_docker() {
  step "Installing Docker Engine"

  if command -v docker &>/dev/null; then
    local ver
    ver=$(docker --version)
    info "Docker is already installed: ${ver}"
    success "Skipping Docker installation"
    return 0
  fi

  info "Adding Docker's official GPG key & repository…"

  # Remove any legacy docker packages
  apt-get remove -y \
    docker docker-engine docker.io containerd runc 2>/dev/null || true

  # Add Docker GPG key
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Add Docker apt repository
  echo \
    "deb [arch=$(dpkg --print-architecture) \
    signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -y >> "$LOG_FILE" 2>&1
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin    >> "$LOG_FILE" 2>&1

  success "Docker Engine installed"
}

# =============================================================================
# FUNCTION: install_compose
# Verifies Docker Compose v2 plugin is available (installed above with Docker).
# Falls back to standalone binary if plugin is missing.
# =============================================================================
install_compose() {
  step "Verifying Docker Compose v2"

  if docker compose version &>/dev/null; then
    local ver
    ver=$(docker compose version --short 2>/dev/null || docker compose version)
    success "Docker Compose v2 available: ${ver}"
    return 0
  fi

  warn "Docker Compose plugin not found — installing standalone binary…"

  local compose_version
  compose_version=$(curl -fsSL \
    "https://api.github.com/repos/docker/compose/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')

  local arch
  arch=$(uname -m)
  [[ "$arch" == "x86_64" ]] && arch="x86_64"
  [[ "$arch" == "aarch64" ]] && arch="aarch64"

  curl -fsSL \
    "https://github.com/docker/compose/releases/download/v${compose_version}/docker-compose-linux-${arch}" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose

  # Create shim so 'docker compose' works
  mkdir -p /usr/local/lib/docker/cli-plugins
  ln -sf /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

  success "Docker Compose ${compose_version} installed"
}

# =============================================================================
# FUNCTION: configure_docker_service
# Enables & starts the Docker daemon; adds current (sudo-invoking) user to the
# docker group so they can run docker without sudo post-install.
# =============================================================================
configure_docker_service() {
  step "Configuring Docker service"

  systemctl enable docker  >> "$LOG_FILE" 2>&1
  systemctl start  docker  >> "$LOG_FILE" 2>&1
  success "Docker service enabled & started"

  # SUDO_USER is set when the script is run with sudo
  local target_user="${SUDO_USER:-$USER}"
  if [[ -n "$target_user" && "$target_user" != "root" ]]; then
    usermod -aG docker "$target_user"
    success "User '${target_user}' added to the 'docker' group"
    info "Log out and back in (or run 'newgrp docker') for group change to take effect."
  fi
}

# =============================================================================
# FUNCTION: configure_firewall
# Opens the n8n port in UFW if UFW is installed and active.
# =============================================================================
configure_firewall() {
  step "Configuring firewall (UFW)"

  if ! command -v ufw &>/dev/null; then
    warn "UFW not found — skipping firewall configuration."
    warn "Ensure port ${N8N_PORT} is open in your AWS Security Group."
    return 0
  fi

  local ufw_status
  ufw_status=$(ufw status | head -1)

  if [[ "$ufw_status" == *"inactive"* ]]; then
    warn "UFW is installed but inactive — skipping rule (it would activate UFW)."
    warn "Ensure port ${N8N_PORT} is open in your AWS Security Group."
    return 0
  fi

  ufw allow "${N8N_PORT}/tcp" comment "n8n workflow automation" >> "$LOG_FILE" 2>&1
  success "UFW: port ${N8N_PORT}/tcp allowed"

  if $USE_HTTPS; then
    ufw allow 80/tcp  comment "HTTP (ACME challenge)" >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp comment "HTTPS"                 >> "$LOG_FILE" 2>&1
    success "UFW: ports 80/tcp and 443/tcp allowed (HTTPS)"
  fi
}

# =============================================================================
# FUNCTION: create_project_dir
# Creates the n8n working directory and persistent data folder.
# =============================================================================
create_project_dir() {
  step "Creating n8n project directory"

  mkdir -p "${N8N_DIR}/n8n_data"

  # Set ownership so the n8n container (uid 1000) can write to the volume
  chown -R 1000:1000 "${N8N_DIR}/n8n_data" 2>/dev/null || true

  success "Project directory: ${N8N_DIR}"
  success "Persistent data:   ${N8N_DIR}/n8n_data"
}

# =============================================================================
# FUNCTION: create_compose_file
# Writes the docker-compose.yml into the project directory.
# =============================================================================
create_compose_file() {
  step "Generating docker-compose.yml"

  # Determine the host/webhook base URL
  local host_or_domain
  if [[ -n "$DOMAIN_NAME" ]]; then
    host_or_domain="$DOMAIN_NAME"
    local protocol="https"
    $USE_HTTPS || protocol="http"
    WEBHOOK_URL="${protocol}://${host_or_domain}/"
  else
    host_or_domain="${PUBLIC_IP}"
    WEBHOOK_URL="http://${PUBLIC_IP}:${N8N_PORT}/"
  fi

  cat > "${N8N_DIR}/docker-compose.yml" <<EOF
# =============================================================================
# docker-compose.yml — n8n  (generated by setup-n8n.sh)
# Generated : $(date)
# =============================================================================

version: "3.8"

services:
  ${CONTAINER_NAME}:
    image: n8nio/n8n:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    ports:
      - "${N8N_PORT}:5678"
    environment:
      # Network / host configuration
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - NODE_ENV=production

      # Webhook URL — used by n8n to build callback URLs
      - WEBHOOK_URL=${WEBHOOK_URL}

      # Optional: set a timezone (https://momentjs.com/timezone/)
      # - GENERIC_TIMEZONE=UTC

      # Optional: basic-auth credentials for the UI (uncomment to enable)
      # - N8N_BASIC_AUTH_ACTIVE=true
      # - N8N_BASIC_AUTH_USER=admin
      # - N8N_BASIC_AUTH_PASSWORD=changeme

      # Optional: restrict access to specific origin
      # - N8N_CORS_ENABLE=true

    volumes:
      # Persistent storage — survives container restarts/upgrades
      - ./n8n_data:/home/node/.n8n

    # Limit resource usage (optional — tune to your instance size)
    # deploy:
    #   resources:
    #     limits:
    #       cpus: '1.0'
    #       memory: 512M
EOF

  success "docker-compose.yml written to ${N8N_DIR}/docker-compose.yml"
}

# =============================================================================
# FUNCTION: start_n8n
# Fresh install path: pulls the latest image and starts the container.
# Only called when NO existing container was found.
# =============================================================================
start_n8n() {
  step "Pulling n8n image and starting container (fresh install)"
  cd "${N8N_DIR}"

  info "Pulling latest n8nio/n8n image…"
  docker compose pull >> "$LOG_FILE" 2>&1
  success "Image pulled"

  info "Starting n8n container…"
  docker compose up -d >> "$LOG_FILE" 2>&1
  success "Container started"

  # Give the container a moment to initialise
  info "Waiting 5 s for n8n to initialise…"
  sleep 5
}

# =============================================================================
# FUNCTION: verify_installation
# Checks the running container and (optionally) the HTTP endpoint.
# =============================================================================
verify_installation() {
  step "Verifying installation"

  # Container running?
  if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" \
       --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    success "Container '${CONTAINER_NAME}' is running"
  else
    error "Container '${CONTAINER_NAME}' does NOT appear to be running."
    error "Check logs with:  docker compose -f ${N8N_DIR}/docker-compose.yml logs"
    exit 1
  fi

  # HTTP health check (best-effort — n8n may still be starting)
  local url="http://127.0.0.1:${N8N_PORT}/healthz"
  info "Probing ${url} (3 attempts)…"
  local attempt
  for attempt in 1 2 3; do
    if curl -fsSL --max-time 5 "$url" -o /dev/null 2>/dev/null; then
      success "n8n HTTP health check passed (attempt ${attempt})"
      return 0
    fi
    sleep 5
  done
  warn "Health check did not respond — n8n may still be starting up."
  warn "Try  curl -I http://127.0.0.1:${N8N_PORT}/  in a minute."
}

# =============================================================================
# FUNCTION: print_summary
# Prints a friendly end-of-run summary with useful commands.
# =============================================================================
print_summary() {
  local access_url
  if [[ -n "$DOMAIN_NAME" ]]; then
    local protocol="http"
    $USE_HTTPS && protocol="https"
    access_url="${protocol}://${DOMAIN_NAME}/"
  else
    access_url="http://${PUBLIC_IP}:${N8N_PORT}/"
  fi

  echo ""
  echo -e "${GREEN}${BOLD}"
  if [[ "${CONTAINER_EXISTS:-false}" == "true" ]]; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          🔄  n8n Container Restarted with New IP!            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
  else
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║               🎉  n8n Installation Complete!                 ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
  fi
  echo -e "${RESET}"

  echo -e "${BOLD}  Access n8n at:${RESET}"
  echo -e "    ${CYAN}${BOLD}${access_url}${RESET}"
  echo ""
  echo -e "${BOLD}  Project directory:${RESET}  ${N8N_DIR}"
  echo -e "${BOLD}  Persistent data:${RESET}    ${N8N_DIR}/n8n_data   ← BACK THIS UP!"
  echo -e "${BOLD}  Install log:${RESET}        ${LOG_FILE}"
  echo ""

  echo -e "${BOLD}  Container status:${RESET}"
  docker ps --filter "name=${CONTAINER_NAME}" \
    --format "    {{.Names}}\t{{.Status}}\t{{.Ports}}"
  echo ""

  echo -e "${BOLD}  Useful Docker commands:${RESET}"
  echo -e "    ${YELLOW}# View live logs${RESET}"
  echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml logs -f"
  echo ""
  echo -e "    ${YELLOW}# Stop n8n${RESET}"
  echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml down"
  echo ""
  echo -e "    ${YELLOW}# Restart n8n${RESET}"
  echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml restart"
  echo ""
  echo -e "    ${YELLOW}# Update to latest n8n image${RESET}"
  echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml pull"
  echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml up -d"
  echo ""
  echo -e "    ${YELLOW}# Enter the container shell${RESET}"
  echo    "    docker exec -it ${CONTAINER_NAME} sh"
  echo ""
  echo -e "${BOLD}  Backup command:${RESET}"
  echo    "    tar czf n8n-backup-\$(date +%Y%m%d).tar.gz ${N8N_DIR}/n8n_data"
  echo ""

  if $USE_HTTPS; then
    echo -e "${BOLD}${YELLOW}  HTTPS — Next steps (Certbot):${RESET}"
    echo    "    sudo apt-get install -y certbot python3-certbot-nginx"
    echo    "    sudo certbot --nginx -d ${DOMAIN_NAME}"
    echo    "    # Then update WEBHOOK_URL in ${N8N_DIR}/docker-compose.yml"
    echo    "    # and run: docker compose -f ${N8N_DIR}/docker-compose.yml up -d"
    echo ""
  fi

  echo -e "${BOLD}  AWS Security Group reminder:${RESET}"
  echo -e "    Ensure port ${N8N_PORT} (TCP inbound) is open in your EC2 Security Group."
  echo ""
  echo -e "${GREEN}${BOLD}  Happy automating! 🚀${RESET}"
  echo ""
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================
main() {
  banner

  # Log file header
  {
    echo "=================================================="
    echo " setup-n8n.sh — started at $(date)"
    echo "=================================================="
  } > "$LOG_FILE"

  # ── Prerequisites (always run) ─────────────────────────────────────────────
  check_root
  check_internet
  detect_os
  detect_public_ip
  optional_prompts
  system_update
  install_docker
  install_compose
  configure_docker_service
  configure_firewall

  # ── Container existence check ──────────────────────────────────────────────
  check_container_exists

  if [[ "$CONTAINER_EXISTS" == "true" ]]; then
    # ── PATH A: Container already exists → update IP & restart ──────────────
    step "Existing container detected — updating IP and restarting"

    # Ensure the project dir / data volume still exist (idempotent)
    create_project_dir

    # Patch WEBHOOK_URL in docker-compose.yml to current public IP
    update_webhook_url

    # Recreate the container with the new env vars (volume is preserved)
    restart_existing_container

  else
    # ── PATH B: No container found → fresh install ───────────────────────────
    step "No existing container — performing fresh installation"

    create_project_dir
    create_compose_file
    start_n8n
  fi

  # ── Always verify & summarise ─────────────────────────────────────────────
  verify_installation
  print_summary
}

main "$@"