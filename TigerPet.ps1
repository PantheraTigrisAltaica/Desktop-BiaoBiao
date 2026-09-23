# Tiger Desktop Pet - five actions: walk / rest / wave / ball / shake
# Windows 10/11, Windows PowerShell 5.1 + WPF

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $scriptDir 'TigerPet_error.log'
try { if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force } } catch {}

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

    # ── 动作定义 ────────────────────────────────────────────────────────
    # ground : 脚底在画面中的高度比例。各动作数值不同（趴着 0.869、坐着 0.988），
    #          切换时据此补偿窗口位置, 否则老虎会上下瞬移。
    # center : 身体水平中心比例, 同理用于左右补偿。
    # moves  : 是否带动窗口横向移动, 只有走路为真。
    $script:actionOrder = @('walk','rest','wave','ball','shake')
    $script:actionLabel = @{
        walk  = '走路 Walk'
        rest  = '休息 Rest'
        wave  = '挥爪 Wave'
        ball  = '玩球 Ball'
        shake = '抖水 Shake'
    }
    $script:actions = @{
        walk  = @{ frameCount = 10; interval = 0.110; ground = 0.9196; center = 0.5007; moves = $true  }
        rest  = @{ frameCount = 10; interval = 0.200; ground = 0.8689; center = 0.5022; moves = $false }
        wave  = @{ frameCount = 10; interval = 0.120; ground = 0.9558; center = 0.4911; moves = $false }
        ball  = @{ frameCount =  9; interval = 0.130; ground = 0.9672; center = 0.5006; moves = $false }
        shake = @{ frameCount = 10; interval = 0.085; ground = 0.9486; center = 0.5010; moves = $false }
    }

    $script:frames = @{}
    foreach ($act in $script:actionOrder) {
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
    $script:window.Title = 'Tiger Desktop Pet'
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

    # 素材画布 880x572, 与窗口同比例 (1.538), 所以 Uniform 缩放不会留黑边
    $script:baseWidth = 520.0
    $script:baseHeight = 338.0
    $script:userScale = 1.0
    $script:frameIndex = 0
    $script:direction = 1
    $script:state = 'walk'
    $script:paused = $false
    $script:autoSwitch = $true
    $script:speedFactor = 1.0
    $script:moveSpeed = 78.0
    $script:lastFrameTime = 0.0
    $script:nextSwitchTime = 0.0
    $script:clock = [System.Diagnostics.Stopwatch]::StartNew()
    $script:lastTick = $script:clock.Elapsed.TotalSeconds
    $script:rand = New-Object System.Random

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

    # ── 锚点模型 ────────────────────────────────────────────────────────
    # anchorX / anchorY = 老虎"脚底中心"在屏幕上的位置, 这才是老虎真正站的地方。
    # 窗口位置每次都由锚点反算, 而不是反过来。原因:
    #   1) 各动作脚底在画面里的高度不同, 直接比较窗口矩形会让老虎上下跳;
    #   2) 窗口里有大片透明区, 用窗口矩形做边界限制会把老虎推离任务栏;
    #   3) 限制只作用于显示位置、不改锚点, 所以在屏幕边缘放大再缩小能回到原位。
    $script:anchorX = 0.0
    $script:anchorY = 0.0

    function Apply-Anchor {
        $cfg = $script:actions[$script:state]
        $w = $script:baseWidth * $script:userScale
        $h = $script:baseHeight * $script:userScale
        $script:window.Width = $w
        $script:window.Height = $h
        $left = $script:anchorX - ($w * $cfg.center)
        $top  = $script:anchorY - ($h * $cfg.ground)
        $work = Get-WorkArea
        # 只约束脚底不低于工作区底边; 脚下的透明留白可以伸到任务栏后面
        if (($top + $h * $cfg.ground) -gt $work.Bottom) { $top = $work.Bottom - ($h * $cfg.ground) }
        if ($top -lt $work.Top) { $top = $work.Top }
        if ($left -lt $work.Left) { $left = $work.Left }
        if (($left + $w) -gt $work.Right) { $left = $work.Right - $w }
        $script:window.Left = $left
        $script:window.Top = $top
    }

    # 拖动结束或走到屏幕边缘时, 以实际显示位置为准回写锚点
    function Sync-AnchorFromWindow {
        $cfg = $script:actions[$script:state]
        $script:anchorX = $script:window.Left + ($script:window.Width * $cfg.center)
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
        return $script:window.Left + ($script:window.Width * $script:actions[$script:state].center)
    }

    function Set-PetScale([double]$newScale) {
        if ($newScale -lt 0.55) { $newScale = 0.55 }
        if ($newScale -gt 1.65) { $newScale = 1.65 }
        $script:userScale = $newScale
        Apply-Anchor          # 锚点不变, 所以是原地变大变小
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
        # 锚点不变, 只换动作参数再反算窗口: 各动作 ground 不同 (趴着 0.869 /
        # 坐着 0.988) 也不会让老虎上下瞬移
        $script:state = $act
        $script:frameIndex = 0
        $script:lastFrameTime = $script:clock.Elapsed.TotalSeconds
        Apply-Anchor
        Show-Frame 0
        Schedule-NextSwitch
        foreach ($k in $script:actionOrder) {
            if ($script:actionItems.ContainsKey($k)) { $script:actionItems[$k].IsChecked = ($k -eq $act) }
        }
    }

    function Next-Action {
        $i = [Array]::IndexOf($script:actionOrder, $script:state)
        Set-Action $script:actionOrder[(($i + 1) % $script:actionOrder.Count)]
    }

    function Pick-RandomAction {
        # 走路权重高一些, 桌面上有移动才像活的
        $pool = @('walk','walk','walk','rest','rest','wave','ball','shake')
        $pick = $pool[$script:rand.Next(0, $pool.Count)]
        if ($pick -eq $script:state) { Schedule-NextSwitch; return }
        Set-Action $pick
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

        if ($script:paused) { return }

        $cfg = $script:actions[$script:state]
        $interval = $cfg.interval / $script:speedFactor
        if (($now - $script:lastFrameTime) -ge $interval) {
            $steps = [Math]::Max(1, [int][Math]::Floor(($now - $script:lastFrameTime) / $interval))
            $script:lastFrameTime += $steps * $interval
            Show-Frame ($script:frameIndex + $steps)
        }

        if ($cfg.moves -and -not $script:dragging) {
            $work = Get-WorkArea
            $script:anchorX += ($script:moveSpeed * $script:speedFactor * $dt * $script:direction * $script:userScale)
            Apply-Anchor
            if (($script:window.Left + $script:window.Width) -ge $work.Right) {
                $script:direction = -1
                $script:flip.ScaleX = -1
                Sync-AnchorFromWindow     # 贴边后锚点不能继续往外跑
            } elseif ($script:window.Left -le $work.Left) {
                $script:direction = 1
                $script:flip.ScaleX = 1
                Sync-AnchorFromWindow
            }
        }

        if ($script:autoSwitch -and -not $script:dragging -and $now -ge $script:nextSwitchTime) {
            Pick-RandomAction
        }
    })

    $script:window.Add_MouseLeftButtonDown({
        param($sender,$e)
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
        } else {
            # 原地单击 = 换下一个动作, 并停止自动切换, 免得刚选完就被换掉
            $script:autoSwitch = $false
            if ($script:autoItem) { $script:autoItem.IsChecked = $false }
            Next-Action
        }
        $e.Handled = $true
    })

    $script:window.Add_MouseWheel({
        param($sender,$e)
        if ($e.Delta -gt 0) { Set-PetScale ($script:userScale + 0.08) }
        else { Set-PetScale ($script:userScale - 0.08) }
        $e.Handled = $true
    })

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
        $item.Header = $script:actionLabel[$act]
        $item.IsCheckable = $true
        $item.Tag = $act
        $item.Add_Click({
            param($s,$e)
            $script:autoSwitch = $false
            if ($script:autoItem) { $script:autoItem.IsChecked = $false }
            Set-Action ([string]$s.Tag)
        })
        [void]$script:menu.Items.Add($item)
        $script:actionItems[$act] = $item
    }
    [void]$script:menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $script:autoItem = New-Object System.Windows.Controls.MenuItem
    $script:autoItem.Header = '自动切换动作 Auto'
    $script:autoItem.IsCheckable = $true
    $script:autoItem.IsChecked = $true
    $script:autoItem.Add_Click({
        $script:autoSwitch = $script:autoItem.IsChecked
        if ($script:autoSwitch) { Schedule-NextSwitch }
    })
    [void]$script:menu.Items.Add($script:autoItem)

    $script:pauseItem = New-Object System.Windows.Controls.MenuItem
    $script:pauseItem.Header = '暂停 Pause'
    $script:pauseItem.IsCheckable = $true
    $script:pauseItem.Add_Click({
        $script:paused = $script:pauseItem.IsChecked
        if (-not $script:paused) {
            $script:lastFrameTime = $script:clock.Elapsed.TotalSeconds
            Schedule-NextSwitch
        }
    })
    [void]$script:menu.Items.Add($script:pauseItem)
    [void]$script:menu.Items.Add((New-Object System.Windows.Controls.Separator))

    [void](Add-MenuItem '正常速度 Normal' { $script:speedFactor = 1.0 })
    [void](Add-MenuItem '慢速 Slow'       { $script:speedFactor = 0.72 })
    [void](Add-MenuItem '快速 Fast'       { $script:speedFactor = 1.35 })
    [void]$script:menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $script:topItem = New-Object System.Windows.Controls.MenuItem
    $script:topItem.Header = '窗口置顶 Always on top'
    $script:topItem.IsCheckable = $true
    $script:topItem.IsChecked = $true
    $script:topItem.Add_Click({ $script:window.Topmost = $script:topItem.IsChecked })
    [void]$script:menu.Items.Add($script:topItem)

    [void](Add-MenuItem '放大 Larger'      { Set-PetScale ($script:userScale + 0.12) })
    [void](Add-MenuItem '缩小 Smaller'     { Set-PetScale ($script:userScale - 0.12) })
    [void](Add-MenuItem '默认大小 Default' { Set-PetScale 1.0 })
    [void]$script:menu.Items.Add((New-Object System.Windows.Controls.Separator))
    [void](Add-MenuItem '退出 Exit' { Stop-Pet })
    $script:root.ContextMenu = $script:menu

    $script:trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($act in $script:actionOrder) {
        $ti = New-Object System.Windows.Forms.ToolStripMenuItem
        $ti.Text = $script:actionLabel[$act]
        $ti.Tag = $act
        $ti.Add_Click({
            param($s,$e)
            $script:autoSwitch = $false
            if ($script:autoItem) { $script:autoItem.IsChecked = $false }
            Set-Action ([string]$s.Tag)
        })
        [void]$script:trayMenu.Items.Add($ti)
    }
    [void]$script:trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $showItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $showItem.Text = '回到屏幕内 Show tiger'
    $showItem.Add_Click({
        $script:window.Show(); $script:window.Topmost = $script:topItem.IsChecked
        Reset-Position
        $script:window.Activate()
    })
    [void]$script:trayMenu.Items.Add($showItem)
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = '退出 Exit'
    $exitItem.Add_Click({ Stop-Pet })
    [void]$script:trayMenu.Items.Add($exitItem)

    $script:tray = New-Object System.Windows.Forms.NotifyIcon
    $script:tray.Icon = [System.Drawing.SystemIcons]::Application
    $script:tray.Text = 'Tiger Desktop Pet'
    $script:tray.ContextMenuStrip = $script:trayMenu
    $script:tray.Visible = $true
    $script:tray.Add_DoubleClick({ $script:window.Show(); $script:window.Activate() })

    function Reset-Position {
        # 脚底站在任务栏上方 4px, 身体离左边缘留出半个窗口宽
        $work = Get-WorkArea
        $script:anchorX = $work.Left + 30 + ($script:baseWidth * $script:userScale * $script:actions[$script:state].center)
        $script:anchorY = $work.Bottom - 4
        Apply-Anchor
    }

    Reset-Position
    Set-Action 'walk'

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
            "Tiger Desktop Pet failed to start.`r`nError log:`r`n$logPath`r`n`r`n$msg",
            'Tiger Desktop Pet - Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch {}
    exit 1
}
