# test-whatsapp-booking-webhook.ps1
#
# Prueba de integracion: envia un nfm_reply sintetico al webhook local
# y verifica que la cita se persiste en Supabase.
#
# Prerrequisitos:
#   1. supabase start  (Docker corriendo)
#   2. supabase db reset --local
#   3. supabase functions serve whatsapp-webhook --env-file ./supabase/.env.local
#   4. $env:META_APP_SECRET = "tu-app-secret"
#
# Uso:
#   .\tests\test-whatsapp-booking-webhook.ps1
#   .\tests\test-whatsapp-booking-webhook.ps1 -Duplicate   # prueba idempotencia

param(
    [string]$Url = "http://localhost:54321/functions/v1/whatsapp-webhook",
    [switch]$Duplicate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Prerequisito: META_APP_SECRET requerido para firma HMAC
# ---------------------------------------------------------------------------
if (-not $env:META_APP_SECRET) {
    Write-Error "Variable META_APP_SECRET no definida. Ejecutar: `$env:META_APP_SECRET = 'tu-secret'"
    exit 1
}

# ---------------------------------------------------------------------------
# Fecha: proximo lunes (negocio abierto lun-sab en el seed)
# ---------------------------------------------------------------------------
$today        = [DateTime]::Today
$dow          = [int]$today.DayOfWeek
$daysToMonday = @{0=1; 1=7; 2=6; 3=5; 4=4; 5=3; 6=2}[$dow]
$nextMonday   = $today.AddDays($daysToMonday).ToString("yyyy-MM-dd")

# ---------------------------------------------------------------------------
# External reference
# ---------------------------------------------------------------------------
if ($Duplicate) {
    $externalRef = "test-duplicate-smoke-001"
    Write-Host "Modo: DUPLICADO (external_reference fijo para probar idempotencia)"
} else {
    $externalRef = "test-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 16)
}

# ---------------------------------------------------------------------------
# Telefono sintetico unico por ejecucion.
# Formato: 5219900XXXXXX (13 digitos) -> normalizado a +5219900XXXXXX en webhook.
# Unico por ejecucion para evitar conflictos de FK con runs anteriores.
# En modo -Duplicate el mismo telefono se reutiliza en ambas llamadas.
# ---------------------------------------------------------------------------
$randomSuffix      = Get-Random -Minimum 100000 -Maximum 999999
$customerPhoneRaw  = "5219900$randomSuffix"   # sin '+', se usa como msg.from
$customerPhoneE164 = "+$customerPhoneRaw"       # E.164, se usa en consultas BD

$businessId = "00000000-0000-0000-0000-000000000001"

# ---------------------------------------------------------------------------
# Construir payload nfm_reply
# msg.from = $customerPhoneRaw (sin '+') -- verifica normalizacion en el webhook
# ---------------------------------------------------------------------------
$responseJson = @{
    service_id       = "haircut"
    extra_ids        = @("wash")
    appointment_date = $nextMonday
    appointment_time = "10_00"
    flow_version     = "appointment-booking-static-v1"
} | ConvertTo-Json -Compress

$payload = @{
    object = "whatsapp_business_account"
    entry  = @(
        @{
            id      = "000000000000001"
            changes = @(
                @{
                    value = @{
                        metadata = @{ phone_number_id = "000000000000002" }
                        messages = @(
                            @{
                                from        = $customerPhoneRaw
                                id          = $externalRef
                                type        = "interactive"
                                interactive = @{
                                    type      = "nfm_reply"
                                    nfm_reply = @{
                                        response_json = $responseJson
                                        name          = "flow"
                                    }
                                }
                            }
                        )
                    }
                }
            )
        }
    )
} | ConvertTo-Json -Compress -Depth 10

# ---------------------------------------------------------------------------
# Calcular firma HMAC-SHA256
# ---------------------------------------------------------------------------
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$hmac      = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key  = [System.Text.Encoding]::UTF8.GetBytes($env:META_APP_SECRET)
$hashBytes = $hmac.ComputeHash($bodyBytes)
$hexHash   = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
$signature = "sha256=$hexHash"

# ---------------------------------------------------------------------------
# Detectar psql local o contenedor Docker de Supabase
# ---------------------------------------------------------------------------
$script:useLocal    = $false
$script:dbContainer = ""

$localPsql = Get-Command psql -ErrorAction SilentlyContinue
if ($localPsql) {
    $script:useLocal = $true
    Write-Host "BD: psql local en $($localPsql.Source)"
} else {
    $found = & docker ps --format "{{.Names}}" 2>$null |
        Where-Object { $_ -like "supabase_db_*" } |
        Select-Object -First 1
    if ($found) {
        $script:dbContainer = $found
        Write-Host "BD: contenedor Docker $($script:dbContainer)"
    } else {
        Write-Warning "No se encontro psql ni contenedor supabase_db_*. Las verificaciones de BD se omitiran."
    }
}

$dbAvailable = $script:useLocal -or ($script:dbContainer -ne "")

# ---------------------------------------------------------------------------
# Helpers de BD
# Invoke-LocalPsql       -- ejecuta SQL via stdin, devuelve array de lineas no vacias
# Invoke-LocalPsqlScalar -- devuelve la primera linea no vacia (valor escalar)
# ---------------------------------------------------------------------------
function Invoke-LocalPsql {
    param([string]$Sql)
    if ($script:useLocal) {
        $raw = $Sql | & psql "postgresql://postgres:postgres@localhost:54322/postgres" `
            --no-psqlrc -t -A 2>&1
    } else {
        $raw = $Sql | & docker exec -i $script:dbContainer `
            psql -U postgres -d postgres --no-psqlrc -t -A 2>&1
    }
    @($raw | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne "" })
}

function Invoke-LocalPsqlScalar {
    param([string]$Sql)
    $lines = Invoke-LocalPsql $Sql
    $first = $lines | Select-Object -First 1
    if ($first) { $first } else { "" }
}

# ---------------------------------------------------------------------------
# Funcion: enviar POST al webhook y devolver resultado
# ---------------------------------------------------------------------------
function Send-WebhookPost {
    $req = [System.Net.WebRequest]::Create($Url)
    $req.Method      = "POST"
    $req.ContentType = "application/json"
    $req.Headers.Add("x-hub-signature-256", $signature)

    $st = $req.GetRequestStream()
    $st.Write($bodyBytes, 0, $bodyBytes.Length)
    $st.Close()

    try {
        $resp   = $req.GetResponse()
        $code   = [int]$resp.StatusCode
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $rb     = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()
    } catch [System.Net.WebException] {
        $ex     = $_.Exception
        $code   = [int]$ex.Response.StatusCode
        $reader = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
        $rb     = $reader.ReadToEnd()
        $reader.Close()
    }

    [PSCustomObject]@{ StatusCode = $code; Body = $rb }
}

# ---------------------------------------------------------------------------
# SQL de cleanup (siempre en el orden correcto para respetar FKs):
#   1. appointment_extras  (FK -> appointments)
#   2. appointments        (FK -> customers)
#   3. customers           (solo si ya no tienen otras appointments)
# ---------------------------------------------------------------------------
$sqlCleanup = @"
DELETE FROM public.appointment_extras ae
USING public.appointments a
WHERE ae.appointment_id = a.id
  AND a.business_id = '$businessId'
  AND a.external_reference = '$externalRef';
DELETE FROM public.appointments
WHERE business_id = '$businessId'
  AND external_reference = '$externalRef';
DELETE FROM public.customers c
WHERE c.business_id = '$businessId'
  AND c.whatsapp_phone_e164 = '$customerPhoneE164'
  AND NOT EXISTS (
    SELECT 1 FROM public.appointments a WHERE a.customer_id = c.id
  );
"@

# ---------------------------------------------------------------------------
# Mostrar parametros del test
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Test de integracion: webhook --> BD ==="
Write-Host "  URL:              $Url"
Write-Host "  phone_number_id:  000000000000002"
Write-Host "  customer.from:    $customerPhoneRaw (sin +, se normaliza a $customerPhoneE164)"
Write-Host "  appointment_date: $nextMonday (proximo lunes)"
Write-Host "  external_ref:     $externalRef"
Write-Host ""

$allPass = $true

# ---------------------------------------------------------------------------
# Las llamadas HTTP y verificaciones de BD van dentro del try.
# El cleanup va en finally y reporta su propio error sin ocultar fallos del test.
# ---------------------------------------------------------------------------
try {

    # -----------------------------------------------------------------------
    # Pre-cleanup en modo -Duplicate: eliminar residuos de ejecuciones previas
    # con la misma external_reference fija.
    # -----------------------------------------------------------------------
    if ($Duplicate -and $dbAvailable) {
        Invoke-LocalPsql $sqlCleanup | Out-Null
        Write-Host "Pre-cleanup completado para external_reference='$externalRef'."
        Write-Host ""
    }

    # -----------------------------------------------------------------------
    # Llamada 1
    # -----------------------------------------------------------------------
    Write-Host "Llamada 1..."
    $r1 = Send-WebhookPost
    Write-Host "  HTTP $($r1.StatusCode)  Body: $($r1.Body)"

    if ($r1.StatusCode -ne 200) {
        Write-Host "FAIL: llamada 1 esperaba HTTP 200, obtenido $($r1.StatusCode)"
        $allPass = $false
    } else {
        Write-Host "  PASS: HTTP 200"
    }

    if ($r1.Body -notmatch '"received"\s*:\s*true') {
        Write-Host "FAIL: body no contiene received=true"
        $allPass = $false
    } else {
        Write-Host "  PASS: body contiene received=true"
    }

    # -----------------------------------------------------------------------
    # Modo -Duplicate: llamada 2 con el mismo payload
    # -----------------------------------------------------------------------
    if ($Duplicate) {
        Write-Host ""
        Write-Host "Llamada 2 (mismo external_reference para probar idempotencia)..."
        $r2 = Send-WebhookPost
        Write-Host "  HTTP $($r2.StatusCode)  Body: $($r2.Body)"

        if ($r2.StatusCode -ne 200) {
            Write-Host "FAIL: llamada 2 esperaba HTTP 200, obtenido $($r2.StatusCode)"
            $allPass = $false
        } else {
            Write-Host "  PASS: HTTP 200"
        }
    }

    # -----------------------------------------------------------------------
    # Verificaciones de BD
    # -----------------------------------------------------------------------
    if (-not $dbAvailable) {
        Write-Warning "BD no disponible -- verificaciones omitidas."
    } else {
        Write-Host ""
        Write-Host "Verificando BD..."

        $sqlCustCount = @"
SELECT count(*) FROM public.customers
WHERE business_id = '$businessId'
  AND whatsapp_phone_e164 = '$customerPhoneE164';
"@

        $sqlApptCount = @"
SELECT count(*) FROM public.appointments
WHERE business_id = '$businessId'
  AND external_reference = '$externalRef';
"@

        $sqlApptFields = @"
SELECT status || '|' || source FROM public.appointments
WHERE business_id = '$businessId'
  AND external_reference = '$externalRef'
LIMIT 1;
"@

        $sqlExtCount = @"
SELECT count(*) FROM public.appointment_extras ae
JOIN public.appointments a ON a.id = ae.appointment_id
WHERE a.business_id = '$businessId'
  AND a.external_reference = '$externalRef';
"@

        # --- Customer con telefono normalizado ---
        $custCount = Invoke-LocalPsqlScalar $sqlCustCount
        Write-Host "  customer $customerPhoneE164 : $custCount (esperado: 1)"
        if ($custCount -ne "1") {
            Write-Host "FAIL: customer con telefono normalizado no encontrado en BD"
            $allPass = $false
        } else {
            Write-Host "  PASS: customer existe"
        }

        # --- Exactamente 1 appointment ---
        $apptCount = Invoke-LocalPsqlScalar $sqlApptCount
        Write-Host "  appointments con external_reference '$externalRef': $apptCount (esperado: 1)"
        if ($apptCount -ne "1") {
            Write-Host "FAIL: esperada 1 appointment, encontradas: $apptCount"
            $allPass = $false
        } else {
            Write-Host "  PASS: exactamente 1 appointment"

            # --- Campos status y source ---
            $apptRow = Invoke-LocalPsqlScalar $sqlApptFields
            if ($apptRow -match '\|') {
                $parts      = $apptRow -split '\|'
                $apptStatus = $parts[0]
                $apptSource = $parts[1]

                if ($apptStatus -ne "pending") {
                    Write-Host "FAIL: status esperado=pending, obtenido=$apptStatus"
                    $allPass = $false
                } else {
                    Write-Host "  PASS: status=pending"
                }

                if ($apptSource -ne "whatsapp_flow") {
                    Write-Host "FAIL: source esperado=whatsapp_flow, obtenido=$apptSource"
                    $allPass = $false
                } else {
                    Write-Host "  PASS: source=whatsapp_flow"
                }
            } else {
                Write-Host "FAIL: no se pudieron leer campos de la appointment (fila=$apptRow)"
                $allPass = $false
            }
        }

        # --- Exactamente 1 appointment_extra ---
        $extCount = Invoke-LocalPsqlScalar $sqlExtCount
        Write-Host "  appointment_extras: $extCount (esperado: 1)"
        if ($extCount -ne "1") {
            Write-Host "FAIL: esperado 1 appointment_extra (wash), encontrados: $extCount"
            $allPass = $false
        } else {
            Write-Host "  PASS: 1 appointment_extra (wash)"
        }

        # --- Modo -Duplicate: verificar idempotencia por estado final ---
        if ($Duplicate) {
            Write-Host ""
            Write-Host "Verificando idempotencia (la segunda llamada no debe crear duplicados)..."

            $dupAppt = Invoke-LocalPsqlScalar $sqlApptCount
            Write-Host "  appointments tras llamada 2: $dupAppt (esperado: 1)"
            if ($dupAppt -ne "1") {
                Write-Host "FAIL: idempotencia rota en appointments, encontradas: $dupAppt"
                $allPass = $false
            } else {
                Write-Host "  PASS: 1 sola appointment (idempotencia confirmada)"
            }

            $dupCust = Invoke-LocalPsqlScalar $sqlCustCount
            Write-Host "  customers $customerPhoneE164 tras llamada 2: $dupCust (esperado: 1)"
            if ($dupCust -ne "1") {
                Write-Host "FAIL: idempotencia rota en customers, encontrados: $dupCust"
                $allPass = $false
            } else {
                Write-Host "  PASS: 1 solo customer"
            }

            $dupExt = Invoke-LocalPsqlScalar $sqlExtCount
            Write-Host "  appointment_extras tras llamada 2: $dupExt (esperado: 1)"
            if ($dupExt -ne "1") {
                Write-Host "FAIL: idempotencia rota en extras, encontrados: $dupExt"
                $allPass = $false
            } else {
                Write-Host "  PASS: sin extras duplicados"
            }
        }
    }

} catch {
    Write-Host "ERROR inesperado durante el test: $($_.Exception.Message)"
    $allPass = $false
} finally {
    # Cleanup: siempre se ejecuta; los errores se reportan sin ocultar el resultado del test
    if ($dbAvailable) {
        try {
            Invoke-LocalPsql $sqlCleanup | Out-Null
            Write-Host ""
            Write-Host "(Datos de prueba eliminados)"
        } catch {
            Write-Warning "Error durante cleanup (no afecta el resultado del test): $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# Resultado final
# ---------------------------------------------------------------------------
Write-Host ""
if ($allPass) {
    Write-Host "=== PASS: webhook y BD verificados correctamente ==="
} else {
    Write-Host "=== FAIL: revisar logs arriba ==="
    exit 1
}
