#!/bin/bash
################################################################################
# Script for installing Odoo on Ubuntu 16.04, 18.04, 20.04 and 24.04
# Rewritten to deploy Traefik (community) instead of Nginx as reverse proxy.
# Original base author: Yenthe Van Ginneken
# Rewriter: ChatGPT
#-------------------------------------------------------------------------------
# Usage:
#   chmod +x odoo_install_traefik.sh
#   sudo ./odoo_install_traefik.sh
################################################################################

set -euo pipefail

OE_USER="odoo19"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"

# The default port where this Odoo instance will run under (provided you use the command -c in the terminal)
INSTALL_WKHTMLTOPDF="True"

# Set the default Odoo port
OE_PORT="8069"

# Choose the Odoo version which you want to install. For example: 19.0, 18.0, 17.0 or master.
OE_VERSION="19.0"

# Set this to True if you want to install the Odoo enterprise version
IS_ENTERPRISE="True"

# Install PostgreSQL 16 from PGDG (improved performance)
INSTALL_POSTGRESQL_SIXTEEN="False"

# --- Traefik instead of Nginx ---
INSTALL_TRAEFIK="True"
# Force-disable Nginx logic from the original script
INSTALL_NGINX="False"

# Admin / SSL settings
OE_SUPERADMIN="admin"
GENERATE_RANDOM_PASSWORD="False"
OE_CONFIG="${OE_USER}-server"
WEBSITE_NAME="_"         # e.g. "erp.example.com"
LONGPOLLING_PORT="8072"
ENABLE_SSL="True"        # When True and WEBSITE_NAME & ADMIN_EMAIL are set, Traefik will provision Let's Encrypt
ADMIN_EMAIL="odoo@example.com"

# ---- Optional DB dashboards ----
ENABLE_PGHERO="False"
ENABLE_PGADMIN="False"

# PgHero connection (will be generated if empty)
PGHERO_DB_NAME="postgres"
PGHERO_DB_USER="pghero_user"
PGHERO_DB_PASSWORD=""   # leave empty to auto-generate
PGHERO_DB_HOST="127.0.0.1"
PGHERO_DB_PORT="5432"

# pgAdmin defaults (only used when ENABLE_PGADMIN=True)
PGADMIN_DEFAULT_EMAIL="admin@example.com"
PGADMIN_DEFAULT_PASSWORD=""  # leave empty to auto-generate
PGADMIN_LISTEN_PORT="8082"   # bound to localhost, Traefik proxies externally
PGHERO_LISTEN_PORT="8081"    # bound to localhost, Traefik proxies externally

# Subdomains for dashboards (set valid DNS A/AAAA records)
PGHERO_SUBDOMAIN="pghero.example.com"
PGADMIN_SUBDOMAIN="pgadmin.example.com"

# (Optional) IP allowlists for Traefik middlewares. Comma-separated CIDRs.
# Leave empty to disable IP allowlisting.
PGHERO_IP_ALLOWLIST=""
PGADMIN_IP_ALLOWLIST=""

# Enterprise Github (optional)
GITHUB_ENTERPRISE_USER=""
GITHUB_ENTERPRISE_TOKEN=" "

# ---- Helpers ----
PYTHON_BIN="python3"
VENV_DIR="${OE_HOME_EXT}/venv"

detect_branch () {
  local repo="$1" want="$2"
  if git ls-remote --heads "$repo" "$want" | grep -q "$want"; then
    echo "$want"
    return 0
  fi
  echo ">>> WARNING: Branch '$want' not found on $repo"
  if [[ "$want" =~ ^19(\.0)?$ ]]; then
    echo "master"
  else
    echo "18.0"
  fi
}

detect_pg_version () {
  if command -v psql >/dev/null 2>&1; then
    local v
    v="$( if [ "$ENABLE_PGHERO" = "True" ]; then cat <<'EOT'
    pghero:
      rule: "Host(`PGHERO_SUBDOMAIN_PLACEHOLDER`)"
      entryPoints: ["websecure"]
      service: pghero-svc
      middlewares: ["secure-headers", "pghero-auth"$( [ -n "$PGHERO_IP_ALLOWLIST" , "pghero-auth"] && echo ', "pghero-allow"' )]
      tls:
        certResolver: letsencrypt
EOT
fi )

$( 
if [ "$ENABLE_PGADMIN" = "True" ]; then
  echo -e "\n---- Installing pgAdmin4 (non-Docker, APT repo) ----"
  # Add official pgAdmin APT repo
  curl -fsSLo /usr/share/keyrings/pgadmin-keyring.gpg https://www.pgadmin.org/static/packages_pgadmin_org.pub
  sh -c 'echo "deb [signed-by=/usr/share/keyrings/pgadmin-keyring.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(lsb_release -cs) pgadmin4 main" > /etc/apt/sources.list.d/pgadmin4.list'
  apt-get update -y
  apt-get install -y pgadmin4-web

  # Non-interactive setup
  /usr/pgadmin4/bin/setup-web.sh --yes

  # Rebind Apache to localhost:${PGADMIN_LISTEN_PORT}
  if [ -f /etc/apache2/ports.conf ]; then
    sed -i 's/^\s*Listen .*/Listen 127.0.0.1:${PGADMIN_LISTEN_PORT}/g' /etc/apache2/ports.conf
    grep -q "Listen 127.0.0.1:${PGADMIN_LISTEN_PORT}" /etc/apache2/ports.conf || echo "Listen 127.0.0.1:${PGADMIN_LISTEN_PORT}" >> /etc/apache2/ports.conf
  fi
  if [ -f /etc/apache2/sites-available/pgadmin4.conf ]; then
    sed -i "s#<VirtualHost \\*:80>#<VirtualHost 127.0.0.1:${PGADMIN_LISTEN_PORT}>#g" /etc/apache2/sites-available/pgadmin4.conf
  fi
  systemctl restart apache2

  echo "pgAdmin4 installed. Access will be proxied by Traefik at https://${PGADMIN_SUBDOMAIN}"
fi
  if [ -n "$PGADMIN_IP_ALLOWLIST" ]; then
    PGADMIN_IPS=$(echo "$PGADMIN_IP_ALLOWLIST" | sed "s/,/\", \"/g")
    sudo sed -i "s|PGADMIN_IPS_PLACEHOLDER|\"${PGADMIN_IPS}\"|g" /etc/traefik/dynamic/odoo.yml
  else
    sudo sed -i "s|PGADMIN_IPS_PLACEHOLDER||g" /etc/traefik/dynamic/odoo.yml
  fi

  # If SSL is enabled & domain/email are set, append ACME config
  if [ "$ENABLE_SSL" = "True" ] && [ "$ADMIN_EMAIL" != "odoo@example.com" ] && [ "$WEBSITE_NAME" != "_" ]; then
    sudo bash -c 'cat >> /etc/traefik/traefik.yml' <<EOF
certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ADMIN_EMAIL}"
      storage: "/var/lib/traefik/acme.json"
      httpChallenge:
        entryPoint: web
EOF
  else
    echo "INFO: SSL is disabled or misconfigured (ADMIN_EMAIL/WEBSITE_NAME). Running HTTP only on :80."
  fi

  # Ensure Traefik uses our YAML (Ubuntu package may default to TOML). Create a systemd drop-in.
  sudo mkdir -p /etc/systemd/system/traefik.service.d
  sudo bash -c 'cat > /etc/systemd/system/traefik.service.d/override.conf' <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/traefik --configFile=/etc/traefik/traefik.yml
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable traefik
  sudo systemctl restart traefik

  # Enable proxy mode in Odoo config
  sudo su root -c "grep -q '^proxy_mode' /etc/${OE_CONFIG}.conf || printf 'proxy_mode = True\n' >> /etc/${OE_CONFIG}.conf"

  echo "Done! Traefik is up and proxying to Odoo."
else
  echo "Traefik isn't installed due to user choice!"
fi

# Certbot section removed: Traefik handles ACME automatically when ENABLE_SSL=True.

echo -e "* Starting Odoo Service"
sudo su root -c "/etc/init.d/$OE_CONFIG start"

echo "-----------------------------------------------------------"
echo "Done! The Odoo server is up and running. Specifications:"
echo "Port: $OE_PORT"
echo "User service: $OE_USER"
echo "Configuraton file location: /etc/${OE_CONFIG}.conf"
echo "Logfile location: /var/log/$OE_USER"
echo "User PostgreSQL: $OE_USER"
echo "Code location: $OE_USER"
echo "Addons folder: $OE_USER/$OE_CONFIG/addons/"
echo "Password superadmin (database): $OE_SUPERADMIN"
echo "Start Odoo service: sudo service $OE_CONFIG start"
echo "Stop Odoo service: sudo service $OE_CONFIG stop"
echo "Restart Odoo service: sudo service $OE_CONFIG restart"
if [ "$INSTALL_TRAEFIK" = "True" ]; then
  echo "Traefik main config: /etc/traefik/traefik.yml"
  echo "Traefik dynamic config: /etc/traefik/dynamic/odoo.yml"
  echo "ACME storage: /var/lib/traefik/acme.json"
fi
echo "-----------------------------------------------------------"
