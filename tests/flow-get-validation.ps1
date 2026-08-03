<#
.SYNOPSIS
    Consulta los errores de validacion de un Flow en Meta.

.DESCRIPTION
    Obtiene el estado y los errores de validacion del Flow JSON
    que fue subido. Debe ejecutarse despues de flow-upload-json.ps1.

.PARAMETER FlowId
    ID del Flow a consultar.

.EXAMPLE
    $env:WHATSAPP_ACCESS_TOKEN  = "tu-token"
    $env:META_GRAPH_API_VERSION = "v20.0"
    .\tests\flow-get-validation.ps1 -FlowId "123456789"

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

Write-Host "Consultando validacion del Flow $FlowId..."
Write-Host ""

$url = "https://graph.facebook.com/$apiVersion/$FlowId`?fields=id,name,status,validation_errors"

try {
    $response = Invoke-RestMethod `
        -Method Get `
        -Uri $url `
        -Headers @{ "Authorization" = "Bearer $token" }

    Write-Host "Flow ID:  $($response.id)"
    Write-Host "Nombre:   $($response.name)"
    Write-Host "Estado:   $($response.status)"
    Write-Host ""

    $errors = $response.validation_errors
    if ($errors -eq $null -or ($errors -is [System.Array] -and $errors.Count -eq 0)) {
        Write-Host "Sin errores de validacion. El JSON es valido." -ForegroundColor Green
        Write-Host ""
        Write-Host "Siguiente paso (solo despues de revision manual):"
        Write-Host "  .\tests\flow-publish.ps1 -FlowId $FlowId"
    } else {
        Write-Host "Errores de validacion encontrados:" -ForegroundColor Red
        Write-Host ($errors | ConvertTo-Json -Depth 10)
        Write-Host ""
        Write-Host "Corrige el JSON y vuelve a subir con flow-upload-json.ps1"
        exit 1
    }
} catch {
    $statusCode = 0
    if ($_.Exception.Response -ne $null) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    Write-Error "Error HTTP $statusCode al consultar el Flow."

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
