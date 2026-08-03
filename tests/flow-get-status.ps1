<#
.SYNOPSIS
    Consulta el ID y estado de un WhatsApp Flow en Meta.

.DESCRIPTION
    Obtiene los campos principales del Flow: id, nombre, estado y categorias.
    Util para confirmar que el Flow fue creado, subido o publicado correctamente.

.PARAMETER FlowId
    ID del Flow a consultar.

.EXAMPLE
    $env:WHATSAPP_ACCESS_TOKEN  = "tu-token"
    $env:META_GRAPH_API_VERSION = "v20.0"
    .\tests\flow-get-status.ps1 -FlowId "123456789"

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

Write-Host "Consultando estado del Flow $FlowId..."
Write-Host ""

$url = "https://graph.facebook.com/$apiVersion/$FlowId`?fields=id,name,status,categories,validation_errors"

try {
    $response = Invoke-RestMethod `
        -Method Get `
        -Uri $url `
        -Headers @{ "Authorization" = "Bearer $token" }

    $status = $response.status

    Write-Host "--- Flow Info ---"
    Write-Host "ID:          $($response.id)"
    Write-Host "Nombre:      $($response.name)"
    Write-Host "Estado:      $status"

    if ($response.categories -ne $null) {
        Write-Host "Categorias:  $($response.categories -join ', ')"
    }

    $errors = $response.validation_errors
    if ($errors -ne $null -and $errors -is [System.Array] -and $errors.Count -gt 0) {
        Write-Host ""
        Write-Host "Errores de validacion:" -ForegroundColor Red
        Write-Host ($errors | ConvertTo-Json -Depth 10)
    }

    Write-Host ""

    if ($status -eq "DRAFT") {
        Write-Host "Estado DRAFT: el Flow aun no esta publicado." -ForegroundColor Yellow
        Write-Host "Para publicar (solo despues de revision): .\tests\flow-publish.ps1 -FlowId $FlowId"
    } elseif ($status -eq "PUBLISHED") {
        Write-Host "Estado PUBLISHED: el Flow esta activo." -ForegroundColor Green
    } elseif ($status -eq "DEPRECATED") {
        Write-Host "Estado DEPRECATED: el Flow fue deprecado." -ForegroundColor Yellow
    } else {
        Write-Host "Estado: $status"
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
