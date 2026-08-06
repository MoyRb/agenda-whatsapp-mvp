<#
.SYNOPSIS
  Tests del flujo OAuth de Google (TO01-TO10).
  Usar run-google-oauth-flow-tests.ps1 como orquestador.

.PARAMETER FunctionUrl
  URL base de las Edge Functions locales.
  Default: http://localhost:54321/functions/v1

.PARAMETER MockAdminUrl
  URL del mock del token endpoint para cambiar escenarios.
  Default: http://localhost:18081

.PARAMETER DbUrl
  Connection string de PostgreSQL local.
  Default: postgresql://postgres:postgres@localhost:54322/postgres

.PARAMETER DbContainer
  Nombre del contenedor Docker con la BD (alternativa a psql).
  Si se omite, se detecta automaticamente el contenedor supabase_db_*.

.PARAMETER TestFilter
  Prefijo para filtrar tests (ej: TO01). Sin filtro ejecuta todos.

.EXAMPLE
  # Via orquestador (recomendado):
  $env:INTERNAL_FUNCTION_SECRET = "tu-secret"
  .\tests\run-google-oauth-flow-tests.ps1

  # Directo (requiere mock y functions serve ya activos):
  $env:INTERNAL_FUNCTION_SECRET = "tu-secret"
  .\tests\test-google-oauth-flow.ps1
#>
param(
  [string]$FunctionUrl  = "http://localhost:54321/functions/v1",
  [string]$MockAdminUrl = "http://localhost:18081",
  [string]$DbUrl        = "postgresql://postgres:postgres@localhost:54322/postgres",
  [string]$DbContainer  = "",
  [string]$TestFilter   = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off

Add-Type -AssemblyName System.Web

$InternalSecret    = $env:INTERNAL_FUNCTION_SECRET
if (-not $InternalSecret) {
  Write-Error "Falta INTERNAL_FUNCTION_SECRET"
  exit 1
}

$OauthStartUrl    = "$FunctionUrl/google-oauth-start"
$OauthCallbackUrl = "$FunctionUrl/google-oauth-callback"
$BID              = "00000000-0000-0000-0000-000000000001"

$passed  = 0
$failed  = 0
$skipped = 0

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
$script:DbUsePsql   = $false
$script:DbUrlLocal  = $DbUrl
$script:DbContLocal = ""

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
    return psql $script:DbUrlLocal -t -A -c $sql 2>&1
  } else {
    return ($sql | docker exec -i $script:DbContLocal `
      psql -U postgres -d postgres -v ON_ERROR_STOP=1 -t -A) 2>&1
  }
}

function Invoke-LocalSqlScalar([string]$sql) {
  $raw = Invoke-LocalSql $sql
  $val = if ($raw -is [array]) {
    $raw | Where-Object { $_ -ne $null -and "$_".Trim() -ne "" } | Select-Object -First 1
  } else { $raw }
  if ($null -eq $val) { return "" }
  return "$val".Trim()
}

# ---------------------------------------------------------------------------
# HTTP helper — todos los parametros son nombrados para evitar ambiguedad
# ---------------------------------------------------------------------------
function Invoke-WebReq {
  param(
    [string]   $Url,
    [string]   $Method  = "GET",
    [string]   $Body    = "",
    [hashtable]$Headers = @{}
  )
  try {
    $req         = [System.Net.WebRequest]::Create($Url)
    $req.Method  = $Method
    $req.Timeout = 15000
    foreach ($k in $Headers.Keys) {
      # Content-Type se setea via propiedad, no via Headers (header restringido)
      if ($k -eq "Content-Type") { $req.ContentType = $Headers[$k] }
      else                       { $req.Headers.Add($k, $Headers[$k]) }
    }

    if ($Body -and $Method -ne "GET") {
      if (-not $req.ContentType) { $req.ContentType = "application/json" }
      $bodyBytes        = [System.Text.Encoding]::UTF8.GetBytes($Body)
      $req.ContentLength = $bodyBytes.Length
      $stream            = $req.GetRequestStream()
      $stream.Write($bodyBytes, 0, $bodyBytes.Length)
      $stream.Close()
    }

    try {
      $resp    = $req.GetResponse()
      $reader  = New-Object System.IO.StreamReader($resp.GetResponseStream())
      $content = $reader.ReadToEnd()
      $reader.Close(); $resp.Close()
      return @{ StatusCode = [int]$resp.StatusCode; Body = $content }
    } catch [System.Net.WebException] {
      $errResp = $_.Exception.Response
      if ($errResp) {
        $reader  = New-Object System.IO.StreamReader($errResp.GetResponseStream())
        $content = $reader.ReadToEnd()
        $reader.Close()
        return @{ StatusCode = [int]$errResp.StatusCode; Body = $content }
      }
      return @{ StatusCode = 0; Body = $_.Exception.Message }
    }
  } catch {
    return @{ StatusCode = 0; Body = $_.Exception.Message }
  }
}

# ---------------------------------------------------------------------------
# Mock: cambiar escenario del token endpoint
# ---------------------------------------------------------------------------
function Set-MockScenario([string]$scenario) {
  try {
    $body = [System.Text.Encoding]::ASCII.GetBytes($scenario)
    $wr   = [System.Net.WebRequest]::Create("$MockAdminUrl/admin/set-scenario")
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

# ---------------------------------------------------------------------------
# Helpers de estado en BD
# ---------------------------------------------------------------------------
function Cleanup-OauthStates {
  Invoke-LocalSql `
    "DELETE FROM public.google_oauth_states WHERE business_id = '$BID';" | Out-Null
}

function Cleanup-Connections {
  Invoke-LocalSql `
    "DELETE FROM public.google_calendar_connections WHERE business_id = '$BID';" | Out-Null
}

function Get-StateCount {
  return Invoke-LocalSqlScalar `
    "SELECT COUNT(*)::text FROM public.google_oauth_states WHERE business_id = '$BID' AND used_at IS NULL;"
}

function Get-ConnectionStatus {
  return Invoke-LocalSqlScalar `
    "SELECT COALESCE(status,'') FROM public.google_calendar_connections WHERE business_id = '$BID';"
}

function Get-VaultSecret {
  # Accede a vault.decrypted_secrets via el secreto de la conexion de este negocio.
  return Invoke-LocalSqlScalar @"
SELECT COALESCE(ds.decrypted_secret,'')
  FROM vault.decrypted_secrets ds
  JOIN public.google_calendar_connections gcc
    ON gcc.refresh_token_secret_id = ds.id
 WHERE gcc.business_id = '$BID';
"@
}

# ---------------------------------------------------------------------------
# Helper: obtener state_token de una respuesta oauth-start
# ---------------------------------------------------------------------------
function Get-StateTokenFromUrl([string]$oauthUrl) {
  $uri   = [System.Uri]$oauthUrl
  $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
  return $query["state"]
}

# ---------------------------------------------------------------------------
# Helper: helper que invoca oauth-start con el secret correcto y retorna el
# state token (o $null si falla)
# ---------------------------------------------------------------------------
function Invoke-OauthStart {
  $body = '{"business_id":"' + $BID + '"}'
  $resp = Invoke-WebReq `
    -Url     $OauthStartUrl `
    -Method  "POST" `
    -Body    $body `
    -Headers @{ "x-internal-secret" = $InternalSecret }
  if ($resp.StatusCode -ne 200) { return $null }
  $data = $resp.Body | ConvertFrom-Json -ErrorAction SilentlyContinue
  if (-not $data.url) { return $null }
  return @{ Data = $data; StateToken = (Get-StateTokenFromUrl $data.url) }
}

# ---------------------------------------------------------------------------
# Inicializar acceso a BD
# ---------------------------------------------------------------------------
Initialize-DbAccess

# ===========================================================================
# TO01 — oauth-start con secret válido → 200 + URL bien formada
# ===========================================================================
if (Should-Run "TO01") {
  try {
    $body = '{"business_id":"' + $BID + '"}'
    $resp = Invoke-WebReq `
      -Url     $OauthStartUrl `
      -Method  "POST" `
      -Body    $body `
      -Headers @{ "x-internal-secret" = $InternalSecret }

    if ($resp.StatusCode -ne 200) {
      Write-Fail "TO01" "Esperado 200, obtenido $($resp.StatusCode): $($resp.Body)"
    } else {
      $data = $resp.Body | ConvertFrom-Json -ErrorAction SilentlyContinue
      if (-not $data.url) {
        Write-Fail "TO01" "Response no contiene campo 'url'"
      } else {
        $authUri = [System.Uri]$data.url
        $q       = [System.Web.HttpUtility]::ParseQueryString($authUri.Query)
        $checks  = @(
          ($authUri.Host   -like "*google*"),
          ($q["client_id"] -eq "fake-client-id-for-tests"),
          ($q["redirect_uri"] -eq "http://localhost:54321/functions/v1/google-oauth-callback"),
          ($q["response_type"] -eq "code"),
          ($q["access_type"]   -eq "offline"),
          ($q["prompt"]        -eq "consent"),
          ($q["scope"]         -like "*calendar.events.owned*"),
          ($q["state"]         -ne "" -and $q["state"] -ne $null)
        )
        $allOk = $checks -notcontains $false
        if ($allOk) {
          Write-Pass "TO01" "200 + URL con client_id, redirect_uri, response_type, access_type, prompt, scope, state"
        } else {
          Write-Fail "TO01" "URL incompleta o con parametros incorrectos: $($data.url)"
        }
      }
    }
  } catch {
    Write-Fail "TO01" $_.Exception.Message
  } finally {
    try { Cleanup-OauthStates } catch {}
  }
}

# ===========================================================================
# TO02 — State token: estructura correcta + guardado en google_oauth_states
# ===========================================================================
if (Should-Run "TO02") {
  try {
    $start = Invoke-OauthStart
    if (-not $start) {
      Write-Fail "TO02" "oauth-start fallo o no devolvio URL"
    } else {
      $stateToken = $start.StateToken

      # Estructura: payloadBase64Url + "." + signatureBase64Url
      $lastDot = $stateToken.LastIndexOf(".")
      if ($lastDot -le 0 -or $stateToken.Substring(0,$lastDot).Length -lt 10 `
            -or $stateToken.Substring($lastDot+1).Length -lt 10) {
        Write-Fail "TO02" "State token no tiene estructura payloadB64.signatureB64 valida"
      } else {
        # Decodificar y verificar payload
        $payloadB64 = $stateToken.Substring(0, $lastDot)
        $padded     = $payloadB64.Replace("-","+").Replace("_","/")
        $padded     = $padded + "=" * ((4 - $padded.Length % 4) % 4)
        try {
          $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($padded))
          $payload     = $payloadJson | ConvertFrom-Json
          $payloadOk   = $payload.business_id -eq $BID -and $payload.nonce -and $payload.exp

          # Verificar que el state fue guardado en BD (count = 1)
          $stateCount = Get-StateCount
          $dbOk       = $stateCount -eq "1"

          if ($payloadOk -and $dbOk) {
            Write-Pass "TO02" "State firmado sobre payloadBase64Url con business_id+nonce+exp; guardado en BD (count=$stateCount)"
          } else {
            Write-Fail "TO02" "payloadOk=$payloadOk dbCount=$stateCount (esperado 1)"
          }
        } catch {
          Write-Fail "TO02" "No se pudo decodificar payload: $($_.Exception.Message)"
        }
      }
    }
  } catch {
    Write-Fail "TO02" $_.Exception.Message
  } finally {
    try { Cleanup-OauthStates } catch {}
  }
}

# ===========================================================================
# TO03 — Callback válido: conexión guardada, state consumido, sin tokens
#         en respuesta, refresh_token en Vault
# ===========================================================================
if (Should-Run "TO03") {
  try {
    Set-MockScenario "success"
    $start = Invoke-OauthStart
    if (-not $start) {
      Write-Fail "TO03" "oauth-start fallo"
    } else {
      $stateToken  = $start.StateToken
      $encodedState = [System.Uri]::EscapeDataString($stateToken)
      $callbackUrl  = $OauthCallbackUrl + "?code=test_auth_code&state=" + $encodedState

      $resp = Invoke-WebReq -Url $callbackUrl -Method "GET"

      if ($resp.StatusCode -ne 200) {
        Write-Fail "TO03" "Callback retorno $($resp.StatusCode): $($resp.Body)"
      } else {
        $cbData = $resp.Body | ConvertFrom-Json -ErrorAction SilentlyContinue

        # Sin tokens en respuesta
        $noTokensInResp = $resp.Body -notlike "*refresh_token*" `
                       -and $resp.Body -notlike "*access_token*"

        # success = true y campos esperados
        $responseOk = $cbData.success -eq $true `
                   -and $cbData.business_id -eq $BID `
                   -and $cbData.calendar_id -eq "primary"

        # Conexion guardada en BD
        $connStatus = Get-ConnectionStatus
        $connOk     = $connStatus -eq "active"

        # State consumido (used_at IS NOT NULL → count de disponibles = 0)
        $stateCount   = Get-StateCount
        $stateConsumed = $stateCount -eq "0"

        # Refresh token en Vault
        $vaultSecret = ""
        try { $vaultSecret = Get-VaultSecret } catch {}
        $vaultOk = $vaultSecret -eq "mock-refresh-token-to03"

        if ($noTokensInResp -and $responseOk -and $connOk -and $stateConsumed -and $vaultOk) {
          Write-Pass "TO03" "Callback valido: success=true, connection=active, state consumido, vault OK, sin tokens en respuesta"
        } else {
          Write-Fail "TO03" ("noTokensInResp=$noTokensInResp responseOk=$responseOk " +
                             "connStatus=$connStatus stateConsumed=$stateConsumed vaultOk=$vaultOk")
        }
      }
    }
  } catch {
    Write-Fail "TO03" $_.Exception.Message
  } finally {
    try { Cleanup-OauthStates } catch {}
    try { Cleanup-Connections } catch {}
    Set-MockScenario "success"
  }
}

# ===========================================================================
# TO04 — State expirado → callback retorna 400 con oauth_state_expired
# ===========================================================================
if (Should-Run "TO04") {
  try {
    $start = Invoke-OauthStart
    if (-not $start) {
      Write-Fail "TO04" "oauth-start fallo"
    } else {
      $stateToken = $start.StateToken

      # Forzar expiración del state en BD (sin cambiar el state_token ni el HMAC)
      Invoke-LocalSql @"
UPDATE public.google_oauth_states
   SET expires_at = now() - INTERVAL '1 hour'
 WHERE business_id = '$BID'
   AND used_at IS NULL;
"@ | Out-Null

      $encodedState = [System.Uri]::EscapeDataString($stateToken)
      $callbackUrl  = $OauthCallbackUrl + "?code=test_code&state=" + $encodedState
      $resp         = Invoke-WebReq -Url $callbackUrl -Method "GET"

      if ($resp.StatusCode -eq 400 -and $resp.Body -like "*oauth_state_expired*") {
        Write-Pass "TO04" "State expirado → callback 400 con oauth_state_expired"
      } else {
        Write-Fail "TO04" "Esperado 400 oauth_state_expired; obtenido $($resp.StatusCode): $($resp.Body)"
      }
    }
  } catch {
    Write-Fail "TO04" $_.Exception.Message
  } finally {
    try { Cleanup-OauthStates } catch {}
  }
}

# ===========================================================================
# TO05 — State reutilizado → callback retorna 400 con oauth_state_already_used
# ===========================================================================
if (Should-Run "TO05") {
  try {
    $start = Invoke-OauthStart
    if (-not $start) {
      Write-Fail "TO05" "oauth-start fallo"
    } else {
      $stateToken = $start.StateToken

      # Marcar el state como ya usado en BD
      Invoke-LocalSql @"
UPDATE public.google_oauth_states
   SET used_at = now()
 WHERE business_id = '$BID'
   AND used_at IS NULL;
"@ | Out-Null

      $encodedState = [System.Uri]::EscapeDataString($stateToken)
      $callbackUrl  = $OauthCallbackUrl + "?code=test_code&state=" + $encodedState
      $resp         = Invoke-WebReq -Url $callbackUrl -Method "GET"

      if ($resp.StatusCode -eq 400 -and $resp.Body -like "*oauth_state_already_used*") {
        Write-Pass "TO05" "State ya usado → callback 400 con oauth_state_already_used"
      } else {
        Write-Fail "TO05" "Esperado 400 oauth_state_already_used; obtenido $($resp.StatusCode): $($resp.Body)"
      }
    }
  } catch {
    Write-Fail "TO05" $_.Exception.Message
  } finally {
    try { Cleanup-OauthStates } catch {}
  }
}

# ===========================================================================
# TO06 — HMAC inválido → callback retorna 401
# ===========================================================================
if (Should-Run "TO06") {
  try {
    # State con payload válido pero firma incorrecta
    $fakePayload   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(
      '{"business_id":"' + $BID + '","nonce":"fake","exp":9999999999999}'))
    $fakePayload   = $fakePayload.Replace("+","-").Replace("/","_").Replace("=","")
    $fakeSig       = "aW52YWxpZHNpZ25hdHVyZXRoYXRkb2VzbWF0Y2g"
    $fakeState     = "$fakePayload.$fakeSig"
    $encodedState  = [System.Uri]::EscapeDataString($fakeState)
    $callbackUrl   = $OauthCallbackUrl + "?code=some_code&state=" + $encodedState
    $resp          = Invoke-WebReq -Url $callbackUrl -Method "GET"

    if ($resp.StatusCode -eq 401) {
      Write-Pass "TO06" "HMAC invalido → callback 401"
    } else {
      Write-Fail "TO06" "Esperado 401; obtenido $($resp.StatusCode): $($resp.Body)"
    }
  } catch {
    Write-Fail "TO06" $_.Exception.Message
  }
}

# ===========================================================================
# TO07 — ?error=access_denied → callback retorna 400 sin consumir state
# ===========================================================================
if (Should-Run "TO07") {
  try {
    $start = Invoke-OauthStart
    if (-not $start) {
      Write-Fail "TO07" "oauth-start fallo"
    } else {
      $stateToken   = $start.StateToken
      $encodedState = [System.Uri]::EscapeDataString($stateToken)
      $callbackUrl  = $OauthCallbackUrl + "?error=access_denied&state=" + $encodedState
      $resp         = Invoke-WebReq -Url $callbackUrl -Method "GET"

      # State debe seguir disponible (no consumido)
      $stateCount = Get-StateCount

      if ($resp.StatusCode -eq 400 -and $resp.Body -like "*access_denied*" -and $stateCount -eq "1") {
        Write-Pass "TO07" "access_denied → 400 + state no consumido (count=$stateCount)"
      } else {
        Write-Fail "TO07" "Esperado 400 access_denied y state intacto; obtenido $($resp.StatusCode) stateCount=$($stateCount): $($resp.Body)"
      }
    }
  } catch {
    Write-Fail "TO07" $_.Exception.Message
  } finally {
    try { Cleanup-OauthStates } catch {}
  }
}

# ===========================================================================
# TO08 — Token endpoint sin refresh_token → callback retorna 400
# ===========================================================================
if (Should-Run "TO08") {
  try {
    Set-MockScenario "no_refresh_token"
    $start = Invoke-OauthStart
    if (-not $start) {
      Write-Fail "TO08" "oauth-start fallo"
    } else {
      $stateToken   = $start.StateToken
      $encodedState = [System.Uri]::EscapeDataString($stateToken)
      $callbackUrl  = $OauthCallbackUrl + "?code=test_code&state=" + $encodedState
      $resp         = Invoke-WebReq -Url $callbackUrl -Method "GET"

      if ($resp.StatusCode -eq 400 -and $resp.Body -like "*no_refresh_token_in_response*") {
        Write-Pass "TO08" "Token endpoint sin refresh_token → callback 400 con no_refresh_token_in_response"
      } else {
        Write-Fail "TO08" "Esperado 400 no_refresh_token_in_response; obtenido $($resp.StatusCode): $($resp.Body)"
      }
    }
  } catch {
    Write-Fail "TO08" $_.Exception.Message
  } finally {
    try { Cleanup-OauthStates } catch {}
    try { Cleanup-Connections } catch {}
    Set-MockScenario "success"
  }
}

# ===========================================================================
# TO09 — Sin x-internal-secret → oauth-start retorna 401
# ===========================================================================
if (Should-Run "TO09") {
  try {
    $body = '{"business_id":"' + $BID + '"}'
    $resp = Invoke-WebReq `
      -Url    $OauthStartUrl `
      -Method "POST" `
      -Body   $body

    if ($resp.StatusCode -eq 401) {
      Write-Pass "TO09" "Sin x-internal-secret → oauth-start 401"
    } else {
      Write-Fail "TO09" "Esperado 401; obtenido $($resp.StatusCode)"
    }
  } catch {
    Write-Fail "TO09" $_.Exception.Message
  }
}

# ===========================================================================
# TO10 — Secret incorrecto → oauth-start retorna 401
# ===========================================================================
if (Should-Run "TO10") {
  try {
    $body = '{"business_id":"' + $BID + '"}'
    $resp = Invoke-WebReq `
      -Url     $OauthStartUrl `
      -Method  "POST" `
      -Body    $body `
      -Headers @{ "x-internal-secret" = "wrong-secret-value-for-to10" }

    if ($resp.StatusCode -eq 401) {
      Write-Pass "TO10" "Secret incorrecto → oauth-start 401"
    } else {
      Write-Fail "TO10" "Esperado 401; obtenido $($resp.StatusCode)"
    }
  } catch {
    Write-Fail "TO10" $_.Exception.Message
  }
}

# ===========================================================================
# Resumen
# ===========================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Resultados OAuth: PASS=$passed  FAIL=$failed  SKIP=$skipped" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 }
