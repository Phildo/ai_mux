param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.txt')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

function Get-RunBatPath {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        return $null
    }

    $runBat = Join-Path -Path $Directory.Trim() -ChildPath 'run.bat'
    if (Test-Path -LiteralPath $runBat -PathType Leaf) {
        return $runBat
    }

    return $null
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

function Set-ExeButtonCellValue {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [string]$Directory
    )

    if ($null -eq $Row -or [string]::IsNullOrWhiteSpace($Directory)) {
        return
    }

    $Row.Cells['Exe'].Value = if (Get-RunBatPath -Directory $Directory) { 'Exe' } else { '' }
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
$form.Height = 420
$form.StartPosition = 'CenterScreen'

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$split.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel1
$split.IsSplitterFixed = $true
$split.SplitterWidth = 4
$split.Panel1MinSize = 100
$form.Controls.Add($split)

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

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoSizeRowsMode = 'None'
$grid.ReadOnly = $true
$split.Panel1.Controls.Add($topPanel)
$split.Panel2.Controls.Add($grid)
Resize-TopPanelToContent -Panel $topPanel -Split $split
$form.Add_Shown({
    Resize-TopPanelToContent -Panel $topPanel -Split $split
})
$form.Add_Resize({
    Resize-TopPanelToContent -Panel $topPanel -Split $split
})

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

$gridButtonColors = @{
    'AI' = '#7B1FA2'
    '10x' = '#2E7D32'
    'Git' = '#1976D2'
    'Diff' = '#66BB6A'
    'Exe' = '#EF6C00'
    'Cmd' = '#000000'
    'Folder' = '#F3E5AB'
    'X' = '#C62828'
}

foreach ($name in @('AI', '10x', 'Git', 'Diff', 'Exe', 'Cmd', 'Folder', 'X')) {
    $col = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $col.Name = $name
    $col.HeaderText = if ($name -eq 'X') { 'x' } else { $name }
    $col.Text = if ($name -eq 'X') { 'x' } else { $name }
    $col.UseColumnTextForButtonValue = ($name -ne 'Exe')
    if ($name -eq 'X') {
        $col.Width = 40
    }
    elseif ($name -eq 'Folder') {
        $col.Width = 40
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
        Set-ExeButtonCellValue -Row $Grid.Rows[$rowIndex] -Directory $normalized.Path
    }
}

function Load-IntoUi {
    $config = Load-Config -Path $ConfigPath
    $txtAgent.Text = $config.AgentCmd
    $txtTenx.Text = $config.TenxExe
    $txtFilePilot.Text = $config.FilePilotExe
    $txtDiff.Text = $config.DiffExe
    Refresh-Grid -Grid $grid -Directories $config.Directories
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
        Set-ExeButtonCellValue -Row $grid.Rows[$rowIndex] -Directory $selectedPath
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
        'Git' {
            Start-CmdInDirectory -Directory $directory -Command 'git add . && git commit -m "stuff" && git pull'
        }
        'Diff' {
            Open-InDiff -Directory $directory -DiffExe $txtDiff.Text
        }
        'Cmd' {
            Start-CmdInDirectory -Directory $directory -Command ''
        }
        'Exe' {
            Start-RunBatInDirectory -Directory $directory
        }
        'Folder' {
            Open-FolderInFilePilot -Directory $directory -FilePilotExe $txtFilePilot.Text
        }
        'X' {
            $grid.Rows.RemoveAt($e.RowIndex)
        }
    }
})

Load-IntoUi

[void]$form.ShowDialog()
