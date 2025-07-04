#!/bin/sh
# Automated script ... just run either the wget command or curl 
# wget -qO - https://raw.githubusercontent.com/mgherghi/CalPoly_Infrastructure/main/create_nginx_site.sh | bash -s -- <domain> <backend1> [backend2] ...
# curl -s https://raw.githubusercontent.com/mgherghi/CalPoly_Infrastructure/refs/heads/main/create_nginx_site.sh | bash -s -- <domain> <backend1> [backend2] ...
#!/bin/bash

LOG_FILE="/var/log/nginx-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <domain> <backend1> [backend2] ..."
  exit 1
fi

DOMAIN="$1"
shift
BACKENDS=("$@")

echo "[INFO] Starting Nginx setup for $DOMAIN..."

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
SSL_PARAMS="/etc/nginx/ssl-params.conf"

# Create SSL params file if missing
if [[ ! -f "$SSL_PARAMS" ]]; then
  echo "[INFO] Creating $SSL_PARAMS with secure defaults"
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

# Write nginx config
echo "[INFO] Writing Nginx config to $NGINX_CONF"
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
        root /var/www/html;
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

# Enable site and reload
sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

if ! sudo nginx -t; then
  echo "[ERROR] Nginx config test failed!"
  exit 1
fi

sudo systemctl reload nginx
echo "[INFO] Nginx reloaded successfully"

# Run certbot without email
echo "[INFO] Running certbot for $DOMAIN"
sudo certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --agree-tos --non-interactive || {
  echo "[ERROR] Certbot failed"
  exit 1
}

sudo systemctl reload nginx
echo "[INFO] SSL cert installed and nginx reloaded"

# Setup renewal cron job
if ! sudo crontab -l | grep -q "certbot renew"; then
  echo "[INFO] Adding certbot renew cron job"
  (sudo crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --deploy-hook --cert-name $DOMAIN 'systemctl reload nginx'") | sudo crontab -
fi

echo "[DONE] Site $DOMAIN is ready"
log "🎉 Setup complete for: $domains"
log " - Reverse proxy to backend: $backend_ip"
log " - HTTPS redirect is active"
log " - Certbot auto-renew is scheduled"
