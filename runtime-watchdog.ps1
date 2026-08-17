# ==============================================================================
# runtime-watchdog.ps1 -- clean up background services owned by one launch.bat
#
# launch.bat starts services detached so they can keep serving while its console
# is minimized. This watchdog gives those processes an explicit lifetime: when
# the dedicated launcher cmd.exe exits, stop only processes that this invocation
# marked as owned in its small runtime-state file.
# ==============================================================================

$ErrorActionPreference = 'SilentlyContinue'
function Env([string]$Name, $Default = '') {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}

$ParentPid = [int](Env 'GOBBONET_PARENT_PID' '0')
$StateFile = Env 'GOBBONET_RUNTIME_STATE'
$Root      = [IO.Path]::GetFullPath((Env 'GOBBONET_ROOT' (Split-Path -Parent $MyInvocation.MyCommand.Path))).TrimEnd('\')
$LlmPort   = [int](Env 'GOBBONET_LLM_PORT' '11437')
$EmbedPort = [int](Env 'GOBBONET_EMBED_PORT' '11436')
$SearchPort= [int](Env 'GOBBONET_SEARCH_PORT' '11435')
$WebPort   = [int](Env 'GOBBONET_WEB_PORT' '8420')
$LogFile   = Join-Path $Root 'runtime-watchdog.log'

function Log([string]$Text) {
    try { Add-Content -LiteralPath $LogFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -Encoding UTF8 } catch { }
}
function Parent-Alive {
    if ($ParentPid -le 0) { return $false }
    return $null -ne (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)
}
function Read-Ownership {
    $o = @{ LLM=$false; EMBED=$false; SEARCH=$false; WEB=$false }
    if (-not $StateFile -or -not (Test-Path -LiteralPath $StateFile)) { return $o }
    foreach ($line in (Get-Content -LiteralPath $StateFile -ErrorAction SilentlyContinue)) {
        if ($line -match '^OWN_(LLM|EMBED|SEARCH|WEB)=(1|0)$') {
            $o[$Matches[1]] = ($Matches[2] -eq '1')
        }
    }
    return $o
}
function Has-PortArg([string]$Cmd, [int]$Port) {
    if ([string]::IsNullOrWhiteSpace($Cmd)) { return $false }
    return $Cmd -match ('(?i)(?:--port\s+|--port=)' + [regex]::Escape([string]$Port) + '(?:\s|$)')
}
function In-Root([string]$Cmd) {
    if ([string]::IsNullOrWhiteSpace($Cmd)) { return $false }
    return $Cmd.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

if ($ParentPid -le 0) { exit 0 }
Log ("watching launcher pid={0}; llm={1} embed={2} search={3} web={4}" -f $ParentPid,$LlmPort,$EmbedPort,$SearchPort,$WebPort)
while (Parent-Alive) { Start-Sleep -Seconds 2 }

$own = Read-Ownership
Log ("launcher exited; ownership llm={0} embed={1} search={2} web={3}" -f $own.LLM,$own.EMBED,$own.SEARCH,$own.WEB)

# Query command lines once so cleanup is based on service identity + project
# root, never on a port alone. That prevents killing Ollama or another app.
$procs = @(Get-CimInstance Win32_Process)
foreach ($p in $procs) {
    $name = ([string]$p.Name).ToLowerInvariant()
    $cmd  = [string]$p.CommandLine
    if (-not (In-Root $cmd)) { continue }

    $kill = $false
    if ($name -eq 'llama-server.exe') {
        if ($own.LLM   -and (Has-PortArg $cmd $LlmPort))   { $kill = $true }
        if ($own.EMBED -and (Has-PortArg $cmd $EmbedPort)) { $kill = $true }
    }
    elseif ($name -in @('powershell.exe','pwsh.exe')) {
        if ($own.SEARCH -and $cmd -match '(?i)searchproxy\.ps1') { $kill = $true }
        if ($own.WEB    -and $cmd -match '(?i)fileserver\.ps1')  { $kill = $true }
    }
    elseif ($name -eq 'cmd.exe') {
        if ($own.LLM   -and $cmd -match '(?i)\.llama-launch\.cmd') { $kill = $true }
        if ($own.EMBED -and $cmd -match '(?i)\.embed-launch\.cmd') { $kill = $true }
    }

    if ($kill) {
        try {
            Log ("stopping pid={0} name={1}" -f $p.ProcessId,$p.Name)
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        } catch { }
    }
}

if ($StateFile) { Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue }
Log 'cleanup complete'
