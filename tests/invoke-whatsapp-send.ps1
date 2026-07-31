<#
.SYNOPSIS
    Invoca la Edge Function whatsapp-send para enviar la plantilla hello_world.

.PARAMETER Url
    URL del endpoint.
    Local:   http://localhost:54321/functions/v1/whatsapp-send  (default)
    Remoto:  https://<PROJECT_REF>.supabase.co/functions/v1/whatsapp-send

.PARAMETER Phone
    Numero de telefono destino en formato E.164 estricto (ej. +521234567890).

.EXAMPLE
    # Local (requiere: supabase functions serve whatsapp-send --env-file ./supabase/.env.local)
    $env:INTERNAL_FUNCTION_SECRET = "tu-secret"
    .\tests\invoke-whatsapp-send.ps1 -Phone "+521234567890"

    # Remoto
    $env:INTERNAL_FUNCTION_SECRET = "tu-secret"
    .\tests\invoke-whatsapp-send.ps1 `
        -Url "https://<PROJECT_REF>.supabase.co/functions/v1/whatsapp-send" `
        -Phone "+521234567890"
#>

param(
    [string]$Url = "http://localhost:54321/functions/v1/whatsapp-send",

    [Parameter(Mandatory = $true)]
    [string]$Phone
)

# Leer INTERNAL_FUNCTION_SECRET desde variable de entorno — nunca hardcodeado
$secret = $env:INTERNAL_FUNCTION_SECRET
if (-not $secret) {
    Write-Error "Variable de entorno INTERNAL_FUNCTION_SECRET no definida. Ejecucion detenida."
    exit 1
}

$headers = @{
    "x-internal-secret" = $secret
    "Content-Type"      = "application/json"
}

$body = @{ to = $Phone } | ConvertTo-Json -Compress

Write-Host "Endpoint : $Url"
Write-Host "Telefono : $Phone"
Write-Host ""

try {
    $response = Invoke-RestMethod `
        -Uri $Url `
        -Method POST `
        -Headers $headers `
        -Body $body `
        -ErrorAction Stop

    Write-Host "OK - Respuesta exitosa:" -ForegroundColor Green
    $response | ConvertTo-Json -Depth 5
}
catch {
    $statusCode = $null
    if ($_.Exception.Response -ne $null) {
        $statusCode = $_.Exception.Response.StatusCode.value__
    }
    Write-Host "Error HTTP $statusCode" -ForegroundColor Red

    try {
        if ($_.Exception.Response -ne $null) {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $errorBody = $reader.ReadToEnd() | ConvertFrom-Json
            $errorBody | ConvertTo-Json -Depth 5
        }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}
