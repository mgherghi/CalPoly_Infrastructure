# Automated script ... just run either the wget command or curl 
# wget -qO- https://raw.githubusercontent.com/mgherghi/CalPoly_Infrastructure/refs/heads/main/create_nginx_site.sh | sh -s yourdomain.com
# curl -s https://raw.githubusercontent.com/mgherghi/CalPoly_Infrastructure/refs/heads/main/create_nginx_site.sh | sh -s yourdomain.com

#!/bin/sh

# === Package Check & Install ===
for pkg in nginx certbot python3-certbot-nginx; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "📦 Installing $pkg..."
    apt update && apt install -y "$pkg"
  else
    echo "✅ $pkg is already installed."
  fi
done

# === Step 0: Input validation ===
if [ -z "$1" ]; then
  echo "Usage: sh create_nginx_site.sh <domain_name>"
  exit 1
fi

domain="$1"

# === Step 1: Ask for backend IP ===
echo -n "Enter the backend server IP (e.g., 127.0.0.1:5000): "
read backend_ip

if [ -z "$backend_ip" ]; then
  echo "❌ No backend IP entered. Aborting."
  exit 1
fi

available_path="/etc/nginx/sites-available/$domain"
enabled_path="/etc/nginx/sites-enabled/$domain"

# === Step 2: Write Nginx config with backend IP ===
cat <<EOF > "$available_path"
server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://$backend_ip;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# === Step 3: Create symlink ===
[ -e "$enabled_path" ] || ln -s "$available_path" "$enabled_path"

# === Step 4: Test and reload Nginx ===
if nginx -t; then
  echo "✅ Reloading Nginx..."
  systemctl reload nginx
else
  echo "❌ Nginx config invalid. Aborting."
  exit 1
fi

# === Step 5: Obtain SSL with Certbot ===
certbot --nginx -d "$domain"

# === Step 6: Create systemd timer for renewal ===
cat <<EOF > /etc/systemd/system/certbot-renew.timer
[Unit]
Description=Certbot renewal timer (every 80 days)

[Timer]
OnBootSec=10min
OnUnitActiveSec=6912000s
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat <<EOF > /etc/systemd/system/certbot-renew.service
[Unit]
Description=Renew Let's Encrypt certificates using Certbot

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet
EOF

systemctl daemon-reload
systemctl enable --now certbot-renew.timer

echo "🎉 Setup complete for $domain with SSL and auto-renew every 80 days"
