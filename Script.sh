#!/bin/bash
set -e

read -p "Enter your domain name for PeerTube (e.g., peertube.example.com): " PEERTUBE_DOMAIN
if [[ -z "$PEERTUBE_DOMAIN" ]]; then
  echo "Domain name cannot be empty. Exiting."
  exit 1
fi

read -sp "Enter a password for the 'peertube' system user: " PEERTUBE_SYSTEM_USER_PASSWORD
echo
if [[ -z "$PEERTUBE_SYSTEM_USER_PASSWORD" ]]; then
  echo "PeerTube system user password cannot be empty. Exiting."
  exit 1
fi

read -sp "Enter a password for the 'peertube' PostgreSQL database user: " PEERTUBE_DB_PASSWORD
echo
if [[ -z "$PEERTUBE_DB_PASSWORD" ]]; then
  echo "PeerTube database password cannot be empty. Exiting."
  exit 1
fi

read -p "Enter the email address for the PeerTube administrator (root user): " PEERTUBE_ADMIN_EMAIL
if [[ -z "$PEERTUBE_ADMIN_EMAIL" ]]; then
  echo "Admin email cannot be empty. Exiting."
  exit 1
fi

echo "--- SUMMARY ---"
echo "PeerTube Domain: $PEERTUBE_DOMAIN"
echo "PeerTube Admin Email: $PEERTUBE_ADMIN_EMAIL"
echo "PeerTube System User: peertube"
echo "PeerTube DB User: peertube"
echo "---"
read -p "Proceed with installation? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Installation cancelled."
  exit 0
fi

log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1"
}

log_success() {
  echo "[SUCCESS] $1"
}

log_info "Updating system packages..."
apt-get update -y
apt-get upgrade -y

log_info "Installing basic dependencies (curl, sudo, unzip, vim, gnupg)..."
apt-get install -y curl sudo unzip vim gnupg apt-transport-https

log_info "Attempting to remove any existing older NodeJS versions and libnode-dev..."
if dpkg -l | grep -q 'libnode-dev'; then
  log_warn "'libnode-dev' is installed. Attempting to remove it along with old nodejs."
  apt-get remove --purge -y nodejs libnode-dev
  if dpkg -l | grep -q 'libnode-dev'; then
    log_warn "Failed to remove 'libnode-dev' with apt-get. Trying dpkg --force-depends."
    dpkg --remove --force-depends libnode-dev || echo "dpkg remove failed for libnode-dev, but continuing if error was minor."
    if dpkg -l | grep -q 'libnode-dev'; then
        echo "ERROR: 'libnode-dev' could not be removed. Please resolve this manually. The file /usr/include/node/common.gypi is causing a conflict."
        exit 1
    fi
  fi
else
  log_info "'libnode-dev' not found, proceeding with NodeJS installation."
  apt-get remove --purge -y nodejs > /dev/null 2>&1 || true
fi
apt-get autoremove -y
apt-get clean

NODE_MAJOR=20
log_info "Setting up Nodesource repository and installing NodeJS ${NODE_MAJOR}.x..."
curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -
apt-get update -y
apt-get install -y nodejs

log_info "NodeJS version:"
node -v
log_info "NPM version:"
npm -v

log_info "Installing Yarn..."
npm install --global yarn
log_info "Yarn version:"
yarn --version

log_info "Installing PostgreSQL, Nginx, Redis, FFmpeg, Certbot, jq, and other dependencies..."
apt-get install -y \
  postgresql postgresql-contrib \
  nginx \
  redis-server \
  ffmpeg \
  g++ make openssl libssl-dev \
  python3-dev \
  cron \
  wget \
  certbot python3-certbot-nginx jq

log_info "Starting and enabling PostgreSQL and Redis..."
systemctl start postgresql
systemctl enable postgresql
systemctl start redis-server
systemctl enable redis-server

log_info "Creating 'peertube' system user..."
if id "peertube" &>/dev/null; then
  log_warn "'peertube' user already exists. Skipping creation, but ensuring home directory exists."
  mkdir -p /var/www/peertube
  chown peertube:peertube /var/www/peertube
else
  useradd -m -d /var/www/peertube -s /bin/bash peertube
fi
echo "peertube:$PEERTUBE_SYSTEM_USER_PASSWORD" | chpasswd
log_success "'peertube' system user configured."

log_info "Setting up PostgreSQL database for PeerTube..."
sudo -u postgres psql -c "CREATE USER peertube WITH PASSWORD '$PEERTUBE_DB_PASSWORD';" || log_warn "PostgreSQL user 'peertube' might already exist."
sudo -u postgres psql -c "CREATE DATABASE peertube_prod OWNER peertube ENCODING 'UTF8' TEMPLATE template0;" || log_warn "Database 'peertube_prod' might already exist."
sudo -u postgres psql -d peertube_prod -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" || log_warn "Could not enable pg_trgm extension."
sudo -u postgres psql -d peertube_prod -c "CREATE EXTENSION IF NOT EXISTS unaccent;" || log_warn "Could not enable unaccent extension."
log_success "PostgreSQL database setup complete."

log_info "Fetching latest PeerTube version tag..."
PEERTUBE_VERSION=$(curl -s https://api.github.com/repos/Chocobozzz/PeerTube/releases/latest | jq -r .tag_name | sed 's/v//')
if [[ -z "$PEERTUBE_VERSION" ]]; then
  log_warn "Could not automatically fetch latest PeerTube version. Please check manually."
  read -p "Enter PeerTube version to install (e.g., 3.1.0): " PEERTUBE_VERSION
  if [[ -z "$PEERTUBE_VERSION" ]]; then
    echo "Version required. Exiting."
    exit 1
  fi
fi
log_info "Latest PeerTube version identified as: v$PEERTUBE_VERSION"

log_info "Preparing PeerTube directories..."
mkdir -p /var/www/peertube/{versions,storage,config}
chown -R peertube:peertube /var/www/peertube

log_info "Downloading PeerTube v$PEERTUBE_VERSION..."
cd /var/www/peertube/versions
sudo -u peertube wget -q "https://github.com/Chocobozzz/PeerTube/releases/download/v${PEERTUBE_VERSION}/peertube-v${PEERTUBE_VERSION}.zip"
log_info "Unzipping PeerTube..."
sudo -u peertube unzip -o -q "peertube-v${PEERTUBE_VERSION}.zip"
sudo -u peertube rm "peertube-v${PEERTUBE_VERSION}.zip"

log_info "Installing PeerTube..."
cd /var/www/peertube
sudo -u peertube ln -sfn versions/peertube-v$PEERTUBE_VERSION peertube-latest
cd peertube-latest
sudo -u peertube yarn install --production --pure-lockfile
log_success "PeerTube installation complete."

log_info "Configuring PeerTube (production.yaml)..."
CONFIG_DIR="/var/www/peertube/config"
PRODUCTION_YAML="$CONFIG_DIR/production.yaml"
PRODUCTION_EXAMPLE_YAML="/var/www/peertube/peertube-latest/config/production.yaml.example"

if [ ! -f "$PRODUCTION_YAML" ]; then
    sudo -u peertube cp "$PRODUCTION_EXAMPLE_YAML" "$PRODUCTION_YAML"
else
    chown peertube:peertube "$PRODUCTION_YAML"
fi

log_info "Setting basic configuration in $PRODUCTION_YAML..."
sudo -u peertube sed -i "s|^\(\s*hostname:\s*\).*|\1'$PEERTUBE_DOMAIN'|" "$PRODUCTION_YAML"
sudo -u peertube sed -i "s|^\(\s*port:\s*\).*|\1 9000|" "$PRODUCTION_YAML"
sudo -u peertube sed -i "/webserver:/,/^[^[:space:]]/{s|^\(\s*listen:\s*\).*|\1 '0.0.0.0'|; s|^\(\s*port:\s*\).*|\1 9000|;}" "$PRODUCTION_YAML"

log_info "Configuring database connection..."
sudo -u peertube sed -i "s|^\(\s*username:\s*\).*|\1'peertube'|" "$PRODUCTION_YAML"
sudo -u peertube sed -i "s|^\(\s*password:\s*\).*|\1'$PEERTUBE_DB_PASSWORD'|" "$PRODUCTION_YAML"

log_info "Configuring admin email..."
sudo -u peertube sed -i "s|^\(\s*email:\s*\).*|\1'$PEERTUBE_ADMIN_EMAIL'|" "$PRODUCTION_YAML"

chown -R peertube:peertube "$CONFIG_DIR"
chmod 640 "$PRODUCTION_YAML"

log_success "PeerTube basic configuration written."
log_warn "You may need to further customize $PRODUCTION_YAML for advanced features (email, federation, etc.)."

log_info "Configuring Nginx..."
NGINX_CONF_PEERTUBE="/etc/nginx/sites-available/$PEERTUBE_DOMAIN"
sudo cp /var/www/peertube/peertube-latest/support/nginx/peertube "$NGINX_CONF_PEERTUBE"

sed -i "s/WEBSERVER_HOST/$PEERTUBE_DOMAIN/g" "$NGINX_CONF_PEERTUBE"
sed -i 's|\${PEERTUBE_HOST}|127.0.0.1:9000|g' "$NGINX_CONF_PEERTUBE" # Corrected line

ln -sfn "$NGINX_CONF_PEERTUBE" "/etc/nginx/sites-enabled/$PEERTUBE_DOMAIN"

log_info "Testing Nginx configuration..."
nginx -t

log_info "Stopping Nginx temporarily for Certbot..."
systemctl stop nginx || true

log_info "Obtaining SSL certificate for $PEERTUBE_DOMAIN with Certbot..."
certbot --nginx -d "$PEERTUBE_DOMAIN" --non-interactive --agree-tos -m "$PEERTUBE_ADMIN_EMAIL" --redirect

log_info "Restarting Nginx with SSL configuration..."
systemctl start nginx
systemctl reload nginx
log_success "Nginx configured with SSL."

log_info "Setting up Systemd service for PeerTube..."
sudo cp /var/www/peertube/peertube-latest/support/systemd/peertube.service /etc/systemd/system/

sed -i "s|^User=peertube|User=peertube|" /etc/systemd/system/peertube.service
sed -i "s|^Group=peertube|Group=peertube|" /etc/systemd/system/peertube.service
sed -i "s|^WorkingDirectory=/var/www/peertube/peertube-latest|WorkingDirectory=/var/www/peertube/peertube-latest|" /etc/systemd/system/peertube.service
sed -i "s|ExecStart=/usr/bin/yarn start --production|ExecStart=$(which yarn) start --production|" /etc/systemd/system/peertube.service

systemctl daemon-reload
systemctl enable --now peertube
log_success "PeerTube service started and enabled."

log_info "Waiting a few seconds for PeerTube to fully initialize..."
sleep 15

log_success "PeerTube installation should be complete!"
echo "--------------------------------------------------------------------"
echo " Access your PeerTube instance at: https://$PEERTUBE_DOMAIN"
echo ""
echo " IMPORTANT: Your initial 'root' administrator password for PeerTube"
echo " has been generated. You need to find it in the PeerTube logs."
echo " Run the following command to check the logs:"
echo "   sudo journalctl -feu peertube | grep -A5 -B2 'User password'"
echo " Or search for 'Default password for root user is'"
echo " Or 'User password' in the output of 'sudo journalctl -feu peertube'"
echo ""
echo " Login as 'root' with this password and CHANGE IT IMMEDIATELY."
echo " Also, verify the admin email in PeerTube's admin settings."
echo "--------------------------------------------------------------------"

exit 0
