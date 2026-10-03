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
repo1,C:\path\to\repo1,0,A
repo2,D:\work\repo2,1,E,*
```

- `AGENT_CMD`: command used by the `AI` button.
- `TENX_EXE`: path or command name for 10x editor executable.
- `FILEPILOT_EXE`: path or command name for FilePilot executable.
- `DIFF_EXE`: path or command name for diff executable.
- `[DIRS]`: one entry per line in `name,path,bg,text` format, where `bg` and `text` are single hex digits (`0`-`F`) for cmd background/text colors. Append `,*` to mark a row as active.
- Path-only lines are still accepted; the app auto-sets `name` from the folder name when loading/saving.
- If colors are omitted or invalid, ai_mux uses stable auto-generated defaults for that directory.

## UI actions per directory

- `AI`: opens `cmd` in that directory and runs `AGENT_CMD`.
- All launched `cmd` windows are auto-labeled as `<project-folder>` and use each row's configured per-project cmd color.
- Clicking `o` opens a per-project dialog with `bg color`, `text color`, and `remove`; color changes and remove are saved to `config.txt` immediately.
- Clicking `t` opens a tiny draggable titlecard window for that project name, using the row's configured cmd color.
- Clicking `*` toggles an active marker for that row: black/white when off, row color when on. This is saved in `config.txt` with a trailing `,*` on that line.
- The `o` button for each row is colored from that same cmd background/text combination so the row color matches the launched terminal color.
- `10x`: finds first `*.10x` recursively and opens it in 10x; if none, opens the directory in 10x.
- `Push` cell: type a commit message and press `Enter` to run `git add . && git commit -m "<message>" && git push`.
- `GitHub` (next to `Push`): `Create` appears for repository roots without a GitHub fetch or push remote. Click it to create a **private** repository in your signed-in GitHub account and push the current branch. Click the column header to refresh remote detection after changing remotes outside ai_mux.
- `Pull`: runs `git pull` in that folder; click the `Pull` column header to run pull for all rows.
- `misc`: deploys the project's current branch from GitHub over SSH to `phildo@phildogames.com:/var/www/phildogames/misc/<repository-name>`. Opens a terminal for SSH prompts and deployment output.
- `Diff`: opens the configured `DIFF_EXE` with that folder path as its argument.
- `Dirty` (`?` button): auto-checks on load in the background, and you can click `?` to refresh manually with `git status --porcelain`; green means clean, red means dirty.
- `Run`: runs `run.bat` in that folder (button is blank when no `run.bat` is present).
- `Dbg`: runs `debug.bat` in that folder (button is blank when no `debug.bat` is present).
- `Spcl`: runs `spcl.bat` in that folder (button is blank when no `spcl.bat` is present).
- `Build`: runs `build.bat` in that folder (`Build` button text).
- `Cmd`: opens plain `cmd` in that directory.
- `Folder`: opens that directory using `FILEPILOT_EXE`.

Use `Add Folder` to open the add-project dialog, then either `Add Project` (existing folder) or `New Project` (create folder + `git init` + add row). Use `o` for per-project settings, then `Save Config`.

For `New Project`, optionally check **Create private GitHub repository** to publish the new folder automatically. The checkbox defaults to off and applies only to `New Project`.

## GitHub setup

Install [GitHub CLI](https://cli.github.com), then run these once in a terminal:

```powershell
gh auth login --hostname github.com
gh auth setup-git --hostname github.com
```

Restart ai_mux after installing the CLI. GitHub CLI handles authentication; ai_mux does not store tokens in its config. Publishing uses GitHub's repository creation API with `private=true` and an HTTPS remote. Repository names come from the folder name, with characters other than letters, digits, `.`, `_`, and `-` replaced by `-`. Name collisions and authentication failures appear as errors; existing GitHub repositories are not reused or overwritten.

Publishing runs in the background. Existing repositories push the current committed branch; uncommitted changes remain local. Repositories without commits first stage files (respecting `.gitignore`) and create an `Initial commit`, which may be empty. Git's commit identity must be configured. Existing non-GitHub remotes are preserved: ai_mux uses `origin` if free, otherwise `github` (or a numbered variant), and sets the current branch's upstream to it.

Remote detection checks configured GitHub.com HTTPS, SSH, and Git URLs, including fetch and push URLs; it does not query whether the remote repository still exists. Custom SSH host aliases and GitHub Enterprise hosts are not detected. If creation succeeds but pushing fails, the error includes the repository URL and retry command. The local project is retained.

## misc deployment

Click `misc` to create a Git checkout on the server, or fast-forward an existing checkout. ai_mux fetches the latest branch from GitHub using **this PC's Git credentials**, packages it as a Git bundle, and streams it to the server over SSH. It deploys the current local branch's upstream branch when configured, otherwise the same branch name on GitHub. Remote selection prefers that branch's GitHub upstream, then GitHub `origin`, then a sole GitHub fetch remote. Ambiguous remotes and detached HEAD produce an error. Commit and push first: local edits and unpushed commits are not uploaded by this button. The local checkout stays on its current commit; the temporary fetch ref and bundle are removed afterward.

The destination uses the **GitHub repository name**, even if the local folder has a different name. For example, `owner/my-game` goes to `/var/www/phildogames/misc/my-game`, available at `http://phildogames.com/misc/my-game/`. Repositories with the same name under different owners conflict; deployment refuses to reuse a checkout belonging to another repository. This action checks out files only; it does not install dependencies or run builds.

No server `.sh` installation is needed: ai_mux sends its bundled `misc-deploy.sh` through SSH. Windows needs `ssh.exe` on PATH; Linux needs Bash, Git, `base64`, and `flock`. Test your login with `ssh phildo@phildogames.com`. The terminal supports passwords and SSH host-key confirmation.

The server does **not** need GitHub credentials, including for private repositories. Your PC must already be able to fetch the selected GitHub remote; use the GitHub setup above if necessary. Tokens and SSH private keys stay on your PC, and SSH agent forwarding is disabled. The server retains the GitHub URL as `origin`, but the button updates from the transferred bundle. Running `git pull` manually on the server would still require separate server-side GitHub authentication. Each deployment transfers the branch's complete reachable Git history, so large repositories may take longer. The server's temporary bundle is private and removed when the operation exits.

Deployment never lists `misc` or changes its permissions: mode `333` works with direct child paths. New repository directories are made web-readable after cloning; `.git` directories are restricted to phildo (`700`). Existing web-file permissions are retained. Updates stop on local server edits (including untracked files), unrelated destinations, symlinks, or commits that cannot be fast-forwarded. Concurrent deployments to the same repository are locked. A failed clone may leave a partial directory; inspect it on the server before removing it and retrying.

Mode `333` prevents directory listing but grants everyone write permission, including nginx if it runs under another user. If you only need phildo to write while everyone else can traverse known paths, owner `phildo` and mode `311` (`-wx--x--x`) provide that. The button leaves your current mode unchanged. Known paths remain publicly accessible, including any private-repository files checked out here; keep secrets out of deployed repositories.


