$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ai-mux-ui-tests-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($testRoot)
$config = Join-Path $testRoot 'config.txt'
$localRepo = Join-Path $testRoot 'local'
[void][IO.Directory]::CreateDirectory($localRepo)
& git -C $localRepo init --quiet
if ($LASTEXITCODE -ne 0) { throw 'Test git init failed' }
[IO.File]::WriteAllText($config, "[DIRS]`r`nlocal,$localRepo,0,A`r`n")
$source = [IO.File]::ReadAllText((Join-Path $projectRoot 'ai_mux.ps1'))
$source = $source.Replace("Join-Path `$PSScriptRoot 'github.ps1'", "'$($projectRoot.Replace("'", "''"))\github.ps1'")
$source = $source.Replace("Join-Path `$PSScriptRoot 'misc.ps1'", "'$($projectRoot.Replace("'", "''"))\misc.ps1'")
$source = $source.Replace('[void]$form.ShowDialog()', '')
$checks = @'
function Assert-Ui($Condition, $Message) {
    if (-not $Condition) { throw "UI assertion failed: $Message" }
}
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($script:GitHubJobs.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
    Assert-Ui ($script:GitHubJobs.Count -eq 0) 'Background worker completes'
    $row = $grid.Rows[0]
    Assert-Ui ($row.Cells['GitHub'].Value -eq 'Create') 'Local repo gets Create'
    Assert-Ui ($row.Cells['GitHub'] -is [System.Windows.Forms.DataGridViewButtonCell]) 'Create is a button'
    Assert-Ui ($grid.Columns['GitHub'].DisplayIndex -eq $grid.Columns['Message'].DisplayIndex + 1) 'GitHub next to Push'
    Assert-Ui ($grid.Columns['misc'].Text -eq 'misc') 'misc button label'
    Assert-Ui ($grid.Columns['misc'].DisplayIndex -eq $grid.Columns['GitHub'].DisplayIndex + 1) 'misc next to GitHub'
    $directory = [string]$row.Cells['Directory'].Value
    Set-GitHubCells $grid $directory 'Publishing'
    Assert-Ui ($row.Cells['GitHub'] -is [System.Windows.Forms.DataGridViewTextBoxCell]) 'Busy cell cannot publish again'
    Assert-Ui ($row.Cells['GitHub'].Value -eq '...') 'Busy indicator'
    Set-GitHubCells $grid $directory 'Published'
    Assert-Ui ($row.Cells['GitHub'].Value -eq '') 'Published cell blank'
    Assert-Ui ($row.Cells['GitHub'] -is [System.Windows.Forms.DataGridViewTextBoxCell]) 'Published has no button'
    & git -C $directory remote add mirror git@github.com:owner/test.git
    Start-GitHubRefreshForGrid $grid
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($script:GitHubJobs.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
    Assert-Ui ($row.Cells['GitHub'].Tag -eq 'Published') 'Refresh detects external remote change'
    Assert-Ui (Test-IsAddProjectRow $grid.Rows[$grid.Rows.Count - 1]) 'Add row remains intact'

    # Exercise the new-project handler without displaying a dialog or contacting GitHub.
    $script:publishRequests = @()
    function Start-GitHubWork {
        param($Grid, [string]$Directory, [switch]$Publish)
        if ($Publish) { $script:publishRequests += $Directory }
    }
    $dialogSource = ${function:Show-ProjectAddCellDialog}.ToString()
    $dialogSource = $dialogSource.Replace('$btnNewProject.Add_Click({', '$newProjectHandler = {')
    $dialogSource = $dialogSource -replace '\}\)\s+\$dialog.AcceptButton', "}`n    `$dialog.AcceptButton"
    $dialogSource = $dialogSource.Substring(0, $dialogSource.IndexOf('    $owner = $Grid.FindForm()'))
    $dialogSource += @"
    Assert-Ui (-not `$chkGitHub.Checked) 'Checkbox defaults off'
    `$txtPath.Text = Split-Path '$($directory.Replace("'", "''"))' -Parent
    `$txtName.Text = if (`$script:testPublishChecked) { 'new-private' } else { 'new-local' }
    `$chkGitHub.Checked = `$script:testPublishChecked
    & `$newProjectHandler
    `$dialog.Dispose()
"@
    $dialogTest = [scriptblock]::Create($dialogSource)
    $script:testPublishChecked = $false
    & $dialogTest -Grid $grid -ConfigPath $ConfigPath
    Assert-Ui ($script:publishRequests.Count -eq 0) 'Unchecked creates only local project'
    $newLocal = Join-Path (Split-Path $directory -Parent) 'new-local'
    Assert-Ui (Test-Path -LiteralPath (Join-Path $newLocal '.git')) 'Unchecked project initialized'
    $script:testPublishChecked = $true
    & $dialogTest -Grid $grid -ConfigPath $ConfigPath
    $newPrivate = Join-Path (Split-Path $directory -Parent) 'new-private'
    Assert-Ui ($script:publishRequests.Count -eq 1 -and $script:publishRequests[0] -eq $newPrivate) 'Checked dispatches publishing for the new folder'
    Assert-Ui (Test-Path -LiteralPath (Join-Path $newPrivate '.git')) 'Checked project initialized'
    Assert-Ui ((Get-Content -LiteralPath $ConfigPath -Raw) -match 'new-private') 'Project saved before publishing'
    Write-Output 'PASS: Windows Forms, background workers, availability, column order, remote refresh, and checked/unchecked new-project flow.'
}
finally {
    if ($null -ne $script:GitHubTimer) { $script:GitHubTimer.Stop(); $script:GitHubTimer.Dispose() }
    foreach ($job in $script:GitHubJobs.ToArray()) { $job.Worker.Stop(); $job.Worker.Dispose() }
    if ($null -ne $script:GitHubPool) { $script:GitHubPool.Dispose() }
    if ($null -ne $script:DirtyStatusPollTimer) { $script:DirtyStatusPollTimer.Stop(); $script:DirtyStatusPollTimer.Dispose() }
    foreach ($info in $script:DirtyStatusProcessInfos) { $info.Process.WaitForExit(); $info.Process.Dispose() }
    $form.Dispose()
}
'@
try {
    & ([scriptblock]::Create($source + [Environment]::NewLine + $checks)) -ConfigPath $config
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ai-mux-ui-tests-'
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
