#!/usr/bin/env bash
set -euo pipefail

# ─── COULEURS ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
die()  { echo -e "\n${RED}✗ ERREUR:${NC} $*\n" >&2; exit 1; }
step() { echo -e "\n${BOLD}[${1}]${NC}"; }

# ─── DOMAINE ──────────────────────────────────────────────────────────────────
DOMAIN="${1:-}"
[[ -z "$DOMAIN" ]] && die "Domaine manquant.\nUsage: curl -fsSL https://raw.githubusercontent.com/meissaniang/coolify_ubuntu/main/install.sh | bash -s -- coolify.mondomaine.com"

DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%/}"
[[ "$DOMAIN" == *"."* && "$DOMAIN" != *" "* && "$DOMAIN" != *"/"* ]] \
  || die "Domaine invalide: '$DOMAIN'. Exemple: coolify.mondomaine.com"

# ─── PRÉREQUIS ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]                                && die "Exécuter en tant que root"
grep -qi ubuntu /etc/os-release 2>/dev/null      || die "Ubuntu requis"

UBUNTU_VERSION=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release 2>/dev/null || echo "0")
[[ "$UBUNTU_VERSION" -ge 22 ]] || warn "Ubuntu 22+ recommandé (détecté: $UBUNTU_VERSION)"

# ─── CONSTANTES ───────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/coolify"
DATA_DIR="$INSTALL_DIR/data"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
LETSENCRYPT_EMAIL="admin@${DOMAIN}"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Coolify Installer — Traefik + Let's Encrypt${NC}"
echo -e "${BOLD}  Domaine : ${CYAN}${DOMAIN}${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ─────────────────────────────────────────────────────────────────────────────
step "1/7 — Paquets système"
# ─────────────────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget git ufw ca-certificates gnupg lsb-release
ok "curl, wget, git, ufw installés"

# ─────────────────────────────────────────────────────────────────────────────
step "2/7 — Firewall (ufw)"
# ─────────────────────────────────────────────────────────────────────────────
ufw --force reset   >/dev/null 2>&1
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp  comment 'SSH'   >/dev/null
ufw allow 80/tcp  comment 'HTTP'  >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw --force enable >/dev/null
ok "Règles : 22 (SSH), 80 (HTTP), 443 (HTTPS) — reste bloqué"

# ─────────────────────────────────────────────────────────────────────────────
step "3/7 — Docker"
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  info "Installation de Docker..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable docker --now >/dev/null 2>&1
  ok "Docker installé ($(docker --version | awk '{print $3}' | tr -d ','))"
else
  ok "Docker présent ($(docker --version | awk '{print $3}' | tr -d ','))"
fi

docker compose version &>/dev/null || die "Docker Compose v2 introuvable"
ok "Docker Compose v2 disponible"

# ─────────────────────────────────────────────────────────────────────────────
step "4/7 — Répertoires & secrets"
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${DATA_DIR}/traefik" "${DATA_DIR}/coolify"

# acme.json : doit exister avec chmod 600 avant le démarrage de Traefik
touch "${DATA_DIR}/traefik/acme.json"
chmod 600 "${DATA_DIR}/traefik/acme.json"

# Génère les secrets une seule fois (idempotent)
if [[ ! -f "$ENV_FILE" ]]; then
  APP_KEY="base64:$(openssl rand -base64 32)"
  DB_PASSWORD="$(openssl rand -hex 24)"
  cat > "$ENV_FILE" <<EOF
APP_KEY=${APP_KEY}
DB_PASSWORD=${DB_PASSWORD}
DOMAIN=${DOMAIN}
EOF
  chmod 600 "$ENV_FILE"
  ok "Secrets générés et stockés dans ${ENV_FILE}"
else
  # Met à jour le domaine si relancé avec un nouveau domaine
  sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" "$ENV_FILE"
  ok "Secrets existants conservés"
fi

# Charge les variables depuis .env
set -a; source "$ENV_FILE"; set +a

# ─────────────────────────────────────────────────────────────────────────────
step "5/7 — Génération docker-compose.yml"
# ─────────────────────────────────────────────────────────────────────────────
# Note: <<'EOF' = pas de substitution bash → ${VAR} sera résolu par docker compose
# via le fichier .env situé dans le même répertoire (chargement automatique).
cat > "$COMPOSE_FILE" <<'COMPOSE'
networks:
  coolify-net:
    driver: bridge
    name: coolify-net

volumes:
  postgres-data:
  redis-data:

services:

  # ── Traefik ── reverse proxy, TLS, Let's Encrypt ───────────────────────────
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    command:
      - "--log.level=WARN"
      - "--api.dashboard=false"
      # Docker provider
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=coolify-net"
      # Entrypoints
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      # Redirection globale HTTP → HTTPS
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.web.http.redirections.entrypoint.permanent=true"
      # Let's Encrypt via HTTP-01 (compatible Cloudflare proxy)
      - "--certificatesresolvers.letsencrypt.acme.email=admin@${DOMAIN}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/certs/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/coolify/data/traefik/acme.json:/certs/acme.json
    networks:
      - coolify-net

  # ── PostgreSQL ─────────────────────────────────────────────────────────────
  coolify-db:
    image: postgres:16-alpine
    container_name: coolify-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: coolify
      POSTGRES_USER: coolify
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - coolify-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coolify -d coolify"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  # ── Redis ──────────────────────────────────────────────────────────────────
  coolify-redis:
    image: redis:7-alpine
    container_name: coolify-redis
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - redis-data:/data
    networks:
      - coolify-net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 5s

  # ── Coolify ────────────────────────────────────────────────────────────────
  # Port 8080 interne uniquement — aucun port exposé sur l'hôte
  # Tout le trafic passe par Traefik
  coolify:
    image: ghcr.io/coollabsio/coolify:latest
    container_name: coolify
    restart: unless-stopped
    environment:
      APP_ENV: production
      APP_DEBUG: "false"
      APP_KEY: ${APP_KEY}
      APP_URL: https://${DOMAIN}
      DB_CONNECTION: pgsql
      DB_HOST: coolify-db
      DB_PORT: 5432
      DB_DATABASE: coolify
      DB_USERNAME: coolify
      DB_PASSWORD: ${DB_PASSWORD}
      REDIS_HOST: coolify-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ""
      QUEUE_CONNECTION: redis
      SESSION_DRIVER: redis
      CACHE_DRIVER: redis
      FILESYSTEM_DISK: local
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/coolify/data/coolify:/data/coolify
    depends_on:
      coolify-db:
        condition: service_healthy
      coolify-redis:
        condition: service_healthy
    networks:
      - coolify-net
    labels:
      - "traefik.enable=true"
      # Routeur HTTPS
      - "traefik.http.routers.coolify.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.coolify.entrypoints=websecure"
      - "traefik.http.routers.coolify.tls=true"
      - "traefik.http.routers.coolify.tls.certresolver=letsencrypt"
      # Service → port interne 8080
      - "traefik.http.services.coolify.loadbalancer.server.port=8080"
COMPOSE

ok "docker-compose.yml généré dans ${INSTALL_DIR}/"

# ─────────────────────────────────────────────────────────────────────────────
step "6/7 — Démarrage des services"
# ─────────────────────────────────────────────────────────────────────────────
cd "$INSTALL_DIR"

info "Pull des images (peut prendre quelques minutes)..."
docker compose pull -q 2>/dev/null

info "Démarrage de Traefik..."
docker compose up -d traefik
ok "Traefik démarré"

info "Démarrage de PostgreSQL et Redis..."
docker compose up -d coolify-db coolify-redis

info "Attente de la santé des bases de données..."
TIMEOUT=90; ELAPSED=0
until docker inspect --format='{{.State.Health.Status}}' coolify-db  2>/dev/null | grep -q "healthy" \
   && docker inspect --format='{{.State.Health.Status}}' coolify-redis 2>/dev/null | grep -q "healthy"; do
  sleep 4; ELAPSED=$((ELAPSED + 4))
  [[ $ELAPSED -ge $TIMEOUT ]] && die "Timeout: bases de données non prêtes après ${TIMEOUT}s\nVérifier: docker compose -f ${COMPOSE_FILE} logs coolify-db coolify-redis"
  echo -n "."
done
echo ""
ok "PostgreSQL ✓ Redis ✓"

info "Démarrage de Coolify..."
docker compose up -d coolify
ok "Coolify démarré"

# ─────────────────────────────────────────────────────────────────────────────
step "7/7 — Vérifications"
# ─────────────────────────────────────────────────────────────────────────────
info "Vérification des conteneurs..."
FAILURES=()
for SVC in traefik coolify-db coolify-redis coolify; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$SVC" 2>/dev/null || echo "missing")
  if [[ "$STATUS" == "running" ]]; then
    ok "$SVC → running"
  else
    FAILURES+=("$SVC ($STATUS)")
    warn "$SVC → $STATUS"
  fi
done

[[ ${#FAILURES[@]} -eq 0 ]] \
  || die "Services en échec : ${FAILURES[*]}\nLogs: docker compose -f ${COMPOSE_FILE} logs"

# Let's Encrypt a besoin que Traefik soit accessible sur le port 80
# Le certificat est émis lors du premier hit HTTPS — on attend quelques secondes
info "Attente de l'émission du certificat Let's Encrypt..."
sleep 20

HTTPS_CODE=$(curl -o /dev/null -sf -w "%{http_code}" \
  --max-time 15 --connect-timeout 10 \
  "https://${DOMAIN}" 2>/dev/null || echo "000")

if [[ "$HTTPS_CODE" =~ ^(200|302|301|307|308)$ ]]; then
  ok "HTTPS actif (HTTP ${HTTPS_CODE})"
else
  warn "HTTPS pas encore prêt (code: ${HTTPS_CODE}) — le certificat peut prendre 1-2 minutes"
  info "Vérifier dans quelques instants: curl -I https://${DOMAIN}"
fi

SERVER_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
  || curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
  || echo "<ip-serveur>")

# ─── SUCCÈS ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}${BOLD}Installation terminée avec succès !${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}URL Coolify :${NC}   https://${DOMAIN}"
echo -e "  ${CYAN}IP serveur :${NC}    ${SERVER_IP}"
echo -e "  ${CYAN}Fichiers :${NC}      ${INSTALL_DIR}/"
echo -e "  ${CYAN}Certificats :${NC}   ${DATA_DIR}/traefik/acme.json"
echo ""
echo -e "  ${YELLOW}Cloudflare :${NC} SSL/TLS → mode ${BOLD}Full${NC} ou ${BOLD}Full (strict)${NC}"
echo ""
echo -e "  ${GREEN}${BOLD}Coolify est disponible sur https://${DOMAIN}${NC}"
echo ""
echo "  Commandes utiles :"
echo "    docker compose -f ${COMPOSE_FILE} ps"
echo "    docker compose -f ${COMPOSE_FILE} logs -f coolify"
echo "    docker compose -f ${COMPOSE_FILE} restart"
echo ""
