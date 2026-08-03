<#
.SYNOPSIS
    Sube el Flow JSON a un Flow DRAFT en Meta.

.DESCRIPTION
    Usa multipart/form-data para subir el archivo JSON al endpoint de assets
    de la Graph API. El Flow debe estar en estado DRAFT.

.PARAMETER FlowId
    ID del Flow DRAFT obtenido con flow-create-draft.ps1

.PARAMETER FilePath
    Ruta al archivo Flow JSON.
    Ejemplo: "whatsapp\flows\appointment-booking-static-v1.json"

.EXAMPLE
    $env:WHATSAPP_ACCESS_TOKEN  = "tu-token"
    $env:META_GRAPH_API_VERSION = "v20.0"
    .\tests\flow-upload-json.ps1 -FlowId "123456789" -FilePath "whatsapp\flows\appointment-booking-static-v1.json"

.NOTES
    Compatible con Windows PowerShell 5.1 y PowerShell 7.
    Usa System.Net.Http para construir multipart/form-data.
    El campo name y el filename del campo file se envian como "flow.json"
    tal como requiere la Graph API. asset_type debe ser "FLOW_JSON".
    No imprime tokens ni secretos.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$FlowId,

    [Parameter(Mandatory=$true)]
    [string]$FilePath
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# --- Leer variables de entorno ---
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

# --- Verificar que el archivo existe y tiene extension .json ---
$resolvedPath = $null
try {
    $resolvedPath = Resolve-Path $FilePath -ErrorAction Stop
} catch {
    Write-Error "El archivo no existe: $FilePath"
    exit 1
}
$absolutePath = $resolvedPath.Path
$ext = [System.IO.Path]::GetExtension($absolutePath).ToLower()
if ($ext -ne ".json") {
    Write-Error "El archivo debe tener extension .json: $absolutePath"
    exit 1
}

Write-Host "Subiendo Flow JSON..."
Write-Host "  Flow ID:    $FlowId"
Write-Host "  Archivo:    $absolutePath"
Write-Host "  API:        $apiVersion"
Write-Host "  Partes:     file (flow.json, application/json) + name (flow.json) + asset_type (FLOW_JSON)"
Write-Host ""

$url = "https://graph.facebook.com/$apiVersion/$FlowId/assets"

# --- Construir multipart/form-data con .NET ---
Add-Type -AssemblyName System.Net.Http

$client    = New-Object System.Net.Http.HttpClient
$multipart = New-Object System.Net.Http.MultipartFormDataContent
$fileStream = $null

try {
    $client.DefaultRequestHeaders.Add("Authorization", "Bearer $token")

    $fileStream  = [System.IO.File]::OpenRead($absolutePath)
    $fileContent = New-Object System.Net.Http.StreamContent($fileStream)

    $mediaType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
    $fileContent.Headers.ContentType = $mediaType

    # filename fijo "flow.json" tal como requiere la Graph API
    $multipart.Add($fileContent, "file", "flow.json")
    $multipart.Add((New-Object System.Net.Http.StringContent("flow.json")), "name")
    $multipart.Add((New-Object System.Net.Http.StringContent("FLOW_JSON")), "asset_type")

    $task     = $client.PostAsync($url, $multipart)
    $response = $task.Result
    $body     = $response.Content.ReadAsStringAsync().Result

    $statusCode = [int]$response.StatusCode

    if ($response.IsSuccessStatusCode) {
        Write-Host "JSON subido exitosamente (HTTP $statusCode)." -ForegroundColor Green
        Write-Host ""
        Write-Host "Respuesta de Meta:"
        Write-Host $body
        Write-Host ""
        Write-Host "Siguiente paso: verificar errores de validacion:"
        Write-Host "  .\tests\flow-get-validation.ps1 -FlowId $FlowId"
    } else {
        Write-Host "Error HTTP $statusCode al subir el JSON:" -ForegroundColor Red
        Write-Host $body
        exit 1
    }
} finally {
    if ($fileStream -ne $null) { $fileStream.Dispose() }
    $multipart.Dispose()
    $client.Dispose()
}
