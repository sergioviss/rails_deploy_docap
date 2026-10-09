# rails_deploy_docap

Skill para agentes de IA (Claude Code, Codex, Gemini CLI...) que despliega una app Rails + PostgreSQL
en un Ubuntu limpio (AWS EC2, DigitalOcean) con Capistrano, Puma (systemd) y Nginx, y verifica que quede funcionando.

Lo mecánico está en scripts idempotentes; el agente orquesta, pide datos y corrige errores. Ver [SKILL.md](SKILL.md).

```
SKILL.md              instrucciones por fases (lo que lee el agente)
scripts/detect.sh     local: versiones y necesidades del proyecto
scripts/bootstrap.sh  servidor (root/sudo): usuario deploy, Ruby, PostgreSQL, Nginx, Puma, firewall
scripts/verify.sh     servidor (deploy): Puma, Nginx, assets, BD, migraciones
scripts/ssl.sh        servidor (root/sudo): HTTPS con Let's Encrypt para dominio o IP
templates/            Capfile, config/deploy.rb, config/deploy/production.rb
```

## Instalación

Clona el repo y enlázalo en la carpeta de skills de tu CLI (el nombre del enlace debe ser `rails-cap-deploy`):

```bash
git clone git@github.com:sergioviss/rails_deploy_docap.git ~/rails_deploy_docap
ln -s ~/rails_deploy_docap ~/.claude/skills/rails-cap-deploy    # Claude Code
ln -s ~/rails_deploy_docap ~/.codex/skills/rails-cap-deploy     # Codex (verifica la ruta de skills de tu versión)
```

Si tu CLI no soporta skills, agrega a su archivo de instrucciones (`AGENTS.md`, `GEMINI.md`...):

> Para desplegar una app Rails con Capistrano, sigue `~/rails_deploy_docap/SKILL.md`.

## Uso

Desde la raíz del proyecto Rails: *"despliega esta app en 165.227.86.152, usuario root"*.

Requisitos locales: `git`, `ssh`, `rsync`, Ruby/Bundler del proyecto; opcional `gh` (deploy key automática).
