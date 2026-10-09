#!/usr/bin/env bash
# Detecta lo que el deploy necesita saber de un proyecto Rails. Correr en la raíz del proyecto.
# Salida: líneas KEY=valor (sin secretos).
set -uo pipefail
[ -f Gemfile.lock ] || { echo "ERROR=no hay Gemfile.lock; corre esto en la raíz de un proyecto Rails"; exit 1; }

lock_ver() { grep -m1 -E "^    $1 \(" Gemfile.lock | sed -E 's/.*\(([^)]*)\).*/\1/'; }
has_gem() { grep -qE "^    $1 \(" Gemfile.lock && echo 1 || echo 0; }
after_header() { sed -n "/^$1/{n;p;}" Gemfile.lock | xargs; }

repo=$(git remote get-url origin 2>/dev/null || true)
ruby=$(sed 's/^ruby-//' .ruby-version 2>/dev/null || after_header "RUBY VERSION" | awk '{print $2}' | cut -dp -f1)

echo "REPO_URL=$repo"
echo "APP_NAME=$(basename "${repo:-$PWD}" .git | tr 'A-Z_.' 'a-z--')"
echo "BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "RUBY_VERSION=$ruby"
echo "BUNDLER_VERSION=$(after_header "BUNDLED WITH")"
echo "RAILS_VERSION=$(lock_ver rails)"
echo "DB_ADAPTER=$(for g in pg mysql2 trilogy sqlite3; do [ "$(has_gem $g)" = 1 ] && echo $g; done | xargs)"
echo "PROD_DATABASES=$(sed -n '/^production:/,/^[a-z]/p' config/database.yml 2>/dev/null | grep -oE 'database: *[^ ]+' | awk '{print $2}' | xargs)"
echo "ASSETS=$(for g in propshaft sprockets-rails importmap-rails jsbundling-rails cssbundling-rails tailwindcss-rails; do [ "$(has_gem $g)" = 1 ] && echo $g; done | xargs)"
echo "USES_SOLID_QUEUE=$(has_gem solid_queue)"
echo "USES_SIDEKIQ=$(has_gem sidekiq)"
echo "USES_REDIS=$(has_gem redis)"
echo "USES_IMAGE_PROCESSING=$(has_gem image_processing)"
echo "HAS_CAPFILE=$([ -f Capfile ] && echo 1 || echo 0)"
echo "FORCE_SSL=$(grep -qE '^\s*config\.force_ssl\s*=\s*true' config/environments/production.rb 2>/dev/null && echo 1 || echo 0)"
echo "LOCK_PLATFORMS=$(sed -n '/^PLATFORMS/,/^$/p' Gemfile.lock | tail -n +2 | xargs)"
# Archivos ignorados por git que existen en config/ (master.key, JSON de cuentas de servicio...): hay que subirlos a shared/
echo "SECRET_FILES=$(git ls-files -o -i --exclude-standard config/ 2>/dev/null | xargs)"
echo "ENV_VARS=$( { grep -rhoE 'ENV(\.fetch)?[[(] *"[A-Z0-9_]+"' app config lib 2>/dev/null | grep -oE '"[A-Z0-9_]+"' | tr -d '"'
  grep -hoE '^[A-Z0-9_]+=' .env.example .env.sample 2>/dev/null | tr -d '='; } | sort -u | xargs)"
