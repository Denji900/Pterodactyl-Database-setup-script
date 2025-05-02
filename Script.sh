#!/bin/bash
set -euo pipefail

prompt_input() {
    while true; do
        read -rp "$1" val
        [[ -n "$val" ]] && { echo "$val"; return; }
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

ufw allow from 172.16.0.0/14 to any port 3306
ufw reload

sed -i.bak 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl restart mariadb

mysql -u root <<EOF
CREATE USER IF NOT EXISTS '$ptero_user'@'%' IDENTIFIED BY '$ptero_pass';
GRANT ALL PRIVILEGES ON *.* TO '$ptero_user'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

host_ip=$(hostname -I | awk '{print $1}')

echo
echo "Setup complete. Use these values in the panel's Create New Database Host form:"
echo "Name:       $dbhost_name"
echo "Host:       $host_ip"
echo "Port:       3306"
echo "Username:   $ptero_user"
echo "Password:   $ptero_pass"
