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

##  WKHTMLTOPDF download links
if [[ $(lsb_release -r -s) == "24.04" ]]; then
    WKHTMLTOX_X64="https://packages.ubuntu.com/noble/wkhtmltopdf"
    WKHTMLTOX_X32="https://packages.ubuntu.com/noble/wkhtmltopdf"
else
    WKHTMLTOX_X64="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_amd64.deb"
    WKHTMLTOX_X32="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_i386.deb"
fi

echo -e "\n---- Update Server ----"
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y libpq-dev curl wget ca-certificates gnupg lsb-release

echo -e "\n---- Install PostgreSQL Server ----"
if [ "$INSTALL_POSTGRESQL_SIXTEEN" = "True" ]; then
    echo -e "\n---- Installing postgreSQL V16 from PGDG ----"
    sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    sudo apt-get update -y
    sudo apt-get install -y postgresql-16 postgresql-client-16 postgresql-contrib-16 postgresql-16-pgvector
else
    echo -e "\n---- Installing the default postgreSQL version based on Linux version ----"
    sudo apt-get install -y postgresql postgresql-server-dev-all postgresql-16-pgvector || sudo apt-get install -y postgresql postgresql-server-dev-all
fi

echo -e "\n---- Creating the ODOO PostgreSQL User ----"
sudo su - postgres -c "createuser -s $OE_USER" 2> /dev/null || true

echo -e "\n--- Installing Python 3 + pip3 ---"
sudo apt-get install -y python3 python3-pip python3-venv python3-dev python3-wheel

echo -e "\n--- Installing build & libs ---"
sudo apt-get install -y git python3-google-auth python3-paramiko python3-cffi build-essential wget \
  libxslt-dev libzip-dev libldap2-dev libsasl2-dev python3-setuptools node-less libpng-dev libjpeg-dev gdebi-core

echo -e "\n---- Installing nodeJS NPM and rtlcss ----"
sudo apt-get install -y nodejs npm
sudo npm install -g rtlcss || true

echo -e "\n---- Create ODOO system user ----"
if ! id "$OE_USER" >/dev/null 2>&1; then
  sudo adduser --system --quiet --shell=/bin/bash --home="$OE_HOME" --gecos 'ODOO' --group "$OE_USER"
  sudo adduser "$OE_USER" sudo
fi

echo -e "\n---- Create directories & Log directory ----"
sudo mkdir -p "$OE_HOME_EXT" "$OE_HOME/custom/addons" "/var/log/$OE_USER"
sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME" "/var/log/$OE_USER"

#--------------------------------------------------
# Detect branch and clone ODOO
#--------------------------------------------------
REPO_URL="https://github.com/odoo/odoo"
GIT_BRANCH="$(detect_branch "$REPO_URL" "$OE_VERSION")"

echo -e "\n==== Installing ODOO Server (branch: $GIT_BRANCH) ===="
if [ ! -d "$OE_HOME_EXT/.git" ]; then
  sudo git clone --depth 1 --branch "$GIT_BRANCH" https://www.github.com/odoo/odoo "$OE_HOME_EXT/"
else
  sudo git -C "$OE_HOME_EXT" fetch --depth 1 origin "$GIT_BRANCH" || true
  sudo git -C "$OE_HOME_EXT" checkout "$GIT_BRANCH"
  sudo git -C "$OE_HOME_EXT" pull --ff-only || true
fi

# Clone design-themes in a separate folder
if [ ! -d "$OE_HOME/design-themes/.git" ]; then
  sudo git clone --depth 1 --branch "$GIT_BRANCH" https://www.github.com/odoo/design-themes "$OE_HOME/design-themes" || true
  sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME/design-themes" || true
fi

sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT"

echo -e "\n---- Create Python virtualenv ----"
sudo -u "$OE_USER" "$PYTHON_BIN" -m venv "$VENV_DIR"
sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel

echo -e "\n---- Install python packages/requirements (into venv) ----"
sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install --no-cache-dir -r "https://raw.githubusercontent.com/odoo/odoo/${GIT_BRANCH}/requirements.txt"

#--------------------------------------------------
# Enterprise (optional)
#--------------------------------------------------
if [ "$IS_ENTERPRISE" = "True" ]; then
    echo -e "\n---- Odoo Enterprise install ----"
    sudo ln -sf /usr/bin/nodejs /usr/bin/node || true
    sudo su "$OE_USER" -c "mkdir -p $OE_HOME/enterprise/addons"

    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch "$GIT_BRANCH" "https://${GITHUB_ENTERPRISE_USER}:${GITHUB_ENTERPRISE_TOKEN}@github.com/odoo/enterprise" "$OE_HOME/enterprise/addons" 2>&1)
    while [[ "$GITHUB_RESPONSE" == *"Authentication"* ]]; do
        echo "------------------------WARNING------------------------------"
        echo "Your authentication with Github has failed! Please try again."
        printf "In order to clone and install the Odoo enterprise version you \nneed to be an offical Odoo partner and you need access to\nhttp://github.com/odoo/enterprise.\n"
        echo "TIP: Press ctrl+c to stop this script."
        echo "-------------------------------------------------------------"
        echo "$GITHUB_ENTERPRISE_TOKEN"
        GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch "$GIT_BRANCH" "https://${GITHUB_ENTERPRISE_USER}:${GITHUB_ENTERPRISE_TOKEN}@github.com/odoo/enterprise" "$OE_HOME/enterprise/addons" 2>&1)
    done

    echo -e "\n---- Installing Enterprise specific libraries into venv ----"
    sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install psycopg2-binary pdfminer.six
    sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
    sudo npm install -g less || true
    sudo npm install -g less-plugin-clean-css || true
fi

#--------------------------------------------------
# Install Wkhtmltopdf if needed
#--------------------------------------------------
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
  echo -e "\n---- Install wkhtmltopdf / paper-muncher ----"
  if [ "`getconf LONG_BIT`" == "64" ]; then
      _url=$WKHTMLTOX_X64
  else
      _url=$WKHTMLTOX_X32
  fi

  if [[ $(lsb_release -r -s) == "24.04" ]]; then
    sudo apt-get install -y wkhtmltopdf
    wget -q https://github.com/odoo/paper-muncher/releases/download/nightly/paper-muncher_nightly_noble_amd64.deb -O /tmp/paper-muncher.deb
    sudo apt-get install -y /tmp/paper-muncher.deb || sudo dpkg -i /tmp/paper-muncher.deb
    sudo ln -sf /opt/paper-muncher/bin/paper-muncher /usr/bin/paper-muncher
    paper-muncher --version || true
  else
    sudo wget -q "$_url" -O /tmp/wkhtmltox.deb
    sudo gdebi --non-interactive /tmp/wkhtmltox.deb || sudo apt-get install -y /tmp/wkhtmltox.deb || true
    sudo ln -sf /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf || true
    sudo ln -sf /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage || true
  fi
else
  echo "Wkhtmltopdf isn't installed due to the choice of the user!"
fi

echo -e "\n---- Setting permissions on home folder ----"
sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME"/*

echo -e "* Create server config file"
sudo touch /etc/${OE_CONFIG}.conf
echo -e "* Creating server config file"
sudo su root -c "printf '[options]\n; This is the password that allows database operations:\n' > /etc/${OE_CONFIG}.conf"
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    echo -e "* Generating random admin password"
    OE_SUPERADMIN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
fi
sudo su root -c "printf 'admin_passwd = ${OE_SUPERADMIN}\n' >> /etc/${OE_CONFIG}.conf"
sudo su root -c "printf 'http_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
sudo su root -c "printf 'longpolling_port = ${LONGPOLLING_PORT}\n' >> /etc/${OE_CONFIG}.conf"
sudo su root -c "printf 'logfile = /var/log/${OE_USER}/${OE_CONFIG}.log\n' >> /etc/${OE_CONFIG}.conf"

# addons_path: incluye design-themes si existe
if [ "$IS_ENTERPRISE" = "True" ]; then
    if [ -d "$OE_HOME/design-themes" ]; then
      sudo su root -c "printf 'addons_path=${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons,${OE_HOME}/design-themes\n' >> /etc/${OE_CONFIG}.conf"
    else
      sudo su root -c "printf 'addons_path=${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons\n' >> /etc/${OE_CONFIG}.conf"
    fi
else
    if [ -d "$OE_HOME/design-themes" ]; then
      sudo su root -c "printf 'addons_path=${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons,${OE_HOME}/design-themes\n' >> /etc/${OE_CONFIG}.conf"
    else
      sudo su root -c "printf 'addons_path=${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons\n' >> /etc/${OE_CONFIG}.conf"
    fi
fi
sudo chown "$OE_USER:$OE_USER" /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

echo -e "* Create startup file"
sudo bash -c "cat > $OE_HOME_EXT/start.sh" <<EOF
#!/bin/sh
export PATH="$VENV_DIR/bin:\$PATH"
sudo -u $OE_USER $OE_HOME_EXT/odoo-bin --config=/etc/${OE_CONFIG}.conf
EOF
sudo chmod 755 "$OE_HOME_EXT/start.sh"

#--------------------------------------------------
# Adding ODOO as a daemon (init.d)
#--------------------------------------------------
echo -e "* Create init file"
cat <<EOF > ~/$OE_CONFIG
#!/bin/sh
### BEGIN INIT INFO
# Provides: $OE_CONFIG
# Required-Start: \$remote_fs \$syslog
# Required-Stop: \$remote_fs \$syslog
# Should-Start: \$network
# Should-Stop: \$network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Enterprise Business Applications
# Description: ODOO Business Applications
### END INIT INFO
PATH=$VENV_DIR/bin:/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
DAEMON=$OE_HOME_EXT/odoo-bin
NAME=$OE_CONFIG
DESC=$OE_CONFIG
USER=$OE_USER
CONFIGFILE="/etc/${OE_CONFIG}.conf"
PIDFILE=/var/run/\${NAME}.pid
DAEMON_OPTS="-c \$CONFIGFILE"
[ -x \$DAEMON ] || exit 0
[ -f \$CONFIGFILE ] || exit 0
checkpid() {
  [ -f \$PIDFILE ] || return 1
  pid=\`cat \$PIDFILE\`
  [ -d /proc/\$pid ] && return 0
  return 1
}
case "\${1}" in
start)
  echo -n "Starting \${DESC}: "
  start-stop-daemon --start --quiet --pidfile \$PIDFILE \
  --chuid \$USER --background --make-pidfile \
  --exec \$DAEMON -- \$DAEMON_OPTS
  echo "\${NAME}."
  ;;
stop)
  echo -n "Stopping \${DESC}: "
  start-stop-daemon --stop --quiet --pidfile \$PIDFILE --oknodo
  echo "\${NAME}."
  ;;
restart|force-reload)
  echo -n "Restarting \${DESC}: "
  start-stop-daemon --stop --quiet --pidfile \$PIDFILE --oknodo
  sleep 1
  start-stop-daemon --start --quiet --pidfile \$PIDFILE \
  --chuid \$USER --background --make-pidfile \
  --exec \$DAEMON -- \$DAEMON_OPTS
  echo "\${NAME}."
  ;;
*)
  N=/etc/init.d/\$NAME
  echo "Usage: \$NAME {start|stop|restart|force-reload}" >&2
  exit 1
  ;;
esac
exit 0
EOF

echo -e "* Security Init File"
sudo mv ~/$OE_CONFIG /etc/init.d/$OE_CONFIG
sudo chmod 755 /etc/init.d/$OE_CONFIG
sudo chown root: /etc/init.d/$OE_CONFIG

echo -e "* Start ODOO on Startup"
sudo update-rc.d $OE_CONFIG defaults

#--------------------------------------------------
# Install Traefik (Community) as reverse proxy
#--------------------------------------------------
if [ "$INSTALL_TRAEFIK" = "True" ]; then
  echo -e "\n---- Installing and setting up Traefik ----"
  # Install from Ubuntu repositories
  sudo apt-get update -y
  sudo apt-get install -y traefik

  # Create config directories
  sudo mkdir -p /etc/traefik/dynamic
  sudo mkdir -p /var/lib/traefik
  sudo touch /var/lib/traefik/acme.json
  sudo chmod 600 /var/lib/traefik/acme.json

  # Static configuration (YAML)
  sudo bash -c 'cat > /etc/traefik/traefik.yml' <<'EOF'
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

api:
  dashboard: false

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

# Increase timeouts for Odoo long requests
serversTransport:
  forwardingTimeouts:
    idleTimeout: "900s"
    responseHeaderTimeout: "900s"

# Access / error logs
log:
  level: INFO
accessLog: {}
EOF

  # Dynamic configuration: routers/services/middlewares for Odoo
  sudo bash -c "cat > /etc/traefik/dynamic/odoo.yml" <<EOF
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
          X-Forwarded-Host: "\${host}"
          X-Forwarded-Proto: "\${scheme}"
          X-Real-IP: "\${remoteAddr}"
        customResponseHeaders:
          X-Frame-Options: "SAMEORIGIN"
          X-XSS-Protection: "1; mode=block"

  routers:
    odoo-redirect:
      rule: "Host(\`${WEBSITE_NAME}\`)"
      entryPoints: ["web"]
      service: odoo-svc
      middlewares: ["redirect-to-https"]
$( [ "$ENABLE_SSL" = "True" ] && [ "$ADMIN_EMAIL" != "odoo@example.com" ] && [ "$WEBSITE_NAME" != "_" ] && cat <<'EOT'
    odoo-websecure:
      rule: "Host(`WEBSITE_NAME_PLACEHOLDER`) && PathPrefix(`/`)"
      entryPoints: ["websecure"]
      service: odoo-svc
      middlewares: ["secure-headers"]
      tls:
        certResolver: letsencrypt
    odoo-longpolling:
      rule: "Host(`WEBSITE_NAME_PLACEHOLDER`) && PathPrefix(`/longpolling`)"
      entryPoints: ["websecure"]
      service: odoo-longpolling-svc
      middlewares: ["secure-headers"]
      tls:
        certResolver: letsencrypt
EOT
)

  services:
    odoo-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${OE_PORT}"
        passHostHeader: true
    odoo-longpolling-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${LONGPOLLING_PORT}"
        passHostHeader: true
EOF

  # Replace placeholder with actual hostname safely
  sudo sed -i "s|WEBSITE_NAME_PLACEHOLDER|${WEBSITE_NAME}|g" /etc/traefik/dynamic/odoo.yml

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
