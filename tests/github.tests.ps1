$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\github.ps1')

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Assert ($_.Exception.Message -match $Pattern) "Expected '$Pattern', got '$($_.Exception.Message)'"
        return
    }
    throw "Expected failure matching '$Pattern'"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ai-mux-github-tests-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($testRoot)
$realCommand = ${function:Invoke-ProjectCommand}
$script:ghMode = 'Success'
$script:apiCalls = 0
$script:pushCalls = 0
$script:cliAvailable = $true

# Only GitHub is mocked. Git repositories, commits, remotes and pushes are real,
# with pushInsteadOf routing uploads to a temporary local bare repository.
function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    if ($Name -eq 'gh' -and $script:cliAvailable) { return [pscustomobject]@{ Name = 'gh.exe' } }
}
function Invoke-ProjectCommand {
    param([string]$FileName, [string[]]$Arguments, [string]$Directory, [switch]$AllowFailure)
    if ($FileName -eq 'gh') {
        if ($Arguments[0] -eq 'auth') {
            return [pscustomobject]@{ ExitCode = $(if ($script:ghMode -eq 'AuthFailure') { 1 } else { 0 }); Output = ''; Error = '' }
        }
        $script:apiCalls++
        Assert (($Arguments -join '|') -match 'POST\|user/repos') 'Create uses authenticated user endpoint'
        Assert ($Arguments -contains 'private=true') 'Repository must be private'
        Assert ($Arguments -contains 'github.com') 'Host is explicitly github.com'
        if ($script:ghMode -eq 'Collision') { throw 'Repository name already exists' }
        $script:lastName = ($Arguments | Where-Object { $_ -like 'name=*' }).Substring(5)
        $url = "https://github.com/test-account/$script:lastName.git"
        $script:bare = Join-Path $testRoot ('remote-' + $script:apiCalls + '.git')
        $null = & $realCommand git @('init', '--bare', $script:bare) $testRoot
        $pushPath = $script:bare.Replace('\', '/')
        $null = & $realCommand git @('config', "url.$pushPath.pushInsteadOf", $url) $Directory
        return [pscustomobject]@{ ExitCode = 0; Output = (@{ private = $true; clone_url = $url } | ConvertTo-Json); Error = '' }
    }
    if ($Arguments[0] -eq 'push') {
        $script:pushCalls++
        if ($script:ghMode -eq 'PushFailure') { throw 'Simulated upload failure' }
    }
    return & $realCommand $FileName $Arguments $Directory -AllowFailure:$AllowFailure
}
function New-TestRepository([string]$Name) {
    $path = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($path)
    $null = & $realCommand git @('init', '--initial-branch=main') $path
    $null = & $realCommand git @('config', 'user.name', 'Test User') $path
    $null = & $realCommand git @('config', 'user.email', 'test@example.invalid') $path
    $null = & $realCommand git @('config', 'commit.gpgsign', 'false') $path
    return $path
}

try {
    foreach ($url in @('https://github.com/owner/repo.git', 'git@github.com:owner/repo.git', 'ssh://git@github.com/owner/repo', 'ssh://git@ssh.github.com:443/owner/repo', 'git://github.com/owner/repo', 'https://user@GITHUB.COM/owner/repo')) {
        Assert (Test-GitHubRemoteUrl $url) "Recognize $url"
    }
    foreach ($url in @('https://github.com.evil.test/owner/repo', 'https://example.com/github.com/owner/repo', 'C:\github.com\owner\repo', 'https://github.com@evil.test/owner/repo')) {
        Assert (-not (Test-GitHubRemoteUrl $url)) "Reject $url"
    }
    $empty = New-TestRepository 'empty'
    Assert ((Get-ProjectGitHubState $empty) -eq 'Available') 'Empty repo can be published'
    $message = Publish-ProjectToGitHub $empty
    Assert ($message -match 'Created private repository') 'Success reported'
    Assert ((Get-ProjectGitHubState $empty) -eq 'Published') 'New remote detected'
    Assert ((& $realCommand git @('rev-list', '--count', 'main') $script:bare).Output -eq '1') 'Empty initial commit pushed'
    Assert ((& $realCommand git @('config', 'branch.main.remote') $empty).Output -eq 'origin') 'Upstream set'
    $calls = $script:apiCalls
    Assert-Throws { Publish-ProjectToGitHub $empty } 'already has a GitHub remote'
    Assert ($script:apiCalls -eq $calls) 'No duplicate create'

    $files = New-TestRepository 'spaces & $dollars `ticks'
    [IO.File]::WriteAllText((Join-Path $files '.gitignore'), "ignored.txt`n")
    [IO.File]::WriteAllText((Join-Path $files 'ignored.txt'), 'local')
    [IO.File]::WriteAllText((Join-Path $files 'hello.txt'), 'hello')
    $null = Publish-ProjectToGitHub $files
    Assert ($script:lastName -eq 'spaces----dollars--ticks') 'Folder name normalized'
    $tree = (& $realCommand git @('ls-tree', '--name-only', 'main') $script:bare).Output
    Assert ($tree -match 'hello.txt' -and $tree -notmatch 'ignored.txt') 'Initial files respect gitignore'

    $existing = New-TestRepository 'existing'
    $null = & $realCommand git @('commit', '--allow-empty', '-m', 'Existing commit') $existing
    [IO.File]::WriteAllText((Join-Path $existing 'uncommitted.txt'), 'keep local')
    $null = & $realCommand git @('remote', 'add', 'origin', 'https://example.invalid/owner/repo') $existing
    $null = & $realCommand git @('remote', 'add', 'github', 'https://example.invalid/owner/another') $existing
    $null = Publish-ProjectToGitHub $existing
    Assert ((& $realCommand git @('remote', 'get-url', 'origin') $existing).Output -eq 'https://example.invalid/owner/repo') 'Existing origin preserved'
    Assert ((& $realCommand git @('config', 'branch.main.remote') $existing).Output -eq 'github2') 'Free remote selected'
    Assert ((& $realCommand git @('status', '--porcelain') $existing).Output -match 'uncommitted.txt') 'Dirty changes stay local'

    $pushOnly = New-TestRepository 'push-only'
    $null = & $realCommand git @('remote', 'add', 'other', 'https://example.invalid/owner/repo') $pushOnly
    $null = & $realCommand git @('remote', 'set-url', '--push', 'other', 'git@github.com:owner/repo.git') $pushOnly
    Assert ((Get-ProjectGitHubState $pushOnly) -eq 'Published') 'GitHub push URL detected on non-origin remote'
    $child = Join-Path $pushOnly 'child'
    [void][IO.Directory]::CreateDirectory($child)
    Assert-Throws { Get-ProjectGitHubState $child } 'inside another repository'
    Assert-Throws { Get-ProjectGitHubState $testRoot } 'not a Git working tree'

    $failure = New-TestRepository 'failure'
    $script:cliAvailable = $false
    Assert-Throws { Publish-ProjectToGitHub $failure } 'Install GitHub CLI'
    $script:cliAvailable = $true
    $script:ghMode = 'AuthFailure'
    Assert-Throws { Publish-ProjectToGitHub $failure } 'Sign in first'
    Assert ((& $realCommand git @('rev-parse', '--verify', 'HEAD') $failure -AllowFailure).ExitCode -ne 0) 'Auth failure does not commit'
    $script:ghMode = 'Collision'
    Assert-Throws { Publish-ProjectToGitHub $failure } 'name already exists'
    Assert ([string]::IsNullOrWhiteSpace((& $realCommand git @('remote') $failure).Output)) 'Collision leaves remotes alone'
    $script:ghMode = 'PushFailure'
    Assert-Throws { Publish-ProjectToGitHub $failure } 'Repository created at .*git push --set-upstream origin main'
    Assert ((Get-ProjectGitHubState $failure) -eq 'Published') 'Failed push keeps created remote'
    $script:ghMode = 'Success'
    $null = & $realCommand git @('push') $failure
    Assert ((& $realCommand git @('rev-list', '--count', 'main') $script:bare).Output -eq '1') 'Plain push retries successfully'

    $detached = New-TestRepository 'detached'
    $null = & $realCommand git @('commit', '--allow-empty', '-m', 'Existing commit') $detached
    $null = & $realCommand git @('checkout', '--detach') $detached
    Assert-Throws { Publish-ProjectToGitHub $detached } 'HEAD is detached'
    Write-Output 'PASS: GitHub detection, private creation, real local pushes, initial commits, remote preservation, quoting, and failures.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ai-mux-github-tests-'
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
