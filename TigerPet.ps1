# Desktop Pet framework - Windows PowerShell 5.1 + WPF
# Double-click feeding interaction (wait -> eat / roar) is configured in the
# "interaction" block of assets\actions.json; hidden actions never appear in menus.
# All pet-specific data (name, actions, frame counts, sizes, ground/center,
# menu text) lives in assets\actions.json. This script is ASCII-only on
# purpose: non-ASCII text in a .ps1 breaks parsing on Windows systems whose
# code page is not UTF-8. Keep all translatable text in the JSON file.

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $scriptDir 'TigerPet_error.log'
try { if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force } } catch {}

# ---------------------------------------------------------------- config
function Load-PetConfig([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing config: $path" }
    $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg = @{
        name       = [string]$json.name
        id         = [string]$json.id
        assetRatio = [double]$json.asset_ratio
        moveSpeed  = [double]$json.move_speed
        order      = @($json.order | ForEach-Object { [string]$_ })
        all        = @($json.actions.PSObject.Properties | ForEach-Object { [string]$_.Name })
        actions    = @{}
        ui         = @{}
        feed       = $null
    }
    foreach ($a in $cfg.all) {
        $c = $json.actions.$a
        $cfg.actions[$a] = @{
            frameCount = [int]$c.frames
            interval   = [double]$c.interval
            width      = [double]$c.width
            height     = [double]$c.height
            ground     = [double]$c.ground
            center     = [double]$c.center
            moves      = [bool]$c.moves
            weight     = [int]$c.weight
            label      = [string]$c.label
            hidden     = [bool]$c.hidden
            once       = [bool]$c.once
            sound      = [string]$c.sound
        }
    }
    if ($null -ne $json.interaction) {
        $i = $json.interaction
        $cfg.feed = @{
            from    = @($i.from | ForEach-Object { [string]$_ })
            wait    = [string]$i.wait
            timeout = [double]$i.timeout
            success = [string]$i.success
            fail    = [string]$i.fail
        }
    }
    foreach ($p in $json.ui.PSObject.Properties) { $cfg.ui[$p.Name] = [string]$p.Value }
    return $cfg
}

try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    function New-Bitmap([string]$path) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing asset: $path" }
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bmp.UriSource = New-Object System.Uri($path, [System.UriKind]::Absolute)
        $bmp.EndInit()
        $bmp.Freeze()
        return $bmp
    }

    $assetDir = Join-Path $scriptDir 'assets'
    $script:cfg = Load-PetConfig (Join-Path $assetDir 'actions.json')
    $script:actionOrder = $script:cfg.order
    $script:actions = $script:cfg.actions
    $script:ui = $script:cfg.ui

    # Weighted pool for random switching (e.g. walk 3, lie 2, others 1)
    $script:pickPool = @()
    foreach ($a in $script:actionOrder) {
        $w = [Math]::Max(1, $script:actions[$a].weight)
        for ($k = 0; $k -lt $w; $k++) { $script:pickPool += $a }
    }

    $script:frames = @{}
    $script:sounds = @{}
    foreach ($act in $script:cfg.all) {
        $snd = $script:actions[$act].sound
        if ($snd) {
            $p = New-Object System.Media.SoundPlayer (Join-Path $assetDir $snd)
            $p.Load()
            $script:sounds[$act] = $p
        }
        $list = New-Object System.Collections.ArrayList
        for ($i = 1; $i -le $script:actions[$act].frameCount; $i++) {
            $name = ('{0}_{1:d2}.png' -f $act, $i)
            [void]$list.Add((New-Bitmap (Join-Path $assetDir $name)))
        }
        $script:frames[$act] = $list
    }

    $script:app = New-Object System.Windows.Application
    $script:app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

    $script:window = New-Object System.Windows.Window
    $script:window.Title = $script:cfg.name
    $script:window.WindowStyle = [System.Windows.WindowStyle]::None
    $script:window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $script:window.AllowsTransparency = $true
    $script:window.Background = [System.Windows.Media.Brushes]::Transparent
    $script:window.Topmost = $true
    $script:window.ShowInTaskbar = $false
    $script:window.SizeToContent = [System.Windows.SizeToContent]::Manual
    $script:window.UseLayoutRounding = $true
    $script:window.SnapsToDevicePixels = $true

    $script:root = New-Object System.Windows.Controls.Grid
    $script:root.Background = [System.Windows.Media.Brushes]::Transparent
    $script:root.Cursor = [System.Windows.Input.Cursors]::Hand

    $script:image = New-Object System.Windows.Controls.Image
    $script:image.Stretch = [System.Windows.Media.Stretch]::Uniform
    $script:image.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $script:image.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
    $script:image.SnapsToDevicePixels = $true
    $script:image.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    $script:flip = New-Object System.Windows.Media.ScaleTransform(1,1)
    $script:image.RenderTransform = $script:flip
    [void]$script:root.Children.Add($script:image)
    $script:window.Content = $script:root

    $script:userScale = 1.0
    $script:frameIndex = 0
    $script:direction = 1
    $script:state = $script:actionOrder[0]
    $script:paused = $false
    $script:autoSwitch = $true
    $script:speedFactor = 1.0
    $script:moveSpeed = $script:cfg.moveSpeed
    $script:lastFrameTime = 0.0
    $script:nextSwitchTime = 0.0
    $script:clock = [System.Diagnostics.Stopwatch]::StartNew()
    $script:lastTick = $script:clock.Elapsed.TotalSeconds
    $script:rand = New-Object System.Random

    # Feeding interaction: '' (none) | 'waiting' | 'once'
    $script:interaction = ''
    $script:returnState = ''
    $script:waitDeadline = 0.0
    $script:onceRemaining = 0
    $script:soundOn = $true
    # Single clicks are deferred by the system double-click time so that the
    # first click of a double-click does not switch the action.
    $script:dblTime = [System.Windows.Forms.SystemInformation]::DoubleClickTime / 1000.0
    $script:pendingClickAt = 0.0
    $script:suppressUp = $false
    # Our own double-click detection in SCREEN coordinates. WPF's click count
    # compares positions relative to the window, so while the pet walks the
    # window slides under a still cursor and the second click never counts.
    $script:lastDownAt = -10.0
    $script:lastDownPos = New-Object System.Windows.Point(-9999, -9999)
    $script:dblDist = [Math]::Max(4.0, [double][System.Windows.Forms.SystemInformation]::DoubleClickSize.Width)

    $script:dragging = $false
    $script:moved = $false
    $script:dragThreshold = 8.0
    $script:dragStartMouse = New-Object System.Windows.Point(0,0)
    $script:dragStartLeft = 0.0
    $script:dragStartTop = 0.0

    function Get-WorkArea { return [System.Windows.SystemParameters]::WorkArea }

    function Get-CursorDip {
        $p = [System.Windows.Forms.Cursor]::Position
        $pt = [System.Windows.Point]::new([double]$p.X, [double]$p.Y)
        $src = [System.Windows.PresentationSource]::FromVisual($script:window)
        if ($null -ne $src -and $null -ne $src.CompositionTarget) {
            return $src.CompositionTarget.TransformFromDevice.Transform($pt)
        }
        return $pt
    }

    # ---------------------------------------------------------- anchor model
    # anchorX/anchorY = screen position of the pet's feet (body centre, ground).
    # The window is always derived from the anchor, never the other way round:
    #  * every action has its own canvas size and its own ground/centre ratios;
    #  * the window contains transparent margins, so clamping the window rect
    #    would push the pet off the taskbar;
    #  * clamping changes only the displayed rect, so zooming in at a screen
    #    edge and zooming out again returns the pet to exactly where it was.
    $script:anchorX = 0.0
    $script:anchorY = 0.0

    # When the pet faces left the image is mirrored inside the window, so the
    # body centre sits at (1 - center) of the window width, not at center.
    function Get-EffCenter([string]$act) {
        $c = $script:actions[$act].center
        if ($script:direction -lt 0) { return 1.0 - $c }
        return $c
    }

    function Get-ActionSize([string]$act) {
        $c = $script:actions[$act]
        $w = $c.width / $script:cfg.assetRatio * $script:userScale
        $h = $c.height / $script:cfg.assetRatio * $script:userScale
        return @($w, $h)
    }

    function Apply-Anchor {
        $cfg = $script:actions[$script:state]
        $size = Get-ActionSize $script:state
        $w = $size[0]; $h = $size[1]
        $script:window.Width = $w
        $script:window.Height = $h
        $left = $script:anchorX - ($w * (Get-EffCenter $script:state))
        $top  = $script:anchorY - ($h * $cfg.ground)
        $work = Get-WorkArea
        # Only the feet must stay above the work-area bottom; the transparent
        # margin under the feet may extend behind the taskbar.
        if (($top + $h * $cfg.ground) -gt $work.Bottom) { $top = $work.Bottom - ($h * $cfg.ground) }
        if ($top -lt $work.Top) { $top = $work.Top }
        if ($left -lt $work.Left) { $left = $work.Left }
        if (($left + $w) -gt $work.Right) { $left = $work.Right - $w }
        $script:window.Left = $left
        $script:window.Top = $top
    }

    function Sync-AnchorFromWindow {
        $cfg = $script:actions[$script:state]
        $script:anchorX = $script:window.Left + ($script:window.Width * (Get-EffCenter $script:state))
        $script:anchorY = $script:window.Top + ($script:window.Height * $cfg.ground)
    }

    function Keep-On-Screen {
        Sync-AnchorFromWindow
        Apply-Anchor
        Sync-AnchorFromWindow
    }

    function Get-GroundY {
        return $script:window.Top + ($script:window.Height * $script:actions[$script:state].ground)
    }
    function Get-CenterX {
        return $script:window.Left + ($script:window.Width * (Get-EffCenter $script:state))
    }

    function Set-PetScale([double]$newScale) {
        if ($newScale -lt 0.55) { $newScale = 0.55 }
        if ($newScale -gt 1.65) { $newScale = 1.65 }
        $script:userScale = $newScale
        Apply-Anchor
    }

    function Reset-Position {
        # Feet 4 px above the taskbar, body 30 px + half a window from the left edge
        $work = Get-WorkArea
        $size = Get-ActionSize $script:state
        $script:anchorX = $work.Left + 30 + ($size[0] * (Get-EffCenter $script:state))
        $script:anchorY = $work.Bottom - 4
        Apply-Anchor
    }

    function Show-Frame([int]$index) {
        $list = $script:frames[$script:state]
        if ($list.Count -eq 0) { return }
        $index = $index % $list.Count
        if ($index -lt 0) { $index += $list.Count }
        $script:frameIndex = $index
        $script:image.Source = $list[$script:frameIndex]
    }

    function Schedule-NextSwitch {
        $now = $script:clock.Elapsed.TotalSeconds
        $script:nextSwitchTime = $now + 6.0 + ($script:rand.NextDouble() * 8.0)
    }

    function Set-Action([string]$act) {
        if (-not $script:actions.ContainsKey($act)) { return }
        # The anchor stays put; only the action parameters change.
        $script:state = $act
        $script:frameIndex = 0
        $script:lastFrameTime = $script:clock.Elapsed.TotalSeconds
        Apply-Anchor
        Show-Frame 0
        Schedule-NextSwitch
        if ($script:soundOn -and $script:sounds.ContainsKey($act)) {
            try { $script:sounds[$act].Play() } catch {}
        }
        foreach ($k in $script:actionOrder) {
            if ($script:actionItems.ContainsKey($k)) { $script:actionItems[$k].IsChecked = ($k -eq $act) }
        }
    }

    function Next-Action {
        $i = [Array]::IndexOf($script:actionOrder, $script:state)
        Set-Action $script:actionOrder[(($i + 1) % $script:actionOrder.Count)]
    }

    function Pick-RandomAction {
        $pick = $script:pickPool[$script:rand.Next(0, $script:pickPool.Count)]
        if ($pick -eq $script:state) { Schedule-NextSwitch; return }
        Set-Action $pick
    }

    function Start-Once([string]$act) {
        # One-shot action: plays every frame once, then End-Interaction restores
        # the action the pet was doing before the double-click.
        $script:interaction = 'once'
        $script:onceRemaining = $script:actions[$act].frameCount
        Set-Action $act
    }

    function End-Interaction {
        $back = $script:returnState
        $script:interaction = ''
        $script:returnState = ''
        if ($back) { Set-Action $back }
    }

    function On-DoubleClick {
        $f = $script:cfg.feed
        if ($null -eq $f) { return }
        if ($script:interaction -eq 'waiting') { Start-Once $f.success; return }   # fed within time
        if ($script:interaction -ne '') { return }                                   # eating / roaring
        if ($f.from -notcontains $script:state) { return }                           # e.g. ball, shake
        $script:returnState = $script:state
        $script:interaction = 'waiting'
        $script:waitDeadline = $script:clock.Elapsed.TotalSeconds + $f.timeout
        Set-Action $f.wait
    }

    function Choose-Action([string]$act) {
        # A manual choice cancels any feeding interaction and turns
        # auto-switching off so it is not replaced at once
        $script:interaction = ''
        $script:returnState = ''
        $script:autoSwitch = $false
        if ($script:autoItem) { $script:autoItem.IsChecked = $false }
        Set-Action $act
    }

    function Stop-Pet {
        try { $script:timer.Stop() } catch {}
        try { $script:tray.Visible = $false; $script:tray.Dispose() } catch {}
        try { $script:window.Close() } catch {}
        try { $script:app.Shutdown() } catch {}
    }

    $script:timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(16)
    $script:timer.Add_Tick({
        $now = $script:clock.Elapsed.TotalSeconds
        $dt = $now - $script:lastTick
        if ($dt -lt 0) { $dt = 0 }
        if ($dt -gt 0.12) { $dt = 0.016 }
        $script:lastTick = $now

        if ($script:paused) {
            if ($script:interaction -eq 'waiting') { $script:waitDeadline += $dt }
            return
        }

        if ($script:pendingClickAt -gt 0 -and $now -ge $script:pendingClickAt) {
            $script:pendingClickAt = 0.0
            if ($script:interaction -eq '') {
                $script:autoSwitch = $false
                if ($script:autoItem) { $script:autoItem.IsChecked = $false }
                Next-Action
            }
        }

        $cfg = $script:actions[$script:state]
        $interval = $cfg.interval / $script:speedFactor
        if (($now - $script:lastFrameTime) -ge $interval) {
            $steps = [Math]::Max(1, [int][Math]::Floor(($now - $script:lastFrameTime) / $interval))
            $script:lastFrameTime += $steps * $interval
            if ($script:interaction -eq 'once') {
                $script:onceRemaining -= $steps
                if ($script:onceRemaining -le 0) { End-Interaction; return }
            }
            Show-Frame ($script:frameIndex + $steps)
        }

        if ($script:interaction -eq 'waiting' -and $now -ge $script:waitDeadline) {
            Start-Once $script:cfg.feed.fail
            return
        }

        # While a click may still become a double-click the pet stands still,
        # so the second click lands on the same spot of its body.
        if ($cfg.moves -and -not $script:dragging -and -not ($script:pendingClickAt -gt 0)) {
            $work = Get-WorkArea
            $script:anchorX += ($script:moveSpeed * $script:speedFactor * $dt * $script:direction * $script:userScale)
            Apply-Anchor
            if (($script:window.Left + $script:window.Width) -ge $work.Right) {
                $script:direction = -1
                $script:flip.ScaleX = -1
                Sync-AnchorFromWindow
            } elseif ($script:window.Left -le $work.Left) {
                $script:direction = 1
                $script:flip.ScaleX = 1
                Sync-AnchorFromWindow
            }
        }

        if ($script:autoSwitch -and $script:interaction -eq '' -and -not $script:dragging -and $now -ge $script:nextSwitchTime) {
            Pick-RandomAction
        }
    })

    $script:window.Add_MouseLeftButtonDown({
        param($sender,$e)
        if ($null -ne $script:cfg.feed) {
            $tNow = $script:clock.Elapsed.TotalSeconds
            $pNow = Get-CursorDip
            $isDbl = (($tNow - $script:lastDownAt) -le $script:dblTime) -and
                     ([Math]::Abs($pNow.X - $script:lastDownPos.X) -le $script:dblDist) -and
                     ([Math]::Abs($pNow.Y - $script:lastDownPos.Y) -le $script:dblDist)
            if ($isDbl) {
                $script:lastDownAt = -10.0        # a third click starts a new sequence
                $script:pendingClickAt = 0.0      # cancel the deferred single click
                $script:suppressUp = $true        # the matching button-up is not a click
                On-DoubleClick
            } else {
                $script:lastDownAt = $tNow
                $script:lastDownPos = $pNow
            }
        }
        $script:dragging = $true
        $script:moved = $false
        $script:dragStartMouse = Get-CursorDip
        $script:dragStartLeft = $script:window.Left
        $script:dragStartTop = $script:window.Top
        [void]$script:window.CaptureMouse()
        $script:window.Activate()
        $e.Handled = $true
    })

    $script:window.Add_MouseMove({
        param($sender,$e)
        if (-not $script:dragging) { return }
        if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        $now = Get-CursorDip
        $dx = $now.X - $script:dragStartMouse.X
        $dy = $now.Y - $script:dragStartMouse.Y
        if (-not $script:moved -and (([Math]::Abs($dx) + [Math]::Abs($dy)) -ge $script:dragThreshold)) {
            $script:moved = $true
        }
        if ($script:moved) {
            $script:window.Left = $script:dragStartLeft + $dx
            $script:window.Top = $script:dragStartTop + $dy
        }
        $e.Handled = $true
    })

    $script:window.Add_MouseLeftButtonUp({
        param($sender,$e)
        if (-not $script:dragging) { return }
        $script:dragging = $false
        try { $script:window.ReleaseMouseCapture() } catch {}
        if ($script:moved) {
            Keep-On-Screen
        } elseif ($script:suppressUp) {
            # second half of a double-click: already handled
        } elseif ($null -eq $script:cfg.feed) {
            # No double-click interaction for this pet: act on the click at once
            $script:autoSwitch = $false
            if ($script:autoItem) { $script:autoItem.IsChecked = $false }
            Next-Action
        } else {
            $script:pendingClickAt = $script:clock.Elapsed.TotalSeconds + $script:dblTime
        }
        $script:suppressUp = $false
        $e.Handled = $true
    })

    $script:window.Add_MouseWheel({
        param($sender,$e)
        if ($e.Delta -gt 0) { Set-PetScale ($script:userScale + 0.08) }
        else { Set-PetScale ($script:userScale - 0.08) }
        $e.Handled = $true
    })

    # ---------------------------------------------------------------- menus
    $script:menu = New-Object System.Windows.Controls.ContextMenu
    function Add-MenuItem([string]$header, [scriptblock]$handler) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = $header
        $item.Add_Click($handler)
        [void]$script:menu.Items.Add($item)
        return $item
    }

    $script:actionItems = @{}
    foreach ($act in $script:actionOrder) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = $script:actions[$act].label
        $item.IsCheckable = $true
        $item.Tag = $act
        $item.Add_Click({ param($s,$e) Choose-Action ([string]$s.Tag) })
        [void]$script:menu.Items.Add($item)
        $script:actionItems[$act] = $item
    }
    [void]$script:menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $script:autoItem = New-Object System.Windows.Controls.MenuItem
    $script:autoItem.Header = $script:ui.auto
    $script:autoItem.IsCheckable = $true
    $script:autoItem.IsChecked = $true
    $script:autoItem.Add_Click({
        $script:autoSwitch = $script:autoItem.IsChecked
        if ($script:autoSwitch) { Schedule-NextSwitch }
    })
    [void]$script:menu.Items.Add($script:autoItem)

    $script:pauseItem = New-Object System.Windows.Controls.MenuItem
    $script:pauseItem.Header = $script:ui.pause
    $script:pauseItem.IsCheckable = $true
    $script:pauseItem.Add_Click({
        $script:paused = $script:pauseItem.IsChecked
        if (-not $script:paused) {
            $script:lastFrameTime = $script:clock.Elapsed.TotalSeconds
            Schedule-NextSwitch
        }
    })
    [void]$script:menu.Items.Add($script:pauseItem)

    # The sound toggle only appears for pets that actually have sounds
    if ($script:sounds.Count -gt 0) {
        $script:soundItem = New-Object System.Windows.Controls.MenuItem
        $script:soundItem.Header = $script:ui.sound
        $script:soundItem.IsCheckable = $true
        $script:soundItem.IsChecked = $true
        $script:soundItem.Add_Click({
            $script:soundOn = $script:soundItem.IsChecked
            if (-not $script:soundOn) { foreach ($p in $script:sounds.Values) { try { $p.Stop() } catch {} } }
        })
        [void]$script:menu.Items.Add($script:soundItem)
    }
    [void]$script:menu.Items.Add((New-Object System.Windows.Controls.Separator))

    [void](Add-MenuItem $script:ui.normal { $script:speedFactor = 1.0 })
    [void](Add-MenuItem $script:ui.slow   { $script:speedFactor = 0.72 })
    [void](Add-MenuItem $script:ui.fast   { $script:speedFactor = 1.35 })
    [void]$script:menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $script:topItem = New-Object System.Windows.Controls.MenuItem
    $script:topItem.Header = $script:ui.top
    $script:topItem.IsCheckable = $true
    $script:topItem.IsChecked = $true
    $script:topItem.Add_Click({ $script:window.Topmost = $script:topItem.IsChecked })
    [void]$script:menu.Items.Add($script:topItem)

    [void](Add-MenuItem $script:ui.larger  { Set-PetScale ($script:userScale + 0.12) })
    [void](Add-MenuItem $script:ui.smaller { Set-PetScale ($script:userScale - 0.12) })
    [void](Add-MenuItem $script:ui.default { Set-PetScale 1.0 })
    [void](Add-MenuItem $script:ui.reset   { Reset-Position })
    [void]$script:menu.Items.Add((New-Object System.Windows.Controls.Separator))
    [void](Add-MenuItem $script:ui.quit { Stop-Pet })
    $script:root.ContextMenu = $script:menu

    $script:trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($act in $script:actionOrder) {
        $ti = New-Object System.Windows.Forms.ToolStripMenuItem
        $ti.Text = $script:actions[$act].label
        $ti.Tag = $act
        $ti.Add_Click({ param($s,$e) Choose-Action ([string]$s.Tag) })
        [void]$script:trayMenu.Items.Add($ti)
    }
    [void]$script:trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $showItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $showItem.Text = $script:ui.reset
    $showItem.Add_Click({
        $script:window.Show(); $script:window.Topmost = $script:topItem.IsChecked
        Reset-Position
        $script:window.Activate()
    })
    [void]$script:trayMenu.Items.Add($showItem)
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = $script:ui.quit
    $exitItem.Add_Click({ Stop-Pet })
    [void]$script:trayMenu.Items.Add($exitItem)

    $script:tray = New-Object System.Windows.Forms.NotifyIcon
    $script:tray.Icon = [System.Drawing.SystemIcons]::Application
    $script:tray.Text = $script:cfg.name
    $script:tray.ContextMenuStrip = $script:trayMenu
    $script:tray.Visible = $true
    $script:tray.Add_DoubleClick({ $script:window.Show(); $script:window.Activate() })

    Reset-Position
    Set-Action $script:actionOrder[0]

    $script:window.Add_KeyDown({
        param($sender,$e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) { Stop-Pet }
    })

    $script:window.Add_Closed({
        try { $script:timer.Stop() } catch {}
        try { $script:tray.Visible = $false; $script:tray.Dispose() } catch {}
        try { $script:app.Shutdown() } catch {}
    })

    $script:timer.Start()
    [void]$script:app.Run($script:window)
    exit 0
}
catch {
    $msg = $_.Exception.ToString()
    try { $msg | Out-File -LiteralPath $logPath -Encoding UTF8 -Force } catch {}
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show(
            "Desktop pet failed to start.`r`nError log:`r`n$logPath`r`n`r`n$msg",
            'Desktop Pet - Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch {}
    exit 1
}
