#!/usr/bin/env bash
# install.sh — NABU chat one-liner installer para empleados NABU Holdings
#
# Uso (empleado):
#   curl -fsSL https://raw.githubusercontent.com/dcalder0n/nabu-chat/main/install.sh | bash
#   (si falta la clave de NABU, la pide sin mostrarla; nunca la pongas en la línea de comandos)
#
# Uso con datos (Daniel):
#   NABU_USER_EMAIL=... NABU_USER_NAME=... NABU_USER_EMPRESA=... NABU_USER_ROLE=... \
#   NABU_WAGENT_NAME=<nombre-en-el-registry> bash install.sh
#   (INTERNAL_SVC_TOKEN y CLAUDE_CODE_OAUTH_TOKEN se aceptan por entorno —p. ej. exportadas desde un
#    archivo—, pero si falta la clave el script la pide por la terminal: así no queda en el historial)
#   (NABU_USER_ROL se acepta como sinónimo de NABU_USER_ROLE)
#
# Qué hace:
#   1. Verifica Claude Code + jq + curl + git
#   2. Clona/actualiza ~/nabu-chat
#   3. Pide email + nombre + empresa + rol + nombre del agente → user.json (con wagent_name)
#   4. Guarda credenciales en ~/.nabu-config (chmod 600, FUERA del repo); si falta la clave, la pide sin eco
#   5. Prueba la bandeja del agente (GET /api/handoffs/inbox/<wagent>): solo 200 es OK
#   6. Te dice cómo arrancar conversación
#
# Para actualizar más adelante: volvé a correr este mismo comando (no `git pull` a mano).
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

REPO_URL="${NABU_CHAT_REPO_URL:-https://github.com/dcalder0n/nabu-chat.git}"  # la variable solo sirve para pruebas
TARGET_DIR="${HOME}/nabu-chat"
HOME_CONFIG="${HOME}/.nabu-config"
SCRIPT_NOMBRE="install.sh"

NABU_USER_ROLE="${NABU_USER_ROLE:-$NABU_USER_ROL}"
NABU_USER_ROL="$NABU_USER_ROLE"

# Con `curl | bash` el stdin es el script: las preguntas se leen de la terminal.
preguntar() {  # preguntar "texto" VAR
  local resp=""
  if [ -r /dev/tty ]; then read -r -p "$1" resp < /dev/tty || true; else read -r -p "$1" resp || true; fi
  printf -v "$2" '%s' "$resp"
}

wagent_valido() { case "$1" in ''|*[!a-z0-9-]*) return 1 ;; *) return 0 ;; esac; }

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
  echo "# actualizado por install.sh $(date '+%Y-%m-%d %H:%M')" >> "$TMP"
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
  (umask 077; cp "$f" "$respaldo")
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
      # URL fija (la da la plantilla; las viejas apuntaban a túneles muertos) y credenciales retiradas
      # (llave del API: rompe la suscripción; Supabase: ya no existe). Quedan solo en el respaldo.
      NABU_API_URL|ANTHROPIC_API_KEY|SUPABASE_*|PATH|HOME|SHELL|IFS|USER|BASH*|LD_*|DYLD_*|PS[0-9])
        case " $omitidas " in *" $var "*) ;; *) omitidas="$omitidas $var" ;; esac
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
  actualizar_repo
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

# R14/H4: un user.json roto (p. ej. armado a mano con comillas en el nombre) se aparta y se vuelve a generar.
if [ -f user.json ] && ! jq -e . user.json >/dev/null 2>&1; then
  mv user.json "user.json.roto.$(date +%s)"
  echo -e "  ${YELLOW}⚠${NC} user.json estaba dañado: quedó como user.json.roto.* y se vuelve a generar"
fi
escribir_user_json() {  # siempre con jq --arg: nombres con comillas, \ o $ quedan como texto
  jq -n --arg w "$WAGENT" --arg e "$EMAIL" --arg n "$NAME" --arg em "$EMPRESA" --arg r "$ROLE" \
     --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
     '{wagent_name:$w, email:$e, display_name:$n, empresa:$em, role:$r, configured_at:$t}' > user.json.nuevo
  mv user.json.nuevo user.json
  chmod 600 user.json
}

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
  escribir_user_json
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

  escribir_user_json
  echo
  echo -e "  ${GREEN}✓${NC} user.json creado"
else
  EMAIL=$(jq -r '.email // empty' user.json)
  NAME=$(jq -r '.display_name // empty' user.json)
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
TENIA_CLAVE=0
grep -q -E '^(export )?INTERNAL_SVC_TOKEN=.+' "$HOME_CONFIG" 2>/dev/null && TENIA_CLAVE=1
if [ -z "$INTERNAL_SVC_TOKEN" ] && [ "$TENIA_CLAVE" = "0" ]; then
  pedir_clave || true
fi
if [ -n "$INTERNAL_SVC_TOKEN" ]; then
  if ! valor_seguro "$INTERNAL_SVC_TOKEN" || [ ${#INTERNAL_SVC_TOKEN} -lt 40 ]; then
    echo -e "  ${RED}✗${NC} INTERNAL_SVC_TOKEN no tiene el formato esperado (40+ caracteres, sin espacios ni comillas)."
    exit 1
  fi
  NABU_API_URL="${NABU_API_URL:-https://api.calderon.coffee}"
  guardar_config_home NABU_API_URL INTERNAL_SVC_TOKEN NABU_WAGENT_NAME CLAUDE_CODE_OAUTH_TOKEN
  echo -e "  ${GREEN}✓${NC} ~/.nabu-config (chmod 600): INTERNAL_SVC_TOKEN, NABU_API_URL, NABU_WAGENT_NAME${CLAUDE_CODE_OAUTH_TOKEN:+, CLAUDE_CODE_OAUTH_TOKEN}"
else
  guardar_config_home NABU_WAGENT_NAME CLAUDE_CODE_OAUTH_TOKEN
  if [ "$TENIA_CLAVE" = "1" ]; then
    echo -e "  ${GREEN}✓${NC} ~/.nabu-config ya tiene INTERNAL_SVC_TOKEN"
  else
    echo -e "  ${YELLOW}⚠${NC} Falta INTERNAL_SVC_TOKEN en ~/.nabu-config"
    echo -e "  ${GRAY}  Volvé a correr install.sh en una ventana de Terminal: te la pide sin mostrarla. No la pegues en el chat.${NC}"
  fi
fi
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] && ! grep -q -E '^(export )?CLAUDE_CODE_OAUTH_TOKEN=.+' "$HOME_CONFIG" 2>/dev/null \
   && ! claude auth status 2>/dev/null | grep -q '"loggedIn": true'; then
  echo -e "  ${YELLOW}⚠${NC} No hay credencial de Claude (ni CLAUDE_CODE_OAUTH_TOKEN ni login): pedísela a Daniel, sin ella ./nabu no abre"
fi
echo

# ─── 5. Prueba de conexión: bandeja del agente ────────────────────────────────
# Llega al bus a través del portero → valida clave + wagent_name + bus. SOLO 200 es OK.

echo -e "${BOLD}Probando conexión con NABU${NC}"
[ -f .nabu-config ] && source ./.nabu-config
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
echo -e "${GRAY}  • \"¿tengo algo pendiente?\"${NC}"
echo -e "${GRAY}  • \"necesito vacaciones próxima semana\"${NC}"
echo
echo -e "${GRAY}Para actualizar más adelante: volvé a correr este mismo instalador (no hagas git pull a mano).${NC}"
echo
[ "$CONEXION_OK" = "1" ] || exit 1
