#!/usr/bin/env bash
set -euo pipefail

# Function to prompt for input with validation
prompt_input() {
  local var_name="$1"
  local prompt_message="$2"
  local is_password="${3:-false}"
  local input=""

  while true; do
    if [ "$is_password" = true ]; then
      read -s -p "$prompt_message: " input
      echo
    else
      read -p "$prompt_message: " input
    fi

    if [ -n "$input" ]; then
      eval "$var_name=\"\$input\""
      break
    else
      echo "Input cannot be empty. Please try again."
    fi
  done
}

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo."
  exit 1
fi

echo "Starting Pterodactyl Database Setup..."

# Prompt for inputs
prompt_input PTERO_USER "Enter Pterodactyl database username"
prompt_input PTERO_PASS "Enter Pterodactyl database password" true
prompt_input NORMAL_USER "Enter 'normal' database username (e.g., server)"
prompt_input NORMAL_PASS "Enter 'normal' database password" true
prompt_input NORMAL_DB "Enter name of the 'normal' database to create"
read -p "Enter network/CIDR to allow via UFW firewall [default: 172.16.0.0/14]: " ALLOWED_NET
ALLOWED_NET="${ALLOWED_NET:-172.16.0.0/14}"

echo "Configuration Summary:"
echo "Pterodactyl User: $PTERO_USER"
echo "Normal User: $NORMAL_USER"
echo "Normal Database: $NORMAL_DB"
echo "Allowed Network: $ALLOWED_NET"
echo

# Confirm to proceed
read -p "Proceed with the setup? (y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Setup aborted by user."
  exit 0
fi

# Allow MariaDB port through UFW
echo "Configuring UFW to allow MySQL connections from $ALLOWED_NET..."
ufw allow from "$ALLOWED_NET" to any port 3306

# Update MariaDB bind-address
CONF_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf"
if grep -q "^bind-address" "$CONF_FILE"; then
  echo "Updating bind-address in $CONF_FILE..."
  sed -i.bak -E 's/^(bind-address\s*=\s*)127\.0\.0\.1/\10.0.0.0/' "$CONF_FILE"
else
  echo "⚠bind-address not found in $CONF_FILE. Please check the configuration."
  exit 1
fi

# Restart MariaDB services
echo "Restarting MariaDB services..."
systemctl restart mysql
systemctl restart mariadb

# Create users and databases
echo "Setting up databases and users..."
mysql -u root <<SQL
-- Pterodactyl setup
CREATE USER IF NOT EXISTS '${PTERO_USER}'@'%' IDENTIFIED BY '${PTERO_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${PTERO_USER}'@'%' WITH GRANT OPTION;

-- Normal database setup
CREATE USER IF NOT EXISTS '${NORMAL_USER}'@'%' IDENTIFIED BY '${NORMAL_PASS}';
CREATE DATABASE IF NOT EXISTS \`${NORMAL_DB}\`;
GRANT ALL PRIVILEGES ON \`${NORMAL_DB}\`.* TO '${NORMAL_USER}'@'%';

FLUSH PRIVILEGES;
SQL

echo "Setup Complete!"
echo "Pterodactyl user '${PTERO_USER}' and database '${NORMAL_DB}' with user '${NORMAL_USER}' have been created."
