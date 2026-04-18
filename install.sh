#!/usr/bin/env bash
set -euo pipefail

# ─── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${CYAN}→${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# ─── USAGE ────────────────────────────────────────────────────────────────────
DOMAIN="${1:-}"
[[ -z "$DOMAIN" ]] && die "Usage: curl -fsSL https://raw.githubusercontent.com/meissaniang/coolify_ubuntu/main/install.sh | bash -s -- yourdomain.com"

# Strip protocol if accidentally passed (http://domain.com → domain.com)
DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%/}"

# Basic domain format check (contains a dot, no spaces, no protocol)
[[ "$DOMAIN" == *"."* && "$DOMAIN" != *" "* && "$DOMAIN" != *"/"* ]] \
  || die "Invalid domain: '$DOMAIN'. Example: coolify.example.com"

# ─── ROOT CHECK ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root: sudo bash install.sh $DOMAIN"

# ─── OS CHECK ─────────────────────────────────────────────────────────────────
grep -qi ubuntu /etc/os-release 2>/dev/null || die "Ubuntu is required"

UBUNTU_VERSION=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
[[ "$UBUNTU_VERSION" -ge 22 ]] || warn "Ubuntu 22+ recommended (detected $UBUNTU_VERSION)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Coolify Installer — domain: ${DOMAIN}"
echo "  Mode: HTTP port 80 (SSL géré par Cloudflare)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── SYSTEM PACKAGES ──────────────────────────────────────────────────────────
info "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git ufw
ok "System updated"

# ─── FIREWALL ─────────────────────────────────────────────────────────────────
info "Configuring firewall (ufw)..."
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp  comment 'SSH'  >/dev/null
ufw allow 80/tcp  comment 'HTTP' >/dev/null
# Port 443 not needed — Cloudflare Flexible mode connects on port 80 only
ufw --force enable >/dev/null
ok "Firewall configured (22, 80 open)"

# ─── DOCKER ───────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable docker >/dev/null 2>&1
  systemctl start docker
  ok "Docker installed"
else
  ok "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
fi

# ─── COOLIFY INSTALL ──────────────────────────────────────────────────────────
info "Installing Coolify..."
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
ok "Coolify installation script completed"

# ─── WAIT FOR ENV FILE ────────────────────────────────────────────────────────
COOLIFY_ENV="/data/coolify/source/.env"
COOLIFY_DIR="/data/coolify/source"

info "Waiting for Coolify env file..."
TIMEOUT=60
ELAPSED=0
until [[ -f "$COOLIFY_ENV" ]] || [[ $ELAPSED -ge $TIMEOUT ]]; do
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done

[[ -f "$COOLIFY_ENV" ]] || die "Coolify env file not found at $COOLIFY_ENV after ${TIMEOUT}s. Check: docker ps"

# ─── CONFIGURE DOMAIN (HTTP only — Cloudflare Flexible SSL) ───────────────────
info "Configuring domain: http://${DOMAIN} (port 80, no SSL on server)..."

cd "$COOLIFY_DIR"
docker compose stop >/dev/null 2>&1 || true

# APP_FQDN with http:// prefix → Caddy does NOT attempt Let's Encrypt
# and does NOT redirect HTTP→HTTPS — Cloudflare handles SSL for end users
if grep -q "^APP_FQDN=" "$COOLIFY_ENV"; then
  sed -i "s|^APP_FQDN=.*|APP_FQDN=http://${DOMAIN}|" "$COOLIFY_ENV"
else
  echo "APP_FQDN=http://${DOMAIN}" >> "$COOLIFY_ENV"
fi

if grep -q "^APP_URL=" "$COOLIFY_ENV"; then
  sed -i "s|^APP_URL=.*|APP_URL=http://${DOMAIN}|" "$COOLIFY_ENV"
else
  echo "APP_URL=http://${DOMAIN}" >> "$COOLIFY_ENV"
fi

ok "Domain configured in $COOLIFY_ENV"

# ─── RESTART COOLIFY ──────────────────────────────────────────────────────────
info "Starting Coolify services..."
docker compose pull -q 2>/dev/null || true
docker compose up -d --force-recreate --remove-orphans >/dev/null 2>&1
ok "Coolify services started"

# ─── HEALTH CHECK ─────────────────────────────────────────────────────────────
info "Waiting for Coolify to be healthy..."
TIMEOUT=120
ELAPSED=0
until curl -sf "http://localhost:8000/api/v1/health" >/dev/null 2>&1 || [[ $ELAPSED -ge $TIMEOUT ]]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  echo -n "."
done
echo ""

if curl -sf "http://localhost:8000/api/v1/health" >/dev/null 2>&1; then
  ok "Coolify API is healthy"
else
  warn "Coolify API not yet responding — it may still be initializing (give it 2-3 minutes)"
fi

# ─── SERVER IP ────────────────────────────────────────────────────────────────
SERVER_IP=$(curl -sf https://api.ipify.org 2>/dev/null || curl -sf https://ifconfig.me 2>/dev/null || echo "<your-server-ip>")

# ─── DONE ─────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}Installation complete!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "  ${CYAN}Coolify URL:${NC}  https://${DOMAIN}  (via Cloudflare)"
echo -e "  ${CYAN}Server IP:${NC}   ${SERVER_IP}"
echo ""
echo "  Cloudflare checklist:"
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │ DNS → A  ${DOMAIN}"
echo "  │          → ${SERVER_IP}  (proxy ☁ activé)          │"
echo "  │                                                     │"
echo "  │ SSL/TLS → Mode: Flexible                            │"
echo "  │   Cloudflare ──HTTPS──► vous                       │"
echo "  │   Cloudflare ──HTTP──►  serveur port 80            │"
echo "  │                                                     │"
echo "  │ Apps déployées: même config — A record + Flexible   │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
echo "  First visit → https://${DOMAIN} → create your admin account"
echo ""
