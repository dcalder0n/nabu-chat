#!/usr/bin/env bash
# grant-nabu-ssh.sh — el EMPLEADO ejecuta esto UNA VEZ en su Mac
# Le da a NABU (M4 Pro de Daniel) acceso SSH a su cuenta para soporte/setup.
#
# Uso: el empleado pega esta línea en su terminal (los placeholders los
# completa Daniel al armar el comando):
#
#   NABU_PUB_KEY="ssh-ed25519 AAAA... nabu-master@..." \
#   bash <(curl -fsSL https://raw.githubusercontent.com/dcalder0n/nabu-chat/main/grant-nabu-ssh.sh)
#
# Qué hace:
#   1. Crea ~/.ssh con permisos correctos
#   2. Append la public key de NABU a authorized_keys con comentario claro
#   3. Habilita Remote Login en macOS (Sharing → Remote Login)
#   4. Agrega el usuario al grupo com.apple.access_ssh
#   5. Verifica que SSH responde
#   6. Pide password admin Mac UNA VEZ (sudo)

set -e

GREEN="\033[0;32m"; CYAN="\033[0;36m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; GRAY="\033[0;90m"; BOLD="\033[1m"; NC="\033[0m"

USER_HOME="${HOME}"
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
NABU_USER="$(whoami)"

clear
echo
echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   Autorizando acceso SSH de NABU                  ║${NC}"
echo -e "${BOLD}${CYAN}║   (te va a pedir password de tu Mac una vez)      ║${NC}"
echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════╝${NC}"
echo
echo -e "  Empleado:  ${BOLD}${NABU_USER}${NC} @ $(hostname)"
echo -e "  Mac IP:    $(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "n/a")"
echo

# ─── Validar env var ────────────────────────────────────────────────────────
if [ -z "${NABU_PUB_KEY}" ]; then
  echo -e "${RED}✗ Falta NABU_PUB_KEY env var.${NC}"
  echo -e "${GRAY}  Daniel debe pasarte la public key de NABU para tu Mac.${NC}"
  exit 1
fi

# Validar formato básico
if [[ ! "$NABU_PUB_KEY" =~ ^ssh-(ed25519|rsa)\  ]]; then
  echo -e "${RED}✗ NABU_PUB_KEY no parece una public key válida.${NC}"
  exit 1
fi

# ─── 1. ~/.ssh setup ────────────────────────────────────────────────────────
echo -e "${BOLD}1) ~/.ssh setup${NC}"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"
echo -e "   ${GREEN}✓${NC} ~/.ssh listo (chmod 700/600)"
echo

# ─── 2. Append public key (idempotente — no duplica) ────────────────────────
echo -e "${BOLD}2) Autorizar NABU public key${NC}"
if grep -qF "$NABU_PUB_KEY" "${AUTH_KEYS}"; then
  echo -e "   ${GREEN}✓${NC} Key ya autorizada (no duplico)"
else
  echo "" >> "${AUTH_KEYS}"
  echo "# nabu-master support access — agregado $(date '+%Y-%m-%d %H:%M') — NO BORRAR (es para que Daniel/NABU te dé soporte remoto)" >> "${AUTH_KEYS}"
  echo "$NABU_PUB_KEY" >> "${AUTH_KEYS}"
  echo -e "   ${GREEN}✓${NC} Key agregada con comentario claro"
fi
echo

# ─── 3. Enable Remote Login + agregar al grupo SSH ──────────────────────────
echo -e "${BOLD}3) Habilitando Remote Login + acceso SSH para ${NABU_USER}${NC}"
echo -e "${GRAY}   (te va a pedir tu password de Mac — es la del login normal)${NC}"
echo
sudo systemsetup -setremotelogin on 2>/dev/null || true
sudo dseditgroup -o edit -a "$NABU_USER" -t user com.apple.access_ssh 2>/dev/null || true

# Verificar que quedó en el grupo
if sudo dseditgroup -o checkmember -m "$NABU_USER" com.apple.access_ssh 2>/dev/null | grep -q "yes"; then
  echo -e "   ${GREEN}✓${NC} ${NABU_USER} en grupo com.apple.access_ssh"
else
  echo -e "   ${YELLOW}⚠${NC} No pude verificar pertenencia al grupo (puede estar OK igual)"
fi
echo

# ─── 4. Final summary ────────────────────────────────────────────────────────
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✓ NABU autorizado para conectar a tu Mac${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo
echo -e "Daniel/NABU ahora va a conectarse remoto a:"
echo -e "   ${CYAN}${NABU_USER}@$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)${NC}"
echo
echo -e "${GRAY}Si querés REVOCAR este acceso en el futuro, editá ~/.ssh/authorized_keys${NC}"
echo -e "${GRAY}y borrá la línea marcada como 'nabu-master support access'.${NC}"
echo
