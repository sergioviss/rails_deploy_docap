#!/usr/bin/env bash
# HTTPS con Let's Encrypt para un dominio o para la IP del servidor. Idempotente. Requiere haber corrido bootstrap.sh.
# Uso, desde la máquina local:
#   ssh USUARIO@IP "sudo APP=miapp HOST=app.midominio.com EMAIL=yo@x.com bash -s" < ssl.sh
# Variables: APP y HOST (dominio o IP) obligatorias; EMAIL (si falta, se registra sin correo).
# Con IP, Let's Encrypt solo da certificados de 6 días (perfil shortlived); certbot los renueva solo.
set -euo pipefail
: "${APP:?falta APP}" "${HOST:?falta HOST (dominio o IP)}"
[ "$(id -u)" = 0 ] || { echo "Correr con sudo o como root" >&2; exit 1; }
SITE=/etc/nginx/sites-available/$APP
[ -f "/etc/nginx/snippets/$APP.conf" ] || { echo "Falta /etc/nginx/snippets/$APP.conf: corre antes bootstrap.sh" >&2; exit 1; }
step() { echo; echo "==> $*"; }

step "Certbot (snap; el de apt es muy viejo para certificados de IP)"
command -v snap >/dev/null || apt-get install -yq snapd
snap list certbot &>/dev/null || snap install --classic certbot
snap refresh certbot >/dev/null 2>&1 || true
ln -sf /snap/bin/certbot /usr/bin/certbot
certbot --version

if [[ $HOST =~ ^[0-9.]+$ || $HOST == *:* ]]; then
  ident=(--ip-address "$HOST" --preferred-profile shortlived)
else
  ident=(-d "$HOST")
fi
if [ -n "${EMAIL:-}" ]; then contact=(-m "$EMAIL"); else contact=(--register-unsafely-without-email); fi
args=(certonly --webroot -w /var/www/letsencrypt "${ident[@]}" --cert-name "$HOST"
      --non-interactive --agree-tos "${contact[@]}" --deploy-hook "systemctl reload nginx")

step "Prueba contra staging (no gasta el límite de certificados reales)"
certbot "${args[@]}" --dry-run

step "Certificado real para $HOST"
certbot "${args[@]}" --keep-until-expiring

step "Nginx: HTTPS en 443 y redirección desde HTTP"
cat > "$SITE" <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name $HOST;
  location ^~ /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl default_server;
  listen [::]:443 ssl default_server;
  server_name $HOST;
  ssl_certificate /etc/letsencrypt/live/$HOST/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$HOST/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_session_cache shared:SSL:10m;
  include snippets/$APP.conf;
}
EOF
nginx -t -q && systemctl reload nginx

step "Renovación automática"
systemctl list-timers --all | grep -i certbot || echo "AVISO: no se encontró el timer de renovación de certbot"
certbot renew --dry-run --cert-name "$HOST" >/dev/null && echo "renovación (dry-run) OK"

echo
echo "SSL_OK"
openssl x509 -in "/etc/letsencrypt/live/$HOST/fullchain.pem" -noout -enddate
