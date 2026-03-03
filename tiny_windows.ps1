param(
    [string[]]$Titles = @(),
    [string]$CmdColor = '',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

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
        default { return [System.Drawing.Color]::FromArgb(232, 232, 232) }
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

function Get-OffsetColor {
    param(
        [System.Drawing.Color]$Color,
        [int]$Offset
    )

    $r = [Math]::Min(255, [Math]::Max(0, $Color.R + $Offset))
    $g = [Math]::Min(255, [Math]::Max(0, $Color.G + $Offset))
    $b = [Math]::Min(255, [Math]::Max(0, $Color.B + $Offset))
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

if ($args.Count -gt 0) {
    $Titles += $args
}

if ($Titles.Count -eq 0) {
    $Titles = @("tiny_window")
}

$resolvedCmdColor = Normalize-CmdColorCode -ColorCode $CmdColor
if ([string]::IsNullOrWhiteSpace($resolvedCmdColor)) {
    $resolvedCmdColor = '70'
}

$titleBarBackColor = Get-ConsoleColorFromHexDigit -HexDigit $resolvedCmdColor[0]
$titleBarTextColor = Get-ConsoleColorFromHexDigit -HexDigit $resolvedCmdColor[1]
if ($titleBarBackColor.ToArgb() -eq $titleBarTextColor.ToArgb()) {
    $titleBarTextColor = Get-ReadableTextColor -BackgroundColor $titleBarBackColor
}

$windowBackColor = Get-OffsetColor -Color $titleBarBackColor -Offset 16
$closeHoverBackColor = Get-OffsetColor -Color $titleBarBackColor -Offset 28

if ($DryRun) {
    Write-Output ("Dry run: would open {0} window(s): {1} (color {2})" -f $Titles.Count, ($Titles -join ", "), $resolvedCmdColor)
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeDrag {
    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
}
"@

[System.Windows.Forms.Application]::EnableVisualStyles()

$titleHeight = 28
$startX = 40
$startY = 40
$offset = 24
$script:openWindowCount = $Titles.Count

$forms = New-Object System.Collections.Generic.List[System.Windows.Forms.Form]

for ($i = 0; $i -lt $Titles.Count; $i++) {
    $title = $Titles[$i]

    $textWidth = [Math]::Max(90, ($title.Length * 8))
    $windowWidth = $textWidth + 48

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Size = New-Object System.Drawing.Size($windowWidth, $titleHeight)
    $form.Location = New-Object System.Drawing.Point(($startX + ($offset * $i)), ($startY + ($offset * $i)))
    $form.BackColor = $windowBackColor
    $form.ShowInTaskbar = $false

    $titleBar = New-Object System.Windows.Forms.Panel
    $titleBar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $titleBar.Padding = New-Object System.Windows.Forms.Padding(8, 4, 4, 4)
    $titleBar.BackColor = $titleBarBackColor

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = $title
    $nameLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $nameLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $nameLabel.ForeColor = $titleBarTextColor

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "x"
    $closeButton.Dock = [System.Windows.Forms.DockStyle]::Right
    $closeButton.Width = 22
    $closeButton.TabStop = $false
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.FlatAppearance.BorderSize = 0
    $closeButton.FlatAppearance.MouseOverBackColor = $closeHoverBackColor
    $closeButton.BackColor = $titleBarBackColor
    $closeButton.ForeColor = $titleBarTextColor

    $dragWindow = {
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $targetForm = $null
            if ($sender -is [System.Windows.Forms.Control]) {
                $targetForm = $sender.FindForm()
            }

            if ($null -ne $targetForm) {
                [NativeDrag]::ReleaseCapture() | Out-Null
                [NativeDrag]::SendMessage($targetForm.Handle, 0xA1, 0x2, 0) | Out-Null
            }
        }
    }

    $titleBar.add_MouseDown($dragWindow)
    $nameLabel.add_MouseDown($dragWindow)
    $closeButton.add_Click({
        param($sender, $e)
        if ($sender -is [System.Windows.Forms.Control]) {
            $ownerForm = $sender.FindForm()
            if ($null -ne $ownerForm) {
                $ownerForm.Close()
            }
        }
    })

    $titleBar.Controls.Add($nameLabel)
    $titleBar.Controls.Add($closeButton)
    $form.Controls.Add($titleBar)

    $form.add_FormClosed({
        $script:openWindowCount--
        if ($script:openWindowCount -le 0) {
            [System.Windows.Forms.Application]::ExitThread()
        }
    })

    [void]$forms.Add($form)
}

$appContext = New-Object System.Windows.Forms.ApplicationContext
foreach ($form in $forms) {
    $form.Show()
}

[System.Windows.Forms.Application]::Run($appContext)
