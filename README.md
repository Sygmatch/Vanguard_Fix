Vanguard Fix & Reboot (MARCKO-SYGMATCH)

Herramienta de automatizacion y solucion de problemas en lote (.bat) disenada para jugadores de League of Legends y Valorant. Este script permite gestionar de forma inteligente el cierre de procesos de los juegos de Riot Games, reiniciar el sistema antitrampas Vanguard (vgc), reparar problemas de red y re-lanzar los titulos de manera automatica.

---

Caracteristicas Principales

* Deteccion Inteligente de Juegos: Identifica automaticamente si League of Legends o Valorant se encuentran en ejecucion en segundo plano para proceder con su cierre forzoso y seguro.
* Gestion de Procesos de Riot: Finaliza limpiamente los ejecutables principales de los juegos, asi como los servicios y controladores de errores del Riot Client.
* Reinicio del Servicio Vanguard (vgc): Detiene y vuelve a iniciar el sistema antitrampas de Riot Games para solucionar errores de inicializacion o bloqueos comunes.
* Limpieza de Cache DNS: Ejecuta un ipconfig /flushdns para mitigar problemas de conectividad, latencia o fallos al reconectarse a las partidas.
* Re-lanzamiento Automatico (Protocolo Riot Client): Vuelve a abrir de manera directa el juego que estabas ejecutando previamente (o el cliente general si no habia ninguno abierto).
* Elevacion de Privilegios Automatica: Solicita permisos de Administrador de manera transparente mediante UAC si no se ejecuta con dichos privilegios.

---

Opciones del Menu

[ 1 ] Cerrar Procesos de Riot / Juego Activo: Detecta automaticamente si LoL o Valorant estan abiertos, los cierra junto con los servicios auxiliares de Riot.
[ 2 ] Reiniciar Servicio Vanguard (vgc): Detiene y arranca nuevamente el servicio anti-cheat.
[ 3 ] Re-lanzar League of Legends: Abre el juego directamente usando el protocolo oficial de Riot.
[ 4 ] Re-lanzar Valorant: Inicia Valorant de forma directa mediante el cliente de Riot.
[ 5 ] Reparar Conexion / Flush DNS: Vacia la cache de resolucion DNS del sistema para solucionar problemas de red.
[ X ] Restart Completo: Ejecuta el ciclo completo automatizado: Deteccion/Cierre de juego -> Reinicio de Vanguard -> Limpieza DNS -> Re-lanzamiento automatico.
[ 0 ] Salir de la aplicacion.

---

Uso e Instalacion

1. Clona o descarga el repositorio en tu ordenador.
2. Haz clic derecho sobre el archivo .bat y ejecutalo (el script solicitara automaticamente permisos de Administrador por su cuenta).
3. Selecciona la opcion deseada ingresando el numero o letra correspondiente en el menu interactivo.
