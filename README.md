# ai_mux

Dead-simple native Windows GUI launcher for per-folder actions. No browser runtime, no third-party packages.

## Run

```powershell
powershell -ExecutionPolicy Bypass -File .\ai_mux.ps1
```

Or double-click:

- `run.vbs` for no console window
- `run.bat` (delegates to `run.vbs`)

## Config file

`config.txt` format:

```txt
# ai_mux config
AGENT_CMD=codex --yolo
TENX_EXE=10x.exe
FILEPILOT_EXE=FilePilot.exe
[DIRS]
C:\path\to\repo1
D:\work\repo2
```

- `AGENT_CMD`: command used by the `AI` button.
- `TENX_EXE`: path or command name for 10x editor executable.
- `FILEPILOT_EXE`: path or command name for FilePilot executable.
- `[DIRS]`: one directory per line.

## UI actions per directory

- `AI`: opens `cmd` in that directory and runs `AGENT_CMD`.
- `10x`: finds first `*.10x` recursively and opens it in 10x; if none, opens the directory in 10x.
- `Git`: opens `cmd` and runs `git add . && git commit -m "stuff"`.
- `Cmd`: opens plain `cmd` in that directory.
- `Folder`: opens that directory using `FILEPILOT_EXE`.

Use `Add Folder` and `Remove` in the UI, then `Save Config`.


