# GobboNet port / lifecycle fixes

This patch is based on the supplied GobboNet archive from 2026-08-17.
It intentionally does **not** include models, `llama-cpp` binaries, secrets,
or generated runtime files.

## New default ports

| Service | Default |
|---|---:|
| GobboNet web UI / file server | `8420` |
| llama.cpp chat server | `11437` |
| optional web-search proxy | `11435` |
| embedding llama-server | `11436` |
| Ollama | left untouched on its normal `11434` |

All GobboNet ports remain configurable:

- `GEMMA_LISTEN_PORT` — web UI/file server
- `GEMMA_LLM_PORT` — main llama.cpp server
- `GEMMA_SEARCH_PORT` — search proxy
- `GEMMA_EMBED_PORT` — embedding server

## Fixed bugs

1. `launch.bat` no longer opens or prints `:8080` after the UI was actually
   started on another `GEMMA_LISTEN_PORT`.
2. `11434` is no longer GobboNet's default LLM port, avoiding the standard
   Ollama listener.
3. HTTP `404`, `500`, and `503` responses are no longer treated as a healthy
   service. Health checks now require a successful HTTP response.
4. The file server and search proxy expose GobboNet-specific health markers,
   so Apache/IIS/EDB/another HTTP service cannot be mistaken for GobboNet.
5. Search proxy source is now `searchproxy.ps1` instead of an opaque Base64
   `-EncodedCommand`; `GEMMA_SEARCH_PORT` is therefore real, not cosmetic.
6. Search-proxy startup errors are written to `search-proxy.log`.
7. `runtime-watchdog.ps1` cleans up background services started by the current
   launcher when its dedicated launcher process exits.
8. `cmd /k` was replaced with a dedicated `cmd /c` lifecycle boundary, so
   Ctrl+C can actually end the launcher instance the watchdog is following.
9. Cleanup is ownership-aware and project-root-aware; it does not kill Ollama
   or a compatible server that existed before this launch.
10. Main-server restart no longer uses `taskkill /im llama-server.exe`.
    It targets only the llama-server with the main LLM `--port`, so the
    embedding llama-server and unrelated llama.cpp instances survive.
11. Hot-swap cleanup in `fileserver.ps1` is likewise limited to the configured
    main LLM port instead of killing every `llama-server.exe` process.
12. GPU verification does not trust an old `llama-server.log` when the launcher
    merely discovered a pre-existing server.
13. `setup-lan.bat` uses the same configurable/default ports as `launch.bat`.
14. Direct `file://` fallback now points to the new default LLM port `11437`.

## Install

Extract this ZIP directly over the GobboNet installation directory and allow
Windows to replace the existing files. The two new PowerShell files must sit
next to `launch.bat` and `fileserver.ps1`.

If you use GobboNet from another device on your LAN, run the **new**
`setup-lan.bat` once as Administrator because the default UI port changed from
8080 to 8420.

No environment overrides are needed for the normal layout; simply run:

```powershell
.\launch.bat
```

## Applying to a fork

The ZIP also contains `GobboNet-port-lifecycle-fixes.patch`. From the root of
a fork that matches the supplied 2026-08-17 source snapshot, you can apply it
with:

```bash
git switch -c fix/windows-port-lifecycle
git apply --whitespace=nowarn GobboNet-port-lifecycle-fixes.patch
git status
```

If upstream changed the same sections since this archive was built, Git may
report rejected/context-mismatched hunks. In that case use the replacement
files in the ZIP as the reference rather than forcing a patch onto newer code.

Expected layout with Ollama running:

```text
8420   GobboNet UI
11434  Ollama
11435  GobboNet search proxy
11436  GobboNet embeddings
11437  GobboNet llama.cpp chat server
```

Useful checks while GobboNet is running:

```powershell
curl.exe http://127.0.0.1:8420/health-fileserver
curl.exe http://127.0.0.1:11435/health
curl.exe http://127.0.0.1:11437/health
```

After stopping GobboNet and giving the watchdog a couple of seconds, this
should normally show only Ollama on `11434` (assuming Ollama itself is running):

```powershell
Get-NetTCPConnection -State Listen |
    Where-Object LocalPort -in 8420,11434,11435,11436,11437 |
    Sort-Object LocalPort |
    Select-Object LocalAddress, LocalPort, OwningProcess,
        @{N='Process';E={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName}}
```

## Validation note

The JavaScript files were syntax-checked with Node. The Windows-specific
`.bat`/Windows PowerShell runtime cannot be executed in the packaging
environment, so the first real integration test should be done on Windows.
