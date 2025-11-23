#!/bin/bash

# Colors
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
NC="\e[0m" # No Color

log() {
    color=${2:-$BLUE}
    echo -e "\n${color}======= $1 =======${NC}"
}

success() {
    echo -e "${GREEN}[✔] $1${NC}"
}

fail() {
    echo -e "${RED}[✘] $1${NC}"
}


# ======================================================
# STEP 1 — Update system
# ======================================================
log "Updating and upgrading system" $YELLOW
sudo apt update
sudo apt upgrade -y


# ======================================================
# STEP 2 — SAFE APT BATCH INSTALL (no parallel apt)
# ======================================================
log "Installing all required apt packages (safe batch install)" $YELLOW

sudo apt install -y \
    nginx \
    redis-server \
    gnupg \
    curl \
    certbot \
    python3-certbot-nginx \
    chromium-browser \
    chromium-chromedriver \
    micro

success "All apt packages installed safely"


# ======================================================
# STEP 3 — Install Node.js 22.x
# ======================================================
log "Installing Node.js 22.x" $YELLOW
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
success "Node.js installed"


# ======================================================
# STEP 4 — Install MongoDB Enterprise 8.2
# ======================================================
log "Setting up MongoDB Enterprise Repository" $YELLOW

curl -fsSL https://pgp.mongodb.com/server-8.0.asc | \
    sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.com/apt/ubuntu noble/mongodb-enterprise/8.2 multiverse" \
    | sudo tee /etc/apt/sources.list.d/mongodb-enterprise-8.2.list

sudo apt update
sudo apt install -y mongodb-enterprise

success "MongoDB installed"


# ======================================================
# STEP 5 — ENABLE SERVICES + PARALLEL POST CONFIG TASKS
# ======================================================
log "Starting essential services & running post-install tasks in parallel" $YELLOW

(
    sudo systemctl enable nginx
    sudo systemctl start nginx
) &

(
    sudo systemctl enable redis-server
    sudo systemctl start redis-server
) &

(
    sudo systemctl enable mongod
    sudo systemctl start mongod
) &

(
    sudo npm install -g pm2
) &

(
    # Fix ChromeDriver path if needed
    if [ -f "/usr/lib/chromium-browser/chromedriver" ]; then
        sudo ln -sf /usr/lib/chromium-browser/chromedriver /usr/bin/chromedriver
    elif [ -f "/usr/lib/chromium/chromedriver" ]; then
        sudo ln -sf /usr/lib/chromium/chromedriver /usr/bin/chromedriver
    fi
) &

wait
success "All services started & post-config tasks completed"


# ======================================================
# STEP 6 — FINAL VERIFICATION
# ======================================================
log "Verifying all installations..." $BLUE

check_service() {
    SERVICE=$1
    NAME=$2
    if systemctl is-active --quiet "$SERVICE"; then
        success "$NAME is running"
    else
        fail "$NAME is NOT running"
    fi
}

check_cmd() {
    CMD=$1
    NAME=$2
    if command -v $CMD >/dev/null 2>&1; then
        success "$NAME installed"
    else
        fail "$NAME missing"
    fi
}

# Check Services
check_service nginx "Nginx"
check_service redis-server "Redis"
check_service mongod "MongoDB"

# Check Commands
check_cmd node "Node.js"
check_cmd npm "NPM"
check_cmd pm2 "PM2"
check_cmd certbot "Certbot"
check_cmd chromium-browser "Chromium Browser"
check_cmd chromedriver "ChromeDriver"
check_cmd micro "Micro Editor"

echo -e "\n${GREEN}====== SYSTEM SETUP VERIFIED ✓ ALL DONE! ======${NC}"
