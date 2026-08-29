@echo off
NET SESSION >nul 2>&1
if %errorLevel% NEQ 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

setlocal enabledelayedexpansion
title Reinicio y Reparacion de Riot Services - MARCKO-SYGMATCH
mode con cols=95 lines=38
color 0B

:MENU
cls
echo.
echo  ========================================================================================
echo   M A R C K O  -  S Y G M A T C H   ^|   VANGUARD FIX ^& REBOOT
echo  ========================================================================================
echo.
echo   [ 1 ] CERRAR PROCESOS DE RIOT / LEAGUE OF LEGENDS
echo         ^> Fuerza el cierre de clientes y ejecutable colgados en memoria.
echo.
echo   [ 2 ] REINICIAR SERVICIO VANGUARD (vgc)
echo         ^> Detiene y vuelve a iniciar el sistema anti-trampas en segundo plano.
echo.
echo   [ 3 ] RE-LANZAR LEAGUE OF LEGENDS
echo         ^> Inicia el juego directamente utilizando el protocolo de Riot Client.
echo.
echo   [ 4 ] REPARAR CONEXION / FLUSH DNS
echo         ^> Limpia la cache DNS de Windows para resolver problemas de reconexion.
echo.
echo   [ X ] EJECUTAR RESTART COMPLETO (Cerrar, Reiniciar vgc, Limpiar DNS y Re-lanzar)
echo.
echo   [ 0 ] Salir
echo.
echo  ========================================================================================
set /p opcion=" Selecciona una opcion [1-4, X o 0]: "

if "%opcion%"=="1" goto OPCION_1
if "%opcion%"=="2" goto OPCION_2
if "%opcion%"=="3" goto OPCION_3
if "%opcion%"=="4" goto OPCION_4
if /i "%opcion%"=="X" goto OPCION_X
if "%opcion%"=="0" exit
goto MENU

:OPCION_1
cls
echo.
echo  ========================================================================================
echo   CERRANDO PROCESOS DE RIOT Y LEAGUE OF LEGENDS
echo  ========================================================================================
echo.
echo [!] Finalizando ejecutable de League of Legends...
taskkill /f /im "League of Legends.exe" >nul 2>&1
echo [!] Finalizando servicios de Riot Client...
taskkill /f /im "RiotClientServices.exe" >nul 2>&1
taskkill /f /im "RiotClientCrashHandler.exe" >nul 2>&1
echo.
echo [OK] Procesos cerrados de forma limpia.
pause
goto MENU

:OPCION_2
cls
echo.
echo  ========================================================================================
echo   REINICIANDO SERVICIO VANGUARD (vgc)
echo  ========================================================================================
echo.
echo [!] Deteniendo servicio vgc...
net stop vgc >nul 2>&1
timeout /t 2 /nobreak >nul
echo [!] Iniciando servicio vgc...
net start vgc >nul 2>&1
echo.
echo [OK] Servicio Vanguard reiniciado con exito.
pause
goto MENU

:OPCION_3
cls
echo.
echo  ========================================================================================
echo   INICIANDO LEAGUE OF LEGENDS
echo  ========================================================================================
echo.
echo [!] Enviando orden de arranque a Riot Client...
start "" "riotclient://launch-product=league_of_legends&line=live"
echo.
echo [OK] Solicitud enviada correctamente.
timeout /t 2 /nobreak >nul
goto MENU

:OPCION_4
cls
echo.
echo  ========================================================================================
echo   LIMPIEZA DE CACHE DNS DE RED
echo  ========================================================================================
echo.
echo [!] Limpiando la cache de resolucion DNS...
ipconfig /flushdns >nul 2>&1
echo.
echo [OK] Cache DNS vaciada con exito.
pause
goto MENU

:OPCION_X
cls
echo.
echo  ========================================================================================
echo   EJECUTANDO RECONEXION Y RESTART COMPLETO
echo  ========================================================================================
echo.
echo [1/4] Cerrando procesos colgados de Riot...
taskkill /f /im "League of Legends.exe" >nul 2>&1
taskkill /f /im "RiotClientServices.exe" >nul 2>&1
taskkill /f /im "RiotClientCrashHandler.exe" >nul 2>&1
timeout /t 2 /nobreak >nul

echo [2/4] Reiniciando servicio de seguridad Vanguard (vgc)...
net stop vgc >nul 2>&1
timeout /t 2 /nobreak >nul
net start vgc >nul 2>&1

echo [3/4] Refrescando la red y tabla DNS...
ipconfig /flushdns >nul 2>&1
timeout /t 2 /nobreak >nul

echo [4/4] Invocando inicio de League of Legends...
start "" "riotclient://launch-product=league_of_legends&line=live"

echo.
echo  ========================================================================================
echo   [OK] PROCESO FINALIZADO DE FORMA LIMPIA.
echo  ========================================================================================
echo.
timeout /t 3 /nobreak >nul
exit
