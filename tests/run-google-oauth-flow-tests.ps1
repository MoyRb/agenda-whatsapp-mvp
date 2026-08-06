<#
.SYNOPSIS
  Orquestador de pruebas OAuth de Google (TO01-TO10).
  Inicia mock del token endpoint, supabase functions serve con env temporal,
  ejecuta los tests y limpia todo al terminar.

.PARAMETER MockPort
  Puerto local para el mock del token endpoint. Default: 18081.
  (Usar un puerto distinto al de run-google-calendar-sync-tests.ps1 = 18080)

.PARAMETER FunctionUrl
  URL base de las Edge Functions locales.
  Default: http://localhost:54321/functions/v1

.PARAMETER DbUrl
  Connection string de la BD local.
  Default: postgresql://postgres:postgres@localhost:54322/postgres

.EXAMPLE
  $env:INTERNAL_FUNCTION_SECRET = "tu-secret"
  .\tests\run-google-oauth-flow-tests.ps1

.NOTES
  Prerequisitos:
    - Docker corriendo
    - supabase start ejecutado
    - supabase db reset --local ejecutado
    - INTERNAL_FUNCTION_SECRET en el entorno
    - Puerto $MockPort accesible desde Docker (http://+:PORT/ o URL ACL configurado)
#>
param(
  [int]$MockPort       = 18081,
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
# Archivos temporales (fuera del repositorio)
# ---------------------------------------------------------------------------
$Ts         = [int](([datetime]::UtcNow - [datetime]::new(1970,1,1)).TotalSeconds)
$TmpDir     = $env:TEMP
$ScFile     = Join-Path $TmpDir "gcal_oauth_scenario_$MockPort.txt"
$StopFile   = Join-Path $TmpDir "gcal_oauth_stop_$MockPort.txt"
$EnvFile    = Join-Path $TmpDir "gcal_oauth_env_${MockPort}_$Ts.txt"
$FuncStdout = Join-Path $TmpDir "gcal_oauth_func_out_$Ts.log"
$FuncStderr = Join-Path $TmpDir "gcal_oauth_func_err_$Ts.log"

foreach ($f in @($ScFile,$StopFile,$EnvFile,$FuncStdout,$FuncStderr)) {
  Remove-Item $f -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllText($ScFile, "success", [System.Text.Encoding]::ASCII)

# ---------------------------------------------------------------------------
# Mock del token endpoint de Google.
# Rutas:
#   GET  /health                 - probe de disponibilidad
#   POST /admin/set-scenario     - cambia el escenario activo
#   POST /token                  - simula el token endpoint de Google
#
# Escenarios:
#   success          → 200 con access_token + refresh_token + email (default)
#   no_refresh_token → 200 con access_token pero SIN refresh_token
# ---------------------------------------------------------------------------
$MockScript = {
  param([int]$Port, [string]$ScFile, [string]$SpFile)

  # Solo http://+:PORT/ — requerido para que Docker alcance via host.docker.internal
  $listener = New-Object System.Net.HttpListener
  try {
    $listener.Prefixes.Add("http://+:$Port/")
    $listener.Start()
  } catch {
    try { $listener.Close() } catch {}
    $errMsg = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { "unknown" }
    Write-Output "MOCK_ERROR:$errMsg"
    Write-Output "MOCK_FIX:Ejecutar como Administrador o configurar URL ACL:"
    Write-Output "MOCK_FIX:  netsh http add urlacl url=http://+:$Port/ user=Everyone"
    return
  }
  Write-Output "MOCK_READY:http://+:$Port/"

  while ($true) {
    $task = $listener.GetContextAsync()
    while (-not $task.IsCompleted) {
      if (Test-Path $SpFile) { try { $listener.Stop() } catch {}; return }
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

    $path = if ($req.Url) { $req.Url.AbsolutePath } else { "/" }
    $meth = if ($req.HttpMethod) { $req.HttpMethod } else { "GET" }

    $scenario = "success"
    try {
      if (Test-Path $ScFile) {
        $s = [System.IO.File]::ReadAllText($ScFile).Trim()
        if ($s) { $scenario = $s }
      }
    } catch {}

    $sc    = 200
    $rbody = "{}"

    try {
      $reqBody = ""
      if ($req.HasEntityBody) {
        $rd = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
        $reqBody = $rd.ReadToEnd()
        $rd.Close()
      }

      if ($path -eq "/health") {
        $sc    = 200
        $rbody = '{"status":"ok"}'
      }
      elseif ($path -eq "/admin/set-scenario" -and $meth -eq "POST") {
        [System.IO.File]::WriteAllText($ScFile, $reqBody.Trim(), [System.Text.Encoding]::ASCII)
        $rbody = '{"ok":true}'
      }
      elseif ($path -like "*/token" -and $meth -eq "POST") {
        switch ($scenario) {
          "no_refresh_token" {
            $sc    = 200
            $rbody = '{"access_token":"mock-access-nort","token_type":"Bearer","expires_in":3600}'
          }
          default {
            $sc    = 200
            $rbody = '{"access_token":"mock-access-token","refresh_token":"mock-refresh-token-to03","token_type":"Bearer","expires_in":3600,"email":"mock@example.com","scope":"https://www.googleapis.com/auth/calendar.events.owned"}'
          }
        }
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
      $resp.StatusCode      = $sc
      $resp.ContentType     = "application/json; charset=utf-8"
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
  # 1. Iniciar mock del token endpoint
  # -------------------------------------------------------------------------
  Write-Host "[1/4] Iniciando mock OAuth (token endpoint) en puerto $MockPort..." -ForegroundColor Cyan

  $mockJob = Start-Job -ScriptBlock $MockScript `
    -ArgumentList $MockPort, $ScFile, $StopFile

  # Fuente de verdad: GET /health desde Windows
  $healthUrl = "http://localhost:$MockPort/health"
  $mockReady = $false
  $deadline  = [DateTime]::UtcNow.AddSeconds(15)

  do {
    if ($mockJob.State -in @("Failed","Stopped","Completed")) { break }
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
    Write-Error "Mock no respondio en GET /health (15 s)"
    exit 1
  }
  Write-Host "    Mock escuchando en http://+:$MockPort/ (health desde Windows: OK)" -ForegroundColor Green

  # Verificar conectividad desde Docker
  Write-Host "    Verificando conectividad desde Docker..." -ForegroundColor DarkGray
  $null = & docker run --rm curlimages/curl:8.10.1 `
    --max-time 5 --silent --fail `
    "http://host.docker.internal:$MockPort/health" 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Docker no puede alcanzar el mock." -ForegroundColor Red
    Write-Host "El mock requiere binding a http://+:$MockPort/ (todas las interfaces)." -ForegroundColor Red
    Write-Host ""
    Write-Host "Para resolver, elegir una opcion:" -ForegroundColor Yellow
    Write-Host "  1. Ejecutar PowerShell como Administrador." -ForegroundColor Yellow
    Write-Host "  2. Configurar URL ACL de forma permanente:" -ForegroundColor Yellow
    Write-Host "       netsh http add urlacl url=http://+:$MockPort/ user=Everyone" -ForegroundColor Yellow
    Write-Error "Mock no es accesible desde Docker. No se puede continuar."
    exit 1
  }
  Write-Host "    Docker puede alcanzar el mock (host.docker.internal:$($MockPort): OK)" -ForegroundColor Green

  $dockerMockBase = "http://host.docker.internal:$MockPort"
  $MockAdminUrl   = "http://localhost:$MockPort"

  # -------------------------------------------------------------------------
  # 2. Crear archivo de entorno temporal
  # -------------------------------------------------------------------------
  Write-Host "[2/4] Creando entorno temporal..." -ForegroundColor Cyan
  $envLines = @(
    "INTERNAL_FUNCTION_SECRET=$InternalSecret",
    "GOOGLE_CLIENT_ID=fake-client-id-for-tests",
    "GOOGLE_CLIENT_SECRET=fake-client-secret-for-tests",
    "GOOGLE_OAUTH_REDIRECT_URI=http://localhost:54321/functions/v1/google-oauth-callback",
    "GOOGLE_OAUTH_STATE_SECRET=fake-oauth-state-secret-32chars-xxxx",
    "GOOGLE_TOKEN_ENDPOINT=$dockerMockBase/token"
  )
  [System.IO.File]::WriteAllText($EnvFile, ($envLines -join "`n"), [System.Text.Encoding]::ASCII)
  Write-Host "    Health (host)   : http://localhost:$MockPort/health" -ForegroundColor DarkGray
  Write-Host "    Token endpoint  : $dockerMockBase/token" -ForegroundColor DarkGray

  # -------------------------------------------------------------------------
  # 3. Iniciar supabase functions serve
  # -------------------------------------------------------------------------
  Write-Host "[3/4] Iniciando supabase functions serve..." -ForegroundColor Cyan

  $funcProcess = Start-Process `
    -FilePath "supabase" `
    -ArgumentList @("functions","serve","--env-file",$EnvFile) `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardOutput $FuncStdout `
    -RedirectStandardError  $FuncStderr

  $startProbeUrl = "$FunctionUrl/google-oauth-start"
  $probeBody     = [System.Text.Encoding]::UTF8.GetBytes('{"business_id":"00000000-0000-0000-0000-000000000001"}')
  $funcReady     = $false
  $sw            = [System.Diagnostics.Stopwatch]::StartNew()
  Write-Host "    Esperando que las funciones respondan..." -ForegroundColor DarkGray

  while ($sw.Elapsed.TotalSeconds -lt 90) {
    Start-Sleep -Milliseconds 800
    try {
      $wr = [System.Net.WebRequest]::Create($startProbeUrl)
      $wr.Method        = "POST"
      $wr.ContentType   = "application/json"
      $wr.Headers.Add("x-internal-secret", "probe-wrong-secret")
      $wr.Timeout       = 4000
      $wr.ContentLength = $probeBody.Length
      $st = $wr.GetRequestStream()
      $st.Write($probeBody, 0, $probeBody.Length)
      $st.Close()
      try {
        $r = $wr.GetResponse(); $r.Close()
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
    Write-Error "supabase functions serve no respondio en 90 segundos"
    exit 1
  }
  Write-Host "    Edge Functions listas ($([int]$sw.Elapsed.TotalSeconds)s)." -ForegroundColor Green

  # -------------------------------------------------------------------------
  # 4. Ejecutar script de tests
  # -------------------------------------------------------------------------
  Write-Host "[4/4] Ejecutando tests..." -ForegroundColor Cyan
  Write-Host ""

  $testScript = Join-Path $PSScriptRoot "test-google-oauth-flow.ps1"
  & $testScript `
    -FunctionUrl  $FunctionUrl `
    -MockAdminUrl $MockAdminUrl `
    -DbUrl        $DbUrl

  $exitCode = if ($LASTEXITCODE -ne $null) { $LASTEXITCODE } else { 0 }

} finally {
  Write-Host ""
  Write-Host "Limpiando recursos..." -ForegroundColor Cyan

  if ($funcProcess -and -not $funcProcess.HasExited) {
    try { $funcProcess.Kill() } catch {}
    try { $funcProcess.WaitForExit(5000) | Out-Null } catch {}
  }

  if ($mockJob) {
    try { [System.IO.File]::WriteAllText($StopFile, "stop") } catch {}
    Start-Sleep -Milliseconds 600
    try { Stop-Job  $mockJob -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job $mockJob -Force -ErrorAction SilentlyContinue } catch {}
  }

  foreach ($f in @($ScFile,$StopFile,$EnvFile,$FuncStdout,$FuncStderr)) {
    try { Remove-Item $f -ErrorAction SilentlyContinue } catch {}
  }

  Write-Host "Listo." -ForegroundColor Cyan
}

exit $exitCode
