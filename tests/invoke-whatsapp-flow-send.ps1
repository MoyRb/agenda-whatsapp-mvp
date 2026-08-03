<#
.SYNOPSIS
    Envia un mensaje interactivo de WhatsApp Flow al telefono indicado.

.DESCRIPTION
    Llama a la Edge Function whatsapp-flow-send para enviar el formulario
    de reservacion de cita al numero de telefono autorizado.

    El Flow debe estar en estado PUBLISHED para usar -Mode published (default).
    Para pruebas con un Flow en DRAFT usa -Mode draft.

.PARAMETER Phone
    Numero de telefono en formato E.164. Ejemplo: +524421234567

.PARAMETER FlowId
    ID del Flow a enviar. Si no se proporciona se usa $env:WHATSAPP_FLOW_ID.

.PARAMETER FlowToken
    Token de sesion de Flow. Por defecto "unused" (valido para pruebas).

.PARAMETER Mode
    Modo de envio: "published" (default) o "draft".

.PARAMETER Url
    URL de la Edge Function. Por defecto: http://localhost:54321/functions/v1/whatsapp-flow-send

.EXAMPLE
    $env:INTERNAL_FUNCTION_SECRET = "tu-secret"
    $env:WHATSAPP_FLOW_ID         = "123456789"
    .\tests\invoke-whatsapp-flow-send.ps1 -Phone "+524421234567"

.EXAMPLE
    .\tests\invoke-whatsapp-flow-send.ps1 -Phone "+524421234567" -FlowId "123456789" -Mode draft

.NOTES
    Compatible con Windows PowerShell 5.1.
    No imprime tokens ni secretos.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Phone,

    [Parameter(Mandatory=$false)]
    [string]$FlowId = "",

    [Parameter(Mandatory=$false)]
    [string]$FlowToken = "unused",

    [Parameter(Mandatory=$false)]
    [ValidateSet("published","draft")]
    [string]$Mode = "published",

    [Parameter(Mandatory=$false)]
    [string]$Url = "http://localhost:54321/functions/v1/whatsapp-flow-send"
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

$secret = $env:INTERNAL_FUNCTION_SECRET

if ($secret -eq $null -or $secret -eq "") {
    Write-Error "La variable de entorno INTERNAL_FUNCTION_SECRET no esta definida en la sesion."
    exit 1
}

# Resolver flow_id: parametro tiene prioridad, luego variable de entorno
$resolvedFlowId = $FlowId
if ($resolvedFlowId -eq $null -or $resolvedFlowId -eq "") {
    $resolvedFlowId = $env:WHATSAPP_FLOW_ID
}
if ($resolvedFlowId -eq $null -or $resolvedFlowId -eq "") {
    Write-Error "flow_id requerido: usa -FlowId o define `$env:WHATSAPP_FLOW_ID"
    exit 1
}

Write-Host "Enviando WhatsApp Flow..."
Write-Host "  Destinatario: $Phone"
Write-Host "  Flow ID:      $resolvedFlowId"
Write-Host "  Modo:         $Mode"
Write-Host "  URL:          $Url"
Write-Host ""

# Construir body JSON sin acentos para evitar problemas de encoding en PS 5.1
$bodyObj = @{
    to         = $Phone
    flow_id    = $resolvedFlowId
    flow_token = $FlowToken
    mode       = $Mode
}
$bodyJson  = $bodyObj | ConvertTo-Json -Compress
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

$request = [System.Net.WebRequest]::Create($Url)
$request.Method      = "POST"
$request.ContentType = "application/json; charset=utf-8"
$request.ContentLength = $bodyBytes.Length
$request.Headers.Add("x-internal-secret", $secret)

$stream = $request.GetRequestStream()
$stream.Write($bodyBytes, 0, $bodyBytes.Length)
$stream.Close()

try {
    $response    = $request.GetResponse()
    $statusCode  = [int]$response.StatusCode
    $respStream  = $response.GetResponseStream()
    $reader      = New-Object System.IO.StreamReader($respStream)
    $respBody    = $reader.ReadToEnd()
    $reader.Close()
    $response.Close()

    Write-Host "HTTP $statusCode" -ForegroundColor Green

    try {
        $parsed    = $respBody | ConvertFrom-Json
        $msgId     = $null
        $recipient = $null
        $modeResp  = $null

        if ($parsed -ne $null) {
            if ($parsed.message_id -ne $null)  { $msgId     = $parsed.message_id }
            if ($parsed.recipient  -ne $null)  { $recipient = $parsed.recipient  }
            if ($parsed.mode       -ne $null)  { $modeResp  = $parsed.mode       }
        }

        Write-Host ""
        Write-Host "Flow enviado exitosamente." -ForegroundColor Green
        if ($msgId     -ne $null) { Write-Host "  message_id: $msgId"     }
        if ($recipient -ne $null) { Write-Host "  recipient:  $recipient" }
        if ($modeResp  -ne $null) { Write-Host "  modo:       $modeResp"  }
    } catch {
        Write-Host "Respuesta: $respBody"
    }
} catch [System.Net.WebException] {
    $webEx      = $_.Exception
    $statusCode = 0
    $errorBody  = ""

    if ($webEx.Response -ne $null) {
        $statusCode = [int]$webEx.Response.StatusCode
        try {
            $errStream = $webEx.Response.GetResponseStream()
            $errReader = New-Object System.IO.StreamReader($errStream)
            $errorBody = $errReader.ReadToEnd()
            $errReader.Close()
        } catch { }
    }

    Write-Host "HTTP $statusCode" -ForegroundColor Red
    if ($errorBody -ne "") {
        Write-Host "Error: $errorBody"
    } else {
        Write-Host "Error: $($webEx.Message)"
    }
    exit 1
}
