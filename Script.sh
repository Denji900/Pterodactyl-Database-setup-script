#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to detect local CIDR
get_local_cidr() {
    local interface
    interface=$(ip route | awk '/default/ {print $5}' | head -n1)
    ip -o -f inet addr show "$interface" | awk '{print $4}' | head -n1
}

# Function to prompt for input with validation
prompt_input() {
    local prompt="$1"
    local var
    while true; do
        read -rp "$prompt" var
        if [[ -n "$var" ]]; then
            echo "$var"
            return
        else
            echo "Input cannot be empty. Please try again."
        fi
    done
}

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

echo "=== Pterodactyl Database Setup Script ==="

# Prompt for Pterodactyl database user credentials
ptero_user=$(prompt_input "Enter Pterodactyl database username: ")
read -rsp "Enter password for $ptero_user: " ptero_pass
echo

# Prompt for additional database user credentials
normal_user=$(prompt_input "Enter additional database username: ")
read -rsp "Enter password for $normal_user: " normal_pass
echo
normal_db=$(prompt_input "Enter name for the additional database: ")

# Detect local CIDR and prompt for UFW configuration
default_cidr=$(get_local_cidr)
read -rp "Enter network/CIDR to allow via UFW firewall [default: $default_cidr]: " cidr_input
cidr="${cidr_input:-$default_cidr}"

# Configure UFW
echo "Configuring UFW to allow MySQL connections from $cidr..."
ufw allow from "$cidr" to any port 3306
ufw reload

# Update MariaDB bind-address
echo "Updating MariaDB bind-address to allow external connections..."
sed -i.bak 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf

# Restart MariaDB service
echo "Restarting MariaDB service..."
systemctl restart mariadb

# Create Pterodactyl database user
echo "Creating Pterodactyl database user..."
mysql -u root <<EOF
CREATE USER IF NOT EXISTS '$ptero_user'@'%' IDENTIFIED BY '$ptero_pass';
GRANT ALL PRIVILEGES ON *.* TO '$ptero_user'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Create additional database and user
echo "Creating additional database and user..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS \`$normal_db\`;
CREATE USER IF NOT EXISTS '$normal_user'@'%' IDENTIFIED BY '$normal_pass';
GRANT ALL PRIVILEGES ON \`$normal_db\`.* TO '$normal_user'@'%';
FLUSH PRIVILEGES;
EOF

echo "=== Setup Complete ==="
echo "Pterodactyl user: $ptero_user"
echo "Additional user: $normal_user"
echo "Additional database: $normal_db"
