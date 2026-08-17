# ==============================================================================
# searchproxy.ps1 -- loopback-only relay for the optional Ollama web-search API
#
# Config:
#   GEMMA_SEARCH_PORT   default 11435
#   GEMMA_ROOT          project root (for search-proxy.log)
#
# This used to live as an opaque Base64-encoded -EncodedCommand in launch.bat,
# which also hard-coded 11435 inside the payload. Keeping it as source makes the
# port truly configurable and gives startup/runtime errors a normal log file.
# ==============================================================================

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-EnvOrDefault {
    param([string]$Name, $Default)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}

$Root = Get-EnvOrDefault 'GEMMA_ROOT' (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Port = [int](Get-EnvOrDefault 'GEMMA_SEARCH_PORT' '11435')
$Log  = Join-Path $Root 'search-proxy.log'

function Log([string]$Message) {
    $line = ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message)
    try { Add-Content -LiteralPath $Log -Value $line -Encoding UTF8 } catch { }
}
function Write-Bytes($Response, [int]$Status, [string]$ContentType, [byte[]]$Bytes) {
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Bytes.Length
    if ($Bytes.Length -gt 0) { $Response.OutputStream.Write($Bytes, 0, $Bytes.Length) }
}
function Write-Text($Response, [int]$Status, [string]$ContentType, [string]$Text) {
    Write-Bytes $Response $Status $ContentType ([Text.Encoding]::UTF8.GetBytes($Text))
}
function Escape-Json([string]$Text) {
    if ($null -eq $Text) { return '' }
    return ($Text -replace '\\','\\\\' -replace '"','\\"' -replace "`r",'' -replace "`n",' ')
}

try { Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue } catch { }
$listener = New-Object System.Net.HttpListener
$prefix = 'http://127.0.0.1:{0}/' -f $Port
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
    Log ("search proxy listening on {0}" -f $prefix)
} catch {
    Log ("FATAL: could not bind {0}: {1}" -f $prefix, $_.Exception.Message)
    exit 1
}

while ($listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }
    $req = $ctx.Request
    $res = $ctx.Response
    try {
        $res.AddHeader('Access-Control-Allow-Origin', '*')
        $res.AddHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        $res.AddHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization')
        $res.AddHeader('Cache-Control', 'no-store')

        if ($req.HttpMethod -eq 'OPTIONS') {
            $res.StatusCode = 204
            continue
        }

        $path = $req.Url.AbsolutePath
        if ($path -eq '/health') {
            Write-Text $res 200 'application/json; charset=utf-8' '{"status":"ok","service":"gobbonet-search-proxy"}'
            continue
        }

        if ($req.HttpMethod -ne 'POST') {
            Write-Text $res 405 'application/json; charset=utf-8' '{"error":"POST only"}'
            continue
        }

        $reader = New-Object IO.StreamReader($req.InputStream, $req.ContentEncoding)
        try { $body = $reader.ReadToEnd() } finally { $reader.Close() }

        $targetUrl = 'https://ollama.com/api' + $path
        $headers = @{}
        $auth = [string]$req.Headers['Authorization']
        if (-not [string]::IsNullOrWhiteSpace($auth)) { $headers['Authorization'] = $auth }

        try {
            $wr = Invoke-WebRequest -Uri $targetUrl -Method POST -Body $body `
                    -ContentType 'application/json' -Headers $headers `
                    -UseBasicParsing -TimeoutSec 30
            $contentType = if ($wr.Headers['Content-Type']) { [string]$wr.Headers['Content-Type'] } else { 'application/json; charset=utf-8' }
            Write-Text $res ([int]$wr.StatusCode) $contentType ([string]$wr.Content)
        } catch [System.Net.WebException] {
            # Preserve real upstream HTTP errors (401/403/429/etc.) instead of
            # converting every API-key problem into a misleading local 502.
            $up = $_.Exception.Response
            if ($null -ne $up) {
                $status = [int]$up.StatusCode
                $contentType = if ($up.ContentType) { [string]$up.ContentType } else { 'application/json; charset=utf-8' }
                $sr = New-Object IO.StreamReader($up.GetResponseStream())
                try { $text = $sr.ReadToEnd() } finally { $sr.Close(); $up.Close() }
                Write-Text $res $status $contentType $text
            } else {
                $msg = Escape-Json $_.Exception.Message
                Write-Text $res 502 'application/json; charset=utf-8' ('{"error":"proxy: ' + $msg + '"}')
            }
        } catch {
            $msg = Escape-Json $_.Exception.Message
            Write-Text $res 502 'application/json; charset=utf-8' ('{"error":"proxy: ' + $msg + '"}')
        }
    } catch {
        Log ("request error: {0}" -f $_.Exception.Message)
        try {
            $msg = Escape-Json $_.Exception.Message
            Write-Text $res 500 'application/json; charset=utf-8' ('{"error":"search proxy failure: ' + $msg + '"}')
        } catch { }
    } finally {
        try { $res.Close() } catch { }
    }
}

try { $listener.Close() } catch { }
Log 'search proxy stopped'
