# test-booking-idempotency-concurrency.ps1
#
# Prueba de idempotencia bajo concurrencia real.
# Llama a la RPC directamente via SQL — NO usa el webhook ni requiere META_APP_SECRET.
#
# Prerrequisitos:
#   1. supabase start  (Docker corriendo)
#   2. supabase db reset --local
#
# Uso:
#   .\tests\test-booking-idempotency-concurrency.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Detectar psql local o contenedor Docker de Supabase
# ---------------------------------------------------------------------------
$localPsql     = Get-Command psql -ErrorAction SilentlyContinue
$usedMethod    = ""
$containerName = ""

if ($localPsql) {
  $usedMethod = "local"
  Write-Host "  psql local encontrado: $($localPsql.Source)"
} else {
  Write-Host "  psql no encontrado localmente. Buscando contenedor Docker..."
  $containerName = & docker ps --format "{{.Names}}" 2>$null |
    Where-Object { $_ -like "supabase_db_*" } |
    Select-Object -First 1
  if (-not $containerName) {
    Write-Error "No se encontro psql ni contenedor supabase_db_*. Asegurese de que 'supabase start' esta corriendo."
    exit 1
  }
  $usedMethod = "docker"
  Write-Host "  Usando contenedor Docker: $containerName"
}

# ---------------------------------------------------------------------------
# Funcion auxiliar: ejecutar SQL, retornar [PSCustomObject]@{Lines; ExitCode}
# ---------------------------------------------------------------------------
function Invoke-Sql {
  param(
    [string]$Sql,
    [string]$Method,
    [string]$Container
  )
  if ($Method -eq "local") {
    $raw      = & psql "postgresql://postgres:postgres@localhost:54322/postgres" `
      --no-psqlrc -t -A -c $Sql 2>&1
    $exitCode = $LASTEXITCODE
  } else {
    $raw      = & docker exec $Container psql -U postgres -d postgres `
      --no-psqlrc -t -A -c $Sql 2>&1
    $exitCode = $LASTEXITCODE
  }
  $lines = @($raw | ForEach-Object { $_.ToString() })
  [PSCustomObject]@{ Lines = $lines; ExitCode = $exitCode }
}

# ---------------------------------------------------------------------------
# Parametros del test
# ---------------------------------------------------------------------------
$today        = [DateTime]::Today
$dow          = [int]$today.DayOfWeek          # 0=Dom .. 6=Sab
$daysToMonday = @{0=1; 1=7; 2=6; 3=5; 4=4; 5=3; 6=2}[$dow]
$nextMonday   = $today.AddDays($daysToMonday).ToString("yyyy-MM-dd")

$ExternalRef   = "concurrency-test-idempotency-001"
$PhoneNumberId = "000000000000002"
$CustomerPhone = "+5219990000091"
$BusinessId    = "00000000-0000-0000-0000-000000000001"

# SQL que ejecuta cada job.
# El usuario postgres es superusuario y puede llamar la funcion sin restricciones de EXECUTE.
# Resultado esperado: exactamente una fila con formato "<uuid>|true" o "<uuid>|false".
$rpcSql = "SELECT appointment_id::text || '|' || created_new::text FROM public.create_whatsapp_flow_appointment('$PhoneNumberId', '$CustomerPhone', 'Test Concurrency', 'haircut', ARRAY['wash']::text[], '$nextMonday'::date, '10_00', 'appointment-booking-static-v1', '$ExternalRef');"

$cleanSql = "DELETE FROM public.appointments WHERE business_id = '$BusinessId' AND external_reference = '$ExternalRef'; DELETE FROM public.customers WHERE business_id = '$BusinessId' AND whatsapp_phone_e164 = '$CustomerPhone';"

Write-Host ""
Write-Host "=== Test de idempotencia bajo concurrencia real ==="
Write-Host "  Metodo:             $usedMethod"
Write-Host "  external_reference: $ExternalRef"
Write-Host "  appointment_date:   $nextMonday"
Write-Host ""

# ---------------------------------------------------------------------------
# Limpiar residuos de ejecuciones previas
# ---------------------------------------------------------------------------
$pre = Invoke-Sql -Sql $cleanSql -Method $usedMethod -Container $containerName
if ($pre.ExitCode -ne 0) {
  Write-Warning "Cleanup previo exitCode=$($pre.ExitCode) (normal si no habia datos)"
}

# ---------------------------------------------------------------------------
# Script block compartido por ambos jobs
# Recibe todos los valores como parametros — no depende de variables del padre.
# ---------------------------------------------------------------------------
$jobScript = {
  param(
    [string]$Method,
    [string]$Container,
    [string]$Sql
  )

  $raw      = $null
  $exitCode = 0
  $errMsg   = ""

  try {
    if ($Method -eq "local") {
      $raw      = & psql "postgresql://postgres:postgres@localhost:54322/postgres" `
        --no-psqlrc -t -A -c $Sql 2>&1
      $exitCode = $LASTEXITCODE
    } else {
      $raw      = & docker exec $Container psql -U postgres -d postgres `
        --no-psqlrc -t -A -c $Sql 2>&1
      $exitCode = $LASTEXITCODE
    }
  } catch {
    $errMsg   = $_.Exception.Message
    $exitCode = 1
  }

  $lines = @($raw | ForEach-Object { $_.ToString() })

  # El parseo de AppointmentId/CreatedNew se realiza en el proceso padre
  # para evitar dependencias de $Matches dentro del job.
  [PSCustomObject]@{
    ExitCode = $exitCode
    Stdout   = $lines   # array de lineas; el padre lo normaliza y parsea
    Stderr   = $errMsg
  }
}

# ---------------------------------------------------------------------------
# Lanzar dos jobs realmente paralelos
# ---------------------------------------------------------------------------
Write-Host "Lanzando 2 jobs paralelos..."
$job1 = Start-Job -ScriptBlock $jobScript -ArgumentList $usedMethod, $containerName, $rpcSql
$job2 = Start-Job -ScriptBlock $jobScript -ArgumentList $usedMethod, $containerName, $rpcSql

Write-Host "Jobs lanzados: $($job1.Id) y $($job2.Id). Esperando..."
Wait-Job $job1, $job2 | Out-Null

$r1 = Receive-Job $job1
$r2 = Receive-Job $job2
Remove-Job $job1, $job2

# ---------------------------------------------------------------------------
# Parsear AppointmentId y CreatedNew desde el stdout de cada job.
# Patron: <uuid>|true  o  <uuid>|false  (boolean::text de Postgres).
# Se usa [regex]::Match para evitar dependencias de $Matches en el scope actual.
# ---------------------------------------------------------------------------
$rpcPattern = '^(?<appointment_id>[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})\|(?<created_new>true|false)$'

function Parse-JobResult {
  param([PSCustomObject]$JobResult)

  $lines = @($JobResult.Stdout) |
    ForEach-Object { ([string]$_).Trim() } |
    Where-Object { $_ -ne "" }

  $resultLine = $lines |
    Where-Object {
      [regex]::IsMatch($_, $rpcPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    } |
    Select-Object -Last 1

  $appointmentId = $null
  $createdNew    = $null

  if ($resultLine) {
    $m             = [regex]::Match($resultLine, $rpcPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $appointmentId = $m.Groups["appointment_id"].Value
    $createdNew    = [System.Convert]::ToBoolean($m.Groups["created_new"].Value)
  }

  [PSCustomObject]@{
    AppointmentId = $appointmentId
    CreatedNew    = $createdNew
  }
}

$p1 = Parse-JobResult $r1
$p2 = Parse-JobResult $r2

Write-Host ""
Write-Host "Job 1 -> ExitCode=$($r1.ExitCode)  appointment_id=$($p1.AppointmentId)  created_new=$($p1.CreatedNew)"
Write-Host "Job 2 -> ExitCode=$($r2.ExitCode)  appointment_id=$($p2.AppointmentId)  created_new=$($p2.CreatedNew)"
Write-Host ""

# ---------------------------------------------------------------------------
# Verificaciones
# ---------------------------------------------------------------------------
$allPass = $true

# 1. Ambos jobs terminaron con exit code 0
if ($r1.ExitCode -ne 0) {
  Write-Host "FAIL: Job 1 exit code $($r1.ExitCode)"
  Write-Host "  Stdout: $($r1.Stdout -join ' | ')"
  if ($r1.Stderr) { Write-Host "  Stderr: $($r1.Stderr)" }
  $allPass = $false
} else {
  Write-Host "  PASS: Job 1 exit code 0"
}

if ($r2.ExitCode -ne 0) {
  Write-Host "FAIL: Job 2 exit code $($r2.ExitCode)"
  Write-Host "  Stdout: $($r2.Stdout -join ' | ')"
  if ($r2.Stderr) { Write-Host "  Stderr: $($r2.Stderr)" }
  $allPass = $false
} else {
  Write-Host "  PASS: Job 2 exit code 0"
}

# 2. Ambos produjeron un appointment_id (parseo exitoso)
if (-not $p1.AppointmentId) {
  Write-Host "FAIL: Job 1 no produjo appointment_id. Stdout: $($r1.Stdout -join ' | ')"
  $allPass = $false
} else {
  Write-Host "  PASS: Job 1 appointment_id=$($p1.AppointmentId)"
}

if (-not $p2.AppointmentId) {
  Write-Host "FAIL: Job 2 no produjo appointment_id. Stdout: $($r2.Stdout -join ' | ')"
  $allPass = $false
} else {
  Write-Host "  PASS: Job 2 appointment_id=$($p2.AppointmentId)"
}

# 3. Ambos apuntan al mismo appointment_id
if ($p1.AppointmentId -and $p2.AppointmentId) {
  if ($p1.AppointmentId -ne $p2.AppointmentId) {
    Write-Host "FAIL: Jobs apuntan a appointments distintos:"
    Write-Host "  Job 1: $($p1.AppointmentId)"
    Write-Host "  Job 2: $($p2.AppointmentId)"
    $allPass = $false
  } else {
    Write-Host "  PASS: ambos jobs apuntan al mismo appointment_id"
  }
}

# 4. Uno created_new=true, otro created_new=false
$trueCount  = @($p1, $p2 | Where-Object { $_.CreatedNew -eq $true  }).Count
$falseCount = @($p1, $p2 | Where-Object { $_.CreatedNew -eq $false }).Count

if ($trueCount -ne 1 -or $falseCount -ne 1) {
  Write-Host "FAIL: esperado 1xcreated_new=true y 1xcreated_new=false, obtenido true=$trueCount false=$falseCount"
  $allPass = $false
} else {
  Write-Host "  PASS: un job created_new=true, otro created_new=false"
}

# ---------------------------------------------------------------------------
# Verificar estado de BD
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Verificando estado de BD..."

# Contar citas con ese external_reference
$r = Invoke-Sql -Method $usedMethod -Container $containerName -Sql `
  "SELECT count(*) FROM public.appointments WHERE business_id = '$BusinessId' AND external_reference = '$ExternalRef';"
$apptCount = $r.Lines | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
Write-Host "  Citas con external_reference '$ExternalRef': $apptCount (esperado: 1)"
if ($apptCount -ne "1") {
  Write-Host "FAIL: esperada 1 cita, encontradas: $apptCount"
  $allPass = $false
} else {
  Write-Host "  PASS: exactamente 1 cita creada"
}

# Contar customers con ese telefono
$r = Invoke-Sql -Method $usedMethod -Container $containerName -Sql `
  "SELECT count(*) FROM public.customers WHERE business_id = '$BusinessId' AND whatsapp_phone_e164 = '$CustomerPhone';"
$custCount = $r.Lines | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
Write-Host "  Customers con telefono '$CustomerPhone': $custCount (esperado: 1)"
if ($custCount -ne "1") {
  Write-Host "FAIL: esperado 1 customer, encontrados: $custCount"
  $allPass = $false
} else {
  Write-Host "  PASS: exactamente 1 customer creado"
}

# Contar appointment_extras (1 extra: wash, sin duplicados)
$extSql = "SELECT count(*) FROM public.appointment_extras ae JOIN public.appointments a ON a.id = ae.appointment_id WHERE a.business_id = '$BusinessId' AND a.external_reference = '$ExternalRef';"
$r = Invoke-Sql -Method $usedMethod -Container $containerName -Sql $extSql
$extCount = $r.Lines | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
Write-Host "  appointment_extras para la cita: $extCount (esperado: 1)"
if ($extCount -ne "1") {
  Write-Host "FAIL: esperado 1 appointment_extra (wash), encontrados: $extCount"
  $allPass = $false
} else {
  Write-Host "  PASS: exactamente 1 appointment_extra sin duplicados"
}

# ---------------------------------------------------------------------------
# Cleanup y resultado final
# ---------------------------------------------------------------------------
Write-Host ""
Invoke-Sql -Sql $cleanSql -Method $usedMethod -Container $containerName | Out-Null
Write-Host "(Datos de prueba eliminados)"
Write-Host ""

if ($allPass) {
  Write-Host "=== PASS: idempotencia bajo concurrencia verificada ==="
  Write-Host "    Ambos jobs exit code 0, mismo appointment_id, 1 cita, 1 customer, sin extras duplicados."
} else {
  Write-Host "=== FAIL: revisar logs arriba para diagnostico ==="
  exit 1
}
