#!/usr/bin/env bash
# =============================================================================
# setup-n8n.sh — Production-ready n8n installer for AWS EC2 Ubuntu 22.04/24.04
# Author  : DevOps Engineer
# Version : 3.0.0
# License : MIT
# =============================================================================
# Usage:
#   chmod +x setup-n8n.sh
#   ./setup-n8n.sh
#
# HTTPS Options (all FREE, no domain purchase required):
#   1) Cloudflare Tunnel  — instant HTTPS via *.trycloudflare.com (no domain)
#   2) DuckDNS + Certbot  — free permanent subdomain + Let's Encrypt SSL
#   3) Own Domain + Nginx — bring your own domain, Certbot issues SSL
#   4) IP only (no HTTPS) — plain HTTP on port 5678
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# TRAP — run cleanup() on any unexpected exit
# -----------------------------------------------------------------------------
trap 'on_error $LINENO' ERR
trap 'cleanup'          EXIT

# =============================================================================
# ANSI COLOUR CODES
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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

# HTTPS mode: "none" | "cloudflare_tunnel" | "duckdns" | "own_domain"
HTTPS_MODE="none"
DUCKDNS_TOKEN=""
DUCKDNS_SUBDOMAIN=""
TUNNEL_URL=""        # populated after cloudflared starts
FINAL_URL=""         # the URL shown to the user at the end

# =============================================================================
# LOGGING HELPERS
# =============================================================================
log()     { echo -e "${BOLD}[$(date '+%H:%M:%S')]${RESET} $*" | tee -a "$LOG_FILE"; }
info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE" >&2; }
step()    { echo -e "\n${BLUE}${BOLD}━━━  $* ${RESET}\n" | tee -a "$LOG_FILE"; }
heading() { echo -e "\n${MAGENTA}${BOLD}  ▶  $*${RESET}\n"; }

banner() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║         n8n  ·  Docker Installer  ·  AWS EC2  v3.0          ║"
  echo "║   Ubuntu 22.04 / 24.04  —  Production Ready  —  Free HTTPS  ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
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
  # Remove any temp files created during the run
  rm -f /tmp/cloudflared_output.log 2>/dev/null || true
}

# =============================================================================
# FUNCTION: check_root
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
# Uses EC2 IMDSv2 first, then several public fallbacks.
# =============================================================================
detect_public_ip() {
  step "Detecting public IP address"
  local ip=""

  # AWS EC2 IMDSv2
  local token
  token=$(curl -fsSL --max-time 3 \
    -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)

  if [[ -n "$token" ]]; then
    ip=$(curl -fsSL --max-time 3 \
      -H "X-aws-ec2-metadata-token: $token" \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)
  fi

  # Fallback: public lookup services
  if [[ -z "$ip" ]]; then
    ip=$(curl -fsSL --max-time 5 https://ifconfig.me    2>/dev/null \
      || curl -fsSL --max-time 5 https://api.ipify.org  2>/dev/null \
      || curl -fsSL --max-time 5 https://icanhazip.com  2>/dev/null \
      || true)
  fi

  # Ultimate fallback
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I | awk '{print $1}')
    warn "Could not detect public IP — using local IP: ${ip}"
  fi

  PUBLIC_IP="${ip// /}"
  success "Public IP: ${PUBLIC_IP}"
}

# =============================================================================
# FUNCTION: optional_prompts
# Asks the user how they want HTTPS configured, plus basic options.
# =============================================================================
optional_prompts() {
  step "Configuration"
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

  # --- Working directory ---
  read -rp "  n8n project directory [${N8N_DIR}]: " input_dir
  [[ -n "$input_dir" ]] && N8N_DIR="$input_dir"

  echo ""
  # ── HTTPS / SSL Menu ──────────────────────────────────────────────────────
  echo -e "${BOLD}${CYAN}  ┌─────────────────────────────────────────────────┐${RESET}"
  echo -e "${BOLD}${CYAN}  │        FREE HTTPS / SSL Setup Options           │${RESET}"
  echo -e "${BOLD}${CYAN}  ├─────────────────────────────────────────────────┤${RESET}"
  echo -e "${BOLD}${CYAN}  │  1)${RESET} Cloudflare Tunnel  ${GREEN}(EASIEST — no domain!)${RESET}   ${CYAN}│${RESET}"
  echo -e "${BOLD}${CYAN}  │     Instant HTTPS via *.trycloudflare.com       │${RESET}"
  echo -e "${BOLD}${CYAN}  │                                                 │${RESET}"
  echo -e "${BOLD}${CYAN}  │  2)${RESET} DuckDNS + Let's Encrypt  ${GREEN}(free forever)${RESET}   ${CYAN}│${RESET}"
  echo -e "${BOLD}${CYAN}  │     yourname.duckdns.org  + Nginx + Certbot     │${RESET}"
  echo -e "${BOLD}${CYAN}  │                                                 │${RESET}"
  echo -e "${BOLD}${CYAN}  │  3)${RESET} Own Domain + Nginx + Certbot               ${CYAN}│${RESET}"
  echo -e "${BOLD}${CYAN}  │     You already have a domain name              │${RESET}"
  echo -e "${BOLD}${CYAN}  │                                                 │${RESET}"
  echo -e "${BOLD}${CYAN}  │  4)${RESET} No HTTPS  (plain HTTP on port ${N8N_PORT})       ${CYAN}│${RESET}"
  echo -e "${BOLD}${CYAN}  └─────────────────────────────────────────────────┘${RESET}"
  echo ""

  local choice
  read -rp "  Choose HTTPS option [1/2/3/4] (default: 4): " choice
  choice="${choice:-4}"

  case "$choice" in
    1)
      HTTPS_MODE="cloudflare_tunnel"
      USE_HTTPS=true
      info "Selected: Cloudflare Tunnel (free, no domain needed)"
      ;;
    2)
      HTTPS_MODE="duckdns"
      USE_HTTPS=true
      echo ""
      heading "DuckDNS Setup"
      echo -e "  ${YELLOW}Step 1:${RESET} Go to ${BOLD}https://duckdns.org${RESET} and log in (Google/GitHub)"
      echo -e "  ${YELLOW}Step 2:${RESET} Create a subdomain, e.g. ${BOLD}my-n8n${RESET}"
      echo -e "  ${YELLOW}Step 3:${RESET} Copy your token from the top of the DuckDNS page"
      echo ""
      read -rp "  Your DuckDNS subdomain (e.g. my-n8n → my-n8n.duckdns.org): " DUCKDNS_SUBDOMAIN
      if [[ -z "$DUCKDNS_SUBDOMAIN" ]]; then
        warn "No subdomain entered. Falling back to plain HTTP."
        HTTPS_MODE="none"; USE_HTTPS=false
      else
        read -rp "  Your DuckDNS token: " DUCKDNS_TOKEN
        if [[ -z "$DUCKDNS_TOKEN" ]]; then
          warn "No token entered. Falling back to plain HTTP."
          HTTPS_MODE="none"; USE_HTTPS=false
        else
          DOMAIN_NAME="${DUCKDNS_SUBDOMAIN}.duckdns.org"
          info "Will configure: https://${DOMAIN_NAME}"
        fi
      fi
      ;;
    3)
      HTTPS_MODE="own_domain"
      USE_HTTPS=true
      echo ""
      read -rp "  Your domain name (e.g. n8n.mysite.com): " input_domain
      if [[ -z "$input_domain" ]]; then
        warn "No domain entered. Falling back to plain HTTP."
        HTTPS_MODE="none"; USE_HTTPS=false
      else
        DOMAIN_NAME="$input_domain"
        echo ""
        echo -e "  ${YELLOW}Important:${RESET} Make sure your domain's DNS A record points to:"
        echo -e "  ${BOLD}${PUBLIC_IP}${RESET}"
        echo -e "  (Do this in your domain registrar or Cloudflare DNS panel)"
        echo ""
        read -rp "  Press ENTER when DNS is configured (or Ctrl+C to abort)..." _confirm
        info "Will configure: https://${DOMAIN_NAME}"
      fi
      ;;
    4|*)
      HTTPS_MODE="none"
      USE_HTTPS=false
      info "Selected: Plain HTTP on port ${N8N_PORT}"
      ;;
  esac

  echo ""
  success "Configuration accepted"
}

# =============================================================================
# FUNCTION: system_update
# =============================================================================
system_update() {
  step "Updating & upgrading system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update  -y >> "$LOG_FILE" 2>&1
  apt-get upgrade -y >> "$LOG_FILE" 2>&1
  apt-get install -y \
    curl wget gnupg lsb-release ca-certificates \
    apt-transport-https software-properties-common \
    ufw jq >> "$LOG_FILE" 2>&1
  success "System packages updated"
}

# =============================================================================
# FUNCTION: install_docker
# =============================================================================
install_docker() {
  step "Installing Docker Engine"

  if command -v docker &>/dev/null; then
    local ver; ver=$(docker --version)
    info "Docker already installed: ${ver}"
    success "Skipping Docker installation"
    return 0
  fi

  info "Adding Docker's official GPG key & repository…"
  apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) \
    signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -y >> "$LOG_FILE" 2>&1
  apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

  success "Docker Engine installed"
}

# =============================================================================
# FUNCTION: install_compose
# =============================================================================
install_compose() {
  step "Verifying Docker Compose v2"

  if docker compose version &>/dev/null; then
    local ver; ver=$(docker compose version --short 2>/dev/null || docker compose version)
    success "Docker Compose v2 available: ${ver}"
    return 0
  fi

  warn "Docker Compose plugin not found — installing standalone binary…"

  local compose_version arch
  compose_version=$(curl -fsSL \
    "https://api.github.com/repos/docker/compose/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
  arch=$(uname -m)

  curl -fsSL \
    "https://github.com/docker/compose/releases/download/v${compose_version}/docker-compose-linux-${arch}" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  mkdir -p /usr/local/lib/docker/cli-plugins
  ln -sf /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

  success "Docker Compose ${compose_version} installed"
}

# =============================================================================
# FUNCTION: configure_docker_service
# =============================================================================
configure_docker_service() {
  step "Configuring Docker service"
  systemctl enable docker >> "$LOG_FILE" 2>&1
  systemctl start  docker >> "$LOG_FILE" 2>&1
  success "Docker service enabled & started"

  local target_user="${SUDO_USER:-$USER}"
  if [[ -n "$target_user" && "$target_user" != "root" ]]; then
    usermod -aG docker "$target_user"
    success "User '${target_user}' added to the 'docker' group"
    info "Log out and back in (or run 'newgrp docker') for group change to take effect."
  fi
}

# =============================================================================
# FUNCTION: configure_firewall
# =============================================================================
configure_firewall() {
  step "Configuring firewall (UFW)"

  if ! command -v ufw &>/dev/null; then
    warn "UFW not found — skipping. Ensure required ports are open in your AWS Security Group."
    return 0
  fi

  local ufw_status
  ufw_status=$(ufw status | head -1)

  if [[ "$ufw_status" == *"inactive"* ]]; then
    warn "UFW inactive — skipping (it would activate UFW unexpectedly)."
    warn "Ensure the required ports are open in your AWS Security Group."
    return 0
  fi

  # Always open n8n port
  ufw allow "${N8N_PORT}/tcp" comment "n8n" >> "$LOG_FILE" 2>&1
  success "UFW: port ${N8N_PORT}/tcp allowed"

  # Open HTTP/HTTPS if needed for Nginx / Certbot
  if [[ "$HTTPS_MODE" == "duckdns" || "$HTTPS_MODE" == "own_domain" ]]; then
    ufw allow 80/tcp  comment "HTTP Certbot" >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp comment "HTTPS"        >> "$LOG_FILE" 2>&1
    success "UFW: ports 80 and 443 allowed"
  fi
}

# =============================================================================
# FUNCTION: check_container_exists
# Detects whether the n8n container (running OR stopped) already exists.
# =============================================================================
check_container_exists() {
  step "Checking for existing n8n container"

  CONTAINER_EXISTS=false
  CONTAINER_RUNNING=false
  OLD_WEBHOOK_URL=""

  if docker ps -a --filter "name=^${CONTAINER_NAME}$" \
       --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then

    CONTAINER_EXISTS=true

    if docker ps --filter "name=^${CONTAINER_NAME}$" --filter "status=running" \
         --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
      CONTAINER_RUNNING=true
    fi

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
# Patches the WEBHOOK_URL in docker-compose.yml with the current URL.
# =============================================================================
update_webhook_url() {
  step "Updating WEBHOOK_URL"

  local compose_file="${N8N_DIR}/docker-compose.yml"

  if [[ ! -f "$compose_file" ]]; then
    warn "docker-compose.yml not found — regenerating…"
    create_compose_file
    return 0
  fi

  if grep -q "WEBHOOK_URL=" "$compose_file"; then
    sed -i "s|WEBHOOK_URL=.*|WEBHOOK_URL=${FINAL_URL}|g" "$compose_file"
    success "WEBHOOK_URL updated → ${FINAL_URL}"
  else
    warn "WEBHOOK_URL line not found — regenerating compose file."
    create_compose_file
  fi

  # Also remove N8N_SECURE_COOKIE=false if HTTPS is now active
  if $USE_HTTPS && grep -q "N8N_SECURE_COOKIE=false" "$compose_file"; then
    sed -i '/N8N_SECURE_COOKIE=false/d' "$compose_file"
    info "Removed N8N_SECURE_COOKIE=false (HTTPS is active)"
  fi
}

# =============================================================================
# FUNCTION: restart_existing_container
# =============================================================================
restart_existing_container() {
  step "Restarting existing n8n container with updated configuration"
  cd "${N8N_DIR}"

  info "Stopping container '${CONTAINER_NAME}'…"
  docker compose down --remove-orphans >> "$LOG_FILE" 2>&1
  success "Container stopped"

  info "Pulling latest n8nio/n8n image…"
  docker compose pull >> "$LOG_FILE" 2>&1
  success "Image check done"

  info "Starting container with new URL: ${FINAL_URL}…"
  docker compose up -d >> "$LOG_FILE" 2>&1
  success "Container restarted successfully"

  info "Waiting 5 s for n8n to initialise…"
  sleep 5
}

# =============================================================================
# FUNCTION: create_project_dir
# =============================================================================
create_project_dir() {
  step "Creating n8n project directory"
  mkdir -p "${N8N_DIR}/n8n_data"
  chown -R 1000:1000 "${N8N_DIR}/n8n_data" 2>/dev/null || true
  success "Project directory: ${N8N_DIR}"
  success "Persistent data:   ${N8N_DIR}/n8n_data"
}

# =============================================================================
# FUNCTION: create_compose_file
# Writes docker-compose.yml with all environment variables properly set.
# =============================================================================
create_compose_file() {
  step "Generating docker-compose.yml"

  # Determine secure cookie setting
  local secure_cookie="false"
  $USE_HTTPS && secure_cookie="true"

  # Determine protocol for N8N_PROTOCOL
  local n8n_protocol="http"
  $USE_HTTPS && n8n_protocol="https"

  cat > "${N8N_DIR}/docker-compose.yml" <<EOF
# =============================================================================
# docker-compose.yml — n8n  (generated by setup-n8n.sh v3.0)
# Generated : $(date)
# HTTPS Mode: ${HTTPS_MODE}
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
      # ── Network ──────────────────────────────────────────
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=${n8n_protocol}
      - NODE_ENV=production

      # ── Webhook URL (auto-detected) ───────────────────────
      - WEBHOOK_URL=${FINAL_URL}

      # ── Cookie security (false = allow HTTP/Safari access) ─
      - N8N_SECURE_COOKIE=${secure_cookie}

      # ── Optional: timezone ────────────────────────────────
      # - GENERIC_TIMEZONE=UTC

      # ── Optional: basic auth (uncomment to enable) ────────
      # - N8N_BASIC_AUTH_ACTIVE=true
      # - N8N_BASIC_AUTH_USER=admin
      # - N8N_BASIC_AUTH_PASSWORD=changeme

    volumes:
      # Persistent storage — survives container restarts/upgrades
      - ./n8n_data:/home/node/.n8n
EOF

  success "docker-compose.yml written to ${N8N_DIR}/docker-compose.yml"
}

# =============================================================================
# FUNCTION: start_n8n
# Fresh install: pull & start.
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

  info "Waiting 5 s for n8n to initialise…"
  sleep 5
}

# =============================================================================
# FUNCTION: install_nginx
# Installs Nginx if not already present.
# =============================================================================
install_nginx() {
  step "Installing Nginx"

  if command -v nginx &>/dev/null; then
    info "Nginx already installed: $(nginx -v 2>&1)"
    success "Skipping Nginx installation"
    return 0
  fi

  apt-get install -y nginx >> "$LOG_FILE" 2>&1
  systemctl enable nginx   >> "$LOG_FILE" 2>&1
  systemctl start  nginx   >> "$LOG_FILE" 2>&1
  success "Nginx installed and started"
}

# =============================================================================
# FUNCTION: write_nginx_config
# Writes the Nginx reverse-proxy config for a given domain.
# =============================================================================
write_nginx_config() {
  local domain="$1"
  step "Writing Nginx config for ${domain}"

  cat > "/etc/nginx/sites-available/n8n" <<NGINXEOF
# n8n reverse proxy — generated by setup-n8n.sh
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    # Security headers
    add_header X-Frame-Options    "SAMEORIGIN"  always;
    add_header X-XSS-Protection   "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;

    # Allow large file uploads for n8n nodes
    client_max_body_size 50M;

    location / {
        proxy_pass         http://127.0.0.1:${N8N_PORT};
        proxy_http_version 1.1;

        # WebSocket support — required for n8n real-time UI
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";

        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        # Long timeouts — n8n workflows can run for minutes
        proxy_read_timeout    3600;
        proxy_connect_timeout 3600;
        proxy_send_timeout    3600;
    }
}
NGINXEOF

  # Enable site, disable default
  ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  nginx -t >> "$LOG_FILE" 2>&1
  systemctl reload nginx >> "$LOG_FILE" 2>&1
  success "Nginx config active for ${domain}"
}

# =============================================================================
# FUNCTION: install_certbot
# Installs Certbot and the Nginx plugin.
# =============================================================================
install_certbot() {
  step "Installing Certbot (Let's Encrypt)"

  if command -v certbot &>/dev/null; then
    info "Certbot already installed: $(certbot --version 2>&1)"
    success "Skipping Certbot installation"
    return 0
  fi

  apt-get install -y certbot python3-certbot-nginx >> "$LOG_FILE" 2>&1
  success "Certbot installed"
}

# =============================================================================
# FUNCTION: obtain_certbot_ssl
# Runs certbot to get a Let's Encrypt certificate for the domain.
# =============================================================================
obtain_certbot_ssl() {
  local domain="$1"
  step "Obtaining Let's Encrypt SSL certificate for ${domain}"

  info "Running Certbot (non-interactive)…"
  if certbot --nginx \
       --non-interactive \
       --agree-tos \
       --register-unsafely-without-email \
       -d "${domain}" >> "$LOG_FILE" 2>&1; then
    success "SSL certificate obtained for ${domain}"

    # Set up auto-renewal cron (idempotent)
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
      (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
      success "Auto-renewal cron job added (runs daily at 03:00)"
    fi
  else
    warn "Certbot could not get a certificate automatically."
    warn "This usually means the domain DNS hasn't propagated yet."
    warn "Once DNS is ready, run manually:"
    warn "  sudo certbot --nginx -d ${domain}"
    warn "Continuing with HTTP for now — n8n is still accessible."
    USE_HTTPS=false
    FINAL_URL="http://${PUBLIC_IP}:${N8N_PORT}/"
  fi
}

# =============================================================================
# FUNCTION: setup_duckdns
# Registers the current IP with DuckDNS and sets up an auto-update cron.
# =============================================================================
setup_duckdns() {
  step "Configuring DuckDNS"

  local subdomain="$DUCKDNS_SUBDOMAIN"
  local token="$DUCKDNS_TOKEN"

  info "Updating DuckDNS IP for ${subdomain}.duckdns.org → ${PUBLIC_IP}…"

  local response
  response=$(curl -fsSL \
    "https://www.duckdns.org/update?domains=${subdomain}&token=${token}&ip=${PUBLIC_IP}" \
    2>/dev/null || true)

  if [[ "$response" == "OK" ]]; then
    success "DuckDNS updated: ${subdomain}.duckdns.org → ${PUBLIC_IP}"
  else
    warn "DuckDNS update returned: '${response}'"
    warn "Check your subdomain and token. Continuing anyway…"
  fi

  # Save DuckDNS updater script for cron
  mkdir -p /opt/duckdns
  cat > /opt/duckdns/update.sh <<DUCKEOF
#!/usr/bin/env bash
# Auto-update DuckDNS IP — runs every 5 minutes via cron
SUBDOMAIN="${subdomain}"
TOKEN="${token}"
curl -fsSL "https://www.duckdns.org/update?domains=\${SUBDOMAIN}&token=\${TOKEN}&ip=" \
  -o /tmp/duckdns.log 2>&1
DUCKEOF
  chmod +x /opt/duckdns/update.sh

  # Add cron job (idempotent)
  if ! crontab -l 2>/dev/null | grep -q "duckdns"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/duckdns/update.sh") | crontab -
    success "DuckDNS auto-update cron added (every 5 min)"
  fi

  info "Waiting 10 s for DNS to propagate…"
  sleep 10
}

# =============================================================================
# FUNCTION: install_cloudflared
# Installs the cloudflared binary (Cloudflare Tunnel client).
# =============================================================================
install_cloudflared() {
  step "Installing cloudflared (Cloudflare Tunnel)"

  if command -v cloudflared &>/dev/null; then
    info "cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
    success "Skipping cloudflared installation"
    return 0
  fi

  local arch
  arch=$(uname -m)
  local deb_url

  case "$arch" in
    x86_64)  deb_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" ;;
    aarch64) deb_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb" ;;
    *)
      error "Unsupported architecture: ${arch}"
      exit 1
      ;;
  esac

  info "Downloading cloudflared for ${arch}…"
  curl -fsSL "$deb_url" -o /tmp/cloudflared.deb >> "$LOG_FILE" 2>&1
  dpkg -i /tmp/cloudflared.deb                  >> "$LOG_FILE" 2>&1
  rm -f /tmp/cloudflared.deb

  success "cloudflared installed: $(cloudflared --version 2>&1 | head -1)"
}

# =============================================================================
# FUNCTION: start_cloudflare_tunnel
# Starts a temporary Cloudflare Tunnel and captures the .trycloudflare.com URL.
# Then installs it as a systemd service for persistence across reboots.
# =============================================================================
start_cloudflare_tunnel() {
  step "Starting Cloudflare Tunnel"

  # Stop any existing tunnel service first
  systemctl stop cloudflared-n8n 2>/dev/null || true

  info "Starting tunnel to http://localhost:${N8N_PORT}…"
  info "Waiting for Cloudflare to assign a URL (up to 30 s)…"

  # Run cloudflared in background, capture output
  cloudflared tunnel --url "http://localhost:${N8N_PORT}" \
    --no-autoupdate \
    > /tmp/cloudflared_output.log 2>&1 &

  local cf_pid=$!
  local tunnel_url=""
  local waited=0

  # Poll the output file for the tunnel URL
  while [[ -z "$tunnel_url" && $waited -lt 30 ]]; do
    sleep 2
    waited=$(( waited + 2 ))
    tunnel_url=$(grep -oP 'https://[a-z0-9\-]+\.trycloudflare\.com' \
      /tmp/cloudflared_output.log 2>/dev/null | head -1 || true)
  done

  # Kill the background cloudflared (we'll run it as a service)
  kill "$cf_pid" 2>/dev/null || true
  sleep 1

  if [[ -z "$tunnel_url" ]]; then
    warn "Could not capture Cloudflare Tunnel URL automatically."
    warn "Starting tunnel as a service — check the URL with:"
    warn "  journalctl -u cloudflared-n8n -f"
    tunnel_url="https://<check-journalctl-for-url>.trycloudflare.com"
  else
    success "Tunnel URL: ${tunnel_url}"
  fi

  TUNNEL_URL="$tunnel_url"
  FINAL_URL="${tunnel_url}/"

  # ── Install as systemd service (survives reboots) ──────────────────────────
  info "Installing cloudflared as a systemd service…"

  cat > /etc/systemd/system/cloudflared-n8n.service <<SVCEOF
[Unit]
Description=Cloudflare Tunnel for n8n
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:${N8N_PORT} --no-autoupdate
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

  # Also try the package install path
  if [[ -f /usr/bin/cloudflared ]]; then
    sed -i 's|/usr/local/bin/cloudflared|/usr/bin/cloudflared|g' \
      /etc/systemd/system/cloudflared-n8n.service
  fi

  systemctl daemon-reload                    >> "$LOG_FILE" 2>&1
  systemctl enable cloudflared-n8n           >> "$LOG_FILE" 2>&1
  systemctl start  cloudflared-n8n           >> "$LOG_FILE" 2>&1
  success "cloudflared-n8n service enabled and started"

  info "Waiting 10 s for the tunnel to stabilise…"
  sleep 10

  # Try to grab the live URL from journalctl
  local live_url
  live_url=$(journalctl -u cloudflared-n8n --no-pager -n 50 2>/dev/null \
    | grep -oP 'https://[a-z0-9\-]+\.trycloudflare\.com' | head -1 || true)

  if [[ -n "$live_url" ]]; then
    TUNNEL_URL="$live_url"
    FINAL_URL="${live_url}/"
    success "Live Tunnel URL confirmed: ${live_url}"
  fi
}

# =============================================================================
# FUNCTION: setup_https
# Master HTTPS dispatcher — calls the right sub-functions based on HTTPS_MODE.
# =============================================================================
setup_https() {
  case "$HTTPS_MODE" in

    # ── Cloudflare Tunnel ────────────────────────────────────────────────────
    cloudflare_tunnel)
      step "Setting up Cloudflare Tunnel (free HTTPS, no domain needed)"
      install_cloudflared
      # Set a temporary FINAL_URL before the tunnel starts so compose file is written
      FINAL_URL="http://${PUBLIC_IP}:${N8N_PORT}/"
      # Start/restart n8n first so the tunnel has something to proxy
      if [[ "${CONTAINER_EXISTS:-false}" == "true" ]]; then
        update_webhook_url
        restart_existing_container
      else
        create_project_dir
        create_compose_file
        start_n8n
      fi
      # Now start the tunnel — captures the real URL
      start_cloudflare_tunnel
      # Update compose file with real tunnel URL
      update_webhook_url
      # Restart n8n one more time with the correct WEBHOOK_URL
      info "Restarting n8n with final Cloudflare Tunnel URL…"
      cd "${N8N_DIR}"
      docker compose down >> "$LOG_FILE" 2>&1
      docker compose up -d >> "$LOG_FILE" 2>&1
      sleep 5
      ;;

    # ── DuckDNS + Certbot ────────────────────────────────────────────────────
    duckdns)
      step "Setting up DuckDNS + Let's Encrypt SSL"
      FINAL_URL="https://${DOMAIN_NAME}/"
      setup_duckdns
      install_nginx
      write_nginx_config "${DOMAIN_NAME}"
      install_certbot
      obtain_certbot_ssl "${DOMAIN_NAME}"
      ;;

    # ── Own Domain + Certbot ─────────────────────────────────────────────────
    own_domain)
      step "Setting up Nginx + Let's Encrypt SSL for ${DOMAIN_NAME}"
      FINAL_URL="https://${DOMAIN_NAME}/"
      install_nginx
      write_nginx_config "${DOMAIN_NAME}"
      install_certbot
      obtain_certbot_ssl "${DOMAIN_NAME}"
      ;;

    # ── No HTTPS ─────────────────────────────────────────────────────────────
    none|*)
      FINAL_URL="http://${PUBLIC_IP}:${N8N_PORT}/"
      info "HTTPS not configured — using plain HTTP."
      ;;
  esac
}

# =============================================================================
# FUNCTION: verify_installation
# =============================================================================
verify_installation() {
  step "Verifying installation"

  if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" \
       --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    success "Container '${CONTAINER_NAME}' is running"
  else
    error "Container '${CONTAINER_NAME}' does NOT appear to be running."
    error "Check logs with: docker compose -f ${N8N_DIR}/docker-compose.yml logs"
    exit 1
  fi

  # Health check against localhost
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
  warn "Health check did not respond — n8n may still be starting."
  warn "Try: curl -I http://127.0.0.1:${N8N_PORT}/"
}

# =============================================================================
# FUNCTION: print_summary
# =============================================================================
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}"
  if [[ "${CONTAINER_EXISTS:-false}" == "true" ]]; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          🔄  n8n Container Restarted with New Config!        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
  else
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║               🎉  n8n Installation Complete!                 ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
  fi
  echo -e "${RESET}"

  # ── Access URL ──────────────────────────────────────────────────────────────
  echo -e "${BOLD}  🌐 Access n8n at:${RESET}"
  echo -e "    ${CYAN}${BOLD}${FINAL_URL}${RESET}"
  echo ""

  # ── HTTPS Mode info ─────────────────────────────────────────────────────────
  case "$HTTPS_MODE" in
    cloudflare_tunnel)
      echo -e "${BOLD}  🔒 HTTPS Mode:${RESET}  Cloudflare Tunnel"
      echo -e "  ${YELLOW}Note:${RESET} The tunnel URL may change if the service restarts."
      echo -e "  Check the current live URL with:"
      echo    "    journalctl -u cloudflared-n8n -n 20 | grep trycloudflare"
      echo -e "  Tunnel service status:"
      echo    "    systemctl status cloudflared-n8n"
      ;;
    duckdns)
      echo -e "${BOLD}  🔒 HTTPS Mode:${RESET}  DuckDNS + Let's Encrypt"
      echo -e "  ${GREEN}SSL auto-renews every 90 days via cron.${RESET}"
      echo -e "  DuckDNS IP auto-updates every 5 minutes via cron."
      ;;
    own_domain)
      echo -e "${BOLD}  🔒 HTTPS Mode:${RESET}  Own Domain (${DOMAIN_NAME}) + Let's Encrypt"
      echo -e "  ${GREEN}SSL auto-renews every 90 days via cron.${RESET}"
      ;;
    none|*)
      echo -e "${BOLD}  ⚠️  HTTPS Mode:${RESET}  None (plain HTTP)"
      echo -e "  ${YELLOW}Tip for Safari:${RESET} If you get a secure cookie error, run:"
      echo    "    sed -i 's|- NODE_ENV=production|- NODE_ENV=production\\n      - N8N_SECURE_COOKIE=false|' ${N8N_DIR}/docker-compose.yml"
      echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml up -d"
      ;;
  esac
  echo ""

  # ── Paths ───────────────────────────────────────────────────────────────────
  echo -e "${BOLD}  📁 Project directory:${RESET}  ${N8N_DIR}"
  echo -e "${BOLD}  💾 Persistent data:${RESET}    ${N8N_DIR}/n8n_data   ${RED}← BACK THIS UP!${RESET}"
  echo -e "${BOLD}  📋 Install log:${RESET}        ${LOG_FILE}"
  echo ""

  # ── Container status ─────────────────────────────────────────────────────────
  echo -e "${BOLD}  🐳 Container status:${RESET}"
  docker ps --filter "name=${CONTAINER_NAME}" \
    --format "    {{.Names}}\t{{.Status}}\t{{.Ports}}"
  echo ""

  # ── Useful commands ──────────────────────────────────────────────────────────
  echo -e "${BOLD}  🛠️  Useful Docker commands:${RESET}"
  echo -e "    ${YELLOW}# View live logs${RESET}"
  echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml logs -f"
  echo ""
  echo -e "    ${YELLOW}# Stop n8n${RESET}"
  echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml down"
  echo ""
  echo -e "    ${YELLOW}# Restart n8n${RESET}"
  echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml restart"
  echo ""
  echo -e "    ${YELLOW}# Update to latest n8n${RESET}"
  echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml pull"
  echo    "    docker compose -f ${N8N_DIR}/docker-compose.yml up -d"
  echo ""
  echo -e "    ${YELLOW}# Enter container shell${RESET}"
  echo    "    docker exec -it ${CONTAINER_NAME} sh"
  echo ""

  # ── Backup ───────────────────────────────────────────────────────────────────
  echo -e "${BOLD}  💾 Backup command:${RESET}"
  echo    "    tar czf n8n-backup-\$(date +%Y%m%d).tar.gz ${N8N_DIR}/n8n_data"
  echo ""

  # ── Nginx commands (if applicable) ───────────────────────────────────────────
  if [[ "$HTTPS_MODE" == "duckdns" || "$HTTPS_MODE" == "own_domain" ]]; then
    echo -e "${BOLD}  🌍 Nginx commands:${RESET}"
    echo    "    sudo systemctl status nginx"
    echo    "    sudo nginx -t && sudo systemctl reload nginx"
    echo    "    sudo certbot renew --dry-run"
    echo ""
  fi

  # ── AWS reminder ─────────────────────────────────────────────────────────────
  echo -e "${BOLD}  ☁️  AWS Security Group reminder:${RESET}"
  echo -e "    Ensure these ports are open (inbound TCP) in your EC2 Security Group:"
  echo -e "    Port ${N8N_PORT} (n8n direct access)"
  if [[ "$HTTPS_MODE" == "duckdns" || "$HTTPS_MODE" == "own_domain" ]]; then
    echo    "    Port 80  (HTTP / Certbot ACME challenge)"
    echo    "    Port 443 (HTTPS)"
  fi
  echo ""
  echo -e "${GREEN}${BOLD}  Happy automating! 🚀${RESET}"
  echo ""
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================
main() {
  banner

  {
    echo "=================================================="
    echo " setup-n8n.sh v3.0 — started at $(date)"
    echo "=================================================="
  } > "$LOG_FILE"

  # ── Always run ────────────────────────────────────────────────────────────
  check_root
  check_internet
  detect_os
  detect_public_ip
  optional_prompts       # sets HTTPS_MODE, DOMAIN_NAME, etc.
  system_update
  install_docker
  install_compose
  configure_docker_service
  configure_firewall

  # ── Container check ───────────────────────────────────────────────────────
  check_container_exists

  # ── HTTPS setup (Cloudflare Tunnel handles its own n8n lifecycle) ─────────
  if [[ "$HTTPS_MODE" == "cloudflare_tunnel" ]]; then
    # cloudflare_tunnel branch manages container start internally
    setup_https

  elif [[ "$CONTAINER_EXISTS" == "true" ]]; then
    # ── PATH A: existing container → update config & restart ─────────────
    step "Existing container detected — updating configuration and restarting"

    # Set FINAL_URL before updating compose file
    if $USE_HTTPS && [[ -n "$DOMAIN_NAME" ]]; then
      FINAL_URL="https://${DOMAIN_NAME}/"
    else
      FINAL_URL="http://${PUBLIC_IP}:${N8N_PORT}/"
    fi

    create_project_dir
    update_webhook_url
    restart_existing_container

    # Run HTTPS setup after container is up (for duckdns / own_domain)
    if [[ "$HTTPS_MODE" != "none" ]]; then
      setup_https
    fi

  else
    # ── PATH B: fresh install ────────────────────────────────────────────
    step "No existing container — performing fresh installation"

    # Set FINAL_URL before writing compose file
    if $USE_HTTPS && [[ -n "$DOMAIN_NAME" ]]; then
      FINAL_URL="https://${DOMAIN_NAME}/"
    else
      FINAL_URL="http://${PUBLIC_IP}:${N8N_PORT}/"
    fi

    create_project_dir
    create_compose_file
    start_n8n

    # Run HTTPS setup after container is up (for duckdns / own_domain)
    if [[ "$HTTPS_MODE" != "none" ]]; then
      setup_https
    fi
  fi

  # ── Always verify & summarise ─────────────────────────────────────────────
  verify_installation
  print_summary
}

main "$@"