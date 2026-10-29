#!/usr/bin/env bash
#
# arranque.sh — el arranque público del instalador de Lion.
#
# Vive en un repositorio PÚBLICO pequeño (pgq27/lion-arranque) y no guarda ningún
# secreto: solo prepara el servidor, genera la llave de despliegue EN el servidor,
# espera a que el dueño la autorice en GitHub, clona el repositorio privado y le
# pasa la posta a `bash instalar.sh`, que sigue siendo la única fuente de verdad
# (PHP, .env, migraciones, cron, worker y verificación se quedan allá).
#
#     curl -fsSL https://raw.githubusercontent.com/pgq27/lion-arranque/main/arranque.sh \
#         | bash -s -- DOMINIO [USUARIO] [opciones de instalar.sh…]
#
# Se puede correr como root, como un usuario con sudo o como el usuario del sitio:
#   · root o sudo: prepara el servidor (composer global, Node 22, cliente de MariaDB,
#     proc_open en el pool de PHP-FPM) y el resto lo hace como el usuario del sitio.
#   · el usuario del sitio, sin sudo: salta la preparación y lista lo que le falta
#     al administrador; el resto (llave, clon, instalar.sh) lo hace igual.
#
# Se puede volver a correr cuantas veces haga falta: cada paso mira si ya está hecho.
#
# Lo que NO hace: no toca Hestia (el dominio, la base y el SSL se crean en el panel),
# no copia la lógica de instalar.sh y no guarda ni pide tokens (el del actualizador
# se carga después en el panel, Configuración → Llaves API).
#
# Código de salida: el de instalar.sh; 2 si termina bien pero quedan pendientes de
# la preparación; 1 si se cortó por un error.

set -euo pipefail

REPO_PRIVADO='git@github.com:pgq27/Lion.git'
URL_GITHUB_LLAVES='https://github.com/pgq27/Lion/settings/keys'
LLAVE='.ssh/lion_deploy'

ayuda() {
    cat <<'TEXTO'
Uso: curl -fsSL https://raw.githubusercontent.com/pgq27/lion-arranque/main/arranque.sh \
         | bash -s -- DOMINIO [USUARIO] [opciones de instalar.sh]

  DOMINIO    El dominio ya creado en Hestia (p. ej. beta.tuempresa.pe).
  USUARIO    El usuario de Hestia dueño del sitio. Si lo omites, se deduce de
             /home/*/web/DOMINIO.
  opciones   Todo lo demás se le pasa a `bash instalar.sh` (p. ej. --sin-assets,
             --estricto). Si no pasas --dominio=, se le pasa el DOMINIO.
TEXTO
}

# ── Cómo habla el script ─────────────────────────────────────────────────────

paso() { printf '\n[%s] %s\n' "$1" "$2"; }
ya_estaba() { printf '  ✔ ya estaba: %s\n' "$1"; }
haciendo() { printf '  → %s\n' "$1"; }
hecho() { printf '  ✔ %s\n' "$1"; }
aviso() { printf '  ! %s\n' "$1"; }
falta() {
    printf '  ✖ falta: %s\n' "$1"
    PENDIENTES+=("$1")
}
morir() {
    printf '\n✖ %s\n' "$1" >&2
    exit 1
}

PENDIENTES=()
TEMPORAL="$(mktemp -d)"
trap 'rm -rf "$TEMPORAL"' EXIT

# Con `curl | bash` la entrada estándar es el propio script: lo que se le pregunta al
# dueño se lee de la terminal (/dev/tty). Sin terminal no se pregunta nada.
hay_terminal() {
    (exec </dev/tty) 2>/dev/null
}

# preguntar «texto» [n]: pregunta [s/N] (o [S/n] si el segundo argumento es «s»).
# Sin terminal contesta que no.
preguntar() {
    local respuesta='' defecto="${2:-n}"
    if ! hay_terminal; then
        return 1
    fi
    if [[ "$defecto" == s ]]; then
        printf '  %s [S/n] ' "$1" >/dev/tty
    else
        printf '  %s [s/N] ' "$1" >/dev/tty
    fi
    read -r respuesta </dev/tty || respuesta=''
    if [[ "$defecto" == s ]]; then
        [[ ! "$respuesta" =~ ^[nN] ]]
    else
        [[ "$respuesta" =~ ^[sS] ]]
    fi
}

# shellcheck disable=SC2329
esperar_enter() {
    if hay_terminal; then
        printf '  %s ' "$1" >/dev/tty
        read -r _ </dev/tty || true
    fi
}

# ── Quién soy y a qué sitio apunto ──────────────────────────────────────────

DOMINIO=''
USUARIO=''
ARGS_DE_INSTALAR=()
PRIVILEGIADO=0
ES_ROOT=0
SUDO=()
VERSION_DEL_SITIO=''
POOL_DEL_SITIO=''

leer_argumentos() {
    local argumento
    for argumento in "$@"; do
        case "$argumento" in
            -h | --ayuda | --help)
                ayuda
                exit 0
                ;;
        esac
    done
    if [[ $# -lt 1 || "$1" == -* ]]; then
        ayuda >&2
        exit 1
    fi
    DOMINIO="$1"
    shift
    if [[ $# -gt 0 && "$1" != -* ]]; then
        USUARIO="$1"
        shift
    fi
    for argumento in "$@"; do
        [[ "$argumento" == -- ]] || ARGS_DE_INSTALAR+=("$argumento")
    done
    if [[ ! "$DOMINIO" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        morir "El dominio «$DOMINIO» no parece un dominio (solo letras, números, puntos y guiones)."
    fi
    if [[ -n "$USUARIO" && ! "$USUARIO" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        morir "El usuario «$USUARIO» no parece un usuario de Linux (minúsculas, números, guion y guion bajo)."
    fi
}

como_admin() {
    ${SUDO[@]+"${SUDO[@]}"} "$@"
}

# ¿El usuario está en un grupo de administradores? (sin tubería: con pipefail, grep -q la rompe)
grupos_del_usuario() {
    local grupos
    grupos=" $(id -nG) "
    [[ "$grupos" == *' sudo '* || "$grupos" == *' wheel '* || "$grupos" == *' admin '* ]]
}

detectar_privilegios() {
    if [[ "$(id -u)" -eq 0 ]]; then
        ES_ROOT=1
        PRIVILEGIADO=1
        hecho 'corres como root'
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        PRIVILEGIADO=1
        SUDO=(sudo)
        hecho "corres como $(id -un), con sudo"
    elif command -v sudo >/dev/null 2>&1 && grupos_del_usuario && hay_terminal; then
        haciendo "$(id -un) está en el grupo de sudo: sudo te va a pedir tu contraseña (sirve para preparar el servidor)."
        if sudo -v; then
            PRIVILEGIADO=1
            SUDO=(sudo)
            hecho "corres como $(id -un), con sudo"
        else
            aviso 'sudo no se autorizó: sigo sin preparar el servidor.'
        fi
    else
        hecho "corres como $(id -un), sin sudo: salto la preparación del servidor y te listo lo que le falte al administrador."
    fi
}

deducir_usuario() {
    local candidato carpetas=()
    if [[ -n "$USUARIO" ]]; then
        if ! id "$USUARIO" >/dev/null 2>&1; then
            morir "No existe el usuario «$USUARIO» en este servidor."
        fi
    else
        for candidato in /home/*/web/"$DOMINIO"; do
            if [[ -d "$candidato" ]]; then
                carpetas+=("$candidato")
            fi
        done
        if [[ ${#carpetas[@]} -eq 0 ]]; then
            morir "No encuentro /home/*/web/$DOMINIO. Crea el dominio en Hestia (Web → Añadir dominio) y vuelve a correr el arranque."
        elif [[ ${#carpetas[@]} -gt 1 ]]; then
            morir "El dominio $DOMINIO aparece en varios usuarios (${carpetas[*]}): pasa el usuario como segundo argumento."
        fi
        USUARIO="${carpetas[0]#/home/}"
        USUARIO="${USUARIO%%/*}"
    fi
    CASA="/home/$USUARIO"
    SITIO="$CASA/web/$DOMINIO"
    if [[ ! -d "$SITIO" ]]; then
        morir "No existe $SITIO. Crea el dominio $DOMINIO en Hestia con el usuario $USUARIO y vuelve a correr el arranque."
    fi
    hecho "sitio: $SITIO (usuario $USUARIO)"
}

# ── 1. La preparación del servidor (solo con root o sudo) ────────────────────

# Quita proc_open de la lista disable_functions de un archivo y lo imprime (no escribe nada).
SED_QUITAR_PROC_OPEN='/^[[:space:]]*(php(_admin)?_value\[disable_functions\]|disable_functions)[[:space:]]*=/ { s/([=,[:space:]])proc_open[[:space:]]*,[[:space:]]*/\1/I; s/,[[:space:]]*proc_open[[:space:]]*$//I; s/=[[:space:]]*proc_open[[:space:]]*$/=/I }'

# La lista de funciones apagadas de un archivo, en minúsculas y sin espacios.
funciones_apagadas() {
    local linea
    linea="$(grep -E '^[[:space:]]*(php(_admin)?_value\[disable_functions\]|disable_functions)[[:space:]]*=' "$1" | tail -n 1 | cut -d= -f2- || true)"
    linea="${linea,,}"
    printf '%s' "${linea//[[:space:]]/}"
}

# ¿Rige una lista de disable_functions en este archivo?
tiene_lista() {
    grep -qE '^[[:space:]]*(php(_admin)?_value\[disable_functions\]|disable_functions)[[:space:]]*=' "$1" 2>/dev/null
}

instalar_composer() {
    local php_bin='' esperado real
    if [[ -n "$VERSION_DEL_SITIO" ]] && command -v "php$VERSION_DEL_SITIO" >/dev/null 2>&1; then
        php_bin="php$VERSION_DEL_SITIO"
    elif command -v php >/dev/null 2>&1; then
        php_bin=php
    fi
    if [[ -z "$php_bin" ]]; then
        falta 'composer global: no hay ningún PHP de consola con qué instalarlo (instala php-cli).'
        return
    fi
    haciendo 'bajando el instalador de composer y comprobando su firma'
    if ! curl -fsSL https://getcomposer.org/installer -o "$TEMPORAL/composer-setup.php" ||
        ! esperado="$(curl -fsSL https://composer.github.io/installer.sig)"; then
        falta 'composer global: no pude bajar el instalador (revisa la salida a internet del servidor).'
        return
    fi
    real="$("$php_bin" -r "echo hash_file('sha384', '$TEMPORAL/composer-setup.php');" 2>/dev/null || true)"
    if [[ -z "$real" || "$real" != "$esperado" ]]; then
        falta 'composer global: la firma del instalador no coincide; no lo ejecuté.'
        return
    fi
    if como_admin "$php_bin" "$TEMPORAL/composer-setup.php" --quiet --install-dir=/usr/local/bin --filename=composer; then
        hecho 'composer instalado en /usr/local/bin/composer'
    else
        falta 'composer global: el instalador falló.'
    fi
}

instalar_node() {
    if ! command -v apt-get >/dev/null 2>&1; then
        falta 'Node 22 LTS: este servidor no usa apt; instálalo con el método de tu distribución (https://nodejs.org).'
        return
    fi
    haciendo 'agregando el repositorio de NodeSource (Node 22 LTS) e instalando nodejs'
    if curl -fsSL https://deb.nodesource.com/setup_22.x -o "$TEMPORAL/nodesource.sh" &&
        como_admin bash "$TEMPORAL/nodesource.sh" >/dev/null &&
        como_admin env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >/dev/null; then
        hecho "Node $(node -v) y npm $(npm -v)"
    else
        falta 'Node 22 LTS: la instalación falló (curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs).'
    fi
}

instalar_cliente_mariadb() {
    if ! command -v apt-get >/dev/null 2>&1; then
        falta 'el cliente de MariaDB (mariadb-dump o mysqldump): instala el paquete del cliente de tu distribución.'
        return
    fi
    haciendo 'instalando mariadb-client'
    if como_admin env DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-client >/dev/null; then
        hecho 'cliente de MariaDB instalado'
    else
        falta 'el cliente de MariaDB: sudo apt-get install -y mariadb-client'
    fi
}

# proc_open: con ella el panel ejecuta git, composer y npm. Hestia la puede traer apagada
# en el pool del dominio o, si el pool no trae lista, en el php.ini de FPM de esa versión.
revisar_proc_open() {
    local pool ini archivo='' apagadas nuevo copia
    for pool in /etc/php/*/fpm/pool.d/"$DOMINIO".conf; do
        if [[ -e "$pool" ]]; then
            POOL_DEL_SITIO="$pool"
            VERSION_DEL_SITIO="${pool#/etc/php/}"
            VERSION_DEL_SITIO="${VERSION_DEL_SITIO%%/*}"
            break
        fi
    done
    if [[ -z "$POOL_DEL_SITIO" ]]; then
        aviso "no encontré el pool de PHP-FPM del sitio (/etc/php/*/fpm/pool.d/$DOMINIO.conf): no sé si proc_open está apagada; Puesta a punto (en el panel) lo comprueba desde adentro."
        return
    fi
    hecho "PHP del sitio (pool de PHP-FPM de $DOMINIO): $VERSION_DEL_SITIO ($POOL_DEL_SITIO)"
    ini="/etc/php/$VERSION_DEL_SITIO/fpm/php.ini"
    if [[ ! -r "$POOL_DEL_SITIO" ]]; then
        aviso "no puedo leer $POOL_DEL_SITIO para ver si proc_open está apagada: corre el arranque con sudo."
        return
    fi
    if tiene_lista "$POOL_DEL_SITIO"; then
        archivo="$POOL_DEL_SITIO"
    elif [[ -r "$ini" ]] && tiene_lista "$ini"; then
        archivo="$ini"
    fi
    if [[ -z "$archivo" ]]; then
        ya_estaba 'proc_open (el pool y el php.ini de FPM no traen disable_functions)'
        return
    fi
    apagadas="$(funciones_apagadas "$archivo")"
    if [[ ",$apagadas," != *,proc_open,* ]]; then
        ya_estaba "proc_open no está apagada ($archivo)"
        return
    fi
    local comando="sudo sed -i -E '$SED_QUITAR_PROC_OPEN' $archivo && sudo systemctl restart php$VERSION_DEL_SITIO-fpm"
    if [[ $PRIVILEGIADO -eq 0 ]]; then
        falta "proc_open está en disable_functions de $archivo y el actualizador del panel no podrá correr git, composer ni npm. El administrador: $comando"
        return
    fi
    nuevo="$TEMPORAL/lista-nueva"
    sed -E "$SED_QUITAR_PROC_OPEN" "$archivo" >"$nuevo"
    aviso "proc_open está apagada en $archivo. Este sería el cambio (solo esa función):"
    diff -u "$archivo" "$nuevo" | sed 's/^/      /' || true
    if ! hay_terminal; then
        falta "proc_open está apagada en $archivo y sin terminal no la toco. Con sudo: $comando"
        return
    fi
    if ! preguntar "¿Aplico el cambio y reinicio php$VERSION_DEL_SITIO-fpm?"; then
        falta "proc_open sigue apagada en $archivo (no autorizaste el cambio). Con sudo: $comando"
        return
    fi
    copia="$archivo.lion-$(date +%Y%m%d%H%M%S).bak"
    como_admin cp -p "$archivo" "$copia"
    como_admin tee "$archivo" <"$nuevo" >/dev/null
    if [[ ",$(funciones_apagadas "$archivo")," == *,proc_open,* ]]; then
        como_admin cp -p "$copia" "$archivo"
        falta "proc_open: no pude quitarla de $archivo con seguridad (dejé el archivo como estaba). Quítala a mano y reinicia php$VERSION_DEL_SITIO-fpm."
        return
    fi
    if como_admin systemctl restart "php$VERSION_DEL_SITIO-fpm"; then
        hecho "proc_open libre en $archivo y php$VERSION_DEL_SITIO-fpm reiniciado (copia: $copia)"
    else
        falta "php$VERSION_DEL_SITIO-fpm no reinició: sudo systemctl restart php$VERSION_DEL_SITIO-fpm"
    fi
}

preparar_servidor() {
    local mayor

    if command -v composer >/dev/null 2>&1; then
        ya_estaba "composer ($(command -v composer))"
    elif [[ $PRIVILEGIADO -eq 1 ]]; then
        instalar_composer
    else
        falta "composer global. El administrador: curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer"
    fi

    mayor=0
    if command -v node >/dev/null 2>&1; then
        mayor="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    fi
    if [[ "$mayor" =~ ^[0-9]+$ ]] && ((mayor >= 20)); then
        ya_estaba "Node $(node -v)"
    elif [[ $PRIVILEGIADO -eq 1 ]]; then
        instalar_node
    else
        falta 'Node 22 LTS (hay node ≥ 20 o ninguno; sin él el panel carga sin estilos). El administrador: curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs'
    fi

    if command -v mariadb-dump >/dev/null 2>&1 || command -v mysqldump >/dev/null 2>&1; then
        ya_estaba 'cliente de MariaDB (mariadb-dump o mysqldump)'
    elif [[ $PRIVILEGIADO -eq 1 ]]; then
        instalar_cliente_mariadb
    else
        falta 'el cliente de MariaDB (mariadb-dump o mysqldump), para que el actualizador respalde la base. El administrador: sudo apt-get install -y mariadb-client'
    fi

    revisar_proc_open
}

# ── 2 a 4. Lo que se hace COMO el usuario del sitio ──────────────────────────

# El código que corre el usuario del sitio: todas las funciones de este script más la llamada,
# en un bash NUEVO con -e activo (dentro de un `|| …` bash apagaría -e en la función).
codigo_del_usuario() {
    printf 'set -euo pipefail; %s
%s
parte_del_usuario %s'         "$(declare -p REPO_PRIVADO URL_GITHUB_LLAVES LLAVE)" "$(declare -f)" "$(printf '%q ' "$@")"
}

# Entra como el usuario del sitio. SOLO se llama desde la rama con root o sudo; el resto
# del arranque no usa `su`.
correr_como_el_usuario_del_sitio() {
    local codigo
    codigo="$(codigo_del_usuario "$@")"
    if [[ $ES_ROOT -eq 1 ]]; then
        su - "$USUARIO" -s /bin/bash -c "$codigo"
    else
        sudo su - "$USUARIO" -s /bin/bash -c "$codigo"
    fi
}

# Todo lo que sigue corre con la identidad del usuario del sitio. No se llama por nombre acá:
# `codigo_del_usuario` lo manda dentro del bash nuevo.
# shellcheck disable=SC2329
# Argumentos: DOMINIO USUARIO [opciones de instalar.sh…]
parte_del_usuario() {
    local dominio="$1" usuario="$2"
    shift 2
    local casa private publica config limite=() intento clon_ok anterior codigo

    casa="$HOME"
    private="$casa/web/$dominio/private"
    PENDIENTES=()

    paso 2 "La llave de despliegue de $usuario"
    for programa in git ssh ssh-keygen; do
        if ! command -v "$programa" >/dev/null 2>&1; then
            morir "Falta $programa. El administrador: sudo apt-get install -y git openssh-client"
        fi
    done
    mkdir -p "$casa/.ssh"
    chmod 700 "$casa/.ssh"
    if [[ -f "$casa/$LLAVE" ]]; then
        ya_estaba "$casa/$LLAVE (ed25519, sin frase)"
    else
        haciendo "generando $casa/$LLAVE (ed25519, sin frase, solo vive en este servidor)"
        ssh-keygen -q -t ed25519 -C "lion@$dominio" -f "$casa/$LLAVE" -N ''
        hecho "llave creada: la privada se queda acá; solo se comparte la pública"
    fi
    publica="$(cat "$casa/$LLAVE.pub")"

    config="$casa/.ssh/config"
    if [[ -f "$config" ]] && grep -q 'lion_deploy' "$config"; then
        ya_estaba "$config ya apunta a la llave de despliegue"
    else
        printf 'Host github.com\n  IdentityFile ~/%s\n  StrictHostKeyChecking accept-new\n' "$LLAVE" >>"$config"
        chmod 600 "$config"
        hecho "$config: github.com usa la llave de despliegue"
    fi

    if command -v timeout >/dev/null 2>&1; then
        limite=(timeout 30)
    fi
    el_remoto_responde() {
        GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15' \
            ${limite[@]+"${limite[@]}"} git ls-remote --heads "$REPO_PRIVADO" main >/dev/null 2>&1 </dev/null
    }

    intento=0
    until el_remoto_responde; do
        intento=$((intento + 1))
        printf '\n  Pega esta llave pública en GitHub → pgq27/Lion → Settings → Deploy keys → Add deploy key\n'
        printf '  (SIN marcar «Allow write access»: el servidor solo lee). Enlace: %s\n\n' "$URL_GITHUB_LLAVES"
        printf '  ┌──────────────────────────────────────────────────────────────────────\n'
        printf '  │ %s\n' "$publica"
        printf '  └──────────────────────────────────────────────────────────────────────\n\n'
        if ! hay_terminal; then
            falta "la llave de despliegue: GitHub todavía no la acepta. Pégala como se indica arriba y vuelve a correr el mismo comando (la llave ya existe, no se rehace)."
            printf '\n'
            return 2
        fi
        esperar_enter 'Cuando la hayas guardado en GitHub, pulsa Enter…'
        if el_remoto_responde; then
            break
        fi
        if ((intento >= 3)) || ! preguntar 'GitHub aún no responde con esa llave. ¿Reintento?' s; then
            falta 'la llave de despliegue: git ls-remote no responde por SSH. Revisa que la pegaste entera en Deploy keys de pgq27/Lion y vuelve a correr el mismo comando.'
            return 2
        fi
    done
    hecho "GitHub responde por SSH con la llave de despliegue"

    paso 3 "Clonar Lion en $private"
    mkdir -p "$private"
    if [[ -d "$private/.git" && -f "$private/artisan" ]]; then
        ya_estaba "Lion ya está clonado en $private (sigo con el instalador)"
    else
        if [[ -n "$(ls -A "$private")" ]]; then
            anterior="$casa/web/$dominio/private.anterior"
            aviso "$private no está vacía: hay una instalación o archivos anteriores."
            find "$private" -mindepth 1 -maxdepth 1 -printf '%f
' | head -n 8 | sed 's/^/      /' || true
            if [[ -e "$anterior" ]]; then
                morir "Ya existe $anterior: muévela o bórrala tú y vuelve a correr el arranque."
            fi
            if ! preguntar "¿Muevo su contenido a $anterior para clonar limpio?"; then
                morir "git clone exige la carpeta vacía. Mueve el contenido de $private a otro lado (o confirma el traslado con una terminal) y vuelve a correr el arranque."
            fi
            mkdir "$anterior"
            find "$private" -mindepth 1 -maxdepth 1 -exec mv -t "$anterior" {} +
            hecho "lo anterior quedó en $anterior (su .env y su storage siguen ahí por si los necesitas)"
        fi
        haciendo 'git clone (rama main)'
        clon_ok=0
        if (cd "$private" && GIT_TERMINAL_PROMPT=0 git clone --quiet --branch main "$REPO_PRIVADO" .); then
            clon_ok=1
        fi
        if [[ $clon_ok -ne 1 || ! -f "$private/instalar.sh" ]]; then
            # un clon cortado deja su .git a medias y la próxima vez la carpeta ya no estaría vacía
            if [[ -d "$private/.git" && ! -f "$private/artisan" ]]; then
                rm -rf "$private/.git"
            fi
            morir "No pude clonar $REPO_PRIVADO en $private."
        fi
        hecho "Lion clonado en $private"
    fi

    paso 4 'El instalador de Lion (instalar.sh)'
    dominio_dado=0
    for argumento in "$@"; do
        if [[ "$argumento" == --dominio=* ]]; then
            dominio_dado=1
        fi
    done
    if [[ $dominio_dado -eq 0 ]]; then
        set -- "--dominio=$dominio" "$@"
    fi
    cd "$private"
    codigo=0
    if hay_terminal; then
        bash instalar.sh "$@" </dev/tty || codigo=$?
    else
        bash instalar.sh "$@" </dev/null || codigo=$?
    fi
    return "$codigo"
}

# ── Lo que corre el arranque ─────────────────────────────────────────────────

main() {
    local codigo=0

    leer_argumentos "$@"

    printf 'Arranque de Lion — %s\n' "$DOMINIO"
    printf '\nEste arranque NO toca Hestia: el dominio, la base de datos con su usuario y el SSL\n'
    printf 'se crean en el panel (docs/INSTALAR_LA_BETA.md, paso 1).\n'
    if hay_terminal; then
        if ! preguntar '¿Ya creaste en Hestia el dominio, la base y el SSL?'; then
            printf '\nCrea primero esas tres cosas en el panel y vuelve a correr el mismo comando.\n'
            exit 0
        fi
    else
        aviso 'sin terminal: doy por hecho que el dominio, la base y el SSL ya existen en Hestia.'
    fi

    paso 0 'Quién eres y a qué sitio apunto'
    detectar_privilegios
    deducir_usuario

    paso 1 'Preparar el servidor (composer, Node 22, cliente de MariaDB, proc_open)'
    preparar_servidor

    # De acá en adelante, lo que sigue lo hace el usuario del sitio.
    if [[ $PRIVILEGIADO -eq 1 && "$(id -un)" != "$USUARIO" ]]; then
        correr_como_el_usuario_del_sitio "$DOMINIO" "$USUARIO" ${ARGS_DE_INSTALAR[@]+"${ARGS_DE_INSTALAR[@]}"} || codigo=$?
    elif [[ "$(id -un)" == "$USUARIO" ]]; then
        bash -c "$(codigo_del_usuario "$DOMINIO" "$USUARIO" ${ARGS_DE_INSTALAR[@]+"${ARGS_DE_INSTALAR[@]}"})" || codigo=$?
    else
        morir "Corres como $(id -un) y el sitio es de $USUARIO, pero no tienes sudo para entrar como ese usuario. Entra por SSH como $USUARIO y vuelve a correr el mismo comando."
    fi

    if [[ ${#PENDIENTES[@]} -gt 0 ]]; then
        printf '\nPendientes de la preparación del servidor:\n'
        printf '  ✖ %s\n' "${PENDIENTES[@]}"
        if [[ $codigo -eq 0 ]]; then
            codigo=2
        fi
    fi
    exit "$codigo"
}

# Todo el script se lee ANTES de ejecutar main: así nada que corra adentro (su, ssh, git)
# puede comerse el resto del script cuando llega por la tubería de curl.
main "$@"
