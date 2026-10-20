# grant-nabu-ssh-windows.ps1 — el EMPLEADO (o Daniel en su compu) lo corre UNA VEZ en Windows
# Le da a NABU acceso remoto por SSH para soporte y tareas remotas (túnel), y deja Tailscale
# instalado para que funcione también fuera de la oficina. Equivalente Windows de grant-nabu-ssh.sh.
#
# Uso: abrir PowerShell COMO ADMINISTRADOR (clic derecho → «Ejecutar como administrador») y pegar:
#
#   irm https://raw.githubusercontent.com/dcalder0n/nabu-chat/main/grant-nabu-ssh-windows.ps1 | iex
#
# Probado el 20-oct-2026 en la compu de Emilio (Windows 10 Pro en español). Lo que aprendimos ahí:
#  - El OpenSSH que trae Windows como «característica» se traba al arrancar como servicio en Windows
#    en español → se usa el OpenSSH oficial de Microsoft vía winget.
#  - El bloque «Match Group administrators» del sshd_config no encuentra el grupo («Administradores»)
#    → se quita; la llave va en el authorized_keys del propio usuario.
#  - Aun así el servicio puede quedar en StartPending → sshd arranca con una TAREA PROGRAMADA al
#    iniciar sesión el empleado (con privilegios altos) y el servicio queda deshabilitado.
#  - icacls con nombres de grupo falla en español → se usan SIDs (*S-1-5-32-544, *S-1-5-18).

$ErrorActionPreference = 'Continue'
$NabuKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILzZe3i9vSMRXVu/cypfva5/hSCR+PJeZnXP201yROZ2 danielcalderon@Mac'

function Paso($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host "Abrí PowerShell como ADMINISTRADOR y volvé a correrlo." -ForegroundColor Red; return
}

Paso "1/6 OpenSSH oficial de Microsoft"
$sshd = 'C:\Program Files\OpenSSH\sshd.exe'
if (-not (Test-Path $sshd)) {
  winget install --id Microsoft.OpenSSH.Preview -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
}
if (-not (Test-Path $sshd)) { Write-Host "No se pudo instalar OpenSSH. Avisale a Daniel." -ForegroundColor Red; return }
Write-Host "OK $sshd"

Paso "2/6 Llave de NABU"
New-Item -Force -ItemType Directory "$env:USERPROFILE\.ssh" | Out-Null
$ak = "$env:USERPROFILE\.ssh\authorized_keys"
if (-not (Test-Path $ak) -or -not (Select-String -Path $ak -SimpleMatch $NabuKey -Quiet)) { Add-Content -Path $ak -Value $NabuKey }
$aak = "$env:ProgramData\ssh\administrators_authorized_keys"
New-Item -Force -ItemType Directory "$env:ProgramData\ssh" | Out-Null
if (-not (Test-Path $aak) -or -not (Select-String -Path $aak -SimpleMatch $NabuKey -Quiet)) { Add-Content -Path $aak -Value $NabuKey }
icacls $aak /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" | Out-Null
Write-Host "OK"

Paso "3/6 Configuración de SSH (sin el bloque de administradores, consola Git Bash)"
$cfg = "$env:ProgramData\ssh\sshd_config"
if (Test-Path $cfg) {
  Copy-Item $cfg "$cfg.bak" -Force
  (Get-Content $cfg) | Where-Object { $_ -notmatch '^\s*Match Group administrators' -and $_ -notmatch '__PROGRAMDATA__/ssh/administrators_authorized_keys' } | Set-Content $cfg
}
if (Test-Path 'C:\Program Files\Git\bin\bash.exe') {
  New-Item -Force 'HKLM:\SOFTWARE\OpenSSH' | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Program Files\Git\bin\bash.exe' -PropertyType String -Force | Out-Null
}
Write-Host "OK"

Paso "4/6 Firewall (puerto 22, cualquier red)"
Remove-NetFirewallRule -Name sshd,OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue
New-NetFirewallRule -Name OpenSSH-Server-In-TCP -DisplayName 'OpenSSH Server (NABU)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any | Out-Null
Write-Host "OK"

Paso "5/6 Arranque automático (tarea programada al iniciar sesión)"
Stop-Service sshd -Force -ErrorAction SilentlyContinue
Get-Process sshd -ErrorAction SilentlyContinue | Stop-Process -Force
sc.exe config sshd start= disabled | Out-Null
$u = $env:USERNAME
$a = New-ScheduledTaskAction -Execute $sshd
$t = New-ScheduledTaskTrigger -AtLogOn -User $u
$p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'OpenSSH-Daemon' -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null
Start-Process $sshd -WindowStyle Hidden
Start-Sleep 4
$escucha = [bool](Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)
Write-Host ("SSH escuchando: " + $escucha)

Paso "6/6 Tailscale (para entrar fuera de la oficina)"
$ts = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $ts)) { winget install --id Tailscale.Tailscale -e --silent --accept-source-agreements --accept-package-agreements | Out-Null }
if (Test-Path $ts) {
  & $ts up --unattended --hostname=("$env:USERNAME-pc".ToLower()) --timeout=15s 2>&1 | Select-String 'login.tailscale.com' | ForEach-Object { Write-Host "Abrí este enlace y entrá con daniel@nabu.com.gt: $_" -ForegroundColor Yellow }
}

Write-Host "`n==================== MANDALE ESTO A DANIEL ====================" -ForegroundColor Green
Write-Host ("Usuario: " + $env:USERNAME + "   Compu: " + $env:COMPUTERNAME)
Write-Host ("IP oficina: " + ((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' -and $_.IPAddress -notlike '100.*' }).IPAddress -join ', '))
if (Test-Path $ts) { Write-Host ("Tailscale: " + ((& $ts ip -4 2>$null) -join ', ')) }
Write-Host ("SSH: " + $(if ($escucha) { 'LISTO' } else { 'NO ARRANCÓ' }))
