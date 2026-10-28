#!/usr/bin/env bash
# bootstrap.sh — instalación all-in-one NABU para empleados Nabu Holdings
#
# Uso (empleado o Daniel en la Mac del empleado):
#   NABU_USER_NAME="..." NABU_USER_EMAIL="..." NABU_USER_EMPRESA="..." \
#   NABU_USER_ROL="..." NABU_API_URL="https://api.calderon.coffee" \
#   NABU_WAGENT_NAME="<nombre-en-el-registry>-wagent" \
#   bash <(curl -fsSL https://raw.githubusercontent.com/dcalder0n/nabu-chat/main/bootstrap.sh)
#
# La clave (INTERNAL_SVC_TOKEN) NO va en la línea de comandos (quedaría en el historial del shell): si no viene
# por entorno ni está ya en ~/.nabu-config, el script la pide por la terminal sin mostrarla. Igual con
# CLAUDE_CODE_OAUTH_TOKEN: se acepta por entorno (p. ej. desde nabu-install-remote.sh, que la pasa por stdin).
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
REPO_URL="${NABU_CHAT_REPO_URL:-$REPO_URL}"  # la variable solo sirve para pruebas
RAW_URL="https://raw.githubusercontent.com/dcalder0n/nabu-chat/main"
TARGET_DIR="${HOME}/nabu-chat"
HOME_CONFIG="${HOME}/.nabu-config"
SCRIPT_NOMBRE="bootstrap.sh"

# Los valores que van a ~/.nabu-config se limitan a [A-Za-z0-9_.:/@-] (auditoría R14/H4): ese archivo se
# carga con `source`, y un valor con $(…), comillas o \ se ejecutaría o rompería el lanzador.
valor_seguro() { case "$1" in ''|*[!A-Za-z0-9_.:/@-]*) return 1 ;; *) return 0 ;; esac; }

# Escribe pares NOMBRE VALOR en ~/.nabu-config (600). Reemplaza solo esas variables; el resto se conserva.
escribir_config_home() {
  local C="$HOME_CONFIG" TMP pat="" i
  local -a pares=("$@")
  for ((i = 0; i < ${#pares[@]}; i += 2)); do
    if ! valor_seguro "${pares[i+1]}"; then
      echo -e "  ${RED}✗${NC} ${pares[i]} trae caracteres no permitidos (solo letras, números y _ . : / @ -): no se guardó." >&2
      return 1
    fi
    pat="${pat:+$pat|}${pares[i]}"
  done
  [ -n "$pat" ] || return 0
  TMP=$(umask 077; mktemp "${HOME}/.nabu-config.XXXXXX")
  if [ -f "$C" ]; then
    grep -v -E "^(export )?(${pat})=|^# actualizado por " "$C" > "$TMP" || true
  else
    echo "# NABU empleado — credenciales (chmod 600). NO va en el repo ni en el chat." > "$TMP"
  fi
  echo "# actualizado por ${SCRIPT_NOMBRE} $(date '+%Y-%m-%d %H:%M')" >> "$TMP"
  for ((i = 0; i < ${#pares[@]}; i += 2)); do
    printf 'export %s=%q\n' "${pares[i]}" "${pares[i+1]}" >> "$TMP"
  done
  chmod 600 "$TMP"
  mv "$TMP" "$C"
}

# Credenciales SIEMPRE en ~/.nabu-config (600). Se escriben solo las variables (por nombre) que traen valor.
guardar_config_home() {
  local var
  local -a pares=()
  for var in "$@"; do [ -n "${!var}" ] && pares+=("$var" "${!var}"); done
  [ ${#pares[@]} -gt 0 ] || return 0
  escribir_config_home "${pares[@]}"
}

# R14/H1+H2: hasta el 20-oct las credenciales (INTERNAL_SVC_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, NABU_WAGENT_NAME…) se
# escribían en el .nabu-config DEL REPO, que está en git. Antes de actualizar: (1) copia 600 del archivo viejo en
# ~/.nabu-config.repo-viejo.<fecha>; (2) toda variable que falte en ~/.nabu-config pasa allá (sin ejecutar el archivo:
# se lee línea por línea); (3) se restaura la plantilla para que `git pull` no aborte. No se imprime ningún valor.
rescatar_config_repo() {
  local f=".nabu-config" linea var val respaldo rescatadas="" omitidas=""
  [ -f "$f" ] || return 0
  git diff --quiet HEAD -- "$f" 2>/dev/null && return 0
  respaldo="${HOME}/.nabu-config.repo-viejo.$(date +%Y%m%d%H%M%S)"
  (umask 077; grep -v -E '^[[:space:]]*(export[[:space:]]+)?(ANTHROPIC_API_KEY|SUPABASE_[A-Za-z0-9_]*)=' "$f" > "$respaldo" || true)
  chmod 600 "$respaldo"
  while IFS= read -r linea || [ -n "$linea" ]; do
    [[ "$linea" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    var="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
    if [[ "$val" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]] || [[ "$val" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      val="${BASH_REMATCH[1]}"
    else
      val="${val%%[[:space:]]#*}"; val="${val%"${val##*[![:space:]]}"}"
    fi
    case "$var" in
      # R16/B-H7: lista PERMITIDA. Lo demás (URL vieja, llave del API, Supabase, PATH, tokens ajenos) no se pasa;
      # queda solo en el respaldo (sin las claves retiradas).
      INTERNAL_SVC_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|NABU_WAGENT_NAME) ;;
      *) case " $omitidas " in *" $var "*) ;; *) omitidas="$omitidas $var" ;; esac
         continue ;;
    esac
    [ -n "$val" ] || continue
    grep -q -E "^(export )?${var}=.+" "$HOME_CONFIG" 2>/dev/null && continue   # ~/.nabu-config ya lo tiene: gana
    case "$var" in INTERNAL_SVC_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|NABU_WAGENT_NAME) [ -n "${!var}" ] && continue ;; esac
    if ! valor_seguro "$val"; then omitidas="$omitidas $var(caracteres-no-permitidos)"; continue; fi
    escribir_config_home "$var" "$val" 2>/dev/null || { omitidas="$omitidas $var"; continue; }
    case "$var" in INTERNAL_SVC_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|NABU_WAGENT_NAME) printf -v "$var" '%s' "$val" ;; esac
    rescatadas="$rescatadas $var"
  done < "$f"
  git checkout -- "$f"
  echo -e "  ${GREEN}✓${NC} .nabu-config del repo tenía cambios locales: copia en ${respaldo/#$HOME/~} (600) y plantilla restaurada"
  [ -n "$rescatadas" ] && echo -e "  ${GREEN}✓${NC} pasadas a ~/.nabu-config:${rescatadas}"
  [ -n "$omitidas" ] && echo -e "  ${GRAY}  no se pasaron (quedan solo en la copia):${omitidas}${NC}"
  return 0
}

# Actualiza el repo sin destruir nada: rescata el .nabu-config viejo y guarda en git stash cualquier otro cambio local.
actualizar_repo() {
  rescatar_config_repo
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    git -c user.name=nabu-install -c user.email=nabu-install@localhost \
      stash push --quiet -m "nabu-install $(date '+%Y-%m-%d %H:%M')" \
      && echo -e "  ${YELLOW}⚠${NC} otros cambios locales guardados en 'git stash' (no se borró nada)"
  fi
  git pull --quiet origin main 2>/dev/null || git pull origin main
}

# R14/H3: pedir la clave por la terminal, sin eco, si no vino por entorno ni está en ~/.nabu-config.
pedir_clave() {
  local t="" intento
  ( exec </dev/tty ) 2>/dev/null || return 1
  echo -e "  La clave de NABU te la da Daniel en privado (por llamada o en persona). Pegá SOLO la clave; no se ve al escribir."
  for intento in 1 2 3; do
    IFS= read -r -s -p "  Clave de NABU: " t < /dev/tty || t=""
    echo
    if [ ${#t} -ge 40 ] && valor_seguro "$t"; then
      INTERNAL_SVC_TOKEN="$t"
      return 0
    fi
    echo -e "  ${RED}✗${NC} esa clave no tiene el formato esperado (largo ${#t}; 40+ caracteres, sin espacios). Probá de nuevo."
  done
  return 1
}


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
# Clave: entorno → ~/.nabu-config ya existente → se pide por la terminal (sin eco). Nunca por argumento.
if [ -z "$INTERNAL_SVC_TOKEN" ] && [ -f "$HOME_CONFIG" ]; then
  INTERNAL_SVC_TOKEN=$(bash -c 'source "$HOME/.nabu-config" >/dev/null 2>&1; printf %s "$INTERNAL_SVC_TOKEN"')
  [ -n "$INTERNAL_SVC_TOKEN" ] && echo -e "  ${GREEN}✓${NC} clave tomada de ~/.nabu-config"
fi
# Laptops configuradas hasta el 20-oct: la clave quedó en el .nabu-config DEL REPO (se lee sin ejecutarlo).
if [ -z "$INTERNAL_SVC_TOKEN" ] && [ -f "$TARGET_DIR/.nabu-config" ]; then
  INTERNAL_SVC_TOKEN=$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?INTERNAL_SVC_TOKEN=["'"'"']?([A-Za-z0-9_.:\/@-]+)["'"'"']?[[:space:]]*$/\2/p' \
    "$TARGET_DIR/.nabu-config" | tail -1)
  [ -n "$INTERNAL_SVC_TOKEN" ] && echo -e "  ${GREEN}✓${NC} clave tomada del .nabu-config viejo del repo (se mueve a ~/.nabu-config)"
fi
[ -n "$INTERNAL_SVC_TOKEN" ] || pedir_clave || true
if [ -n "$INTERNAL_SVC_TOKEN" ] && { ! valor_seguro "$INTERNAL_SVC_TOKEN" || [ ${#INTERNAL_SVC_TOKEN} -lt 40 ]; }; then
  echo -e "  ${RED}✗${NC} INTERNAL_SVC_TOKEN no tiene el formato esperado (40+ caracteres, sin espacios ni comillas)."
  exit 1
fi
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
  actualizar_repo
else
  if [ -d "$TARGET_DIR" ]; then
    echo -e "   ${YELLOW}⚠${NC} ~/nabu-chat existe pero NO es git repo. Movido a ~/nabu-chat.bak.$(date +%s)"
    mv "$TARGET_DIR" "${TARGET_DIR}.bak.$(date +%s)"
  fi
  git clone --quiet "$REPO_URL" "$TARGET_DIR"
fi
cd "$TARGET_DIR"
echo -e "   ${GREEN}✓${NC} Repo en ~/nabu-chat"
# Comando «nabu» en la terminal: los empleados escriben nabu, no ~/nabu-chat/nabu (sin esto: command not found).
for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
  grep -q '# nabu-chat: comando nabu' "$rc" 2>/dev/null \
    || printf '\n# nabu-chat: comando nabu\nalias nabu="$HOME/nabu-chat/nabu"\n' >> "$rc"
done
echo -e "   ${GREEN}✓${NC} Comando nabu listo (en una terminal nueva)"
echo

# ─── 5. user.json ────────────────────────────────────────────────────────────
echo -e "${BOLD}5) user.json + ~/.nabu-config${NC}"
# Siempre con jq --arg (R14/H4): comillas, \ o $ en nombre/rol quedan como texto y el JSON es válido.
jq -n \
  --arg name "$NABU_USER_NAME" --arg email "$NABU_USER_EMAIL" --arg empresa "$NABU_USER_EMPRESA" \
  --arg rol "$NABU_USER_ROL" --arg wagent "$NABU_WAGENT_NAME" \
  --arg phone "${NABU_USER_PHONE:-}" --arg phone_role "${NABU_USER_PHONE_ROLE:-}" \
  --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg mac_user "$(whoami)" --arg host "$(hostname)" \
  '{name:$name, display_name:$name, email:$email, empresa:$empresa, rol:$rol, role:$rol,
    phone_e164:$phone, phone_role:$phone_role, installed_at:$t, mac_user_account:$mac_user,
    mac_hostname:$host, wagent_name:$wagent}' > "$TARGET_DIR/user.json.nuevo"
mv "$TARGET_DIR/user.json.nuevo" "$TARGET_DIR/user.json"
chmod 600 "$TARGET_DIR/user.json"

# Credenciales SIEMPRE en ~/.nabu-config (600), nunca en el .nabu-config del repo (está en git).
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
echo -e "   ${CYAN}nabu${NC}   ${GRAY}(en una terminal nueva)${NC}"
echo
echo -e "Después escribí dentro del chat (NO en zsh):"
echo -e "   ${GRAY}\"Hola, soy ${NABU_USER_NAME%%[[:space:]]*}. ¿Qué tengo pendiente?\"${NC}"
echo
echo -e "${BOLD}Si necesitás ayuda:${NC} escribile por WhatsApp a Daniel al +502 5522 5524"
echo
