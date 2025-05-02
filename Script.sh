#!/usr/bin/env bash
set -euo pipefail

# default network to allow through UFW
ALLOWED_NET="172.16.0.0/14"

usage() {
  cat <<EOF
Usage: $0 -u PTERO_USER -p PTERO_PASS -s NORMAL_USER -q NORMAL_PASS -d NORMAL_DB [-n ALLOWED_NETWORK]
  -u  Pterodactyl database username
  -p  Pterodactyl database password
  -s  "Normal" database username (e.g. "server")
  -q  "Normal" database password
  -d  Name of the "normal" database to create
  -n  (Optional) CIDR/network to allow via UFW firewall [default: $ALLOWED_NET]
Example:
  sudo $0 -u ptero -p 'PteroPwd1' -s server -q 'SrvPwd2' -d server_db -n '172.16.0.0/14'
EOF
  exit 1
}


# Parse Command-Line

while getopts "u:p:s:q:d:n:" opt; do
  case "$opt" in
    u) PTERO_USER="$OPTARG" ;;
    p) PTERO_PASS="$OPTARG" ;;
    s) NORMAL_USER="$OPTARG" ;;
    q) NORMAL_PASS="$OPTARG" ;;
    d) NORMAL_DB="$OPTARG" ;;
    n) ALLOWED_NET="$OPTARG" ;;
    *) usage ;;
  esac
done

# check required
: "${PTERO_USER:?Missing -u (Pterodactyl user)}"
: "${PTERO_PASS:?Missing -p (Pterodactyl pass)}"
: "${NORMAL_USER:?Missing -s (normal user)}"
: "${NORMAL_PASS:?Missing -q (normal pass)}"
: "${NORMAL_DB:?Missing -d (normal db name)}"

# Become root, allow firewall, etc.
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (or via sudo)." >&2
  exit 1
fi

echo "Allowing MariaDB port from ${ALLOWED_NET} through UFW..."
ufw allow from "$ALLOWED_NET" to any port 3306

# Update MariaDB bind-address
CONF_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf"

if ! grep -q "^bind-address" "$CONF_FILE"; then
  echo "Error: bind-address setting not found in $CONF_FILE" >&2
  exit 1
fi

echo "Updating bind-address to 0.0.0.0 in $CONF_FILE..."
sed -i.bak -E 's/^(bind-address\s*=\s*)127\.0\.0\.1$/\10.0.0.0/' "$CONF_FILE"

# Restart database services
echo "Restarting mysql and mariadb services..."
systemctl restart mysql
systemctl restart mariadb

# Create users & grants in MySQL
echo "Applying SQL commands..."
mysql -u root <<SQL
-- Use the system database to create users
USE mysql;

-- Pterodactyl setup
CREATE USER IF NOT EXISTS '${PTERO_USER}'@'%' IDENTIFIED BY '${PTERO_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${PTERO_USER}'@'%' WITH GRANT OPTION;

-- Normal database setup
CREATE USER IF NOT EXISTS '${NORMAL_USER}'@'%' IDENTIFIED BY '${NORMAL_PASS}';
CREATE DATABASE IF NOT EXISTS \`${NORMAL_DB}\`;
GRANT ALL PRIVILEGES ON \`${NORMAL_DB}\`.* TO '${NORMAL_USER}'@'%';

FLUSH PRIVILEGES;
EXIT;
SQL

echo "✅ All done! Your Pterodactyl user '${PTERO_USER}' and database '${NORMAL_DB}' with user '${NORMAL_USER}' have been created."