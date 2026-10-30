# lion-arranque

El arranque público del instalador de **Lion ERP**. Este repositorio solo trae
un script, `arranque.sh`: prepara el servidor, genera la llave de despliegue,
espera a que la autorices en GitHub, clona el repositorio privado de Lion y le
pasa la posta a su `instalar.sh`. Todo lo demás vive en el privado.

## El comando

Con el dominio ya creado en Hestia, por SSH:

```bash
curl -fsSL https://raw.githubusercontent.com/pgq27/lion-arranque/main/arranque.sh | bash -s -- DOMINIO
```

`DOMINIO` es, por ejemplo, `beta.tuempresa.pe`. Si el servidor tiene varios
usuarios con ese dominio, agrega el usuario de Hestia después:
`… | bash -s -- DOMINIO USUARIO`. Lo que pongas después (`--sin-assets`,
`--estricto`…) se le pasa tal cual a `bash instalar.sh`.

Córrelo como root, como un usuario con `sudo` o como el usuario del sitio. Se
puede repetir cuantas veces haga falta: cada paso mira si ya está hecho.

## Qué prepara

Solo si lo corre root o alguien con `sudo` (si no, lo salta y te lista lo que
le falta al administrador):

- `composer` global en `/usr/local/bin`, si falta (comprueba la firma del instalador).
- Node 22 LTS (NodeSource), si no hay `node` 20 o más nuevo.
- El cliente de MariaDB (`mariadb-dump` o `mysqldump`).
- `proc_open` fuera de `disable_functions` en el pool de PHP-FPM del dominio (o
  en el `php.ini` de FPM de esa versión): te muestra el cambio, lo aplica solo si
  lo confirmas en la terminal y reinicia `phpX.Y-fpm`. Sin terminal lo deja como
  pendiente con el comando exacto.

Siempre, como el usuario del sitio: la llave `~/.ssh/lion_deploy` (ed25519, sin
frase), el bloque de `~/.ssh/config`, el clon en
`/home/USUARIO/web/DOMINIO/private` y `bash instalar.sh`.

## Qué te pide

1. Confirmar que ya creaste en Hestia el dominio, la base y el SSL.
2. Pegar la llave **pública** que imprime en GitHub → `pgq27/Lion` → Settings →
   Deploy keys → Add deploy key, **sin** marcar *Allow write access*, y pulsar Enter.
3. Si el dominio ya tenía algo (una instalación de Lion o de otro sistema), el
   arranque instala **de cero**: antes de borrar `private/` te pide **escribir el
   dominio** y, si hay un `.env` anterior, te deja **elegir qué te llevas** (solo
   nombres en pantalla, nunca valores secretos): la base principal si conecta (la
   clave viaja a `instalar.sh` por `LION_DB_CLAVE` y no la vuelves a escribir), las
   claves de cifrado (`APP_KEY` y la frase del respaldo; por defecto sí, salvo que
   vacíes la base), la base de prueba de restauración (`RESPALDO_PRUEBA_DB_*`) y
   los demás ajustes que agregaste (correo, integraciones, rutas de composer…).
   Lo que elijas se escribe, solo para el dueño, como el `.env` del que parte
   `instalar.sh --reconfigurar`. Redis lo decide el instalador (detecta y
   pregunta). También te pregunta si vacía la base (`php artisan db:wipe`). No guarda copias: lo borrado
   no vuelve. Si en `public_html` hay archivos de otro sistema, también pide
   confirmar antes de borrarla; si es un enlace a otro lado, solo quita el enlace.
   Después `instalar.sh` la enlaza a `private/public`, para que `.env`, `storage` y
   `.git` queden fuera de lo que el servidor publica. Si no confirmas, no se borra
   nada y se sigue con lo que haya.

## Qué no hace

- No guarda ningún secreto: la llave privada nace y se queda en el servidor.
  El token del actualizador se carga después, en el panel de Lion.
- No toca el cron ni nada fuera de `private/` y `public_html/` de ese dominio (el
  crontab del usuario puede tener líneas de otros sistemas).
- No toca Hestia: el dominio, la base y el SSL se crean en el panel.
- No repite la lógica de `instalar.sh` (PHP, `.env`, migraciones, cron, worker,
  verificación): eso lo hace el instalador del repositorio privado.

> Este repositorio es una **copia que se publica**. La fuente es
> `arranque-publico/` dentro de `pgq27/Lion`; no se edita acá.
