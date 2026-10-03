$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\github.ps1')
. (Join-Path $PSScriptRoot '..\misc.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
function Assert-Throws([scriptblock]$Action, $Pattern) {
    try { & $Action | Out-Null } catch {
        Assert ($_.Exception.Message -match $Pattern) "Expected $Pattern; got $_"
        return
    }
    throw "Expected failure: $Pattern"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ai-mux-misc-tests-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($temp)
function Git([string[]]$Arguments) { (Invoke-ProjectCommand git $Arguments $temp).Output }
try {
    $null = Git @('init', '-b', 'main')
    Assert-Throws { Get-MiscRepository $temp } 'GitHub remote'
    $null = Git @('remote', 'add', 'origin', 'https://github.com/owner/sample.git')
    $repo = Get-MiscRepository $temp
    Assert ($repo.Name -eq 'sample' -and $repo.Owner -eq 'owner' -and $repo.Branch -eq 'main' -and $repo.Transport -eq 'https') 'Origin selection'
    $null = Git @('remote', 'add', 'upstream', 'git@github.com:other/upstream.git')
    $null = Git @('config', 'branch.main.remote', 'upstream')
    $null = Git @('config', 'branch.main.merge', 'refs/heads/release')
    $repo = Get-MiscRepository $temp
    Assert ($repo.Owner -eq 'other' -and $repo.Name -eq 'upstream' -and $repo.Branch -eq 'release' -and $repo.Transport -eq 'ssh') 'Upstream preference and branch mapping'
    $null = Git @('remote', 'set-url', 'upstream', 'ssh://git@ssh.github.com:443/other/upstream.git')
    Assert ((Get-MiscRepository $temp).Name -eq 'upstream') 'SSH port URL'
    $null = Git @('config', '--unset', 'branch.main.remote')
    $null = Git @('remote', 'rename', 'origin', 'mirror')
    Assert-Throws { Get-MiscRepository $temp } 'Cannot choose'
    $null = Git @('remote', 'remove', 'mirror')
    Assert ((Get-MiscRepository $temp).Name -eq 'upstream') 'Sole remote fallback'
    $null = Git @('remote', 'set-url', 'upstream', 'https://github.com/owner/..')
    Assert-Throws { Get-MiscRepository $temp } 'Unsupported GitHub'
    $null = Git @('remote', 'set-url', 'upstream', 'https://github.com/owner/sample.git')
    $null = Git @('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'test')
    $null = Git @('checkout', '--detach')
    Assert-Throws { Get-MiscRepository $temp } 'detached'
    # Bundle only the remote branch, even with unpushed commits and edits in the local checkout.
    $remotePath = Join-Path $temp 'remote.git'
    $null = Git @('init', '--bare', $remotePath)
    $null = Git @('remote', 'add', 'bundle-test', $remotePath)
    $null = Git @('push', 'bundle-test', 'HEAD:refs/heads/main')
    $published = Git @('rev-parse', 'HEAD')
    $null = Git @('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'local only')
    $localHead = Git @('rev-parse', 'HEAD')
    $localFile = Join-Path $temp 'local-only.txt'
    [IO.File]::WriteAllText($localFile, 'keep this local')
    $bundle = Join-Path $temp 'test.bundle'
    $bundleRepo = [pscustomobject]@{ Remote = 'bundle-test'; Branch = 'main' }
    $bundleRef = New-MiscBundle $temp $bundleRepo $bundle
    Assert ((Git @('bundle', 'list-heads', $bundle)) -eq "$published $bundleRef") 'Bundle contains the published commit, not the unpushed commit'
    Assert ((Git @('for-each-ref', 'refs/ai_mux/misc/')) -eq '') 'Temporary fetch ref removed'
    Assert ((Git @('rev-parse', 'HEAD')) -eq $localHead) 'Local HEAD preserved'
    Assert ([IO.File]::ReadAllText($localFile) -eq 'keep this local') 'Uncommitted file preserved'
    $bundleRepo.Branch = 'missing'
    Assert-Throws { New-MiscBundle $temp $bundleRepo (Join-Path $temp 'missing.bundle') } 'failed'
    Assert ((Git @('for-each-ref', 'refs/ai_mux/misc/')) -eq '') 'Temporary ref removed on fetch failure'
    # Exercise the generated SSH shell command locally using Git for Windows Bash.
    $gitRoot = Split-Path (Split-Path (Get-Command git -CommandType Application).Source -Parent) -Parent
    $bash = Join-Path $gitRoot 'bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash)) { throw 'Git for Windows Bash is required for the shell-quoting test.' }
    $probe = Join-Path $temp 'probe.sh'
    [IO.File]::WriteAllText($probe, 'printf ''%s\n'' "$@"')
    $repo = [pscustomobject]@{ Owner = 'owner'; Name = 'sample'; Branch = 'feature/quote''$(printf_PROBE);test'; Transport = 'https' }
    $command = New-MiscRemoteCommand $repo -ScriptPath $probe
    $result = Invoke-ProjectCommand $bash @('-c', $command) $temp
    Assert ($result.Output.Replace("`r`n", "`n") -ceq (@($repo.Owner, $repo.Name, $repo.Branch, $repo.Transport) -join "`n")) 'Literal shell arguments roundtrip through generated command'
    $command = New-MiscRemoteCommand $repo -ScriptPath $probe -BundleRef $bundleRef
    $result = Invoke-ProjectCommand $bash @('-c', $command) $temp
    Assert ($result.Output.Replace("`r`n", "`n") -ceq (@($repo.Owner, $repo.Name, $repo.Branch, $repo.Transport, $bundleRef) -join "`n")) 'Bundle ref reaches the server as a separate argument'
    Write-Output 'PASS: misc repository selection, bundle excludes unpushed changes, local state preserved, temporary ref cleanup, and shell quoting.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ai-mux-misc-tests-'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
