#!/bin/bash
# Automated Elektrine deployment for Vultr with Docker and Let's Encrypt
# Usage: curl -sSL https://raw.githubusercontent.com/yourusername/elektrine/main/deploy-vultr.sh | bash -s -- --domain elektrine.com --email admin@elektrine.com --repo https://github.com/yourusername/elektrine.git

set -e

# Parse arguments
DOMAIN=""
EMAIL=""
REPO_URL=""
ENABLE_SSL=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift; shift ;;
        --email) EMAIL="$2"; shift; shift ;;
        --repo) REPO_URL="$2"; shift; shift ;;
        --no-ssl) ENABLE_SSL=false; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required arguments
if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ] || [ -z "$REPO_URL" ]; then
    echo "Usage: $0 --domain <domain> --email <email> --repo <git-repo-url> [--no-ssl]"
    exit 1
fi

echo "🚀 Elektrine Automated Deployment"
echo "================================="
echo "Domain: $DOMAIN"
echo "Email: $EMAIL"
echo "Repository: $REPO_URL"
echo "SSL: $ENABLE_SSL"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root"
    exit 1
fi

# Update system
echo "📦 Updating system..."
apt-get update && apt-get upgrade -y

# Install dependencies
echo "📦 Installing dependencies..."
apt-get install -y curl wget git ufw fail2ban htop

# Install Docker
if ! command -v docker &> /dev/null; then
    echo "🐳 Installing Docker..."
    curl -fsSL https://get.docker.com | sh
fi

# Install Docker Compose
if ! command -v docker-compose &> /dev/null; then
    echo "🐳 Installing Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# Setup firewall
echo "🔥 Configuring firewall..."
ufw --force disable
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Setup fail2ban
echo "🛡️ Configuring fail2ban..."
systemctl enable fail2ban
systemctl start fail2ban

# Configure Docker
echo "⚙️ Configuring Docker..."
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker

# Create app directory
echo "📁 Setting up application..."
mkdir -p /opt/elektrine
cd /opt/elektrine

# Clone repository
echo "📥 Cloning repository..."
if [ ! -d "app" ]; then
    git clone "$REPO_URL" app
fi

# Generate secrets
echo "🔐 Generating secrets..."
DB_PASSWORD=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 64)

# Create environment file
echo "⚙️ Creating configuration..."
cat > .env.production <<EOF
# Auto-generated configuration
DB_PASSWORD=$DB_PASSWORD
PHX_HOST=$DOMAIN
PRIMARY_DOMAIN=$DOMAIN
SECRET_KEY_BASE=$SECRET_KEY_BASE
LETS_ENCRYPT_ENABLED=$ENABLE_SSL
ELEKTRINE_RELEASE_MODULES=all
ELEKTRINE_ENABLED_MODULES=all

# Email Configuration
EMAIL_SERVICE=haraka
PHOENIX_API_KEY=
HARAKA_HTTP_API_KEY=
HARAKA_OUTBOUND_API_KEY=
HARAKA_INBOUND_API_KEY=
HARAKA_API_KEY=
HARAKA_BASE_URL=https://mail.$DOMAIN
HARAKA_INTERNAL_SIGNING_SECRET=
POSTAL_API_KEY=
POSTAL_API_KEY_ZORG=

# VPN Configuration
VPN_FLEET_REGISTRATION_KEY=

# Storage (Cloudflare R2)
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
R2_ENDPOINT=
R2_BUCKET_NAME=

# Security
HCAPTCHA_SITE_KEY=
HCAPTCHA_SECRET_KEY=

# OAuth
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=

# APIs
VIRUSTOTAL_API_KEY=
ABUSEIPDB_API_KEY=
RANSOMWARE_LIVE_API_KEY=
GIPHY_API_KEY=
SENTRY_DSN=
EOF
chmod 600 .env.production
cp .env.production .env
chmod 600 .env

# Build and start services
echo "🏗️ Building application..."
cd app
docker-compose build

echo "🗄️ Starting database..."
docker-compose up -d postgres

echo "⏳ Waiting for database..."
for i in {1..30}; do
    if docker-compose exec postgres pg_isready -U elektrine > /dev/null 2>&1; then
        break
    fi
    sleep 2
done

echo "🔧 Running migrations..."
docker-compose run --rm app bin/elektrine eval "Elektrine.Release.migrate()"

# Setup SSL if enabled
if [ "$ENABLE_SSL" = true ]; then
    echo "🔐 Setting up Let's Encrypt..."

    # Install certbot
    if ! command -v certbot &> /dev/null; then
        apt-get install -y certbot
    fi

    # Stop services for cert generation
    docker-compose down

    # Get certificate
    certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "$EMAIL" \
        --domains "$DOMAIN,www.$DOMAIN"

    # Create Docker volume and copy certs
    docker volume create letsencrypt
    docker run --rm \
        -v letsencrypt:/target \
        -v /etc/letsencrypt:/source:ro \
        alpine \
        sh -c "cp -r /source/* /target/"

    # Setup auto-renewal
    cat > /etc/systemd/system/certbot-renew.service <<EOF
[Unit]
Description=Certbot Renewal
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=/opt/elektrine/app
ExecStart=/bin/bash -c 'docker-compose down && certbot renew && docker run --rm -v letsencrypt:/target -v /etc/letsencrypt:/source:ro alpine sh -c "cp -r /source/* /target/" && docker-compose up -d'
EOF

    cat > /etc/systemd/system/certbot-renew.timer <<EOF
[Unit]
Description=Certbot renewal timer

[Timer]
OnCalendar=daily
RandomizedDelaySec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable certbot-renew.timer
    systemctl start certbot-renew.timer
fi

# Start all services
echo "🚀 Starting services..."
docker-compose up -d

# Health check
echo "🏥 Checking health..."
sleep 5
if docker-compose ps | grep -q "Up"; then
    echo ""
    echo "✅ Deployment complete!"
    echo ""
    if [ "$ENABLE_SSL" = true ]; then
        echo "🌐 Application: https://$DOMAIN"
        echo "🔐 SSL: Enabled with auto-renewal"
    else
        echo "🌐 Application: http://$DOMAIN"
    fi
    echo ""
    echo "📝 Commands:"
    echo "  cd /opt/elektrine/app"
    echo "  docker-compose logs -f     # View logs"
    echo "  docker-compose restart      # Restart"
    echo "  docker-compose down         # Stop"
    echo "  docker-compose up -d        # Start"
else
    echo "❌ Services failed to start. Check logs:"
    echo "  docker-compose logs"
    exit 1
fi
