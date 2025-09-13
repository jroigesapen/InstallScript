#!/bin/bash
################################################################################
# Odoo install (Ubuntu 16.04/18.04/20.04/24.04) - Mod Traefik + sin PostgreSQL
# Basado en Yenthe Van Ginneken, adaptado para:
#  - NO instalar PostgreSQL (se asume ya instalado/gestionado)
#  - Sustituir Nginx+Certbot por Traefik (https, redirección http→https, ACME)
################################################################################

set -euo pipefail

OE_USER="odoo19"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"

INSTALL_WKHTMLTOPDF="True"
OE_PORT="8069"
OE_VERSION="19.0"
IS_ENTERPRISE="True"

# PostgreSQL: NO instalar
#INSTALL_POSTGRESQL_SIXTEEN="False"   # ← eliminado uso

INSTALL_NGINX="False"                 # ← forzamos a False (no usamos Nginx)

OE_SUPERADMIN="admin"
GENERATE_RANDOM_PASSWORD="False"
OE_CONFIG="${OE_USER}-server"

WEBSITE_NAME="_"                      # dominio FQDN (ej. odoo.midominio.com)
LONGPOLLING_PORT="8072"

ENABLE_SSL="True"                     # Si True, crea config para Traefik (https)
ADMIN_EMAIL="odoo@example.com"        # usa email real para ACME

# Enterprise login (si aplica)
GITHUB_ENTERPRISE_USER=""
GITHUB_ENTERPRISE_TOKEN=" "

# ---- Helpers ----
PYTHON_BIN="python3"
VENV_DIR="${OE_HOME_EXT}/venv"

detect_branch () {
  local repo="$1" want="$2"
  if git ls-remote --heads "$repo" "$want" | grep -q "$want"; then
    echo "$want"; return 0
  fi
  echo ">>> WARNING: Branch '$want' not found on $repo"
  if [[ "$want" =~ ^19(\.0)?$ ]]; then
    echo "master"
  else
    echo "18.0"
  fi
}

## WKHTMLTOPDF links
if [[ $(lsb_release -r -s) == "24.04" ]]; then
  WKHTMLTOX_X64="https://packages.ubuntu.com/noble/wkhtmltopdf"
  WKHTMLTOX_X32="https://packages.ubuntu.com/noble/wkhtmltopdf"
else
  WKHTMLTOX_X64="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_amd64.deb"
  WKHTMLTOX_X32="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_i386.deb"
fi

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n---- Update Server ----"
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y libpq-dev curl wget ca-certificates

#--------------------------------------------------
# PostgreSQL (NO instalar) - solo crear usuario si ya existe el servidor
#--------------------------------------------------
echo -e "\n---- PostgreSQL: NO se instala. Se asume ya disponible en el sistema ----"
echo -e "\n---- Creando el usuario de BD para Odoo (si no existía) ----"
sudo su - postgres -c "createuser -s $OE_USER" 2> /dev/null || true

#--------------------------------------------------
# Dependencias
#--------------------------------------------------
echo -e "\n--- Installing Python 3 + pip3 --"
sudo apt-get install -y python3 python3-pip python3-venv python3-dev python3-wheel

echo -e "\n--- Installing build & libs --"
sudo apt-get install -y git python3-google-auth python3-paramiko python3-cffi build-essential wget \
  libxslt-dev libzip-dev libldap2-dev libsasl2-dev python3-setuptools node-less libpng-dev libjpeg-dev gdebi-core

echo -e "\n---- Installing nodeJS NPM and rtlcss ----"
sudo apt-get install -y nodejs npm
sudo npm install -g rtlcss || true

#--------------------------------------------------
# Usuario y directorios
#--------------------------------------------------
echo -e "\n---- Create ODOO system user ----"
if ! id "$OE_USER" >/dev/null 2>&1; then
  sudo adduser --system --quiet --shell=/bin/bash --home="$OE_HOME" --gecos 'ODOO' --group "$OE_USER"
  sudo adduser "$OE_USER" sudo
fi

echo -e "\n---- Create directories & Log directory ----"
sudo mkdir -p "$OE_HOME_EXT" "$OE_HOME/custom/addons" "/var/log/$OE_USER"
sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME" "/var/log/$OE_USER"

#--------------------------------------------------
# Clonado Odoo
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

# design-themes
if [ ! -d "$OE_HOME/design-themes/.git" ]; then
  sudo git clone --depth 1 --branch "$GIT_BRANCH" https://www.github.com/odoo/design-themes "$OE_HOME/design-themes" || true
  sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME/design-themes" || true
fi
sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT"

#--------------------------------------------------
# venv + requirements
#--------------------------------------------------
echo -e "\n---- Create Python virtualenv ----"
sudo -u "$OE_USER" "$PYTHON_BIN" -m venv "$VENV_DIR"
sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel

echo -e "\n---- Install python requirements (into venv) ----"
sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install --no-cache-dir -r "https://raw.githubusercontent.com/odoo/odoo/${GIT_BRANCH}/requirements.txt"

#--------------------------------------------------
# Enterprise (opcional)
#--------------------------------------------------
if [ "$IS_ENTERPRISE" = "True" ]; then
  echo -e "\n---- Odoo Enterprise install ----"
  sudo ln -sf /usr/bin/nodejs /usr/bin/node || true
  sudo su "$OE_USER" -c "mkdir -p $OE_HOME/enterprise/addons"

  GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch "$GIT_BRANCH" "https://${GITHUB_ENTERPRISE_USER}:${GITHUB_ENTERPRISE_TOKEN}@github.com/odoo/enterprise" "$OE_HOME/enterprise/addons" 2>&1)
  while [[ "$GITHUB_RESPONSE" == *"Authentication"* ]]; do
    echo "------------------------WARNING------------------------------"
    echo "Github auth failed. Retrying..."
    echo "-------------------------------------------------------------"
    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch "$GIT_BRANCH" "https://${GITHUB_ENTERPRISE_USER}:${GITHUB_ENTERPRISE_TOKEN}@github.com/odoo/enterprise" "$OE_HOME/enterprise/addons" 2>&1)
  done

  echo -e "\n---- Enterprise extra libs ----"
  sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install psycopg2-binary pdfminer.six
  sudo -u "$OE_USER" "$VENV_DIR/bin/pip" install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
  sudo npm install -g less || true
  sudo npm install -g less-plugin-clean-css || true
fi

#--------------------------------------------------
# Wkhtmltopdf / paper-muncher
#--------------------------------------------------
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
  echo -e "\n---- Install wkhtmltopdf / paper-muncher ----"
  if [ "`getconf LONG_BIT`" == "64" ]; then _url=$WKHTMLTOX_X64; else _url=$WKHTMLTOX_X32; fi
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
  echo "Wkhtmltopdf NOT installed by user choice."
fi

echo -e "\n---- Setting permissions on home folder ----"
sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME"/*

#--------------------------------------------------
# Config Odoo
#--------------------------------------------------
echo -e "* Create server config file"
sudo touch /etc/${OE_CONFIG}.conf
sudo su root -c "printf '[options]\n; This is the password that allows database operations:\n' > /etc/${OE_CONFIG}.conf"
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
  OE_SUPERADMIN=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
fi
sudo su root -c "printf 'admin_passwd = ${OE_SUPERADMIN}\n' >> /etc/${OE_CONFIG}.conf"
if [[ "$OE_VERSION" > "11.0" ]]; then
  sudo su root -c "printf 'http_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
else
  sudo su root -c "printf 'xmlrpc_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
fi
sudo su root -c "printf 'longpolling_port = ${LONGPOLLING_PORT}\n' >> /etc/${OE_CONFIG}.conf"
sudo su root -c "printf 'logfile = /var/log/${OE_USER}/${OE_CONFIG}.log\n' >> /etc/${OE_CONFIG}.conf"
# addons_path
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
# SIEMPRE en proxy (Traefik u otro)
sudo su root -c "printf 'proxy_mode = True\n' >> /etc/${OE_CONFIG}.conf"

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
# Servicio init.d (legacy pero funcional en Ubuntu)
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
# Traefik (HTTPS + redirección) en lugar de Nginx
#--------------------------------------------------
if [ "$ENABLE_SSL" = "True" ] && [ "$WEBSITE_NAME" != "_" ]; then
  echo -e "\n---- Configurando Traefik para Odoo (${WEBSITE_NAME}) ----"

  # Directorio dinámico de Traefik (usar conf.d si existe, si no dynamic)
  TRAEFIK_DYNAMIC_DIR="/etc/traefik/conf.d"
  if [ ! -d "$TRAEFIK_DYNAMIC_DIR" ]; then
    if [ -d "/etc/traefik/dynamic" ]; then
      TRAEFIK_DYNAMIC_DIR="/etc/traefik/dynamic"
    else
      sudo mkdir -p "$TRAEFIK_DYNAMIC_DIR"
    fi
  fi

  # Si el traefik.yml usa email example.com, cámbialo por ADMIN_EMAIL (solo si example.com)
  if [ "$ADMIN_EMAIL" != "odoo@example.com" ]; then
    if sudo grep -q "email:.*example.com" /etc/traefik/traefik.yml 2>/dev/null; then
      sudo sed -i -E "s/email:\s*[^#]*example\.com/email: ${ADMIN_EMAIL}/" /etc/traefik/traefik.yml || true
    fi
  fi

  # Asegurar almacenamiento ACME
  sudo install -d -m 700 /var/lib/traefik
  sudo touch /var/lib/traefik/acme.json
  sudo chmod 600 /var/lib/traefik/acme.json

  # Config dinámica para Odoo
  sudo tee "${TRAEFIK_DYNAMIC_DIR}/odoo.yml" >/dev/null <<YAML
http:
  routers:
    odoo-http:
      entryPoints: ["web"]
      rule: "Host(\`${WEBSITE_NAME}\`)"
      middlewares: ["redirect-to-https"]
      service: "odoo"
    odoo-https:
      entryPoints: ["websecure"]
      rule: "Host(\`${WEBSITE_NAME}\`)"
      service: "odoo"
      tls:
        certResolver: "letsencrypt"
    odoo-longpoll-https:
      entryPoints: ["websecure"]
      rule: "Host(\`${WEBSITE_NAME}\`) && PathPrefix(\`/longpolling\`)"
      service: "odoo-longpoll"
      tls:
        certResolver: "letsencrypt"

  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true

  services:
    odoo:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://127.0.0.1:${OE_PORT}"
    odoo-longpoll:
      loadBalancer:
        passHostHeader: true
        serversTransport: "odoo-transport"
        servers:
          - url: "http://127.0.0.1:${LONGPOLLING_PORT}"

  serversTransports:
    odoo-transport:
      forwardingTimeouts:
        responseHeaderTimeout: 3600s
        idleConnTimeout: 3600s
YAML

  # Reiniciar Traefik para aplicar cambios
  sudo systemctl restart traefik

  echo "Traefik configurado. Certificados se emitirán/renovarán automáticamente con el resolver 'letsencrypt'."
else
  echo "Traefik/HTTPS no configurado (ENABLE_SSL=False o WEBSITE_NAME no definido)"
fi

#--------------------------------------------------
# Arranque Odoo
#--------------------------------------------------
echo -e "* Starting Odoo Service"
sudo /etc/init.d/$OE_CONFIG start

echo "-----------------------------------------------------------"
echo "Odoo en marcha."
echo "Port (backend): $OE_PORT"
echo "Dominio: $WEBSITE_NAME"
echo "Logfile: /var/log/$OE_USER/${OE_CONFIG}.log"
echo "Config: /etc/${OE_CONFIG}.conf  (proxy_mode = True)"
echo "Service: sudo service $OE_CONFIG {start|stop|restart}"
echo "Traefik dynamic: /etc/traefik/conf.d/odoo.yml"
echo "Recuerda usar un email real en Traefik ACME."
echo "-----------------------------------------------------------"
