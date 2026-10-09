#!/usr/bin/env bash
# Prepara un Ubuntu (22.04/24.04) limpio para recibir la app con Capistrano. Idempotente: se puede volver a correr.
# Uso, desde la máquina local (el usuario SSH necesita sudo):
#   ssh USUARIO@IP "sudo APP=miapp RUBY_VERSION=3.4.1 BUNDLER_VERSION=2.6.2 bash -s" < bootstrap.sh
# Variables: APP y RUBY_VERSION (obligatorias); BUNDLER_VERSION; DEPLOY_USER (deploy); SERVER_NAME (dominio, o _);
#            PORT (3000, donde escucha Puma); EXTRA_PACKAGES (ej. "redis-server libvips-tools"); UPGRADE (1 = apt upgrade)
set -euo pipefail
: "${APP:?falta APP}" "${RUBY_VERSION:?falta RUBY_VERSION}"
DEPLOY_USER=${DEPLOY_USER:-deploy}
SERVER_NAME=${SERVER_NAME:-_}
PORT=${PORT:-3000}
APP_DIR=/var/www/$APP
ENV_FILE=$APP_DIR/shared/.env
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
[ "$(id -u)" = 0 ] || { echo "Correr con sudo o como root" >&2; exit 1; }
cd /tmp

step() { echo; echo "==> $*"; }
as_deploy() { runuser -l "$DEPLOY_USER" -c 'bash -se'; } # lee el script de stdin
env_set() { grep -q "^$1=" "$ENV_FILE" || echo "$1=$2" >> "$ENV_FILE"; }

step "Swap (sin swap, compilar Ruby con 1-2 GB de RAM muere por falta de memoria)"
if [ -z "$(swapon --show)" ] && [ "$(awk '/MemTotal/{print $2}' /proc/meminfo)" -lt 4000000 ]; then
  [ -f /swapfile ] || { fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; }
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

step "Paquetes"
apt-get update -q
if [ "${UPGRADE:-0}" = 1 ]; then apt-get upgrade -yq; fi
# shellcheck disable=SC2086
apt-get install -yq git curl rsync ufw build-essential autoconf bison libssl-dev libreadline-dev zlib1g-dev \
  libyaml-dev libffi-dev libgdbm-dev libncurses-dev libpq-dev postgresql postgresql-contrib nginx ${EXTRA_PACKAGES:-}

step "Usuario $DEPLOY_USER (sin contraseña ni sudo; entra con las mismas llaves SSH que tú)"
id "$DEPLOY_USER" &>/dev/null || adduser --disabled-password --gecos "" "$DEPLOY_USER"
home=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
src_home=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$home/.ssh"
touch "$home/.ssh/authorized_keys"
sort -u "$src_home/.ssh/authorized_keys" "$home/.ssh/authorized_keys" -o "$home/.ssh/authorized_keys"
chown "$DEPLOY_USER:" "$home/.ssh/authorized_keys" && chmod 600 "$home/.ssh/authorized_keys"

step "Ruby $RUBY_VERSION con rbenv (la primera vez tarda 5-15 min)"
as_deploy <<EOF
export PATH="\$HOME/.rbenv/bin:\$HOME/.rbenv/shims:\$PATH"
[ -d ~/.rbenv ] || git clone -q https://github.com/rbenv/rbenv.git ~/.rbenv
if [ -d ~/.rbenv/plugins/ruby-build ]; then git -C ~/.rbenv/plugins/ruby-build pull -q
else git clone -q https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build; fi
grep -q 'rbenv init' ~/.bashrc || printf '%s\n' 'export PATH="\$HOME/.rbenv/bin:\$PATH"' 'eval "\$(rbenv init - bash)"' >> ~/.bashrc
rbenv versions --bare | grep -qx '$RUBY_VERSION' || rbenv install '$RUBY_VERSION'
rbenv global '$RUBY_VERSION'
gem install bundler ${BUNDLER_VERSION:+-v $BUNDLER_VERSION} --conservative --no-document
rbenv rehash
EOF

step "Carpetas de Capistrano en $APP_DIR"
for d in "" releases shared shared/config shared/log shared/storage shared/tmp shared/tmp/pids shared/tmp/cache \
         shared/tmp/sockets shared/public shared/public/assets; do
  install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_DIR/$d"
done
touch "$ENV_FILE" && chown "$DEPLOY_USER:" "$ENV_FILE" && chmod 600 "$ENV_FILE"
env_set RAILS_ENV production
env_set SECRET_KEY_BASE "$(openssl rand -hex 64)"

step "PostgreSQL: rol $DEPLOY_USER con permiso para crear sus BDs (db:prepare las crea)"
if ! grep -q '^DATABASE_PASSWORD=.' "$ENV_FILE"; then
  db_pass=$(openssl rand -hex 24)
  if runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DEPLOY_USER'" | grep -q 1; then verb=ALTER; else verb=CREATE; fi
  echo "$verb ROLE \"$DEPLOY_USER\" LOGIN CREATEDB PASSWORD '$db_pass'" | runuser -u postgres -- psql -q
  sed -i '/^DATABASE_PASSWORD=/d' "$ENV_FILE"
  env_set DATABASE_PASSWORD "$db_pass"
fi
env_set DATABASE_USERNAME "$DEPLOY_USER"
env_set DATABASE_HOST localhost

step "Llave SSH del servidor para clonar el repo (deploy key)"
as_deploy <<EOF
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "$DEPLOY_USER@$APP"
grep -q '^github.com' ~/.ssh/known_hosts 2>/dev/null || ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
EOF

step "Servicio systemd de usuario ${APP}_puma"
unit_dir=$home/.config/systemd/user
for d in "$home/.config" "$home/.config/systemd" "$unit_dir"; do install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$d"; done
cat > "$unit_dir/${APP}_puma.service" <<EOF
[Unit]
Description=Puma $APP
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR/current
Environment=RAILS_ENV=production
Environment=PORT=$PORT
Environment=PATH=$home/.rbenv/shims:$home/.rbenv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$home/.rbenv/shims/bundle exec puma -C config/puma.rb
StandardOutput=append:$APP_DIR/shared/log/puma.log
StandardError=inherit
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
chown "$DEPLOY_USER:" "$unit_dir/${APP}_puma.service"
loginctl enable-linger "$DEPLOY_USER"
uid=$(id -u "$DEPLOY_USER")
for _ in $(seq 20); do [ -S "/run/user/$uid/bus" ] && break; sleep 1; done
runuser -u "$DEPLOY_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user daemon-reload
runuser -u "$DEPLOY_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user enable -q "${APP}_puma"

cat > "/etc/logrotate.d/$APP" <<EOF
$APP_DIR/shared/log/*.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
  copytruncate
}
EOF

step "Nginx como proxy inverso hacia Puma (127.0.0.1:$PORT)"
# La app vive en un snippet que comparten el server de HTTP (aquí) y el de HTTPS (ssl.sh)
install -d /var/www/letsencrypt
cat > "/etc/nginx/snippets/$APP.conf" <<EOF
root $APP_DIR/current/public;
client_max_body_size 50m;

location ^~ /assets/ {
  expires max;
  add_header Cache-Control public;
  try_files \$uri =404;
}

location / {
  try_files \$uri @puma;
}

location @puma {
  proxy_pass http://127.0.0.1:$PORT;
  proxy_set_header Host \$host;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_redirect off;
}
EOF
# Si ssl.sh ya configuró HTTPS, no se pisa el sitio
if ! grep -q ssl_certificate "/etc/nginx/sites-available/$APP" 2>/dev/null; then
  cat > "/etc/nginx/sites-available/$APP" <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name $SERVER_NAME;
  location ^~ /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
  include snippets/$APP.conf;
}
EOF
fi
ln -sf "../sites-available/$APP" "/etc/nginx/sites-enabled/$APP"
rm -f /etc/nginx/sites-enabled/default
nginx -t -q && systemctl reload nginx

step "Firewall: solo SSH y HTTP/HTTPS (Puma no queda expuesto)"
ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
ufw allow "${ssh_port:-22}/tcp" >/dev/null
ufw allow 'Nginx Full' >/dev/null
ufw --force enable >/dev/null

echo
echo "BOOTSTRAP_OK"
echo "SERVER_ARCH=$(uname -m)"
echo "ENV_KEYS=$(cut -d= -f1 "$ENV_FILE" | xargs)"
echo "DEPLOY_PUBKEY=$(cat "$home/.ssh/id_ed25519.pub")"
