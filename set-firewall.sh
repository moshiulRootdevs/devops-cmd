#!/bin/bash

# Run as sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

# Install required packages
apt-get update -y
apt-get install -y ufw whiptail iptables

# Initialize arrays
allowedPorts=()
allowedPortsForSpecificIPAddresses=()
ipAddressArray=()
dockerSafeEnabled=false

# Enable IPv6
sed -i 's/IPV6=no/IPV6=yes/' /etc/default/ufw

# Ask user whether to remove all previous rules
if whiptail --title "Reset UFW" --yesno "Do you want to remove all previous UFW rules?" 10 60; then
    echo "Resetting UFW..."
    ufw --force reset
else
    echo "Keeping existing UFW rules."
fi

# Set default policies
ufw default deny incoming
ufw default allow outgoing

# Enable essential services
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow OpenSSH
ufw limit OpenSSH
ufw logging on

##############################################
# Validate IP/CIDR
##############################################
function validate_ip_or_cidr() {
    local input=$1
    if [[ $input =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(\/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; then
        IFS='/' read -r ip mask <<< "$input"
        IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
        if ((o1<=255 && o2<=255 && o3<=255 && o4<=255)); then
            return 0
        fi
    fi
    return 1
}

##############################################
# Validate Port Number
##############################################
function validate_port() {
    local port=$1
    if [[ $port =~ ^[0-9]+$ ]] && ((port>0 && port<=65535)); then
        return 0
    fi
    return 1
}

##############################################
# Add/Edit/Remove IPs
##############################################
function manage_ips() {
    while true; do
        MENU_ITEMS=()
        for i in "${!ipAddressArray[@]}"; do
            MENU_ITEMS+=("$i" "${ipAddressArray[$i]}")
        done
        MENU_ITEMS+=("A" "Add new IP/CIDR")
        MENU_ITEMS+=("C" "Continue")

        CHOICE=$(whiptail --title "Manage Restricted IPs" --menu \
            "Select an IP/CIDR to remove, add new, or continue:" 25 70 15 \
            "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)

        case "$CHOICE" in
            A) 
                ip=$(whiptail --inputbox "Enter allowed IP/CIDR (e.g., 192.168.1.5 or 10.0.0.0/24):" 10 70 3>&1 1>&2 2>&3)
                if validate_ip_or_cidr "$ip"; then
                    ipAddressArray+=("$ip")
                    whiptail --msgbox "Added: $ip" 8 50
                else
                    whiptail --msgbox "Invalid IP/CIDR: $ip" 8 50
                fi
                ;;
            C) break ;;
            *) 
                if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
                    whiptail --yesno "Remove ${ipAddressArray[$CHOICE]}?" 8 60
                    if [ $? -eq 0 ]; then
                        unset ipAddressArray[$CHOICE]
                        ipAddressArray=("${ipAddressArray[@]}")
                    fi
                fi
                ;;
        esac
    done
}

##############################################
# Manage Global Allowed Ports
##############################################
function manage_global_ports() {
    while true; do
        PORTS_STR=$(IFS=','; echo "${allowedPorts[*]}")
        action=$(whiptail --title "Global Ports" --menu "Allowed ports for everyone: $PORTS_STR\nChoose action:" 20 70 10 \
            "A" "Add a port" \
            "R" "Remove a port" \
            "C" "Continue" 3>&1 1>&2 2>&3)

        case $action in
            A)
                port=$(whiptail --inputbox "Enter port number to allow globally (1-65535):" 10 60 3>&1 1>&2 2>&3)
                if validate_port "$port"; then
                    allowedPorts+=("$port")
                    whiptail --msgbox "Port $port added." 8 50
                else
                    whiptail --msgbox "Invalid port: $port" 8 50
                fi
                ;;
            R)
                if [ ${#allowedPorts[@]} -eq 0 ]; then
                    whiptail --msgbox "No ports to remove." 8 50
                    continue
                fi
                MENU_ITEMS=()
                for i in "${!allowedPorts[@]}"; do
                    MENU_ITEMS+=("$i" "${allowedPorts[$i]}")
                done
                port_index=$(whiptail --title "Remove Global Port" --menu "Select port to remove:" 20 60 10 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
                unset allowedPorts[$port_index]
                allowedPorts=("${allowedPorts[@]}")
                ;;
            C) break ;;
        esac
    done
}

##############################################
# Manage Restricted Ports
##############################################
function manage_restricted_ports() {
    while true; do
        PORTS_STR=$(IFS=','; echo "${allowedPortsForSpecificIPAddresses[*]}")
        action=$(whiptail --title "Restricted Ports" --menu "Ports restricted to specific IPs: $PORTS_STR\nChoose action:" 20 70 10 \
            "A" "Add a port" \
            "R" "Remove a port" \
            "C" "Continue" 3>&1 1>&2 2>&3)

        case $action in
            A)
                port=$(whiptail --inputbox "Enter restricted port number (1-65535):" 10 60 3>&1 1>&2 2>&3)
                if validate_port "$port"; then
                    allowedPortsForSpecificIPAddresses+=("$port")
                    whiptail --msgbox "Port $port added." 8 50
                else
                    whiptail --msgbox "Invalid port: $port" 8 50
                fi
                ;;
            R)
                if [ ${#allowedPortsForSpecificIPAddresses[@]} -eq 0 ]; then
                    whiptail --msgbox "No restricted ports to remove." 8 50
                    continue
                fi
                MENU_ITEMS=()
                for i in "${!allowedPortsForSpecificIPAddresses[@]}"; do
                    MENU_ITEMS+=("$i" "${allowedPortsForSpecificIPAddresses[$i]}")
                done
                port_index=$(whiptail --title "Remove Restricted Port" --menu "Select port to remove:" 20 60 10 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
                unset allowedPortsForSpecificIPAddresses[$port_index]
                allowedPortsForSpecificIPAddresses=("${allowedPortsForSpecificIPAddresses[@]}")
                ;;
            C) break ;;
        esac
    done
}

##############################################
# Apply restricted ports
##############################################
function apply_restricted_ports() {
    if [ ${#ipAddressArray[@]} -gt 0 ]; then
        for ip in "${ipAddressArray[@]}"; do
            for port in "${allowedPortsForSpecificIPAddresses[@]}"; do
                ufw allow from "$ip" to any port "$port"
            done
        done
    fi
}

##############################################
# Make Docker obey UFW
##############################################
function apply_docker_rules() {
    echo "Applying Docker/UFW compatibility fix..."

    mkdir -p /etc/docker
    echo '{ "iptables": false }' > /etc/docker/daemon.json

    systemctl restart docker
}

##############################################
# Open ports for everyone
##############################################
function open_ports_everyone() {
    for port in "${allowedPorts[@]}"; do
        ufw allow "$port"
    done
}

##############################################
# Show firewall status
##############################################
function show_status() {
    ufw status verbose
}

##############################################
# Main Execution
##############################################
manage_ips
manage_global_ports
manage_restricted_ports

open_ports_everyone
apply_restricted_ports
apply_docker_rules
ufw --force enable

whiptail --title "Firewall Setup Completed" --msgbox "Firewall setup completed successfully!\n\nCurrent status:\n$(ufw status verbose)" 25 90
