---
name: rails-cap-deploy
description: Despliega una app Rails + PostgreSQL en un servidor Ubuntu limpio (AWS EC2, DigitalOcean, etc.) con Capistrano, Puma (systemd) y Nginx. Prepara el servidor, configura Capistrano en el proyecto, despliega, sube los assets precompilados en local y verifica que la app quede funcionando. Usar cuando el usuario pida desplegar, deployar o subir a producción una app Rails en un servidor por IP.
---

# Deploy de Rails con Capistrano

`SKILL_DIR` = la carpeta donde está este archivo (contiene `scripts/` y `templates/`).
Trabaja desde la raíz del proyecto Rails. Avanza fase por fase. Al terminar cada una, dile al usuario en una línea qué quedó listo.

## Reglas

- **Nunca guardes contraseñas ni secretos** en archivos del repo, en logs ni en tu respuesta. Los valores del `.env` solo viven en `/var/www/APP/shared/.env` del servidor.
- **Pide confirmación antes de:** `apt upgrade` (`UPGRADE=1`), desactivar el login SSH por contraseña, hacer commit/push en el repo del usuario, y cualquier comando que borre datos (`db:drop`, `db:schema:load`, `db:reset`). En este flujo nada borra datos: `db:prepare` crea las BDs solo si no existen.
- Los scripts son idempotentes. Si uno falla, corrige la causa y vuelve a correrlo completo.
- `rbenv install` tarda de 5 a 15 min. Usa un timeout largo (≥ 20 min) o córrelo en segundo plano.
- Si algo falla 3 veces con el mismo error, detente y pregunta al usuario.

## Fase 0. Datos y detección

Corre `bash "$SKILL_DIR/scripts/detect.sh"` y muéstrale al usuario un resumen. Luego pide solo lo que falte:

| Dato | Notas |
|---|---|
| IP del servidor | |
| Usuario SSH inicial | `root` (DigitalOcean) o `ubuntu` (AWS). Necesita **sudo sin contraseña**. Es el único permiso que se requiere. |
| Acceso | Contraseña **o** llave `.pem`. Ver Fase 1. |
| Rama a desplegar | por defecto, `BRANCH` de detect |
| Dominio (opcional) | para `server_name` y SSL. Sin dominio se usa la IP por HTTP. |
| Valores del `.env` | Las variables salen de `ENV_VARS` de detect. Pide solo los valores. Lo más fácil es que el usuario tenga un archivo local (ej. `.env.production`, ignorado por git) y lo subas. |

Revisa también lo siguiente:
- `DB_ADAPTER` debe incluir `pg`. Si no, avisa que esta skill solo cubre PostgreSQL.
- `RAILS_VERSION` debe ser ≥ 6 (por `db:prepare`).
- `USES_SIDEKIQ=1`: el servicio de Sidekiq no está cubierto. Avisa y ofrece crear otro unit systemd igual al de Puma.

## Fase 1. Acceso por llave

El objetivo es que `ssh -o BatchMode=yes USER@IP true` funcione sin contraseña. Todo lo demás depende de esto.

- **Con contraseña:** si el usuario no tiene llave local (`ls ~/.ssh/id_ed25519.pub`), ofrece crearla con `ssh-keygen -t ed25519`. Lo preferible es que el usuario mismo corra `ssh-copy-id USER@IP` y escriba la contraseña en su terminal (en Claude Code: `! ssh-copy-id USER@IP`). Así tú nunca la ves. Si te la dio en el chat, usa `SSHPASS='...' sshpass -e ssh-copy-id -o StrictHostKeyChecking=accept-new USER@IP`, sin escribirla en ningún archivo.
- **Con `.pem` (AWS):** primero `chmod 400 llave.pem`. Para no tener que pasar `-i` en cada comando (ssh, rsync y Capistrano), instala también la llave normal del usuario: `ssh-copy-id -f -i ~/.ssh/id_ed25519.pub -o IdentityFile=llave.pem ubuntu@IP`.

## Fase 2. Preparar el servidor

```bash
ssh USER@IP "sudo APP=<APP_NAME> RUBY_VERSION=<RUBY_VERSION> BUNDLER_VERSION=<BUNDLER_VERSION> \
  SERVER_NAME=<dominio o _> EXTRA_PACKAGES='<extras>' UPGRADE=0 bash -s" < "$SKILL_DIR/scripts/bootstrap.sh"
```

En `EXTRA_PACKAGES` agrega `libvips-tools` si `USES_IMAGE_PROCESSING=1` y `redis-server` si `USES_REDIS=1` o `USES_SIDEKIQ=1`.

Si `config/puma.rb` no escucha en `ENV["PORT"]` o 3000, pasa `PORT=<puerto>`.

El script instala paquetes, crea el usuario `deploy` (entra con las mismas llaves), rbenv con Ruby y Bundler, el rol de PostgreSQL `deploy` con contraseña aleatoria (`CREATEDB`), las carpetas de Capistrano, `shared/.env` con `RAILS_ENV`, `SECRET_KEY_BASE` y `DATABASE_*`, el unit systemd `APP_puma`, Nginx y el firewall (ufw). También agrega swap si hace falta.

Debe terminar con `BOOTSTRAP_OK`. Guarda `DEPLOY_PUBKEY` y `SERVER_ARCH`.

Comprueba que el usuario deploy entra con llave: `ssh -o BatchMode=yes deploy@IP true`.

## Fase 3. `.env` y secretos en el servidor

1. **BD:** lee la sección `production` de `config/database.yml`. El bootstrap ya escribió `DATABASE_USERNAME`, `DATABASE_PASSWORD` y `DATABASE_HOST=localhost`.
   - Si database.yml lee otras variables, renómbralas en el `.env` del servidor.
   - Si usa `DATABASE_URL` con **una sola** BD, arma `postgres://deploy:<pass>@localhost/<bd>`.
   - Con varias BDs (`PROD_DATABASES`, ej. solid_cache/queue/cable) **no** uses `DATABASE_URL`, porque solo aplica a la primaria.
2. **Variables de la app:** agrega las de `ENV_VARS` con sus valores. Si el usuario tiene un archivo local, súbelo con `scp archivo deploy@IP:/tmp/env.add`. Luego, en el servidor, agrega al `.env` solo las claves que no existan y borra `/tmp/env.add`.
   - Agrega también `APP_HOST=<dominio o IP>`.
   - Si hay solid_queue y no habrá un proceso aparte de jobs, agrega `SOLID_QUEUE_IN_PUMA=true`.
   - Si `db/seeds.rb` necesita variables (ej. `SEED_ADMIN_PASSWORD`), deben estar **antes** del primer deploy.
   - Nunca imprimas el `.env`. Para revisarlo usa `cut -d= -f1`.
3. **Archivos secretos (`SECRET_FILES`):** súbelos a `/var/www/APP/shared/<misma ruta>`, por ejemplo `scp config/master.key deploy@IP:/var/www/APP/shared/config/`, y agrégalos a `linked_files` en la Fase 5. Después: `ssh deploy@IP chmod 600 /var/www/APP/shared/config/*`.

## Fase 4. Acceso del servidor al repo

Si `REPO_URL` es HTTPS de un repo público, omite esta fase. Si es privado o SSH, agrega `DEPLOY_PUBKEY` como **deploy key de solo lectura**:

```bash
ssh deploy@IP cat .ssh/id_ed25519.pub > /tmp/deploy_key.pub
gh repo deploy-key add /tmp/deploy_key.pub --repo OWNER/REPO --title "deploy@IP"
```

Si `gh` no está, no tiene sesión o no tiene permisos de admin en el repo, dale al usuario la llave y la ruta: GitHub → Settings → Deploy keys → Add.

Para probar: `ssh deploy@IP 'ssh -T git@github.com'`. Debe decir "successfully authenticated" (el código de salida 1 es normal).

## Fase 5. Capistrano en el proyecto

Si `HAS_CAPFILE=1`, revisa la configuración existente y adáptala a lo que sigue, en vez de sobrescribirla.

1. **Gemfile:** agrega `capistrano` (`~> 3.19`), `capistrano-rails` y `capistrano-rbenv`, todas con `require: false`, en `group :development`.
2. **dotenv en producción:** la app debe cargar `.env` también en producción. Si `dotenv` o `dotenv-rails` está solo en `:development, :test`, sácalo del grupo. Si no existe, agrega `gem "dotenv"` (v3, que trae el railtie).
3. Corre `bundle install`.
4. **Plataformas:** si `LOCK_PLATFORMS` no incluye la del servidor (`x86_64-linux` o `aarch64-linux`, según `SERVER_ARCH`) ni `ruby`, corre `bundle lock --add-platform <plataforma>`.
5. **Templates:** copia `$SKILL_DIR/templates/Capfile` a `Capfile`, `templates/deploy.rb` a `config/deploy.rb` y `templates/production.rb` a `config/deploy/production.rb`. Reemplaza `__APP__`, `__REPO_URL__`, `__BRANCH__` e `__IP__`, y agrega los `SECRET_FILES` a `linked_files`.
6. **SSL:** si `FORCE_SSL=1` y no hay dominio con certificado, la app redirige a https y no carga. Pregunta al usuario. Lo usual es cambiarlo a `config.force_ssl = ENV["FORCE_SSL"] == "true"` y lo mismo con `assume_ssl`.
7. **Hosts:** si `config.hosts` está activo en `production.rb`, agrega el dominio o la IP.
8. **Commit y push:** con confirmación del usuario, haz commit y push de Gemfile, Gemfile.lock, Capfile y config/deploy*. Capistrano clona desde el remoto, así que sin push el servidor no ve estos cambios.

## Fase 6. Deploy

```bash
bundle exec cap production deploy:check   # valida SSH, git y que existan los linked_files
bundle exec cap production deploy
```

Qué hace el deploy:
- Antes de empezar, verifica que el código local sea igual a `origin/<rama>` y precompila los assets en local.
- `deploy:migrate` corre `db:prepare`. En el primer deploy crea todas las BDs, carga el schema y corre los seeds. Después solo migra.
- Antes de publicar, sube `public/assets/` con rsync a `shared/public/assets/` (es el `scp -r public/assets/. deploy@IP:/var/www/APP/shared/public/assets/`, pero incremental) y limpia la copia local.
- Al final reinicia `APP_puma`.

## Fase 7. Verificar (no termines sin esto)

1. Corre `ssh deploy@IP "APP=<APP_NAME> bash -s" < "$SKILL_DIR/scripts/verify.sh"`. Debe terminar en `TODO OK`.
2. Desde local: `curl -sIL http://IP/` (o el dominio) debe dar 200, o 302 a una página que responde 200.
3. Si tienes herramientas de navegador (Playwright, Chrome), abre la URL. Revisa que carguen estilos y JS sin errores en consola. Si el usuario da credenciales (ej. el usuario de los seeds), inicia sesión y navega una o dos páginas.
4. Si algo falla: lee los logs que imprime `verify.sh`, usa la tabla de abajo, corrige y vuelve a desplegar. Repite hasta que todo pase.

**Reporte final para el usuario:**
- La URL.
- Cómo redesplegar: `bundle exec cap production deploy`.
- Dónde están los logs: `/var/www/APP/shared/log/`.
- Qué quedó fuera: SSL si no hubo dominio, procesos de jobs aparte y respaldos de la BD.

## Fase 8 (opcional, con confirmación)

- **SSL** (requiere un dominio que apunte a la IP): `ssh USER@IP "sudo apt-get install -yq certbot python3-certbot-nginx && sudo certbot --nginx -d DOMINIO --non-interactive --agree-tos -m EMAIL --redirect"`. Después activa `FORCE_SSL=true` en `.env` y reinicia Puma.
- **Cerrar el login SSH por contraseña:** solo después de comprobar que `ssh -o BatchMode=yes` funciona para USER y para deploy.
  ```bash
  ssh USER@IP "echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/00-no-password.conf && sudo systemctl reload ssh"
  ```

## Problemas comunes

| Síntoma | Causa y solución |
|---|---|
| `rbenv install` muere con `Killed` | Falta de RAM. El bootstrap agrega swap si no hay; revisa `free -h` y vuelve a correrlo. |
| `Your bundle only supports platforms ...` | `bundle lock --add-platform x86_64-linux` (o `aarch64-linux`), commit y push. |
| `Permission denied (publickey)` al clonar | Falta la deploy key (Fase 4). |
| `linked file .../.env does not exist` | El bootstrap no corrió o `APP` no coincide con `:application`. |
| `PG::ConnectionBad ... password authentication failed` | Las variables del `.env` no coinciden con las que lee `database.yml`. |
| `ArgumentError: Missing secret_key_base` / `InvalidMessage` | Falta `config/master.key` en shared + `linked_files`, o falta `SECRET_KEY_BASE`. |
| Precompilado local falla por `ENV.fetch` | Un initializer exige variables. Pásalas con un valor dummy solo para el precompilado o haz que el initializer tolere su ausencia (pregunta). |
| 502 Bad Gateway | Puma no corre. Revisa `tail shared/log/puma.log` y `systemctl --user status APP_puma`. |
| Redirige a https / `ERR_SSL_PROTOCOL_ERROR` | `force_ssl` sin certificado (Fase 5, paso 6). |
| `Blocked hosts: ...` | Agrega el host a `config.hosts`. |
| Página sin estilos / `/assets/...` 404 | Falta `public/assets` en `linked_dirs`, el rsync no corrió, o Nginx no tiene `root .../current/public`. |
| `systemctl --user`: `Failed to connect to bus` | `sudo loginctl enable-linger deploy` y `export XDG_RUNTIME_DIR=/run/user/$(id -u)`. |
| `db:prepare` falla con `permission denied to create extension` | Corre `sudo -u postgres psql -d <bd> -c 'CREATE EXTENSION <ext>'` una vez. |
