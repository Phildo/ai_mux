# GitHub operations shared by the UI's background workers and local tests.
function Invoke-ProjectCommand {
    param([string]$FileName, [string[]]$Arguments, [string]$Directory, [switch]$AllowFailure)

    # Quote individual argv values for Windows; never pass project data through a shell.
    $quoted = foreach ($argument in $Arguments) {
        '"' + (($argument -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FileName
    $info.Arguments = $quoted -join ' '
    $info.WorkingDirectory = $Directory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $info.EnvironmentVariables['GCM_INTERACTIVE'] = 'Never'
    $info.EnvironmentVariables['GH_PROMPT_DISABLED'] = '1'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) {
            $process.Kill()
            throw "$FileName timed out. Check the repository and network before retrying."
        }
        $result = [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result.Trim(); Error = $stderr.Result.Trim() }
        if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "$FileName failed (exit $($result.ExitCode)).`r`n$($result.Error)`r`n$($result.Output)"
        }
        return $result
    }
    finally { $process.Dispose() }
}

function Test-GitHubRemoteUrl {
    param([string]$Url)
    return $Url -match '^(?i)(?:[a-z][a-z0-9+.-]*://(?:[^/@]+@)?(?:github\.com|ssh\.github\.com)(?::\d+)?/|(?:[^/@:]+@)?github\.com:)[^/]+/[^/]+/?$'
}

function Get-ProjectGitHubState {
    param([string]$Directory)
    $root = Invoke-ProjectCommand git @('rev-parse', '--show-toplevel') $Directory -AllowFailure
    if ($root.ExitCode -ne 0) { throw 'This folder is not a Git working tree.' }
    $expected = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    if (-not [string]::Equals($expected, [IO.Path]::GetFullPath($root.Output).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'This folder is inside another repository. Add the repository root instead.'
    }
    $remotes = Invoke-ProjectCommand git @('remote', '-v') $Directory
    foreach ($line in ($remotes.Output -split '\r?\n')) {
        if ($line -match '^\S+\s+(\S+)\s+\((?:fetch|push)\)$' -and (Test-GitHubRemoteUrl $Matches[1])) {
            return 'Published'
        }
    }
    return 'Available'
}

function Publish-ProjectToGitHub {
    param([string]$Directory)
    if ((Get-ProjectGitHubState $Directory) -ne 'Available') {
        throw 'This repository already has a GitHub remote.'
    }
    if (-not (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Install GitHub CLI (https://cli.github.com), then run: gh auth login --hostname github.com; gh auth setup-git --hostname github.com. Restart ai_mux after installation.'
    }
    $auth = Invoke-ProjectCommand gh @('auth', 'status', '--hostname', 'github.com') $Directory -AllowFailure
    if ($auth.ExitCode -ne 0) { throw 'Sign in first: gh auth login --hostname github.com, then gh auth setup-git --hostname github.com.' }

    $name = [IO.Path]::GetFileName($Directory.TrimEnd('\', '/'))
    # Match GitHub's normalization of unsupported name characters.
    $name = $name -replace '[^a-zA-Z0-9_.-]', '-'
    if ($name -notmatch '[a-zA-Z0-9_-]' -or $name.Length -gt 100) { throw 'The folder name does not produce a valid GitHub repository name (maximum 100 characters).' }
    $branch = Invoke-ProjectCommand git @('symbolic-ref', '--quiet', '--short', 'HEAD') $Directory -AllowFailure
    if ($branch.ExitCode -ne 0) { throw 'Check out a branch before publishing (HEAD is detached).' }

    $head = Invoke-ProjectCommand git @('rev-parse', '--verify', 'HEAD') $Directory -AllowFailure
    if ($head.ExitCode -ne 0) {
        $null = Invoke-ProjectCommand git @('add', '--all') $Directory
        $null = Invoke-ProjectCommand git @('commit', '--allow-empty', '-m', 'Initial commit') $Directory
    }
    $remotes = (Invoke-ProjectCommand git @('remote') $Directory).Output -split '\r?\n'
    $remote = 'origin'
    if ($remotes -contains $remote) {
        $remote = 'github'
        $suffix = 2
        while ($remotes -contains $remote) { $remote = "github$suffix"; $suffix++ }
    }

    $url = $null
    try {
        $response = Invoke-ProjectCommand gh @('api', '--hostname', 'github.com', '--method', 'POST', 'user/repos', '-f', "name=$name", '-F', 'private=true') $Directory
        $repository = $response.Output | ConvertFrom-Json
        $url = [string]$repository.clone_url
        if ($repository.private -ne $true -or -not (Test-GitHubRemoteUrl $url)) { throw 'GitHub returned an unexpected repository response.' }
        $null = Invoke-ProjectCommand git @('remote', 'add', $remote, $url) $Directory
        # Store the target before pushing so a failed upload can be retried with git push.
        $null = Invoke-ProjectCommand git @('config', "branch.$($branch.Output).remote", $remote) $Directory
        $null = Invoke-ProjectCommand git @('config', "branch.$($branch.Output).merge", "refs/heads/$($branch.Output)") $Directory
        $null = Invoke-ProjectCommand git @('push', '--set-upstream', $remote, $branch.Output) $Directory
        return "Created private repository $url and pushed branch '$($branch.Output)'."
    }
    catch {
        if ($url) { throw "Repository created at $url, but publishing did not finish. Local files were kept. Check 'git remote -v', then retry with 'git push --set-upstream $remote $($branch.Output)'.`r`n$($_.Exception.Message)" }
        throw
    }
}
