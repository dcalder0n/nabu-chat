#!/usr/bin/env bash
# install.sh — NABU chat one-liner installer para empleados NABU Holdings
#
# Uso (empleado):
#   curl -fsSL https://raw.githubusercontent.com/dcalder0n/nabu-chat/main/install.sh | bash
#
# Uso con datos (Daniel):
#   NABU_USER_EMAIL=... NABU_USER_NAME=... NABU_USER_EMPRESA=... NABU_USER_ROLE=... \
#   NABU_WAGENT_NAME=<nombre-en-el-registry> INTERNAL_SVC_TOKEN=... [CLAUDE_CODE_OAUTH_TOKEN=...] \
#   bash install.sh
#   (NABU_USER_ROL se acepta como sinónimo de NABU_USER_ROLE)
#
# Qué hace:
#   1. Verifica Claude Code + jq + curl + git
#   2. Clona/actualiza ~/nabu-chat
#   3. Pide email + nombre + empresa + rol + nombre del agente → user.json (con wagent_name)
#   4. Guarda credenciales en ~/.nabu-config (chmod 600, FUERA del repo)
#   5. Prueba la bandeja del agente (GET /api/handoffs/inbox/<wagent>): solo 200 es OK
#   6. Te dice cómo arrancar conversación
#
# El wagent_name sale del registry de agentes (te lo da Daniel); NUNCA se deriva del email.
# Ya no se usa ANTHROPIC_API_KEY (suscripción del equipo desde el 20-oct-2026) ni Supabase.

set -e

GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
GRAY="\033[0;90m"
BOLD="\033[1m"
NC="\033[0m"

REPO_URL="https://github.com/dcalder0n/nabu-chat.git"
TARGET_DIR="${HOME}/nabu-chat"
HOME_CONFIG="${HOME}/.nabu-config"

NABU_USER_ROLE="${NABU_USER_ROLE:-$NABU_USER_ROL}"
NABU_USER_ROL="$NABU_USER_ROLE"

# Con `curl | bash` el stdin es el script: las preguntas se leen de la terminal.
preguntar() {  # preguntar "texto" VAR
  local resp=""
  if [ -r /dev/tty ]; then read -r -p "$1" resp < /dev/tty || true; else read -r -p "$1" resp || true; fi
  printf -v "$2" '%s' "$resp"
}

wagent_valido() { case "$1" in ''|*[!a-z0-9-]*) return 1 ;; *) return 0 ;; esac; }

# Credenciales SIEMPRE en ~/.nabu-config (600). Se reemplazan solo las variables que traen valor.
guardar_config_home() {
  local C="$HOME_CONFIG" TMP var pat=""
  for var in "$@"; do [ -n "${!var}" ] && pat="${pat:+$pat|}$var"; done
  [ -n "$pat" ] || return 0
  TMP=$(umask 077; mktemp "${HOME}/.nabu-config.XXXXXX")
  if [ -f "$C" ]; then
    grep -v -E "^(export )?(${pat})=|^# actualizado por " "$C" > "$TMP" || true
  else
    echo "# NABU empleado — credenciales (chmod 600). NO va en el repo ni en el chat." > "$TMP"
  fi
  echo "# actualizado por install.sh $(date '+%Y-%m-%d %H:%M')" >> "$TMP"
  for var in "$@"; do
    [ -n "${!var}" ] && printf 'export %s="%s"\n' "$var" "${!var}" >> "$TMP"
  done
  chmod 600 "$TMP"
  mv "$TMP" "$C"
}

clear 2>/dev/null || true
echo
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║  NABU Chat — instalación                 ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
echo
echo -e "${GRAY}Tu interfaz al ecosistema NABU Holdings.${NC}"
echo

# ─── 1. Dependencies ──────────────────────────────────────────────────────────

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $1"
    return 0
  else
    echo -e "  ${RED}✗${NC} $1 ${GRAY}(falta)${NC}"
    return 1
  fi
}

echo -e "${BOLD}Verificando dependencias${NC}"
MISSING=0
check_cmd claude || { MISSING=1; echo -e "    ${GRAY}→ Instalá: brew install --cask claude-code${NC}"; }
check_cmd jq     || { MISSING=1; echo -e "    ${GRAY}→ Instalá: brew install jq${NC}"; }
check_cmd curl   || MISSING=1
check_cmd git    || MISSING=1

if [ "$MISSING" = "1" ]; then
  echo
  echo -e "${RED}Falta(n) dependencia(s). Instalalas y reintentá.${NC}"
  exit 1
fi
echo

# ─── 2. Clone or update repo ──────────────────────────────────────────────────

echo -e "${BOLD}Descargando NABU chat${NC}"
if [ -d "$TARGET_DIR/.git" ]; then
  echo -e "  ${GRAY}~/nabu-chat ya existe — actualizando${NC}"
  cd "$TARGET_DIR"
  # Migración: instalaciones viejas guardaban la clave en el .nabu-config del repo (trackeado).
  # Antes de descartar cambios locales, la rescatamos a ~/.nabu-config si ahí todavía no está.
  if [ -z "$INTERNAL_SVC_TOKEN" ] && ! grep -q -E '^(export )?INTERNAL_SVC_TOKEN=.+' "$HOME_CONFIG" 2>/dev/null \
     && grep -q -E '^export INTERNAL_SVC_TOKEN=.+' .nabu-config 2>/dev/null; then
    INTERNAL_SVC_TOKEN=$(bash -c 'source ./.nabu-config >/dev/null 2>&1; printf %s "$INTERNAL_SVC_TOKEN"')
    [ -n "$INTERNAL_SVC_TOKEN" ] && guardar_config_home INTERNAL_SVC_TOKEN \
      && echo -e "  ${GREEN}✓${NC} clave rescatada del .nabu-config viejo → ~/.nabu-config"
  fi
  # Descartar cambios locales: el .nabu-config del repo es solo plantilla (las credenciales van en ~/.nabu-config)
  git checkout -- . 2>/dev/null || true
  git pull --quiet origin main 2>/dev/null || git pull origin main
else
  if [ -d "$TARGET_DIR" ]; then
    echo -e "  ${YELLOW}⚠ ~/nabu-chat existe pero NO es git repo. Movido a ~/nabu-chat.bak${NC}"
    mv "$TARGET_DIR" "${TARGET_DIR}.bak.$(date +%s)"
  fi
  git clone --quiet "$REPO_URL" "$TARGET_DIR"
fi
cd "$TARGET_DIR"
echo -e "  ${GREEN}✓${NC} Descargado a ~/nabu-chat"
echo

# ─── 3. User config ───────────────────────────────────────────────────────────

if [ -n "$NABU_WAGENT_NAME" ] && ! wagent_valido "$NABU_WAGENT_NAME"; then
  echo -e "${RED}✗ NABU_WAGENT_NAME inválido: solo minúsculas, números y guiones (ej: abby-wagent)${NC}"
  exit 1
fi
# Si vienen TODAS las env vars NABU_USER_* + NABU_WAGENT_NAME, SIEMPRE sobreescribir user.json
if [ -n "$NABU_USER_EMAIL" ] && [ -n "$NABU_USER_NAME" ] && [ -n "$NABU_USER_EMPRESA" ] && [ -n "$NABU_USER_ROLE" ] && [ -n "$NABU_WAGENT_NAME" ]; then
  EMAIL="$NABU_USER_EMAIL"
  NAME="$NABU_USER_NAME"
  EMPRESA="$NABU_USER_EMPRESA"
  ROLE="$NABU_USER_ROLE"
  WAGENT="$NABU_WAGENT_NAME"
  echo -e "${BOLD}Datos del empleado${NC} ${GREEN}(auto-config desde comando)${NC}"
  echo -e "  $NAME · $EMAIL · $EMPRESA · $ROLE · $WAGENT"
  cat > user.json <<EOF2
{
  "wagent_name": "$WAGENT",
  "email": "$EMAIL",
  "display_name": "$NAME",
  "empresa": "$EMPRESA",
  "role": "$ROLE",
  "configured_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF2
  chmod 600 user.json
elif [ ! -f user.json ]; then
  # Interactivo: se pregunta solo lo que no vino por env vars
  echo -e "${BOLD}Datos del empleado${NC}"
  echo -e "${GRAY}(Solo se guarda local en tu Mac, no se sube a NABU sin handoff explícito)${NC}"
  echo
  EMAIL="$NABU_USER_EMAIL"; NAME="$NABU_USER_NAME"; EMPRESA="$NABU_USER_EMPRESA"; ROLE="$NABU_USER_ROLE"
  WAGENT="$NABU_WAGENT_NAME"
  [ -n "$EMAIL" ] || preguntar "  Email NABU Workspace (ej: alejandra@vencor.com): " EMAIL
  [ -n "$NAME" ]  || preguntar "  Nombre completo: " NAME
  if [ -z "$EMPRESA" ]; then
    echo "  Empresa principal:"
    echo "    1) Ventamatic"
    echo "    2) BZL Media"
    echo "    3) Vencor"
    echo "    4) Julia Bakery"
    echo "    5) Nabu Holdings"
    preguntar "  Tu opción (1-5): " EMPRESA_NUM
    case "$EMPRESA_NUM" in
      1) EMPRESA="Ventamatic" ;;
      2) EMPRESA="BZL Media" ;;
      3) EMPRESA="Vencor" ;;
      4) EMPRESA="Julia Bakery" ;;
      5) EMPRESA="Nabu Holdings" ;;
      *) EMPRESA="$EMPRESA_NUM" ;;
    esac
  fi
  [ -n "$ROLE" ] || preguntar "  Rol (ej: ventas, contabilidad, diseño, ops, gerente): " ROLE
  INTENTOS=0
  while ! wagent_valido "$WAGENT" && [ "$INTENTOS" -lt 3 ]; do
    INTENTOS=$((INTENTOS + 1))
    preguntar "  Nombre de tu agente (ej: abby-wagent; te lo da Daniel): " WAGENT
  done
  if ! wagent_valido "$WAGENT"; then
    echo -e "  ${RED}✗${NC} Falta el nombre del agente (NABU_WAGENT_NAME). Pedíselo a Daniel."
    exit 1
  fi

  cat > user.json <<EOF
{
  "wagent_name": "$WAGENT",
  "email": "$EMAIL",
  "display_name": "$NAME",
  "empresa": "$EMPRESA",
  "role": "$ROLE",
  "configured_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
  chmod 600 user.json
  echo
  echo -e "  ${GREEN}✓${NC} user.json creado"
else
  EMAIL=$(jq -r .email user.json)
  NAME=$(jq -r .display_name user.json)
  WAGENT=$(jq -r '.wagent_name // empty' user.json)
  if [ -n "$NABU_WAGENT_NAME" ] && [ "$NABU_WAGENT_NAME" != "$WAGENT" ]; then
    # Agregar/corregir wagent_name sin tocar el resto de user.json
    jq --arg w "$NABU_WAGENT_NAME" '.wagent_name = $w' user.json > user.json.nuevo && mv user.json.nuevo user.json
    chmod 600 user.json
    WAGENT="$NABU_WAGENT_NAME"
    echo -e "  ${GREEN}✓${NC} user.json: wagent_name = $WAGENT"
  fi
  echo -e "${GRAY}user.json ya existe — usando datos de $NAME ($EMAIL, agente: ${WAGENT:-<falta>})${NC}"
fi
echo

# ─── 4. Credenciales → ~/.nabu-config (fuera del repo) ─────────────────────────

echo -e "${BOLD}Credenciales${NC}"
chmod +x "$TARGET_DIR/nabu" 2>/dev/null || true

NABU_WAGENT_NAME="${WAGENT:-$NABU_WAGENT_NAME}"
if [ -n "$INTERNAL_SVC_TOKEN" ]; then
  NABU_API_URL="${NABU_API_URL:-https://api.calderon.coffee}"
  guardar_config_home NABU_API_URL INTERNAL_SVC_TOKEN NABU_WAGENT_NAME CLAUDE_CODE_OAUTH_TOKEN
  echo -e "  ${GREEN}✓${NC} ~/.nabu-config (chmod 600): INTERNAL_SVC_TOKEN, NABU_API_URL, NABU_WAGENT_NAME${CLAUDE_CODE_OAUTH_TOKEN:+, CLAUDE_CODE_OAUTH_TOKEN}"
else
  guardar_config_home NABU_WAGENT_NAME CLAUDE_CODE_OAUTH_TOKEN
  if ! grep -q -E '^(export )?INTERNAL_SVC_TOKEN=.+' "$HOME_CONFIG" 2>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} Falta INTERNAL_SVC_TOKEN en ~/.nabu-config"
    echo -e "  ${GRAY}  Pedíselo a Daniel en privado y volvé a correr con INTERNAL_SVC_TOKEN=... (no lo pegues en el chat)${NC}"
  else
    echo -e "  ${GREEN}✓${NC} ~/.nabu-config ya tiene INTERNAL_SVC_TOKEN"
  fi
fi
echo

# ─── 5. Prueba de conexión: bandeja del agente ────────────────────────────────
# Llega al bus a través del portero → valida clave + wagent_name + bus. SOLO 200 es OK.

echo -e "${BOLD}Probando conexión con NABU${NC}"
[ -f .nabu-config ] && source .nabu-config
[ -f "$HOME_CONFIG" ] && source "$HOME_CONFIG"
WAGENT="${WAGENT:-$NABU_WAGENT_NAME}"
NABU_API_URL="${NABU_API_URL:-https://api.calderon.coffee}"
CONEXION_OK=0
if [ -z "$INTERNAL_SVC_TOKEN" ] || [ -z "$WAGENT" ]; then
  [ -z "$INTERNAL_SVC_TOKEN" ] && echo -e "  ${RED}✗${NC} No se puede probar: falta INTERNAL_SVC_TOKEN en ~/.nabu-config"
  [ -z "$WAGENT" ] && echo -e "  ${RED}✗${NC} No se puede probar: falta wagent_name en user.json"
else
  STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$INTERNAL_SVC_TOKEN" \
    | curl -s -o /dev/null -w "%{http_code}" -m 8 -K - "${NABU_API_URL}/api/handoffs/inbox/${WAGENT}" 2>/dev/null) || true
  STATUS="${STATUS:-000}"
  case "$STATUS" in
    200) CONEXION_OK=1; echo -e "  ${GREEN}✓${NC} bandeja de ${WAGENT}: HTTP 200 (clave, agente y bus OK)" ;;
    401|403) echo -e "  ${RED}✗${NC} HTTP $STATUS: la clave INTERNAL_SVC_TOKEN es incorrecta — pedile a Daniel la correcta" ;;
    404) echo -e "  ${RED}✗${NC} HTTP 404: el agente '${WAGENT}' no existe en el registry — confirmá el nombre con Daniel" ;;
    000) echo -e "  ${RED}✗${NC} sin conexión a ${NABU_API_URL} (internet, URL o túnel caído)" ;;
    5*)  echo -e "  ${RED}✗${NC} HTTP $STATUS: el bus de NABU está caído o el túnel falla — avisale a Daniel" ;;
    *)   echo -e "  ${RED}✗${NC} HTTP $STATUS: respuesta inesperada de ${NABU_API_URL}" ;;
  esac
fi
echo

# ─── 7. Done ──────────────────────────────────────────────────────────────────

if [ "$CONEXION_OK" = "1" ]; then
  echo -e "${BOLD}${GREEN}Instalación completa.${NC}"
else
  echo -e "${BOLD}${YELLOW}Instalación hecha, pero la conexión con NABU NO quedó probada (ver arriba).${NC}"
  echo -e "${GRAY}El chat no va a poder abrir pedidos hasta que la prueba dé 200.${NC}"
fi
echo
echo -e "${BOLD}Para arrancar conversación con tu asistente NABU:${NC}"
echo
echo -e "  ${BOLD}~/nabu-chat/nabu${NC}"
echo
echo -e "${GRAY}(El wrapper ./nabu carga las credenciales auto + arranca Claude Code${NC}"
echo -e "${GRAY} como tu asistente NABU. Usá siempre ~/nabu-chat/nabu, no 'claude' a secas.)${NC}"
echo
echo -e "${GRAY}Conversá natural en español. Probá:${NC}"
echo -e "${GRAY}  • \"necesito una cotización Vencor para X cliente\"${NC}"
echo -e "${GRAY}  • \"qué agentes hay activos\"${NC}"
echo -e "${GRAY}  • \"preguntale a fel-agent cuántas facturas hoy\"${NC}"
echo -e "${GRAY}  • \"necesito vacaciones próxima semana\"${NC}"
echo
echo -e "${GRAY}Para actualizar más adelante: cd ~/nabu-chat && git pull${NC}"
echo
[ "$CONEXION_OK" = "1" ] || exit 1
