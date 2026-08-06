<#
.SYNOPSIS
  Orquestador de pruebas para google-calendar-sync (TC01-TC21).
  Inicia mock HTTP, supabase functions serve con env temporal, ejecuta los
  tests y limpia todo al terminar.

.PARAMETER MockPort
  Puerto local para el mock HTTP server. Default: 18080.

.PARAMETER FunctionUrl
  URL base de las Edge Functions locales.
  Default: http://localhost:54321/functions/v1

.PARAMETER DbUrl
  Connection string de la BD local (usado si psql esta disponible).
  Default: postgresql://postgres:postgres@localhost:54322/postgres

.EXAMPLE
  $env:INTERNAL_FUNCTION_SECRET = "tu-secret"
  .\tests\run-google-calendar-sync-tests.ps1

.NOTES
  Prerequisitos:
    - Docker corriendo
    - supabase start ejecutado
    - supabase db reset --local ejecutado
    - INTERNAL_FUNCTION_SECRET en el entorno (no en este script)
    - Sin otro "supabase functions serve" en el puerto 54321
#>
param(
  [int]$MockPort       = 18080,
  [string]$FunctionUrl = "http://localhost:54321/functions/v1",
  [string]$DbUrl       = "postgresql://postgres:postgres@localhost:54322/postgres"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Prerequisitos
# ---------------------------------------------------------------------------
$InternalSecret = $env:INTERNAL_FUNCTION_SECRET
if (-not $InternalSecret) {
  Write-Error "Falta la variable de entorno INTERNAL_FUNCTION_SECRET"
  exit 1
}

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) {
  Write-Error "supabase CLI no encontrado en PATH"
  exit 1
}

# ---------------------------------------------------------------------------
# Archivos temporales  (fuera del repositorio, en TEMP del sistema)
# ---------------------------------------------------------------------------
$Ts            = [int](([datetime]::UtcNow - [datetime]::new(1970,1,1)).TotalSeconds)
$TmpDir        = $env:TEMP
$ScenarioFile  = Join-Path $TmpDir "gcal_scenario_$MockPort.txt"
$EventCache    = Join-Path $TmpDir "gcal_eventcache_$MockPort.txt"
$StopFile      = Join-Path $TmpDir "gcal_stop_$MockPort.txt"
$EnvFile       = Join-Path $TmpDir "gcal_env_${MockPort}_$Ts.txt"
$FuncStdout    = Join-Path $TmpDir "gcal_func_out_$Ts.log"
$FuncStderr    = Join-Path $TmpDir "gcal_func_err_$Ts.log"

foreach ($f in @($ScenarioFile,$EventCache,$StopFile,$EnvFile,$FuncStdout,$FuncStderr)) {
  Remove-Item $f -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllText($ScenarioFile, "success_201", [System.Text.Encoding]::ASCII)

# ---------------------------------------------------------------------------
# Script block del mock HTTP server (corre en background job)
# Rutas manejadas:
#   POST /admin/set-scenario   - cambia el escenario activo
#   POST /token                - simula token endpoint de Google
#   POST /calendar/v3/calendars/*/events  - simula events.insert
#   GET  /calendar/v3/calendars/*/events/* - simula events.get
# ---------------------------------------------------------------------------
$MockScript = {
  param([int]$Port, [string]$ScFile, [string]$EvFile, [string]$SpFile)

  # Solo http://+:PORT/ — requerido para que los contenedores Docker accedan
  # via host.docker.internal. No se usa fallback a localhost: un mock solo en
  # loopback hace que las Edge Functions (dentro de Docker) no puedan conectarse
  # y todos los escenarios retornan retryable_error por error de red.
  $listener = New-Object System.Net.HttpListener
  try {
    $listener.Prefixes.Add("http://+:$Port/")
    $listener.Start()
  } catch {
    try { $listener.Close() } catch {}
    $errMsg = if ($_.Exception -and $_.Exception.Message) {
      $_.Exception.Message
    } else { "error desconocido al iniciar HttpListener" }
    Write-Output "MOCK_ERROR:$errMsg"
    Write-Output "MOCK_FIX:El mock requiere acceso a http://+:$Port/ (todas las interfaces)."
    Write-Output "MOCK_FIX:Ejecutar PowerShell como Administrador, o configurar URL ACL:"
    Write-Output "MOCK_FIX:  netsh http add urlacl url=http://+:$Port/ user=Everyone"
    return
  }
  Write-Output "MOCK_READY:http://+:$Port/"

  # Contadores de solicitudes por endpoint (diagnostico de falsos positivos)
  $tokenCalls  = 0; $tokenLastSc  = 0
  $insertCalls = 0; $insertLastSc = 0
  $getCalls    = 0; $getLastSc    = 0

  while ($true) {
    # Espera asincrona para poder chequear el archivo de parada.
    $task = $listener.GetContextAsync()
    while (-not $task.IsCompleted) {
      if (Test-Path $SpFile) {
        try { $listener.Stop() } catch {}
        return
      }
      [System.Threading.Thread]::Sleep(50)
    }
    if ($task.IsFaulted -or $task.IsCanceled) { break }

    $ctx = $null
    try { $ctx = $task.Result } catch {}
    if ($ctx -eq $null) { continue }

    $req  = $ctx.Request
    $resp = $ctx.Response
    if ($req -eq $null -or $resp -eq $null) {
      try { $ctx.Response.Close() } catch {}
      continue
    }

    $path = if ($req.Url -ne $null) { $req.Url.AbsolutePath } else { "/" }
    $meth = if ($req.HttpMethod)     { $req.HttpMethod }        else { "GET" }

    $scenario = "success_201"
    try {
      if (Test-Path $ScFile) {
        $s = [System.IO.File]::ReadAllText($ScFile).Trim()
        if ($s) { $scenario = $s }
      }
    } catch {}

    $sc   = 200
    $rbody = "{}"

    try {
      $reqBody = ""
      if ($req.HasEntityBody) {
        $rd = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
        $reqBody = $rd.ReadToEnd()
        $rd.Close()
      }

      # --- Health check (siempre disponible, sin dependencia de headers) ---
      if ($path -eq "/health") {
        $sc    = 200
        $rbody = '{"status":"ok"}'
      }

      # --- Admin: cambiar escenario ---
      elseif ($path -eq "/admin/set-scenario" -and $meth -eq "POST") {
        [System.IO.File]::WriteAllText($ScFile, $reqBody.Trim(), [System.Text.Encoding]::ASCII)
        $rbody = '{"ok":true}'
      }

      # --- Admin: estadisticas de solicitudes (diagnostico de falsos positivos) ---
      elseif ($path -eq "/admin/stats" -and $meth -eq "GET") {
        $rbody = '{"token_calls":' + $tokenCalls +
                 ',"token_last_sc":' + $tokenLastSc +
                 ',"insert_calls":' + $insertCalls +
                 ',"insert_last_sc":' + $insertLastSc +
                 ',"get_calls":' + $getCalls +
                 ',"get_last_sc":' + $getLastSc + '}'
      }

      # --- Admin: resetear contadores ---
      elseif ($path -eq "/admin/reset-stats" -and $meth -eq "POST") {
        $tokenCalls  = 0; $tokenLastSc  = 0
        $insertCalls = 0; $insertLastSc = 0
        $getCalls    = 0; $getLastSc    = 0
        $rbody = '{"ok":true}'
      }

      # --- Token endpoint ---
      elseif ($path -like "*/token") {
        $tokenCalls++
        switch ($scenario) {
          "invalid_grant" {
            $sc    = 400
            $rbody = '{"error":"invalid_grant","error_description":"Token expired or revoked."}'
          }
          "token_5xx" {
            $sc    = 500
            $rbody = '{"error":"server_error"}'
          }
          default {
            $sc    = 200
            $rbody = '{"access_token":"mock-access-token","token_type":"Bearer","expires_in":3600}'
          }
        }
        $tokenLastSc = $sc
      }

      # --- Calendar events.insert ---
      elseif ($meth -eq "POST" -and $path -like "*/events") {
        $obj   = $null
        try { $obj = $reqBody | ConvertFrom-Json } catch {}
        $evId  = if ($obj -and $obj.id) { $obj.id } else { "mock" + [guid]::NewGuid().ToString("N") }
        $apId  = ""
        $biId  = ""
        if ($obj -and $obj.extendedProperties -and $obj.extendedProperties.private) {
          $apId = $obj.extendedProperties.private.appointment_id
          $biId = $obj.extendedProperties.private.business_id
        }

        # Contador incrementado antes del switch para que timeout_calendar
        # (que duerme 12s antes de poder responder) quede registrado.
        $insertCalls++
        switch ($scenario) {
          "409_get_match" {
            [System.IO.File]::WriteAllText($EvFile, "$evId|$apId|$biId")
            $sc    = 409
            $rbody = '{"error":{"code":409,"errors":[{"domain":"calendar","reason":"duplicate"}],"message":"Already Exists."}}'
          }
          "409_get_404" {
            [System.IO.File]::WriteAllText($EvFile, "$evId|NO_MATCH|NO_MATCH")
            $sc    = 409
            $rbody = '{"error":{"code":409,"errors":[{"domain":"calendar","reason":"duplicate"}],"message":"Already Exists."}}'
          }
          "429_calendar" {
            $sc = 429
            $rbody = '{"error":{"code":429,"message":"Too Many Requests"}}'
          }
          "403_rate_limit" {
            $sc    = 403
            $rbody = '{"error":{"code":403,"errors":[{"domain":"usageLimits","reason":"rateLimitExceeded","message":"Rate Limit Exceeded"}],"message":"Rate Limit Exceeded"}}'
          }
          "403_perms" {
            $sc    = 403
            $rbody = '{"error":{"code":403,"errors":[{"domain":"calendar","reason":"forbidden","message":"Forbidden"}],"message":"Forbidden"}}'
          }
          "5xx_calendar" {
            $sc    = 503
            $rbody = '{"error":{"code":503,"message":"Backend Error"}}'
          }
          "timeout_calendar" {
            # Duerme 12s; la Edge Function tiene AbortController de 10s.
            [System.Threading.Thread]::Sleep(12000)
            $sc    = 200
            $rbody = '{"id":"' + $evId + '"}'
          }
          "delay_1s" {
            [System.Threading.Thread]::Sleep(1000)
            $sc    = 201
            $rbody = '{"id":"' + $evId + '","status":"confirmed","extendedProperties":{"private":{"appointment_id":"' + $apId + '","business_id":"' + $biId + '"}}}'
          }
          default {
            $sc    = 201
            $rbody = '{"id":"' + $evId + '","status":"confirmed","extendedProperties":{"private":{"appointment_id":"' + $apId + '","business_id":"' + $biId + '"}}}'
          }
        }
        $insertLastSc = $sc
      }

      # --- Calendar events.get (reconcile tras 409) ---
      elseif ($meth -eq "GET" -and $path -like "*/events/*") {
        $getCalls++
        switch ($scenario) {
          "409_get_match" {
            $parts = @("mockevent", "", "")
            try {
              if (Test-Path $EvFile) {
                $parts = ([System.IO.File]::ReadAllText($EvFile)).Split("|")
              }
            } catch {}
            $evId2 = if ($parts.Count -gt 0) { $parts[0] } else { "mockevent" }
            $apId2 = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            $biId2 = if ($parts.Count -gt 2) { $parts[2] } else { "" }
            $sc    = 200
            $rbody = '{"id":"' + $evId2 + '","status":"confirmed","extendedProperties":{"private":{"appointment_id":"' + $apId2 + '","business_id":"' + $biId2 + '"}}}'
          }
          "409_get_404" {
            $sc    = 404
            $rbody = '{"error":{"code":404,"message":"Not Found"}}'
          }
          default {
            $sc    = 200
            $rbody = '{"id":"mockevent","status":"confirmed"}'
          }
        }
        $getLastSc = $sc
      }

      else {
        $sc    = 404
        $rbody = '{"error":"not_found","path":"' + $path + '"}'
      }
    } catch {
      $sc    = 500
      $rbody = '{"error":"mock_internal_error"}'
    }

    try {
      $resp.StatusCode    = $sc
      $resp.ContentType   = "application/json; charset=utf-8"
      $b = [System.Text.Encoding]::UTF8.GetBytes($rbody)
      $resp.ContentLength64 = $b.Length
      $resp.OutputStream.Write($b, 0, $b.Length)
      $resp.Close()
    } catch {
      try { $resp.Close() } catch {}
    }
  }

  try { $listener.Stop()  } catch {}
  try { $listener.Close() } catch {}
}

# ---------------------------------------------------------------------------
# Variables de control
# ---------------------------------------------------------------------------
$mockJob     = $null
$funcProcess = $null
$exitCode    = 0

try {
  # -------------------------------------------------------------------------
  # 1. Iniciar mock HTTP server
  # -------------------------------------------------------------------------
  Write-Host "[1/4] Iniciando mock HTTP en puerto $MockPort..." -ForegroundColor Cyan

  $mockJob = Start-Job -ScriptBlock $MockScript `
    -ArgumentList $MockPort, $ScenarioFile, $EventCache, $StopFile

  # Fuente de verdad: GET /health hasta 15 s.
  # No se espera MOCK_READY como pre-condicion (Write-Host no era legible via
  # Receive-Job; ahora usa Write-Output, pero el health probe es mas robusto).
  $healthUrl  = "http://localhost:$MockPort/health"
  $mockReady  = $false
  $deadline   = [DateTime]::UtcNow.AddSeconds(15)

  do {
    if ($mockJob.State -in @("Failed", "Stopped", "Completed")) { break }
    try {
      $wr = [System.Net.WebRequest]::Create($healthUrl)
      $wr.Method  = "GET"
      $wr.Timeout = 1000
      $r = $wr.GetResponse()
      $r.Close()
      $mockReady = $true
      break
    } catch {
      Start-Sleep -Milliseconds 250
    }
  } while ([DateTime]::UtcNow -lt $deadline)

  if (-not $mockReady) {
    Write-Host "Mock state: $($mockJob.State)" -ForegroundColor Red
    $jobOut  = Receive-Job $mockJob -Keep -ErrorAction SilentlyContinue
    $jobErrs = $mockJob.ChildJobs[0].Error
    $jobInfo = $mockJob.ChildJobs[0].Information
    Write-Host "OUTPUT:"      ; $jobOut  | ForEach-Object { Write-Host "  $_" }
    Write-Host "ERROR:"       ; $jobErrs | ForEach-Object { Write-Host "  $_" }
    Write-Host "INFORMATION:" ; $jobInfo | ForEach-Object { Write-Host "  $_" }
    Write-Error "Mock server no respondio en GET /health (15 s)"
    exit 1
  }
  Write-Host "    Mock escuchando en http://+:$MockPort/ (health desde Windows: OK)" -ForegroundColor Green

  # Verificar conectividad desde Docker — las Edge Functions corren en contenedores.
  # Sin este check, un mock solo en loopback produce falsos positivos: todos los
  # escenarios retornarian retryable_error por error de red en lugar de la
  # respuesta especifica del escenario.
  Write-Host "    Verificando conectividad desde Docker..." -ForegroundColor DarkGray
  $null = & docker run --rm curlimages/curl:8.10.1 `
    --max-time 5 --silent --fail `
    "http://host.docker.internal:$MockPort/health" 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Las Edge Functions (Docker) no pueden alcanzar el mock." -ForegroundColor Red
    Write-Host "El mock requiere binding a http://+:$MockPort/ (todas las interfaces)." -ForegroundColor Red
    Write-Host ""
    Write-Host "Para resolver, elegir una opcion:" -ForegroundColor Yellow
    Write-Host "  1. Ejecutar PowerShell como Administrador y volver a ejecutar el script." -ForegroundColor Yellow
    Write-Host "  2. Configurar URL ACL de forma permanente (una sola vez, requiere admin):" -ForegroundColor Yellow
    Write-Host "       netsh http add urlacl url=http://+:$MockPort/ user=Everyone" -ForegroundColor Yellow
    Write-Error "El mock no es accesible desde Docker. No se puede continuar."
    exit 1
  }
  Write-Host "    Docker puede alcanzar el mock (host.docker.internal:$($MockPort): OK)" -ForegroundColor Green

  # Las Edge Functions siempre usan host.docker.internal (nunca localhost)
  $dockerMockBase = "http://host.docker.internal:$MockPort"
  $MockAdminUrl   = "http://localhost:$MockPort"

  # -------------------------------------------------------------------------
  # 2. Crear archivo de entorno temporal (nunca dentro del repositorio)
  # -------------------------------------------------------------------------
  Write-Host "[2/4] Creando entorno temporal..." -ForegroundColor Cyan
  $envLines = @(
    "INTERNAL_FUNCTION_SECRET=$InternalSecret",
    "GOOGLE_CLIENT_ID=fake-client-id-for-tests",
    "GOOGLE_CLIENT_SECRET=fake-client-secret-for-tests",
    "GOOGLE_OAUTH_REDIRECT_URI=http://localhost:54321/functions/v1/google-oauth-callback",
    "GOOGLE_OAUTH_STATE_SECRET=fake-oauth-state-secret-32chars-xxxx",
    "GOOGLE_CALENDAR_SYNC_URL=http://localhost:54321/functions/v1/google-calendar-sync",
    "GOOGLE_TOKEN_ENDPOINT=$dockerMockBase/token",
    "GOOGLE_CALENDAR_API_BASE_URL=$dockerMockBase/calendar/v3"
  )
  [System.IO.File]::WriteAllText($EnvFile, ($envLines -join "`n"), [System.Text.Encoding]::ASCII)
  Write-Host "    Health (host)   : http://localhost:$MockPort/health" -ForegroundColor DarkGray
  Write-Host "    Token endpoint  : $dockerMockBase/token" -ForegroundColor DarkGray
  Write-Host "    Calendar base   : $dockerMockBase/calendar/v3" -ForegroundColor DarkGray

  # -------------------------------------------------------------------------
  # 3. Iniciar supabase functions serve
  # -------------------------------------------------------------------------
  Write-Host "[3/4] Iniciando supabase functions serve..." -ForegroundColor Cyan

  $funcProcess = Start-Process `
    -FilePath "supabase" `
    -ArgumentList @("functions", "serve", "--env-file", $EnvFile) `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardOutput $FuncStdout `
    -RedirectStandardError  $FuncStderr

  # Esperar hasta que la funcion responda (max 90s).
  # Sondear con secret incorrecto: esperamos 401 (no 000 = no conecta).
  $syncProbeUrl = "$FunctionUrl/google-calendar-sync"
  $probeBody    = [System.Text.Encoding]::UTF8.GetBytes('{"business_id":"00000000-0000-0000-0000-000000000001","appointment_id":"00000000-0000-0000-0000-000000000001"}')
  $funcReady    = $false
  $sw           = [System.Diagnostics.Stopwatch]::StartNew()
  Write-Host "    Esperando que las funciones respondan..." -ForegroundColor DarkGray

  while ($sw.Elapsed.TotalSeconds -lt 90) {
    Start-Sleep -Milliseconds 800
    try {
      $wr = [System.Net.WebRequest]::Create($syncProbeUrl)
      $wr.Method      = "POST"
      $wr.ContentType = "application/json"
      $wr.Headers["x-internal-secret"] = "probe-wrong-secret"
      $wr.Timeout     = 4000
      $wr.ContentLength = $probeBody.Length
      $st = $wr.GetRequestStream()
      $st.Write($probeBody, 0, $probeBody.Length)
      $st.Close()
      try {
        $r = $wr.GetResponse()
        $r.Close()
        $funcReady = $true; break
      } catch [System.Net.WebException] {
        $code = [int]$_.Exception.Response.StatusCode
        if ($code -eq 401 -or $code -eq 200) { $funcReady = $true; break }
      }
    } catch {}
  }

  if (-not $funcReady) {
    Write-Host "Edge Functions no respondieron en 90s. Ultimas lineas de stderr:" -ForegroundColor Red
    if (Test-Path $FuncStderr) { Get-Content $FuncStderr | Select-Object -Last 30 }
    Write-Host "Ultimas lineas de stdout:" -ForegroundColor Red
    if (Test-Path $FuncStdout) { Get-Content $FuncStdout | Select-Object -Last 30 }
    Write-Error "supabase functions serve no respondio en 90 segundos"
    exit 1
  }
  Write-Host "    Edge Functions listas ($([int]$sw.Elapsed.TotalSeconds)s)." -ForegroundColor Green

  # -------------------------------------------------------------------------
  # 4. Ejecutar script de tests
  # -------------------------------------------------------------------------
  Write-Host "[4/4] Ejecutando tests..." -ForegroundColor Cyan
  Write-Host ""

  $testScript = Join-Path $PSScriptRoot "test-google-calendar-sync.ps1"
  & $testScript `
    -FunctionUrl  $FunctionUrl `
    -MockAdminUrl $MockAdminUrl `
    -DbUrl        $DbUrl

  $exitCode = if ($LASTEXITCODE -ne $null) { $LASTEXITCODE } else { 0 }

} finally {
  # -------------------------------------------------------------------------
  # Cleanup
  # -------------------------------------------------------------------------
  Write-Host ""
  Write-Host "Limpiando recursos..." -ForegroundColor Cyan

  # Detener supabase functions serve
  if ($funcProcess -and -not $funcProcess.HasExited) {
    try { $funcProcess.Kill() } catch {}
    try { $funcProcess.WaitForExit(5000) | Out-Null } catch {}
  }

  # Detener mock server
  if ($mockJob) {
    try { [System.IO.File]::WriteAllText($StopFile, "stop") } catch {}
    Start-Sleep -Milliseconds 600
    try { Stop-Job  $mockJob -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job $mockJob -Force -ErrorAction SilentlyContinue } catch {}
  }

  # Eliminar archivos temporales
  foreach ($f in @($ScenarioFile,$EventCache,$StopFile,$EnvFile,$FuncStdout,$FuncStderr)) {
    try { Remove-Item $f -ErrorAction SilentlyContinue } catch {}
  }

  Write-Host "Listo." -ForegroundColor Cyan
}

exit $exitCode
