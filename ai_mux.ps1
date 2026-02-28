param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.txt')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('AiMuxControls.MessageEnterDataGridView' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Windows.Forms;

namespace AiMuxControls
{
    public class MessageEnterDataGridView : DataGridView
    {
        public event EventHandler MessageEnterPressed;

        private bool IsMessageCellFocused()
        {
            if (this.CurrentCell == null || this.CurrentCell.OwningColumn == null)
            {
                return false;
            }

            return string.Equals(this.CurrentCell.OwningColumn.Name, "Message", StringComparison.OrdinalIgnoreCase);
        }

        private bool TryHandleEnterKey(Keys keyData)
        {
            if ((keyData & Keys.KeyCode) != Keys.Enter || !IsMessageCellFocused())
            {
                return false;
            }

            if (MessageEnterPressed != null)
            {
                MessageEnterPressed(this, EventArgs.Empty);
            }
            return true;
        }

        protected override bool ProcessDialogKey(Keys keyData)
        {
            if (TryHandleEnterKey(keyData))
            {
                return true;
            }

            return base.ProcessDialogKey(keyData);
        }

        protected override bool ProcessDataGridViewKey(KeyEventArgs e)
        {
            if (e != null && TryHandleEnterKey(e.KeyData))
            {
                return true;
            }

            return base.ProcessDataGridViewKey(e);
        }
    }
}
"@ -ReferencedAssemblies @('System.Windows.Forms.dll', 'System.Drawing.dll')
}

if (-not ('AiMuxControls.GitStatusChecker' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;

namespace AiMuxControls
{
    public sealed class GitStatusResult
    {
        public string Directory { get; set; }
        public bool? IsClean { get; set; }
    }

    public static class GitStatusChecker
    {
        public static Task<GitStatusResult> CheckAsync(string directory)
        {
            return Task.Run(() =>
            {
                var result = new GitStatusResult
                {
                    Directory = directory,
                    IsClean = null
                };

                if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
                {
                    return result;
                }

                try
                {
                    var args = "-C \"" + directory + "\" status --porcelain";
                    var psi = new ProcessStartInfo("git", args)
                    {
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        CreateNoWindow = true
                    };

                    using (var process = Process.Start(psi))
                    {
                        if (process == null)
                        {
                            return result;
                        }

                        var stdout = process.StandardOutput.ReadToEnd();
                        process.WaitForExit();
                        result.IsClean = (process.ExitCode == 0) ? string.IsNullOrWhiteSpace(stdout) : (bool?)null;
                    }
                }
                catch
                {
                    result.IsClean = null;
                }

                return result;
            });
        }
    }
}
"@
}

$script:DirtyStatusPollTimer = $null
$script:DirtyStatusProcessInfos = @()
$script:DirtyStatusGrid = $null

function Get-DirectoryNameFromPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $trimmed = $Path.Trim().TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return ''
    }

    $name = [System.IO.Path]::GetFileName($trimmed)
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $trimmed
    }

    return $name
}

function New-DirectoryEntry {
    param(
        [string]$Name,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $trimmedPath = $Path.Trim()
    $resolvedName = if ([string]::IsNullOrWhiteSpace($Name)) {
        Get-DirectoryNameFromPath -Path $trimmedPath
    }
    else {
        $Name.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        $resolvedName = $trimmedPath
    }

    return [pscustomobject]@{
        Name = $resolvedName
        Path = $trimmedPath
    }
}

function Load-Config {
    param([string]$Path)

    $config = [ordered]@{
        AgentCmd      = 'codex --yolo'
        TenxExe       = '10x.exe'
        FilePilotExe  = 'FilePilot.exe'
        DiffExe       = 'diff.exe'
        Directories   = New-Object System.Collections.Generic.List[object]
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $config
    }

    $inDirsSection = $false
    foreach ($rawLine in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        if ($line -eq '[DIRS]') {
            $inDirsSection = $true
            continue
        }

        if ($inDirsSection) {
            $entryName = ''
            $entryPath = $line

            if ($line.Contains(',')) {
                $parts = $line.Split(',', 2)
                $entryName = $parts[0].Trim()
                $entryPath = $parts[1].Trim()
            }

            $entry = New-DirectoryEntry -Name $entryName -Path $entryPath
            if ($null -ne $entry) {
                $config.Directories.Add($entry)
            }
            continue
        }

        $parts = $line.Split('=', 2)
        if ($parts.Count -ne 2) {
            continue
        }

        $key = $parts[0].Trim().ToUpperInvariant()
        $value = $parts[1].Trim()

        switch ($key) {
            'AGENT_CMD' { $config.AgentCmd = $value }
            'TENX_EXE'  { $config.TenxExe = $value }
            'FILEPILOT_EXE' { $config.FilePilotExe = $value }
            'DIFF_EXE' { $config.DiffExe = $value }
        }
    }

    return $config
}

function Save-Config {
    param(
        [string]$Path,
        [string]$AgentCmd,
        [string]$TenxExe,
        [string]$FilePilotExe,
        [string]$DiffExe,
        [object[]]$Directories
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# ai_mux config')
    $lines.Add('AGENT_CMD=' + $AgentCmd)
    $lines.Add('TENX_EXE=' + $TenxExe)
    $lines.Add('FILEPILOT_EXE=' + $FilePilotExe)
    $lines.Add('DIFF_EXE=' + $DiffExe)
    $lines.Add('[DIRS]')

    foreach ($entry in $Directories) {
        $dirPath = ''
        $dirName = ''

        if ($entry -is [string]) {
            $dirPath = $entry.Trim()
            $dirName = Get-DirectoryNameFromPath -Path $dirPath
        }
        else {
            $dirPath = [string]$entry.Path
            $dirName = [string]$entry.Name
        }

        if ([string]::IsNullOrWhiteSpace($dirPath)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($dirName)) {
            $dirName = Get-DirectoryNameFromPath -Path $dirPath
        }

        $lines.Add("$dirName,$dirPath")
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Start-CmdInDirectory {
    param(
        [string]$Directory,
        [string]$Command
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return
    }

    $args = "/K cd /d `"$Directory`""
    if (-not [string]::IsNullOrWhiteSpace($Command)) {
        $args += " && $Command"
    }

    Start-Process -FilePath 'cmd.exe' -ArgumentList $args | Out-Null
}

function Start-GitCommitInDirectory {
    param(
        [string]$Directory,
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Message)) {
        [System.Windows.Forms.MessageBox]::Show('Enter a commit message first.', 'ai_mux', 'OK', 'Warning') | Out-Null
        return $false
    }

    $safeMessage = $Message.Trim().Replace('"', "'")
    $command = "git add . && git commit -m `"$safeMessage`" && git pull"

    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $command" -WorkingDirectory $Directory | Out-Null
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to run git command in '$Directory'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
        return $false
    }
}

function Test-GitWorkingTreeClean {
    param(
        [string]$Directory,
        [switch]$Silent
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        }
        return $null
    }

    try {
        $statusOutput = & git -C $Directory status --porcelain 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $details = ($statusOutput | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($details)) {
                $details = 'Unknown git error.'
            }

            throw "git status failed in '$Directory' with exit code $exitCode.`r`n$details"
        }

        $joinedOutput = if ($statusOutput -is [System.Array]) {
            ($statusOutput -join [Environment]::NewLine)
        }
        else {
            [string]$statusOutput
        }

        return [string]::IsNullOrWhiteSpace($joinedOutput)
    }
    catch {
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show("Failed to run git status in '$Directory'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
        }
        return $null
    }
}

function Set-DirtyCellState {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [ValidateSet('Unknown', 'Clean', 'Dirty')]
        [string]$State = 'Unknown'
    )

    if ($null -eq $Row -or $null -eq $Row.DataGridView -or -not $Row.DataGridView.Columns.Contains('Dirty')) {
        return
    }

    $cell = $Row.Cells['Dirty']
    if ($null -eq $cell) {
        return
    }

    $colorHex = switch ($State) {
        'Clean' { '#2E7D32' }
        'Dirty' { '#C62828' }
        default { '#9E9E9E' }
    }

    $backColor = [System.Drawing.ColorTranslator]::FromHtml($colorHex)
    $cell.Value = '?'
    $cell.Style.BackColor = $backColor
    $cell.Style.ForeColor = [System.Drawing.Color]::White
    $cell.Style.SelectionBackColor = $backColor
    $cell.Style.SelectionForeColor = [System.Drawing.Color]::White
}

function Update-DirtyCellsByDirectory {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [string]$Directory,
        [ValidateSet('Unknown', 'Clean', 'Dirty')]
        [string]$State
    )

    if ($null -eq $Grid -or $Grid.IsDisposed -or [string]::IsNullOrWhiteSpace($Directory)) {
        return
    }

    $targetDirectory = $Directory.Trim()
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) {
            continue
        }

        $rowDirectory = [string]$row.Cells['Directory'].Value
        if ([string]::IsNullOrWhiteSpace($rowDirectory)) {
            continue
        }

        if ([string]::Equals($rowDirectory.Trim(), $targetDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
            Set-DirtyCellState -Row $row -State $State
        }
    }
}

function Start-DirtyStatusProcess {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        return $null
    }

    $targetDirectory = $Directory.Trim()
    if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
        return $null
    }

    try {
        $escapedDirectory = $targetDirectory.Replace('"', '""')
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = 'cmd.exe'
        $processInfo.Arguments = "/d /c git -C `"$escapedDirectory`" status --porcelain"
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $null = $process.Start()
        return $process
    }
    catch {
        return $null
    }
}

function Initialize-DirtyStatusPoller {
    param([System.Windows.Forms.DataGridView]$Grid)

    if ($null -eq $Grid -or $Grid.IsDisposed) {
        return
    }

    $script:DirtyStatusGrid = $Grid
    if ($null -ne $script:DirtyStatusPollTimer) {
        return
    }

    $script:DirtyStatusPollTimer = New-Object System.Windows.Forms.Timer
    $script:DirtyStatusPollTimer.Interval = 120
    $script:DirtyStatusPollTimer.Add_Tick({
        try {
            if ($null -eq $script:DirtyStatusGrid -or $script:DirtyStatusGrid.IsDisposed) {
                foreach ($processInfo in $script:DirtyStatusProcessInfos) {
                    $process = $processInfo.Process
                    if ($null -ne $process) {
                        try { if (-not $process.HasExited) { $process.Kill() | Out-Null } } catch {}
                        try { $process.Dispose() } catch {}
                    }
                }
                $script:DirtyStatusProcessInfos = @()
                $script:DirtyStatusPollTimer.Stop()
                return
            }

            if ($script:DirtyStatusProcessInfos.Count -eq 0) {
                $script:DirtyStatusPollTimer.Stop()
                return
            }

            $remaining = @()
            foreach ($processInfo in $script:DirtyStatusProcessInfos) {
                $process = $processInfo.Process
                if ($null -eq $process) {
                    continue
                }

                if (-not $process.HasExited) {
                    $remaining += $processInfo
                    continue
                }

                $state = 'Dirty'
                try {
                    $output = $process.StandardOutput.ReadToEnd()
                    if ($process.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($output)) {
                        $state = 'Clean'
                    }
                }
                catch {
                    $state = 'Dirty'
                }
                finally {
                    try { $process.Dispose() } catch {}
                }

                Update-DirtyCellsByDirectory -Grid $script:DirtyStatusGrid -Directory ([string]$processInfo.Directory) -State $state
            }

            $script:DirtyStatusProcessInfos = $remaining
            if ($script:DirtyStatusProcessInfos.Count -eq 0) {
                $script:DirtyStatusPollTimer.Stop()
            }
        }
        catch {
            $script:DirtyStatusPollTimer.Stop()
        }
    })
}

function Start-DirtyStatusRefreshForGrid {
    param([System.Windows.Forms.DataGridView]$Grid)

    if ($null -eq $Grid -or $Grid.IsDisposed -or -not $Grid.Columns.Contains('Dirty')) {
        return
    }

    Initialize-DirtyStatusPoller -Grid $Grid
    $script:DirtyStatusGrid = $Grid
    foreach ($processInfo in $script:DirtyStatusProcessInfos) {
        $process = $processInfo.Process
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { $process.Kill() | Out-Null } } catch {}
            try { $process.Dispose() } catch {}
        }
    }

    $script:DirtyStatusProcessInfos = @()
    if ($null -ne $script:DirtyStatusPollTimer) {
        $script:DirtyStatusPollTimer.Stop()
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) {
            continue
        }

        $directory = [string]$row.Cells['Directory'].Value
        if ([string]::IsNullOrWhiteSpace($directory)) {
            continue
        }

        $normalizedDirectory = $directory.Trim()
        if ($seen.Add($normalizedDirectory)) {
            $process = Start-DirtyStatusProcess -Directory $normalizedDirectory
            if ($null -eq $process) {
                Update-DirtyCellsByDirectory -Grid $Grid -Directory $normalizedDirectory -State 'Dirty'
                continue
            }

            $script:DirtyStatusProcessInfos += [pscustomobject]@{
                Directory = $normalizedDirectory
                Process = $process
            }
        }
    }

    if ($script:DirtyStatusProcessInfos.Count -gt 0 -and $null -ne $script:DirtyStatusPollTimer) {
        $script:DirtyStatusPollTimer.Start()
    }
}

function Open-In10x {
    param(
        [string]$Directory,
        [string]$TenxExe
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return
    }

    $tenx = if ([string]::IsNullOrWhiteSpace($TenxExe)) { '10x.exe' } else { $TenxExe.Trim() }

    $tenxProject = Get-ChildItem -LiteralPath $Directory -Filter '*.10x' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $target = if ($tenxProject) { $tenxProject.FullName } else { $Directory }

    try {
        Start-Process -FilePath $tenx -ArgumentList "`"$target`"" -WorkingDirectory $Directory | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to open 10x using '$tenx'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
    }
}

function Open-FolderInFilePilot {
    param(
        [string]$Directory,
        [string]$FilePilotExe
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return
    }

    $filePilot = if ([string]::IsNullOrWhiteSpace($FilePilotExe)) { 'FilePilot.exe' } else { $FilePilotExe.Trim() }

    try {
        Start-Process -FilePath $filePilot -ArgumentList "`"$Directory`"" | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to open FilePilot using '$filePilot'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
    }
}

function Open-InDiff {
    param(
        [string]$Directory,
        [string]$DiffExe
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return
    }

    $diff = if ([string]::IsNullOrWhiteSpace($DiffExe)) { 'diff.exe' } else { $DiffExe.Trim() }

    try {
        Start-Process -FilePath $diff -ArgumentList "`"$Directory`"" | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to open diff using '$diff'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
    }
}

function Get-BatPath {
    param(
        [string]$Directory,
        [string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($Directory) -or [string]::IsNullOrWhiteSpace($FileName)) {
        return $null
    }

    $batPath = Join-Path -Path $Directory.Trim() -ChildPath $FileName.Trim()
    if (Test-Path -LiteralPath $batPath -PathType Leaf) {
        return $batPath
    }

    return $null
}

function Get-RunBatPath {
    param([string]$Directory)

    return Get-BatPath -Directory $Directory -FileName 'run.bat'
}

function Get-BuildReleaseBatPath {
    param([string]$Directory)

    return Get-BatPath -Directory $Directory -FileName 'buildrelease.bat'
}

function Start-RunBatInDirectory {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return
    }

    $runBatPath = Get-RunBatPath -Directory $Directory
    if ([string]::IsNullOrWhiteSpace($runBatPath)) {
        [System.Windows.Forms.MessageBox]::Show("run.bat not found in: $Directory", 'ai_mux', 'OK', 'Warning') | Out-Null
        return
    }

    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"`"$runBatPath`"`"" -WorkingDirectory $Directory | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to run '$runBatPath'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
    }
}

function Start-BuildReleaseBatInDirectory {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return
    }

    $buildReleaseBatPath = Get-BuildReleaseBatPath -Directory $Directory
    if ([string]::IsNullOrWhiteSpace($buildReleaseBatPath)) {
        [System.Windows.Forms.MessageBox]::Show("buildrelease.bat not found in: $Directory", 'ai_mux', 'OK', 'Warning') | Out-Null
        return
    }

    try {
        $runBatPath = Get-RunBatPath -Directory $Directory
        $command = if ([string]::IsNullOrWhiteSpace($runBatPath)) {
            "call `"$buildReleaseBatPath`""
        }
        else {
            "call `"$buildReleaseBatPath`" && call `"$runBatPath`""
        }

        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $command" -WorkingDirectory $Directory | Out-Null

        if ([string]::IsNullOrWhiteSpace($runBatPath)) {
            [System.Windows.Forms.MessageBox]::Show("run.bat not found in: $Directory`r`nExecuted buildrelease.bat only.", 'ai_mux', 'OK', 'Warning') | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to run buildrelease.bat + run.bat in '$Directory'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
    }
}

function Set-ScriptButtonCellValues {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [string]$Directory
    )

    if ($null -eq $Row -or [string]::IsNullOrWhiteSpace($Directory)) {
        return
    }

    $Row.Cells['Exe'].Value = if (Get-RunBatPath -Directory $Directory) { 'Exe' } else { '' }
    $Row.Cells['Release'].Value = 'Build'
    Set-DirtyCellState -Row $Row -State 'Unknown'
}

function Get-UniqueDirectoryEntriesFromGrid {
    param([System.Windows.Forms.DataGridView]$Grid)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[object]

    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) {
            continue
        }

        $pathValue = [string]$row.Cells['Directory'].Value
        if ([string]::IsNullOrWhiteSpace($pathValue)) {
            continue
        }

        $dirPath = $pathValue.Trim()
        if ($seen.Add($dirPath)) {
            $nameValue = [string]$row.Cells['Name'].Value
            $result.Add((New-DirectoryEntry -Name $nameValue -Path $dirPath))
        }
    }

    return $result.ToArray()
}

function Resize-TopPanelToContent {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [System.Windows.Forms.SplitContainer]$Split
    )

    if ($Split.Panel1Collapsed) {
        return
    }

    $maxBottom = 0
    foreach ($control in $Panel.Controls) {
        if ($control.Bottom -gt $maxBottom) {
            $maxBottom = $control.Bottom
        }
    }

    $desired = $maxBottom + $Panel.Padding.Bottom + 10
    if ($desired -lt 100) {
        $desired = 100
    }

    if ($Split.Height -le 0) {
        return
    }

    $maxAllowed = [Math]::Max(120, $Split.Height - 140)
    if ($desired -gt $maxAllowed) {
        $desired = $maxAllowed
    }

    if ($desired -gt 0) {
        $Split.SplitterDistance = $desired
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ai_mux'
$form.Width = 550
$form.Height = 250
$form.StartPosition = 'CenterScreen'

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount = 2
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$form.Controls.Add($layout)

$configBar = New-Object System.Windows.Forms.Panel
$configBar.Dock = 'Fill'
$configBar.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
$layout.Controls.Add($configBar, 0, 0)

$btnToggleConfig = New-Object System.Windows.Forms.Button
$btnToggleConfig.Text = 'Config'
$btnToggleConfig.Width = 95
$btnToggleConfig.Location = New-Object System.Drawing.Point(8, 6)
$configBar.Controls.Add($btnToggleConfig)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$split.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel1
$split.IsSplitterFixed = $true
$split.SplitterWidth = 4
$split.Panel1MinSize = 100
$layout.Controls.Add($split, 0, 1)

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = 'Fill'
$topPanel.Height = 100
$topPanel.Padding = New-Object System.Windows.Forms.Padding(10)

$lblAgent = New-Object System.Windows.Forms.Label
$lblAgent.Text = 'Agent cmd:'
$lblAgent.AutoSize = $true
$lblAgent.Location = New-Object System.Drawing.Point(10, 12)
$topPanel.Controls.Add($lblAgent)

$txtAgent = New-Object System.Windows.Forms.TextBox
$txtAgent.Width = 46
$txtAgent.Location = New-Object System.Drawing.Point(90, 8)
$topPanel.Controls.Add($txtAgent)

$lblTenx = New-Object System.Windows.Forms.Label
$lblTenx.Text = '10x exe:'
$lblTenx.AutoSize = $true
$lblTenx.Location = New-Object System.Drawing.Point(10, 44)
$topPanel.Controls.Add($lblTenx)

$txtTenx = New-Object System.Windows.Forms.TextBox
$txtTenx.Width = 46
$txtTenx.Location = New-Object System.Drawing.Point(90, 40)
$topPanel.Controls.Add($txtTenx)

$btnBrowseTenx = New-Object System.Windows.Forms.Button
$btnBrowseTenx.Text = 'Browse...'
$btnBrowseTenx.Width = 90
$btnBrowseTenx.Location = New-Object System.Drawing.Point(142, 38)
$topPanel.Controls.Add($btnBrowseTenx)

$lblFilePilot = New-Object System.Windows.Forms.Label
$lblFilePilot.Text = 'FilePilot exe:'
$lblFilePilot.AutoSize = $true
$lblFilePilot.Location = New-Object System.Drawing.Point(10, 76)
$topPanel.Controls.Add($lblFilePilot)

$txtFilePilot = New-Object System.Windows.Forms.TextBox
$txtFilePilot.Width = 46
$txtFilePilot.Location = New-Object System.Drawing.Point(90, 72)
$topPanel.Controls.Add($txtFilePilot)

$btnBrowseFilePilot = New-Object System.Windows.Forms.Button
$btnBrowseFilePilot.Text = 'Browse...'
$btnBrowseFilePilot.Width = 90
$btnBrowseFilePilot.Location = New-Object System.Drawing.Point(142, 70)
$topPanel.Controls.Add($btnBrowseFilePilot)

$lblDiff = New-Object System.Windows.Forms.Label
$lblDiff.Text = 'Diff exe:'
$lblDiff.AutoSize = $true
$lblDiff.Location = New-Object System.Drawing.Point(10, 108)
$topPanel.Controls.Add($lblDiff)

$txtDiff = New-Object System.Windows.Forms.TextBox
$txtDiff.Width = 46
$txtDiff.Location = New-Object System.Drawing.Point(90, 104)
$topPanel.Controls.Add($txtDiff)

$btnBrowseDiff = New-Object System.Windows.Forms.Button
$btnBrowseDiff.Text = 'Browse...'
$btnBrowseDiff.Width = 90
$btnBrowseDiff.Location = New-Object System.Drawing.Point(142, 102)
$topPanel.Controls.Add($btnBrowseDiff)

$btnAddDir = New-Object System.Windows.Forms.Button
$btnAddDir.Text = 'Add Folder'
$btnAddDir.Width = 95
$btnAddDir.Location = New-Object System.Drawing.Point(142, 8)
$topPanel.Controls.Add($btnAddDir)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = 'Reload'
$btnReload.Width = 95
$btnReload.Location = New-Object System.Drawing.Point(245, 8)
$topPanel.Controls.Add($btnReload)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save Config'
$btnSave.Width = 95
$btnSave.Location = New-Object System.Drawing.Point(348, 8)
$topPanel.Controls.Add($btnSave)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Rows show one directory each by name. Click x to delete a row.'
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(670, 76)
$topPanel.Controls.Add($hint)

$grid = New-Object AiMuxControls.MessageEnterDataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoSizeRowsMode = 'None'
$grid.ReadOnly = $false
$grid.EditMode = [System.Windows.Forms.DataGridViewEditMode]::EditOnEnter
$split.Panel1.Controls.Add($topPanel)
$split.Panel2.Controls.Add($grid)
Resize-TopPanelToContent -Panel $topPanel -Split $split
$form.Add_Shown({
    Resize-TopPanelToContent -Panel $topPanel -Split $split
    Start-DirtyStatusRefreshForGrid -Grid $grid
})
$form.Add_Resize({
    Resize-TopPanelToContent -Panel $topPanel -Split $split
})
$btnToggleConfig.Add_Click({
    $split.Panel1Collapsed = -not $split.Panel1Collapsed
    if ($split.Panel1Collapsed) {
        $btnToggleConfig.Text = 'Config'
        return
    }

    $btnToggleConfig.Text = 'Hide Config'
    Resize-TopPanelToContent -Panel $topPanel -Split $split
})
$split.Panel1Collapsed = $true

$colDirectory = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colDirectory.Name = 'Directory'
$colDirectory.HeaderText = 'Directory'
$colDirectory.Visible = $false
$grid.Columns.Add($colDirectory) | Out-Null

$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.Name = 'Name'
$colName.HeaderText = 'Name'
$colName.AutoSizeMode = 'Fill'
$grid.Columns.Insert(0, $colName)
$grid.Columns['Directory'].DisplayIndex = 1
$grid.Columns['Directory'].Visible = $false
$grid.Columns['Name'].DisplayIndex = 0
$grid.Columns['Name'].AutoSizeMode = 'Fill'
$grid.Columns['Name'].ReadOnly = $true
$colDirectory.AutoSizeMode = 'Fill'
$colDirectory.ReadOnly = $true

$colMessage = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colMessage.Name = 'Message'
$colMessage.HeaderText = 'Git'
$colMessage.Width = 70
$colMessage.ReadOnly = $false
$grid.Columns.Add($colMessage) | Out-Null

$gridButtonColors = @{
    'AI' = '#7B1FA2'
    '10x' = '#2E7D32'
    'Diff' = '#66BB6A'
    'Dirty' = '#9E9E9E'
    'Exe' = '#EF6C00'
    'Release' = '#8B0000'
    'Cmd' = '#000000'
    'Folder' = '#F3E5AB'
    'X' = '#C62828'
}

foreach ($name in @('AI', '10x', 'Diff', 'Dirty', 'Exe', 'Release', 'Cmd', 'Folder', 'X')) {
    $col = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $displayName = if ($name -eq 'Release') { 'Build' } elseif ($name -eq 'X') { 'x' } elseif ($name -eq 'Dirty') { '?' } else { $name }
    $col.Name = $name
    $col.HeaderText = if ($name -eq 'X') { '' } elseif ($name -eq 'Dirty') { 'Dirty' } else { $displayName }
    $col.Text = $displayName
    $col.UseColumnTextForButtonValue = ($name -ne 'Exe' -and $name -ne 'Release')
    if ($name -eq 'X') {
        $col.Width = 30
    }
    elseif ($name -eq 'Folder') {
        $col.Width = 40
    }
    elseif ($name -eq 'Dirty') {
        $col.Width = 30
    }
    else {
        $col.Width = 35
    }

    $colorHex = $gridButtonColors[$name]
    if ($colorHex) {
        $buttonColor = [System.Drawing.ColorTranslator]::FromHtml($colorHex)
        $textColor = if ($name -eq 'Folder') { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
        $col.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $col.DefaultCellStyle.BackColor = $buttonColor
        $col.DefaultCellStyle.ForeColor = $textColor
        $col.DefaultCellStyle.SelectionBackColor = $buttonColor
        $col.DefaultCellStyle.SelectionForeColor = $textColor
    }

    $grid.Columns.Add($col) | Out-Null
}

$grid.Columns['X'].DisplayIndex = 0
$grid.Columns['Name'].DisplayIndex = 1
$grid.Columns['AI'].DisplayIndex = 2
$grid.Columns['10x'].DisplayIndex = 3
$grid.Columns['Diff'].DisplayIndex = 4
$grid.Columns['Dirty'].DisplayIndex = 5
$grid.Columns['Message'].DisplayIndex = 6
$grid.Columns['Release'].DisplayIndex = 7
$grid.Columns['Exe'].DisplayIndex = 8
$grid.Columns['Cmd'].DisplayIndex = 9
$grid.Columns['Folder'].DisplayIndex = 10

function Invoke-GitCommitFromRow {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$RowIndex
    )

    if ($null -eq $Grid -or $RowIndex -lt 0 -or $RowIndex -ge $Grid.Rows.Count) {
        return
    }

    $directory = [string]$Grid.Rows[$RowIndex].Cells['Directory'].Value
    if ([string]::IsNullOrWhiteSpace($directory)) {
        return
    }

    $message = [string]$Grid.Rows[$RowIndex].Cells['Message'].Value
    if (Start-GitCommitInDirectory -Directory $directory.Trim() -Message $message) {
        $Grid.Rows[$RowIndex].Cells['Message'].Value = ''
        Set-DirtyCellState -Row $Grid.Rows[$RowIndex] -State 'Clean'

        if ($Grid.Columns.Contains('Name')) {
            $Grid.ClearSelection()
            $Grid.Rows[$RowIndex].Selected = $true
            $Grid.CurrentCell = $Grid.Rows[$RowIndex].Cells['Name']
        }
    }
}

function Refresh-Grid {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [object[]]$Directories
    )

    $Grid.Rows.Clear()
    foreach ($entry in $Directories) {
        $normalized = $null

        if ($entry -is [string]) {
            $normalized = New-DirectoryEntry -Name '' -Path $entry
        }
        else {
            $normalized = New-DirectoryEntry -Name ([string]$entry.Name) -Path ([string]$entry.Path)
        }

        if ($null -eq $normalized) {
            continue
        }

        $rowIndex = $Grid.Rows.Add($normalized.Name, $normalized.Path)
        Set-ScriptButtonCellValues -Row $Grid.Rows[$rowIndex] -Directory $normalized.Path
    }
}

function Load-IntoUi {
    $config = Load-Config -Path $ConfigPath
    $txtAgent.Text = $config.AgentCmd
    $txtTenx.Text = $config.TenxExe
    $txtFilePilot.Text = $config.FilePilotExe
    $txtDiff.Text = $config.DiffExe
    Refresh-Grid -Grid $grid -Directories $config.Directories
    Start-DirtyStatusRefreshForGrid -Grid $grid
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Save-Config -Path $ConfigPath -AgentCmd 'codex --yolo' -TenxExe '10x.exe' -FilePilotExe 'FilePilot.exe' -DiffExe 'diff.exe' -Directories @()
}

$btnBrowseTenx.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Executable (*.exe)|*.exe|All files (*.*)|*.*'
    $dialog.Title = 'Select 10x executable'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtTenx.Text = $dialog.FileName
    }
})

$btnBrowseFilePilot.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Executable (*.exe)|*.exe|All files (*.*)|*.*'
    $dialog.Title = 'Select FilePilot executable'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFilePilot.Text = $dialog.FileName
    }
})

$btnBrowseDiff.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Executable (*.exe)|*.exe|All files (*.*)|*.*'
    $dialog.Title = 'Select diff executable'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtDiff.Text = $dialog.FileName
    }
})

$btnAddDir.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select a directory to add'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $selectedPath = $dialog.SelectedPath
        $name = Get-DirectoryNameFromPath -Path $selectedPath
        $rowIndex = $grid.Rows.Add($name, $selectedPath)
        Set-ScriptButtonCellValues -Row $grid.Rows[$rowIndex] -Directory $selectedPath
    }
})

$btnReload.Add_Click({
    Load-IntoUi
})

$btnSave.Add_Click({
    $directories = Get-UniqueDirectoryEntriesFromGrid -Grid $grid
    Save-Config -Path $ConfigPath -AgentCmd $txtAgent.Text.Trim() -TenxExe $txtTenx.Text.Trim() -FilePilotExe $txtFilePilot.Text.Trim() -DiffExe $txtDiff.Text.Trim() -Directories $directories
    Refresh-Grid -Grid $grid -Directories $directories
    [System.Windows.Forms.MessageBox]::Show("Saved: $ConfigPath", 'ai_mux') | Out-Null
})

$grid.Add_CellContentClick({
    param($sender, $e)

    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) {
        return
    }

    $columnName = $grid.Columns[$e.ColumnIndex].Name
    $directory = [string]$grid.Rows[$e.RowIndex].Cells['Directory'].Value

    if ([string]::IsNullOrWhiteSpace($directory)) {
        return
    }

    $directory = $directory.Trim()

    switch ($columnName) {
        'AI' {
            $agentCmd = $txtAgent.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($agentCmd)) {
                [System.Windows.Forms.MessageBox]::Show('Set Agent cmd first.', 'ai_mux', 'OK', 'Warning') | Out-Null
                return
            }
            Start-CmdInDirectory -Directory $directory -Command $agentCmd
        }
        '10x' {
            Open-In10x -Directory $directory -TenxExe $txtTenx.Text
        }
        'Diff' {
            Open-InDiff -Directory $directory -DiffExe $txtDiff.Text
        }
        'Dirty' {
            $isClean = Test-GitWorkingTreeClean -Directory $directory
            if ($isClean -eq $true) {
                Set-DirtyCellState -Row $grid.Rows[$e.RowIndex] -State 'Clean'
            }
            else {
                Set-DirtyCellState -Row $grid.Rows[$e.RowIndex] -State 'Dirty'
            }
        }
        'Cmd' {
            Start-CmdInDirectory -Directory $directory -Command ''
        }
        'Exe' {
            Start-RunBatInDirectory -Directory $directory
        }
        'Release' {
            Start-BuildReleaseBatInDirectory -Directory $directory
        }
        'Folder' {
            Open-FolderInFilePilot -Directory $directory -FilePilotExe $txtFilePilot.Text
        }
        'X' {
            $grid.Rows.RemoveAt($e.RowIndex)
        }
    }
})

$grid.Add_MessageEnterPressed({
    if ($null -eq $grid.CurrentCell) {
        return
    }

    $rowIndex = $grid.CurrentCell.RowIndex
    $grid.EndEdit() | Out-Null
    Invoke-GitCommitFromRow -Grid $grid -RowIndex $rowIndex
})

$form.Add_FormClosed({
    if ($null -ne $script:DirtyStatusPollTimer) {
        $script:DirtyStatusPollTimer.Stop()
        $script:DirtyStatusPollTimer.Dispose()
        $script:DirtyStatusPollTimer = $null
    }

    $script:DirtyStatusProcessInfos = @()
    $script:DirtyStatusGrid = $null
})

Load-IntoUi

[void]$form.ShowDialog()
