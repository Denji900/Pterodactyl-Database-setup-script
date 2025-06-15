#!/bin/bash
set -euo pipefail

get_local_cidr() {
    interface=$(ip route | awk '/default/ {print $5; exit}')
    ip -o -f inet addr show "$interface" | awk '{print $4; exit}'
}

prompt_input() {
    while true; do
        read -rp "$1" var
        [[ -n "$var" ]] && { echo "$var"; return; }
        echo "Input cannot be empty. Please try again."
    done
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

dbhost_name=$(prompt_input "Enter a short name for this database host: ")
ptero_user=$(prompt_input "Enter Pterodactyl database username: ")
read -rsp "Enter password for $ptero_user: " ptero_pass; echo
normal_user=$(prompt_input "Enter additional database username: ")
read -rsp "Enter password for $normal_user: " normal_pass; echo
normal_db=$(prompt_input "Enter name for the additional database: ")
default_cidr=$(get_local_cidr)
read -rp "Enter network/CIDR to allow via UFW firewall [default: $default_cidr]: " cidr_input
cidr="${cidr_input:-$default_cidr}"

ufw allow from "$cidr" to any port 3306
ufw allow from 172.16.0.0/14 to any port 3306
ufw reload

sed -i.bak 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf

mysql -u root <<EOF
CREATE USER IF NOT EXISTS '$ptero_user'@'%' IDENTIFIED BY '$ptero_pass';
GRANT ALL PRIVILEGES ON *.* TO '$ptero_user'@'%' WITH GRANT OPTION;
CREATE DATABASE IF NOT EXISTS \`$normal_db\`;
CREATE USER IF NOT EXISTS '$normal_user'@'%' IDENTIFIED BY '$normal_pass';
GRANT ALL PRIVILEGES ON \`$normal_db\`.* TO '$normal_user'@'%';
FLUSH PRIVILEGES;
EOF

host_ip=$(hostname -I | awk '{print $1}')
echo "Setup complete."
read -rp "View credentials for new database host? (y/n): " view
if [[ $view =~ ^[Yy]$ ]]; then
    echo "Host: $host_ip"
    echo "Port: 3306"
    echo "Pterodactyl User: $ptero_user"
    echo "Pterodactyl Password: $ptero_pass"
    echo "Database User: $normal_user"
    echo "Database Name: $normal_db"
    echo "Database Password: $normal_pass"
fi

echo
echo "Setup complete. Use these values in the panel's Create New Database Host form:"
echo "Name:       $dbhost_name"
echo "Host:       $host_ip"
echo "Port:       3306"
echo "Username:   $ptero_user"
echo "Password:   $ptero_pass"
