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

# Las funciones del usuario del sitio viajan dentro de un bash nuevo (declare -f): shellcheck no
# ve esa llamada y las da por no usadas.
# shellcheck disable=SC2329
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
CON_TERMINAL=0
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
    printf 'set -euo pipefail; %s\n%s\nparte_del_usuario %s' \
        "$(declare -p REPO_PRIVADO URL_GITHUB_LLAVES LLAVE CON_TERMINAL)" "$(declare -f)" "$(printf '%q ' "$@")"
}

# Entra como el usuario del sitio. SOLO se llama desde la rama con root o sudo; el resto
# del arranque no usa `su`. Con --session-command (y no con -c) `su` NO abre una sesión nueva:
# con -c el hijo pierde la terminal de control, /dev/tty deja de existir y ninguna pregunta
# (borrar, vaciar la base, las del instalador) llegaría a hacerse.
# La entrada se fija a mano: con `curl | bash` la estándar es la tubería del script, y `sudo`
# (que corre el comando en su propio pty) solo reenvía el teclado al hijo si la entrada estándar
# es una terminal; si no, toda lectura de /dev/tty queda esperando para siempre.
correr_como_el_usuario_del_sitio() {
    local codigo entrada=/dev/null
    codigo="$(codigo_del_usuario "$@")"
    if [[ "$CON_TERMINAL" -eq 1 ]]; then
        entrada=/dev/tty
    fi
    if [[ $ES_ROOT -eq 1 ]]; then
        su - "$USUARIO" -s /bin/bash --session-command "$codigo" <"$entrada"
    else
        # shellcheck disable=SC2024  # la terminal la abre quien lanza el arranque, a propósito
        sudo su - "$USUARIO" -s /bin/bash --session-command "$codigo" <"$entrada"
    fi
}

# El PHP de consola de la versión del sitio (la del pool de PHP-FPM del dominio); si no hay, `php`.
php_del_sitio() {
    local pool version
    for pool in /etc/php/*/fpm/pool.d/"$1".conf; do
        if [[ -e "$pool" ]]; then
            version="${pool#/etc/php/}"
            version="${version%%/*}"
            if command -v "php$version" >/dev/null 2>&1; then
                printf 'php%s' "$version"
                return 0
            fi
        fi
    done
    printf 'php'
}

# Un valor del .env de la instalación que hay, sin comillas (solo para nombres, nunca claves).
valor_del_env() {
    local linea
    linea="$(grep -E "^$2=" "$1/.env" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
    linea="${linea%\"}"
    printf '%s' "${linea#\"}"
}

# Un valor del .env viejo leído como lo lee Laravel (comillas, escapes, #). Con el vendor de esa
# instalación; sin él, una lectura simple sin las comillas de los extremos. Solo para la base.
# shellcheck disable=SC2016
valor_exacto_del_env() {
    local php_bin="$1" private="$2" clave="$3" valor=''
    if [[ -f "$private/vendor/autoload.php" ]]; then
        valor="$(cd "$private" && "$php_bin" -r 'require "vendor/autoload.php"; $v = Dotenv\Dotenv::parse((string) file_get_contents(".env")); echo $v[$argv[1]] ?? "";' -- "$clave" 2>/dev/null)" || valor=''
    fi
    if [[ -z "$valor" ]]; then
        valor="$(valor_del_env "$private" "$clave")"
    fi
    printf '%s' "$valor"
}

# Qué se lleva del .env viejo a la instalación nueva. Muestra los grupos por NOMBRE (jamás un valor
# secreto) y deja elegir cada uno. Lo elegido se arma en memoria (ENV_A_CONSERVAR) y, tras el clon,
# se escribe como el .env del que parte `instalar.sh --reconfigurar`: éste conserva todo lo agregado a
# mano y rehace solo lo fijo de producción. Los datos de la base van aparte (REUSO_*): la clave viaja
# por LION_DB_CLAVE, nunca por opción. Redis no se decide acá: lion:configurar-env lo detecta y pregunta.
# Argumentos: private php_bin conecta(0|1) vaciar(0|1) base usuario_base
elegir_que_conservar() {
    local private="$1" php_bin="$2" conecta="$3" vaciar="$4" base="$5" usuario_base="$6"
    local viejo="$private/.env" kb=0 kc=0 kp=0 ko=0 prueba_base prueba_usuario otros cuantos nombres defecto_cifrado=s
    [[ -f "$viejo" ]] || return 0
    printf '\n  El .env anterior trae estas cosas; elige qué se lleva a la instalación nueva.\n'
    printf '  (Redis lo decide el instalador: detecta si el servidor lo tiene y te pregunta.)\n'

    if [[ "$conecta" -eq 1 ]]; then
        if preguntar "Base principal «$base» (usuario «$usuario_base»): ¿la conservo, sin volver a escribir la clave? (la clave queda solo en memoria)" s; then
            kb=1
            REUSO_BASE="$base"
            REUSO_USUARIO="$usuario_base"
            REUSO_CLAVE="$(valor_exacto_del_env "$php_bin" "$private" DB_PASSWORD)"
        fi
    elif [[ -n "$base" ]]; then
        aviso "la base principal «$base» no conectó con el .env viejo (o está en otro servidor): el instalador te pedirá los datos."
    fi

    if [[ -n "$(valor_del_env "$private" APP_KEY)" ]]; then
        if [[ "$vaciar" -eq 1 ]]; then
            defecto_cifrado=n
            printf '  Vas a vaciar la base: no queda nada cifrado que dependa de la APP_KEY vieja.\n'
        else
            printf '  Sin la APP_KEY vieja, lo cifrado en la base (certificado, clave SOL, tokens) queda ilegible.\n'
        fi
        if preguntar 'Claves de cifrado (APP_KEY y la frase del respaldo): ¿las conservo?' "$defecto_cifrado"; then
            kc=1
        fi
    fi

    prueba_base="$(valor_del_env "$private" RESPALDO_PRUEBA_DB_DATABASE)"
    if [[ -n "$prueba_base" ]]; then
        prueba_usuario="$(valor_del_env "$private" RESPALDO_PRUEBA_DB_USERNAME)"
        if preguntar "Base de prueba de restauración «$prueba_base» (usuario «${prueba_usuario:-?}»): ¿la conservo?" s; then
            kp=1
        fi
    fi

    # Lo que es TUYO: claves con valor que difieren del .env.example de esa instalación (correo,
    # integraciones, rutas de composer y del respaldo…). Los valores de plantilla y las claves que el
    # instalador rehace por su cuenta no cuentan.
    ejemplo="$private/.env.example"
    [[ -f "$ejemplo" ]] || ejemplo=/dev/null
    otros="$(awk -v q="'" '
        function llave(l,   k) { k = l; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k); return k }
        function valor(l) { return substr(l, index(l, "=") + 1) }
        FILENAME == ARGV[1] { if ($0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/) ej[llave($0)] = valor($0); next }
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ { k = llave($0); v = valor($0); if (v != "" && v != "\"\"" && v != q q && !((k in ej) && ej[k] == v)) print k }
        ' "$ejemplo" "$viejo" |
        grep -vE '^(APP_KEY|BACKUP_ARCHIVE_PASSWORD|DB_|RESPALDO_PRUEBA_DB_|APP_ENV|APP_DEBUG|APP_URL|APP_NAME|APP_TIMEZONE|SESSION_|EXIGIR_HTTPS|CSP_|LOG_|QUEUE_CONNECTION|CACHE_STORE|REDIS_|ACTUALIZADOR_PHP_BIN)' || true)"
    cuantos="$(printf '%s' "$otros" | grep -c . || true)"
    if [[ "$cuantos" -gt 0 ]]; then
        nombres="$(printf '%s\n' "$otros" | head -n 8 | paste -sd, - | sed 's/,/, /g')"
        if preguntar "Otros ajustes y credenciales que agregaste ($cuantos claves, p. ej. $nombres): ¿los conservo?" s; then
            ko=1
            REUSO_CORREO="$(valor_del_env "$private" MAIL_FROM_ADDRESS)"
            # un correo de plantilla (hello@example.com) no es una respuesta: que el instalador lo pregunte
            if [[ "$REUSO_CORREO" =~ @example\.(com|org|net)$ ]]; then
                REUSO_CORREO=''
            fi
            REUSO_ZONA="$(valor_del_env "$private" APP_TIMEZONE)"
        fi
    fi

    # kb/kc/kp/ko son los grupos que se quedan; ko también lleva comentarios y líneas sueltas.
    ENV_A_CONSERVAR="$(awk -v kb="$kb" -v kc="$kc" -v kp="$kp" -v ko="$ko" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { if (ko == 1) print; next }
        {
            k = $0; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k)
            if (k ~ /^DB_(DATABASE|USERNAME|PASSWORD)$/) g = kb
            else if (k == "APP_KEY" || k == "BACKUP_ARCHIVE_PASSWORD") g = kc
            else if (k ~ /^RESPALDO_PRUEBA_DB_/) g = kp
            else g = ko
            if (g == 1) print
        }' "$viejo")"
    if [[ -n "$ENV_A_CONSERVAR" ]]; then
        hecho "me llevo del .env viejo lo que elegiste (en memoria; se escribe con permisos 600 en la instalación nueva)"
    fi
}

# Borra lo que haya en private/ para instalar de cero. No hay copia ni vuelta atrás, por eso se
# pide escribir el dominio. Devuelve 0 si limpió y 1 si el dueño no lo confirmó.
limpiar_private() {
    local dominio="$1" private="$2" respuesta='' base usuario_base php_bin vaciar=0 conecta con_app
    if [[ -z "$dominio" || -L "$private" || ! -d "$private" || "$private" != /home/*/web/"$dominio"/private ]]; then
        morir "No borro $private: no es la carpeta private/ de un sitio de Hestia."
    fi
    aviso "$private ya tiene contenido (¿una instalación de Lion o de otro sistema?):"
    find "$private" -mindepth 1 -maxdepth 1 -printf '%f\n' | head -n 8 | sed 's/^/      /' || true
    if ! hay_terminal; then
        return 1
    fi
    printf '\n  Para instalar de cero se BORRA todo lo que hay en %s\n' "$private" >/dev/tty
    printf '  (código, .env y storage con los archivos subidos). No se guarda copia.\n' >/dev/tty
    printf '  Escribe %s para borrar y empezar de cero, o pulsa Enter para dejarlo como está: ' "$dominio" >/dev/tty
    read -r respuesta </dev/tty || respuesta=''
    if [[ "$respuesta" != "$dominio" ]]; then
        return 1
    fi
    base="$(valor_del_env "$private" DB_DATABASE)"
    usuario_base="$(valor_del_env "$private" DB_USERNAME)"
    php_bin="$(php_del_sitio "$dominio")"
    # Se prueba que la clave vieja conecte ANTES de borrar nada: si no conecta, no se ofrece reusarla.
    conecta=0
    con_app=0
    if [[ -f "$private/artisan" && -f "$private/vendor/autoload.php" ]]; then
        con_app=1
    fi
    if [[ -n "$base" && -n "$usuario_base" && $con_app -eq 1 ]] &&
        [[ "$(valor_del_env "$private" DB_HOST)" =~ ^(|127\.0\.0\.1|localhost)$ ]] &&
        (cd "$private" && "$php_bin" artisan db:show --json >/dev/null 2>&1); then
        conecta=1
    fi
    # Primero se decide si se vacía la base: de eso depende lo que conviene conservar del .env.
    if [[ -n "$base" && $con_app -eq 1 ]]; then
        if preguntar "¿Vacío la base «$base» (borra TODAS sus tablas) para que la instalación sea de cero?"; then
            vaciar=1
        fi
    fi
    elegir_que_conservar "$private" "$php_bin" "$conecta" "$vaciar" "$base" "$usuario_base"
    if [[ $vaciar -eq 1 ]]; then
        haciendo "vaciando la base «$base» con $php_bin artisan db:wipe"
        if ! (cd "$private" && "$php_bin" artisan db:wipe --force); then
            morir "No pude vaciar la base «$base»: no borré nada de $private. Vacíala a mano (Hestia → Base de datos) y vuelve a correr el arranque."
        fi
        hecho "base «$base» vacía"
    fi
    haciendo "borrando el contenido de $private"
    if ! find "$private" -mindepth 1 -delete; then
        morir "No pude borrar todo el contenido de $private. Revisa los permisos y vuelve a correr el arranque."
    fi
    hecho "$private quedó vacía"
}

# Todo lo que sigue corre con la identidad del usuario del sitio. No se llama por nombre acá:
# `codigo_del_usuario` lo manda dentro del bash nuevo.
# Argumentos: DOMINIO USUARIO [opciones de instalar.sh…]
parte_del_usuario() {
    local dominio="$1" usuario="$2"
    shift 2
    local casa private publica config llave_publica limite=() intento clon_ok hay_que_clonar destino codigo

    casa="$HOME"
    private="$casa/web/$dominio/private"
    PENDIENTES=()
    REUSO_BASE=''
    REUSO_USUARIO=''
    REUSO_CLAVE=''
    REUSO_CORREO=''
    REUSO_ZONA=''
    ENV_A_CONSERVAR=''

    # Si el que lanzó el arranque tenía terminal y esta parte no la heredó, seguir sin preguntar
    # dejaría pasar de largo todo lo que pide confirmación: mejor cortar.
    if [[ "$CON_TERMINAL" -eq 1 ]] && ! hay_terminal; then
        morir 'Perdí la terminal al entrar como el usuario del sitio y no puedo hacerte las preguntas. Entra por SSH como ese usuario y vuelve a correr el mismo comando.'
    fi

    paso 2 "La llave de despliegue de $usuario"
    for programa in git ssh ssh-keygen; do
        if ! command -v "$programa" >/dev/null 2>&1; then
            morir "Falta $programa. El administrador: sudo apt-get install -y git openssh-client"
        fi
    done
    mkdir -p "$casa/.ssh"
    chmod 700 "$casa/.ssh"
    if command -v timeout >/dev/null 2>&1; then
        limite=(timeout 30)
    fi
    el_remoto_responde() {
        GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15' \
            ${limite[@]+"${limite[@]}"} git ls-remote --heads "$REPO_PRIVADO" main >/dev/null 2>&1 </dev/null
    }

    # Si este usuario YA llega al repositorio privado (una llave de despliegue de antes, por
    # ejemplo), no se crea otra: una llave de despliegue solo puede estar en un repositorio.
    if el_remoto_responde; then
        ya_estaba 'GitHub ya responde por SSH con la configuración de este usuario (no genero otra llave)'
    else
        if [[ -f "$casa/$LLAVE" ]]; then
            ya_estaba "$casa/$LLAVE (ed25519, sin frase)"
        else
            haciendo "generando $casa/$LLAVE (ed25519, sin frase, solo vive en este servidor)"
            ssh-keygen -q -t ed25519 -C "lion@$dominio" -f "$casa/$LLAVE" -N ''
            hecho "llave creada: la privada se queda acá; solo se comparte la pública"
        fi
        llave_publica="$(cat "$casa/$LLAVE.pub")"

        config="$casa/.ssh/config"
        if [[ -f "$config" ]] && grep -q 'lion_deploy' "$config"; then
            ya_estaba "$config ya apunta a la llave de despliegue"
        else
            printf 'Host github.com\n  IdentityFile ~/%s\n  StrictHostKeyChecking accept-new\n' "$LLAVE" >>"$config"
            chmod 600 "$config"
            hecho "$config: github.com usa la llave de despliegue"
        fi

        intento=0
        until el_remoto_responde; do
            intento=$((intento + 1))
            printf '\n  Pega esta llave pública en GitHub → pgq27/Lion → Settings → Deploy keys → Add deploy key\n'
            printf '  (SIN marcar «Allow write access»: el servidor solo lee). Enlace: %s\n\n' "$URL_GITHUB_LLAVES"
            printf '  ┌──────────────────────────────────────────────────────────────────────\n'
            printf '  │ %s\n' "$llave_publica"
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
    fi

    paso 3 "Clonar Lion en $private"
    mkdir -p "$private"
    hay_que_clonar=1
    if [[ -d "$private/.git" && -f "$private/artisan" && ! -f "$private/.env" ]]; then
        # un arranque anterior que se cortó después del clon y antes de crear el .env
        ya_estaba "Lion ya está clonado en $private, todavía sin .env (sigo con el instalador)"
        hay_que_clonar=0
    elif [[ -n "$(ls -A "$private")" ]]; then
        if limpiar_private "$dominio" "$private"; then
            hay_que_clonar=1
        elif [[ -d "$private/.git" && -f "$private/artisan" ]]; then
            ya_estaba "sigo con la instalación que hay en $private (instalar.sh es repetible)"
            hay_que_clonar=0
        else
            morir "git clone exige la carpeta vacía y no confirmaste borrarla. Vacía $private (o confirma desde una terminal) y vuelve a correr el arranque."
        fi
    fi
    if [[ $hay_que_clonar -eq 1 ]]; then
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

    # Lo que el dueño eligió llevarse del .env viejo: se escribe (solo el dueño lo puede leer) y
    # instalar.sh --reconfigurar parte de él, conserva lo agregado a mano y rehace lo fijo.
    if [[ -n "$ENV_A_CONSERVAR" && $hay_que_clonar -eq 1 ]]; then
        (umask 077 && printf '%s\n' "$ENV_A_CONSERVAR" >"$private/.env")
        chmod 600 "$private/.env"
        ENV_A_CONSERVAR=''
        set -- --reconfigurar "$@"
        if [[ -n "$REUSO_BASE" ]]; then
            set -- --si "$@"
        fi
        if [[ -n "$REUSO_CORREO" ]]; then
            set -- "--correo=$REUSO_CORREO" "$@"
        fi
        if [[ -n "$REUSO_ZONA" ]]; then
            set -- "--zona=$REUSO_ZONA" "$@"
        fi
        hecho "$private/.env escrito con lo que elegiste conservar (permisos 600)"
    fi

    # public_html tiene que ser un enlace a private/public: así el .env, storage y .git quedan
    # FUERA de lo que el servidor publica. El enlace lo crea instalar.sh; acá solo se limpia, con
    # confirmación, lo que haya de un sistema anterior.
    publica="$casa/web/$dominio/public_html"
    if [[ -L "$publica" ]]; then
        destino="$(readlink "$publica")"
        if [[ "$destino" == private/public || "$destino" == "$private/public" ]]; then
            ya_estaba "public_html → $destino"
        else
            aviso "public_html es un enlace a $destino, no a private/public."
            if preguntar "¿Quito ese enlace (no borra nada de $destino) para enlazarla a private/public?"; then
                rm "$publica"
                hecho "enlace quitado (apuntaba a $destino)"
            else
                aviso 'lo dejo: instalar.sh te lo marcará como pendiente.'
            fi
        fi
    elif [[ -d "$publica" && -n "$(find "$publica" -mindepth 1 ! -type d ! -path "$publica/index.html" ! -path "$publica/robots.txt" -print -quit)" ]]; then
        aviso "public_html tiene archivos que no son la bienvenida de Hestia (¿de otro sistema?):"
        find "$publica" -mindepth 1 -maxdepth 1 -printf '%f\n' | head -n 8 | sed 's/^/      /' || true
        if preguntar "¿BORRO todo $publica y la enlazo a private/public? (sin copia)"; then
            rm -rf "$publica"
            hecho "$publica borrada: instalar.sh la enlaza a private/public"
        else
            aviso 'los dejo: instalar.sh te lo marcará como pendiente.'
        fi
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
    if [[ -n "$REUSO_BASE" ]]; then
        set -- "--base=$REUSO_BASE" "--usuario=$REUSO_USUARIO" "$@"
    fi
    cd "$private"
    codigo=0
    # La clave de la base viaja en el entorno SOLO de este proceso (LION_DB_CLAVE), nunca como opción.
    if hay_terminal; then
        LION_DB_CLAVE="${REUSO_CLAVE:-${LION_DB_CLAVE:-}}" bash instalar.sh "$@" </dev/tty || codigo=$?
    else
        LION_DB_CLAVE="${REUSO_CLAVE:-${LION_DB_CLAVE:-}}" bash instalar.sh "$@" </dev/null || codigo=$?
    fi
    REUSO_CLAVE=''
    return "$codigo"
}

# ── Lo que corre el arranque ─────────────────────────────────────────────────

main() {
    local codigo=0

    leer_argumentos "$@"
    if hay_terminal; then
        CON_TERMINAL=1
    fi

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
