# Deployment helpers. No local commits or pushes are performed by this action.
function Get-MiscRepository {
    param([string]$Directory)
    if ((Get-ProjectGitHubState $Directory) -ne 'Published') {
        throw 'This project needs a GitHub remote before it can be deployed.'
    }
    $branch = Invoke-ProjectCommand git @('symbolic-ref', '--quiet', '--short', 'HEAD') $Directory -AllowFailure
    if ($branch.ExitCode -ne 0) { throw 'Check out a branch before deploying (HEAD is detached).' }
    $remote = (Invoke-ProjectCommand git @('config', "branch.$($branch.Output).remote") $Directory -AllowFailure).Output
    $merge = (Invoke-ProjectCommand git @('config', "branch.$($branch.Output).merge") $Directory -AllowFailure).Output
    $lines = (Invoke-ProjectCommand git @('remote', '-v') $Directory).Output -split '\r?\n'
    $candidates = @(foreach ($line in $lines) {
        if ($line -match '^(\S+)\s+(\S+)\s+\(fetch\)$') {
            $remoteName = $Matches[1]
            $url = $Matches[2]
            if (Test-GitHubRemoteUrl $url) { [pscustomobject]@{ Remote = $remoteName; Url = $url } }
        }
    })
    $selected = @($candidates | Where-Object { $_.Remote -eq $remote })
    if ($selected.Count -eq 0) { $selected = @($candidates | Where-Object { $_.Remote -eq 'origin' }) }
    if ($selected.Count -eq 0 -and $candidates.Count -eq 1) { $selected = $candidates }
    if ($selected.Count -ne 1) { throw 'Cannot choose a GitHub fetch remote. Set this branch upstream to the desired GitHub remote, or use origin.' }
    $url = $selected[0].Url
    # Extract only validated GitHub path components; credentials and shell syntax never travel to the server.
    if ($url -notmatch '(?i)(?:github\.com[:/]|github\.com:\d+/)([a-z0-9-]+)/([a-z0-9_.-]+)/?$') {
        throw 'The GitHub remote has an unsupported owner or repository name.'
    }
    $owner = $Matches[1]
    $name = $Matches[2] -replace '\.git$', ''
    if ($name -in @('', '.', '..') -or $name.StartsWith('-')) { throw 'Unsupported GitHub repository name.' }
    $transport = if ($url -match '^(?i)(?:git@|ssh://)') { 'ssh' } else { 'https' }
    $deployBranch = $branch.Output
    if ($selected[0].Remote -eq $remote -and $merge.StartsWith('refs/heads/')) { $deployBranch = $merge.Substring(11) }
    $null = Invoke-ProjectCommand git @('check-ref-format', '--branch', $deployBranch) $Directory
    [pscustomobject]@{ Owner = $owner; Name = $name; Branch = $deployBranch; Transport = $transport; Remote = $selected[0].Remote }
}

function New-MiscBundle {
    param([string]$Directory, $Repository, [string]$Path)
    $ref = 'refs/ai_mux/misc/' + [guid]::NewGuid().ToString('N')
    try {
        # Fetch into an isolated ref: never bundle local edits or an unpushed local branch.
        $null = Invoke-ProjectCommand git @('fetch', '--no-tags', '--no-write-fetch-head', '--no-recurse-submodules', $Repository.Remote, "refs/heads/$($Repository.Branch):$ref") $Directory
        $null = Invoke-ProjectCommand git @('bundle', 'create', $Path, $ref) $Directory
        return $ref
    }
    finally { $null = Invoke-ProjectCommand git @('update-ref', '-d', $ref) $Directory }
}

function ConvertTo-MiscShellLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function New-MiscRemoteCommand {
    param($Repository, [string]$ScriptPath = (Join-Path $PSScriptRoot 'misc-deploy.sh'), [string]$BundleRef = '')
    $source = [IO.File]::ReadAllText($ScriptPath).Replace("`r`n", "`n")
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $arguments = @($Repository.Owner, $Repository.Name, $Repository.Branch, $Repository.Transport) |
        ForEach-Object { ConvertTo-MiscShellLiteral $_ }
    if ($BundleRef) { $arguments += ConvertTo-MiscShellLiteral $BundleRef }
    # Decode the script into bash -c so stdin can carry the binary Git bundle.
    return 'bash -c "$(printf %s ' + $payload + ' | base64 -d)" -- ' + ($arguments -join ' ')
}

function Invoke-MiscDeployment {
    param([string]$Directory)
    $repository = Get-MiscRepository $Directory
    $bundle = Join-Path ([IO.Path]::GetTempPath()) ('ai-mux-misc-' + [guid]::NewGuid() + '.bundle')
    $process = $null
    $stream = $null
    try {
        Write-Host 'Fetching the latest branch from GitHub using this PC''s credentials...'
        $bundleRef = New-MiscBundle $Directory $repository $bundle
        $command = New-MiscRemoteCommand $repository -BundleRef $bundleRef
        Write-Host "Deploying $($repository.Owner)/$($repository.Name), branch $($repository.Branch)"
        Write-Host "Destination: phildo@phildogames.com:/var/www/phildogames/misc/$($repository.Name)"
        $arguments = @('-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', '-o', 'ForwardAgent=no', 'phildo@phildogames.com', $command)
        $quoted = foreach ($argument in $arguments) {
            '"' + (($argument -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
        }
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = 'ssh.exe'
        $info.Arguments = $quoted -join ' '
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        [void]$process.Start()
        $stream = [IO.File]::OpenRead($bundle)
        $copyError = $null
        try { $stream.CopyTo($process.StandardInput.BaseStream) }
        catch { $copyError = $_ }
        finally { $process.StandardInput.Close() }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Deployment failed (SSH exit $($process.ExitCode)). See the output above." }
        if ($null -ne $copyError) { throw $copyError }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $process) { $process.Dispose() }
        if ([IO.File]::Exists($bundle)) { [IO.File]::Delete($bundle) }
    }
}

function Start-MiscInDirectory {
    param([string]$Directory)
    try {
        $helper = Join-Path $PSScriptRoot 'misc.ps1'
        $githubHelper = Join-Path $PSScriptRoot 'github.ps1'
        $code = @"
`$ErrorActionPreference = 'Stop'
try {
    . '$($githubHelper.Replace("'", "''"))'
    . '$($helper.Replace("'", "''"))'
    Invoke-MiscDeployment -Directory '$($Directory.Replace("'", "''"))'
} catch { Write-Host `$_.Exception.Message -ForegroundColor Red }
Read-Host 'Press Enter to close'
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        # This is an interactive terminal: users can answer SSH password/host-key prompts and read failures.
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -WindowStyle Normal | Out-Null
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'misc deployment', 'OK', 'Error') | Out-Null }
}
