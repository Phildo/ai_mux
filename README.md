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
DIFF_EXE=diff.exe
[DIRS]
repo1,C:\path\to\repo1
repo2,D:\work\repo2
```

- `AGENT_CMD`: command used by the `AI` button.
- `TENX_EXE`: path or command name for 10x editor executable.
- `FILEPILOT_EXE`: path or command name for FilePilot executable.
- `DIFF_EXE`: path or command name for diff executable.
- `[DIRS]`: one entry per line in `name,path` format.
- Path-only lines are still accepted; the app auto-sets `name` from the folder name when loading/saving.

## UI actions per directory

- `AI`: opens `cmd` in that directory and runs `AGENT_CMD`.
- `10x`: finds first `*.10x` recursively and opens it in 10x; if none, opens the directory in 10x.
- `Git` cell: type a commit message and press `Enter` to run `git add . && git commit -m "<message>" && git pull`.
- `Diff`: opens the configured `DIFF_EXE` with that folder path as its argument.
- `Dirty` (`?` button): runs `git status --porcelain`; green means clean working tree, red means dirty. Running `Git` from Enter marks this as green.
- `Exe`: runs `run.bat` in that folder (button is blank when no `run.bat` is present).
- `Build`: runs `buildrelease.bat` in that folder (`Build` button text).
- `Cmd`: opens plain `cmd` in that directory.
- `Folder`: opens that directory using `FILEPILOT_EXE`.

Use `Add Folder` and `x` in the UI, then `Save Config`.


