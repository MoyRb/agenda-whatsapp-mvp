<#
.SYNOPSIS
    Crea un WhatsApp Flow en estado DRAFT en Meta.

.DESCRIPTION
    Llama a la Graph API para crear un Flow con categoria APPOINTMENT_BOOKING.
    Imprime el Flow ID resultante. No publica ni modifica secretos.

.PARAMETER Name
    Nombre del Flow. Ejemplo: "Reservacion de cita"

.EXAMPLE
    $env:WHATSAPP_ACCESS_TOKEN         = "tu-token"
    $env:WHATSAPP_BUSINESS_ACCOUNT_ID  = "tu-waba-id"
    $env:META_GRAPH_API_VERSION        = "v20.0"
    .\tests\flow-create-draft.ps1 -Name "Reservacion de cita"

.NOTES
    Compatible con Windows PowerShell 5.1.
    No imprime tokens ni secretos.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Name
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# --- Leer variables de entorno ---
$token      = $env:WHATSAPP_ACCESS_TOKEN
$wabaId     = $env:WHATSAPP_BUSINESS_ACCOUNT_ID
$apiVersion = $env:META_GRAPH_API_VERSION

if ($token -eq $null -or $token -eq "") {
    Write-Error "La variable de entorno WHATSAPP_ACCESS_TOKEN no esta definida en la sesion."
    exit 1
}
if ($wabaId -eq $null -or $wabaId -eq "") {
    Write-Error "La variable de entorno WHATSAPP_BUSINESS_ACCOUNT_ID no esta definida en la sesion."
    exit 1
}
if ($apiVersion -eq $null -or $apiVersion -eq "") {
    Write-Error "La variable de entorno META_GRAPH_API_VERSION no esta definida en la sesion."
    exit 1
}

Write-Host "Creando Flow DRAFT en Meta..."
Write-Host "  WABA ID:     $wabaId"
Write-Host "  API version: $apiVersion"
Write-Host "  Nombre:      $Name"
Write-Host ""

$url  = "https://graph.facebook.com/$apiVersion/$wabaId/flows"
$body = '{"name":"' + $Name + '","categories":["APPOINTMENT_BOOKING"]}'

try {
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri $url `
        -Headers @{ "Authorization" = "Bearer $token" } `
        -ContentType "application/json; charset=utf-8" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body))

    $flowId = $null
    if ($response -ne $null -and $response.id -ne $null) {
        $flowId = $response.id
    }

    if ($flowId -ne $null -and $flowId -ne "") {
        Write-Host "Flow DRAFT creado exitosamente." -ForegroundColor Green
        Write-Host ""
        Write-Host "Flow ID: $flowId"
        Write-Host ""
        Write-Host "Guarda el Flow ID para los siguientes pasos:"
        Write-Host "  `$env:WHATSAPP_FLOW_ID = `"$flowId`""
        Write-Host ""
        Write-Host "Siguiente paso:"
        Write-Host "  .\tests\flow-upload-json.ps1 -FlowId $flowId -FilePath whatsapp\flows\appointment-booking-static-v1.json"
    } else {
        Write-Warning "No se recibio un Flow ID. Respuesta completa:"
        Write-Host ($response | ConvertTo-Json -Depth 5)
    }
} catch {
    $statusCode = 0
    if ($_.Exception.Response -ne $null) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    Write-Error "Error HTTP $statusCode al crear el Flow."

    if ($_.Exception.Response -ne $null) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $errorBody = $reader.ReadToEnd()
            Write-Host "Detalle del error: $errorBody" -ForegroundColor Red
        } catch {
            Write-Warning "No se pudo leer el cuerpo del error."
        }
    }
    exit 1
}
