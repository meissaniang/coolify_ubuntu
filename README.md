# Coolify One-Line Installer

Installe [Coolify](https://coolify.io) sur un VPS Ubuntu avec un domaine custom géré par Cloudflare — en une seule commande.

## Prérequis

| Quoi | Détail |
|---|---|
| VPS | Ubuntu 22.04+ (fresh), accès root |
| Domaine | Enregistré dans Cloudflare |
| DNS Cloudflare | Record `A` → IP du VPS, **proxy activé (☁ orange)** |
| Ports ouverts | 22, 80, 443 |

> Le script **ne touche pas** Cloudflare. Le DNS doit être configuré manuellement avant de lancer l'install.

---

## Utilisation

```bash
curl -fsSL https://raw.githubusercontent.com/meissaniang/coolify_ubuntu/main/install.sh | bash -s -- coolify.mondomaine.com
```

Remplacer `coolify.mondomaine.com` par ton domaine réel.

Pour télécharger et inspecter avant d'exécuter :

```bash
curl -fsSL https://raw.githubusercontent.com/meissaniang/coolify_ubuntu/main/install.sh -o install.sh
cat install.sh          # vérifier le contenu
bash install.sh coolify.mondomaine.com
```

---

## Ce que fait le script

```
1. Update du système (apt)
2. Configuration firewall (ufw) → 22, 80, 443
3. Installation Docker (si absent)
4. Installation Coolify via l'installeur officiel
5. Configuration du domaine dans /data/coolify/source/.env
6. Restart des services Coolify
7. Health check de l'API
```

---

## Configuration Cloudflare

Après l'install, configurer dans le dashboard Cloudflare :

### DNS
| Type | Nom | Valeur | Proxy |
|---|---|---|---|
| A | `coolify.mondomaine.com` | IP du VPS | ☁ Activé |

### SSL/TLS
- Aller dans **SSL/TLS → Overview**
- Choisir le mode **Full** (pas Flexible, pas Full (strict))

> **Pourquoi "Full" ?**  
> - Flexible → Cloudflare fait du HTTP vers ton serveur (non sécurisé)  
> - Full → Cloudflare fait du HTTPS vers ton serveur (accepte le cert Let's Encrypt de Coolify)  
> - Full (strict) → Exige un cert signé par une CA reconnue (Let's Encrypt via HTTP-01 fonctionne aussi)

### Comment le SSL fonctionne
```
Utilisateur ──HTTPS──► Cloudflare ──HTTPS──► VPS (Coolify/Caddy)
                         ↑
                   Cert Cloudflare          Cert Let's Encrypt
                   (géré par CF)            (auto via Caddy)
```

Caddy (proxy interne de Coolify) obtient automatiquement un certificat Let's Encrypt via HTTP-01. Cloudflare proxifie la validation → ça fonctionne même derrière le proxy Cloudflare.

---

## Après l'installation

1. Ouvrir `https://coolify.mondomaine.com`
2. Créer le compte administrateur
3. Coolify est prêt — il gère seul :
   - Le déploiement des apps
   - Les domaines custom des apps (sous-domaines via Cloudflare)
   - Les certificats SSL des apps déployées
   - Les bases de données, services, etc.

---

## Déployer une app via Coolify

Chaque app déployée sur Coolify peut avoir son propre sous-domaine :

1. Créer un record DNS dans Cloudflare : `A` → `app1.mondomaine.com` → IP du VPS (☁ proxy)
2. Dans Coolify : ajouter le domaine `https://app1.mondomaine.com` à l'app
3. Coolify/Caddy gère le routing et le SSL automatiquement

---

## Résolution de problèmes

**Coolify inaccessible après l'install**
```bash
# Vérifier que les containers tournent
docker ps

# Voir les logs Coolify
docker logs coolify

# Relancer manuellement
cd /data/coolify/source && docker compose up -d
```

**Let's Encrypt rate limit / cert non obtenu**
```bash
# Vérifier les logs Caddy
docker logs coolify-proxy
```

**Vérifier la config du domaine**
```bash
cat /data/coolify/source/.env | grep -E "APP_FQDN|APP_URL"
```

---

## Serveurs supportés

| OS | Supporté |
|---|---|
| Ubuntu 22.04 LTS | ✓ |
| Ubuntu 24.04 LTS | ✓ |
| Ubuntu 20.04 LTS | ✓ (non testé) |
| Debian / autres | ✗ |

Minimum recommandé : 2 vCPU, 2 GB RAM, 20 GB disque.
