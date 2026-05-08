#!/usr/bin/env bash
# install.sh — NABU chat one-liner installer para empleados NABU Holdings
#
# Uso (empleado):
#   curl -fsSL https://raw.githubusercontent.com/dcalder0n/nabu-chat/main/install.sh | bash
#
# Qué hace:
#   1. Verifica Claude Code + jq + curl + git
#   2. Clona/actualiza ~/nabu-chat
#   3. Pide email + nombre + empresa + rol → user.json
#   4. Verifica conectividad NABU API
#   5. Te dice cómo arrancar conversación

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

clear
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
  git pull --quiet origin main || true
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

if [ ! -f user.json ]; then
  # Auto-config si Daniel pasó datos via env vars
  if [ -n "$NABU_USER_EMAIL" ] && [ -n "$NABU_USER_NAME" ] && [ -n "$NABU_USER_EMPRESA" ] && [ -n "$NABU_USER_ROLE" ]; then
    EMAIL="$NABU_USER_EMAIL"
    NAME="$NABU_USER_NAME"
    EMPRESA="$NABU_USER_EMPRESA"
    ROLE="$NABU_USER_ROLE"
    echo -e "${BOLD}Datos del empleado${NC} ${GREEN}(auto-config)${NC}"
    echo -e "  $NAME · $EMAIL · $EMPRESA · $ROLE"
  else
    echo -e "${BOLD}Datos del empleado${NC}"
    echo -e "${GRAY}(Solo se guarda local en tu Mac, no se sube a NABU sin handoff explícito)${NC}"
    echo
    read -p "  Email NABU Workspace (ej: alejandra@vencor.com): " EMAIL
    read -p "  Nombre completo: " NAME
    echo "  Empresa principal:"
    echo "    1) Ventamatic"
    echo "    2) BZL Media"
    echo "    3) Vencor"
    echo "    4) Julia Bakery"
    echo "    5) Nabu Holdings"
    read -p "  Tu opción (1-5): " EMPRESA_NUM
    case "$EMPRESA_NUM" in
      1) EMPRESA="Ventamatic" ;;
      2) EMPRESA="BZL Media" ;;
      3) EMPRESA="Vencor" ;;
      4) EMPRESA="Julia Bakery" ;;
      5) EMPRESA="Nabu Holdings" ;;
      *) EMPRESA="$EMPRESA_NUM" ;;
    esac
    read -p "  Rol (ej: ventas, contabilidad, diseño, ops, gerente): " ROLE
  fi

  cat > user.json <<EOF
{
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
  echo -e "${GRAY}user.json ya existe — usando datos de $NAME ($EMAIL)${NC}"
fi
echo

# ─── 4. Smoke test NABU API ───────────────────────────────────────────────────

echo -e "${BOLD}Probando conexión NABU API${NC}"
if [ -f .nabu-config ]; then
  source .nabu-config
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "${NABU_API_URL}/api/handoffs?limit=1" 2>/dev/null || echo "000")
  if [ "$STATUS" = "200" ]; then
    echo -e "  ${GREEN}✓${NC} ${NABU_API_URL} responde 200"
  elif [ "$STATUS" = "000" ]; then
    echo -e "  ${YELLOW}⚠${NC} ${NABU_API_URL} no responde"
    echo -e "    ${GRAY}El tunnel cloudflared debe estar caído. Pedile a Daniel actualizar.${NC}"
  else
    echo -e "  ${YELLOW}⚠${NC} ${NABU_API_URL} responde $STATUS"
  fi
else
  echo -e "  ${YELLOW}⚠${NC} Falta .nabu-config (Daniel agregalo al repo)"
fi
echo

# ─── 5. Done ──────────────────────────────────────────────────────────────────

# ─── 6. Credenciales — auto-config si vienen via env vars ─────────────────────

echo -e "${BOLD}Credenciales${NC}"

chmod +x "$TARGET_DIR/nabu" 2>/dev/null || true

# Auto-config si Daniel pasó las creds inline (env vars del comando)
if [ -n "$ANTHROPIC_API_KEY" ] && [ -n "$INTERNAL_SVC_TOKEN" ]; then
  # Make local copy of config (NOT committed to repo)
  cp "$TARGET_DIR/.nabu-config" "$TARGET_DIR/.nabu-config.local"

  # Append credentials uncommented
  cat >> "$TARGET_DIR/.nabu-config.local" <<EOF

# Auto-configured by install ($(date -u '+%Y-%m-%d %H:%M UTC'))
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
export INTERNAL_SVC_TOKEN="$INTERNAL_SVC_TOKEN"
EOF

  # Replace public .nabu-config with local (so wrapper picks it up)
  mv "$TARGET_DIR/.nabu-config.local" "$TARGET_DIR/.nabu-config"
  chmod 600 "$TARGET_DIR/.nabu-config"

  echo -e "  ${GREEN}✓${NC} ANTHROPIC_API_KEY configurada (${#ANTHROPIC_API_KEY} chars)"
  echo -e "  ${GREEN}✓${NC} INTERNAL_SVC_TOKEN configurado (${#INTERNAL_SVC_TOKEN} chars)"
  echo -e "  ${GRAY}(.nabu-config chmod 600, solo legible por vos)${NC}"
else
  # Fallback manual si las vars no vinieron
  HAS_KEY=$(grep -E "^export ANTHROPIC_API_KEY=" "$TARGET_DIR/.nabu-config" 2>/dev/null | head -1)
  if [ -z "$HAS_KEY" ]; then
    echo -e "  ${YELLOW}⚠${NC} ANTHROPIC_API_KEY no recibida via env var ni config"
    echo -e "  ${GRAY}  Pedile a Daniel la 1-liner CON credenciales (incluye env vars)${NC}"
    echo -e "  ${GRAY}  O editá manual: nano ~/nabu-chat/.nabu-config${NC}"
  fi
fi
echo

# ─── 7. Done ──────────────────────────────────────────────────────────────────

echo -e "${BOLD}${GREEN}Instalación completa.${NC}"
echo
echo -e "${BOLD}Para arrancar conversación con nabu-master:${NC}"
echo
echo -e "  ${BOLD}~/nabu-chat/nabu${NC}"
echo
echo -e "${GRAY}(El wrapper ./nabu carga las credenciales auto + arranca Claude Code${NC}"
echo -e "${GRAY} en modo nabu-master. NO arranquen 'claude' directamente o pedirá subscripción.)${NC}"
echo
echo -e "${GRAY}Conversá natural en español. Probá:${NC}"
echo -e "${GRAY}  • \"necesito una cotización Vencor para X cliente\"${NC}"
echo -e "${GRAY}  • \"qué agentes hay activos\"${NC}"
echo -e "${GRAY}  • \"preguntale a fel-agent cuántas facturas hoy\"${NC}"
echo -e "${GRAY}  • \"necesito vacaciones próxima semana\"${NC}"
echo
echo -e "${GRAY}Para actualizar más adelante: cd ~/nabu-chat && git pull${NC}"
echo
