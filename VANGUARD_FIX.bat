<#
.SYNOPSIS
    Reinicio y Reparacion de Riot Services - MARCKO-SYGMATCH (GUI Edition)
.DESCRIPTION
    Script avanzado con interfaz grafica en Windows Forms para la gestion,
    limpieza de procesos, reinicio de Vanguard y reparacion de red para LoL y Valorant.
.LINK
    https://github.com/Sygmatch/Vanguard_Fix
#>

# Asegurar privilegios de Administrador
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ==========================================
# CREACION DE LA INTERFAZ GRAFICA (GUI)
# ==========================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "MARCKO-SYGMATCH | Vanguard Fix & Reboot GUI"
$form.Size = New-Object System.Drawing.Size(680, 565)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
$form.ForeColor = [System.Drawing.Color]::White

# Titulo Superior
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "MARCKO-SYGMATCH | GESTOR DE RIOT & VANGUARD"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 210, 255)
$lblTitle.Location = New-Object System.Drawing.Point(20, 15)
$lblTitle.Size = New-Object System.Drawing.Size(620, 30)
$form.Controls.Add($lblTitle)

# Consola de Registro / Salida (RichTextBox)
$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 55)
$txtLog.Size = New-Object System.Drawing.Size(410, 450)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 28)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(0, 255, 128)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)

# Funcion para escribir en el log
function Write-Log {
    param([string]$Message, [string]$Type = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $colorPrefix = "[$timestamp] [$Type] "
    $txtLog.AppendText("$colorPrefix$Message`n")
    $txtLog.ScrollToCaret()
}

# ==========================================
# LOGICA DE LAS ACCIONES
# ==========================================

function Invoke-CloseRiotProcesses {
    Write-Log "Detectando y cerrando juegos y procesos de Riot..." "ACTION"
    $juegoDetectado = $false

    # Verificacion y cierre completo de League of Legends (Cierre total de subprocesos)
    $lolProcesses = @("League of Legends", "LeagueClient", "LeagueClientUx", "LeagueClientUxRender", "LeagueCrashHandler")
    $lolRunning = Get-Process -Name $lolProcesses -ErrorAction SilentlyContinue
    if ($lolRunning) {
        $juegoDetectado = "LoL"
        Write-Log "Se detecto League of Legends activo. Forzando cierre total..." "WARN"
        foreach ($proc in $lolProcesses) {
            Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue
        }
    }

    # Verificacion y cierre completo de Valorant (Cierre total de subprocesos)
    $valProcesses = @("VALORANT", "Valorant-Win64-Shipping", "RiotClientServices", "RiotClientCrashHandler")
    $valRunning = Get-Process -Name $valProcesses -ErrorAction SilentlyContinue
    if ($valRunning) {
        $juegoDetectado = "Valorant"
        Write-Log "Se detecto Valorant activo. Forzando cierre total..." "WARN"
        foreach ($proc in $valProcesses) {
            Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue
        }
    }

    # Asegurar cierre de servicios generales de Riot Client
    Stop-Process -Name "RiotClientServices", "RiotClientCrashHandler" -Force -ErrorAction SilentlyContinue

    if (-not $juegoDetectado) {
        Write-Log "No se encontro ningun juego principal abierto (LoL o Valorant)." "INFO"
    }
    Write-Log "Procesos cerrados de forma limpia." "SUCCESS"
    Write-Log "--------------------------------------------------"
    return $juegoDetectado
}

function Invoke-RestartVanguard {
    Write-Log "Reiniciando servicio de seguridad Vanguard (vgc)..." "ACTION"
    Write-Log "Deteniendo servicio vgc..." "INFO"
    net stop vgc | Out-Null
    Start-Sleep -Seconds 2
    Write-Log "Iniciando servicio vgc..." "INFO"
    net start vgc | Out-Null
    Write-Log "Servicio Vanguard reiniciado con exito." "SUCCESS"
    Write-Log "--------------------------------------------------"
}

function Invoke-LaunchLoL {
    Write-Log "Enviando orden de arranque a Riot Client para League of Legends..." "ACTION"
    Start-Process "riotclient://launch-product=league_of_legends&line=live"
    Write-Log "Solicitud enviada correctamente." "SUCCESS"
    Write-Log "--------------------------------------------------"
}

function Invoke-LaunchValorant {
    Write-Log "Enviando orden de arranque a Riot Client para Valorant..." "ACTION"
    Start-Process "riotclient://launch-product=valorant&line=live"
    Write-Log "Solicitud enviada correctamente." "SUCCESS"
    Write-Log "--------------------------------------------------"
}

function Invoke-FlushDNS {
    Write-Log "Limpiando la cache de resolucion DNS..." "ACTION"
    ipconfig /flushdns | Out-Null
    Write-Log "Cache DNS vaciada con exito." "SUCCESS"
    Write-Log "--------------------------------------------------"
}

function Invoke-CompleteRestart {
    Write-Log "=== EJECUTANDO RESTART COMPLETO ===" "ACTION"
    $juego = Invoke-CloseRiotProcesses
    Start-Sleep -Seconds 1
    Invoke-RestartVanguard
    Start-Sleep -Seconds 1
    Invoke-FlushDNS
    Start-Sleep -Seconds 1

    Write-Log "Re-lanzando el juego detectado o cliente..." "ACTION"
    if ($juego -eq "LoL") {
        Write-Log "Iniciando League of Legends..." "INFO"
        Start-Process "riotclient://launch-product=league_of_legends&line=live"
    } elseif ($juego -eq "Valorant") {
        Write-Log "Iniciando Valorant..." "INFO"
        Start-Process "riotclient://launch-product=valorant&line=live"
    } else {
        Write-Log "No habia juego abierto, abriendo Riot Client general..." "INFO"
        Start-Process "riotclient://launch-product=riot&line=live"
    }
    Write-Log "Proceso completado exitosamente." "SUCCESS"
    Write-Log "=================================================="
}

function Open-GitHubRepo {
    Write-Log "Abriendo repositorio de GitHub..." "INFO"
    Start-Process "https://github.com/Sygmatch/Vanguard_Fix"
}

# ==========================================
# CREACION DE BOTONES DE LA GUI
# ==========================================

function New-CustomButton {
    param($text, $yPos, $action, $bgColor = [System.Drawing.Color]::FromArgb(45, 45, 48))
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Location = New-Object System.Drawing.Point(445, $yPos)
    $btn.Size = New-Object System.Drawing.Size(205, 38)
    $btn.BackColor = $bgColor
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 1
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btn.Add_Click($action)
    return $btn
}

$form.Controls.Add((New-CustomButton "Cerrar Procesos Riot/Juego" 55 { Invoke-CloseRiotProcesses }))
$form.Controls.Add((New-CustomButton "Reiniciar Vanguard (vgc)" 100 { Invoke-RestartVanguard }))
$form.Controls.Add((New-CustomButton "Re-lanzar LoL" 145 { Invoke-LaunchLoL }))
$form.Controls.Add((New-CustomButton "Re-lanzar Valorant" 190 { Invoke-LaunchValorant }))
$form.Controls.Add((New-CustomButton "Reparar Conexion / DNS" 235 { Invoke-FlushDNS }))

# Boton Destacado para Restart Completo (Sin la 'X')
$form.Controls.Add((New-CustomButton "RESTART COMPLETO" 290 { Invoke-CompleteRestart } ([System.Drawing.Color]::FromArgb(0, 122, 204))))

# Boton de GitHub
$form.Controls.Add((New-CustomButton "GitHub: Vanguard_Fix" 345 { Open-GitHubRepo } ([System.Drawing.Color]::FromArgb(33, 110, 83))))

# Boton Salir (Sin número)
$form.Controls.Add((New-CustomButton "Salir" 467 { $form.Close() } ([System.Drawing.Color]::FromArgb(180, 50, 50))))

# Mensaje inicial en consola
Write-Log "Sistema listo. Seleccione una opcion del menu." "INFO"
Write-Log "Repositorio oficial: https://github.com/Sygmatch/Vanguard_Fix" "INFO"

# Mostrar Formulario
[void]$form.ShowDialog()
