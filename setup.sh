#!/usr/bin/env bash
# setup.sh — onboarding para empleado nuevo en NABU chat (Claude Code mode)
#
# Uso (una sola vez por empleado):
#   bash setup.sh
#
# Después: ~/nabu-chat/nabu
#
# Las credenciales (INTERNAL_SVC_TOKEN, NABU_WAGENT_NAME, CLAUDE_CODE_OAUTH_TOKEN) van en
# ~/.nabu-config (chmod 600, fuera del repo); este script NO las escribe — las pone install.sh
# o bootstrap.sh. Si user.json ya tiene wagent_name, no se sobrescribe.

set -e

GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
GRAY="\033[0;90m"
BOLD="\033[1m"
NC="\033[0m"

echo
echo -e "${BOLD}${CYAN}NABU Chat — setup empleado${NC}"
echo -e "${GRAY}─────────────────────────────${NC}"
echo

# Verificar Claude Code instalado
if ! command -v claude >/dev/null 2>&1; then
  echo -e "${YELLOW}⚠ Claude Code no encontrado.${NC}"
  echo -e "${GRAY}  Instalar: https://docs.claude.com/en/docs/claude-code/quickstart${NC}"
  echo -e "${GRAY}  ó: brew install --cask claude-code${NC}"
  exit 1
fi
echo -e "${GREEN}✓${NC} Claude Code detectado"

# Verificar jq (para parsear JSON en handoffs)
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${YELLOW}⚠ jq no instalado (necesario para handoffs).${NC}"
  echo -e "${GRAY}  Instalá: brew install jq${NC}"
  exit 1
fi
echo -e "${GREEN}✓${NC} jq detectado"

# Verificar curl
command -v curl >/dev/null 2>&1 && echo -e "${GREEN}✓${NC} curl detectado" || { echo "✗ falta curl"; exit 1; }

wagent_valido() { case "$1" in ''|*[!a-z0-9-]*) return 1 ;; *) return 0 ;; esac; }

# user.json: si ya tiene wagent_name (lo dejó bootstrap/install), se conserva tal cual.
if [ -f user.json ] && [ -n "$(jq -r '.wagent_name // empty' user.json 2>/dev/null)" ]; then
  WAGENT=$(jq -r .wagent_name user.json)
  echo -e "${GREEN}✓${NC} user.json ya existe con wagent_name=${WAGENT} — no se sobrescribe"
else
  echo
  echo -e "${BOLD}Datos del empleado${NC}"
  read -r -p "  Email NABU Workspace (ej: alejandra@vencor.com): " EMAIL
  read -r -p "  Nombre completo: " NAME
  read -r -p "  Empresa principal (Ventamatic/BZL Media/Vencor/Julia Bakery/Nabu Holdings): " EMPRESA
  read -r -p "  Rol (ej: ventas, contabilidad, diseño, ops): " ROLE
  WAGENT="${NABU_WAGENT_NAME:-}"
  # El nombre sale del registry de agentes (te lo da Daniel); NUNCA se deriva del email.
  [ -n "$WAGENT" ] || read -r -p "  Nombre de tu agente (ej: abby-wagent; te lo da Daniel): " WAGENT
  if ! wagent_valido "$WAGENT"; then
    echo -e "${RED}✗${NC} Nombre de agente inválido o vacío (solo minúsculas, números y guiones). Pedíselo a Daniel."
    exit 1
  fi
  jq -n --arg w "$WAGENT" --arg e "$EMAIL" --arg n "$NAME" --arg em "$EMPRESA" --arg r "$ROLE" \
     --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
     '{wagent_name:$w, email:$e, display_name:$n, empresa:$em, role:$r, configured_at:$t}' > user.json
  chmod 600 user.json
  echo
  echo -e "${GREEN}✓${NC} user.json creado (wagent_name=${WAGENT})"
fi

# Config: plantilla del repo (URL fija) y después ~/.nabu-config (credenciales; gana)
[ -f .nabu-config ] && source .nabu-config
[ -f "$HOME/.nabu-config" ] && source "$HOME/.nabu-config"
NABU_API_URL="${NABU_API_URL:-https://api.calderon.coffee}"
if [ -z "$INTERNAL_SVC_TOKEN" ]; then
  echo -e "${RED}✗${NC} Falta INTERNAL_SVC_TOKEN en ~/.nabu-config"
  echo -e "${GRAY}  Pedíselo a Daniel en privado (no lo pegues en el chat) o corré install.sh con INTERNAL_SVC_TOKEN=...${NC}"
  exit 1
fi

# Prueba de conexión: bandeja del agente (llega al bus → valida clave + wagent + bus). Solo 200 es OK.
# El token va por stdin (-K -) para que no quede visible en `ps`.
STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$INTERNAL_SVC_TOKEN" \
  | curl -s -o /dev/null -w "%{http_code}" -m 8 -K - "${NABU_API_URL}/api/handoffs/inbox/${WAGENT}" 2>/dev/null) || true
STATUS="${STATUS:-000}"
case "$STATUS" in
  200) echo -e "${GREEN}✓${NC} bandeja de ${WAGENT}: HTTP 200 (clave, agente y bus OK)" ;;
  401|403) echo -e "${RED}✗${NC} HTTP $STATUS: clave INTERNAL_SVC_TOKEN mala o ausente — pedile la correcta a Daniel"; exit 1 ;;
  404) echo -e "${RED}✗${NC} HTTP 404: el agente '${WAGENT}' no existe en el registry — confirmá el nombre con Daniel"; exit 1 ;;
  000) echo -e "${RED}✗${NC} sin conexión a ${NABU_API_URL} (internet, URL o túnel caído)"; exit 1 ;;
  5*)  echo -e "${RED}✗${NC} HTTP $STATUS: el bus de NABU está caído o el túnel falla — avisale a Daniel"; exit 1 ;;
  *)   echo -e "${RED}✗${NC} HTTP $STATUS: respuesta inesperada de ${NABU_API_URL}"; exit 1 ;;
esac

echo
echo -e "${BOLD}${GREEN}Setup completo.${NC}"
echo
echo -e "Para arrancar conversación con tu asistente NABU:"
echo -e "  ${BOLD}$(pwd)/nabu${NC}"
echo
echo -e "${GRAY}El lanzador carga ~/.nabu-config y abre Claude Code, que lee CLAUDE.md.${NC}"
echo -e "${GRAY}Cualquier cosa que escribas → handoff a agente vertical o respuesta directa.${NC}"
echo
