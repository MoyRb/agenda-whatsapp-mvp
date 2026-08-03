<#
.SYNOPSIS
    Publica un WhatsApp Flow (cambia estado DRAFT a PUBLISHED).

.DESCRIPTION
    ATENCION: Esta accion es irreversible. Un Flow publicado no puede
    volver a estado DRAFT ni ser eliminado mientras tenga envios activos.

    Ejecutar SOLO despues de:
      1. flow-upload-json.ps1 — JSON subido
      2. flow-get-validation.ps1 — 0 errores confirmados
      3. Revision manual del Flow en Meta Business Suite o el emulador

.PARAMETER FlowId
    ID del Flow a publicar.

.EXAMPLE
    $env:WHATSAPP_ACCESS_TOKEN  = "tu-token"
    $env:META_GRAPH_API_VERSION = "v20.0"
    .\tests\flow-publish.ps1 -FlowId "123456789"

.NOTES
    Compatible con Windows PowerShell 5.1.
    No imprime tokens ni secretos.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$FlowId
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

$token      = $env:WHATSAPP_ACCESS_TOKEN
$apiVersion = $env:META_GRAPH_API_VERSION

if ($token -eq $null -or $token -eq "") {
    Write-Error "La variable de entorno WHATSAPP_ACCESS_TOKEN no esta definida en la sesion."
    exit 1
}
if ($apiVersion -eq $null -or $apiVersion -eq "") {
    Write-Error "La variable de entorno META_GRAPH_API_VERSION no esta definida en la sesion."
    exit 1
}

Write-Host "ADVERTENCIA: Publicar un Flow es irreversible." -ForegroundColor Yellow
Write-Host "Flow ID a publicar: $FlowId"
Write-Host ""
$confirm = Read-Host "Escribe 'PUBLICAR' para confirmar"

if ($confirm -ne "PUBLICAR") {
    Write-Host "Publicacion cancelada." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Publicando Flow $FlowId..."

$url = "https://graph.facebook.com/$apiVersion/$FlowId/publish"

try {
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri $url `
        -Headers @{ "Authorization" = "Bearer $token" } `
        -ContentType "application/json; charset=utf-8" `
        -Body "{}"

    $success = $false
    if ($response -ne $null -and $response.success -ne $null) {
        $success = [bool]$response.success
    }

    if ($success) {
        Write-Host "Flow publicado exitosamente." -ForegroundColor Green
        Write-Host ""
        Write-Host "Ahora puedes enviar el Flow al telefono con:"
        Write-Host "  .\tests\invoke-whatsapp-flow-send.ps1 -Phone `"+52XXXXXXXXXX`" -FlowId $FlowId"
    } else {
        Write-Warning "Meta respondio pero success no fue true."
        Write-Host ($response | ConvertTo-Json -Depth 5)
    }
} catch {
    $statusCode = 0
    if ($_.Exception.Response -ne $null) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    Write-Error "Error HTTP $statusCode al publicar el Flow."

    if ($_.Exception.Response -ne $null) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            Write-Host "Detalle: $($reader.ReadToEnd())" -ForegroundColor Red
        } catch {
            Write-Warning "No se pudo leer el cuerpo del error."
        }
    }
    exit 1
}
