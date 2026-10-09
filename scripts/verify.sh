#!/usr/bin/env bash
# Revisa en el servidor que la app esté sana. Correr como el usuario deploy:
#   ssh deploy@IP "APP=miapp bash -s" < verify.sh
# Sale con 1 si algo falla e imprime los logs útiles.
set -uo pipefail
: "${APP:?falta APP}"
PORT=${PORT:-3000}
cd "/var/www/$APP/current" 2>/dev/null || { echo "FAIL no existe /var/www/$APP/current (¿ya corrió cap production deploy?)"; exit 1; }
export PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH" RAILS_ENV=production
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

fails=0
check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "OK   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}
http_ok() { [[ $(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$1") =~ ^[23] ]]; }
# Con HTTPS configurado (ssl.sh), HTTP solo redirige: las revisiones de nginx van por HTTPS
if curl -sk -o /dev/null --max-time 5 https://127.0.0.1/; then WEB=https://127.0.0.1; else WEB=http://127.0.0.1; fi
asset=$(ls public/assets 2>/dev/null | grep -m1 -E '\.(css|js)$')

check "puma activo (systemd)"            systemctl --user is-active "${APP}_puma"
check "puma responde en :$PORT"          http_ok "http://127.0.0.1:$PORT/"
check "nginx responde en $WEB"           http_ok "$WEB/"
check "assets presentes en public/assets" test -n "$asset"
check "nginx sirve /assets/$asset"       http_ok "$WEB/assets/$asset"
check "conexión a la BD"                 bundle exec rails runner 'ActiveRecord::Base.connection.select_value("SELECT 1")'
check "sin migraciones pendientes"       bash -c '! bundle exec rails db:migrate:status | grep -qE "^\s+down"'

echo "GET / vía nginx: $(curl -sk -o /dev/null -w '%{http_code} -> %{redirect_url}' --max-time 15 "$WEB/")"
if [ "$fails" -gt 0 ]; then
  echo "--- shared/log/puma.log ---";      tail -n 60 "/var/www/$APP/shared/log/puma.log" 2>/dev/null
  echo "--- log/production.log ---";       tail -n 60 log/production.log 2>/dev/null
  echo "--- systemctl status ---";         systemctl --user status "${APP}_puma" --no-pager -n 0 2>&1 | head -5
  exit 1
fi
echo "TODO OK"
