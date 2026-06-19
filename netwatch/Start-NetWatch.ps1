# Start-NetWatch.ps1 - Iniciador de NetWatch VTSA
$base = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "  =====================================  " -ForegroundColor Cyan
Write-Host "        NetWatch - Monitor de Red        " -ForegroundColor Cyan
Write-Host "              VTSA v1.0                  " -ForegroundColor Cyan
Write-Host "  =====================================  " -ForegroundColor Cyan
Write-Host ""

# Liberar puerto 8080 si esta ocupado
$conn = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
if ($conn) {
    Write-Host "  [!] Puerto 8080 ocupado por PID $($conn.OwningProcess). Liberando..." -ForegroundColor Yellow
    Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Iniciar Monitor en segundo plano
Write-Host "  [1/3] Iniciando motor de monitoreo..." -ForegroundColor Green
$monitorProc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$base\NetWatch-Monitor.ps1`" -BasePath `"$base`"" -PassThru
Write-Host "        PID Monitor: $($monitorProc.Id)" -ForegroundColor DarkGray

Start-Sleep -Seconds 1

# Iniciar Servidor HTTP en segundo plano
Write-Host "  [2/3] Iniciando servidor web en localhost:8080..." -ForegroundColor Green
$serverProc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$base\NetWatch-Server.ps1`" -BasePath `"$base`"" -PassThru
Write-Host "        PID Servidor: $($serverProc.Id)" -ForegroundColor DarkGray

# Esperar que el servidor este listo
Write-Host "  [3/3] Esperando servidor..." -ForegroundColor Green
$ready = $false
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8080/login.html" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
    Write-Host "        Intento $i/20..." -ForegroundColor DarkGray
}

Write-Host ""
if ($ready) {
    Write-Host "  OK - NetWatch iniciado!" -ForegroundColor Green
    Write-Host "  URL        : http://localhost:8080" -ForegroundColor Cyan
    Write-Host "  Contrasena : Trapani2021" -ForegroundColor Cyan
    Write-Host ""
    Start-Process "http://localhost:8080"
} else {
    Write-Host "  ERROR - El servidor no respondio en el tiempo esperado." -ForegroundColor Red
    Write-Host "  Verifica que el puerto 8080 este libre e intenta de nuevo." -ForegroundColor Red
}

Write-Host ""
Write-Host "  Los servicios corren en background. Podes cerrar esta ventana." -ForegroundColor DarkGray
Write-Host "  Para detener: cierra las ventanas minimizadas de PowerShell." -ForegroundColor DarkGray
Write-Host ""
Start-Sleep -Seconds 5
