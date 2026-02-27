param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.txt')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Load-Config {
    param([string]$Path)

    $config = [ordered]@{
        AgentCmd      = 'codex --yolo'
        TenxExe       = '10x.exe'
        FilePilotExe  = 'FilePilot.exe'
        Directories   = New-Object System.Collections.Generic.List[string]
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
            $config.Directories.Add($line)
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
        [string[]]$Directories
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# ai_mux config')
    $lines.Add('AGENT_CMD=' + $AgentCmd)
    $lines.Add('TENX_EXE=' + $TenxExe)
    $lines.Add('FILEPILOT_EXE=' + $FilePilotExe)
    $lines.Add('[DIRS]')

    foreach ($dir in $Directories) {
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            $lines.Add($dir.Trim())
        }
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

function Get-UniqueDirectoriesFromGrid {
    param([System.Windows.Forms.DataGridView]$Grid)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[string]

    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) {
            continue
        }

        $value = [string]$row.Cells['Directory'].Value
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $dir = $value.Trim()
        if ($seen.Add($dir)) {
            $result.Add($dir)
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
$form.Width = 1100
$form.Height = 640
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
$txtAgent.Width = 460
$txtAgent.Location = New-Object System.Drawing.Point(90, 8)
$topPanel.Controls.Add($txtAgent)

$lblTenx = New-Object System.Windows.Forms.Label
$lblTenx.Text = '10x exe:'
$lblTenx.AutoSize = $true
$lblTenx.Location = New-Object System.Drawing.Point(10, 44)
$topPanel.Controls.Add($lblTenx)

$txtTenx = New-Object System.Windows.Forms.TextBox
$txtTenx.Width = 460
$txtTenx.Location = New-Object System.Drawing.Point(90, 40)
$topPanel.Controls.Add($txtTenx)

$btnBrowseTenx = New-Object System.Windows.Forms.Button
$btnBrowseTenx.Text = 'Browse...'
$btnBrowseTenx.Width = 90
$btnBrowseTenx.Location = New-Object System.Drawing.Point(560, 38)
$topPanel.Controls.Add($btnBrowseTenx)

$lblFilePilot = New-Object System.Windows.Forms.Label
$lblFilePilot.Text = 'FilePilot exe:'
$lblFilePilot.AutoSize = $true
$lblFilePilot.Location = New-Object System.Drawing.Point(10, 76)
$topPanel.Controls.Add($lblFilePilot)

$txtFilePilot = New-Object System.Windows.Forms.TextBox
$txtFilePilot.Width = 460
$txtFilePilot.Location = New-Object System.Drawing.Point(90, 72)
$topPanel.Controls.Add($txtFilePilot)

$btnBrowseFilePilot = New-Object System.Windows.Forms.Button
$btnBrowseFilePilot.Text = 'Browse...'
$btnBrowseFilePilot.Width = 90
$btnBrowseFilePilot.Location = New-Object System.Drawing.Point(560, 70)
$topPanel.Controls.Add($btnBrowseFilePilot)

$btnAddDir = New-Object System.Windows.Forms.Button
$btnAddDir.Text = 'Add Folder'
$btnAddDir.Width = 95
$btnAddDir.Location = New-Object System.Drawing.Point(670, 8)
$topPanel.Controls.Add($btnAddDir)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = 'Reload'
$btnReload.Width = 95
$btnReload.Location = New-Object System.Drawing.Point(770, 8)
$topPanel.Controls.Add($btnReload)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save Config'
$btnSave.Width = 95
$btnSave.Location = New-Object System.Drawing.Point(870, 8)
$topPanel.Controls.Add($btnSave)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Rows show one directory each. Click Remove to delete a row.'
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
$colDirectory.AutoSizeMode = 'Fill'
$grid.Columns.Add($colDirectory) | Out-Null

foreach ($name in @('AI', '10x', 'Git', 'Cmd', 'Folder', 'Remove')) {
    $col = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $col.Name = $name
    $col.HeaderText = $name
    $col.Text = $name
    $col.UseColumnTextForButtonValue = $true
    if ($name -eq 'Remove') {
        $col.Width = 80
    }
    elseif ($name -eq 'Folder') {
        $col.Width = 80
    }
    else {
        $col.Width = 70
    }
    $grid.Columns.Add($col) | Out-Null
}

function Refresh-Grid {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [string[]]$Directories
    )

    $Grid.Rows.Clear()
    foreach ($dir in $Directories) {
        if ([string]::IsNullOrWhiteSpace($dir)) {
            continue
        }
        [void]$Grid.Rows.Add($dir.Trim())
    }
}

function Load-IntoUi {
    $config = Load-Config -Path $ConfigPath
    $txtAgent.Text = $config.AgentCmd
    $txtTenx.Text = $config.TenxExe
    $txtFilePilot.Text = $config.FilePilotExe
    Refresh-Grid -Grid $grid -Directories $config.Directories
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Save-Config -Path $ConfigPath -AgentCmd 'codex --yolo' -TenxExe '10x.exe' -FilePilotExe 'FilePilot.exe' -Directories @()
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

$btnAddDir.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select a directory to add'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        [void]$grid.Rows.Add($dialog.SelectedPath)
    }
})

$btnReload.Add_Click({
    Load-IntoUi
})

$btnSave.Add_Click({
    $directories = Get-UniqueDirectoriesFromGrid -Grid $grid
    Save-Config -Path $ConfigPath -AgentCmd $txtAgent.Text.Trim() -TenxExe $txtTenx.Text.Trim() -FilePilotExe $txtFilePilot.Text.Trim() -Directories $directories
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
            Start-CmdInDirectory -Directory $directory -Command 'git add . && git commit -m "stuff"'
        }
        'Cmd' {
            Start-CmdInDirectory -Directory $directory -Command ''
        }
        'Folder' {
            Open-FolderInFilePilot -Directory $directory -FilePilotExe $txtFilePilot.Text
        }
        'Remove' {
            $grid.Rows.RemoveAt($e.RowIndex)
        }
    }
})

Load-IntoUi

[void]$form.ShowDialog()
