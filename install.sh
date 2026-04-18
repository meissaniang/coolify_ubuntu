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
[[ $EUID -ne 0 ]]                           && die "Exécuter en tant que root"
grep -qi ubuntu /etc/os-release 2>/dev/null || die "Ubuntu requis"

UBUNTU_VERSION=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release 2>/dev/null || echo "0")
[[ "$UBUNTU_VERSION" -ge 22 ]] || warn "Ubuntu 22+ recommandé (détecté: $UBUNTU_VERSION)"

# ─── CONSTANTES ───────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/coolify"
DATA_DIR="$INSTALL_DIR/data"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
COOLIFY_VERSION="4.0.0-beta.473"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Coolify Installer — Traefik + Let's Encrypt${NC}"
echo -e "${BOLD}  Domaine  : ${CYAN}${DOMAIN}${NC}"
echo -e "${BOLD}  Version  : ${CYAN}${COOLIFY_VERSION}${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ─────────────────────────────────────────────────────────────────────────────
step "1/7 — Paquets système"
# ─────────────────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget git ufw ca-certificates gnupg lsb-release openssh-server
ok "Paquets système installés"

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
DOCKER_API_CURRENT=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo "0.0")
DOCKER_API_OK=$(awk -v cur="$DOCKER_API_CURRENT" -v req="1.40" \
  'BEGIN{split(cur,a,"."); split(req,b,"."); print (a[1]>b[1] || (a[1]==b[1] && a[2]>=b[2])) ? "yes" : "no"}')

if ! command -v docker &>/dev/null || [[ "$DOCKER_API_OK" == "no" ]]; then
  info "Installation/mise à jour de Docker..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable docker --now >/dev/null 2>&1
  ok "Docker installé ($(docker --version | awk '{print $3}' | tr -d ','))"
else
  ok "Docker OK — API ${DOCKER_API_CURRENT} ($(docker --version | awk '{print $3}' | tr -d ','))"
fi

docker compose version &>/dev/null || die "Docker Compose v2 introuvable"
ok "Docker Compose v2 disponible"

# ─────────────────────────────────────────────────────────────────────────────
step "4/7 — Répertoires & secrets"
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${DATA_DIR}/traefik/dynamic" "${DATA_DIR}/coolify/ssh/keys"

touch "${DATA_DIR}/traefik/acme.json"
chmod 600 "${DATA_DIR}/traefik/acme.json"

if [[ ! -f "$ENV_FILE" ]]; then
  FRESH_INSTALL=true
  APP_KEY="base64:$(openssl rand -base64 32)"
  DB_PASSWORD="$(openssl rand -hex 24)"
  cat > "$ENV_FILE" <<EOF
APP_KEY=${APP_KEY}
DB_PASSWORD=${DB_PASSWORD}
DOMAIN=${DOMAIN}
EOF
  chmod 600 "$ENV_FILE"
  ok "Secrets générés → ${ENV_FILE}"
else
  FRESH_INSTALL=false
  sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" "$ENV_FILE"
  ok "Secrets existants conservés"
fi

set -a; source "$ENV_FILE"; set +a

# ─────────────────────────────────────────────────────────────────────────────
step "5/7 — Génération des fichiers de configuration"
# ─────────────────────────────────────────────────────────────────────────────

# Traefik : file provider uniquement.
# Le Docker provider de Traefik v3 négocie en API 1.24 → rejeté par Docker 29+
# (minimum 1.40). Le file provider évite totalement cette dépendance.
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

ok "Config Traefik → ${DATA_DIR}/traefik/dynamic/coolify.yml"

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
    image: ghcr.io/coollabsio/coolify:${COOLIFY_VERSION}
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

ok "docker-compose.yml → ${COMPOSE_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
step "6/7 — Démarrage des services"
# ─────────────────────────────────────────────────────────────────────────────
cd "$INSTALL_DIR"

if [[ "$FRESH_INSTALL" == "true" ]]; then
  info "Fresh install — suppression des volumes existants..."
  docker compose down -v --remove-orphans 2>/dev/null || true
else
  info "Re-run — arrêt des containers (volumes préservés)..."
  docker compose down --remove-orphans 2>/dev/null || true
fi

info "Pull des images..."
docker compose pull || die "Échec pull images — vérifier l'accès à ghcr.io et docker.io"

# Réseau requis par Coolify pour déployer les applications
docker network create --driver bridge coolify 2>/dev/null || true
ok "Réseau Docker 'coolify' disponible"

info "Démarrage de Traefik..."
docker compose up -d traefik
ok "Traefik démarré (file provider)"

info "Démarrage de PostgreSQL et Redis..."
docker compose up -d coolify-db coolify-redis

info "Attente santé des bases de données..."
TIMEOUT=90; ELAPSED=0
until docker inspect --format='{{.State.Health.Status}}' coolify-db  2>/dev/null | grep -q "healthy" \
   && docker inspect --format='{{.State.Health.Status}}' coolify-redis 2>/dev/null | grep -q "healthy"; do
  sleep 4; ELAPSED=$((ELAPSED + 4))
  [[ $ELAPSED -ge $TIMEOUT ]] && die "Timeout DB/Redis après ${TIMEOUT}s"
  echo -n "."
done
echo ""
ok "PostgreSQL ✓  Redis ✓"

info "Démarrage de Coolify (migrations + seeding gérés par l'entrypoint)..."
docker compose up -d coolify
ok "Coolify démarré"

# ── Clé SSH pour le serveur local ─────────────────────────────────────────────
SSH_KEY="${DATA_DIR}/coolify/ssh/keys/id.root@host.docker.internal"
mkdir -p "${DATA_DIR}/coolify/ssh/keys"
chmod 755 "${DATA_DIR}/coolify/ssh/keys"

if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "coolify@local" -q
  ok "Clé SSH Coolify générée"
else
  ok "Clé SSH existante conservée"
fi
chmod 644 "$SSH_KEY" "${SSH_KEY}.pub"

mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
PUBKEY=$(cat "${SSH_KEY}.pub")
grep -qF "$PUBKEY" /root/.ssh/authorized_keys \
  || { echo "$PUBKEY" >> /root/.ssh/authorized_keys; ok "Clé publique → authorized_keys"; }

systemctl is-active --quiet ssh 2>/dev/null \
  || systemctl is-active --quiet sshd 2>/dev/null \
  || systemctl enable --now ssh >/dev/null 2>&1

# ── Attente Coolify health ─────────────────────────────────────────────────────
info "Attente que Coolify soit opérationnel..."
TIMEOUT=180; ELAPSED=0
until docker exec coolify curl -sf http://localhost:8080/api/v1/health >/dev/null 2>&1; do
  sleep 5; ELAPSED=$((ELAPSED + 5))
  [[ $ELAPSED -ge $TIMEOUT ]] && { warn "Coolify pas encore prêt après ${TIMEOUT}s — continuer manuellement"; break; }
  echo -n "."
done
echo ""

if docker exec coolify curl -sf http://localhost:8080/api/v1/health >/dev/null 2>&1; then
  ok "Coolify API opérationnelle"
fi

# ── Correction clé SSH serveur local ──────────────────────────────────────────
# Coolify seeder crée private_key id=1 avec une clé de test, mais
# servers.private_key_id=0 (id inexistant) → 500 "getPublicKey() on null".
# On attend le seeder, puis on remplace la clé par la nôtre via docker cp
# (évite les problèmes de permissions sur le volume) et on corrige la FK.
info "Configuration de la clé SSH pour le serveur local..."

# Attendre que le seeder ait rempli private_keys (max 60s)
TIMEOUT=60; ELAPSED=0
until docker exec coolify-db psql -U coolify -d coolify -tAc \
  "SELECT COUNT(*) FROM private_keys;" 2>/dev/null | grep -q "^[1-9]"; do
  sleep 3; ELAPSED=$((ELAPSED + 3))
  [[ $ELAPSED -ge $TIMEOUT ]] && break
  echo -n "."
done

# Si toujours vide, forcer le seeder maintenant (pas de race condition, Coolify est up)
if ! docker exec coolify-db psql -U coolify -d coolify -tAc \
  "SELECT COUNT(*) FROM private_keys;" 2>/dev/null | grep -q "^[1-9]"; then
  docker exec coolify php artisan db:seed --class=PrivateKeySeeder --force 2>/dev/null || true
fi
echo ""

# Passer la clé en base64 inline — pas de fichier temporaire, pas de problème de permissions
SSH_KEY_B64=$(base64 -w0 "$SSH_KEY")

docker exec coolify php artisan tinker --execute="
\$key = App\Models\PrivateKey::updateOrCreate(
  ['uuid' => 'ssh'],
  [
    'name'        => 'localhost',
    'description' => 'SSH key for local server',
    'private_key' => base64_decode('${SSH_KEY_B64}'),
    'team_id'     => 0,
  ]
);
echo 'PrivateKey id=' . \$key->id;
" 2>/dev/null || true

PK_ID=$(docker exec coolify-db psql -U coolify -d coolify -tAc \
  "SELECT id FROM private_keys WHERE uuid='ssh' LIMIT 1;" 2>/dev/null | tr -d ' ')

if [[ -n "$PK_ID" ]]; then
  docker exec coolify-db psql -U coolify -d coolify \
    -c "UPDATE servers SET private_key_id = ${PK_ID} WHERE id = 0;" \
    >/dev/null 2>&1 || true
  ok "Clé SSH locale → DB (private_key_id=${PK_ID})"
else
  warn "Impossible de corriger private_key_id — vérifier manuellement"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "7/7 — Vérifications"
# ─────────────────────────────────────────────────────────────────────────────
FAILURES=()
for SVC in traefik coolify-db coolify-redis coolify; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$SVC" 2>/dev/null || echo "missing")
  if [[ "$STATUS" == "running" ]]; then
    ok "$SVC → running"
  else
    FAILURES+=("$SVC ($STATUS)"); warn "$SVC → $STATUS"
  fi
done
[[ ${#FAILURES[@]} -eq 0 ]] \
  || die "Services en échec : ${FAILURES[*]}\nLogs: docker compose -f ${COMPOSE_FILE} logs"

HTTPS_CODE=$(curl -o /dev/null -sf -w "%{http_code}" \
  --max-time 15 --connect-timeout 10 "https://${DOMAIN}" 2>/dev/null || echo "000")

if [[ "$HTTPS_CODE" =~ ^(200|302|301|307|308)$ ]]; then
  ok "HTTPS actif (HTTP ${HTTPS_CODE})"
else
  warn "HTTPS pas encore prêt (${HTTPS_CODE}) — Let's Encrypt prend 1-2 min"
fi

SERVER_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
  || curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
  || echo "<ip-serveur>")

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}${BOLD}Installation terminée !${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}URL     :${NC}  https://${DOMAIN}"
echo -e "  ${CYAN}IP      :${NC}  ${SERVER_IP}"
echo -e "  ${CYAN}Version :${NC}  Coolify ${COOLIFY_VERSION}"
echo ""
echo -e "  ${YELLOW}Cloudflare SSL/TLS :${NC} Full ou Full (strict)"
echo ""
echo -e "  ${GREEN}${BOLD}Coolify est disponible sur https://${DOMAIN}${NC}"
echo ""
echo "  Commandes utiles :"
echo "    docker compose -f ${COMPOSE_FILE} logs -f coolify"
echo "    docker compose -f ${COMPOSE_FILE} logs -f traefik"
echo "    docker exec coolify php artisan migrate:status"
echo ""
