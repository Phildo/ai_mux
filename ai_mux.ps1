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

function Normalize-CmdColorComponent {
    param([string]$ColorComponent)

    if ([string]::IsNullOrWhiteSpace($ColorComponent)) {
        return ''
    }

    $normalized = $ColorComponent.Trim().ToUpperInvariant()
    if ($normalized -match '^[0-9A-F]$') {
        return $normalized
    }

    return ''
}

function Normalize-CmdColorCode {
    param([string]$ColorCode)

    if ([string]::IsNullOrWhiteSpace($ColorCode)) {
        return ''
    }

    $normalized = $ColorCode.Trim().ToUpperInvariant()
    if ($normalized -match '^[0-9A-F]{2}$') {
        return $normalized
    }

    return ''
}

function Get-DefaultCmdColorCodeForDirectory {
    param([string]$Directory)

    $normalizedDirectory = if ([string]::IsNullOrWhiteSpace($Directory)) { '' } else { $Directory.Trim() }
    $palette = @('0A', '0B', '0C', '0D', '0E', '1A', '1B', '1E', '2A', '2B', '3A', '3B', '4A', '5B')
    $checksum = 0
    foreach ($ch in $normalizedDirectory.ToCharArray()) {
        $checksum += [int][char]$ch
    }

    return $palette[$checksum % $palette.Count]
}

function Resolve-CmdColorCode {
    param(
        [string]$Directory,
        [string]$ColorCode = '',
        [string]$BackgroundColor = '',
        [string]$TextColor = ''
    )

    $defaultCode = Get-DefaultCmdColorCodeForDirectory -Directory $Directory
    $defaultBackground = $defaultCode.Substring(0, 1)
    $defaultText = $defaultCode.Substring(1, 1)

    $normalizedCode = Normalize-CmdColorCode -ColorCode $ColorCode
    $codeBackground = $defaultBackground
    $codeText = $defaultText
    if (-not [string]::IsNullOrWhiteSpace($normalizedCode)) {
        $codeBackground = $normalizedCode.Substring(0, 1)
        $codeText = $normalizedCode.Substring(1, 1)
    }

    $resolvedBackground = Normalize-CmdColorComponent -ColorComponent $BackgroundColor
    if ([string]::IsNullOrWhiteSpace($resolvedBackground)) {
        $resolvedBackground = $codeBackground
    }

    $resolvedText = Normalize-CmdColorComponent -ColorComponent $TextColor
    if ([string]::IsNullOrWhiteSpace($resolvedText)) {
        $resolvedText = $codeText
    }

    if ($resolvedBackground -eq $resolvedText) {
        $resolvedText = if ($resolvedBackground -in @('7', 'A', 'B', 'C', 'D', 'E', 'F')) { '0' } else { 'F' }
    }

    return "$resolvedBackground$resolvedText"
}

function Get-ConsoleColorFromHexDigit {
    param([char]$HexDigit)

    $digit = [string]$HexDigit
    switch ($digit.ToUpperInvariant()) {
        '0' { return [System.Drawing.Color]::FromArgb(0, 0, 0) }
        '1' { return [System.Drawing.Color]::FromArgb(0, 0, 128) }
        '2' { return [System.Drawing.Color]::FromArgb(0, 128, 0) }
        '3' { return [System.Drawing.Color]::FromArgb(0, 128, 128) }
        '4' { return [System.Drawing.Color]::FromArgb(128, 0, 0) }
        '5' { return [System.Drawing.Color]::FromArgb(128, 0, 128) }
        '6' { return [System.Drawing.Color]::FromArgb(128, 128, 0) }
        '7' { return [System.Drawing.Color]::FromArgb(192, 192, 192) }
        '8' { return [System.Drawing.Color]::FromArgb(128, 128, 128) }
        '9' { return [System.Drawing.Color]::FromArgb(0, 0, 255) }
        'A' { return [System.Drawing.Color]::FromArgb(0, 255, 0) }
        'B' { return [System.Drawing.Color]::FromArgb(0, 255, 255) }
        'C' { return [System.Drawing.Color]::FromArgb(255, 0, 0) }
        'D' { return [System.Drawing.Color]::FromArgb(255, 0, 255) }
        'E' { return [System.Drawing.Color]::FromArgb(255, 255, 0) }
        'F' { return [System.Drawing.Color]::FromArgb(255, 255, 255) }
        default { return [System.Drawing.Color]::Black }
    }
}

function Get-ReadableTextColor {
    param([System.Drawing.Color]$BackgroundColor)

    $luminance = (0.2126 * $BackgroundColor.R) + (0.7152 * $BackgroundColor.G) + (0.0722 * $BackgroundColor.B)
    if ($luminance -gt 140) {
        return [System.Drawing.Color]::Black
    }

    return [System.Drawing.Color]::White
}

function Get-CmdColorDigits {
    return @('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F')
}

function New-DirectoryEntry {
    param(
        [string]$Name,
        [string]$Path,
        [string]$CmdBgColor = '',
        [string]$CmdTextColor = '',
        [string]$CmdColor = ''
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

    $resolvedCmdColor = Resolve-CmdColorCode -Directory $trimmedPath -ColorCode $CmdColor -BackgroundColor $CmdBgColor -TextColor $CmdTextColor

    return [pscustomobject]@{
        Name = $resolvedName
        Path = $trimmedPath
        CmdBgColor = $resolvedCmdColor.Substring(0, 1)
        CmdTextColor = $resolvedCmdColor.Substring(1, 1)
        CmdColor = $resolvedCmdColor
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
            $entryCmdBgColor = ''
            $entryCmdTextColor = ''
            $entryCmdColor = ''

            if ($line.Contains(',')) {
                $parts = $line.Split(',', 2)
                $entryName = $parts[0].Trim()
                $entryPathAndMaybeColor = $parts[1].Trim()

                $bgTextMatch = [System.Text.RegularExpressions.Regex]::Match($entryPathAndMaybeColor, '^(?<path>.*?),(?<bg>[0-9A-Fa-f]),(?<text>[0-9A-Fa-f])$')
                if ($bgTextMatch.Success) {
                    $entryPath = $bgTextMatch.Groups['path'].Value.Trim()
                    $entryCmdBgColor = $bgTextMatch.Groups['bg'].Value.Trim()
                    $entryCmdTextColor = $bgTextMatch.Groups['text'].Value.Trim()
                }
                else {
                    $colorMatch = [System.Text.RegularExpressions.Regex]::Match($entryPathAndMaybeColor, '^(?<path>.*),(?<color>[0-9A-Fa-f]{2})$')
                    if ($colorMatch.Success) {
                        $entryPath = $colorMatch.Groups['path'].Value.Trim()
                        $entryCmdColor = $colorMatch.Groups['color'].Value.Trim()
                    }
                    else {
                        $entryPath = $entryPathAndMaybeColor
                    }
                }
            }

            $entry = New-DirectoryEntry -Name $entryName -Path $entryPath -CmdBgColor $entryCmdBgColor -CmdTextColor $entryCmdTextColor -CmdColor $entryCmdColor
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
        $dirCmdBgColor = ''
        $dirCmdTextColor = ''
        $dirCmdColor = ''

        if ($entry -is [string]) {
            $dirPath = $entry.Trim()
            $dirName = Get-DirectoryNameFromPath -Path $dirPath
        }
        else {
            $dirPath = [string]$entry.Path
            $dirName = [string]$entry.Name
            if ($entry.PSObject.Properties['CmdBgColor']) {
                $dirCmdBgColor = [string]$entry.CmdBgColor
            }
            if ($entry.PSObject.Properties['CmdTextColor']) {
                $dirCmdTextColor = [string]$entry.CmdTextColor
            }
            if ($entry.PSObject.Properties['CmdColor']) {
                $dirCmdColor = [string]$entry.CmdColor
            }
        }

        if ([string]::IsNullOrWhiteSpace($dirPath)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($dirName)) {
            $dirName = Get-DirectoryNameFromPath -Path $dirPath
        }

        $resolvedCmdColor = Resolve-CmdColorCode -Directory $dirPath -ColorCode $dirCmdColor -BackgroundColor $dirCmdBgColor -TextColor $dirCmdTextColor
        $resolvedBackground = $resolvedCmdColor.Substring(0, 1)
        $resolvedText = $resolvedCmdColor.Substring(1, 1)
        $lines.Add("$dirName,$dirPath,$resolvedBackground,$resolvedText")
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Escape-ForCmdCommandLiteral {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $escaped = $Value.Replace('^', '^^')
    $escaped = $escaped.Replace('&', '^&')
    $escaped = $escaped.Replace('|', '^|')
    $escaped = $escaped.Replace('<', '^<')
    $escaped = $escaped.Replace('>', '^>')
    $escaped = $escaped.Replace('(', '^(')
    $escaped = $escaped.Replace(')', '^)')
    $escaped = $escaped.Replace('%', '%%')
    return $escaped
}

function Get-CmdWindowDecorators {
    param(
        [string]$Directory,
        [string]$CmdColor
    )

    $projectName = Get-DirectoryNameFromPath -Path $Directory
    if ([string]::IsNullOrWhiteSpace($projectName)) {
        $projectName = 'shell'
    }

    $color = Resolve-CmdColorCode -Directory $Directory -ColorCode $CmdColor
    return [pscustomobject]@{
        Title = $projectName
        Color = $color
    }
}

function Get-CmdPrefixCommands {
    param(
        [string]$Directory,
        [string]$CmdColor
    )

    $decorators = Get-CmdWindowDecorators -Directory $Directory -CmdColor $CmdColor
    $safeTitle = Escape-ForCmdCommandLiteral -Value ([string]$decorators.Title)
    return "title $safeTitle & color $($decorators.Color)"
}

function Start-CmdInDirectory {
    param(
        [string]$Directory,
        [string]$Command,
        [string]$CmdColor = ''
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return
    }

    $prefix = Get-CmdPrefixCommands -Directory $Directory -CmdColor $CmdColor
    $args = "/K $prefix & cd /d `"$Directory`""
    if (-not [string]::IsNullOrWhiteSpace($Command)) {
        $args += " && $Command"
    }

    Start-Process -FilePath 'cmd.exe' -ArgumentList $args | Out-Null
}

function Start-GitCommitInDirectory {
    param(
        [string]$Directory,
        [string]$Message,
        [string]$CmdColor = ''
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
    $command = "git add . && git commit -m `"$safeMessage`" && git push"

    try {
        $prefix = Get-CmdPrefixCommands -Directory $Directory -CmdColor $CmdColor
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $prefix & $command" -WorkingDirectory $Directory | Out-Null
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to run git command in '$Directory'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
        return $false
    }
}

function Start-GitPullInDirectory {
    param(
        [string]$Directory,
        [string]$CmdColor = ''
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return $false
    }

    try {
        $prefix = Get-CmdPrefixCommands -Directory $Directory -CmdColor $CmdColor
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $prefix & git pull" -WorkingDirectory $Directory | Out-Null
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to run git pull in '$Directory'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
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

    return Get-BatPath -Directory $Directory -FileName 'build.bat'
}

function Get-DebugBatPath {
    param([string]$Directory)

    return Get-BatPath -Directory $Directory -FileName 'debug.bat'
}

function Start-RunBatInDirectory {
    param(
        [string]$Directory,
        [string]$CmdColor = ''
    )

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
        # Launch run.bat directly (shell execution), matching double-click behavior.
        Start-Process -FilePath $runBatPath -WorkingDirectory $Directory | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to run '$runBatPath'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
    }
}

function Start-DebugBatInDirectory {
    param(
        [string]$Directory,
        [string]$CmdColor = ''
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return
    }

    $debugBatPath = Get-DebugBatPath -Directory $Directory
    if ([string]::IsNullOrWhiteSpace($debugBatPath)) {
        [System.Windows.Forms.MessageBox]::Show("debug.bat not found in: $Directory", 'ai_mux', 'OK', 'Warning') | Out-Null
        return
    }

    try {
        $prefix = Get-CmdPrefixCommands -Directory $Directory -CmdColor $CmdColor
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $prefix & call `"`"$debugBatPath`"`"" -WorkingDirectory $Directory | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to run '$debugBatPath'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
    }
}

function Start-BuildReleaseBatInDirectory {
    param(
        [string]$Directory,
        [string]$CmdColor = ''
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Directory not found: $Directory", 'ai_mux', 'OK', 'Error') | Out-Null
        return
    }

    $buildReleaseBatPath = Get-BuildReleaseBatPath -Directory $Directory
    if ([string]::IsNullOrWhiteSpace($buildReleaseBatPath)) {
        [System.Windows.Forms.MessageBox]::Show("build.bat not found in: $Directory", 'ai_mux', 'OK', 'Warning') | Out-Null
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

        $prefix = Get-CmdPrefixCommands -Directory $Directory -CmdColor $CmdColor
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $prefix & $command" -WorkingDirectory $Directory | Out-Null

        if ([string]::IsNullOrWhiteSpace($runBatPath)) {
            [System.Windows.Forms.MessageBox]::Show("run.bat not found in: $Directory`r`nExecuted build.bat only.", 'ai_mux', 'OK', 'Warning') | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to run build.bat + run.bat in '$Directory'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
    }
}

function Set-XCellColorFromCmdColor {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [string]$CmdColor
    )

    if ($null -eq $Row -or $null -eq $Row.DataGridView -or -not $Row.DataGridView.Columns.Contains('X')) {
        return
    }

    $directory = ''
    if ($Row.DataGridView.Columns.Contains('Directory')) {
        $directory = [string]$Row.Cells['Directory'].Value
    }

    $resolved = Resolve-CmdColorCode -Directory $directory -ColorCode $CmdColor
    $background = Get-ConsoleColorFromHexDigit -HexDigit $resolved[0]
    $foreground = Get-ConsoleColorFromHexDigit -HexDigit $resolved[1]
    if ($background.ToArgb() -eq $foreground.ToArgb()) {
        $foreground = Get-ReadableTextColor -BackgroundColor $background
    }

    $xCell = $Row.Cells['X']
    $xCell.Style.BackColor = $background
    $xCell.Style.ForeColor = $foreground
    $xCell.Style.SelectionBackColor = $background
    $xCell.Style.SelectionForeColor = $foreground
}

function Set-ScriptButtonCellValues {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [string]$Directory,
        [string]$CmdColor = ''
    )

    if ($null -eq $Row -or [string]::IsNullOrWhiteSpace($Directory)) {
        return
    }

    $Row.Cells['Exe'].Value = if (Get-RunBatPath -Directory $Directory) { 'Run' } else { '' }
    $Row.Cells['Dbg'].Value = if (Get-DebugBatPath -Directory $Directory) { 'Dbg' } else { '' }
    $Row.Cells['Release'].Value = if (Get-BuildReleaseBatPath -Directory $Directory) { 'Build' } else { '' }
    if ($Row.DataGridView.Columns.Contains('CmdColor')) {
        $Row.Cells['CmdColor'].Value = Resolve-CmdColorCode -Directory $Directory -ColorCode $CmdColor
    }
    Set-XCellColorFromCmdColor -Row $Row -CmdColor $CmdColor
    Set-DirtyCellState -Row $Row -State 'Unknown'
}

function Test-IsAddProjectRow {
    param([System.Windows.Forms.DataGridViewRow]$Row)

    if ($null -eq $Row -or $null -eq $Row.DataGridView -or -not $Row.DataGridView.Columns.Contains('IsAddRow')) {
        return $false
    }

    $rawValue = $Row.Cells['IsAddRow'].Value
    if ($null -eq $rawValue) {
        return $false
    }

    if ($rawValue -is [bool]) {
        return [bool]$rawValue
    }

    return [string]::Equals(([string]$rawValue).Trim(), 'true', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-AddProjectRowIndex {
    param([System.Windows.Forms.DataGridView]$Grid)

    if ($null -eq $Grid -or $Grid.IsDisposed) {
        return -1
    }

    for ($index = 0; $index -lt $Grid.Rows.Count; $index++) {
        if (Test-IsAddProjectRow -Row $Grid.Rows[$index]) {
            return $index
        }
    }

    return -1
}

function Remove-AddProjectRow {
    param([System.Windows.Forms.DataGridView]$Grid)

    $addProjectRowIndex = Get-AddProjectRowIndex -Grid $Grid
    if ($addProjectRowIndex -lt 0) {
        return $false
    }

    $Grid.Rows.RemoveAt($addProjectRowIndex)
    return $true
}

function Add-AddProjectRow {
    param([System.Windows.Forms.DataGridView]$Grid)

    if ($null -eq $Grid -or $Grid.IsDisposed) {
        return
    }

    $null = Remove-AddProjectRow -Grid $Grid
    $rowIndex = $Grid.Rows.Add('', '', '', $true)
    $row = $Grid.Rows[$rowIndex]
    $rowBackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F6F8')
    $accentColor = [System.Drawing.ColorTranslator]::FromHtml('#2E7D32')

    foreach ($cell in $row.Cells) {
        $cell.ReadOnly = $true
        if ($cell -is [System.Windows.Forms.DataGridViewButtonCell]) {
            $cell.UseColumnTextForButtonValue = $false
            $cell.Value = ''
            if ($cell.OwningColumn.Name -ne 'X') {
                $cell.Style.BackColor = $rowBackColor
                $cell.Style.ForeColor = $rowBackColor
                $cell.Style.SelectionBackColor = $rowBackColor
                $cell.Style.SelectionForeColor = $rowBackColor
            }
        }
    }

    $row.Cells['Name'].Value = 'Add Project...'
    $row.Cells['X'].ReadOnly = $false
    $row.Cells['X'].Value = '+'

    $row.DefaultCellStyle.BackColor = $rowBackColor
    $row.DefaultCellStyle.SelectionBackColor = $rowBackColor
    $row.Cells['Name'].Style.ForeColor = [System.Drawing.Color]::FromArgb(35, 45, 55)
    $row.Cells['Name'].Style.SelectionForeColor = [System.Drawing.Color]::FromArgb(35, 45, 55)

    $row.Cells['X'].Style.BackColor = $accentColor
    $row.Cells['X'].Style.ForeColor = [System.Drawing.Color]::White
    $row.Cells['X'].Style.SelectionBackColor = $accentColor
    $row.Cells['X'].Style.SelectionForeColor = [System.Drawing.Color]::White
}

function Add-ProjectEntryRow {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [object]$Entry
    )

    if ($null -eq $Grid -or $Grid.IsDisposed -or $null -eq $Entry) {
        return
    }

    $hadAddProjectRow = Remove-AddProjectRow -Grid $Grid
    $rowIndex = $Grid.Rows.Add($Entry.Name, $Entry.Path, $Entry.CmdColor, $false)
    Set-ScriptButtonCellValues -Row $Grid.Rows[$rowIndex] -Directory $Entry.Path -CmdColor $Entry.CmdColor

    if ($hadAddProjectRow) {
        Add-AddProjectRow -Grid $Grid
    }
}

function Get-UniqueDirectoryEntriesFromGrid {
    param([System.Windows.Forms.DataGridView]$Grid)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[object]

    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) {
            continue
        }

        if (Test-IsAddProjectRow -Row $row) {
            continue
        }

        $pathValue = [string]$row.Cells['Directory'].Value
        if ([string]::IsNullOrWhiteSpace($pathValue)) {
            continue
        }

        $dirPath = $pathValue.Trim()
        if ($seen.Add($dirPath)) {
            $nameValue = [string]$row.Cells['Name'].Value
            $cmdColorValue = if ($Grid.Columns.Contains('CmdColor')) { [string]$row.Cells['CmdColor'].Value } else { '' }
            $result.Add((New-DirectoryEntry -Name $nameValue -Path $dirPath -CmdColor $cmdColorValue))
        }
    }

    return $result.ToArray()
}

function Save-GridConfigToFile {
    param(
        [string]$Path,
        [System.Windows.Forms.DataGridView]$Grid,
        [string]$AgentCmd,
        [string]$TenxExe,
        [string]$FilePilotExe,
        [string]$DiffExe
    )

    try {
        $directories = Get-UniqueDirectoryEntriesFromGrid -Grid $Grid
        Save-Config -Path $Path -AgentCmd $AgentCmd -TenxExe $TenxExe -FilePilotExe $FilePilotExe -DiffExe $DiffExe -Directories $directories
        return $directories
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to save config '$Path'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
        return $null
    }
}

function Show-ProjectAddCellDialog {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [string]$ConfigPath,
        [string]$AgentCmd,
        [string]$TenxExe,
        [string]$FilePilotExe,
        [string]$DiffExe
    )

    if ($null -eq $Grid -or $Grid.IsDisposed) {
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Add Project'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(520, 128)

    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = 'Path'
    $lblPath.AutoSize = $true
    $lblPath.Location = New-Object System.Drawing.Point(12, 16)
    $dialog.Controls.Add($lblPath)

    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Width = 330
    $txtPath.Location = New-Object System.Drawing.Point(72, 12)
    $dialog.Controls.Add($txtPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'
    $btnBrowse.Width = 90
    $btnBrowse.Location = New-Object System.Drawing.Point(412, 10)
    $dialog.Controls.Add($btnBrowse)

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = 'Name'
    $lblName.AutoSize = $true
    $lblName.Location = New-Object System.Drawing.Point(12, 52)
    $dialog.Controls.Add($lblName)

    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Width = 430
    $txtName.Location = New-Object System.Drawing.Point(72, 48)
    $dialog.Controls.Add($txtName)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Width = 90
    $btnCancel.Location = New-Object System.Drawing.Point(286, 86)
    $btnCancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })
    $dialog.Controls.Add($btnCancel)

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = 'Add Project'
    $btnAdd.Width = 130
    $btnAdd.Location = New-Object System.Drawing.Point(380, 86)
    $dialog.Controls.Add($btnAdd)

    $btnNewProject = New-Object System.Windows.Forms.Button
    $btnNewProject.Text = 'New Project'
    $btnNewProject.Width = 130
    $btnNewProject.Location = New-Object System.Drawing.Point(152, 86)
    $dialog.Controls.Add($btnNewProject)

    $btnBrowse.Add_Click({
        $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDialog.Description = 'Select a project directory or parent location'
        if ($folderDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }

        $txtPath.Text = $folderDialog.SelectedPath
        if ([string]::IsNullOrWhiteSpace($txtName.Text)) {
            $txtName.Text = Get-DirectoryNameFromPath -Path $folderDialog.SelectedPath
        }
    })

    $tryAddProjectEntry = {
        param(
            [string]$EntryName,
            [string]$EntryPath
        )

        $entry = New-DirectoryEntry -Name $EntryName -Path $EntryPath -CmdColor ''
        if ($null -eq $entry) {
            return $false
        }

        foreach ($existingEntry in (Get-UniqueDirectoryEntriesFromGrid -Grid $Grid)) {
            if ([string]::Equals(([string]$existingEntry.Path).Trim(), $entry.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                [System.Windows.Forms.MessageBox]::Show("Project already exists: $($entry.Path)", 'ai_mux', 'OK', 'Information') | Out-Null
                return $false
            }
        }

        Add-ProjectEntryRow -Grid $Grid -Entry $entry
        $savedDirectories = Save-GridConfigToFile -Path $ConfigPath -Grid $Grid -AgentCmd $AgentCmd -TenxExe $TenxExe -FilePilotExe $FilePilotExe -DiffExe $DiffExe
        if ($null -eq $savedDirectories) {
            return $false
        }

        Start-DirtyStatusRefreshForGrid -Grid $Grid
        return $true
    }

    $btnAdd.Add_Click({
        $path = $txtPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($path)) {
            [System.Windows.Forms.MessageBox]::Show('Select a project path.', 'ai_mux', 'OK', 'Warning') | Out-Null
            return
        }

        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show("Directory not found: $path", 'ai_mux', 'OK', 'Error') | Out-Null
            return
        }

        if (-not (& $tryAddProjectEntry -EntryName $txtName.Text -EntryPath $path)) {
            return
        }

        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $btnNewProject.Add_Click({
        $location = $txtPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($location)) {
            [System.Windows.Forms.MessageBox]::Show('Select a parent location.', 'ai_mux', 'OK', 'Warning') | Out-Null
            return
        }

        if (-not (Test-Path -LiteralPath $location -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show("Directory not found: $location", 'ai_mux', 'OK', 'Error') | Out-Null
            return
        }

        $folderName = $txtName.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($folderName)) {
            [System.Windows.Forms.MessageBox]::Show('Enter a folder name for the new project.', 'ai_mux', 'OK', 'Warning') | Out-Null
            return
        }

        if ($folderName -eq '.' -or $folderName -eq '..') {
            [System.Windows.Forms.MessageBox]::Show('Folder name cannot be "." or "..".', 'ai_mux', 'OK', 'Warning') | Out-Null
            return
        }

        if ($folderName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            [System.Windows.Forms.MessageBox]::Show("Folder name contains invalid characters: $folderName", 'ai_mux', 'OK', 'Warning') | Out-Null
            return
        }

        $newProjectPath = Join-Path -Path $location -ChildPath $folderName
        foreach ($existingEntry in (Get-UniqueDirectoryEntriesFromGrid -Grid $Grid)) {
            if ([string]::Equals(([string]$existingEntry.Path).Trim(), $newProjectPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                [System.Windows.Forms.MessageBox]::Show("Project already exists: $newProjectPath", 'ai_mux', 'OK', 'Information') | Out-Null
                return
            }
        }

        if (Test-Path -LiteralPath $newProjectPath) {
            [System.Windows.Forms.MessageBox]::Show("Path already exists: $newProjectPath", 'ai_mux', 'OK', 'Information') | Out-Null
            return
        }

        try {
            New-Item -ItemType Directory -Path $newProjectPath | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to create directory '$newProjectPath'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
            return
        }

        try {
            $gitInitOutput = & git -C $newProjectPath init 2>&1
            $gitInitExitCode = $LASTEXITCODE
            if ($gitInitExitCode -ne 0) {
                $details = ($gitInitOutput | Out-String).Trim()
                if ([string]::IsNullOrWhiteSpace($details)) {
                    $details = 'Unknown git error.'
                }

                throw "git init failed with exit code $gitInitExitCode.`r`n$details"
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to initialize git repository in '$newProjectPath'.`r`n$($_.Exception.Message)", 'ai_mux', 'OK', 'Error') | Out-Null
            return
        }

        if (-not (& $tryAddProjectEntry -EntryName $folderName -EntryPath $newProjectPath)) {
            return
        }

        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $dialog.AcceptButton = $btnAdd
    $dialog.CancelButton = $btnCancel

    $owner = $Grid.FindForm()
    if ($null -ne $owner) {
        [void]$dialog.ShowDialog($owner)
    }
    else {
        [void]$dialog.ShowDialog()
    }
}

function Show-ProjectDeleteCellDialog {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$RowIndex,
        [string]$ConfigPath,
        [string]$AgentCmd,
        [string]$TenxExe,
        [string]$FilePilotExe,
        [string]$DiffExe
    )

    if ($null -eq $Grid -or $Grid.IsDisposed -or $RowIndex -lt 0 -or $RowIndex -ge $Grid.Rows.Count) {
        return
    }

    $row = $Grid.Rows[$RowIndex]
    if ($null -eq $row -or $row.IsNewRow) {
        return
    }

    $directory = [string]$row.Cells['Directory'].Value
    if ([string]::IsNullOrWhiteSpace($directory)) {
        return
    }

    $directory = $directory.Trim()
    $projectName = [string]$row.Cells['Name'].Value
    if ([string]::IsNullOrWhiteSpace($projectName)) {
        $projectName = Get-DirectoryNameFromPath -Path $directory
    }

    $currentCmdColor = if ($Grid.Columns.Contains('CmdColor')) { [string]$row.Cells['CmdColor'].Value } else { '' }
    $resolved = Resolve-CmdColorCode -Directory $directory -ColorCode $currentCmdColor
    $state = @{
        Bg = $resolved.Substring(0, 1)
        Text = $resolved.Substring(1, 1)
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Project: $projectName"
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.AutoSize = $true
    $dialog.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $dialog.Padding = New-Object System.Windows.Forms.Padding(10)

    $table = New-Object System.Windows.Forms.TableLayoutPanel
    $table.AutoSize = $true
    $table.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $table.ColumnCount = 2
    $table.RowCount = 3
    $table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $dialog.Controls.Add($table)

    $lblBg = New-Object System.Windows.Forms.Label
    $lblBg.Text = 'bg color'
    $lblBg.AutoSize = $true
    $lblBg.Margin = New-Object System.Windows.Forms.Padding(0, 7, 8, 4)
    $table.Controls.Add($lblBg, 0, 0)

    $flowBg = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowBg.AutoSize = $true
    $flowBg.WrapContents = $true
    $flowBg.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $table.Controls.Add($flowBg, 1, 0)

    $lblText = New-Object System.Windows.Forms.Label
    $lblText.Text = 'text color'
    $lblText.AutoSize = $true
    $lblText.Margin = New-Object System.Windows.Forms.Padding(0, 7, 8, 4)
    $table.Controls.Add($lblText, 0, 1)

    $flowText = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowText.AutoSize = $true
    $flowText.WrapContents = $true
    $flowText.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $table.Controls.Add($flowText, 1, 1)

    $lblRemove = New-Object System.Windows.Forms.Label
    $lblRemove.Text = 'remove'
    $lblRemove.AutoSize = $true
    $lblRemove.Margin = New-Object System.Windows.Forms.Padding(0, 7, 8, 0)
    $table.Controls.Add($lblRemove, 0, 2)

    $removePanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $removePanel.AutoSize = $true
    $removePanel.WrapContents = $false
    $table.Controls.Add($removePanel, 1, 2)

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = 'Remove Project'
    $btnRemove.Width = 130
    $btnRemove.Height = 28
    $btnRemove.BackColor = [System.Drawing.Color]::FromArgb(198, 40, 40)
    $btnRemove.ForeColor = [System.Drawing.Color]::White
    $btnRemove.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $removePanel.Controls.Add($btnRemove)

    $bgButtons = New-Object 'System.Collections.Generic.List[System.Windows.Forms.Button]'
    $textButtons = New-Object 'System.Collections.Generic.List[System.Windows.Forms.Button]'

    $persistConfig = {
        $null = Save-GridConfigToFile -Path $ConfigPath -Grid $Grid -AgentCmd $AgentCmd -TenxExe $TenxExe -FilePilotExe $FilePilotExe -DiffExe $DiffExe
    }

    $applyCmdColor = {
        if ($row.Index -lt 0) {
            $dialog.Close()
            return
        }

        $newCmdColor = Resolve-CmdColorCode -Directory $directory -BackgroundColor ([string]$state.Bg) -TextColor ([string]$state.Text)
        $state.Bg = $newCmdColor.Substring(0, 1)
        $state.Text = $newCmdColor.Substring(1, 1)

        if ($Grid.Columns.Contains('CmdColor')) {
            $row.Cells['CmdColor'].Value = $newCmdColor
        }

        Set-XCellColorFromCmdColor -Row $row -CmdColor $newCmdColor
        & $persistConfig
    }

    $refreshColorButtons = {
        $selectedTextPreview = Get-ConsoleColorFromHexDigit -HexDigit ([string]$state.Text)[0]
        foreach ($btn in $bgButtons) {
            $digit = [string]$btn.Tag
            $backgroundColor = Get-ConsoleColorFromHexDigit -HexDigit $digit[0]
            $btn.BackColor = $backgroundColor
            $btn.ForeColor = $selectedTextPreview
            $btn.FlatAppearance.BorderSize = if ($digit -eq [string]$state.Bg) { 3 } else { 1 }
        }

        $selectedBackground = Get-ConsoleColorFromHexDigit -HexDigit ([string]$state.Bg)[0]
        foreach ($btn in $textButtons) {
            $digit = [string]$btn.Tag
            $foregroundColor = Get-ConsoleColorFromHexDigit -HexDigit $digit[0]
            if ($selectedBackground.ToArgb() -eq $foregroundColor.ToArgb()) {
                $foregroundColor = Get-ReadableTextColor -BackgroundColor $selectedBackground
            }

            $btn.BackColor = $selectedBackground
            $btn.ForeColor = $foregroundColor
            $btn.FlatAppearance.BorderSize = if ($digit -eq [string]$state.Text) { 3 } else { 1 }
        }
    }

    foreach ($digit in Get-CmdColorDigits) {
        $btnBg = New-Object System.Windows.Forms.Button
        $btnBg.Text = $digit
        $btnBg.Tag = $digit
        $btnBg.Width = 28
        $btnBg.Height = 28
        $btnBg.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnBg.FlatAppearance.BorderColor = [System.Drawing.Color]::Black
        $btnBg.Margin = New-Object System.Windows.Forms.Padding(1)
        $btnBg.Add_Click({
            $state.Bg = [string]$this.Tag
            & $applyCmdColor
            & $refreshColorButtons
        })
        $flowBg.Controls.Add($btnBg)
        $bgButtons.Add($btnBg) | Out-Null

        $btnText = New-Object System.Windows.Forms.Button
        $btnText.Text = $digit
        $btnText.Tag = $digit
        $btnText.Width = 28
        $btnText.Height = 28
        $btnText.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnText.FlatAppearance.BorderColor = [System.Drawing.Color]::Black
        $btnText.Margin = New-Object System.Windows.Forms.Padding(1)
        $btnText.Add_Click({
            $state.Text = [string]$this.Tag
            & $applyCmdColor
            & $refreshColorButtons
        })
        $flowText.Controls.Add($btnText)
        $textButtons.Add($btnText) | Out-Null
    }

    $btnRemove.Add_Click({
        if ($row.Index -ge 0) {
            $Grid.Rows.Remove($row)
            & $persistConfig
        }

        $dialog.Close()
    })

    & $refreshColorButtons
    $owner = $Grid.FindForm()
    if ($null -ne $owner) {
        [void]$dialog.ShowDialog($owner)
    }
    else {
        [void]$dialog.ShowDialog()
    }
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

function Resize-FormHeightToFitGridRows {
    param(
        [System.Windows.Forms.Form]$Form,
        [System.Windows.Forms.DataGridView]$Grid
    )

    if ($null -eq $Form -or $Form.IsDisposed -or $null -eq $Grid -or $Grid.IsDisposed) {
        return
    }

    $rowHeights = $Grid.Rows.GetRowsHeight([System.Windows.Forms.DataGridViewElementStates]::Visible)
    $headerHeight = if ($Grid.ColumnHeadersVisible) { $Grid.ColumnHeadersHeight } else { 0 }
    $desiredGridHeight = $rowHeights + $headerHeight + 2
    if ($desiredGridHeight -lt 120) {
        $desiredGridHeight = 120
    }

    $currentGridHeight = $Grid.ClientSize.Height
    if ($currentGridHeight -le 0) {
        return
    }

    $targetFormHeight = $Form.Height + ($desiredGridHeight - $currentGridHeight)
    $minimumHeight = if ($Form.MinimumSize.Height -gt 0) { $Form.MinimumSize.Height } else { 220 }
    if ($targetFormHeight -lt $minimumHeight) {
        $targetFormHeight = $minimumHeight
    }

    $workingArea = [System.Windows.Forms.Screen]::FromControl($Form).WorkingArea
    $maxHeight = [Math]::Max($minimumHeight, $workingArea.Height - 20)
    if ($targetFormHeight -gt $maxHeight) {
        $targetFormHeight = $maxHeight
    }

    $Form.Height = [int]$targetFormHeight
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ai_mux'
$form.Width = 550
$form.Height = 275
$form.StartPosition = 'CenterScreen'

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount = 2
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36))) | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
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
$hint.Text = 'Rows show one directory each by name. Click o for options or + to add.'
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
$grid.EnableHeadersVisualStyles = $false
$split.Panel1.Controls.Add($topPanel)
$split.Panel2.Controls.Add($grid)
Resize-TopPanelToContent -Panel $topPanel -Split $split
$form.Add_Shown({
    Resize-TopPanelToContent -Panel $topPanel -Split $split
    Resize-FormHeightToFitGridRows -Form $form -Grid $grid
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

$colCmdColor = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colCmdColor.Name = 'CmdColor'
$colCmdColor.HeaderText = 'CmdColor'
$colCmdColor.Visible = $false
$grid.Columns.Add($colCmdColor) | Out-Null

$colIsAddRow = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colIsAddRow.Name = 'IsAddRow'
$colIsAddRow.HeaderText = 'IsAddRow'
$colIsAddRow.Visible = $false
$grid.Columns.Add($colIsAddRow) | Out-Null

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
$colMessage.HeaderText = 'Push'
$colMessage.Width = 70
$colMessage.ReadOnly = $false
$grid.Columns.Add($colMessage) | Out-Null

$gridButtonColors = @{
    'AI' = '#7B1FA2'
    '10x' = '#2E7D32'
    'Diff' = '#66BB6A'
    'Pull' = '#1565C0'
    'Dirty' = '#9E9E9E'
    'Exe' = '#EF6C00'
    'Dbg' = '#6A1B9A'
    'Release' = '#8B0000'
    'Cmd' = '#000000'
    'Folder' = '#F3E5AB'
    'X' = '#C62828'
}

foreach ($name in @('AI', '10x', 'Diff', 'Dirty', 'Pull', 'Exe', 'Dbg', 'Release', 'Cmd', 'Folder', 'X')) {
    $col = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $displayName = if ($name -eq 'Release') { 'Build' } elseif ($name -eq 'Exe') { 'Run' } elseif ($name -eq 'X') { 'o' } elseif ($name -eq 'Dirty') { '?' } elseif ($name -eq 'Dbg') { 'Dbg' } else { $name }
    $col.Name = $name
    $col.HeaderText = if ($name -eq 'X') { '' } elseif ($name -eq 'Dirty') { 'Dirty' } else { $displayName }
    $col.Text = $displayName
    $col.UseColumnTextForButtonValue = ($name -ne 'Exe' -and $name -ne 'Dbg' -and $name -ne 'Release')
    if ($name -eq 'X') {
        $col.Width = 15
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
$grid.Columns['Pull'].DisplayIndex = 7
$grid.Columns['Release'].DisplayIndex = 8
$grid.Columns['Exe'].DisplayIndex = 9
$grid.Columns['Dbg'].DisplayIndex = 10
$grid.Columns['Cmd'].DisplayIndex = 11
$grid.Columns['Folder'].DisplayIndex = 12
$dirtyHeaderColor = [System.Drawing.ColorTranslator]::FromHtml('#9E9E9E')
$grid.Columns['Dirty'].HeaderCell.Style.BackColor = $dirtyHeaderColor
$grid.Columns['Dirty'].HeaderCell.Style.ForeColor = [System.Drawing.Color]::White
$grid.Columns['Dirty'].HeaderCell.Style.SelectionBackColor = $dirtyHeaderColor
$grid.Columns['Dirty'].HeaderCell.Style.SelectionForeColor = [System.Drawing.Color]::White
$grid.Columns['Dirty'].HeaderCell.ToolTipText = 'Refresh Dirty for all rows'
$pullHeaderColor = [System.Drawing.ColorTranslator]::FromHtml('#1565C0')
$grid.Columns['Pull'].HeaderCell.Style.BackColor = $pullHeaderColor
$grid.Columns['Pull'].HeaderCell.Style.ForeColor = [System.Drawing.Color]::White
$grid.Columns['Pull'].HeaderCell.Style.SelectionBackColor = $pullHeaderColor
$grid.Columns['Pull'].HeaderCell.Style.SelectionForeColor = [System.Drawing.Color]::White
$grid.Columns['Pull'].HeaderCell.ToolTipText = 'Run git pull for all rows'

function Invoke-GitCommitFromRow {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$RowIndex
    )

    if ($null -eq $Grid -or $RowIndex -lt 0 -or $RowIndex -ge $Grid.Rows.Count) {
        return
    }

    if (Test-IsAddProjectRow -Row $Grid.Rows[$RowIndex]) {
        return
    }

    $directory = [string]$Grid.Rows[$RowIndex].Cells['Directory'].Value
    if ([string]::IsNullOrWhiteSpace($directory)) {
        return
    }

    $message = [string]$Grid.Rows[$RowIndex].Cells['Message'].Value
    $cmdColor = if ($Grid.Columns.Contains('CmdColor')) { [string]$Grid.Rows[$RowIndex].Cells['CmdColor'].Value } else { '' }
    if (Start-GitCommitInDirectory -Directory $directory.Trim() -Message $message -CmdColor $cmdColor) {
        $Grid.Rows[$RowIndex].Cells['Message'].Value = ''
        Set-DirtyCellState -Row $Grid.Rows[$RowIndex] -State 'Clean'

        if ($Grid.Columns.Contains('Name')) {
            $Grid.ClearSelection()
            $Grid.Rows[$RowIndex].Selected = $true
            $Grid.CurrentCell = $Grid.Rows[$RowIndex].Cells['Name']
        }
    }
}

function Start-GitPullForAllRows {
    param(
        [System.Windows.Forms.DataGridView]$Grid
    )

    if ($null -eq $Grid -or $Grid.IsDisposed) {
        return
    }

    $directories = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) {
            continue
        }

        if (Test-IsAddProjectRow -Row $row) {
            continue
        }

        $directory = [string]$row.Cells['Directory'].Value
        if ([string]::IsNullOrWhiteSpace($directory)) {
            continue
        }

        $trimmedDirectory = $directory.Trim()
        if (-not $directories.Add($trimmedDirectory)) {
            continue
        }

        $cmdColor = if ($Grid.Columns.Contains('CmdColor')) { [string]$row.Cells['CmdColor'].Value } else { '' }
        Start-GitPullInDirectory -Directory $trimmedDirectory -CmdColor $cmdColor | Out-Null
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
            $entryCmdBgColor = if ($entry.PSObject.Properties['CmdBgColor']) { [string]$entry.CmdBgColor } else { '' }
            $entryCmdTextColor = if ($entry.PSObject.Properties['CmdTextColor']) { [string]$entry.CmdTextColor } else { '' }
            $entryCmdColor = if ($entry.PSObject.Properties['CmdColor']) { [string]$entry.CmdColor } else { '' }
            $normalized = New-DirectoryEntry -Name ([string]$entry.Name) -Path ([string]$entry.Path) -CmdBgColor $entryCmdBgColor -CmdTextColor $entryCmdTextColor -CmdColor $entryCmdColor
        }

        if ($null -eq $normalized) {
            continue
        }

        Add-ProjectEntryRow -Grid $Grid -Entry $normalized
    }

    Add-AddProjectRow -Grid $Grid
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
        $entry = New-DirectoryEntry -Name '' -Path $selectedPath -CmdColor ''
        if ($null -eq $entry) {
            return
        }

        Add-ProjectEntryRow -Grid $grid -Entry $entry
    }
})

$btnReload.Add_Click({
    Load-IntoUi
})

$btnSave.Add_Click({
    $directories = Save-GridConfigToFile -Path $ConfigPath -Grid $grid -AgentCmd $txtAgent.Text.Trim() -TenxExe $txtTenx.Text.Trim() -FilePilotExe $txtFilePilot.Text.Trim() -DiffExe $txtDiff.Text.Trim()
    if ($null -eq $directories) {
        return
    }

    Refresh-Grid -Grid $grid -Directories $directories
    [System.Windows.Forms.MessageBox]::Show("Saved: $ConfigPath", 'ai_mux') | Out-Null
})

$grid.Add_ColumnHeaderMouseClick({
    param($sender, $e)

    if ($e.ColumnIndex -lt 0) {
        return
    }

    switch ($grid.Columns[$e.ColumnIndex].Name) {
        'Dirty' {
            Start-DirtyStatusRefreshForGrid -Grid $grid
        }
        'Pull' {
            Start-GitPullForAllRows -Grid $grid
        }
    }
})

$grid.Add_CellContentClick({
    param($sender, $e)

    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) {
        return
    }

    $columnName = $grid.Columns[$e.ColumnIndex].Name
    $row = $grid.Rows[$e.RowIndex]
    $isAddProjectRow = Test-IsAddProjectRow -Row $row

    if ($columnName -eq 'X') {
        if ($isAddProjectRow) {
            Show-ProjectAddCellDialog -Grid $grid -ConfigPath $ConfigPath -AgentCmd $txtAgent.Text.Trim() -TenxExe $txtTenx.Text.Trim() -FilePilotExe $txtFilePilot.Text.Trim() -DiffExe $txtDiff.Text.Trim()
            return
        }

        Show-ProjectDeleteCellDialog -Grid $grid -RowIndex $e.RowIndex -ConfigPath $ConfigPath -AgentCmd $txtAgent.Text.Trim() -TenxExe $txtTenx.Text.Trim() -FilePilotExe $txtFilePilot.Text.Trim() -DiffExe $txtDiff.Text.Trim()
        return
    }

    if ($isAddProjectRow) {
        return
    }

    $directory = [string]$row.Cells['Directory'].Value
    $cmdColor = if ($grid.Columns.Contains('CmdColor')) { [string]$row.Cells['CmdColor'].Value } else { '' }

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
            Start-CmdInDirectory -Directory $directory -Command $agentCmd -CmdColor $cmdColor
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
        'Pull' {
            Start-GitPullInDirectory -Directory $directory -CmdColor $cmdColor
        }
        'Cmd' {
            Start-CmdInDirectory -Directory $directory -Command '' -CmdColor $cmdColor
        }
        'Exe' {
            Start-RunBatInDirectory -Directory $directory -CmdColor $cmdColor
        }
        'Dbg' {
            Start-DebugBatInDirectory -Directory $directory -CmdColor $cmdColor
        }
        'Release' {
            Start-BuildReleaseBatInDirectory -Directory $directory -CmdColor $cmdColor
        }
        'Folder' {
            Open-FolderInFilePilot -Directory $directory -FilePilotExe $txtFilePilot.Text
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
