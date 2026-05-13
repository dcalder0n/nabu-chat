#!/usr/bin/env bash
# bootstrap.sh — instalación all-in-one NABU para empleados Nabu Holdings
#
# Uso (empleado o Daniel en la Mac del empleado):
#   NABU_USER_NAME="..." NABU_USER_EMAIL="..." NABU_USER_EMPRESA="..." \
#   NABU_USER_ROL="..." NABU_API_URL="https://api.calderon.coffee" \
#   ANTHROPIC_API_KEY="sk-ant-..." \
#   bash <(curl -fsSL https://raw.githubusercontent.com/dcalder0n/nabu-chat/main/bootstrap.sh)
#
# Qué hace (en orden):
#   1. Detect macOS arch (Apple Silicon vs Intel)
#   2. Install Homebrew si falta (silent — sin prompt interactivo)
#   3. Configure brew PATH para zsh
#   4. Install Claude Code + jq via brew si faltan
#   5. Verificar Claude Code ejecutable
#   6. Llamar a install.sh (nabu-chat repo) — clone + user.json + .nabu-config
#   7. chmod 600 archivos sensibles
#   8. Smoke test conectividad a NABU API
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
clear
echo
echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   NABU bootstrap (brew + Claude Code + nabu-chat)  ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════╝${NC}"
echo
echo -e "  Empleado:  ${BOLD}${NABU_USER_NAME:-<not set>}${NC}"
echo -e "  Email:     ${NABU_USER_EMAIL:-<not set>}"
echo -e "  Empresa:   ${NABU_USER_EMPRESA:-<not set>}"
echo -e "  Rol:       ${NABU_USER_ROL:-<not set>}"
echo

# ─── 0. Validate env vars ────────────────────────────────────────────────────
MISSING_ENV=0
for var in NABU_USER_NAME NABU_USER_EMAIL NABU_USER_EMPRESA NABU_USER_ROL ANTHROPIC_API_KEY; do
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
echo -e "${BOLD}5) user.json + .nabu-config${NC}"
cat > "$TARGET_DIR/user.json" <<EOF
{
  "name": "${NABU_USER_NAME}",
  "email": "${NABU_USER_EMAIL}",
  "empresa": "${NABU_USER_EMPRESA}",
  "rol": "${NABU_USER_ROL}",
  "phone_e164": "${NABU_USER_PHONE:-}",
  "phone_role": "${NABU_USER_PHONE_ROLE:-}",
  "installed_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "mac_user_account": "$(whoami)",
  "mac_hostname": "$(hostname)"
}
EOF

cat > "$TARGET_DIR/.nabu-config" <<EOF
# NABU empleado config — generado $(date)
export NABU_API_URL="${NABU_API_URL}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
EOF

chmod 600 "$TARGET_DIR/user.json" "$TARGET_DIR/.nabu-config"
echo -e "   ${GREEN}✓${NC} user.json + .nabu-config (chmod 600)"
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

# ─── 7. Smoke test ──────────────────────────────────────────────────────────
echo -e "${BOLD}7) Smoke test conectividad NABU API${NC}"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${NABU_API_URL}/api/agent-invoke")
if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "405" ]; then
  echo -e "   ${GREEN}✓${NC} NABU API responde (HTTP $HTTP_CODE — endpoint vivo)"
elif [ "$HTTP_CODE" = "200" ]; then
  echo -e "   ${GREEN}✓${NC} NABU API responde (HTTP 200)"
elif [ "$HTTP_CODE" = "000" ]; then
  echo -e "   ${RED}✗${NC} NABU API NO responde (HTTP 000 — sin conectividad)"
  echo -e "   ${GRAY}   Verificá tunnel api.calderon.coffee. Continuamos igual.${NC}"
else
  echo -e "   ${YELLOW}⚠${NC} NABU API responde HTTP $HTTP_CODE (puede ser tunnel reload)"
fi
echo

# ─── 8. Notify NABU API que se instaló ──────────────────────────────────────
echo -e "${BOLD}8) Registrando install en NABU${NC}"
curl -s -X POST "${NABU_API_URL}/api/employees/installed" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --arg email "$NABU_USER_EMAIL" \
    --arg name "$NABU_USER_NAME" \
    --arg empresa "$NABU_USER_EMPRESA" \
    --arg host "$(hostname)" \
    --arg mac_user "$(whoami)" \
    '{email:$email, name:$name, empresa:$empresa, host:$host, mac_user:$mac_user, installed_at:now|todate}')" \
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
echo -e "${BOLD}Si necesitás ayuda:${NC} mandale WhatsApp a Daniel +502 4793 8020"
echo
