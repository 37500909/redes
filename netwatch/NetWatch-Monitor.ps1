# NetWatch Monitor v2 - Motor de monitoreo estable con Test-Connection
param([string]$BasePath = $PSScriptRoot)

$dataPath    = Join-Path $BasePath "data"
$hostsFile   = Join-Path $dataPath "hosts.json"
$statusFile  = Join-Path $dataPath "status.json"
$historyPath = Join-Path $dataPath "history"
$tracertPath = Join-Path $dataPath "tracert"

foreach ($d in @($historyPath, $tracertPath)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$downtimesFile  = Join-Path $dataPath "downtimes.json"

# Cargar estados anteriores para detectar transiciones
$previousStates = @{}
if (Test-Path $statusFile) {
    try {
        $oldStatus = Get-Content $statusFile -Raw | ConvertFrom-Json
        foreach ($h in $oldStatus.hosts) {
            $previousStates[$h.ip] = $h.status
        }
    } catch {}
}

# Funciones de downtime
function Get-Downtimes {
    if (-not (Test-Path $downtimesFile)) { return @() }
    try {
        $raw = Get-Content $downtimesFile -Raw -Encoding UTF8
        if (-not $raw -or $raw.Trim() -eq "") { return @() }
        $parsed = $raw | ConvertFrom-Json
        
        $flatten = {
            param($obj)
            if ($obj -is [Array]) {
                $res = @()
                foreach ($item in $obj) {
                    $res += & $flatten $item
                }
                return $res
            }
            if ($obj.PSObject.Properties["value"]) {
                return & $flatten $obj.value
            }
            return $obj
        }
        
        $flat = & $flatten $parsed
        
        $cleanEvents = @()
        foreach ($e in $flat) {
            if ($e -and $e.ip -and $e.downTime) {
                if ($e.ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                    $cleanEvents += [PSCustomObject]@{
                        ip       = [string]$e.ip
                        name     = [string]$e.name
                        downTime = [string]$e.downTime
                        upTime   = if ($e.upTime) { [string]$e.upTime } else { $null }
                        duration = if ($e.duration -ne $null) { [int]$e.duration } else { $null }
                    }
                }
            }
        }
        return @($cleanEvents)
    } catch {
        return @()
    }
}

function Save-Downtimes([object[]]$events) {
    ConvertTo-Json -InputObject @($events) -Depth 5 | Set-Content $downtimesFile -Encoding UTF8
}

function Start-Downtime($ip, $name, $time) {
    $events = Get-Downtimes
    
    $events += [PSCustomObject]@{
        ip        = $ip
        name      = $name
        downTime  = $time
        upTime    = $null
        duration  = $null
    }
    
    if ($events.Count -gt 100) {
        $events = $events[($events.Count-100)..($events.Count-1)]
    }
    
    Save-Downtimes $events
}

function End-Downtime($ip, $time) {
    $events = Get-Downtimes
    if ($events.Count -eq 0) { return }

    $openEvent = $events | Where-Object { $_.ip -eq $ip -and ($_.upTime -eq $null -or $_.upTime -eq "") } | Select-Object -Last 1
    if ($openEvent) {
        $openEvent.upTime = $time
        try {
            $dt1 = [DateTime]::ParseExact($openEvent.downTime, "yyyy-MM-ddTHH:mm:ss", $null)
            $dt2 = [DateTime]::ParseExact($time, "yyyy-MM-ddTHH:mm:ss", $null)
            $openEvent.duration = [math]::Round(($dt2 - $dt1).TotalSeconds, 0)
        } catch {
            $openEvent.duration = 0
        }
        Save-Downtimes $events
    }
}

Write-Host "[Monitor] Iniciado: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "[Monitor] Base: $BasePath"


while ($true) {
    try {
        if (-not (Test-Path $hostsFile)) {
            Write-Host "[Monitor] Esperando hosts.json..."
            Start-Sleep -Seconds 10
            continue
        }

        $hostsRaw = Get-Content $hostsFile -Raw -Encoding UTF8
        $parsed   = $hostsRaw | ConvertFrom-Json
        # Manejar JSON corrompido {value:[...]} generado por PowerShell
        if ($parsed.PSObject.Properties["value"]) { $parsed = $parsed.value }
        $hosts    = @($parsed)
        $enabled  = @($hosts | Where-Object { $_.enabled -eq $true })
        $now      = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        $results  = @{}
        $hostsToTrace = @()

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Pingueando $($enabled.Count) hosts..."

        foreach ($h in $enabled) {
            try {
                $pingCount = 2
                $pings = Test-Connection -ComputerName $h.ip -Count $pingCount -ErrorAction SilentlyContinue
                if ($pings) {
                    $ok   = @($pings | Where-Object { $_.StatusCode -eq 0 })
                    $loss = [math]::Round((($pingCount - $ok.Count) / $pingCount) * 100, 0)
                    $rtts = @($ok | Where-Object { $_.ResponseTime -ge 0 } | ForEach-Object { $_.ResponseTime })
                    $avg  = if ($rtts.Count -gt 0) { [math]::Round(($rtts | Measure-Object -Average).Average, 1) } else { $null }
                    $min  = if ($rtts.Count -gt 0) { ($rtts | Measure-Object -Minimum).Minimum } else { $null }
                    $max  = if ($rtts.Count -gt 0) { ($rtts | Measure-Object -Maximum).Maximum } else { $null }
                    $status = if ($loss -eq 0) { "online" } elseif ($loss -lt 75) { "warning" } else { "offline" }
                    $results[$h.ip] = @{ loss=$loss; avg=$avg; min=$min; max=$max; status=$status }
                } else {
                    $results[$h.ip] = @{ loss=100; avg=$null; min=$null; max=$null; status="offline" }
                }
            } catch {
                $results[$h.ip] = @{ loss=100; avg=$null; min=$null; max=$null; status="offline" }
            }

            # Lógica de detección de transición para caídas / recuperaciones
            $currentStatus  = $results[$h.ip].status
            $previousStatus = $previousStates[$h.ip]

            if ($currentStatus -eq "offline" -and $previousStatus -ne "offline") {
                # SE HA CAÍDO!
                Write-Host "[ALERTA] Host $($h.name) ($($h.ip)) se ha CAÍDO." -ForegroundColor Red

                # 1. Incrementar contador en hosts.json
                try {
                    $hostsRawConfig = Get-Content $hostsFile -Raw -Encoding UTF8
                    $parsedConfig   = $hostsRawConfig | ConvertFrom-Json
                    if ($parsedConfig.PSObject.Properties["value"]) { $parsedConfig = $parsedConfig.value }
                    $hostsConfigList = @($parsedConfig)
                    foreach ($hc in $hostsConfigList) {
                        if ($hc.ip -eq $h.ip) {
                            if (-not $hc.PSObject.Properties["downtimeCount"]) {
                                $hc | Add-Member -MemberType NoteProperty -Name "downtimeCount" -Value 0
                            }
                            $hc.downtimeCount = [int]$hc.downtimeCount + 1
                        }
                    }
                    ConvertTo-Json -InputObject @($hostsConfigList) -Depth 5 | Set-Content $hostsFile -Encoding UTF8
                } catch {
                    Write-Host "[Monitor ERROR] No se pudo incrementar downtimeCount para $($h.ip): $($_.Exception.Message)"
                }

                # 2. Registrar en downtimes.json
                Start-Downtime $h.ip $h.name $now
            }
            elseif ($previousStatus -eq "offline" -and ($currentStatus -eq "online" -or $currentStatus -eq "warning")) {
                # SE HA RECUPERADO!
                Write-Host "[INFO] Host $($h.name) ($($h.ip)) se ha RECUPERADO." -ForegroundColor Green
                End-Downtime $h.ip $now
            }

            # Guardar el estado actual en memoria para la siguiente iteración
            $previousStates[$h.ip] = $currentStatus
        }

        # Construir status
        $statusHosts = @()
        foreach ($h in $hosts) {
            $safe = $h.ip.Replace('.','_')
            if (-not $h.enabled) {
                $statusHosts += [PSCustomObject]@{
                    ip=$h.ip; name=$h.name; group=$h.group
                    status="disabled"; loss=$null; avgLatency=$null
                    minLatency=$null; maxLatency=$null; timestamp=$now
                }
                continue
            }
            $r = $results[$h.ip]
            $entry = [PSCustomObject]@{
                ip=$h.ip; name=$h.name; group=$h.group
                status     = $r.status
                loss       = $r.loss
                avgLatency = $r.avg
                minLatency = $r.min
                maxLatency = $r.max
                timestamp  = $now
            }
            $statusHosts += $entry

            # Historial
            $histFile = Join-Path $historyPath "$safe.json"
            $hist = @()
            if (Test-Path $histFile) {
                try { $hist = @(Get-Content $histFile -Raw | ConvertFrom-Json) } catch {}
            }
            $hist += [PSCustomObject]@{
                t = (Get-Date -Format "HH:mm:ss")
                l = $r.avg
                p = $r.loss
            }
            if ($hist.Count -gt 120) { $hist = $hist[($hist.Count-120)..($hist.Count-1)] }
            try { $hist | ConvertTo-Json -Compress | Set-Content $histFile -Encoding UTF8 } catch {}
            # Tracert diferido si hay pérdida (max cada 5 min)
            if ($r.loss -gt 0) {
                $hostsToTrace += [PSCustomObject]@{ ip = $h.ip; safe = $safe }
            }
        }

        # Guardar status.json (se guarda inmediatamente al terminar los pings para máxima velocidad en la UI)
        $statusObj = [PSCustomObject]@{ timestamp=$now; hosts=$statusHosts }
        $statusObj | ConvertTo-Json -Depth 5 | Set-Content $statusFile -Encoding UTF8

        $on  = @($statusHosts | Where-Object { $_.status -eq "online"  }).Count
        $off = @($statusHosts | Where-Object { $_.status -eq "offline" }).Count
        $wrn = @($statusHosts | Where-Object { $_.status -eq "warning" }).Count
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Online:$on  Warning:$wrn  Offline:$off"

        # Ejecutar tracert pendientes (asíncronamente diferidos al final del ciclo)
        foreach ($traceJob in $hostsToTrace) {
            $tf = Join-Path $tracertPath "$($traceJob.safe).json"
            $doTrace = $true
            if (Test-Path $tf) {
                try {
                    $prev = Get-Content $tf -Raw | ConvertFrom-Json
                    if ((Get-Date) - [DateTime]::ParseExact($prev.timestamp,"yyyy-MM-ddTHH:mm:ss",$null) -lt [TimeSpan]::FromMinutes(5)) {
                        $doTrace = $false
                    }
                } catch {}
            }
            if ($doTrace) {
                Write-Host "[Monitor] Iniciando tracert de diagnóstico para $($traceJob.ip)..."
                $raw   = & tracert -d -h 20 -w 1000 $traceJob.ip 2>&1
                $hops  = @()
                $hopRx = '^\s*(\d+)\s+(?:<?\s*(\d+)\s*ms|(\*))\s+(?:<?\s*(\d+)\s*ms|(\*))\s+(?:<?\s*(\d+)\s*ms|(\*))\s+([\d.]+|\*)'
                foreach ($line in $raw) {
                    if ($line -match $hopRx) {
                        $ms = @($Matches[2],$Matches[4],$Matches[6]) | Where-Object {$_} | ForEach-Object {[int]$_}
                        $hops += [PSCustomObject]@{
                            hop     = $([int]$Matches[1])
                            ip      = if($Matches[8]-ne'*'){$Matches[8]}else{$null}
                            timeout = ($ms.Count-eq 0)
                            avgMs   = if($ms.Count-gt 0){[math]::Round(($ms|Measure-Object -Average).Average,0)}else{$null}
                        }
                    }
                }
                try {
                    [PSCustomObject]@{ip=$traceJob.ip;timestamp=$now;hops=$hops;raw=($raw-join"`n")} |
                        ConvertTo-Json -Depth 5 | Set-Content $tf -Encoding UTF8
                } catch {}
            }
        }
    } catch {
        Write-Host "[Monitor ERROR] $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 15
}
