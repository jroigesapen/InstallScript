#!/bin/bash
set -euo pipefail

################################################################################
# Odoo installer with Traefik (community), PgHero (Docker) & pgAdmin (APT)
# - Subdominios + IP allowlists opcionales para PgHero/pgAdmin
# - Traefik Basic Auth para ambos (usuario/clave por defecto: admin/admin)
# - Instala 'phonenumbers' en el venv de Odoo
# Probado con 'bash -n'
################################################################################

OE_USER="odoo19"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"
OE_VERSION="19.0"
OE_PORT="8069"
LONGPOLLING_PORT="8072"
OE_CONFIG="${OE_USER}-server"
OE_SUPERADMIN="admin"
GENERATE_RANDOM_PASSWORD="False"
IS_ENTERPRISE="True"
INSTALL_POSTGRESQL_SIXTEEN="False"
INSTALL_WKHTMLTOPDF="True"

# Traefik & SSL
INSTALL_TRAEFIK="True"
ENABLE_SSL="True"
WEBSITE_NAME="_"                 # e.g. erp.example.com
ADMIN_EMAIL="odoo@example.com"

# Dashboards opcionales
ENABLE_PGHERO="False"
ENABLE_PGADMIN="False"

# PgHero DB
PGHERO_DB_NAME="postgres"
PGHERO_DB_USER="pghero_user"
PGHERO_DB_PASSWORD=""            # autogenera si vacío
PGHERO_DB_HOST="127.0.0.1"
PGHERO_DB_PORT="5432"

# Puertos locales (solo loopback)
PGHERO_LISTEN_PORT="8081"
PGADMIN_LISTEN_PORT="8082"

# Subdominios
PGHERO_SUBDOMAIN="pghero.example.com"
PGADMIN_SUBDOMAIN="pgadmin.example.com"

# IP allowlists (CIDRs separados por comas) - dejar vacío para desactivar
PGHERO_IP_ALLOWLIST=""
PGADMIN_IP_ALLOWLIST=""

# Traefik Basic Auth (cambia estas credenciales)
PGHERO_BASIC_AUTH_USER="admin"
PGHERO_BASIC_AUTH_PASS="admin"
PGADMIN_BASIC_AUTH_USER="admin"
PGADMIN_BASIC_AUTH_PASS="admin"

# Enterprise Github (opcional)
GITHUB_ENTERPRISE_USER=""
GITHUB_ENTERPRISE_TOKEN=" "

# Helpers
PYTHON_BIN="python3"
VENV_DIR="${OE_HOME_EXT}/venv"

detect_branch () {
  local repo="$1" want="$2"
  if git ls-remote --heads "$repo" "$want" | grep -q "$want"; then
    echo "$want"; return 0
  fi
  echo ">>> WARNING: Branch '$want' not found on $repo"
  if [[ "$want" =~ ^19(\.0)?$ ]]; then echo "master"; else echo "18.0"; fi
}

detect_pg_version () {
  if command -v psql >/dev/null 2>&1; then
    local v
    v="$(psql -V | awk '{print $3}' | cut -d. -f1)"
    echo "$v"; return 0
  fi
  echo ""; return 1
}

echo "---- Update & base packages ----"
apt-get update -y
apt-get upgrade -y
apt-get install -y libpq-dev curl wget ca-certificates gnupg lsb-release git build-essential \
  python3 python3-pip python3-venv python3-dev python3-wheel python3-setuptools nodejs npm \
  libxslt-dev libzip-dev libldap2-dev libsasl2-dev node-less libpng-dev libjpeg-dev gdebi-core

npm install -g rtlcss || true

echo "---- PostgreSQL ----"
if [ "$INSTALL_POSTGRESQL_SIXTEEN" = "True" ]; then
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
  sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
  apt-get update -y && apt-get install -y postgresql-16 postgresql-client-16 postgresql-contrib-16
else
  apt-get install -y postgresql postgresql-server-dev-all
fi

echo "---- Create Odoo PostgreSQL user ----"
su - postgres -c "createuser -s $OE_USER" 2>/dev/null || true

echo "---- Enable pg_stat_statements + PgHero role ----"
PG_VERSION="$(detect_pg_version || true)"
if [ -n "$PG_VERSION" ]; then
  PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
  PG_CONF="$PG_CONF_DIR/postgresql.conf"
  if [ -f "$PG_CONF" ]; then
    sed -i "s/^#\?\s*shared_preload_libraries.*/shared_preload_libraries = 'pg_stat_statements'/g" "$PG_CONF" || true
    grep -q "^shared_preload_libraries" "$PG_CONF" || echo "shared_preload_libraries = 'pg_stat_statements'" >> "$PG_CONF"
    systemctl restart postgresql || true
  fi

  if [ "$ENABLE_PGHERO" = "True" ]; then
    [ -z "$PGHERO_DB_PASSWORD" ] && PGHERO_DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"

    # Bloque robusto mediante heredoc entrecomillado (sin expansión de bash)
    sudo -u postgres psql \
      -v uname="${PGHERO_DB_USER}" \
      -v upass="${PGHERO_DB_PASSWORD}" \
      -v dbname="${PGHERO_DB_NAME}" <<'SQL'
DO $do$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'uname') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'uname', :'upass');
  END IF;
END
$do$;

GRANT CONNECT ON DATABASE :"dbname" TO :"uname";
\connect :"dbname"
GRANT USAGE ON SCHEMA public TO :"uname";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"uname";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO :"uname";
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
  fi
fi

echo "---- Create system user & directories ----"
id "$OE_USER" >/dev/null 2>&1 || adduser --system --quiet --shell=/bin/bash --home="$OE_HOME" --gecos 'ODOO' --group "$OE_USER"
adduser "$OE_USER" sudo || true
mkdir -p "$OE_HOME_EXT" "$OE_HOME/custom/addons" "/var/log/$OE_USER"
chown -R "$OE_USER:$OE_USER" "$OE_HOME" "/var/log/$OE_USER"

echo "---- Clone Odoo ----"
REPO_URL="https://github.com/odoo/odoo"
GIT_BRANCH="$(detect_branch "$REPO_URL" "$OE_VERSION")"
if [ ! -d "$OE_HOME_EXT/.git" ]; then
  git clone --depth 1 --branch "$GIT_BRANCH" https://www.github.com/odoo/odoo "$OE_HOME_EXT/"
else
  git -C "$OE_HOME_EXT" fetch --depth 1 origin "$GIT_BRANCH" || true
  git -C "$OE_HOME_EXT" checkout "$GIT_BRANCH"
  git -C "$OE_HOME_EXT" pull --ff-only || true
fi
chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT"

echo "---- Python venv & requirements (incl. phonenumbers) ----"
sudo -u "$OE_USER" "$PYTHON_BIN" -m venv "$VENV_DIR"
sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel
sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install --no-cache-dir -r "https://raw.githubusercontent.com/odoo/odoo/${GIT_BRANCH}/requirements.txt"
sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install --no-cache-dir phonenumbers

echo "---- Wkhtmltopdf / paper-muncher ----"
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
  if [ "$(lsb_release -r -s)" = "24.04" ]; then
    apt-get install -y wkhtmltopdf
    wget -q https://github.com/odoo/paper-muncher/releases/download/nightly/paper-muncher_nightly_noble_amd64.deb -O /tmp/paper-muncher.deb
    apt-get install -y /tmp/paper-muncher.deb || dpkg -i /tmp/paper-muncher.deb || true
    ln -sf /opt/paper-muncher/bin/paper-muncher /usr/bin/paper-muncher || true
  else
    WKHTMLTOX_X64="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_amd64.deb"
    wget -q "$WKHTMLTOX_X64" -O /tmp/wkhtmltox.deb
    gdebi --non-interactive /tmp/wkhtmltox.deb || apt-get install -y /tmp/wkhtmltox.deb || true
    ln -sf /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf || true
    ln -sf /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage || true
  fi
fi

echo "---- Odoo config ----"
touch /etc/${OE_CONFIG}.conf
{
  echo "[options]"
  echo "; admin password for database operations"
  if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    OE_SUPERADMIN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
  fi
  echo "admin_passwd = ${OE_SUPERADMIN}"
  echo "http_port = ${OE_PORT}"
  echo "longpolling_port = ${LONGPOLLING_PORT}"
  echo "logfile = /var/log/${OE_USER}/${OE_CONFIG}.log"
  echo "addons_path = ${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
} > /etc/${OE_CONFIG}.conf
chown "$OE_USER:$OE_USER" /etc/${OE_CONFIG}.conf
chmod 640 /etc/${OE_CONFIG}.conf

echo "---- Init script ----"
cat >/etc/init.d/$OE_CONFIG <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          Odoo service
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Should-Start:      $network
# Should-Stop:       $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Enterprise Business Applications
# Description:       ODOO Business Applications
### END INIT INFO
PATH=/sbin:/bin:/usr/sbin:/usr/bin
DAEMON=/odoo19/odoo19-server/odoo-bin
NAME=odoo19-server
DESC=odoo19-server
USER=odoo19
CONFIGFILE="/etc/odoo19-server.conf"
PIDFILE=/var/run/${NAME}.pid
DAEMON_OPTS="-c ${CONFIGFILE}"
[ -x ${DAEMON} ] || exit 0
[ -f ${CONFIGFILE} ] || exit 0
case "$1" in
  start) start-stop-daemon --start --quiet --pidfile ${PIDFILE} --chuid ${USER} --background --make-pidfile --exec ${DAEMON} -- ${DAEMON_OPTS};;
  stop) start-stop-daemon --stop --quiet --pidfile ${PIDFILE} --oknodo;;
  restart|force-reload) start-stop-daemon --stop --quiet --pidfile ${PIDFILE} --oknodo; sleep 1; start-stop-daemon --start --quiet --pidfile ${PIDFILE} --chuid ${USER} --background --make-pidfile --exec ${DAEMON} -- ${DAEMON_OPTS};;
  *) echo "Usage: $NAME {start|stop|restart|force-reload}" >&2; exit 1;;
esac
exit 0
EOF
chmod 755 /etc/init.d/$OE_CONFIG
chown root: /etc/init.d/$OE_CONFIG
update-rc.d $OE_CONFIG defaults

#--------------------------------------------------
# pgAdmin (APT) y PgHero (Docker)
#--------------------------------------------------
if [ "$ENABLE_PGHERO" = "True" ]; then
  apt-get update -y
  apt-get install -y docker.io
  systemctl enable docker
  systemctl start docker

  PGHERO_URL="postgres://${PGHERO_DB_USER}:${PGHERO_DB_PASSWORD}@${PGHERO_DB_HOST}:${PGHERO_DB_PORT}/${PGHERO_DB_NAME}"
  cat >/etc/systemd/system/pghero.service <<EOF
[Unit]
Description=PgHero (Docker)
After=docker.service
Requires=docker.service

[Service]
Restart=always
ExecStart=/usr/bin/docker run --rm --name pghero -p 127.0.0.1:${PGHERO_LISTEN_PORT}:8080 -e DATABASE_URL="${PGHERO_URL}" ankane/pghero
ExecStop=/usr/bin/docker stop pghero

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable pghero
  systemctl restart pghero
fi

if [ "$ENABLE_PGADMIN" = "True" ]; then
  echo "---- Installing pgAdmin4 (APT) ----"
  curl -fsSLo /usr/share/keyrings/pgadmin-keyring.gpg https://www.pgadmin.org/static/packages_pgadmin_org.pub
  sh -c 'echo "deb [signed-by=/usr/share/keyrings/pgadmin-keyring.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(lsb_release -cs) pgadmin4 main" > /etc/apt/sources.list.d/pgadmin4.list'
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y pgadmin4-web
  /usr/pgadmin4/bin/setup-web.sh --yes
  # Bind Apache solo en localhost:PGADMIN_LISTEN_PORT
  if [ -f /etc/apache2/ports.conf ]; then
    sed -i "s/^\s*Listen .*/Listen 127.0.0.1:${PGADMIN_LISTEN_PORT}/g" /etc/apache2/ports.conf
    grep -q "Listen 127.0.0.1:${PGADMIN_LISTEN_PORT}" /etc/apache2/ports.conf || echo "Listen 127.0.0.1:${PGADMIN_LISTEN_PORT}" >> /etc/apache2/ports.conf
  fi
  if [ -f /etc/apache2/sites-available/pgadmin4.conf ]; then
    sed -i "s#<VirtualHost \*:80>#<VirtualHost 127.0.0.1:${PGADMIN_LISTEN_PORT}>#g" /etc/apache2/sites-available/pgadmin4.conf
  fi
  systemctl restart apache2
fi

#--------------------------------------------------
# Traefik
#--------------------------------------------------
if [ "$INSTALL_TRAEFIK" = "True" ]; then
  apt-get update -y
  apt-get install -y traefik
  mkdir -p /etc/traefik/dynamic
  mkdir -p /var/lib/traefik
  touch /var/lib/traefik/acme.json
  chmod 600 /var/lib/traefik/acme.json

  cat >/etc/traefik/traefik.yml <<'EOF'
entryPoints:
  web: { address: ":80" }
  websecure: { address: ":443" }

api: { dashboard: false }

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

serversTransport:
  forwardingTimeouts:
    idleTimeout: "900s"
    responseHeaderTimeout: "900s"

log: { level: INFO }
accessLog: {}
EOF

  # Dynamic: Odoo + dashboards
  cat >/etc/traefik/dynamic/odoo.yml <<'EOF'
http:
  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true
    secure-headers:
      headers:
        frameDeny: false
        customRequestHeaders:
          X-Forwarded-Host: "${host}"
          X-Forwarded-Proto: "${scheme}"
          X-Real-IP: "${remoteAddr}"
        customResponseHeaders:
          X-Frame-Options: "SAMEORIGIN"
          X-XSS-Protection: "1; mode=block"
    pghero-allow:
      ipAllowList:
        sourceRange: [PGHERO_IPS_PLACEHOLDER]
    pgadmin-allow:
      ipAllowList:
        sourceRange: [PGADMIN_IPS_PLACEHOLDER]
    pghero-auth:
      basicAuth:
        users:
          - "PGHERO_AUTH_PLACEHOLDER"
    pgadmin-auth:
      basicAuth:
        users:
          - "PGADMIN_AUTH_PLACEHOLDER"

  routers:
    odoo-redirect:
      rule: "Host(`WEBSITE_NAME_PLACEHOLDER`)"
      entryPoints: ["web"]
      service: odoo-svc
      middlewares: ["redirect-to-https"]

    odoo-websecure:
      rule: "Host(`WEBSITE_NAME_PLACEHOLDER`) && PathPrefix(`/`)"
      entryPoints: ["websecure"]
      service: odoo-svc
      middlewares: ["secure-headers"]
      tls: { certResolver: letsencrypt }

    odoo-longpolling:
      rule: "Host(`WEBSITE_NAME_PLACEHOLDER`) && PathPrefix(`/longpolling`)"
      entryPoints: ["websecure"]
      service: odoo-longpolling-svc
      middlewares: ["secure-headers"]
      tls: { certResolver: letsencrypt }

    pghero:
      rule: "Host(`PGHERO_SUBDOMAIN_PLACEHOLDER`)"
      entryPoints: ["websecure"]
      service: pghero-svc
      middlewares: ["secure-headers", "pghero-auth"]
      tls: { certResolver: letsencrypt }

    pgadmin:
      rule: "Host(`PGADMIN_SUBDOMAIN_PLACEHOLDER`)"
      entryPoints: ["websecure"]
      service: pgadmin-svc
      middlewares: ["secure-headers", "pgadmin-auth"]
      tls: { certResolver: letsencrypt }

  services:
    odoo-svc:
      loadBalancer:
        servers: [ { url: "http://127.0.0.1:OE_PORT_PLACEHOLDER" } ]
        passHostHeader: true
    odoo-longpolling-svc:
      loadBalancer:
        servers: [ { url: "http://127.0.0.1:LONGPOLL_PLACEHOLDER" } ]
        passHostHeader: true
    pghero-svc:
      loadBalancer:
        servers: [ { url: "http://127.0.0.1:PGHERO_PORT_PLACEHOLDER" } ]
        passHostHeader: true
    pgadmin-svc:
      loadBalancer:
        servers: [ { url: "http://127.0.0.1:PGADMIN_PORT_PLACEHOLDER" } ]
        passHostHeader: true
EOF

  # Replace placeholders
  sed -i "s|WEBSITE_NAME_PLACEHOLDER|${WEBSITE_NAME}|g" /etc/traefik/dynamic/odoo.yml
  sed -i "s|OE_PORT_PLACEHOLDER|${OE_PORT}|g" /etc/traefik/dynamic/odoo.yml
  sed -i "s|LONGPOLL_PLACEHOLDER|${LONGPOLLING_PORT}|g" /etc/traefik/dynamic/odoo.yml
  sed -i "s|PGHERO_SUBDOMAIN_PLACEHOLDER|${PGHERO_SUBDOMAIN}|g" /etc/traefik/dynamic/odoo.yml
  sed -i "s|PGADMIN_SUBDOMAIN_PLACEHOLDER|${PGADMIN_SUBDOMAIN}|g" /etc/traefik/dynamic/odoo.yml
  sed -i "s|PGHERO_PORT_PLACEHOLDER|${PGHERO_LISTEN_PORT}|g" /etc/traefik/dynamic/odoo.yml
  sed -i "s|PGADMIN_PORT_PLACEHOLDER|${PGADMIN_LISTEN_PORT}|g" /etc/traefik/dynamic/odoo.yml

  # Basic auth hashes
  PGHERO_HTPASS=$(openssl passwd -apr1 "${PGHERO_BASIC_AUTH_PASS}")
  PGADMIN_HTPASS=$(openssl passwd -apr1 "${PGADMIN_BASIC_AUTH_PASS}")
  sed -i "s|PGHERO_AUTH_PLACEHOLDER|${PGHERO_BASIC_AUTH_USER}:${PGHERO_HTPASS}|g" /etc/traefik/dynamic/odoo.yml
  sed -i "s|PGADMIN_AUTH_PLACEHOLDER|${PGADMIN_BASIC_AUTH_USER}:${PGADMIN_HTPASS}|g" /etc/traefik/dynamic/odoo.yml

  # IP allowlists
  if [ -n "$PGHERO_IP_ALLOWLIST" ]; then
    PGHERO_IPS=$(echo "$PGHERO_IP_ALLOWLIST" | sed 's/,/\", \"/g')
    sed -i "s|PGHERO_IPS_PLACEHOLDER|\"${PGHERO_IPS}\"|g" /etc/traefik/dynamic/odoo.yml
  else
    sed -i "s|PGHERO_IPS_PLACEHOLDER||g" /etc/traefik/dynamic/odoo.yml
  fi
  if [ -n "$PGADMIN_IP_ALLOWLIST" ]; then
    PGADMIN_IPS=$(echo "$PGADMIN_IP_ALLOWLIST" | sed 's/,/\", \"/g')
    sed -i "s|PGADMIN_IPS_PLACEHOLDER|\"${PGADMIN_IPS}\"|g" /etc/traefik/dynamic/odoo.yml
  else
    sed -i "s|PGADMIN_IPS_PLACEHOLDER||g" /etc/traefik/dynamic/odoo.yml
  fi

  # ACME
  if [ "$ENABLE_SSL" = "True" ] && [ "$ADMIN_EMAIL" != "odoo@example.com" ] && [ "$WEBSITE_NAME" != "_" ]; then
    cat >>/etc/traefik/traefik.yml <<EOF
certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ADMIN_EMAIL}"
      storage: "/var/lib/traefik/acme.json"
      httpChallenge: { entryPoint: web }
EOF
  fi

  # Systemd override para YAML
  mkdir -p /etc/systemd/system/traefik.service.d
  cat >/etc/systemd/system/traefik.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/traefik --configFile=/etc/traefik/traefik.yml
EOF
  systemctl daemon-reload
  systemctl enable traefik
  systemctl restart traefik

  # proxy_mode en Odoo
  grep -q '^proxy_mode' /etc/${OE_CONFIG}.conf || printf 'proxy_mode = True\n' >> /etc/${OE_CONFIG}.conf
fi

echo "---- Start Odoo ----"
/etc/init.d/$OE_CONFIG start || true

echo "-----------------------------------------------------------"
echo "Done! The Odoo server is up and running. Specifications:"
echo "Port: $OE_PORT"
echo "User service: $OE_USER"
echo "Configuraton file location: /etc/${OE_CONFIG}.conf"
echo "Logfile location: /var/log/$OE_USER"
echo "User PostgreSQL: $OE_USER"
echo "Code location: $OE_HOME_EXT"
echo "Addons folder: $OE_HOME_EXT/addons, $OE_HOME/custom/addons"
echo "Password superadmin (database): $OE_SUPERADMIN"
echo "Traefik main config: /etc/traefik/traefik.yml"
echo "Traefik dynamic config: /etc/traefik/dynamic/odoo.yml"
echo "ACME storage: /var/lib/traefik/acme.json"
echo "-----------------------------------------------------------"
