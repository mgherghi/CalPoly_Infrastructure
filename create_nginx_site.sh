#!/bin/sh
# Automated script ... just run either the wget command or curl 
# wget -qO - https://raw.githubusercontent.com/mgherghi/CalPoly_Infrastructure/main/create_nginx_site.sh | bash -s -- <domain> <backend1> [backend2] ...
# curl -s https://raw.githubusercontent.com/mgherghi/CalPoly_Infrastructure/refs/heads/main/create_nginx_site.sh | bash -s -- <domain> <backend1> [backend2] ...

LOG_FILE="/var/log/nginx-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
set -euo pipefail

# --- Input Validation
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <domain> <backend1> [backend2] [...]"
  exit 1
fi

DOMAIN="$1"
shift
BACKENDS=("$@")

# --- Checks
echo "[INFO] Validating environment..."

required_bins=(nginx certbot tee ln systemctl python3-certbot-nginx crontab)
for bin in "${required_bins[@]}"; do
  if ! command -v "$bin" &>/dev/null; then
    echo "[ERROR] Required command '$bin' not found. Install it and retry."
    exit 1
  fi
done

# --- Ensure webroot exists
WEBROOT="/var/www/html"
if [[ ! -d "$WEBROOT" ]]; then
  echo "[INFO] Creating webroot directory at $WEBROOT"
  sudo mkdir -p "$WEBROOT"
  sudo chown www-data:www-data "$WEBROOT"
fi

# --- Paths
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
SSL_PARAMS="/etc/nginx/ssl-params.conf"

# --- SSL Params
if [[ ! -f "$SSL_PARAMS" ]]; then
  echo "[INFO] Creating SSL params file at $SSL_PARAMS"
  sudo tee "$SSL_PARAMS" > /dev/null <<'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384";
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:50m;
ssl_session_tickets off;

add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Content-Type-Options nosniff;
add_header X-Frame-Options DENY;
add_header X-XSS-Protection "1; mode=block";

ssl_stapling on;
ssl_stapling_verify on;
EOF
fi

# --- Generate NGINX Config
echo "[INFO] Writing NGINX config to $NGINX_CONF"

sudo tee "$NGINX_CONF" > /dev/null <<EOF
upstream backend_pool {
EOF

for BACKEND in "${BACKENDS[@]}"; do
  echo "    server $BACKEND;" | sudo tee -a "$NGINX_CONF" > /dev/null
done

sudo tee -a "$NGINX_CONF" > /dev/null <<EOF
}

server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root $WEBROOT;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include $SSL_PARAMS;

    location / {
        proxy_pass http://backend_pool;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_connect_timeout 3s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }
}
EOF

# --- Enable Site
echo "[INFO] Enabling NGINX site for $DOMAIN"
sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"

# --- Test & Reload NGINX
echo "[INFO] Validating NGINX configuration"
if ! sudo nginx -t; then
  echo "[ERROR] NGINX configuration failed validation"
  exit 1
fi

sudo systemctl reload nginx
echo "[INFO] NGINX reloaded"

# --- Get SSL Certificate (no email)
echo "[INFO] Requesting certificate from Let's Encrypt"
sudo certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --agree-tos --non-interactive || {
  echo "[ERROR] Certbot failed"
  exit 1
}

# --- Final NGINX reload after cert
sudo systemctl reload nginx
echo "[INFO] SSL certificate installed and NGINX reloaded"

# --- Setup Certbot Auto-Renew Cron
echo "[INFO] Ensuring certbot auto-renew is in cron"
if ! sudo crontab -l 2>/dev/null | grep -q "certbot renew"; then
  (sudo crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --deploy-hook --cert-name $DOMAIN 'systemctl reload nginx'") | sudo crontab -
  echo "[INFO] Cron job added for certbot renewal"
else
  echo "[INFO] Certbot renewal already scheduled"
fi

echo "[SUCCESS] Site $DOMAIN is configured with HTTPS and load balancing"
echo "[DONE] Site $DOMAIN is ready"
log "🎉 Setup complete for: $domains"
log " - Reverse proxy to backend: $backend_ip"
log " - HTTPS redirect is active"
log " - Certbot auto-renew is scheduled"
