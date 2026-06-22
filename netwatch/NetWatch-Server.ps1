# NetWatch Server - Servidor HTTP local con autenticacion
# Escucha en http://localhost:8080 (solo local, no accesible desde otras PCs)

param([string]$BasePath = $PSScriptRoot)

$password = "Trapani2021"
$wwwPath  = Join-Path $BasePath "www"
$dataPath = Join-Path $BasePath "data"
$port     = 8080

$globalGatewayIp = ""
try {
    $globalGatewayIp = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty NextHop -First 1
} catch {}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()

$sessions = @{}   # token -> @{created=DateTime}

Write-Host "[NetWatch Server] Escuchando en http://localhost:$port"
Write-Host "[NetWatch Server] Presiona Ctrl+C para detener"

function Get-MimeType($path) {
    switch ([System.IO.Path]::GetExtension($path).ToLower()) {
        ".html" { "text/html; charset=utf-8" }
        ".css"  { "text/css; charset=utf-8" }
        ".js"   { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".png"  { "image/png" }
        ".ico"  { "image/x-icon" }
        ".svg"  { "image/svg+xml" }
        default { "text/plain; charset=utf-8" }
    }
}

function Send-Json($resp, $obj, $code = 200) {
    $body  = if ($obj -is [string]) { $obj } else { $obj | ConvertTo-Json -Depth 10 -Compress }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $resp.StatusCode      = $code
    $resp.ContentType     = "application/json; charset=utf-8"
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Send-Text($resp, $text, $mime = "text/html; charset=utf-8", $code = 200) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $resp.StatusCode      = $code
    $resp.ContentType     = $mime
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Send-File($resp, $filePath) {
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    $resp.StatusCode      = 200
    $resp.ContentType     = Get-MimeType $filePath
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Send-Redirect($resp, $url) {
    $resp.StatusCode = 302
    $resp.Headers.Add("Location", $url)
    $resp.ContentLength64 = 0
    $resp.Close()
}

function Test-Session($req) {
    $cookie = $req.Cookies["nw_sess"]
    if (-not $cookie) { return $false }
    $s = $sessions[$cookie.Value]
    if (-not $s) { return $false }
    if ((Get-Date) - $s.created -gt [TimeSpan]::FromHours(8)) {
        $sessions.Remove($cookie.Value); return $false
    }
    return $true
}

function Read-Body($req) {
    try {
        $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
        return $sr.ReadToEnd()
    } catch { return "" }
}

function Get-Hosts {
    $raw    = Get-Content (Join-Path $dataPath "hosts.json") -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json
    # Manejar formato corrompido {value:[...], Count:N}
    if ($parsed.PSObject.Properties["value"]) { return @($parsed.value) }
    return @($parsed)
}
function Save-Hosts([object[]]$h) {
    # Usar -InputObject para garantizar salida como array JSON []
    ConvertTo-Json -InputObject @($h) -Depth 5 | Set-Content (Join-Path $dataPath "hosts.json") -Encoding UTF8
}

function Get-Downtimes {
    $f = Join-Path $dataPath "downtimes.json"
    if (-not (Test-Path $f)) { return @() }
    try {
        $raw = Get-Content $f -Raw -Encoding UTF8
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

# Archivos accesibles sin auth (solo la pagina de login)
$publicFiles = @("login.html", "favicon.ico")

while ($listener.IsListening) {
    try {
        $ctx  = $listener.GetContext()
        $req  = $ctx.Request
        $resp = $ctx.Response
        $url  = $req.Url.LocalPath.TrimEnd('/')
        $meth = $req.HttpMethod.ToUpper()
        if ($url -eq "") { $url = "/" }

        Write-Host "[$meth] $url"

        # ────────── LOGIN ──────────
        if ($url -eq "/api/login" -and $meth -eq "POST") {
            $body = Read-Body $req
            try { $data = $body | ConvertFrom-Json } catch { $data = $null }
            if ($data -and $data.password -eq $password) {
                $token = [Guid]::NewGuid().ToString("N")
                $sessions[$token] = @{ created = Get-Date }
                $cookie = New-Object System.Net.Cookie("nw_sess", $token, "/")
                $cookie.HttpOnly = $true
                $resp.Cookies.Add($cookie)
                Send-Json $resp @{ success = $true }
            } else {
                Send-Json $resp @{ success = $false; error = "Contraseña incorrecta" } 401
            }
            continue
        }

        # ────────── LOGOUT ──────────
        if ($url -eq "/api/logout") {
            $cookie = $req.Cookies["nw_sess"]
            if ($cookie) { $sessions.Remove($cookie.Value) }
            Send-Redirect $resp "/login.html"
            continue
        }

        # ────────── CHECK AUTH ──────────
        $isPublic = ($publicFiles | Where-Object { $url -eq "/$_" -or $url -eq "/" + $_ })
        $isAuthed = Test-Session $req

        if (-not $isPublic -and -not $isAuthed) {
            if ($url.StartsWith("/api/")) { Send-Json $resp @{ error = "No autorizado" } 401 }
            else { Send-Redirect $resp "/login.html" }
            continue
        }

        # ────────── ROOT → index ──────────
        if ($url -eq "/" -or $url -eq "") {
            Send-Redirect $resp "/index.html"
            continue
        }

        # ────────── API ──────────
        if ($url.StartsWith("/api/")) {
            switch ($url) {

                "/api/status" {
                    $f = Join-Path $dataPath "status.json"
                    $statusJson = if (Test-Path $f) { Get-Content $f -Raw } else { '{"timestamp":null,"hosts":[]}' }
                    try {
                        $statusObj = $statusJson | ConvertFrom-Json
                        if ($statusObj) {
                            if (-not $statusObj.PSObject.Properties["gatewayIp"]) {
                                $statusObj | Add-Member -MemberType NoteProperty -Name "gatewayIp" -Value $globalGatewayIp
                            } else {
                                $statusObj.gatewayIp = $globalGatewayIp
                            }
                            Send-Json $resp $statusObj
                        } else {
                            Send-Json $resp $statusJson
                        }
                    } catch {
                        Send-Json $resp $statusJson
                    }
                }

                "/api/downtimes" {
                    try {
                        $events = Get-Downtimes
                        Send-Json $resp $events
                    } catch {
                        Send-Json $resp '[]'
                    }
                }

                "/api/hosts" {
                    if ($meth -eq "GET") {
                         Send-Json $resp (Get-Content (Join-Path $dataPath "hosts.json") -Raw)
                    }
                    elseif ($meth -eq "POST") {
                        $data  = Read-Body $req | ConvertFrom-Json
                        $hosts = Get-Hosts
                        if (@($hosts | Where-Object { $_.ip -eq $data.ip }).Count -gt 0) {
                            Send-Json $resp @{ success = $false; error = "La IP ya existe" }
                        } else {
                            $internetAccess = $null
                            if ($data.PSObject.Properties["internetAccess"]) {
                                $internetAccess = [bool]$data.internetAccess
                            }
                            $newHost = [PSCustomObject]@{
                                ip             = $data.ip.Trim()
                                name           = if ($data.name -and $data.name.Trim()) { $data.name.Trim() } else { $data.ip.Trim() }
                                group          = if ($data.group -and $data.group.Trim()) { $data.group.Trim() } else { "General" }
                                enabled        = $true
                                downtimeCount  = 0
                                internetAccess = $internetAccess
                            }
                            # Add switch-specific fields if present
                            if ($data.PSObject.Properties["isSwitch"] -and $data.isSwitch) {
                                $newHost | Add-Member -MemberType NoteProperty -Name "isSwitch" -Value $true
                                $newHost | Add-Member -MemberType NoteProperty -Name "snmpCommunity" -Value $(if ($data.snmpCommunity) { $data.snmpCommunity } else { "public" })
                                $newHost | Add-Member -MemberType NoteProperty -Name "switchWebUrl" -Value $(if ($data.switchWebUrl) { $data.switchWebUrl } else { "http://$($data.ip.Trim())" })
                                $newHost | Add-Member -MemberType NoteProperty -Name "switchUser" -Value $(if ($data.switchUser) { $data.switchUser } else { "admin" })
                                $newHost | Add-Member -MemberType NoteProperty -Name "switchPass" -Value $(if ($data.switchPass) { $data.switchPass } else { "" })
                                $newHost | Add-Member -MemberType NoteProperty -Name "switchPortsRJ45" -Value $(if ($data.switchPortsRJ45) { [int]$data.switchPortsRJ45 } else { 24 })
                                $newHost | Add-Member -MemberType NoteProperty -Name "switchPortsSFP" -Value $(if ($data.switchPortsSFP) { [int]$data.switchPortsSFP } else { 4 })
                            }
                            $list = [System.Collections.Generic.List[object]]::new()
                            foreach ($h in $hosts) { $list.Add($h) }
                            $list.Add($newHost)
                            Save-Hosts $list.ToArray()
                            Send-Json $resp @{ success = $true }
                        }
                    }
                    elseif ($meth -eq "DELETE") {
                        $ip    = $req.QueryString["ip"]
                        $hosts = @(Get-Hosts | Where-Object { $_.ip -ne $ip })
                        Save-Hosts $hosts
                        # Limpiar historial y tracert de esa IP
                        $safe = $ip.Replace('.', '_')
                        @("history\$safe.json", "tracert\$safe.json") | ForEach-Object {
                            $f = Join-Path $dataPath $_
                            if (Test-Path $f) { Remove-Item $f -Force }
                        }
                        Send-Json $resp @{ success = $true }
                    }
                }

                "/api/hosts/remove" {
                    # POST alternativo a DELETE para mayor compatibilidad
                    $data  = Read-Body $req | ConvertFrom-Json
                    $ip    = $data.ip
                    $hosts = @(Get-Hosts | Where-Object { $_.ip -ne $ip })
                    Save-Hosts $hosts
                    # Limpiar historial y tracert de esa IP
                    $safe = $ip.Replace('.', '_')
                    @("history\$safe.json", "tracert\$safe.json") | ForEach-Object {
                        $f = Join-Path $dataPath $_
                        if (Test-Path $f) { Remove-Item $f -Force }
                    }
                    Send-Json $resp @{ success = $true }
                }

                "/api/hosts/bulk" {
                    $data  = Read-Body $req | ConvertFrom-Json
                    $hosts = Get-Hosts
                    $added = 0; $skipped = 0
                    $list  = [System.Collections.Generic.List[object]]::new()
                    foreach ($h in $hosts) { $list.Add($h) }

                    foreach ($h in $data.hosts) {
                        $ip = $h.ip.Trim()
                        if (-not $ip -or ($list | Where-Object { $_.ip -eq $ip })) { $skipped++; continue }
                        $newHost = [PSCustomObject]@{
                            ip      = $ip
                            name    = if ($h.name)  { $h.name.Trim() }  else { $ip }
                            group   = if ($h.group) { $h.group.Trim() } else { "General" }
                            enabled = $true
                        }
                        $list.Add($newHost)
                        $added++
                    }
                    Save-Hosts $list.ToArray()
                    Send-Json $resp @{ success = $true; added = $added; skipped = $skipped }
                }

                "/api/toggle" {
                    $data  = Read-Body $req | ConvertFrom-Json
                    $hosts = Get-Hosts
                    foreach ($h in $hosts) {
                        if ($h.ip -eq $data.ip) { $h.enabled = [bool]$data.enabled }
                    }
                    Save-Hosts $hosts
                    Send-Json $resp @{ success = $true }
                }

                "/api/arp" {
                    # Tabla ARP + deteccion de vendor por OUI
                    $arpRaw = & arp -a 2>&1
                    $entries = @()
                    $vendorMap = @{
                        '00:50:56' = 'VMware'; '00:0c:29' = 'VMware';
                        '00:15:5d' = 'Microsoft Hyper-V'; '00:03:ff' = 'Microsoft';
                        'a0:36:bc' = 'Intel'; '8c:8d:28' = 'Intel';
                        '18:03:73' = 'Intel'; '1c:69:7a' = 'Intel';
                        'b4:45:06' = 'Intel'; '00:1a:4b' = 'Intel';
                        'd4:81:d7' = 'HP'; '00:17:a4' = 'HP'; '3c:d9:2b' = 'HP';
                        'f0:1f:af' = 'HP'; 'b8:27:eb' = 'Raspberry Pi';
                        'dc:a6:32' = 'Raspberry Pi'; 'e4:5f:01' = 'Raspberry Pi';
                        '00:e0:4c' = 'Realtek'; '52:54:00' = 'QEMU/KVM';
                        'fc:aa:14' = 'Cisco'; '00:0f:34' = 'Cisco';
                        'a4:4c:11' = 'Cisco'; '00:1b:54' = 'Cisco';
                        'c8:9c:1d' = 'Cisco'; 'f8:72:ea' = 'Cisco';
                        '00:80:c8' = 'D-Link'; '1c:7e:e5' = 'D-Link';
                        '00:11:95' = 'TP-Link'; '7c:8b:ca' = 'TP-Link';
                        'f4:f2:6d' = 'TP-Link'; '50:d4:f7' = 'TP-Link';
                        '00:25:9c' = 'Cisco/Meraki'; '88:15:44' = 'Fortinet';
                        '00:09:0f' = 'Fortinet'; '90:6c:ac' = 'Fortinet'
                    }
                    foreach ($line in $arpRaw) {
                        if ($line -match '(\d+\.\d+\.\d+\.\d+)\s+([\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2})') {
                            $ip  = $Matches[1]
                            $mac = $Matches[2].ToLower().Replace('-',':')
                            $oui = $mac.Substring(0, 8)
                            $vendor = if ($vendorMap.ContainsKey($oui)) { $vendorMap[$oui] } else { '' }
                            $entries += [PSCustomObject]@{
                                ip     = $ip
                                mac    = $mac.ToUpper()
                                vendor = $vendor
                                oui    = $oui
                            }
                        }
                    }
                    Send-Json $resp ([PSCustomObject]@{ entries = $entries } | ConvertTo-Json -Depth 5)
                }

                "/api/tracert" {
                    $ip   = $req.QueryString["ip"]
                    $safe = $ip.Replace('.', '_')
                    $f    = Join-Path $dataPath "tracert\$safe.json"
                    if (Test-Path $f) {
                        Send-Json $resp (Get-Content $f -Raw)
                    } else {
                        # Correr tracert ahora (sincrono)
                        $raw  = & tracert -d -h 20 -w 1000 $ip 2>&1
                        $hops = @()
                        $hopRx = '^\s*(\d+)\s+(?:<?\s*(\d+)\s*ms|(\*))\s+(?:<?\s*(\d+)\s*ms|(\*))\s+(?:<?\s*(\d+)\s*ms|(\*))\s+([\d.]+|\*)'
                        foreach ($line in $raw) {
                            if ($line -match $hopRx) {
                                $ms = @($Matches[2],$Matches[4],$Matches[6]) | Where-Object { $_ } | ForEach-Object { [int]$_ }
                                $hops += [PSCustomObject]@{
                                    hop = [int]$Matches[1]; ip = if ($Matches[8] -ne '*') {$Matches[8]} else {$null}
                                    timeout = ($ms.Count -eq 0)
                                    avgMs = if ($ms.Count -gt 0) { [math]::Round(($ms | Measure-Object -Average).Average, 0) } else { $null }
                                }
                            }
                        }
                        $result = [PSCustomObject]@{
                            ip = $ip; timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
                            hops = $hops; raw = ($raw -join "`n")
                        }
                        $result | ConvertTo-Json -Depth 5 | Set-Content $f -Encoding UTF8
                        Send-Json $resp ($result | ConvertTo-Json -Depth 5)
                    }
                }

                { $_ -match "^/api/history" } {
                    $ip   = $req.QueryString["ip"]
                    $safe = $ip.Replace('.', '_')
                    $f    = Join-Path $dataPath "history\$safe.json"
                    if (Test-Path $f) { Send-Json $resp (Get-Content $f -Raw) }
                    else              { Send-Json $resp "[]" }
                }

                { $_ -match "^/api/switch/ports" } {
                    $switchIp   = $req.QueryString["ip"]
                    $community  = $req.QueryString["community"]
                    if (-not $community) { $community = "public" }
                    if (-not $switchIp) {
                        Send-Json $resp @{ error = "Falta parametro 'ip'" } 400
                    } else {
                        try {
                            $scriptPath = Join-Path $BasePath "get_switch_ports.py"
                            $proc = Start-Process -FilePath "python" `
                                -ArgumentList "`"$scriptPath`" `"$switchIp`" `"$community`"" `
                                -NoNewWindow -Wait -PassThru `
                                -RedirectStandardOutput "$env:TEMP\nw_switch_out.txt" `
                                -RedirectStandardError "$env:TEMP\nw_switch_err.txt"
                            $output = Get-Content "$env:TEMP\nw_switch_out.txt" -Raw -ErrorAction SilentlyContinue
                            if (-not $output -or $output.Trim() -eq "") {
                                $errOut = Get-Content "$env:TEMP\nw_switch_err.txt" -Raw -ErrorAction SilentlyContinue
                                Send-Json $resp @{ error = "Sin respuesta del script SNMP"; detail = $errOut } 500
                            } else {
                                # Enrich FDB entries with IP from ARP table
                                try {
                                    $switchData = $output | ConvertFrom-Json
                                    if ($switchData.fdb) {
                                        $arpRaw = & arp -a 2>&1
                                        $macToIp = @{}
                                        foreach ($line in $arpRaw) {
                                            if ($line -match '(\d+\.\d+\.\d+\.\d+)\s+([\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2}[:-][\da-f]{2})') {
                                                $arpIp  = $Matches[1]
                                                $arpMac = $Matches[2].ToUpper().Replace('-',':')
                                                $macToIp[$arpMac] = $arpIp
                                            }
                                        }
                                        # Also look up host names from config
                                        $hostsLookup = @{}
                                        try {
                                            $hostsList = Get-Hosts
                                            foreach ($h in $hostsList) {
                                                $hostsLookup[$h.ip] = $h.name
                                            }
                                        } catch {}
                                        
                                        foreach ($entry in $switchData.fdb) {
                                            $mac = $entry.mac
                                            if ($macToIp.ContainsKey($mac)) {
                                                $entry | Add-Member -MemberType NoteProperty -Name "ip" -Value $macToIp[$mac] -Force
                                                $resolvedIp = $macToIp[$mac]
                                                if ($hostsLookup.ContainsKey($resolvedIp)) {
                                                    $entry | Add-Member -MemberType NoteProperty -Name "hostname" -Value $hostsLookup[$resolvedIp] -Force
                                                }
                                            }
                                        }
                                        Send-Json $resp $switchData
                                    } else {
                                        Send-Json $resp $output
                                    }
                                } catch {
                                    # If enrichment fails, return raw output
                                    Send-Json $resp $output
                                }
                            }
                        } catch {
                            Send-Json $resp @{ error = "Error ejecutando script SNMP: $($_.Exception.Message)" } 500
                        }
                    }
                }

                default { Send-Json $resp @{ error = "Endpoint no encontrado" } 404 }
            }
            continue
        }

        # ────────── ARCHIVOS ESTATICOS ──────────
        $filePath = Join-Path $wwwPath ($url.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (Test-Path $filePath -PathType Leaf) {
            Send-File $resp $filePath
        } else {
            Send-Text $resp "<h1>404 - No encontrado</h1>" "text/html" 404
        }

    } catch {
        Write-Host "[Server ERROR] $($_.Exception.Message)"
        try { $ctx.Response.StatusCode = 500; $ctx.Response.Close() } catch {}
    }
}

$listener.Stop()
