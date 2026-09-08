param(
    [string]$SessionFile = "",
    [int]$RefreshMilliseconds = 1500,
    [int]$MaxTailMB = 16
)

# Codex Cache Monitor for Windows PowerShell 5.1+
# - Reads Codex rollout JSONL files only.
# - Does not create services, scheduled tasks, background jobs, or child processes.
# - Uses a WinForms UI timer on the main thread. Closing the window ends the process.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# Single-instance guard. If the process exits/crashes, Windows releases the mutex automatically.
$mutex = New-Object System.Threading.Mutex($false, 'Local\CodexCacheMonitor.SingleInstance')
$mutexHeld = $false
try {
    try {
        $mutexHeld = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $mutexHeld = $true
    }

    if (-not $mutexHeld) {
        [System.Windows.Forms.MessageBox]::Show(
            'Codex Cache Monitor is already running.',
            'Codex Cache Monitor',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        exit 0
    }

    function Get-PropertyValue {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    }

    function Convert-ToInt64 {
        param($Value)
        if ($null -eq $Value) { return [int64]0 }
        try { return [Convert]::ToInt64($Value) }
        catch { return [int64]0 }
    }

    function Get-UsageValue {
        param($Usage, [string]$Name)
        return Convert-ToInt64 (Get-PropertyValue $Usage $Name)
    }

    function Format-TokenCount {
        param([int64]$Value)
        return ('{0:N0}' -f $Value)
    }

    function Format-Percent {
        param([double]$Value)
        if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return '—' }
        return ('{0:N2}%' -f $Value)
    }

    function Get-CodexHome {
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            return [Environment]::ExpandEnvironmentVariables($env:CODEX_HOME)
        }
        return (Join-Path $HOME '.codex')
    }

    function Get-LatestRolloutFile {
        param([string]$CodexHome)

        $sessionsRoot = Join-Path $CodexHome 'sessions'
        if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
            return $null
        }

        $candidates = @()
        foreach ($offset in @(0, -1, 1, -2)) {
            $date = (Get-Date).AddDays($offset)
            $dayDir = Join-Path $sessionsRoot ($date.ToString('yyyy\MM\dd'))
            if (Test-Path -LiteralPath $dayDir -PathType Container) {
                try {
                    $candidates += Get-ChildItem -LiteralPath $dayDir -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue
                }
                catch { }
            }
        }

        if ($candidates.Count -eq 0) {
            # Fallback for unusual clocks/timezones or older sessions. This is used only when
            # no rollout is found in recent day folders.
            try {
                $candidates = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue)
            }
            catch {
                $candidates = @()
            }
        }

        if ($candidates.Count -eq 0) { return $null }
        return ($candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    }

    function Find-LatestTokenCountLine {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [int]$TailLimitMB = 16
        )

        $fileStream = $null
        try {
            $fileStream = New-Object System.IO.FileStream(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )

            $length = $fileStream.Length
            if ($length -le 0) { return $null }

            $blockSize = 1024 * 1024
            $maxBytes = [Math]::Max(1, $TailLimitMB) * 1024 * 1024
            $position = $length
            $bytesCollected = 0
            $text = ''
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            $tokenPattern = '"type"\s*:\s*"token_count"'

            while ($position -gt 0 -and $bytesCollected -lt $maxBytes) {
                $remainingBudget = $maxBytes - $bytesCollected
                $readSize = [int][Math]::Min([Math]::Min($blockSize, $position), $remainingBudget)
                if ($readSize -le 0) { break }

                $position -= $readSize
                [void]$fileStream.Seek($position, [System.IO.SeekOrigin]::Begin)
                $buffer = New-Object byte[] $readSize
                $read = $fileStream.Read($buffer, 0, $readSize)
                if ($read -le 0) { break }

                $chunk = $utf8.GetString($buffer, 0, $read)
                $text = $chunk + $text
                $bytesCollected += $read

                $matches = [regex]::Matches($text, $tokenPattern)
                if ($matches.Count -gt 0) {
                    $match = $matches[$matches.Count - 1]
                    $lineStart = $text.LastIndexOf("`n", $match.Index)

                    # If the matching line starts before our current buffer, read one more block.
                    if ($lineStart -lt 0 -and $position -gt 0 -and $bytesCollected -lt $maxBytes) {
                        continue
                    }

                    if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart += 1 }
                    $lineEnd = $text.IndexOf("`n", $match.Index)
                    if ($lineEnd -lt 0) { $lineEnd = $text.Length }

                    $line = $text.Substring($lineStart, $lineEnd - $lineStart).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        return $line
                    }
                }
            }

            return $null
        }
        catch {
            return $null
        }
        finally {
            if ($null -ne $fileStream) { $fileStream.Dispose() }
        }
    }

    function Get-TokenCountPayload {
        param($Event)

        if ($null -eq $Event) { return $null }

        $eventType = Get-PropertyValue $Event 'type'
        if ($eventType -eq 'token_count') { return $Event }

        $payload = Get-PropertyValue $Event 'payload'
        if ($null -ne $payload) {
            $payloadType = Get-PropertyValue $payload 'type'
            if ($payloadType -eq 'token_count') { return $payload }
        }

        return $null
    }

    function Convert-TokenCountLine {
        param([string]$Line)

        if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
        try {
            $event = $Line | ConvertFrom-Json
        }
        catch {
            return $null
        }

        $payload = Get-TokenCountPayload $event
        if ($null -eq $payload) { return $null }

        $info = Get-PropertyValue $payload 'info'
        if ($null -eq $info) { $info = $payload }

        $totalUsage = Get-PropertyValue $info 'total_token_usage'
        if ($null -eq $totalUsage) { $totalUsage = Get-PropertyValue $payload 'total_token_usage' }

        $lastUsage = Get-PropertyValue $info 'last_token_usage'
        if ($null -eq $lastUsage) { $lastUsage = Get-PropertyValue $payload 'last_token_usage' }

        $contextWindow = Get-PropertyValue $info 'model_context_window'
        if ($null -eq $contextWindow) { $contextWindow = Get-PropertyValue $payload 'model_context_window' }

        if ($null -eq $totalUsage -and $null -eq $lastUsage) { return $null }

        return [PSCustomObject]@{
            TotalUsage    = $totalUsage
            LastUsage     = $lastUsage
            ContextWindow = Convert-ToInt64 $contextWindow
            Timestamp     = Get-PropertyValue $event 'timestamp'
        }
    }

    function Convert-UsageToMetrics {
        param($Usage)

        if ($null -eq $Usage) {
            return [PSCustomObject]@{
                Input = 0L; Cached = 0L; Uncached = 0L; Output = 0L; Reasoning = 0L; Total = 0L; HitRate = [double]::NaN
            }
        }

        $input = Get-UsageValue $Usage 'input_tokens'
        $cached = Get-UsageValue $Usage 'cached_input_tokens'
        $output = Get-UsageValue $Usage 'output_tokens'
        $reasoning = Get-UsageValue $Usage 'reasoning_output_tokens'
        $total = Get-UsageValue $Usage 'total_tokens'
        $uncached = [Math]::Max([int64]0, $input - $cached)
        $hitRate = if ($input -gt 0) { 100.0 * $cached / $input } else { [double]::NaN }

        if ($total -le 0) { $total = $input + $output }

        return [PSCustomObject]@{
            Input     = $input
            Cached    = $cached
            Uncached  = $uncached
            Output    = $output
            Reasoning = $reasoning
            Total     = $total
            HitRate   = $hitRate
        }
    }

    # ---------- UI ----------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Codex Cache Monitor'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(790, 680)
    $form.MinimumSize = New-Object System.Drawing.Size(720, 630)
    $form.MaximizeBox = $false
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'Codex Cache Monitor'
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(18, 16)
    $form.Controls.Add($titleLabel)

    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = 'Reads local rollout JSONL; Cached is a subset of Input. Closing this window exits the monitor.'
    $subtitleLabel.AutoSize = $true
    $subtitleLabel.Location = New-Object System.Drawing.Point(21, 51)
    $form.Controls.Add($subtitleLabel)

    $autoFollow = New-Object System.Windows.Forms.CheckBox
    $autoFollow.Text = 'Auto-follow latest session'
    $autoFollow.Checked = [string]::IsNullOrWhiteSpace($SessionFile)
    $autoFollow.AutoSize = $true
    $autoFollow.Location = New-Object System.Drawing.Point(22, 82)
    $form.Controls.Add($autoFollow)

    $chooseButton = New-Object System.Windows.Forms.Button
    $chooseButton.Text = 'Choose JSONL…'
    $chooseButton.Size = New-Object System.Drawing.Size(120, 28)
    $chooseButton.Location = New-Object System.Drawing.Point(215, 77)
    $form.Controls.Add($chooseButton)

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = 'Copy summary'
    $copyButton.Size = New-Object System.Drawing.Size(110, 28)
    $copyButton.Location = New-Object System.Drawing.Point(345, 77)
    $form.Controls.Add($copyButton)

    $exitButton = New-Object System.Windows.Forms.Button
    $exitButton.Text = 'Exit'
    $exitButton.Size = New-Object System.Drawing.Size(75, 28)
    $exitButton.Location = New-Object System.Drawing.Point(465, 77)
    $form.Controls.Add($exitButton)

    $fileCaption = New-Object System.Windows.Forms.Label
    $fileCaption.Text = 'Current session:'
    $fileCaption.AutoSize = $true
    $fileCaption.Location = New-Object System.Drawing.Point(22, 119)
    $form.Controls.Add($fileCaption)

    $fileLabel = New-Object System.Windows.Forms.Label
    $fileLabel.Text = 'Searching…'
    $fileLabel.AutoEllipsis = $true
    $fileLabel.Location = New-Object System.Drawing.Point(120, 116)
    $fileLabel.Size = New-Object System.Drawing.Size(625, 22)
    $form.Controls.Add($fileLabel)

    $toolTip = New-Object System.Windows.Forms.ToolTip

    $updatedLabel = New-Object System.Windows.Forms.Label
    $updatedLabel.Text = 'Status: waiting for data'
    $updatedLabel.AutoSize = $true
    $updatedLabel.Location = New-Object System.Drawing.Point(22, 143)
    $form.Controls.Add($updatedLabel)

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Location = New-Object System.Drawing.Point(22, 178)
    $grid.Size = New-Object System.Drawing.Size(735, 270)
    $grid.ColumnCount = 3
    $grid.RowCount = 8
    $grid.CellBorderStyle = [System.Windows.Forms.TableLayoutPanelCellBorderStyle]::Single
    $grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 34)))
    $grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33)))
    $grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33)))
    for ($i = 0; $i -lt 8; $i++) {
        $grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 12.5)))
    }
    $form.Controls.Add($grid)

    function New-GridLabel {
        param([string]$Text, [bool]$Bold = $false)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Dock = [System.Windows.Forms.DockStyle]::Fill
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $label.Padding = New-Object System.Windows.Forms.Padding(8, 0, 4, 0)
        if ($Bold) {
            $label.Font = New-Object System.Drawing.Font($label.Font, [System.Drawing.FontStyle]::Bold)
        }
        return $label
    }

    $grid.Controls.Add((New-GridLabel 'Metric' $true), 0, 0)
    $grid.Controls.Add((New-GridLabel 'Session total' $true), 1, 0)
    $grid.Controls.Add((New-GridLabel 'Latest request' $true), 2, 0)

    $metricNames = @(
        @{ Key = 'Input';     Label = 'Input tokens (includes cached)' },
        @{ Key = 'Cached';    Label = 'Cached input tokens' },
        @{ Key = 'Uncached';  Label = 'Uncached input tokens' },
        @{ Key = 'HitRate';   Label = 'Cache hit rate' },
        @{ Key = 'Output';    Label = 'Output tokens' },
        @{ Key = 'Reasoning'; Label = 'Reasoning output (subset of Output)' },
        @{ Key = 'Total';     Label = 'Total tokens' }
    )

    $sessionValueLabels = @{}
    $lastValueLabels = @{}
    $row = 1
    foreach ($metric in $metricNames) {
        $grid.Controls.Add((New-GridLabel $metric.Label), 0, $row)
        $sessionLabel = New-GridLabel '—'
        $lastLabel = New-GridLabel '—'
        $grid.Controls.Add($sessionLabel, 1, $row)
        $grid.Controls.Add($lastLabel, 2, $row)
        $sessionValueLabels[$metric.Key] = $sessionLabel
        $lastValueLabels[$metric.Key] = $lastLabel
        $row += 1
    }

    $cacheText = New-Object System.Windows.Forms.Label
    $cacheText.Text = 'Latest request cache hit rate: —'
    $cacheText.AutoSize = $true
    $cacheText.Location = New-Object System.Drawing.Point(22, 468)
    $form.Controls.Add($cacheText)

    $cacheBar = New-Object System.Windows.Forms.ProgressBar
    $cacheBar.Minimum = 0
    $cacheBar.Maximum = 100
    $cacheBar.Value = 0
    $cacheBar.Location = New-Object System.Drawing.Point(22, 490)
    $cacheBar.Size = New-Object System.Drawing.Size(735, 18)
    $form.Controls.Add($cacheBar)

    $contextText = New-Object System.Windows.Forms.Label
    $contextText.Text = 'Latest request context pressure: —'
    $contextText.AutoSize = $true
    $contextText.Location = New-Object System.Drawing.Point(22, 523)
    $form.Controls.Add($contextText)

    $contextBar = New-Object System.Windows.Forms.ProgressBar
    $contextBar.Minimum = 0
    $contextBar.Maximum = 100
    $contextBar.Value = 0
    $contextBar.Location = New-Object System.Drawing.Point(22, 545)
    $contextBar.Size = New-Object System.Drawing.Size(735, 18)
    $form.Controls.Add($contextBar)

    $noteLabel = New-Object System.Windows.Forms.Label
    $noteLabel.Text = 'Note: some Codex builds may not record cache-write tokens in rollout telemetry, so this tool reliably reports cache reads only.'
    $noteLabel.AutoSize = $false
    $noteLabel.Size = New-Object System.Drawing.Size(735, 36)
    $noteLabel.Location = New-Object System.Drawing.Point(22, 573)
    $form.Controls.Add($noteLabel)

    $script:currentPath = ''
    $script:lastSignature = ''
    $script:lastMetrics = $null
    $script:lastBundle = $null
    $script:pollCounter = 0
    $script:closing = $false
    $script:codexHome = Get-CodexHome

    if (-not [string]::IsNullOrWhiteSpace($SessionFile)) {
        try {
            $script:currentPath = (Resolve-Path -LiteralPath $SessionFile).Path
        }
        catch {
            $script:currentPath = $SessionFile
        }
    }

    function Set-MetricLabels {
        param($SessionMetrics, $LastMetrics, [int64]$ContextWindow)

        foreach ($key in @('Input','Cached','Uncached','Output','Reasoning','Total')) {
            $sessionValueLabels[$key].Text = Format-TokenCount $SessionMetrics.$key
            $lastValueLabels[$key].Text = Format-TokenCount $LastMetrics.$key
        }

        $sessionValueLabels['HitRate'].Text = Format-Percent $SessionMetrics.HitRate
        $lastValueLabels['HitRate'].Text = Format-Percent $LastMetrics.HitRate

        if (-not [double]::IsNaN($LastMetrics.HitRate)) {
            $cacheText.Text = 'Latest request cache hit rate: ' + (Format-Percent $LastMetrics.HitRate)
            $cacheBar.Value = [int][Math]::Max(0, [Math]::Min(100, [Math]::Round($LastMetrics.HitRate)))
        }
        else {
            $cacheText.Text = 'Latest request cache hit rate: —'
            $cacheBar.Value = 0
        }

        if ($ContextWindow -gt 0 -and $LastMetrics.Input -gt 0) {
            $contextPercent = 100.0 * $LastMetrics.Input / $ContextWindow
            $contextText.Text = ('Latest request context pressure: {0} / {1}  ({2})' -f (Format-TokenCount $LastMetrics.Input), (Format-TokenCount $ContextWindow), (Format-Percent $contextPercent))
            $contextBar.Value = [int][Math]::Max(0, [Math]::Min(100, [Math]::Round($contextPercent)))
        }
        else {
            $contextText.Text = 'Latest request context pressure: —'
            $contextBar.Value = 0
        }
    }

    function Update-Monitor {
        if ($script:closing) { return }

        try {
            $script:pollCounter += 1

            if ($autoFollow.Checked -and ($script:pollCounter % 3 -eq 1 -or [string]::IsNullOrWhiteSpace($script:currentPath))) {
                $latest = Get-LatestRolloutFile $script:codexHome
                if ($null -ne $latest) {
                    if ($script:currentPath -ne $latest.FullName) {
                        $script:currentPath = $latest.FullName
                        $script:lastSignature = ''
                        $script:lastBundle = $null
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($script:currentPath)) {
                $fileLabel.Text = 'No rollout JSONL found'
                $updatedLabel.Text = 'Status: run Codex once or choose a JSONL file manually.'
                return
            }

            if (-not (Test-Path -LiteralPath $script:currentPath -PathType Leaf)) {
                $fileLabel.Text = [System.IO.Path]::GetFileName($script:currentPath)
                $toolTip.SetToolTip($fileLabel, $script:currentPath)
                $updatedLabel.Text = 'Status: the selected JSONL file does not exist.'
                return
            }

            $fileInfo = Get-Item -LiteralPath $script:currentPath
            $fileLabel.Text = $fileInfo.Name
            $toolTip.SetToolTip($fileLabel, $fileInfo.FullName)

            $signature = '{0}|{1}|{2}' -f $fileInfo.FullName, $fileInfo.Length, $fileInfo.LastWriteTimeUtc.Ticks
            if ($signature -eq $script:lastSignature) {
                if ($null -ne $script:lastBundle) {
                    $age = [Math]::Max(0, [int]((Get-Date) - $fileInfo.LastWriteTime).TotalSeconds)
                    $updatedLabel.Text = ('Status: connected; file {0:N0} KB; last write {1} seconds ago' -f ($fileInfo.Length / 1KB), $age)
                }
                return
            }

            $line = Find-LatestTokenCountLine -Path $script:currentPath -TailLimitMB $MaxTailMB
            if ($null -eq $line) {
                if ($null -ne $script:lastBundle) {
                    $updatedLabel.Text = 'Status: file changed but no new token_count was found near the tail; keeping the previous reading.'
                }
                else {
                    $updatedLabel.Text = ('Status: no token_count found within the last {0} MB of the file.' -f $MaxTailMB)
                }
                $script:lastSignature = $signature
                return
            }

            $bundle = Convert-TokenCountLine $line
            if ($null -eq $bundle) {
                $updatedLabel.Text = 'Status: token_count found, but its field layout could not be parsed; keeping the previous reading.'
                $script:lastSignature = $signature
                return
            }

            $sessionMetrics = Convert-UsageToMetrics $bundle.TotalUsage
            $lastMetrics = Convert-UsageToMetrics $bundle.LastUsage
            Set-MetricLabels -SessionMetrics $sessionMetrics -LastMetrics $lastMetrics -ContextWindow $bundle.ContextWindow

            $script:lastBundle = $bundle
            $script:lastMetrics = [PSCustomObject]@{ Session = $sessionMetrics; Last = $lastMetrics; ContextWindow = $bundle.ContextWindow }
            $script:lastSignature = $signature
            $updatedLabel.Text = ('Status: updated; file {0:N0} KB; last write {1}' -f ($fileInfo.Length / 1KB), $fileInfo.LastWriteTime.ToString('HH:mm:ss'))
        }
        catch {
            $updatedLabel.Text = 'Status: ' + $_.Exception.Message
        }
    }

    $chooseButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Choose Codex rollout JSONL'
        $dialog.Filter = 'JSONL files (*.jsonl)|*.jsonl|All files (*.*)|*.*'
        $sessionsRoot = Join-Path $script:codexHome 'sessions'
        if (Test-Path -LiteralPath $sessionsRoot -PathType Container) {
            $dialog.InitialDirectory = $sessionsRoot
        }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $autoFollow.Checked = $false
            $script:currentPath = $dialog.FileName
            $script:lastSignature = ''
            $script:lastBundle = $null
            Update-Monitor
        }
        $dialog.Dispose()
    })

    $autoFollow.Add_CheckedChanged({
        if ($autoFollow.Checked) {
            $script:lastSignature = ''
            Update-Monitor
        }
    })

    $copyButton.Add_Click({
        if ($null -eq $script:lastMetrics) {
            [System.Windows.Forms.MessageBox]::Show('No token data is available to copy yet.', 'Codex Cache Monitor') | Out-Null
            return
        }

        $s = $script:lastMetrics.Session
        $l = $script:lastMetrics.Last
        $summary = @"
Codex Cache Monitor
Session: $($script:currentPath)

Session total
Input:     $(Format-TokenCount $s.Input)
Cached:    $(Format-TokenCount $s.Cached)
Uncached:  $(Format-TokenCount $s.Uncached)
Cache hit: $(Format-Percent $s.HitRate)
Output:    $(Format-TokenCount $s.Output)
Total:     $(Format-TokenCount $s.Total)

Latest request
Input:     $(Format-TokenCount $l.Input)
Cached:    $(Format-TokenCount $l.Cached)
Uncached:  $(Format-TokenCount $l.Uncached)
Cache hit: $(Format-Percent $l.HitRate)
Output:    $(Format-TokenCount $l.Output)
Total:     $(Format-TokenCount $l.Total)
"@
        [System.Windows.Forms.Clipboard]::SetText($summary)
        $updatedLabel.Text = 'Status: summary copied to clipboard.'
    })

    $exitButton.Add_Click({ $form.Close() })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(500, $RefreshMilliseconds)
    $timer.Add_Tick({ Update-Monitor })

    $form.Add_Shown({
        Update-Monitor
        $timer.Start()
    })

    $form.Add_FormClosing({
        $script:closing = $true
        if ($null -ne $timer) { $timer.Stop() }
    })

    $form.Add_FormClosed({
        if ($null -ne $timer) { $timer.Dispose() }
        if ($null -ne $toolTip) { $toolTip.Dispose() }
    })

    try {
        [System.Windows.Forms.Application]::Run($form)
    }
    finally {
        $script:closing = $true
        if ($null -ne $timer) {
            try { $timer.Stop() } catch { }
            try { $timer.Dispose() } catch { }
        }
        if ($null -ne $form) {
            try { $form.Dispose() } catch { }
        }
    }
}
finally {
    if ($mutexHeld -and $null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $mutex) {
        try { $mutex.Dispose() } catch { }
    }
}
