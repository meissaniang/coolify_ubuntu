# Coolify One-Line Installer

Déploie [Coolify](https://coolify.io) en production sur un VPS Ubuntu avec **Traefik** comme reverse proxy, **Let's Encrypt** automatique et **Cloudflare** comme CDN/SSL — en une seule commande.

## Prérequis

| Quoi | Détail |
|---|---|
| VPS | Ubuntu 22.04+ (fresh), accès root |
| RAM / CPU | 2 vCPU, 2 GB RAM minimum |
| Disque | 20 GB minimum |
| Domaine | Enregistré dans Cloudflare |
| DNS Cloudflare | Record `A` → IP du VPS, **proxy activé (☁ orange)** |

> Le script **ne touche pas** Cloudflare. Le DNS doit être configuré avant de lancer l'install.

---

## Utilisation

```bash
curl -fsSL https://raw.githubusercontent.com/meissaniang/coolify_ubuntu/main/install.sh | bash -s -- coolify.mondomaine.com
```

Pour inspecter le script avant exécution :

```bash
curl -fsSL https://raw.githubusercontent.com/meissaniang/coolify_ubuntu/main/install.sh -o install.sh
cat install.sh
bash install.sh coolify.mondomaine.com
```

---

## Architecture déployée

```
Internet
   │
   │ HTTPS
   ▼
Cloudflare (proxy ☁)
   │
   │ HTTPS
   ▼
VPS — Traefik :443 / :80
         │
         │ HTTP interne
         ▼
      coolify:8080  ← jamais exposé sur l'hôte
```

### Stack Docker

| Service | Image | Port hôte |
|---|---|---|
| Traefik | `traefik:v3.0` | 80, 443 |
| PostgreSQL | `postgres:16-alpine` | aucun |
| Redis | `redis:7-alpine` | aucun |
| Coolify | `ghcr.io/coollabsio/coolify:latest` | **aucun** |

---

## Ce que fait le script

```
1. Vérification du domaine, root et OS
2. Installation des paquets système (curl, git, ufw...)
3. Configuration firewall UFW → 22, 80, 443 (reste bloqué)
4. Installation Docker + Docker Compose v2
5. Création de /opt/coolify/ avec répertoires de données
6. Génération des secrets (APP_KEY, DB_PASSWORD) → /opt/coolify/.env
7. Génération du docker-compose.yml avec le domaine injecté
8. Pull et démarrage des services (Traefik → DB/Redis → Coolify)
9. Health checks PostgreSQL et Redis
10. Vérification HTTPS finale
```

### Fichiers créés sur le VPS

```
/opt/coolify/
├── .env                        ← secrets (APP_KEY, DB_PASSWORD) — chmod 600
├── docker-compose.yml
└── data/
    ├── traefik/
    │   └── acme.json           ← certificats Let's Encrypt — chmod 600
    └── coolify/                ← données persistantes Coolify
```

---

## Configuration Cloudflare

### DNS (avant l'install)

| Type | Nom | Valeur | Proxy |
|---|---|---|---|
| A | `coolify.mondomaine.com` | IP du VPS | ☁ Activé |

### SSL/TLS (après l'install)

Aller dans **SSL/TLS → Overview** et choisir :

**Full** ou **Full (strict)**

| Mode | Comportement | Recommandé |
|---|---|---|
| Flexible | CF → HTTP → serveur | ✗ Non sécurisé |
| Full | CF → HTTPS → serveur (cert auto-signé OK) | ✓ |
| Full (strict) | CF → HTTPS → serveur (cert CA valide requis) | ✓ Let's Encrypt valide |

### Comment fonctionne le SSL

```
Utilisateur ──HTTPS──► Cloudflare ──HTTPS──► Traefik ──HTTP──► Coolify:8080
                           ↑                     ↑
                     Cert Cloudflare       Cert Let's Encrypt
                     (géré par CF)         (auto via HTTP-01)
```

Traefik obtient automatiquement un certificat Let's Encrypt via **HTTP-01**. La validation passe à travers Cloudflare (port 80 proxifié) → fonctionne nativement.

---

## Après l'installation

1. Ouvrir `https://coolify.mondomaine.com`
2. Créer le compte administrateur
3. Coolify est opérationnel — il gère :
   - Le déploiement des apps (Docker, Git, etc.)
   - Les domaines et certificats des apps déployées
   - Les bases de données et services
   - Les environnements et variables

---

## Déployer une app via Coolify

Pour chaque app avec son propre sous-domaine :

1. Créer un record DNS dans Cloudflare : `A` → `app1.mondomaine.com` → IP du VPS (☁ proxy)
2. Dans Coolify : ajouter le domaine `https://app1.mondomaine.com` à l'app
3. Coolify configure le routing automatiquement

---

## Commandes utiles

```bash
# État des services
docker compose -f /opt/coolify/docker-compose.yml ps

# Logs en temps réel
docker compose -f /opt/coolify/docker-compose.yml logs -f coolify
docker compose -f /opt/coolify/docker-compose.yml logs -f traefik

# Redémarrer
docker compose -f /opt/coolify/docker-compose.yml restart

# Mettre à jour Coolify
docker compose -f /opt/coolify/docker-compose.yml pull coolify
docker compose -f /opt/coolify/docker-compose.yml up -d coolify
```

---

## Résolution de problèmes

**Services non démarrés**
```bash
docker compose -f /opt/coolify/docker-compose.yml ps
docker compose -f /opt/coolify/docker-compose.yml logs
```

**Certificat Let's Encrypt non émis**
```bash
# Vérifier les logs Traefik
docker logs traefik 2>&1 | grep -i "acme\|cert\|error"

# Vérifier que le port 80 est accessible depuis l'extérieur
curl -I http://coolify.mondomaine.com
```

**Relancer depuis zéro (idempotent)**
```bash
curl -fsSL https://raw.githubusercontent.com/meissaniang/coolify_ubuntu/main/install.sh | bash -s -- coolify.mondomaine.com
```

---

## Serveurs supportés

| OS | Supporté |
|---|---|
| Ubuntu 22.04 LTS | ✓ |
| Ubuntu 24.04 LTS | ✓ |
| Ubuntu 20.04 LTS | ✓ (non testé) |
| Debian / autres | ✗ |
