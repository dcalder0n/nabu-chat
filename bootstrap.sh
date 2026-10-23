#!/usr/bin/env bash
# bootstrap.sh — instalación all-in-one NABU para empleados Nabu Holdings
#
# Uso (empleado o Daniel en la Mac del empleado):
#   NABU_USER_NAME="..." NABU_USER_EMAIL="..." NABU_USER_EMPRESA="..." \
#   NABU_USER_ROL="..." NABU_API_URL="https://api.calderon.coffee" \
#   NABU_WAGENT_NAME="<nombre-en-el-registry>-wagent" INTERNAL_SVC_TOKEN="..." \
#   [CLAUDE_CODE_OAUTH_TOKEN="..."] \
#   bash <(curl -fsSL https://raw.githubusercontent.com/dcalder0n/nabu-chat/main/bootstrap.sh)
#
# NABU_WAGENT_NAME sale del registry de agentes (te lo da Daniel). NUNCA se deriva del
# email: abi@bzl.media es abby-wagent, alejandra@vencor.com es alejandra-pacheco-wagent.
# NABU_USER_ROLE se acepta como sinónimo de NABU_USER_ROL.
# Ya no se pide ANTHROPIC_API_KEY: los wagents usan la suscripción del equipo (20-oct-2026).
#
# Qué hace (en orden):
#   1. Detect macOS arch (Apple Silicon vs Intel)
#   2. Install Homebrew si falta (silent — sin prompt interactivo)
#   3. Configure brew PATH para zsh
#   4. Install Claude Code + jq via brew si faltan
#   5. Verificar Claude Code ejecutable
#   0. Probar bandeja del wagent (GET /api/handoffs/inbox/<wagent>): solo 200 sigue
#   6. Clonar/actualizar ~/nabu-chat + user.json (con wagent_name)
#   7. Credenciales en ~/.nabu-config (chmod 600, FUERA del repo)
#   8. Registrar la instalación en NABU
#   9. Imprimir summary + próximos pasos para empleado

set -e

GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
GRAY="\033[0;90m"
BOLD="\033[1m"
NC="\033[0m"

REPO_URL="https://github.com/dcalder0n/nabu-chat.git"
RAW_URL="https://raw.githubusercontent.com/dcalder0n/nabu-chat/main"
TARGET_DIR="${HOME}/nabu-chat"

# ─── Header ──────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo
echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   NABU bootstrap (brew + Claude Code + nabu-chat)  ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════╝${NC}"
echo
echo -e "  Empleado:  ${BOLD}${NABU_USER_NAME:-<not set>}${NC}"
echo -e "  Email:     ${NABU_USER_EMAIL:-<not set>}"
echo -e "  Empresa:   ${NABU_USER_EMPRESA:-<not set>}"
NABU_USER_ROL="${NABU_USER_ROL:-$NABU_USER_ROLE}"
NABU_USER_ROLE="$NABU_USER_ROL"
echo -e "  Rol:       ${NABU_USER_ROL:-<not set>}"
echo -e "  Agente:    ${NABU_WAGENT_NAME:-<not set>}"
echo

# ─── 0. Validate env vars ────────────────────────────────────────────────────
MISSING_ENV=0
for var in NABU_USER_NAME NABU_USER_EMAIL NABU_USER_EMPRESA NABU_USER_ROL NABU_WAGENT_NAME INTERNAL_SVC_TOKEN; do
  if [ -z "${!var}" ]; then
    echo -e "  ${RED}✗${NC} env var $var falta"
    MISSING_ENV=1
  fi
done
if [ "$MISSING_ENV" = "1" ]; then
  echo
  echo -e "${RED}Faltan env vars. Re-ejecutá con todas seteadas.${NC}"
  exit 1
fi
NABU_API_URL="${NABU_API_URL:-https://api.calderon.coffee}"

case "$NABU_WAGENT_NAME" in
  *[!a-z0-9-]*)
    echo -e "  ${RED}✗${NC} NABU_WAGENT_NAME inválido: solo minúsculas, números y guiones (ej: abby-wagent)"
    exit 1 ;;
esac

# Prueba de conexión: la bandeja del wagent. El portero la deja pasar y llega al bus, así que valida
# a la vez la clave, el nombre del wagent y que el bus esté vivo. SOLO 200 cuenta como OK.
# El token va por stdin (-K -), no en la línea de comandos: no queda visible en `ps`.
probar_bandeja() {
  local code
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$INTERNAL_SVC_TOKEN" \
    | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - \
        "${NABU_API_URL}/api/handoffs/inbox/${NABU_WAGENT_NAME}" 2>/dev/null) || true
  echo "${code:-000}"
}
explicar_codigo() {
  case "$1" in
    200) echo "OK (clave, wagent y bus válidos)" ;;
    401|403) echo "la clave INTERNAL_SVC_TOKEN es incorrecta o no tiene permiso — pedile a Daniel la correcta" ;;
    404) echo "el agente '${NABU_WAGENT_NAME}' no existe en el registry — confirmá el nombre con Daniel" ;;
    000) echo "sin conexión a ${NABU_API_URL} (internet, URL o túnel caído)" ;;
    5*) echo "el bus de NABU respondió con error (túnel o bus caído) — avisale a Daniel" ;;
    *) echo "respuesta inesperada" ;;
  esac
}

echo -e "${BOLD}0) Conexión con NABU${NC}"
CODE=$(probar_bandeja)
if [ "$CODE" != "200" ]; then
  echo -e "   ${RED}✗${NC} bandeja de ${NABU_WAGENT_NAME}: HTTP ${CODE} — $(explicar_codigo "$CODE")"
  echo -e "   ${GRAY}No se instaló nada. Corregí el dato y volvé a correr el comando.${NC}"
  exit 1
fi
echo -e "   ${GREEN}✓${NC} bandeja de ${NABU_WAGENT_NAME}: HTTP 200 — $(explicar_codigo 200)"
echo

# ─── 1. Detectar arch + Homebrew path ───────────────────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  BREW_PATH="/opt/homebrew/bin/brew"
  BREW_ENV='eval "$(/opt/homebrew/bin/brew shellenv)"'
else
  BREW_PATH="/usr/local/bin/brew"
  BREW_ENV='eval "$(/usr/local/bin/brew shellenv)"'
fi

echo -e "${BOLD}1) Homebrew${NC}"
if [ -x "$BREW_PATH" ]; then
  echo -e "   ${GREEN}✓${NC} Ya instalado ($BREW_PATH)"
  eval "$BREW_ENV"
else
  echo -e "   ${GRAY}Instalando Homebrew (puede pedir password Mac)...${NC}"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add to current session PATH
  eval "$BREW_ENV"
  # Persist in zprofile so future sessions tienen brew en PATH
  if ! grep -q "brew shellenv" "${HOME}/.zprofile" 2>/dev/null; then
    echo "$BREW_ENV" >> "${HOME}/.zprofile"
  fi
  echo -e "   ${GREEN}✓${NC} Homebrew instalado + PATH persistido"
fi
echo

# ─── 2. Claude Code ──────────────────────────────────────────────────────────
echo -e "${BOLD}2) Claude Code${NC}"
if command -v claude >/dev/null 2>&1; then
  echo -e "   ${GREEN}✓${NC} Ya instalado ($(which claude))"
else
  echo -e "   ${GRAY}Instalando Claude Code...${NC}"
  brew install --cask claude-code
  echo -e "   ${GREEN}✓${NC} Claude Code instalado"
fi
echo

# ─── 3. jq ──────────────────────────────────────────────────────────────────
echo -e "${BOLD}3) jq${NC}"
if command -v jq >/dev/null 2>&1; then
  echo -e "   ${GREEN}✓${NC} Ya instalado"
else
  brew install jq
  echo -e "   ${GREEN}✓${NC} jq instalado"
fi
echo

# ─── 4. nabu-chat repo ──────────────────────────────────────────────────────
echo -e "${BOLD}4) nabu-chat${NC}"
if [ -d "$TARGET_DIR/.git" ]; then
  echo -e "   ${GRAY}~/nabu-chat ya existe — actualizando${NC}"
  cd "$TARGET_DIR"
  git checkout -- . 2>/dev/null || true
  git pull --quiet origin main 2>/dev/null || git pull origin main
else
  if [ -d "$TARGET_DIR" ]; then
    echo -e "   ${YELLOW}⚠${NC} ~/nabu-chat existe pero NO es git repo. Movido a ~/nabu-chat.bak.$(date +%s)"
    mv "$TARGET_DIR" "${TARGET_DIR}.bak.$(date +%s)"
  fi
  git clone --quiet "$REPO_URL" "$TARGET_DIR"
fi
cd "$TARGET_DIR"
echo -e "   ${GREEN}✓${NC} Repo en ~/nabu-chat"
echo

# ─── 5. user.json ────────────────────────────────────────────────────────────
echo -e "${BOLD}5) user.json + ~/.nabu-config${NC}"
cat > "$TARGET_DIR/user.json" <<EOF
{
  "name": "${NABU_USER_NAME}",
  "display_name": "${NABU_USER_NAME}",
  "email": "${NABU_USER_EMAIL}",
  "empresa": "${NABU_USER_EMPRESA}",
  "rol": "${NABU_USER_ROL}",
  "role": "${NABU_USER_ROL}",
  "wagent_name": "${NABU_WAGENT_NAME}",
  "phone_e164": "${NABU_USER_PHONE:-}",
  "phone_role": "${NABU_USER_PHONE_ROLE:-}",
  "installed_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "mac_user_account": "$(whoami)",
  "mac_hostname": "$(hostname)"
}
EOF

chmod 600 "$TARGET_DIR/user.json"

# Credenciales SIEMPRE en ~/.nabu-config (600), nunca en el .nabu-config del repo (está en git y
# `git checkout`/`git pull` lo pisan). Se reemplazan solo las variables que traemos; el resto se conserva.
guardar_config_home() {
  local C="${HOME}/.nabu-config" TMP var pat=""
  for var in "$@"; do [ -n "${!var}" ] && pat="${pat:+$pat|}$var"; done
  [ -n "$pat" ] || return 0
  TMP=$(umask 077; mktemp "${HOME}/.nabu-config.XXXXXX")
  if [ -f "$C" ]; then
    grep -v -E "^(export )?(${pat})=|^# actualizado por " "$C" > "$TMP" || true
  else
    echo "# NABU empleado — credenciales (chmod 600). NO va en el repo ni en el chat." > "$TMP"
  fi
  echo "# actualizado por $(basename "$0") $(date '+%Y-%m-%d %H:%M')" >> "$TMP"
  for var in "$@"; do
    [ -n "${!var}" ] && printf 'export %s="%s"\n' "$var" "${!var}" >> "$TMP"
  done
  chmod 600 "$TMP"
  mv "$TMP" "$C"
}
guardar_config_home NABU_API_URL INTERNAL_SVC_TOKEN NABU_WAGENT_NAME CLAUDE_CODE_OAUTH_TOKEN
echo -e "   ${GREEN}✓${NC} user.json (chmod 600, wagent_name=${NABU_WAGENT_NAME})"
echo -e "   ${GREEN}✓${NC} ~/.nabu-config (chmod 600): NABU_API_URL, INTERNAL_SVC_TOKEN, NABU_WAGENT_NAME${CLAUDE_CODE_OAUTH_TOKEN:+, CLAUDE_CODE_OAUTH_TOKEN}"
echo

# ─── 6. Verify wrapper exists ───────────────────────────────────────────────
echo -e "${BOLD}6) Wrapper nabu${NC}"
if [ -x "$TARGET_DIR/nabu" ]; then
  echo -e "   ${GREEN}✓${NC} $TARGET_DIR/nabu existe + ejecutable"
else
  chmod +x "$TARGET_DIR/nabu" 2>/dev/null
  if [ -x "$TARGET_DIR/nabu" ]; then
    echo -e "   ${GREEN}✓${NC} chmod +x aplicado"
  else
    echo -e "   ${RED}✗${NC} $TARGET_DIR/nabu NO existe. Repo puede estar viejo."
  fi
fi
echo

# ─── 7. Conexión (ya probada en el paso 0; se repite tras instalar) ────────────
echo -e "${BOLD}7) Conexión con NABU${NC}"
CODE=$(probar_bandeja)
if [ "$CODE" = "200" ]; then
  echo -e "   ${GREEN}✓${NC} bandeja de ${NABU_WAGENT_NAME}: HTTP 200 — $(explicar_codigo 200)"
else
  echo -e "   ${RED}✗${NC} bandeja de ${NABU_WAGENT_NAME}: HTTP ${CODE} — $(explicar_codigo "$CODE")"
  echo -e "   ${GRAY}La instalación quedó hecha, pero el chat no va a poder hablar con NABU hasta que esto dé 200.${NC}"
  exit 1
fi
echo

# ─── 8. Notify NABU API que se instaló ──────────────────────────────────────
echo -e "${BOLD}8) Registrando install en NABU${NC}"
printf 'header = "Authorization: Bearer %s"\n' "$INTERNAL_SVC_TOKEN" | \
curl -s -K - -X POST "${NABU_API_URL}/api/employees/installed" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --arg email "$NABU_USER_EMAIL" \
    --arg name "$NABU_USER_NAME" \
    --arg empresa "$NABU_USER_EMPRESA" \
    --arg wagent "$NABU_WAGENT_NAME" \
    --arg host "$(hostname)" \
    --arg mac_user "$(whoami)" \
    '{email:$email, name:$name, empresa:$empresa, wagent_name:$wagent, host:$host, mac_user:$mac_user, installed_at:now|todate}')" \
  >/dev/null 2>&1 || true
echo -e "   ${GRAY}   (endpoint /api/employees/installed — best-effort)${NC}"
echo

# ─── 9. Final summary ────────────────────────────────────────────────────────
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✓ Instalación NABU completa para ${NABU_USER_NAME}${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo
echo -e "${BOLD}Próximo paso:${NC} abrí chat con NABU"
echo
echo -e "   ${CYAN}~/nabu-chat/nabu${NC}"
echo
echo -e "Después escribí dentro del chat (NO en zsh):"
echo -e "   ${GRAY}\"Hola, soy ${NABU_USER_NAME%%[[:space:]]*}. ¿Qué tengo pendiente?\"${NC}"
echo
echo -e "${BOLD}Si necesitás ayuda:${NC} escribile por WhatsApp a Daniel al +502 5522 5524"
echo
