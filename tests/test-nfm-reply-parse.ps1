<#
.SYNOPSIS
    Prueba unitaria sintetica del parseo de nfm_reply en el webhook.

.DESCRIPTION
    Construye un payload sintetico de WhatsApp que contiene un mensaje
    interactivo de tipo nfm_reply (respuesta de WhatsApp Flow).

    Firma el payload con HMAC-SHA256 usando $env:META_APP_SECRET y lo
    envia al webhook local. Verifica que:
      - La respuesta HTTP sea 200
      - El cuerpo sea {"received":true}

    Para confirmar que el webhook logueo el flow_response correctamente,
    revisar la consola donde corre "supabase functions serve whatsapp-webhook".

    PREREQUISITO: el webhook debe estar corriendo localmente:
      supabase functions serve whatsapp-webhook --env-file ./supabase/.env.local

    DATOS SINTETICOS: no contiene telefonos reales, tokens ni secretos de produccion.

.PARAMETER Url
    URL del webhook local.
    Por defecto: http://localhost:54321/functions/v1/whatsapp-webhook

.EXAMPLE
    $env:META_APP_SECRET = "tu-app-secret"
    .\tests\test-nfm-reply-parse.ps1

.NOTES
    Compatible con Windows PowerShell 5.1.
    No imprime tokens ni secretos.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$Url = "http://localhost:54321/functions/v1/whatsapp-webhook"
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

$appSecret = $env:META_APP_SECRET
if ($appSecret -eq $null -or $appSecret -eq "") {
    Write-Error "La variable de entorno META_APP_SECRET no esta definida en la sesion."
    exit 1
}

# ---------------------------------------------------------------------------
# Payload sintetico: nfm_reply con datos de prueba (sin datos reales)
# ---------------------------------------------------------------------------
# response_json es el string JSON que viene del formulario completado
$responseJsonInner = '{"service_id":"haircut","extra_ids":["wash","mask"],"appointment_date":"2026-08-15","appointment_time":"10_00","flow_version":"appointment-booking-static-v1"}'
# El response_json se embebe como string dentro del objeto interactive
$responseJsonEscaped = $responseJsonInner.Replace('"', '\"')

$payload = '{"object":"whatsapp_business_account","entry":[{"id":"WABA_SINTETICO_001","changes":[{"value":{"messaging_product":"whatsapp","metadata":{"display_phone_number":"5540001234","phone_number_id":"PHONE_ID_SINTETICO"},"messages":[{"from":"5219991234567","id":"wamid.TEST_NfmReply_001","timestamp":"1753920000","type":"interactive","interactive":{"type":"nfm_reply","nfm_reply":{"response_json":"' + $responseJsonEscaped + '","body":"Sent","name":"flow"}}}]},"field":"messages"}]}]}'

Write-Host "=== Test: nfm_reply sintetico ==="
Write-Host ""
Write-Host "Payload (truncado):"
$preview = $payload.Substring(0, [Math]::Min(120, $payload.Length))
Write-Host "  $preview..."
Write-Host ""

# ---------------------------------------------------------------------------
# Calcular firma HMAC-SHA256
# ---------------------------------------------------------------------------
$secretBytes  = [System.Text.Encoding]::UTF8.GetBytes($appSecret)
$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

$hmac      = New-Object System.Security.Cryptography.HMACSHA256(,$secretBytes)
$hashBytes = $hmac.ComputeHash($payloadBytes)
$hexSig    = ($hashBytes | ForEach-Object { $_.ToString("x2") }) -join ""
$sigHeader = "sha256=$hexSig"

# ---------------------------------------------------------------------------
# Enviar POST al webhook
# ---------------------------------------------------------------------------
$request = [System.Net.WebRequest]::Create($Url)
$request.Method        = "POST"
$request.ContentType   = "application/json; charset=utf-8"
$request.ContentLength = $payloadBytes.Length
$request.Headers.Add("x-hub-signature-256", $sigHeader)

$reqStream = $request.GetRequestStream()
$reqStream.Write($payloadBytes, 0, $payloadBytes.Length)
$reqStream.Close()

$statusCode = 0
$respBody   = ""
$passed     = $false

try {
    $response   = $request.GetResponse()
    $statusCode = [int]$response.StatusCode
    $respStream = $response.GetResponseStream()
    $reader     = New-Object System.IO.StreamReader($respStream)
    $respBody   = $reader.ReadToEnd()
    $reader.Close()
    $response.Close()
} catch [System.Net.WebException] {
    $webEx = $_.Exception
    if ($webEx.Response -ne $null) {
        $statusCode = [int]$webEx.Response.StatusCode
        try {
            $errStream = $webEx.Response.GetResponseStream()
            $errReader = New-Object System.IO.StreamReader($errStream)
            $respBody  = $errReader.ReadToEnd()
            $errReader.Close()
        } catch { }
    }
}

# ---------------------------------------------------------------------------
# Evaluar resultado
# ---------------------------------------------------------------------------
$expectedStatus = 200
$expectedBody   = '{"received":true}'

if ($statusCode -eq $expectedStatus -and $respBody.Trim() -eq $expectedBody) {
    $passed = $true
}

if ($passed) {
    Write-Host "PASS  HTTP $statusCode  body=$respBody" -ForegroundColor Green
} else {
    Write-Host "FAIL  HTTP $statusCode  body=$respBody" -ForegroundColor Red
    Write-Host "      Esperado: HTTP $expectedStatus  body=$expectedBody"
    exit 1
}

Write-Host ""
Write-Host "---"
Write-Host "Para confirmar el log sanitizado, revisa la consola del servidor."
Write-Host "Debe aparecer una linea con:"
Write-Host '  {"type":"flow_response","wabaId":"WABA_SINTETICO_001",...,"serviceId":"haircut",...}'
Write-Host ""
Write-Host "No debe aparecer: response_json completo, telefonos sin enmascarar,"
Write-Host "nombres, tokens ni claves desconocidas."
