# Troubleshooting GobboNet

> **Port defaults in the fixed launcher:** UI `8420`, llama.cpp `11437`, search proxy `11435`, embeddings `11436`. `11434` is deliberately left to Ollama. All four can be overridden with `GEMMA_LISTEN_PORT`, `GEMMA_LLM_PORT`, `GEMMA_SEARCH_PORT`, and `GEMMA_EMBED_PORT`.


Most problems land in one of four buckets. Work down in order — the first
one is far more common than people expect.

---

## The chat page will not load (nothing on the UI port, default :8420)

**Read the log first.** `fileserver.ps1` prints the exact reason it failed,
and as of 1.5.4 it writes that to `fileserver.log` in the install folder.
launch.bat prints the file for you when the server does not come up.

```
type "%LOCALAPPDATA%\GobboNet\fileserver.log"
```

That one file separates four failures that look identical from outside:

| What the log says | What it means |
|---|---|
| `[FATAL] No access secret provided` | Not a port problem at all — see *Password* below |
| `[fatal] cannot create System.Net.HttpListener` | PowerShell is in a restricted language mode (WDAC/AppLocker) |
| `[warn] could not bind ... [ok] listening on 127.0.0.1` | Working, but this PC only — run `setup-lan.bat` for phone access |
| `[fatal] could not bind ... either` | Port genuinely unavailable — checklist below |
| *(no log file at all)* | PowerShell never ran the script: AppLocker policy or antivirus quarantine |

### "netstat says nothing is using 8080"

That can be true and the port still unbindable. **netstat cannot see
Windows port reservations.** Hyper-V, WSL2, Docker Desktop and the Windows
NAT service reserve large dynamic TCP blocks, and 8080 lands inside one
often enough to be a leading suspect. Check with:

```
netsh interface ipv4 show excludedportrange protocol=tcp
```

If a range covers your configured UI port, either use a different port:

```
set GEMMA_LISTEN_PORT=8421
launch.bat
```

…or reserve 8080 back and **reboot**:

```
netsh int ipv4 add excludedportrange protocol=tcp startport=8080 numberofports=1
```

`setup-lan.bat` now checks this for you and says so.

### Other bind causes

```
netsh http show urlacl url=http://+:8420/     :: default; missing reservation? run setup-lan.bat as admin
netsh http show servicestate                  :: another service (IIS, VMware, Citrix) owning it?
```

Note that a missing URL ACL is no longer fatal — the server falls back to
`127.0.0.1` only. The chat works on this PC; phones will not reach it until
you run `setup-lan.bat` as Administrator.

---

## Password problems

The password lives in `.gobbonet-secret` as one line of `<hex>:<hex>` with
no trailing newline. If it is emptied, truncated or locked by antivirus,
the file server exits before it ever tries to listen — which looks exactly
like a port failure and sends people hunting the wrong thing.

To start over, delete it and relaunch:

```
del "%LOCALAPPDATA%\GobboNet\.gobbonet-secret"
```

If you see `.gobbonet-secret.bad`, a previous setup wrote something the
launcher could not parse. Its contents are kept for diagnosis; deleting it
is safe.

---

## The model will not load

The launcher stops and shows `llama-server.log`. Two common causes:

- **Not enough VRAM.** Pick a smaller model or a heavier quantisation.
- **Stale server.** Closing the window without stopping the servers can
  leave `llama-server.exe` holding the port. Check with
  `netstat -ano | findstr "11437 11435 11436 8420"` and end those PIDs.

If a model downloaded but never loads, check for a leftover `.part` file in
`models\` — that is an aborted download and is safe to delete.

---

## Windows or antivirus blocking things

The installer is unsigned, so SmartScreen shows "Windows protected your PC"
— **More info → Run anyway**. Separately, some antivirus engines quarantine
unsigned NSIS installers or the `.ps1` files outright rather than warning.

If `fileserver.log` is never created, that is the signature: PowerShell
never ran the script. Check your antivirus protection history, and add the
install folder to its exclusions.

---

## Linux / Wine

Not supported yet. `fileserver.ps1` **is** the web server, and with the
hardware probe and model identifier that is roughly 4,000 lines of
PowerShell, which Wine does not implement. The launcher detects Wine, says
so, and continues anyway — people have got it running by patching around
the gaps, and nothing here will stop you trying.

---

## Still stuck

Include these in a bug report and it can usually be answered in one reply:

1. `fileserver.log` (whole file)
2. Whether launch.bat printed **"No working PowerShell found"**
3. Whether it printed **`[OK] Search proxy on :<configured-port>`** — that line proves a
   PowerShell HTTP listener bound successfully minutes earlier, which rules
   out a whole class of theories
4. Output of `netsh interface ipv4 show excludedportrange protocol=tcp`
