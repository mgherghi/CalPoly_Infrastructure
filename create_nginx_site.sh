#!/bin/sh
# Automated script ... just run either the wget command or curl 
# wget -qO- https://raw.githubusercontent.com/mgherghi/CalPoly_Infrastructure/refs/heads/main/create_nginx_site.sh | sh -s domain.com
# curl -s https://raw.githubusercontent.com/mgherghi/CalPoly_Infrastructure/refs/heads/main/create_nginx_site.sh | sh  -s domain.com


LOGFILE="/var/log/nginx-setup.log"

# Start logging to file and console
exec > >(tee -a "$LOGFILE") 2>&1

log() {
  echo "[INFO] $1"
}

err() {
  echo "[ERROR] $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

log "🔧 Starting Nginx site setup..."

# Ensure Debian/Ubuntu
require_cmd apt

# Install required packages
for pkg in nginx certbot python3-certbot-nginx cron; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "📦 Installing $pkg..."
    apt update && apt install -y "$pkg" || err "Failed to install $pkg"
  else
    log "✅ $pkg is already installed."
  fi
done

# Ensure cron is running
systemctl enable --now cron || log "cron already running"

# --- Domain Input ---
if [ "$#" -gt 0 ]; then
  domains="$*"
else
  echo -n "Enter domain(s) (e.g., example.com): "
  read domains < /dev/tty
fi

[ -z "$domains" ] && err "Domain name(s) required"

# Normalize domain list
set -- $domains
num_domains=$#

if [ "$num_domains" -eq 1 ]; then
  base_domain="$1"
  case "$base_domain" in
    www.*)
      domains="$base_domain"
      ;;
    *)
      domains="$base_domain www.$base_domain"
      ;;
  esac
fi

# Primary domain for file naming (strip www.)
primary_domain=$(echo "$domains" | awk '{print $1}' | sed 's/^www\.//')
log "🔑 Using primary domain: $primary_domain"
log "🌐 Full domain list: $domains"

# --- Backend IP Input ---
echo -n "Enter backend server IP and port (e.g., 127.0.0.1:5000): "
read backend_ip < /dev/tty

[ -z "$backend_ip" ] && err "Backend IP is required"

# --- Nginx Config Paths ---
site_avail="/etc/nginx/sites-available/$primary_domain"
site_enabled="/etc/nginx/sites-enabled/$primary_domain"

# --- Write Nginx Config ---
cat <<EOF > "$site_avail"
server {
    listen 80;
    server_name $domains;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $domains;

    ssl_certificate /etc/letsencrypt/live/$primary_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$primary_domain/privkey.pem;
    include ssl-params.conf;

    location / {
        proxy_pass http://$backend_ip;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

log "📝 Nginx config written: $site_avail"

# --- SSL Parameters File ---
ssl_params="/etc/nginx/snippets/ssl-params.conf"
if [ ! -f "$ssl_params" ]; then
  mkdir -p /etc/nginx/snippets
  cat <<EOF > "$ssl_params"
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
ssl_ecdh_curve secp384r1;
ssl_session_timeout  10m;
ssl_session_cache shared:SSL:10m;
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 1.1.1.1 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";
add_header X-Frame-Options DENY;
add_header X-Content-Type-Options nosniff;
EOF
  log "🔐 Created secure SSL params at: $ssl_params"
fi

# --- Enable Site ---
[ -L "$site_enabled" ] || ln -s "$site_avail" "$site_enabled" && log "🔗 Site enabled: $site_enabled"

# --- Test & Reload Nginx ---
nginx -t || err "Nginx configuration test failed"
systemctl reload nginx || err "Failed to reload nginx"
log "🚀 Nginx reloaded successfully"

# --- Certbot SSL Setup ---
certbot_args=""
for d in $domains; do
  certbot_args="$certbot_args -d $d"
done

log "🔐 Running Certbot with: $certbot_args"
certbot --nginx $certbot_args || err "Certbot failed to issue certificates"

systemctl reload nginx || err "Final nginx reload failed"
log "✅ SSL setup and HTTPS redirect configured"

# --- Cron Auto-Renew with Restart ---
cron_cmd="0 0 */80 * * /usr/bin/certbot renew --quiet && systemctl reload nginx"
if ! crontab -l 2>/dev/null | grep -Fq "$cron_cmd"; then
  (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
  log "🕒 Added certbot auto-renew cron job (every 80 days) with nginx reload"
else
  log "⚠️ Certbot auto-renew cron already exists"
fi

log "🎉 Setup complete for: $domains"
log " - Reverse proxy to backend: $backend_ip"
log " - HTTPS redirect is active"
log " - Certbot auto-renew is scheduled"
