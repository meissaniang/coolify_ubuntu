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
# Traefik v3 exige Docker API >= 1.40 (Docker Engine >= 19.03).
# On vérifie la version et on upgrade si nécessaire (get.docker.com est idempotent).
DOCKER_API_CURRENT=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo "0.0")
DOCKER_API_OK=$(awk -v cur="$DOCKER_API_CURRENT" -v req="1.40" \
  'BEGIN{split(cur,a,"."); split(req,b,"."); print (a[1]>b[1] || (a[1]==b[1] && a[2]>=b[2])) ? "yes" : "no"}')

if ! command -v docker &>/dev/null || [[ "$DOCKER_API_OK" == "no" ]]; then
  info "Installation/mise à jour de Docker (API actuelle: ${DOCKER_API_CURRENT}, requise: >=1.40)..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable docker --now >/dev/null 2>&1
  ok "Docker installé/mis à jour ($(docker --version | awk '{print $3}' | tr -d ','))"
else
  ok "Docker OK — API ${DOCKER_API_CURRENT} ($(docker --version | awk '{print $3}' | tr -d ','))"
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
step "5/7 — Génération des fichiers de configuration"
# ─────────────────────────────────────────────────────────────────────────────
# Traefik utilise le file provider (pas de Docker socket) → zéro problème
# de version d'API Docker. La route Coolify est dans un fichier YAML statique.

mkdir -p "${DATA_DIR}/traefik/dynamic"

# Config dynamique Traefik : route HTTPS vers Coolify (http://coolify:8080)
cat > "${DATA_DIR}/traefik/dynamic/coolify.yml" <<EOF
http:
  routers:
    coolify:
      rule: "Host(\`${DOMAIN}\`)"
      entrypoints:
        - websecure
      tls:
        certResolver: letsencrypt
      service: coolify-svc

  services:
    coolify-svc:
      loadBalancer:
        servers:
          - url: "http://coolify:8080"
EOF

ok "Config Traefik écrite dans ${DATA_DIR}/traefik/dynamic/coolify.yml"

cat > "$COMPOSE_FILE" <<EOF
networks:
  coolify-net:
    driver: bridge
    name: coolify-net

volumes:
  postgres-data:
  redis-data:

services:

  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    command:
      - "--log.level=WARN"
      - "--api.dashboard=false"
      # File provider — pas de Docker socket, pas de problème d'API version
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.web.http.redirections.entrypoint.permanent=true"
      - "--certificatesresolvers.letsencrypt.acme.email=admin@${DOMAIN}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/certs/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/coolify/data/traefik/acme.json:/certs/acme.json
      - /opt/coolify/data/traefik/dynamic:/etc/traefik/dynamic:ro
    networks:
      - coolify-net

  coolify-db:
    image: postgres:16-alpine
    container_name: coolify-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: coolify
      POSTGRES_USER: coolify
      POSTGRES_PASSWORD: "${DB_PASSWORD}"
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

  coolify:
    image: ghcr.io/coollabsio/coolify:latest
    container_name: coolify
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      APP_ENV: production
      APP_DEBUG: "false"
      APP_KEY: "${APP_KEY}"
      APP_URL: "https://${DOMAIN}"
      DB_CONNECTION: pgsql
      DB_HOST: coolify-db
      DB_PORT: 5432
      DB_DATABASE: coolify
      DB_USERNAME: coolify
      DB_PASSWORD: "${DB_PASSWORD}"
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
EOF

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

# ── Clé SSH pour le serveur local ────────────────────────────────────────────
# Coolify SSH dans l'hôte via host.docker.internal pour gérer "Local server".
# La clé doit exister sur le disque ET être dans authorized_keys du root.
SSH_KEY_DIR="${DATA_DIR}/coolify/ssh/keys"
SSH_KEY="${SSH_KEY_DIR}/id.root@host.docker.internal"
mkdir -p "$SSH_KEY_DIR"
chmod 700 "$SSH_KEY_DIR"

if [[ ! -f "$SSH_KEY" ]]; then
  info "Génération de la clé SSH Coolify..."
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "coolify@local" -q
  chmod 600 "$SSH_KEY"
  ok "Clé SSH générée : ${SSH_KEY}"
else
  ok "Clé SSH existante conservée"
fi

# Ajouter la clé publique dans authorized_keys du root (idempotent)
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
PUBKEY=$(cat "${SSH_KEY}.pub")
if ! grep -qF "$PUBKEY" /root/.ssh/authorized_keys; then
  echo "$PUBKEY" >> /root/.ssh/authorized_keys
  ok "Clé publique ajoutée dans /root/.ssh/authorized_keys"
fi

# S'assurer que SSH tourne sur l'hôte
if ! systemctl is-active --quiet ssh 2>/dev/null && ! systemctl is-active --quiet sshd 2>/dev/null; then
  apt-get install -y -qq openssh-server >/dev/null 2>&1
  systemctl enable --now ssh >/dev/null 2>&1
fi

# Attendre que Coolify soit prêt puis lancer le seeder (crée la PrivateKey en DB)
info "Attente que Coolify initialise la base de données..."
TIMEOUT=120; ELAPSED=0
until docker exec coolify php artisan --version &>/dev/null; do
  sleep 5; ELAPSED=$((ELAPSED+5))
  [[ $ELAPSED -ge $TIMEOUT ]] && break
  echo -n "."
done
echo ""

docker exec coolify php artisan migrate --force >/dev/null 2>&1 \
  && ok "Migrations OK" || warn "Migrations: vérifier les logs"

docker exec coolify php artisan db:seed --force >/dev/null 2>&1 \
  && ok "Seeding OK (clé SSH instance créée en DB)" \
  || warn "Seeding: vérifier les logs (peut-être déjà fait)"

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
