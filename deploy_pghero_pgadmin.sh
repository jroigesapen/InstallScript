#!/usr/bin/env bash
set -euo pipefail

#############################################
# ============ VARIABLES ================== #
#############################################

PGHERO_DOMAIN="pghero.domain.dom"
PGADMIN_DOMAIN="pgadmin.domain.dom"

ENABLE_SSL=true
LETSENCRYPT_EMAIL="admin@example.com"

BASIC_AUTH_USER="admin"
BASIC_AUTH_PASS="admin"

PGHERO_IP_ALLOWLIST=()        # ej: ("203.0.113.10/32" "198.51.100.0/24")
PGADMIN_IP_ALLOWLIST=()       # ej: ("203.0.113.10/32")

PG_LISTEN_HOST="127.0.0.1"
PG_PORT="5432"

PGHERO_LISTEN_PORT="8081"
PGHERO_DB_NAME="postgres"
PGHERO_DB_USER="pghero_user"
PGHERO_DB_PASSWORD=""

PGADMIN_LISTEN_PORT="8082"
PGADMIN_ADMIN_EMAIL="admin@ejemplo.com"
PGADMIN_ADMIN_PASSWORD="admin123"

TRAEFIK_VERSION="${TRAEFIK_VERSION:-v2.11.2}"

export DEBIAN_FRONTEND=noninteractive

#############################################
# ============== HELPERS ================== #
#############################################
log(){ printf "\n\033[1;32m%s\033[0m\n" "---- $* ----"; }
need(){ command -v "$1" >/dev/null 2>&1; }
join_by(){ local IFS="$1"; shift; echo "$*"; }
gen_pw(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }
detect_pg_major(){ psql -V | awk '{print $3}' | cut -d. -f1; }

pause_auto_apt() {
  systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl mask unattended-upgrades apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  for _ in {1..120}; do
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       && ! pgrep -x dpkg >/dev/null && ! pgrep -x apt >/dev/null \
       && ! pgrep -f apt.systemd.daily >/dev/null \
       && ! pgrep -f unattended-upgrade >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "Hay procesos APT activos; reintenta luego." >&2
}

resume_auto_apt() {
  systemctl unmask unattended-upgrades apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl start apt-daily.timer apt-daily-upgrade.timer unattended-upgrades 2>/dev/null || true
}

#############################################
# =========== PAQUETES BASE =============== #
#############################################
log "Actualizando sistema y paquetes base"
pause_auto_apt
apt-get update -y
apt-get -y -o Dpkg::Options::=--force-confnew full-upgrade
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg lsb-release jq \
  apache2 libapache2-mod-wsgi-py3 apache2-utils \
  postgresql
resume_auto_apt

#############################################
# ============= POSTGRESQL ================ #
#############################################
log "Configurando PostgreSQL + pg_stat_statements"
PGV="$(detect_pg_major)"
PG_ETC="/etc/postgresql/${PGV}/main"
PG_CONF="${PG_ETC}/postgresql.conf"

if grep -qE '^\s*#?\s*shared_preload_libraries' "$PG_CONF"; then
  sed -i "s|^\s*#\?\s*shared_preload_libraries.*|shared_preload_libraries = 'pg_stat_statements'|g" "$PG_CONF"
else
  echo "shared_preload_libraries = 'pg_stat_statements'" >> "$PG_CONF"
fi
sed -i "s|^\s*#\?\s*listen_addresses.*|listen_addresses = '${PG_LISTEN_HOST}'|g" "$PG_CONF"
sed -i "s|^\s*#\?\s*port\s*=.*|port = ${PG_PORT}|g" "$PG_CONF"
systemctl restart postgresql

[[ -z "$PGHERO_DB_PASSWORD" ]] && PGHERO_DB_PASSWORD="$(gen_pw)" && echo "PGHERO_DB_PASSWORD=${PGHERO_DB_PASSWORD}"
sudo -u postgres psql -X -A -tqc "CREATE USER ${PGHERO_DB_USER} WITH PASSWORD '${PGHERO_DB_PASSWORD}' LOGIN;" || true
sudo -u postgres psql -X -A -tqc "ALTER USER ${PGHERO_DB_USER} SET search_path TO public;" || true
sudo -u postgres psql -X -A -tqc "GRANT CONNECT ON DATABASE ${PGHERO_DB_NAME} TO ${PGHERO_DB_USER};" || true
sudo -u postgres psql -X -A -tqc "GRANT pg_read_all_stats TO ${PGHERO_DB_USER};" || true
sudo -u postgres psql -X -A -tqc "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" -d "${PGHERO_DB_NAME}"
sudo -u postgres psql -X -A -tqc "GRANT USAGE ON SCHEMA public TO ${PGHERO_DB_USER};" -d "${PGHERO_DB_NAME}" || true
sudo -u postgres psql -X -A -tqc "GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${PGHERO_DB_USER};" -d "${PGHERO_DB_NAME}" || true

#############################################
# ================= PGHERO ================ #
#############################################
log "Instalando PgHero (APT con keyring moderno)"
pause_auto_apt
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://dl.packager.io/srv/pghero/pghero/key | gpg --dearmor -o /usr/share/keyrings/pghero.gpg
. /etc/os-release
UBU_VER="22.04"; [[ "$VERSION_CODENAME" = "noble" ]] && UBU_VER="24.04"
echo "deb [signed-by=/usr/share/keyrings/pghero.gpg] https://dl.packager.io/srv/deb/pghero/pghero/master/ubuntu ${UBU_VER} main" > /etc/apt/sources.list.d/pghero.list
apt-get update -y
apt-get install -y --no-install-recommends pghero
resume_auto_apt

export DATABASE_URL="postgres://${PGHERO_DB_USER}:${PGHERO_DB_PASSWORD}@${PG_LISTEN_HOST}:${PG_PORT}/${PGHERO_DB_NAME}"
pghero config:set DATABASE_URL="${DATABASE_URL}"
pghero config:set PORT="${PGHERO_LISTEN_PORT}"
pghero config:set RAILS_LOG_TO_STDOUT=disabled || true
pghero scale web=1
systemctl enable pghero
systemctl restart pghero

#############################################
# ================= PGADMIN =============== #
#############################################
log "Instalando pgAdmin 4 (APT) + Apache en 127.0.0.1:${PGADMIN_LISTEN_PORT}"
pause_auto_apt
curl -fsS https://www.pgadmin.org/static/packages_pgadmin_org.pub | gpg --dearmor -o /usr/share/keyrings/pgadmin.gpg
echo "deb [signed-by=/usr/share/keyrings/pgadmin.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(lsb_release -cs) pgadmin4 main" > /etc/apt/sources.list.d/pgadmin4.list
apt-get update -y
apt-get install -y --no-install-recommends pgadmin4-web
resume_auto_apt

PGADMIN_SETUP_EMAIL="${PGADMIN_ADMIN_EMAIL}" PGADMIN_SETUP_PASSWORD="${PGADMIN_ADMIN_PASSWORD}" /usr/pgadmin4/bin/setup-web.sh --yes || true

printf "ServerName localhost\n" > /etc/apache2/conf-available/servername.conf
a2enconf servername >/dev/null 2>&1 || true
sed -i "s|^Listen .*|Listen 127.0.0.1:${PGADMIN_LISTEN_PORT}|" /etc/apache2/ports.conf

cat >/etc/apache2/sites-available/pgadmin4-local.conf <<EOF
<VirtualHost 127.0.0.1:${PGADMIN_LISTEN_PORT}>
  ServerName localhost
  ErrorLog \${APACHE_LOG_DIR}/pgadmin4_error.log
  CustomLog \${APACHE_LOG_DIR}/pgadmin4_access.log combined
</VirtualHost>
EOF

a2dissite 000-default.conf default-ssl.conf >/dev/null 2>&1 || true
a2ensite pgadmin4-local.conf >/dev/null 2>&1 || true

a2disconf pgadmin4 >/dev/null 2>&1 || true
rm -f /etc/apache2/conf-enabled/pgadmin4.conf* 2>/dev/null || true
a2enconf pgadmin4 >/dev/null 2>&1 || true

a2enmod headers proxy proxy_http wsgi >/dev/null 2>&1 || true
apache2ctl -t
systemctl restart apache2

#############################################
# =============== TRAEFIK ================= #
#############################################
log "Instalando/Preparando Traefik"
if ! need traefik; then
  pause_auto_apt
  apt-get update -y || true
  apt-get install -y --no-install-recommends software-properties-common || true
  add-apt-repository -y universe || true
  apt-get update -y || true
  if ! apt-get install -y --no-install-recommends traefik; then
    cd /tmp
    case "$(dpkg --print-architecture)" in
      amd64) ARCH="amd64" ;; arm64) ARCH="arm64" ;; *) echo "Arquitectura no soportada"; exit 1 ;;
    esac
    TARBALL="traefik_${TRAEFIK_VERSION}_linux_${ARCH}.tar.gz"
    URL="https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/${TARBALL}"
    curl -fSLO "${URL}"
    tar -xzf "${TARBALL}" traefik
    install -m 0755 traefik /usr/local/bin/traefik
    setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/traefik || true
    cat >/etc/systemd/system/traefik.service <<'EOF'
[Unit]
Description=Traefik Proxy (binary install)
After=network-online.target
Wants=network-online.target
[Service]
Type=notify
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
  resume_auto_apt
fi

install -d -m 0755 /etc/traefik/dynamic
install -d -m 0700 /etc/traefik/htpasswd
install -d -m 0700 /var/lib/traefik
touch /var/lib/traefik/acme.json && chmod 600 /var/lib/traefik/acme.json

# BasicAuth
HASHED="$(htpasswd -nbB "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}" | sed 's/^'"${BASIC_AUTH_USER}"'://')"
echo "${BASIC_AUTH_USER}:${HASHED}" > /etc/traefik/htpasswd/admin

# traefik.yml
cat >/etc/traefik/traefik.yml <<YAML
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
providers:
  file:
    directory: "/etc/traefik/dynamic"
    watch: true
log:
  level: INFO
accessLog: {}
YAML

if [[ "${ENABLE_SSL}" == "true" ]]; then
  cat >>/etc/traefik/traefik.yml <<YAML
certificatesResolvers:
  letsencrypt:
    acme:
      email: "${LETSENCRYPT_EMAIL}"
      storage: /var/lib/traefik/acme.json
      httpChallenge:
        entryPoint: web
YAML
fi

# Allowlist → YAML
join_by(){ local IFS="$1"; shift; echo "$*"; }
PGHERO_RANGES=""; [[ ${#PGHERO_IP_ALLOWLIST[@]} -gt 0 ]] && PGHERO_RANGES="\"$(join_by '","' "${PGHERO_IP_ALLOWLIST[@]}")\""
PGADMIN_RANGES=""; [[ ${#PGADMIN_IP_ALLOWLIST[@]} -gt 0 ]] && PGADMIN_RANGES="\"$(join_by '","' "${PGADMIN_IP_ALLOWLIST[@]}")\""

# Middlewares YAML safe + redirección raíz de pgadmin
PGHERO_MW_BLOCK=$'- basic-auth'
[[ -n "$PGHERO_RANGES" ]] && PGHERO_MW_BLOCK=$'- basic-auth\n      - pghero-allow'

PGADMIN_MW_BLOCK=$'- basic-auth\n      - pgadmin-root'
[[ -n "$PGADMIN_RANGES" ]] && PGADMIN_MW_BLOCK=$'- basic-auth\n      - pgadmin-root\n      - pgadmin-allow'

# dynamic config
DYN="/etc/traefik/dynamic/pghero_pgadmin.yml"
cat > "$DYN" <<YAML
http:
  middlewares:
    basic-auth:
      basicAuth:
        usersFile: "/etc/traefik/htpasswd/admin"
    pgadmin-root:
      redirectRegex:
        regex: "^/$"
        replacement: "/pgadmin4"
        permanent: true
YAML

if [[ -n "$PGHERO_RANGES" ]]; then
  cat >> "$DYN" <<YAML
    pghero-allow:
      ipAllowList:
        sourceRange: [${PGHERO_RANGES}]
YAML
fi
if [[ -n "$PGADMIN_RANGES" ]]; then
  cat >> "$DYN" <<YAML
    pgadmin-allow:
      ipAllowList:
        sourceRange: [${PGADMIN_RANGES}]
YAML
fi

TLS_BLOCK=""
if [[ "${ENABLE_SSL}" == "true" ]]; then
  TLS_BLOCK=$'      tls:\n        certResolver: letsencrypt'
fi

cat >> "$DYN" <<YAML

  routers:
    pghero-http:
      rule: "Host(\`${PGHERO_DOMAIN}\`)"
      entryPoints: ["web"]
      middlewares:
      ${PGHERO_MW_BLOCK}
      service: pghero-svc
    pghero-https:
      rule: "Host(\`${PGHERO_DOMAIN}\`)"
      entryPoints: ["websecure"]
      middlewares:
      ${PGHERO_MW_BLOCK}
${TLS_BLOCK}
      service: pghero-svc

    pgadmin-http:
      rule: "Host(\`${PGADMIN_DOMAIN}\`)"
      entryPoints: ["web"]
      middlewares:
      ${PGADMIN_MW_BLOCK}
      service: pgadmin-svc
    pgadmin-https:
      rule: "Host(\`${PGADMIN_DOMAIN}\`)"
      entryPoints: ["websecure"]
      middlewares:
      ${PGADMIN_MW_BLOCK}
${TLS_BLOCK}
      service: pgadmin-svc

  services:
    pghero-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${PGHERO_LISTEN_PORT}"
    pgadmin-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${PGADMIN_LISTEN_PORT}"
YAML

systemctl enable traefik
systemctl restart traefik

#############################################
# ================ TESTS ================== #
#############################################
log "Pruebas rápidas (HTTP con --resolve a loopback)"
set +e
curl -sI --resolve "${PGHERO_DOMAIN}:80:127.0.0.1"  "http://${PGHERO_DOMAIN}/"          | head -n1
curl -sI --resolve "${PGADMIN_DOMAIN}:80:127.0.0.1" "http://${PGADMIN_DOMAIN}/"        | head -n1
curl -sI --resolve "${PGADMIN_DOMAIN}:80:127.0.0.1" "http://${PGADMIN_DOMAIN}/pgadmin4"| head -n1
set -e

#############################################
# ================== INFO ================= #
#############################################
log "Resumen"
echo "PostgreSQL        : ${PG_LISTEN_HOST}:${PG_PORT}"
echo "PgHero local      : http://127.0.0.1:${PGHERO_LISTEN_PORT}"
echo "pgAdmin local     : http://127.0.0.1:${PGADMIN_LISTEN_PORT}/pgadmin4/"
echo "PgHero dominio    : http://${PGHERO_DOMAIN}  (y https si ENABLE_SSL=true)"
echo "pgAdmin dominio   : http://${PGADMIN_DOMAIN}/  (redirige a /pgadmin4)  (y https si ENABLE_SSL=true)"
echo "BasicAuth (ambos) : ${BASIC_AUTH_USER} / ${BASIC_AUTH_PASS}"
echo "PgHero DB URL     : postgres://${PGHERO_DB_USER}:********@${PG_LISTEN_HOST}:${PG_PORT}/${PGHERO_DB_NAME}"
echo
echo "Abre puertos 80/443 en el firewall del servidor y del cloud."
echo "Errores Traefik → journalctl -u traefik -n 200 --no-pager"
