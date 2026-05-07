#!/usr/bin/env bash
# setup.sh — onboarding para empleado nuevo en NABU chat (Claude Code mode)
#
# Uso (una sola vez por empleado):
#   bash setup.sh
#
# Después: cd ~/nabu-chat && claude

set -e

GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
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

# Pedir info empleado
echo
echo -e "${BOLD}Datos del empleado${NC}"
read -p "  Email NABU Workspace (ej: alejandra@vencor.com): " EMAIL
read -p "  Nombre completo: " NAME
read -p "  Empresa principal (Ventamatic/BZL Media/Vencor/Julia Bakery/Nabu Holdings): " EMPRESA
read -p "  Rol (ej: ventas, contabilidad, diseño, ops): " ROLE

# Generar user.json
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
echo -e "${GREEN}✓${NC} user.json creado"

# Verificar .nabu-config existe
if [ ! -f .nabu-config ]; then
  echo -e "${YELLOW}⚠ .nabu-config no encontrado.${NC} Pedile a Daniel el archivo o copialo del template."
  exit 1
fi
echo -e "${GREEN}✓${NC} .nabu-config presente"

# Smoke test API
source .nabu-config
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "${NABU_API_URL}/api/handoffs?limit=1" 2>/dev/null || echo "000")
if [ "$STATUS" = "200" ]; then
  echo -e "${GREEN}✓${NC} NABU API alcanzable en ${NABU_API_URL}"
else
  echo -e "${YELLOW}⚠${NC} NABU API responde ${STATUS} en ${NABU_API_URL}"
  echo -e "${GRAY}  Si es 000, el tunnel está caído. Pedile a Daniel actualizar .nabu-config.${NC}"
fi

# Verificar SUPABASE_SERVICE_ROLE_KEY
if ! grep -q "^export SUPABASE_SERVICE_ROLE_KEY=" .nabu-config; then
  echo
  echo -e "${YELLOW}⚠ SUPABASE_SERVICE_ROLE_KEY no configurada en .nabu-config${NC}"
  echo -e "${GRAY}   Pedile a Daniel + agregá en .nabu-config (read-only acceso)${NC}"
fi

echo
echo -e "${BOLD}${GREEN}Setup completo.${NC}"
echo
echo -e "Para arrancar conversación con nabu-master:"
echo -e "  ${BOLD}cd $(pwd)${NC}"
echo -e "  ${BOLD}claude${NC}"
echo
echo -e "${GRAY}Claude Code lee CLAUDE.md automáticamente y entra en modo nabu-master.${NC}"
echo -e "${GRAY}Cualquier cosa que escribas → handoff a agente vertical o respuesta directa.${NC}"
echo
