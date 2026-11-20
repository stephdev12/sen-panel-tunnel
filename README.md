<!-- SEN PANEL TUNNEL Banner -->
<p align="center">
  <img src="https://img.shields.io/badge/version-2.1.0-blue.svg" alt="Version">
<a href="LICENSE">
  <img src="https://img.shields.io/badge/license-GPL--3.0-red.svg" alt="License: GPL-3.0">
</a>
  <img src="https://img.shields.io/badge/bash-5.0+-4EAA25.svg" alt="Bash">
  <img src="https://img.shields.io/badge/node.js-18.x+-339933.svg" alt="Node.js">
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs Welcome">
  <img src="https://img.shields.io/badge/Powered%20by-SEN-ff69b4.svg" alt="Powered by SEN">
</p>

<h1 align="center">🚀 SEN PANEL TUNNEL</h1>

<p align="center">
  <strong>Suite complète de gestion de tunnels VPN SSH/UDP avec architecture double-panel & support de l'application cliente Surfeo</strong>
</p>

---

## 📋 Présentation

**SEN PANEL TUNNEL** est une solution complète de gestion de serveurs VPN combinant un panel terminal interactif (`menu`) et un panel web d'administration et de revente en Node.js/Express, synchronisés sur les mêmes fichiers système (`/etc/novaxtunnel/users.db`).

### Protocoles & Fonctionnalités
- **SSH WebSocket / Payload HTTP** (avec support CloudFront CDN et code HTTP 101)
- **SSH UDP Custom / UDPGW** (port 7300)
- **SSH TLS / Stunnel & HAProxy**
- **ZiVPN & SlowDNS (DNSTT)**
- **API Surfeo v1** (`/api/app/v1`) pour l'activation sans configuration, la liaison matérielle d'appareils et le suivi en temps réel
- **BBR & Optimisations réseau TCP / Quotas fiabilisés** (`cur=$wchar` sans double comptage, OpenSSH 9.8+ `sshd-session`)

---

## 🏗️ Architecture

```text
/opt/nova-x-tunnel/
├── bootstrap.sh                    # Script d'installation & mise à jour globale
├── senpanel-fix.sh                 # Correctifs WebSocket, HAProxy, BBR, OpenSSH 9.8+, quotas
├── terminal-panel/                 # Menu interactif SSH Bash
│   ├── install.sh                  # Installation sur le VPS
│   ├── menu.sh                     # Interface terminal (`menu`)
│   └── ssh                         # Configuration SSH durcie
│
└── web-panel/                      # Interface Web Node.js Admin / Resellers + API Surfeo
    ├── deploy/
    │   ├── ubuntu24-install.sh     # Installateur automatisé Ubuntu 24.04 (Nginx + Let's Encrypt)
    │   └── install.sh              # Déploiement interactif avancé
    ├── server.js                   # Point d'entrée de l'application Express
    ├── routes/
    │   ├── appApi.js               # API cliente Surfeo (/api/app/v1)
    │   ├── profiles.js             # Gestion des profils de connexion
    │   ├── appAccounts.js          # Comptes liés & clés d'activation
    │   └── admin.js                # Administration
    └── db/                         # Base SQLite (profils, clés, comptes, logs)
```

---

## 🔄 Migration & Mise à niveau sans coupure (Serveurs existants)

Pour mettre à niveau un serveur existant (anciennement sous NOVA XTUNNEL) vers **SEN PANEL TUNNEL** sans couper les sessions en direct et sans perdre **aucun compte client, revendeur ou administrateur** :

```bash
curl -fsSL https://raw.githubusercontent.com/stephdev12/sen-panel-tunnel/main/migrate-to-senpanel.sh | sudo bash
```

Ce script garantit :
- **Sessions SSH actives maintenues** (aucun redémarrage destructeur de sshd)
- **Comptes clients préservés** (`/etc/novaxtunnel/users.db` et compteurs de données)
- **Comptes revendeurs et admin préservés** (`panel.sqlite3` et `.env`)
- **Lien symbolique de compatibilité** `/opt/nova-x-tunnel -> /opt/nova-x-tunnel`
- **Application immédiate des correctifs** WebSocket HAProxy, OpenSSH 9.8+, quotas fiabilisés et TCP BBR

---

## 🚀 Installation Rapide (Nouveau serveur)

### En une seule commande :
```bash
curl -fsSL https://raw.githubusercontent.com/stephdev12/sen-panel-tunnel/main/bootstrap.sh | sudo bash
```

Le script installe automatiquement :
1. Le panel terminal `/usr/local/bin/menu`
2. Les optimisations VPS (`senpanel-fix.sh` : BBR, CloudFront/HAProxy sur port 444, OpenSSH 9.8+, limites fichiers)
3. Le panel web Node.js avec certificat SSL Let's Encrypt automatique

### Commandes utiles sur le VPS :
- Ouvrir le menu terminal : `menu`
- Gérer le panel web : `novaxpanel` ou `systemctl status novaxpanel`
- Réappliquer les correctifs WebSocket / CloudFront : `sudo bash /opt/nova-x-tunnel/senpanel-fix.sh`

---

## 📱 Extension Application Surfeo

Le panel intègre directement l'API pour l'application cliente **Surfeo** :
- **ID Appareil** : format Crockford base32 `XXXX-XXXX-XXXX-X`
- **Clés d'activation** : `NVX1-SEN-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`
- **Endpoints** :
  - `POST /api/app/v1/activate`
  - `GET /api/app/v1/status`
  - `GET /api/app/v1/config`
  - `GET /api/app/v1/meta`
