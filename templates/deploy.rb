lock "~> 3.19"

set :application, "__APP__"
set :repo_url, "__REPO_URL__"
set :branch, ENV.fetch("BRANCH", "__BRANCH__")
set :deploy_to, "/var/www/#{fetch(:application)}"
set :keep_releases, 5

set :rbenv_type, :user
set :rbenv_ruby, File.read(".ruby-version").strip.delete_prefix("ruby-")

# .env vive en el servidor (shared/.env). Agrega aquí los secretos ignorados por git: config/master.key, JSONs, etc.
set :linked_files, %w[.env]
set :linked_dirs, %w[log storage tmp/pids tmp/cache tmp/sockets public/assets]

# Crea las BDs (y corre seeds) en el primer deploy; en los siguientes solo migra. Nunca borra datos.
set :migration_command, "db:prepare"

namespace :deploy do
  desc "Precompila los assets en local; aborta si el código local no es el mismo que se va a desplegar"
  task :precompile_assets_locally do
    branch = fetch(:branch)
    system("git fetch -q origin #{branch}", exception: true)
    unless `git rev-parse HEAD` == `git rev-parse origin/#{branch}` && `git status --porcelain --untracked-files=no`.empty?
      abort "El código local no coincide con origin/#{branch} (o hay cambios sin commit): los assets no corresponderían al deploy."
    end
    # Sin assets:clobber: algunas apps versionan archivos en public/assets y clobber los borraría.
    # Al terminar (con éxito o error) se borra solo lo que generó el precompilado, para que development no sirva assets viejos.
    existed = Dir.exist?("public/assets")
    before = Dir.glob("public/assets/**/*", File::FNM_DOTMATCH)
    at_exit do
      next FileUtils.rm_rf("public/assets") unless existed
      (Dir.glob("public/assets/**/*", File::FNM_DOTMATCH) - before).reject { |p| p.end_with?("/.") }
        .sort.reverse.each { |p| File.directory?(p) ? Dir.rmdir(p) : File.delete(p) }
    end
    system({ "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1" },
           "bin/rails assets:precompile", exception: true)
  end

  desc "Sube public/assets (precompilados + archivos versionados ahí) a shared/public/assets"
  task :upload_assets do
    on roles(:web) do |host|
      system("rsync", "-az", "--chmod=D755,F644", "public/assets/",
             "#{host.user}@#{host.hostname}:#{shared_path}/public/assets/", exception: true)
    end
  end

  before "deploy:starting", "deploy:precompile_assets_locally"
  before "deploy:publishing", "deploy:upload_assets"
end

namespace :puma do
  desc "Reinicia Puma (servicio systemd de usuario creado por bootstrap.sh)"
  task :restart do
    on roles(:app) do
      execute :systemctl, "--user", "restart", "#{fetch(:application)}_puma"
    end
  end
end
after "deploy:publishing", "puma:restart"
