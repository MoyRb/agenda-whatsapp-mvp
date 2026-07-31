# tests/invoke-whatsapp-webhook.ps1
# Compatible con Windows PowerShell 5.1 y PowerShell 7
# Uso:
#   $env:WHATSAPP_VERIFY_TOKEN = "tu-verify-token"
#   $env:META_APP_SECRET       = "tu-app-secret"
#   .\tests\invoke-whatsapp-webhook.ps1 -Test get-valid

param(
    [string]$Url = "http://localhost:54321/functions/v1/whatsapp-webhook",
    [ValidateSet("get-valid","get-invalid","post-valid","post-invalid")]
    [string]$Test = "get-valid"
)

$verifyToken = $env:WHATSAPP_VERIFY_TOKEN
$appSecret   = $env:META_APP_SECRET

# ---------------------------------------------------------------------------
# Helpers de salida
# ---------------------------------------------------------------------------
function Write-Pass {
    param([string]$msg)
    Write-Host "[PASS] $msg" -ForegroundColor Green
}

function Write-Fail {
    param([string]$msg)
    Write-Host "[FAIL] $msg" -ForegroundColor Red
}

function Get-ResponseStatus {
    param($webReq)
    try {
        $resp = $webReq.GetResponse()
        $status = [int]$resp.StatusCode
        $resp.Close()
        return $status
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Response -ne $null) {
            return [int]$ex.Response.StatusCode
        }
        throw
    }
}

function Get-ResponseBody {
    param($webReq)
    try {
        $resp = $webReq.GetResponse()
        $stream = $resp.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()
        return $body
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Response -ne $null) {
            $stream = $ex.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            return $body
        }
        return ""
    }
}

# ---------------------------------------------------------------------------
# Caso: get-valid
# ---------------------------------------------------------------------------
if ($Test -eq "get-valid") {
    if (-not $verifyToken) {
        Write-Fail "WHATSAPP_VERIFY_TOKEN no está definido"
        exit 1
    }

    $challenge = "test-challenge-12345"
    $getUrl = "$Url`?hub.mode=subscribe&hub.verify_token=$([Uri]::EscapeDataString($verifyToken))&hub.challenge=$challenge"

    $webReq = [System.Net.WebRequest]::Create($getUrl)
    $webReq.Method = "GET"

    $body = Get-ResponseBody $webReq
    $status = 0
    try {
        $webReq2 = [System.Net.WebRequest]::Create($getUrl)
        $webReq2.Method = "GET"
        $resp2 = $webReq2.GetResponse()
        $status = [int]$resp2.StatusCode
        $stream2 = $resp2.GetResponseStream()
        $reader2 = New-Object System.IO.StreamReader($stream2)
        $body = $reader2.ReadToEnd()
        $reader2.Close()
        $resp2.Close()
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Response -ne $null) {
            $status = [int]$ex.Response.StatusCode
        }
    }

    if ($status -eq 200 -and $body -eq $challenge) {
        Write-Pass "get-valid: HTTP $status, challenge devuelto correctamente"
    } else {
        Write-Fail "get-valid: HTTP $status, body='$body' (esperado 200 y '$challenge')"
    }
}

# ---------------------------------------------------------------------------
# Caso: get-invalid
# ---------------------------------------------------------------------------
if ($Test -eq "get-invalid") {
    $challenge = "test-challenge-12345"
    $badToken  = "token-incorrecto-deliberado"
    $getUrl    = "$Url`?hub.mode=subscribe&hub.verify_token=$([Uri]::EscapeDataString($badToken))&hub.challenge=$challenge"

    $status = 0
    try {
        $webReq = [System.Net.WebRequest]::Create($getUrl)
        $webReq.Method = "GET"
        $resp = $webReq.GetResponse()
        $status = [int]$resp.StatusCode
        $resp.Close()
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Response -ne $null) {
            $status = [int]$ex.Response.StatusCode
        }
    }

    if ($status -eq 403) {
        Write-Pass "get-invalid: HTTP $status (403 esperado)"
    } else {
        Write-Fail "get-invalid: HTTP $status (esperado 403)"
    }
}

# ---------------------------------------------------------------------------
# Casos POST: construir body y firma HMAC
# ---------------------------------------------------------------------------
if ($Test -eq "post-valid" -or $Test -eq "post-invalid") {
    if (-not $appSecret) {
        Write-Fail "META_APP_SECRET no está definido"
        exit 1
    }

    # Body JSON compacto y determinista
    $bodyJson = '{"object":"whatsapp_business_account","entry":[{"id":"WABA_TEST","changes":[{"value":{"messaging_product":"whatsapp","metadata":{"phone_number_id":"PHONE_ID_TEST","display_phone_number":""},"messages":[{"from":"529991234567","id":"wamid.test001","timestamp":"1700000000","type":"text","text":{"body":"hola"}}]},"field":"messages"}]}]}'

    # Convertir a bytes UTF-8
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

    # Calcular HMAC-SHA256
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($appSecret)
    $sigBytes = $hmac.ComputeHash($bodyBytes)
    $sigHex = ($sigBytes | ForEach-Object { $_.ToString("x2") }) -join ""
    $signature = "sha256=$sigHex"

    # ---------------------------------------------------------------------------
    # Caso: post-valid
    # ---------------------------------------------------------------------------
    if ($Test -eq "post-valid") {
        $webReq = [System.Net.WebRequest]::Create($Url)
        $webReq.Method = "POST"
        $webReq.ContentType = "application/json; charset=utf-8"
        $webReq.Headers.Add("x-hub-signature-256", $signature)
        $webReq.ContentLength = $bodyBytes.Length

        $stream = $webReq.GetRequestStream()
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Close()

        $status = 0
        $body   = ""
        try {
            $resp = $webReq.GetResponse()
            $status = [int]$resp.StatusCode
            $rStream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($rStream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            $resp.Close()
        } catch [System.Net.WebException] {
            $ex = $_.Exception
            if ($ex.Response -ne $null) {
                $status = [int]$ex.Response.StatusCode
                $rStream = $ex.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($rStream)
                $body = $reader.ReadToEnd()
                $reader.Close()
            }
        }

        if ($status -eq 200 -and $body -eq '{"received":true}') {
            Write-Pass "post-valid: HTTP $status, body='$body'"
        } else {
            Write-Fail "post-valid: HTTP $status, body='$body' (esperado 200 y '{`"received`":true}')"
        }
    }

    # ---------------------------------------------------------------------------
    # Caso: post-invalid — alterar el último carácter de la firma
    # ---------------------------------------------------------------------------
    if ($Test -eq "post-invalid") {
        $lastChar = $sigHex[-1]
        if ($lastChar -eq "a") {
            $alteredHex = $sigHex.Substring(0, $sigHex.Length - 1) + "b"
        } else {
            $alteredHex = $sigHex.Substring(0, $sigHex.Length - 1) + "a"
        }
        $badSignature = "sha256=$alteredHex"

        $webReq = [System.Net.WebRequest]::Create($Url)
        $webReq.Method = "POST"
        $webReq.ContentType = "application/json; charset=utf-8"
        $webReq.Headers.Add("x-hub-signature-256", $badSignature)
        $webReq.ContentLength = $bodyBytes.Length

        $stream = $webReq.GetRequestStream()
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Close()

        $status = 0
        try {
            $resp = $webReq.GetResponse()
            $status = [int]$resp.StatusCode
            $resp.Close()
        } catch [System.Net.WebException] {
            $ex = $_.Exception
            if ($ex.Response -ne $null) {
                $status = [int]$ex.Response.StatusCode
            }
        }

        if ($status -eq 401) {
            Write-Pass "post-invalid: HTTP $status (401 esperado)"
        } else {
            Write-Fail "post-invalid: HTTP $status (esperado 401)"
        }
    }
}
