#!/bin/bash
# ============================================================
#  LTM SSH Free — Auto-Installer & Panel
#  Ejecutar como root en Ubuntu 20.04+
# ============================================================
set -euo pipefail

# ── Colores ─────────────────────────────────────────────────
R='\033[0;31m'   G='\033[0;32m'   Y='\033[1;33m'
C='\033[0;36m'   B='\033[0;34m'   W='\033[1;37m'
D='\033[2m'      NC='\033[0m'     BD='\033[1m'

# ── Rutas ────────────────────────────────────────────────────
APP_DIR="/root/ltmssh-web"
SERVERS_JSON="$APP_DIR/servers.json"
ENV_FILE="$APP_DIR/.env"
SVC="ltmssh"
NGINX_CONF="/etc/nginx/sites-available/ltmssh"

# ── Helpers ──────────────────────────────────────────────────
banner() {
  clear
  echo -e "${C}${BD}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║          LTM SSH FREE — PANEL            ║"
  echo "  ╚══════════════════════════════════════════╝${NC}"
  echo ""
}

ok()   { echo -e "  ${G}✔${NC} $1"; }
err()  { echo -e "  ${R}✘ $1${NC}"; }
info() { echo -e "  ${C}→${NC} $1"; }
warn() { echo -e "  ${Y}!${NC} $1"; }
step() { echo -e "\n  ${BD}${W}$1${NC}"; }

ask() {
  # ask "Pregunta" VAR [default]
  local prompt="$1" varname="$2" def="${3:-}"
  local disp=""
  [[ -n "$def" ]] && disp=" ${D}[${def}]${NC}"
  echo -ne "  ${C}?${NC} ${prompt}${disp}: "
  read -r "$varname"
  if [[ -z "${!varname}" && -n "$def" ]]; then
    eval "$varname=\"$def\""
  fi
}

confirm() {
  echo -ne "  ${Y}?${NC} $1 ${D}[s/N]${NC}: "
  read -r _r
  [[ "$_r" =~ ^[sS]$ ]]
}

check_root() {
  [[ $EUID -eq 0 ]] || { err "Ejecutar como root: sudo bash $0"; exit 1; }
}

require_installed() {
  [[ -d "$APP_DIR" && -f "$SERVERS_JSON" ]] || { err "Sistema no instalado. Usa la opción 1."; return 1; }
}

# ── 1. Instalar dependencias ─────────────────────────────────
install_deps() {
  step "Actualizando paquetes…"
  apt-get update -qq

  step "Instalando nginx, certbot, curl, jq…"
  apt-get install -y -qq nginx certbot python3-certbot-nginx curl jq openssl
  ok "nginx, certbot, jq instalados"

  step "Instalando Node.js 18…"
  if ! command -v node &>/dev/null || [[ "$(node -e 'process.stdout.write(process.version.split(".")[0].slice(1))')" -lt 18 ]]; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - &>/dev/null
    apt-get install -y -qq nodejs
  fi
  ok "Node.js $(node --version) · npm $(npm --version)"
}

# ── Escribir server.js ───────────────────────────────────────
write_server_js() {
cat > "$APP_DIR/server.js" << 'SERVEREOF'
require('dotenv').config();
const express = require('express');
const fs      = require('fs');
const path    = require('path');
const { Client } = require('ssh2');

const app  = express();
const PORT = process.env.PORT || 4000;
const DB   = path.join(__dirname, 'db.json');
const SRV  = path.join(__dirname, 'servers.json');

function loadServers() {
  try { return JSON.parse(fs.readFileSync(SRV, 'utf8')); }
  catch { return []; }
}

function leerDB()  { try { return JSON.parse(fs.readFileSync(DB,'utf8')); } catch { return {accounts:[]}; } }
function saveDB(d) { fs.writeFileSync(DB, JSON.stringify(d, null, 2)); }

function activasPorServidor(id) {
  const now = Date.now();
  return leerDB().accounts.filter(a => a.serverId===id && a.expiresAt>now).length;
}

app.use(express.json({ limit: '4kb' }));
app.get('/', (_, res) => res.sendFile(path.join(__dirname,'index.html')));
app.get('/health', (_, res) => res.json({ ok: true, ts: new Date().toISOString() }));

app.get('/api/servers', (_, res) => {
  const servers = loadServers();
  res.json(servers.map(s => ({
    id: s.id, name: s.name, location: s.location, flag: s.flag,
    ports: s.ports, maxAccounts: s.maxAccounts,
    accountsUsed: activasPorServidor(s.id)
  })));
});

// Acepta /create-user y /api/create-account con ambos formatos de cuerpo
async function handleCreate(req, res) {
  const { serverId, username, nombreElegido, password } = req.body;
  const user   = (username || nombreElegido || '').trim();
  const srvId  = (serverId || '').trim();
  const servers = loadServers();
  const server  = servers.find(s => s.id === srvId);

  if (!server) return res.status(400).json({ error: 'Servidor no encontrado' });
  if (!/^[a-zA-Z0-9_]{3,20}$/.test(user))
    return res.status(400).json({ error: 'Usuario: 3-20 caracteres, letras, números y _' });
  if (!password || password.length < 8 || password.length > 32 || password.includes(':'))
    return res.status(400).json({ error: 'Contraseña inválida (8-32 chars, sin dos puntos)' });

  const usados = activasPorServidor(srvId);
  if (usados >= server.maxAccounts)
    return res.status(429).json({ error: 'Servidor lleno' });

  const sysUser = 'ltmssh-' + user;
  const db = leerDB();
  if (db.accounts.some(a => a.serverId===srvId && a.username===sysUser && a.expiresAt>Date.now()))
    return res.status(409).json({ error: 'Nombre de usuario ya en uso' });

  // Crear usuario en VPS remota vía SSH
  const pass = process.env[server.sshPassEnv];
  if (!pass) return res.status(500).json({ error: 'Credencial del servidor no configurada' });

  try {
    await new Promise((resolve, reject) => {
      const conn = new Client();
      const timer = setTimeout(() => { conn.end(); reject(new Error('Timeout')); }, 25000);
      conn.on('ready', () => {
        const cmd = `useradd -M -N -s /usr/sbin/nologin -e $(date -d "+7 days" +%Y-%m-%d) ${sysUser} && chpasswd`;
        conn.exec(cmd, (err, stream) => {
          if (err) { clearTimeout(timer); conn.end(); return reject(err); }
          let se = '';
          stream.on('data', ()=>{});
          stream.stderr.on('data', d => se += d.toString());
          stream.on('close', code => {
            clearTimeout(timer); conn.end();
            code !== 0 ? reject(new Error(se.trim() || 'Error al crear usuario')) : resolve();
          });
          stream.end(`${sysUser}:${password}\n`);
        });
      }).on('error', e => { clearTimeout(timer); reject(e); })
        .connect({ host: server.host, port: 22, username: server.sshUser || 'root', password: pass, readyTimeout: 20000 });
    });

    const expiresAt = Date.now() + 7*24*60*60*1000;
    db.accounts.push({ serverId: srvId, username: sysUser, createdAt: Date.now(), expiresAt });
    saveDB(db);

    res.json({
      username: sysUser, password,
      host: server.host,
      ports: server.ports,
      expiresAt,
      serverName: server.name
    });
  } catch(e) {
    res.status(500).json({ error: 'Error creando cuenta: ' + e.message });
  }
}

app.post('/create-user', handleCreate);
app.post('/api/create-account', handleCreate);

app.listen(PORT, '0.0.0.0', () => console.log(`LTM SSH corriendo en :${PORT}`));
SERVEREOF
  ok "server.js escrito"
}

# ── Instalar npm packages ─────────────────────────────────────
install_npm() {
  step "Instalando dependencias npm…"
  cd "$APP_DIR"
  # package.json mínimo
  cat > package.json << 'EOF'
{
  "name": "ltmssh-web",
  "version": "2.1.0",
  "private": true,
  "main": "server.js",
  "dependencies": {
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "ssh2": "^1.15.0",
    "uuid": "^9.0.1"
  }
}
EOF
  npm install --silent
  ok "Paquetes instalados"
}

# ── Nginx ─────────────────────────────────────────────────────
write_nginx() {
  local domain="$1"
  cat > "$NGINX_CONF" << NGEOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${domain};

    ssl_certificate     /etc/nginx/ssl/ltmssh.crt;
    ssl_certificate_key /etc/nginx/ssl/ltmssh.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    server_tokens off;
    client_max_body_size 8k;

    if (\$http_user_agent ~* (nmap|nikto|sqlmap|masscan|zgrab)) { return 444; }
    if (\$request_method !~ ^(GET|POST|HEAD)\$) { return 405; }

    # Zona rate limit para creación de cuentas
    limit_req_zone \$http_cf_connecting_ip zone=ltmssh_create:10m rate=5r/m;

    location / {
        proxy_pass         http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$http_cf_connecting_ip;
        proxy_set_header   X-Forwarded-For \$http_cf_connecting_ip;
        proxy_read_timeout 3600s;
        add_header         Cache-Control "no-store" always;
    }

    location /api/ {
        proxy_pass       http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        add_header       Cache-Control "no-store, no-cache, must-revalidate" always;
    }

    location /create-user {
        limit_req        zone=ltmssh_create burst=3 nodelay;
        limit_req_status 429;
        proxy_pass       http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$http_cf_connecting_ip;
    }

    location ~ /\\.      { deny all; return 404; }
    location ~ \\.(env|log|sh|py)\$ { deny all; return 404; }
}
NGEOF
  ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/ltmssh 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
}

setup_ssl() {
  local domain="$1"
  step "Configurando SSL…"
  mkdir -p /etc/nginx/ssl

  if confirm "¿Obtener certificado real con Let's Encrypt para ${domain}?"; then
    nginx -s stop 2>/dev/null || true
    certbot certonly --standalone -d "$domain" --non-interactive --agree-tos -m "admin@${domain}" 2>&1 | tail -5
    ln -sf "/etc/letsencrypt/live/${domain}/fullchain.pem" /etc/nginx/ssl/ltmssh.crt
    ln -sf "/etc/letsencrypt/live/${domain}/privkey.pem"   /etc/nginx/ssl/ltmssh.key
    # Auto-renovación
    echo "0 3 * * * root certbot renew --quiet" > /etc/cron.d/certbot-ltmssh
    ok "Certificado Let's Encrypt instalado"
  else
    info "Generando certificado auto-firmado…"
    openssl req -x509 -newkey rsa:4096 -keyout /etc/nginx/ssl/ltmssh.key \
      -out /etc/nginx/ssl/ltmssh.crt -days 3650 -nodes \
      -subj "/CN=${domain}" 2>/dev/null
    ok "Certificado auto-firmado generado (válido 10 años)"
  fi
}

# ── systemd service ───────────────────────────────────────────
write_service() {
  cat > "/etc/systemd/system/${SVC}.service" << EOF
[Unit]
Description=LTM SSH Free Web Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/node server.js
EnvironmentFile=${ENV_FILE}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SVC" --quiet
  ok "Servicio systemd configurado"
}

# ── 2. Instalación completa ───────────────────────────────────
install_all() {
  banner
  echo -e "  ${BD}Instalación completa de LTM SSH Free${NC}\n"

  ask "Dominio del panel (ej: ltmssh.midominio.com)" DOMAIN
  [[ -z "$DOMAIN" ]] && { err "Dominio requerido"; return 1; }

  echo ""
  step "Configurando primer servidor SSH"
  ask "IP del servidor VPS" VPS_HOST
  ask "Contraseña SSH root del VPS" VPS_PASS
  ask "Nombre del servidor (ej: LTM-01)"  VPS_NAME "LTM-01"
  ask "Máximo de cuentas" VPS_MAX "50"

  install_deps

  step "Creando directorio ${APP_DIR}…"
  mkdir -p "$APP_DIR"
  ok "Directorio listo"

  step "Escribiendo servers.json…"
  cat > "$SERVERS_JSON" << EOF
[
  {
    "id": "vps1",
    "name": "${VPS_NAME}",
    "location": "Estados Unidos",
    "flag": "🇺🇸",
    "host": "${VPS_HOST}",
    "sshUser": "root",
    "sshPassEnv": "VPS1_PASS",
    "ports": { "nonTls": [22, 80, 8080], "tls": [443, 8443] },
    "maxAccounts": ${VPS_MAX}
  }
]
EOF
  ok "servers.json creado"

  step "Escribiendo .env…"
  cat > "$ENV_FILE" << EOF
PORT=4000
VPS1_PASS=${VPS_PASS}
EOF
  chmod 600 "$ENV_FILE"
  ok ".env creado (permisos 600)"

  write_server_js
  install_npm

  step "Descargando interfaz web…"
  curl -fsSL "https://${DOMAIN}/index.html" -o "$APP_DIR/index.html" 2>/dev/null || \
    warn "No se pudo descargar index.html (el dominio aún no resuelve). Cópialo manualmente en ${APP_DIR}/index.html"

  setup_ssl "$DOMAIN"
  write_nginx "$DOMAIN"

  step "Validando nginx…"
  nginx -t && nginx -s reload 2>/dev/null || nginx
  ok "nginx activo"

  write_service

  step "Configurando watchdog…"
  setup_watchdog

  step "Iniciando servicio…"
  systemctl restart "$SVC"
  sleep 2
  if systemctl is-active --quiet "$SVC"; then
    ok "Servicio ${SVC} corriendo"
  else
    err "El servicio no inició. Revisa: journalctl -u ${SVC} -n 30"
  fi

  echo ""
  echo -e "  ${G}${BD}═══════════════════════════════════════${NC}"
  echo -e "  ${G}  Instalación completada${NC}"
  echo -e "  ${W}  Panel:${NC} https://${DOMAIN}"
  echo -e "  ${W}  App dir:${NC} ${APP_DIR}"
  echo -e "  ${W}  Logs:${NC} journalctl -u ${SVC} -f"
  echo -e "  ${G}${BD}═══════════════════════════════════════${NC}"
  echo ""
  read -rp "  Presiona Enter para continuar…"
}

# ── 3. Gestionar VPS ─────────────────────────────────────────
list_vps() {
  require_installed || return 1
  echo ""
  echo -e "  ${BD}Servidores configurados:${NC}\n"
  local i=0
  while read -r srv; do
    i=$((i+1))
    local id name host max
    id=$(echo "$srv" | jq -r '.id')
    name=$(echo "$srv" | jq -r '.name')
    host=$(echo "$srv" | jq -r '.host')
    max=$(echo "$srv" | jq -r '.maxAccounts')
    echo -e "  ${C}${i}.${NC} ${BD}${name}${NC}  ${D}(${id})${NC}  →  ${host}  max: ${max}"
  done < <(jq -c '.[]' "$SERVERS_JSON")
  echo ""
}

add_vps() {
  require_installed || return 1
  banner
  echo -e "  ${BD}Agregar servidor VPS${NC}\n"

  local count
  count=$(jq 'length' "$SERVERS_JSON")
  local new_id="vps$((count+1))"
  local env_key="VPS$((count+1))_PASS"

  ask "ID del servidor (ej: ${new_id})" VPS_ID "$new_id"
  ask "Nombre visible (ej: LTM-0$((count+1)))"   VPS_NAME "LTM-0$((count+1))"
  ask "IP del servidor"                           VPS_HOST
  ask "Contraseña SSH root"                       VPS_PASS
  ask "Ubicación (ej: Estados Unidos)"            VPS_LOC  "Estados Unidos"
  ask "Máximo de cuentas"                         VPS_MAX  "50"

  [[ -z "$VPS_HOST" || -z "$VPS_PASS" ]] && { err "IP y contraseña requeridos"; return 1; }

  # Agregar al JSON
  local env_key_name="VPS${VPS_ID^^}_PASS"
  env_key_name="$(echo "${VPS_ID}" | tr '[:lower:]' '[:upper:]')_PASS"

  jq --arg id    "$VPS_ID" \
     --arg name  "$VPS_NAME" \
     --arg host  "$VPS_HOST" \
     --arg loc   "$VPS_LOC" \
     --arg env   "${env_key_name}" \
     --argjson max "$VPS_MAX" \
     '. + [{
       "id": $id, "name": $name, "location": $loc, "flag": "🇺🇸",
       "host": $host, "sshUser": "root", "sshPassEnv": $env,
       "ports": {"nonTls":[22,80,8080],"tls":[443,8443]},
       "maxAccounts": $max
     }]' "$SERVERS_JSON" > /tmp/srv_tmp.json && mv /tmp/srv_tmp.json "$SERVERS_JSON"

  # Agregar contraseña al .env
  echo "${env_key_name}=${VPS_PASS}" >> "$ENV_FILE"

  systemctl restart "$SVC" 2>/dev/null && ok "Servidor ${VPS_NAME} agregado y servicio reiniciado" || err "Reinicia manualmente: systemctl restart ${SVC}"
  read -rp "  Presiona Enter…"
}

remove_vps() {
  require_installed || return 1
  banner
  echo -e "  ${BD}Eliminar servidor VPS${NC}\n"
  list_vps

  ask "ID del servidor a eliminar" DEL_ID
  [[ -z "$DEL_ID" ]] && return

  local exists
  exists=$(jq --arg id "$DEL_ID" 'map(select(.id==$id)) | length' "$SERVERS_JSON")
  [[ "$exists" -eq 0 ]] && { err "ID no encontrado"; return 1; }

  confirm "¿Eliminar servidor ${DEL_ID}?" || return

  jq --arg id "$DEL_ID" 'map(select(.id!=$id))' "$SERVERS_JSON" > /tmp/srv_tmp.json \
    && mv /tmp/srv_tmp.json "$SERVERS_JSON"

  systemctl restart "$SVC" 2>/dev/null
  ok "Servidor ${DEL_ID} eliminado"
  read -rp "  Presiona Enter…"
}

manage_vps_menu() {
  while true; do
    banner
    echo -e "  ${BD}Gestionar VPS${NC}\n"
    echo -e "  ${C}1.${NC} Ver servidores actuales"
    echo -e "  ${C}2.${NC} Agregar servidor VPS"
    echo -e "  ${C}3.${NC} Eliminar servidor VPS"
    echo -e "  ${C}0.${NC} Volver\n"
    ask "Opción" OPT "0"
    case "$OPT" in
      1) list_vps; read -rp "  Presiona Enter…" ;;
      2) add_vps ;;
      3) remove_vps ;;
      0) return ;;
    esac
  done
}

# ── 4. Instalar protocolos SSH ────────────────────────────────
install_protocols() {
  banner
  echo -e "  ${BD}Instalar protocolos SSH (BadVPN, HTTP Tunnel, etc.)${NC}\n"
  info "Script: github.com/DarkFull0726/SSHSCRIPT-LTM"
  echo ""
  if confirm "¿Instalar protocolos SSH ahora?"; then
    wget -q -O /usr/local/bin/menu \
      "https://raw.githubusercontent.com/DarkFull0726/SSHSCRIPT-LTM/main/sshscript-ltm.sh" \
      && chmod +x /usr/local/bin/menu \
      && ok "Script instalado como comando 'menu'" \
      && echo "" \
      && menu
  fi
}

# ── 5. Estado del sistema ─────────────────────────────────────
show_status() {
  banner
  echo -e "  ${BD}Estado del sistema${NC}\n"

  # Servicio
  if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    echo -e "  ${G}●${NC} Servicio ${SVC}: ${G}activo${NC}"
  else
    echo -e "  ${R}●${NC} Servicio ${SVC}: ${R}inactivo${NC}"
  fi

  # nginx
  if systemctl is-active --quiet nginx 2>/dev/null; then
    echo -e "  ${G}●${NC} nginx: ${G}activo${NC}"
  else
    echo -e "  ${R}●${NC} nginx: ${R}inactivo${NC}"
  fi

  # Cuentas
  if [[ -f "$APP_DIR/db.json" ]]; then
    local total activas
    total=$(jq '.accounts | length' "$APP_DIR/db.json" 2>/dev/null || echo 0)
    activas=$(jq --argjson now "$(date +%s)000" '[.accounts[] | select(.expiresAt > $now)] | length' "$APP_DIR/db.json" 2>/dev/null || echo 0)
    echo -e "\n  ${BD}Cuentas SSH:${NC}"
    echo -e "  Activas: ${G}${activas}${NC}  ·  Total creadas: ${W}${total}${NC}"
  fi

  # VPS
  if [[ -f "$SERVERS_JSON" ]]; then
    echo -e "\n  ${BD}Servidores:${NC}"
    jq -r '.[] | "  \(.name)  \(.host)  max:\(.maxAccounts)"' "$SERVERS_JSON" 2>/dev/null | \
      while read -r line; do echo -e "  ${C}▸${NC} $line"; done
  fi

  echo ""
  echo -e "  ${D}Logs recientes:${NC}"
  journalctl -u "$SVC" -n 8 --no-pager 2>/dev/null | sed 's/^/  /' || true

  echo ""
  read -rp "  Presiona Enter…"
}

# ── 6. Actualizar web ─────────────────────────────────────────
update_web() {
  require_installed || return 1
  banner
  echo -e "  ${BD}Actualizar interfaz web${NC}\n"

  local domain
  domain=$(grep -oP 'server_name \K[^;]+' "$NGINX_CONF" 2>/dev/null | head -1 || echo "")

  info "Copia el nuevo index.html a ${APP_DIR}/index.html"
  info "O pega aquí la URL para descargarlo:"
  echo -ne "  ${C}?${NC} URL (Enter para omitir): "
  read -r WEB_URL
  if [[ -n "$WEB_URL" ]]; then
    curl -fsSL "$WEB_URL" -o "$APP_DIR/index.html" && ok "index.html actualizado"
  fi

  systemctl restart "$SVC" 2>/dev/null
  ok "Servicio reiniciado"
  read -rp "  Presiona Enter…"
}

# ── 7. Desinstalar ────────────────────────────────────────────
uninstall() {
  banner
  echo -e "  ${R}${BD}DESINSTALAR LTM SSH FREE${NC}\n"
  warn "Esto eliminará el servicio, archivos y config nginx."
  confirm "¿Seguro que deseas desinstalar?" || return

  systemctl stop    "$SVC" 2>/dev/null || true
  systemctl disable "$SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SVC}.service"
  systemctl daemon-reload
  rm -rf "$APP_DIR"
  rm -f "$NGINX_CONF" "/etc/nginx/sites-enabled/ltmssh"
  nginx -s reload 2>/dev/null || true
  ok "Desinstalado"
  read -rp "  Presiona Enter…"
}

# ── Watchdog ─────────────────────────────────────────────────
setup_watchdog() {
  local WDOG="/root/ltmssh-watchdog.sh"
  cat > "$WDOG" << 'WDEOF'
#!/bin/bash
# LTM SSH Watchdog — revisar cada 3 min vía cron
LOG="/var/log/ltmssh-watchdog.log"
TS="$(date '+%Y-%m-%d %H:%M:%S')"

restart_if_dead() {
  local svc="$1"
  if ! systemctl is-active --quiet "$svc"; then
    echo "[$TS] $svc caído — reiniciando..." >> "$LOG"
    systemctl start "$svc"
    sleep 3
    if systemctl is-active --quiet "$svc"; then
      echo "[$TS] $svc OK" >> "$LOG"
    else
      echo "[$TS] $svc FALLO al reiniciar" >> "$LOG"
    fi
  fi
}

restart_if_dead ltmssh
restart_if_dead nginx

# Mantener log bajo 500 líneas
tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
WDEOF
  chmod +x "$WDOG"

  # Cron cada 3 minutos
  local cron_line="*/3 * * * * root $WDOG"
  local cron_file="/etc/cron.d/ltmssh-watchdog"
  echo "$cron_line" > "$cron_file"
  chmod 644 "$cron_file"

  ok "Watchdog instalado (corre cada 3 min)"
  ok "Logs: /var/log/ltmssh-watchdog.log"
}

# ── Menú principal ────────────────────────────────────────────
main_menu() {
  check_root
  while true; do
    banner
    local status_svc="${R}inactivo${NC}"
    systemctl is-active --quiet "$SVC" 2>/dev/null && status_svc="${G}activo${NC}"

    echo -e "  ${D}Servicio: ${status_svc}\n"
    echo -e "  ${C}1.${NC} ${BD}Instalación completa${NC}  ${D}(instala todo desde cero)${NC}"
    echo -e "  ${C}2.${NC} ${BD}Gestionar VPS${NC}          ${D}(agregar / eliminar servidores)${NC}"
    echo -e "  ${C}3.${NC} ${BD}Instalar protocolos SSH${NC} ${D}(BadVPN, HTTP Tunnel, etc.)${NC}"
    echo -e "  ${C}4.${NC} ${BD}Estado del sistema${NC}      ${D}(logs, cuentas, VPS)${NC}"
    echo -e "  ${C}5.${NC} ${BD}Actualizar web${NC}          ${D}(subir nuevo index.html)${NC}"
    echo -e "  ${C}6.${NC} ${BD}Desinstalar${NC}"
    echo -e "  ${C}0.${NC} Salir\n"
    ask "Opción" OPT "0"

    case "$OPT" in
      1) install_all ;;
      2) manage_vps_menu ;;
      3) install_protocols ;;
      4) show_status ;;
      5) update_web ;;
      6) uninstall ;;
      0) echo ""; exit 0 ;;
      *) warn "Opción inválida" ;;
    esac
  done
}

main_menu
