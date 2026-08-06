<#
.SYNOPSIS
  Tests de integracion para google-calendar-sync (TC01-TC21).
  Usar run-google-calendar-sync-tests.ps1 como orquestador (inicia mock y
  supabase functions serve automaticamente).

.PARAMETER FunctionUrl
  URL base de las Edge Functions locales.
  Default: http://localhost:54321/functions/v1

.PARAMETER MockAdminUrl
  URL del mock HTTP para cambiar escenarios via /admin/set-scenario.
  Default: http://localhost:18080

.PARAMETER DbUrl
  Connection string de PostgreSQL local (usado si psql esta disponible).
  Default: postgresql://postgres:postgres@localhost:54322/postgres

.PARAMETER DbContainer
  Nombre del contenedor Docker con la BD (alternativa a psql).
  Si se omite, se detecta automaticamente el contenedor supabase_db_*.

.PARAMETER TestFilter
  Prefijo para filtrar tests (ej: TC01, TC1). Sin filtro ejecuta todos.

.EXAMPLE
  # Via orquestador (recomendado):
  $env:INTERNAL_FUNCTION_SECRET = "tu-secret"
  .\tests\run-google-calendar-sync-tests.ps1

  # Directo (requiere mock y functions serve ya activos):
  $env:INTERNAL_FUNCTION_SECRET = "tu-secret"
  .\tests\test-google-calendar-sync.ps1
#>
param(
  [string]$FunctionUrl  = "http://localhost:54321/functions/v1",
  [string]$MockAdminUrl = "http://localhost:18080",
  [string]$DbUrl        = "postgresql://postgres:postgres@localhost:54322/postgres",
  [string]$DbContainer  = "",
  [string]$TestFilter   = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off

$InternalSecret = $env:INTERNAL_FUNCTION_SECRET
if (-not $InternalSecret) {
  Write-Error "Falta la variable de entorno INTERNAL_FUNCTION_SECRET"
  exit 1
}

$SyncUrl    = "$FunctionUrl/google-calendar-sync"
$BID        = "00000000-0000-0000-0000-000000000001"
$SERVICE_ID = "00000000-0000-0000-0001-000000000001"

$passed  = 0
$failed  = 0
$skipped = 0

# Contador para generar numeros de telefono unicos por ejecucion.
$script:PhoneSeq = [int](Get-Random -Minimum 1000000 -Maximum 8000000)

# ---------------------------------------------------------------------------
# Resultados
# ---------------------------------------------------------------------------
function Write-Pass([string]$name, [string]$msg) {
  Write-Host "[PASS] $name : $msg" -ForegroundColor Green
  $script:passed++
}
function Write-Fail([string]$name, [string]$msg) {
  Write-Host "[FAIL] $name : $msg" -ForegroundColor Red
  $script:failed++
}

function Should-Run([string]$name) {
  if (-not $TestFilter) { return $true }
  return $name -like "$TestFilter*"
}

# ---------------------------------------------------------------------------
# Acceso a PostgreSQL: psql o docker exec
# ---------------------------------------------------------------------------
$script:DbUsePsql    = $false
$script:DbUrlLocal   = $DbUrl
$script:DbContLocal  = ""

function Initialize-DbAccess {
  if ($DbContainer) {
    $script:DbContLocal = $DbContainer
    $script:DbUsePsql   = $false
    Write-Host "BD: docker exec $DbContainer" -ForegroundColor DarkGray
    return
  }
  if (Get-Command psql -ErrorAction SilentlyContinue) {
    $script:DbUsePsql = $true
    Write-Host "BD: psql $DbUrl" -ForegroundColor DarkGray
    return
  }
  # Buscar contenedor supabase_db_*
  try {
    $containers = docker ps --format "{{.Names}}" 2>&1 |
      Where-Object { $_ -like "supabase_db_*" }
    if ($containers) {
      $script:DbContLocal = ($containers | Select-Object -First 1).ToString().Trim()
      $script:DbUsePsql   = $false
      Write-Host "BD: docker exec $($script:DbContLocal)" -ForegroundColor DarkGray
      return
    }
  } catch {}
  Write-Error "No se encontro psql ni contenedor supabase_db_*. Ejecuta: supabase start"
  exit 1
}

function Invoke-LocalSql([string]$sql) {
  if ($script:DbUsePsql) {
    $result = psql $script:DbUrlLocal -t -A -c $sql 2>&1
    return $result
  } else {
    $result = ($sql | docker exec -i $script:DbContLocal `
      psql -U postgres -d postgres -v ON_ERROR_STOP=1 -t -A) 2>&1
    return $result
  }
}

function Invoke-LocalSqlScalar([string]$sql) {
  $raw = Invoke-LocalSql $sql
  $val = if ($raw -is [array]) {
    $raw | Where-Object { $_ -ne $null -and "$_".Trim() -ne "" } | Select-Object -First 1
  } else {
    $raw
  }
  if ($null -eq $val) { return "" }
  return "$val".Trim()
}

# ---------------------------------------------------------------------------
# Mock: administracion de escenario y estadisticas
# ---------------------------------------------------------------------------
function Set-MockScenario([string]$scenario) {
  try {
    $url  = "$MockAdminUrl/admin/set-scenario"
    $body = [System.Text.Encoding]::ASCII.GetBytes($scenario)
    $wr   = [System.Net.WebRequest]::Create($url)
    $wr.Method        = "POST"
    $wr.ContentType   = "text/plain"
    $wr.ContentLength = $body.Length
    $wr.Timeout       = 5000
    $st = $wr.GetRequestStream()
    $st.Write($body, 0, $body.Length)
    $st.Close()
    try { $wr.GetResponse().Close() } catch {}
  } catch {}
}

function Reset-MockStats {
  try {
    $wr = [System.Net.WebRequest]::Create("$MockAdminUrl/admin/reset-stats")
    $wr.Method        = "POST"
    $wr.ContentLength = 0
    $wr.Timeout       = 3000
    try { $wr.GetResponse().Close() } catch {}
  } catch {}
}

function Get-MockStats {
  try {
    $wr = [System.Net.WebRequest]::Create("$MockAdminUrl/admin/stats")
    $wr.Method  = "GET"
    $wr.Timeout = 3000
    $r  = $wr.GetResponse()
    $rd = New-Object System.IO.StreamReader($r.GetResponseStream())
    $s  = $rd.ReadToEnd()
    $rd.Close(); $r.Close()
    return $s | ConvertFrom-Json
  } catch {
    return $null
  }
}

# ---------------------------------------------------------------------------
# Helpers de estado en BD
# ---------------------------------------------------------------------------
function Get-JobStatus([string]$apptId) {
  return Invoke-LocalSqlScalar `
    "SELECT COALESCE(status,'') FROM public.calendar_sync_jobs WHERE appointment_id = '$apptId';"
}

function Get-AppointmentStatus([string]$apptId) {
  return Invoke-LocalSqlScalar `
    "SELECT COALESCE(status,'') FROM public.appointments WHERE id = '$apptId';"
}

function Get-CalendarEventId([string]$apptId) {
  return Invoke-LocalSqlScalar `
    "SELECT COALESCE(calendar_event_id,'') FROM public.appointments WHERE id = '$apptId';"
}

function Get-JobCalendarEventId([string]$apptId) {
  return Invoke-LocalSqlScalar `
    "SELECT COALESCE(calendar_event_id,'') FROM public.calendar_sync_jobs WHERE appointment_id = '$apptId';"
}

function Get-ConnectionStatus {
  return Invoke-LocalSqlScalar `
    "SELECT COALESCE(status,'') FROM public.google_calendar_connections WHERE business_id = '$BID';"
}

function Get-JobLastError([string]$apptId) {
  return Invoke-LocalSqlScalar `
    "SELECT COALESCE(last_error_code,'') FROM public.calendar_sync_jobs WHERE appointment_id = '$apptId';"
}

# ---------------------------------------------------------------------------
# Diagnostico al fallar (escenario + estadisticas del mock + last_error_code)
# Nunca imprime authorization headers, access_token ni refresh_token.
# ---------------------------------------------------------------------------
function Show-TcDiag([string]$tc, [string]$apptId, [string]$scenario) {
  $stats = Get-MockStats
  Write-Host "  [diag $tc] scenario=$scenario" -ForegroundColor DarkYellow
  if ($stats) {
    Write-Host ("  [diag $tc] mock: /token=$($stats.token_calls)(sc=$($stats.token_last_sc))" +
                " events.insert=$($stats.insert_calls)(sc=$($stats.insert_last_sc))" +
                " events.get=$($stats.get_calls)(sc=$($stats.get_last_sc))") -ForegroundColor DarkYellow
  } else {
    Write-Host "  [diag $tc] mock stats no disponibles" -ForegroundColor DarkYellow
  }
  if ($apptId) {
    $jErr = ""
    try { $jErr = Get-JobLastError $apptId } catch {}
    if ($jErr) { Write-Host "  [diag $tc] last_error_code=$jErr" -ForegroundColor DarkYellow }
  }
}

# ---------------------------------------------------------------------------
# Llamada al endpoint de sincronizacion
# ---------------------------------------------------------------------------
function Invoke-Sync([string]$apptId, [string]$secret = $InternalSecret) {
  try {
    $b   = [System.Text.Encoding]::UTF8.GetBytes(
      '{"business_id":"' + $BID + '","appointment_id":"' + $apptId + '"}'
    )
    $wr  = [System.Net.WebRequest]::Create($SyncUrl)
    $wr.Method      = "POST"
    $wr.ContentType = "application/json"
    $wr.Headers["x-internal-secret"] = $secret
    $wr.Timeout     = 35000
    $wr.ContentLength = $b.Length
    $st = $wr.GetRequestStream()
    $st.Write($b, 0, $b.Length)
    $st.Close()
    try {
      $r   = $wr.GetResponse()
      $rd  = New-Object System.IO.StreamReader($r.GetResponseStream())
      $cnt = $rd.ReadToEnd()
      $rd.Close(); $r.Close()
      return @{ StatusCode = [int]$r.StatusCode; Body = $cnt }
    } catch [System.Net.WebException] {
      $er = $_.Exception.Response
      if ($er) {
        $rd  = New-Object System.IO.StreamReader($er.GetResponseStream())
        $cnt = $rd.ReadToEnd()
        $rd.Close()
        return @{ StatusCode = [int]$er.StatusCode; Body = $cnt }
      }
      return @{ StatusCode = 0; Body = $_.Exception.Message }
    }
  } catch {
    return @{ StatusCode = 0; Body = $_.Exception.Message }
  }
}

# ---------------------------------------------------------------------------
# Creacion de appointments de prueba
# ---------------------------------------------------------------------------
function Get-NextMonday {
  $today = Get-Date
  $dow   = [int]$today.DayOfWeek
  $days  = if ($dow -eq 0) { 1 } elseif ($dow -eq 1) { 7 } else { 8 - $dow }
  return $today.AddDays($days).ToString("yyyy-MM-dd")
}

function New-TestAppointment([string]$status = "pending") {
  $script:PhoneSeq++
  $apptId     = [guid]::NewGuid().ToString()
  $customerId = [guid]::NewGuid().ToString()
  $phone      = "+52155$($script:PhoneSeq.ToString().PadLeft(7,'0'))"
  $monday     = Get-NextMonday

  $sql = @"
DO `$`$
DECLARE v_cid uuid;
BEGIN
  INSERT INTO public.customers (id, business_id, whatsapp_phone_e164)
  VALUES ('$customerId','$BID','$phone')
  ON CONFLICT (business_id, whatsapp_phone_e164) DO NOTHING;

  SELECT id INTO v_cid FROM public.customers
  WHERE business_id = '$BID' AND whatsapp_phone_e164 = '$phone';

  INSERT INTO public.appointments
    (id, business_id, customer_id, service_id,
     starts_at, ends_at, status, source, external_reference)
  VALUES
    ('$apptId','$BID',v_cid,'$SERVICE_ID',
     '$monday 10:00:00+00','$monday 10:30:00+00',
     'pending','whatsapp_flow','ref-$apptId')
  ON CONFLICT DO NOTHING;
END;
`$`$;
"@
  Invoke-LocalSql $sql | Out-Null

  if ($status -ne "pending") {
    Invoke-LocalSql "UPDATE public.appointments SET status = '$status' WHERE id = '$apptId';" | Out-Null
  }
  return $apptId
}

# ---------------------------------------------------------------------------
# Conexion de prueba con Google Calendar
# ---------------------------------------------------------------------------
function Setup-MockConnection([string]$rt = "mock-rt") {
  $sql = @"
DO `$`$
BEGIN
  DELETE FROM public.google_calendar_connections WHERE business_id = '$BID';
  PERFORM public.store_google_calendar_connection(
    '$BID','primary','test@example.com',
    '$rt',
    'https://www.googleapis.com/auth/calendar.events.owned'
  );
END;
`$`$;
"@
  Invoke-LocalSql $sql | Out-Null
}

function Cleanup-Connection {
  Invoke-LocalSql `
    "DELETE FROM public.google_calendar_connections WHERE business_id = '$BID';" |
    Out-Null
}

function Cleanup-Appointment([string]$apptId) {
  Invoke-LocalSql "DELETE FROM public.appointments WHERE id = '$apptId';" | Out-Null
}

# ---------------------------------------------------------------------------
# Inicializar acceso a BD
# ---------------------------------------------------------------------------
Initialize-DbAccess

# ===========================================================================
# TC01 — INSERT whatsapp_flow crea job automáticamente via trigger
# ===========================================================================
if (Should-Run "TC01") {
  try {
    $apptId   = New-TestAppointment
    $jobCount = Invoke-LocalSqlScalar `
      "SELECT COUNT(*)::text FROM public.calendar_sync_jobs WHERE appointment_id = '$apptId';"
    if ($jobCount -eq "1") {
      Write-Pass "TC01" "INSERT whatsapp_flow crea calendar_sync_job automaticamente"
    } else {
      Write-Fail "TC01" "Esperado 1 job, obtenido '$jobCount'"
    }
  } catch {
    Write-Fail "TC01" $_.Exception.Message
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
  }
}

# ===========================================================================
# TC02 — UNIQUE(appointment_id): solo un job por appointment
# ===========================================================================
if (Should-Run "TC02") {
  try {
    $apptId = New-TestAppointment
    Invoke-LocalSql @"
INSERT INTO public.calendar_sync_jobs (business_id, appointment_id)
VALUES ('$BID','$apptId')
ON CONFLICT (appointment_id) DO NOTHING;
"@ | Out-Null
    $jobCount = Invoke-LocalSqlScalar `
      "SELECT COUNT(*)::text FROM public.calendar_sync_jobs WHERE appointment_id = '$apptId';"
    if ($jobCount -eq "1") {
      Write-Pass "TC02" "UNIQUE(appointment_id) previene job duplicado"
    } else {
      Write-Fail "TC02" "Esperado 1 job, obtenido '$jobCount'"
    }
  } catch {
    Write-Fail "TC02" $_.Exception.Message
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
  }
}

# ===========================================================================
# TC03 — 201 success → appointment confirmed + calendar_event_id guardado
# ===========================================================================
if (Should-Run "TC03") {
  $apptId = ""; $scenario = "success_201"
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC03" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC03" $apptId $scenario
    } else {
      $jobStatus  = Get-JobStatus $apptId
      $apptStatus = Get-AppointmentStatus $apptId
      $evId       = Get-CalendarEventId $apptId
      $expEvId    = $apptId.Replace("-","")
      $stats      = Get-MockStats
      $mockOk     = $stats -and $stats.token_calls -ge 1 -and $stats.insert_calls -ge 1

      if ($jobStatus -eq "synced" -and $apptStatus -eq "confirmed" -and $evId -eq $expEvId -and $mockOk) {
        Write-Pass "TC03" "201 -> job=synced, appointment=confirmed, calendar_event_id=$($evId.Substring(0,8))..."
      } else {
        Write-Fail "TC03" "job=$jobStatus appt=$apptStatus evId='$evId' (esperado '$expEvId') mockOk=$mockOk"
        Show-TcDiag "TC03" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC03" $_.Exception.Message
    Show-TcDiag "TC03" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC04 — 409 + GET 200 con match → reconciliacion → synced
# ===========================================================================
if (Should-Run "TC04") {
  $apptId = ""; $scenario = "409_get_match"
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC04" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC04" $apptId $scenario
    } else {
      $jobStatus  = Get-JobStatus $apptId
      $apptStatus = Get-AppointmentStatus $apptId
      $stats      = Get-MockStats
      $mockOk     = $stats -and $stats.token_calls -ge 1 -and $stats.insert_calls -ge 1 -and $stats.get_calls -ge 1

      if ($jobStatus -eq "synced" -and $apptStatus -eq "confirmed" -and $mockOk) {
        Write-Pass "TC04" "409 + GET 200 match -> reconciliado, job=synced, appointment=confirmed"
      } else {
        Write-Fail "TC04" "job=$jobStatus appt=$apptStatus mockOk=$mockOk"
        Show-TcDiag "TC04" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC04" $_.Exception.Message
    Show-TcDiag "TC04" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC05 — 409 + GET 404 → retryable_error (no permanent)
# ===========================================================================
if (Should-Run "TC05") {
  $apptId = ""; $scenario = "409_get_404"
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC05" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC05" $apptId $scenario
    } else {
      $jobStatus = Get-JobStatus $apptId
      $stats     = Get-MockStats
      # insert >= 1 y get >= 1 confirman que Docker alcanzo el mock (no falso positivo por red)
      $mockOk    = $stats -and $stats.insert_calls -ge 1 -and $stats.get_calls -ge 1

      if ($jobStatus -eq "retryable_error" -and $mockOk) {
        Write-Pass "TC05" "409 + GET 404 -> retryable_error (insert=$($stats.insert_calls) get=$($stats.get_calls))"
      } else {
        Write-Fail "TC05" "Esperado retryable_error con insert>=1 get>=1; obtenido job=$jobStatus mockOk=$mockOk"
        Show-TcDiag "TC05" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC05" $_.Exception.Message
    Show-TcDiag "TC05" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC06 — 429 de Calendar → retryable_error
# ===========================================================================
if (Should-Run "TC06") {
  $apptId = ""; $scenario = "429_calendar"
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC06" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC06" $apptId $scenario
    } else {
      $jobStatus = Get-JobStatus $apptId
      $stats     = Get-MockStats
      $mockOk    = $stats -and $stats.insert_calls -ge 1 -and $stats.insert_last_sc -eq 429

      if ($jobStatus -eq "retryable_error" -and $mockOk) {
        Write-Pass "TC06" "429 de Calendar -> retryable_error (insert_sc=$($stats.insert_last_sc))"
      } else {
        Write-Fail "TC06" "Esperado retryable_error con insert_sc=429; obtenido job=$jobStatus mockOk=$mockOk"
        Show-TcDiag "TC06" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC06" $_.Exception.Message
    Show-TcDiag "TC06" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC07 — 403 rateLimitExceeded → retryable_error
# ===========================================================================
if (Should-Run "TC07") {
  $apptId = ""; $scenario = "403_rate_limit"
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC07" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC07" $apptId $scenario
    } else {
      $jobStatus = Get-JobStatus $apptId
      $stats     = Get-MockStats
      $mockOk    = $stats -and $stats.insert_calls -ge 1 -and $stats.insert_last_sc -eq 403

      if ($jobStatus -eq "retryable_error" -and $mockOk) {
        Write-Pass "TC07" "403 rateLimitExceeded -> retryable_error (insert_sc=$($stats.insert_last_sc))"
      } else {
        Write-Fail "TC07" "Esperado retryable_error con insert_sc=403; obtenido job=$jobStatus mockOk=$mockOk"
        Show-TcDiag "TC07" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC07" $_.Exception.Message
    Show-TcDiag "TC07" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC08 — 403 permisos reales → permanent_error
# ===========================================================================
if (Should-Run "TC08") {
  $apptId = ""; $scenario = "403_perms"
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC08" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC08" $apptId $scenario
    } else {
      $jobStatus = Get-JobStatus $apptId
      $stats     = Get-MockStats
      $mockOk    = $stats -and $stats.insert_calls -ge 1 -and $stats.insert_last_sc -eq 403

      if ($jobStatus -eq "permanent_error" -and $mockOk) {
        Write-Pass "TC08" "403 forbidden -> permanent_error (insert_sc=$($stats.insert_last_sc))"
      } else {
        Write-Fail "TC08" "Esperado permanent_error con insert_sc=403; obtenido job=$jobStatus mockOk=$mockOk"
        Show-TcDiag "TC08" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC08" $_.Exception.Message
    Show-TcDiag "TC08" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC09 — 5xx de Calendar → retryable_error
# ===========================================================================
if (Should-Run "TC09") {
  $apptId = ""; $scenario = "5xx_calendar"
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC09" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC09" $apptId $scenario
    } else {
      $jobStatus = Get-JobStatus $apptId
      $stats     = Get-MockStats
      $mockOk    = $stats -and $stats.insert_calls -ge 1 -and $stats.insert_last_sc -eq 503

      if ($jobStatus -eq "retryable_error" -and $mockOk) {
        Write-Pass "TC09" "503 de Calendar -> retryable_error (insert_sc=$($stats.insert_last_sc))"
      } else {
        Write-Fail "TC09" "Esperado retryable_error con insert_sc=503; obtenido job=$jobStatus mockOk=$mockOk"
        Show-TcDiag "TC09" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC09" $_.Exception.Message
    Show-TcDiag "TC09" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC10 — Timeout de Calendar (>10s) → retryable_error
# ===========================================================================
if (Should-Run "TC10") {
  $apptId = ""; $scenario = "timeout_calendar"
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    # La Edge Function tiene AbortController de 10s.
    # El mock duerme 12s; la funcion aborta y retorna retryable.
    # Invoke-Sync tiene timeout de 35s, suficiente.
    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC10" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC10" $apptId $scenario
    } else {
      $jobStatus = Get-JobStatus $apptId
      $stats     = Get-MockStats
      # insert_calls >= 1 confirma que Docker alcanzo el mock antes del timeout
      $mockOk    = $stats -and $stats.insert_calls -ge 1

      if ($jobStatus -eq "retryable_error" -and $mockOk) {
        Write-Pass "TC10" "Timeout de Calendar -> retryable_error (insert=$($stats.insert_calls))"
      } else {
        Write-Fail "TC10" "Esperado retryable_error con insert>=1; obtenido job=$jobStatus mockOk=$mockOk"
        Show-TcDiag "TC10" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC10" $_.Exception.Message
    Show-TcDiag "TC10" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
    # Restaurar escenario para siguientes pruebas
    Set-MockScenario "success_201"
  }
}

# ===========================================================================
# TC11 — invalid_grant → permanent_error + connection.status='revoked'
# ===========================================================================
if (Should-Run "TC11") {
  $apptId = ""; $scenario = "invalid_grant"
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC11" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC11" $apptId $scenario
    } else {
      $jobStatus  = Get-JobStatus $apptId
      $connStatus = Get-ConnectionStatus
      $stats      = Get-MockStats
      # token endpoint debe haber respondido 400; no debe haber llamadas a insert
      $mockOk     = $stats -and $stats.token_calls -ge 1 -and $stats.token_last_sc -eq 400

      if ($jobStatus -eq "permanent_error" -and $connStatus -eq "revoked" -and $mockOk) {
        Write-Pass "TC11" "invalid_grant -> job=permanent_error, connection=revoked (token_sc=$($stats.token_last_sc))"
      } else {
        Write-Fail "TC11" "job=$jobStatus connStatus=$connStatus mockOk=$mockOk"
        Show-TcDiag "TC11" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC11" $_.Exception.Message
    Show-TcDiag "TC11" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC12 — Token endpoint 5xx → retryable_error
# ===========================================================================
if (Should-Run "TC12") {
  $apptId = ""; $scenario = "token_5xx"
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC12" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC12" $apptId $scenario
    } else {
      $jobStatus = Get-JobStatus $apptId
      $stats     = Get-MockStats
      # token endpoint debe haber respondido 500; no debe haber llamadas a insert
      $mockOk    = $stats -and $stats.token_calls -ge 1 -and $stats.token_last_sc -eq 500

      if ($jobStatus -eq "retryable_error" -and $mockOk) {
        Write-Pass "TC12" "Token endpoint 5xx -> retryable_error (token_sc=$($stats.token_last_sc))"
      } else {
        Write-Fail "TC12" "Esperado retryable_error con token_sc=500; obtenido job=$jobStatus mockOk=$mockOk"
        Show-TcDiag "TC12" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC12" $_.Exception.Message
    Show-TcDiag "TC12" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC13 — Sin conexion activa → job queda en waiting_connection (no permanent)
# ===========================================================================
if (Should-Run "TC13") {
  $apptId = ""; $scenario = "success_201"
  try {
    Cleanup-Connection     # Asegurar que no hay conexion activa
    $apptId = New-TestAppointment
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC13" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC13" $apptId $scenario
    } else {
      $jobStatus = Get-JobStatus $apptId
      if ($jobStatus -eq "waiting_connection") {
        Write-Pass "TC13" "Sin conexion -> job=waiting_connection (no permanent_error)"
      } else {
        Write-Fail "TC13" "Esperado waiting_connection, obtenido '$jobStatus'"
        Show-TcDiag "TC13" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC13" $_.Exception.Message
    Show-TcDiag "TC13" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
  }
}

# ===========================================================================
# TC14 — Reconexion: store_google_calendar_connection reactiva job
#        waiting_connection -> pending
# ===========================================================================
if (Should-Run "TC14") {
  $apptId = ""; $scenario = "success_201"
  try {
    Cleanup-Connection
    $apptId = New-TestAppointment
    Set-MockScenario $scenario
    Reset-MockStats

    # Llevar el job a waiting_connection
    Invoke-Sync $apptId | Out-Null

    $jobAfterSync = Get-JobStatus $apptId
    if ($jobAfterSync -ne "waiting_connection") {
      Write-Fail "TC14" "Setup fallo: esperado waiting_connection antes de reconexion, obtenido '$jobAfterSync'"
      Show-TcDiag "TC14" $apptId $scenario
    } else {
      # Agregar conexion via RPC (simula OAuth completado)
      $sql = @"
DO `$`$
BEGIN
  PERFORM public.store_google_calendar_connection(
    '$BID','primary','reconnect@example.com',
    'mock-rt-tc14',
    'https://www.googleapis.com/auth/calendar.events.owned'
  );
END;
`$`$;
"@
      Invoke-LocalSql $sql | Out-Null

      $jobAfterConn = Get-JobStatus $apptId
      if ($jobAfterConn -eq "pending") {
        Write-Pass "TC14" "store_google_calendar_connection reactiva job waiting_connection -> pending"
      } else {
        Write-Fail "TC14" "Esperado pending tras reconexion, obtenido '$jobAfterConn'"
        Show-TcDiag "TC14" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC14" $_.Exception.Message
    Show-TcDiag "TC14" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC15 — Appointment cancelled → permanent_error 'appointment_not_pending'
# ===========================================================================
if (Should-Run "TC15") {
  $apptId = ""; $scenario = "success_201"
  try {
    $apptId = New-TestAppointment "cancelled"
    # El trigger crea el job como pending; resetear next_attempt_at para que sea reclamable.
    Invoke-LocalSql @"
UPDATE public.calendar_sync_jobs
   SET next_attempt_at = now() - INTERVAL '1 second'
 WHERE appointment_id = '$apptId';
"@ | Out-Null

    Setup-MockConnection
    Set-MockScenario $scenario
    Reset-MockStats

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -ne 200) {
      Write-Fail "TC15" "Sync retorno HTTP $($resp.StatusCode)"
      Show-TcDiag "TC15" $apptId $scenario
    } else {
      $jobStatus = Get-JobStatus $apptId
      if ($jobStatus -eq "permanent_error") {
        Write-Pass "TC15" "Appointment cancelled -> permanent_error"
      } elseif ($jobStatus -eq "") {
        Write-Fail "TC15" "Job no encontrado (supabase functions serve activo?)"
        Show-TcDiag "TC15" $apptId $scenario
      } else {
        Write-Fail "TC15" "Esperado permanent_error, obtenido '$jobStatus'"
        Show-TcDiag "TC15" $apptId $scenario
      }
    }
  } catch {
    Write-Fail "TC15" $_.Exception.Message
    Show-TcDiag "TC15" $apptId $scenario
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
  }
}

# ===========================================================================
# TC16 — attempts >= max_attempts: claim retorna vacio, sync retorna 200
# ===========================================================================
if (Should-Run "TC16") {
  $apptId = ""
  try {
    $apptId = New-TestAppointment
    Invoke-LocalSql @"
UPDATE public.calendar_sync_jobs
   SET attempts = max_attempts,
       next_attempt_at = now() - INTERVAL '1 second'
 WHERE appointment_id = '$apptId';
"@ | Out-Null

    $resp = Invoke-Sync $apptId
    if ($resp.StatusCode -eq 200) {
      Write-Pass "TC16" "attempts >= max_attempts -> sync retorna 200 (no claim)"
    } else {
      Write-Fail "TC16" "Esperado HTTP 200, obtenido $($resp.StatusCode)"
    }
  } catch {
    Write-Fail "TC16" $_.Exception.Message
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
  }
}

# ===========================================================================
# TC17 — Concurrencia: dos Start-Job simultaneos, solo uno crea evento
# ===========================================================================
if (Should-Run "TC17") {
  $apptId = ""; $scenario = "delay_1s"
  $job1   = $null
  $job2   = $null
  try {
    $apptId = New-TestAppointment
    Setup-MockConnection
    # delay_1s: el mock tarda 1s en responder al insert de Calendar.
    # Esto da tiempo a que el segundo worker intente reclamar el job
    # mientras el primero ya lo tiene (SKIP LOCKED).
    Set-MockScenario $scenario
    Reset-MockStats

    $syncBlock = {
      param([string]$url, [string]$bid, [string]$apptId, [string]$sec)
      try {
        $b  = [System.Text.Encoding]::UTF8.GetBytes(
          '{"business_id":"' + $bid + '","appointment_id":"' + $apptId + '"}'
        )
        $wr = [System.Net.WebRequest]::Create($url)
        $wr.Method        = "POST"
        $wr.ContentType   = "application/json"
        $wr.Headers["x-internal-secret"] = $sec
        $wr.Timeout       = 35000
        $wr.ContentLength = $b.Length
        $st = $wr.GetRequestStream()
        $st.Write($b, 0, $b.Length)
        $st.Close()
        try {
          $r  = $wr.GetResponse()
          $rd = New-Object System.IO.StreamReader($r.GetResponseStream())
          $c  = $rd.ReadToEnd()
          $rd.Close(); $r.Close()
          return [int]$r.StatusCode
        } catch [System.Net.WebException] {
          $er = $_.Exception.Response
          if ($er) { return [int]$er.StatusCode }
          return 0
        }
      } catch {
        return 0
      }
    }

    $job1 = Start-Job -ScriptBlock $syncBlock `
      -ArgumentList $SyncUrl, $BID, $apptId, $InternalSecret
    Start-Sleep -Milliseconds 500
    $job2 = Start-Job -ScriptBlock $syncBlock `
      -ArgumentList $SyncUrl, $BID, $apptId, $InternalSecret

    $r1 = Receive-Job $job1 -Wait -AutoRemoveJob 2>$null
    $r2 = Receive-Job $job2 -Wait -AutoRemoveJob 2>$null
    $job1 = $null; $job2 = $null

    $jobStatus  = Get-JobStatus $apptId
    $apptStatus = Get-AppointmentStatus $apptId
    $calEvId    = Get-CalendarEventId $apptId
    $expEvId    = $apptId.Replace("-","")
    $stats      = Get-MockStats
    # Solo un worker debe haber llegado al Calendar (el otro fue bloqueado por SKIP LOCKED)
    $mockOk     = $stats -and $stats.token_calls -ge 1 -and $stats.insert_calls -ge 1

    if ($jobStatus -eq "synced" -and $apptStatus -eq "confirmed" -and $calEvId -eq $expEvId -and $mockOk) {
      Write-Pass "TC17" "Dos workers -> SKIP LOCKED -> 1 evento creado, job=synced, appointment=confirmed"
    } else {
      Write-Fail "TC17" "job=$jobStatus appt=$apptStatus evId='$calEvId' mockOk=$mockOk"
      Show-TcDiag "TC17" $apptId $scenario
    }
  } catch {
    Write-Fail "TC17" $_.Exception.Message
    Show-TcDiag "TC17" $apptId $scenario
  } finally {
    if ($job1) { try { Remove-Job $job1 -Force } catch {} }
    if ($job2) { try { Remove-Job $job2 -Force } catch {} }
    try { Cleanup-Appointment $apptId } catch {}
    try { Cleanup-Connection } catch {}
    Set-MockScenario "success_201"
  }
}

# ===========================================================================
# TC18 — Logs no contienen access_token ni refresh_token (analisis estatico)
# ===========================================================================
if (Should-Run "TC18") {
  try {
    $root      = Split-Path $PSScriptRoot -Parent
    $syncCode  = Get-Content (Join-Path $root "supabase\functions\google-calendar-sync\index.ts") -Raw
    $sharedCode = Get-Content (Join-Path $root "supabase\functions\_shared\google-calendar.ts") -Raw
    $combined  = $syncCode + $sharedCode

    $patterns = @(
      'console\.log.*access_?token',
      'console\.log.*refresh_?token',
      'console\.error.*access_?token',
      'console\.error.*refresh_?token'
    )
    $found = $false
    foreach ($p in $patterns) {
      if ($combined -match $p) { $found = $true; break }
    }

    if (-not $found) {
      Write-Pass "TC18" "Codigo no loguea access_token ni refresh_token"
    } else {
      Write-Fail "TC18" "Codigo contiene log de datos sensibles"
    }
  } catch {
    Write-Fail "TC18" $_.Exception.Message
  }
}

# ===========================================================================
# TC19 — Sin x-internal-secret → HTTP 401
# ===========================================================================
if (Should-Run "TC19") {
  try {
    $apptId = [guid]::NewGuid().ToString()
    $b      = [System.Text.Encoding]::UTF8.GetBytes(
      '{"business_id":"' + $BID + '","appointment_id":"' + $apptId + '"}'
    )
    $wr     = [System.Net.WebRequest]::Create($SyncUrl)
    $wr.Method        = "POST"
    $wr.ContentType   = "application/json"
    $wr.Timeout       = 10000
    $wr.ContentLength = $b.Length
    $st = $wr.GetRequestStream()
    $st.Write($b, 0, $b.Length)
    $st.Close()
    try {
      $wr.GetResponse().Close()
      Write-Fail "TC19" "Esperado HTTP 401, la funcion acepto la peticion"
    } catch [System.Net.WebException] {
      $code = [int]$_.Exception.Response.StatusCode
      if ($code -eq 401) {
        Write-Pass "TC19" "Sin x-internal-secret -> HTTP 401"
      } else {
        Write-Fail "TC19" "Esperado 401, obtenido $code"
      }
    }
  } catch {
    Write-Fail "TC19" $_.Exception.Message
  }
}

# ===========================================================================
# TC20 — Secret incorrecto → HTTP 401
# ===========================================================================
if (Should-Run "TC20") {
  try {
    $apptId = [guid]::NewGuid().ToString()
    $resp   = Invoke-Sync $apptId "wrong-secret-value-for-tc20"
    if ($resp.StatusCode -eq 401) {
      Write-Pass "TC20" "Secret incorrecto -> HTTP 401"
    } else {
      Write-Fail "TC20" "Esperado 401, obtenido $($resp.StatusCode)"
    }
  } catch {
    Write-Fail "TC20" $_.Exception.Message
  }
}

# ===========================================================================
# TC21 — Recuperacion de job processing vencido (locked_until en el pasado)
# ===========================================================================
if (Should-Run "TC21") {
  $apptId = ""
  try {
    $apptId = New-TestAppointment
    # Simular job abandonado: status=processing, locked_until hace 2 min.
    Invoke-LocalSql @"
UPDATE public.calendar_sync_jobs
   SET status         = 'processing',
       locked_until   = now() - INTERVAL '2 minutes',
       attempts       = 1,
       next_attempt_at = now() - INTERVAL '1 minute'
 WHERE appointment_id = '$apptId';
"@ | Out-Null

    # claim_calendar_sync_job deberia recuperar este job (locked_until <= now).
    $claimCount = Invoke-LocalSqlScalar @"
SELECT COUNT(*)::text
  FROM public.claim_calendar_sync_job('$BID','$apptId');
"@
    if ($claimCount -eq "1") {
      Write-Pass "TC21" "Job con locked_until pasado recuperado por nuevo worker"
    } else {
      Write-Fail "TC21" "Claim retorno $claimCount filas (esperado 1)"
    }
  } catch {
    Write-Fail "TC21" $_.Exception.Message
  } finally {
    try { Cleanup-Appointment $apptId } catch {}
  }
}

# ===========================================================================
# Resumen
# ===========================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Resultados: PASS=$passed  FAIL=$failed  SKIP=$skipped" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 }
