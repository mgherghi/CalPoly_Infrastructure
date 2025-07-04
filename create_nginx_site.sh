#!/bin/sh
# Automated script ... just run either the wget command or curl 
# wget -qO- https://raw.githubusercontent.com/mgherghi/CalPoly_Infrastructure/refs/heads/main/create_nginx_site.sh | sh
# curl -s https://raw.githubusercontent.com/mgherghi/CalPoly_Infrastructure/refs/heads/main/create_nginx_site.sh | sh 


# Ensure Debian/Ubuntu
if ! [ -x "$(command -v apt)" ]; then
  echo "❌ This script requires Debian or Ubuntu (APT available)."
  exit 1
fi

# Install required packages
for pkg in nginx certbot python3-certbot-nginx; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "📦 Installing $pkg..."
    apt update && apt install -y "$pkg"
  else
    echo "✅ $pkg is already installed."
  fi
done

# --- Domains input ---
if [ "$#" -gt 0 ]; then
  domains="$*"
else
  echo -n "Enter domain(s) separated by space (e.g., example.com www.example.com): "
  read domains < /dev/tty
fi

if [ -z "$domains" ]; then
  echo "❌ At least one domain is required. Aborting."
  exit 1
fi

# Split domains into positional parameters
set -- $domains
num_domains=$#

if [ "$num_domains" -eq 1 ]; then
  first_domain="$1"
  case "$first_domain" in
    www.*)
      domains="$first_domain"
      ;;
    *)
      domains="$first_domain www.$first_domain"
      ;;
  esac
fi

# Primary domain for nginx filename (strip www. if present)
primary_domain=$(echo $domains | awk '{print $1}' | sed 's/^www\.//')

# --- Backend IP input ---
echo -n "Enter the backend server IP and port (e.g., 127.0.0.1:5000): "
read backend_ip < /dev/tty

if [ -z "$backend_ip" ]; then
  echo "❌ Backend IP is required. Aborting."
  exit 1
fi

available_path="/etc/nginx/sites-available/$primary_domain"
enabled_path="/etc/nginx/sites-enabled/$primary_domain"

# --- Write nginx config ---
cat <<EOF > "$available_path"
server {
    listen 80;
    server_name $domains;

    location / {
        proxy_pass http://$backend_ip;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

echo "✅ Nginx config created at $available_path"

# --- Create symlink ---
if [ ! -e "$enabled_path" ]; then
  ln -s "$available_path" "$enabled_path"
  echo "✅ Symlink created: $enabled_path"
else
  echo "⚠️ Symlink already exists: $enabled_path"
fi

# --- Test & reload nginx ---
echo "🔍 Testing Nginx config..."
if nginx -t; then
  echo "✅ Nginx config valid. Reloading..."
  systemctl reload nginx
else
  echo "❌ Nginx config invalid. Aborting."
  exit 1
fi

# --- Prepare certbot domain arguments ---
certbot_args=""
for d in $domains; do
  certbot_args="$certbot_args -d $d"
done

# --- Obtain SSL certificate ---
echo "🔐 Running Certbot for domains: $domains"
certbot --nginx $certbot_args

# --- Setup systemd timer and service for renewal ---
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

echo "✅ Certbot auto-renew timer set (every 80 days)."
echo "🎉 Setup complete for domains: $domains"
