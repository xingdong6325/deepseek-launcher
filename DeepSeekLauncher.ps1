#Requires -Version 5.1
<#
  DeepSeek 启动器  (DeepSeek Harness Launcher)
  ---------------------------------------------------------------
  双入口：DeepSeek 网页版 / DeepSeek Harness
  功能：自动更新、资源修复、进度条、中断保护、窗口位置记忆、
        黑窗口隐藏、app 模式独立窗口（无浏览器边框）

  参数：
    -SelfTest  只做环境检查，不建界面（给维护用）
    -UiTest    建完整界面但不显示，把控件树 dump 出来后退出
#>
param([switch]$SelfTest, [switch]$UiTest, [switch]$FuncTest, [switch]$PaintTest)

$ErrorActionPreference = 'Stop'

# ══════════════════════ 路径与常量 ══════════════════════
$Root       = 'D:\DeepSeekHarness'
$StateDir   = Join-Path $Root 'launcher'
$StatePath  = Join-Path $StateDir 'state.json'
$LockPath   = Join-Path $StateDir 'op.lock'
$LogPath    = Join-Path $StateDir 'launcher.log'
$DumpPath   = Join-Path $StateDir 'ui_dump.txt'
$IconPath   = Join-Path $Root 'assets\deepseek-whale.ico'
$LogoPng    = Join-Path $Root 'assets\deepseek-whale.png'
$Prefix     = Join-Path $Root 'npm-global'
$DshHome    = Join-Path $Root 'home'
$DshPkgJson = Join-Path $Prefix 'node_modules\@deepseek-ai\dsh\package.json'
$DshBin     = Join-Path $Prefix 'node_modules\@deepseek-ai\dsh\lib\bin.js'
$DshCmd     = Join-Path $Prefix 'dsh.cmd'
$NodeExe    = 'D:\node.exe'
$NpmCli     = 'D:\node_modules\npm\bin\npm-cli.js'
$EdgeExe    = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$ProfileWeb = Join-Path $Root 'browser_profile_web'
$ProfileDsh = Join-Path $Root 'browser_profile_dsh'
$DshPort    = 3080
$WebUrl     = 'https://chat.deepseek.com/'
$script:OrigPath = $env:PATH

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

function Write-Log([string]$m) {
    try {
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m + "`r`n"
        [System.IO.File]::AppendAllText($LogPath, $line, [System.Text.Encoding]::UTF8)
    } catch {}
}

function Test-Port([int]$Port, [int]$TimeoutMs = 400) {
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $c.Connected) { return $true }
        return $false
    } catch { return $false }
    finally { if ($c) { try { $c.Close() } catch {} } }
}

function Read-State {
    try {
        if (Test-Path $StatePath) {
            $raw = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8)
            if ($raw.Trim()) { return ($raw | ConvertFrom-Json) }
        }
    } catch { Write-Log "state 读取失败: $($_.Exception.Message)" }
    return $null
}

function Save-State($h) {
    try {
        $json = $h | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($StatePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log "state 写入失败: $($_.Exception.Message)" }
}

# 保存状态时顺手保留已有的 edge（浏览器窗口位置）记忆，别把它冲掉
function Save-StateMerged($h) {
    try {
        $old = Read-State
        if ($old -and $old.edge -and -not $h.ContainsKey('edge')) { $h['edge'] = $old.edge }
    } catch {}
    Save-State $h
}

function Get-InstalledVersion {
    try {
        if (Test-Path $DshPkgJson) {
            $j = [System.IO.File]::ReadAllText($DshPkgJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            return $j.version
        }
    } catch {}
    return $null
}

# ══════════════════════ DPI 感知 + 程序集 ══════════════════════
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace DshLauncher {
    public class Native {
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

        // ── 用来找到 / 跟踪浏览器那个无边框窗口，好记住它的位置和大小 ──
        public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        // ── 屏幕缩放比例 ──
        // 关键：我们读到的窗口大小是"物理像素"，而 Edge 的 --window-position /
        // --window-size 收的是"逻辑像素(DIP)"。屏幕缩放 150% 时两者差 1.5 倍，
        // 不换算的话窗口会开成记住的 1.5 倍大、位置也偏到右下角去。
        [DllImport("user32.dll")] public static extern int GetDpiForSystem();
        public static double DisplayScale() {
            int d = 0;
            try { d = GetDpiForSystem(); } catch { }
            if (d <= 0) d = 96;
            double s = d / 96.0;
            if (s < 1.0) s = 1.0;
            return s;
        }

        // ── 这个窗口是哪个进程的 ──
        // 用来确保我们盯的是"自己启动的那个 Edge"开的窗口。
        // 只靠标题认窗口会认错：主人日常 Edge 里开着的 DeepSeek 标签页、
        // 或者另一个启动器实例开的窗口，标题里都有 DeepSeek。
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        public static uint PidOf(IntPtr h) {
            uint pid = 0;
            try { GetWindowThreadProcessId(h, out pid); } catch { }
            return pid;
        }

        // ── 读取窗口当前的位置 / 大小 ──
        // 注意：Edge 的 --app 窗口认 --window-position / --window-size / --start-maximized，
        // 启动时直接把记住的值交给它就行，窗口一开就在对的地方。
        // 所以这里不需要任何"开窗后再把它搬过去"的动作 —— 那一搬就是肉眼可见的闪一下。
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
        public struct POINT { public int X; public int Y; }
        public struct WINDOWPLACEMENT {
            public int length; public int flags; public int showCmd;
            public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
        }

        // 要记住的矩形：返回 [左, 上, 宽, 高, 是否最大化]
        // 取的是"还原状态"下的矩形 —— 用户把窗口最大化时，记下的是它原来的大小，
        // 这样下次还原出来才是他熟悉的那个尺寸，而不是一个假的满屏。
        public static int[] SaveRect(IntPtr h) {
            bool zoomed = IsZoomed(h);
            WINDOWPLACEMENT p = new WINDOWPLACEMENT();
            p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
            if (GetWindowPlacement(h, ref p)) {
                RECT r = p.rcNormalPosition;
                if (r.Right - r.Left >= 200 && r.Bottom - r.Top >= 150) {
                    return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, zoomed ? 1 : 0 };
                }
            }
            RECT rr;
            if (!GetWindowRect(h, out rr)) return null;
            return new int[] { rr.Left, rr.Top, rr.Right - rr.Left, rr.Bottom - rr.Top, zoomed ? 1 : 0 };
        }

        public static List<IntPtr> FindWindows(string cls, string titleHas) {
            List<IntPtr> res = new List<IntPtr>();
            EnumWindows(delegate(IntPtr h, IntPtr p) {
                if (!IsWindowVisible(h)) return true;
                if (cls != null) {
                    StringBuilder c = new StringBuilder(256);
                    GetClassName(h, c, 256);
                    if (c.ToString() != cls) return true;
                }
                if (titleHas != null) {
                    StringBuilder t = new StringBuilder(512);
                    GetWindowText(h, t, 512);
                    if (t.ToString().IndexOf(titleHas, StringComparison.OrdinalIgnoreCase) < 0) return true;
                }
                res.Add(h);
                return true;
            }, IntPtr.Zero);
            return res;
        }

        // 返回 [左, 上, 宽, 高]，失败返回 null
        public static int[] Rect(IntPtr h) {
            RECT r;
            if (!GetWindowRect(h, out r)) return null;
            return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
        }
    }
}
'@ -ErrorAction SilentlyContinue
try { [DshLauncher.Native]::SetProcessDPIAware() | Out-Null } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ══════════════════════ 全局异常兜底（必须在建任何窗口之前） ══════════════════════
# 界面里任何一处运行期报错，WinForms 默认会弹一个「未处理的异常」模态小窗。
# 那个小窗盖在整个启动器上面、点哪儿都没反应 —— 表现出来就是「启动器打不开」。
# 这里改成：不弹窗、不卡死，把出错位置写进 launcher.log 并在状态栏红字提示。
[System.Windows.Forms.Application]::SetUnhandledExceptionMode(
    [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    try {
        $ex = $e.Exception
        Write-Log ('【异常】' + $ex.Message)
        Write-Log ('  类型: ' + $ex.GetType().FullName)
        $rec = $null
        try { $rec = $ex.ErrorRecord } catch {}
        if ($rec -and $rec.InvocationInfo) {
            Write-Log ('  出错行号: ' + $rec.InvocationInfo.ScriptLineNumber)
            Write-Log ('  出错语句: ' + ([string]$rec.InvocationInfo.Line).Trim())
            Write-Log ('  堆栈: ' + $rec.ScriptStackTrace)
        } else {
            try { Write-Log ('  堆栈: ' + $ex.ScriptStackTrace) } catch {}
        }
        try { Set-Status ('界面异常(已忽略): ' + $ex.Message) 'err' } catch {}
    } catch {
        try { [System.IO.File]::AppendAllText($LogPath, '  异常处理器自身出错: ' + $_.Exception.Message + "`r`n") } catch {}
    }
})
[System.Windows.Forms.Application]::EnableVisualStyles()

# ══════════════════════ 只允许一个启动器在跑 ══════════════════════
# 出过事（18:48 的日志）：启动器打开网页版后会把自己隐藏起来在后台等窗口关闭，
# 主人看不见它以为没启动，就又双击了一次 —— 两个实例同时盯着浏览器窗口，
# 关窗时各写一份记忆，后写的把先写的盖掉，表现出来就是"大小怎么记都不对"。
# 所以这里先抢一把全局锁。
#
# 抢不到的时候**不要弹框**（弹过一次，主人拿来问"这是怎么回事"——模态框还得手动点确定，
# 纯打扰）。改成跟正常软件一样：双击图标 = 把已经在跑的那个窗口叫出来。
# 叫的办法是一个具名事件：后来的人 Set 一下，先来的那个在 timer 里看到就把窗口显示出来。
$WAKE_NAME = 'DeepSeekLauncherWake'   # 不带 Global\ 前缀：同一会话内够用，兼容性最好（实测可用）
if (-not ($SelfTest -or $UiTest -or $PaintTest -or $FuncTest)) {
    $script:createdNew = $false
    try {
        $script:siMutex = New-Object System.Threading.Mutex(
            $true, 'DeepSeekLauncherSingleInstance', [ref]$script:createdNew)
    } catch {
        $script:createdNew = $true   # 抢锁本身出问题就放行，不能因此打不开
    }
    if (-not $script:createdNew) {
        Write-Log '已经有启动器在运行了 -> 把那个窗口叫出来，本次退出（防止两个实例互相覆盖记忆）'
        try {
            $ev = [System.Threading.EventWaitHandle]::OpenExisting($WAKE_NAME)
            [void]$ev.Set()
            $ev.Close()
        } catch {
            Write-Log ('叫醒已有实例失败（不影响使用）: ' + $_.Exception.Message)
        }
        exit 0
    }
    # 我是第一个：开一个"被唤醒"信号，等着别人来叫我
    try {
        $script:wakeEvent = [System.Threading.EventWaitHandle]::OpenExisting($WAKE_NAME)
    } catch {
        try {
            $script:wakeEvent = New-Object System.Threading.EventWaitHandle(
                $false, [System.Threading.EventResetMode]::ManualReset, $WAKE_NAME)
        } catch { $script:wakeEvent = $null }
    }
}

# ══════════════════════ 自检模式 ══════════════════════
if ($SelfTest) {
    $r = New-Object System.Collections.ArrayList
    function Add-R([string]$t) { [void]$r.Add($t) }
    Add-R ('Root        = ' + $Root + '   exists=' + (Test-Path $Root))
    Add-R ('NodeExe     = ' + $NodeExe + '   exists=' + (Test-Path $NodeExe))
    Add-R ('NpmCli      = ' + $NpmCli + '   exists=' + (Test-Path $NpmCli))
    Add-R ('DshBin      = ' + $DshBin + '   exists=' + (Test-Path $DshBin))
    Add-R ('DshCmd      = ' + $DshCmd + '   exists=' + (Test-Path $DshCmd))
    Add-R ('DshPkgJson  = ' + $DshPkgJson + '   exists=' + (Test-Path $DshPkgJson))
    Add-R ('Version     = ' + (Get-InstalledVersion))
    Add-R ('EdgeExe     = ' + $EdgeExe + '   exists=' + (Test-Path $EdgeExe))
    Add-R ('Icon        = ' + $IconPath + '   exists=' + (Test-Path $IconPath))
    Add-R ('Logo        = ' + $LogoPng + '   exists=' + (Test-Path $LogoPng))
    Add-R ('DshHome     = ' + $DshHome + '   exists=' + (Test-Path $DshHome))
    Add-R ('Port3080    = ' + (Test-Port $DshPort))
    Add-R ('LockExists  = ' + (Test-Path $LockPath))
    Add-R ('PSVersion   = ' + $PSVersionTable.PSVersion)
    $iconOk = 'FAIL'
    try { $null = New-Object System.Drawing.Icon($IconPath); $iconOk = 'OK' } catch { $iconOk = 'FAIL: ' + $_.Exception.Message }
    Add-R ('IconLoad    = ' + $iconOk)
    $logoOk = 'FAIL'
    try { $null = [System.Drawing.Image]::FromFile($LogoPng); $logoOk = 'OK' } catch { $logoOk = 'FAIL: ' + $_.Exception.Message }
    Add-R ('LogoLoad    = ' + $logoOk)
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'selftest.txt'), (($r -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    exit 0
}

$gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$Scale = $gfx.DpiX / 96.0
# ⚠ 注意：这里的缩放变量必须叫 $Scale，绝对不能叫 $S。
# PowerShell 变量名不区分大小写，而界面事件（Paint 等）的 sender 参数习惯写成 $s，
# 一旦叫 $S 就会和它撞成同一个变量、被 Panel 覆盖，Px 里算 $v * $S 就成了「数字 × Panel」，
# 直接把整个界面炸掉（表现为启动器打不开）。
function Px([double]$v) {
    $sc = $Scale
    if ($sc -isnot [double] -and $sc -isnot [int] -and $sc -isnot [float]) { $sc = 1.0 }
    return [int][Math]::Round($v * $sc)
}

Write-Log ('=== 启动器启动 dpi=' + $gfx.DpiX + ' scale=' + $Scale + ' ===')

# ══════════════════════ 配色 ══════════════════════
$C_Brand    = [System.Drawing.Color]::FromArgb(77, 107, 254)
$C_BrandLt  = [System.Drawing.Color]::FromArgb(244, 247, 255)
$C_Bg       = [System.Drawing.Color]::FromArgb(248, 249, 251)
$C_Card     = [System.Drawing.Color]::White
$C_Line     = [System.Drawing.Color]::FromArgb(228, 231, 236)
$C_Txt      = [System.Drawing.Color]::FromArgb(31, 35, 41)
$C_Sub      = [System.Drawing.Color]::FromArgb(120, 128, 140)
$C_BtnBg    = [System.Drawing.Color]::FromArgb(238, 241, 247)
$C_BtnHover = [System.Drawing.Color]::FromArgb(226, 232, 244)
$C_Track    = [System.Drawing.Color]::FromArgb(233, 236, 242)
$C_Warn     = [System.Drawing.Color]::FromArgb(178, 106, 0)
$C_Ok       = [System.Drawing.Color]::FromArgb(18, 128, 92)
$C_Err      = [System.Drawing.Color]::FromArgb(217, 44, 44)

# 字体用 pt（DPI aware 下系统会按 144dpi 自动放大），不再乘 scale
function New-Font([string]$name, [double]$size, [string]$style = 'Regular') {
    $st = [System.Drawing.FontStyle]::$style
    try { return (New-Object System.Drawing.Font($name, [float]$size, $st)) }
    catch { return (New-Object System.Drawing.Font('Microsoft YaHei UI', [float]$size, $st)) }
}
$F_Title = New-Font 'Microsoft YaHei UI' 14   'Bold'
$F_Sub   = New-Font 'Microsoft YaHei UI' 9
$F_CardT = New-Font 'Microsoft YaHei UI' 12   'Bold'
$F_CardD = New-Font 'Microsoft YaHei UI' 9
$F_Btn   = New-Font 'Microsoft YaHei UI' 10
$F_Stat  = New-Font 'Microsoft YaHei UI' 8.5

function Set-RoundedRegion($ctrl, [int]$radius) {
    try {
        $w = $ctrl.Width; $h = $ctrl.Height; $d = $radius * 2
        if ($w -le ($d + 2) -or $h -le ($d + 2)) { return }
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $p.AddArc(0, 0, $d, $d, 180, 90)
        $p.AddArc(($w - $d), 0, $d, $d, 270, 90)
        $p.AddArc(($w - $d), ($h - $d), $d, $d, 0, 90)
        $p.AddArc(0, ($h - $d), $d, $d, 90, 90)
        $p.CloseAllFigures()
        $ctrl.Region = New-Object System.Drawing.Region($p)
    } catch {}
}

# ══════════════════════ 主窗口 ══════════════════════
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'DeepSeek 启动器'
$form.ClientSize      = New-Object System.Drawing.Size((Px 440), (Px 333))
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $true
$form.StartPosition   = 'Manual'
$form.BackColor       = $C_Bg
$form.Font            = $F_Btn
if (Test-Path $IconPath) { try { $form.Icon = New-Object System.Drawing.Icon($IconPath) } catch { Write-Log ('图标载入失败: ' + $_.Exception.Message) } }

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$st0 = Read-State
$wx = $null; $wy = $null
if ($st0 -and $st0.window) { $wx = [int]$st0.window.x; $wy = [int]$st0.window.y }
$fw = $form.Width; $fh = $form.Height
$bad = $false
if ($wx -ne $null) {
    if ($wx -lt ($wa.Left - 20) -or ($wx + 120) -gt $wa.Right -or $wy -lt $wa.Top -or ($wy + 40) -gt $wa.Bottom) { $bad = $true }
}
if ($wx -eq $null -or $bad) {
    $wx = [int]($wa.Left + ($wa.Width - $fw) / 2)
    $wy = [int]($wa.Top + ($wa.Height - $fh) / 2)
    Write-Log ("窗口位置: 默认居中 ($wx,$wy) bad=$bad")
} else {
    Write-Log ("窗口位置: 记忆值 ($wx,$wy)")
}
$form.Location = New-Object System.Drawing.Point($wx, $wy)

# ── 顶部品牌区 ──
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Location  = New-Object System.Drawing.Point((Px 20), (Px 20))
$pic.Size      = New-Object System.Drawing.Size((Px 40), (Px 40))
$pic.SizeMode  = 'Zoom'
$pic.Name      = 'picLogo'
if (Test-Path $LogoPng) { try { $pic.Image = [System.Drawing.Image]::FromFile($LogoPng) } catch { Write-Log ('logo 载入失败: ' + $_.Exception.Message) } }
$form.Controls.Add($pic)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = 'DeepSeek 启动器'
$lblTitle.Font      = $F_Title
$lblTitle.ForeColor = $C_Txt
$lblTitle.AutoSize  = $true
$lblTitle.Name      = 'lblTitle'
$lblTitle.Location  = New-Object System.Drawing.Point((Px 72), (Px 20))
$form.Controls.Add($lblTitle)

$lblHello = New-Object System.Windows.Forms.Label
$lblHello.Text      = '选一个入口开始'
$lblHello.Font      = $F_Sub
$lblHello.ForeColor = $C_Sub
$lblHello.AutoSize  = $true
$lblHello.Name      = 'lblHello'
$lblHello.Location  = New-Object System.Drawing.Point((Px 74), (Px 52))
$form.Controls.Add($lblHello)

$lblWarn = New-Object System.Windows.Forms.Label
$lblWarn.Text      = ''
$lblWarn.Font      = $F_Stat
$lblWarn.ForeColor = $C_Warn
$lblWarn.AutoSize  = $false
$lblWarn.Name      = 'lblWarn'
$lblWarn.Location  = New-Object System.Drawing.Point((Px 20), (Px 73))
$lblWarn.Size      = New-Object System.Drawing.Size((Px 400), (Px 18))
$lblWarn.Visible   = $false
$form.Controls.Add($lblWarn)

# ══════════════════════ 入口卡片工厂 ══════════════════════
function New-Card([int]$x, [int]$y, [int]$w, [int]$h, [string]$title, [string]$desc, [scriptblock]$onClick) {
    $card = New-Object System.Windows.Forms.Panel
    $card.Location  = New-Object System.Drawing.Point($x, $y)
    $card.Size      = New-Object System.Drawing.Size($w, $h)
    $card.BackColor = $C_Card
    $card.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $card.Name      = 'card_' + $title
    $card.Tag       = @{ desc = $desc }
    Set-RoundedRegion $card (Px 8)

    $tl = New-Object System.Windows.Forms.Label
    $tl.Text = $title; $tl.Font = $F_CardT; $tl.ForeColor = $C_Txt
    $tl.AutoSize = $true; $tl.BackColor = [System.Drawing.Color]::Transparent
    $tl.Location = New-Object System.Drawing.Point((Px 18), (Px 11))
    $tl.Name = 't_' + $title
    $card.Controls.Add($tl)

    $dl = New-Object System.Windows.Forms.Label
    $dl.Text = $desc; $dl.Font = $F_CardD; $dl.ForeColor = $C_Sub
    $dl.AutoSize = $true; $dl.BackColor = [System.Drawing.Color]::Transparent
    $dl.Location = New-Object System.Drawing.Point((Px 18), (Px 36))
    $dl.Name = 'd_' + $title
    $card.Controls.Add($dl)

    # 自绘边框：只在卡片自己的 Paint 里画
    $card.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $col = $C_Line
        if ($s.Tag -is [hashtable] -and $s.Tag.ContainsKey('hot') -and $s.Tag.hot) { $col = $C_Brand }
        $pen = New-Object System.Drawing.Pen($col, [float](Px 1))
        $d = (Px 8) * 2
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc(($s.Width - $d - 1), 0, $d, $d, 270, 90)
        $path.AddArc(($s.Width - $d - 1), ($s.Height - $d - 1), $d, $d, 0, 90)
        $path.AddArc(0, ($s.Height - $d - 1), $d, $d, 90, 90)
        $path.CloseAllFigures()
        $e.Graphics.DrawPath($pen, $path)
        $pen.Dispose(); $path.Dispose()
    })

    $enter = {
        param($s, $e)
        $c = $s
        if (-not ($s -is [System.Windows.Forms.Panel])) { $c = $s.Parent }
        if ($c -is [System.Windows.Forms.Panel]) {
            $c.BackColor = $C_BrandLt
            if ($c.Tag -is [hashtable]) { $c.Tag.hot = $true; $lblHello.Text = $c.Tag.desc }
            $c.Invalidate()
        }
    }
    $leave = {
        param($s, $e)
        $c = $s
        if (-not ($s -is [System.Windows.Forms.Panel])) { $c = $s.Parent }
        if ($c -is [System.Windows.Forms.Panel]) {
            $c.BackColor = $C_Card
            if ($c.Tag -is [hashtable]) { $c.Tag.hot = $false }
            $lblHello.Text = '选一个入口开始'
            $c.Invalidate()
        }
    }
    foreach ($c in @($card, $tl, $dl)) {
        $c.Add_Click($onClick)
        $c.Add_MouseEnter($enter)
        $c.Add_MouseLeave($leave)
        if (-not ($c -is [System.Windows.Forms.Panel])) { $c.Cursor = [System.Windows.Forms.Cursors]::Hand }
    }
    return $card
}

$script:mode  = 'idle'
$script:busy  = $false
$script:progressPct = 0

$cardWeb = New-Card (Px 20) (Px 97) (Px 400) (Px 66) 'DeepSeek 网页版' '免费对话 · 打开 chat.deepseek.com' { Start-WebEntry }
$form.Controls.Add($cardWeb)

$cardDsh = New-Card (Px 20) (Px 171) (Px 400) (Px 66) 'DeepSeek Harness' '本地工作台 · 自动启动服务并打开' { Start-HarnessEntry }
$form.Controls.Add($cardDsh)

# ══════════════════════ 底部按钮 ══════════════════════
function New-FlatBtn([int]$x, [int]$y, [int]$w, [int]$h, [string]$text, [string]$name, [scriptblock]$onClick) {
    $b = New-Object System.Windows.Forms.Button
    $b.Location  = New-Object System.Drawing.Point($x, $y)
    $b.Size      = New-Object System.Drawing.Size($w, $h)
    $b.Text      = $text
    $b.Name      = $name
    $b.Font      = $F_Btn
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $C_BtnHover
    $b.FlatAppearance.MouseDownBackColor = $C_Line
    $b.BackColor = $C_BtnBg
    $b.ForeColor = $C_Txt
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $b.UseVisualStyleBackColor = $false
    Set-RoundedRegion $b (Px 6)
    $b.Add_Click($onClick)
    return $b
}

$btnUpdate = New-FlatBtn (Px 20) (Px 247) (Px 193) (Px 38) '自动更新' 'btnUpdate' { Start-Operation 'update' }
$form.Controls.Add($btnUpdate)

$btnRepair = New-FlatBtn (Px 227) (Px 247) (Px 193) (Px 38) '资源修复' 'btnRepair' { Start-Operation 'repair' }
$form.Controls.Add($btnRepair)

# ══════════════════════ 进度条 ══════════════════════
$pbTrack = New-Object System.Windows.Forms.Panel
$pbTrack.Location  = New-Object System.Drawing.Point((Px 20), (Px 295))
$pbTrack.Size      = New-Object System.Drawing.Size((Px 400), (Px 8))
$pbTrack.BackColor = $C_Track
$pbTrack.Name      = 'pbTrack'
Set-RoundedRegion $pbTrack (Px 4)
$form.Controls.Add($pbTrack)

$pbFill = New-Object System.Windows.Forms.Panel
$pbFill.Location  = New-Object System.Drawing.Point(0, 0)
$pbFill.Size      = New-Object System.Drawing.Size((Px 0), (Px 8))
$pbFill.BackColor = $C_Brand
$pbFill.Name      = 'pbFill'
$pbTrack.Controls.Add($pbFill)

function Set-Progress([double]$pct) {
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $w = [int][Math]::Round($pbTrack.Width * $pct / 100.0)
    $pbFill.Width = $w
    Set-RoundedRegion $pbFill (Px 4)
    $script:progressPct = $pct
}

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text      = '就绪'
$lblStatus.Font      = $F_Stat
$lblStatus.ForeColor = $C_Sub
$lblStatus.AutoSize  = $false
$lblStatus.Name      = 'lblStatus'
$lblStatus.Location  = New-Object System.Drawing.Point((Px 20), (Px 307))
$lblStatus.Size      = New-Object System.Drawing.Size((Px 400), (Px 16))
$form.Controls.Add($lblStatus)

function Set-Status([string]$t, [string]$color = 'sub') {
    $lblStatus.Text = $t
    if ($color -eq 'ok') { $lblStatus.ForeColor = $C_Ok }
    elseif ($color -eq 'err') { $lblStatus.ForeColor = $C_Err }
    elseif ($color -eq 'warn') { $lblStatus.ForeColor = $C_Warn }
    else { $lblStatus.ForeColor = $C_Sub }
    Write-Log ('状态: ' + $t)
}

# ══════════════════════ 全局状态 ══════════════════════
$script:dshProc = $null; $script:dshTask = $null; $script:dshErrTask = $null
$script:dshUrl = $null; $script:dshT0 = $null
$script:weStarted = $false; $script:edgeProc = $null
# 窗口跟踪的状态全在 $script:wm 一个变量里（见下方"位置记忆"一节），这里不重复声明
$script:opProc = $null; $script:opTask = $null; $script:opErrTask = $null
$script:opLines = 0; $script:opKind = ''; $script:opT0 = $null; $script:opExpected = 560

# ══════════════════════ 界面自检（把控件树 dump 出来，给看不见界面的我核对） ══════════════════════
function Invoke-UiDump {
    $out = New-Object System.Collections.ArrayList
    function Add-D([string]$t) { [void]$out.Add($t) }
    Add-D ('scale = ' + $Scale + '  form.Size = ' + $form.Size + '  ClientSize = ' + $form.ClientSize)
    Add-D ('form.Location = ' + $form.Location)
    Add-D ('icon = ' + $form.Icon)
    Add-D '----- 顶层控件 -----'
    foreach ($c in $form.Controls) {
        $txt = ''
        try { $txt = [string]$c.Text } catch {}
        Add-D ('{0,-18} {1,-12} ({2},{3}) {4}x{5}  {6}' -f $c.GetType().Name, $c.Name, $c.Left, $c.Top, $c.Width, $c.Height, $txt)
    }
    Add-D '----- 卡片内部 -----'
    foreach ($cd in @($cardWeb, $cardDsh)) {
        Add-D ('card ' + $cd.Name + '  (' + $cd.Left + ',' + $cd.Top + ') ' + $cd.Width + 'x' + $cd.Height)
        foreach ($c in $cd.Controls) {
            $txt = ''
            try { $txt = [string]$c.Text } catch {}
            Add-D ('   {0,-10} {1,-14} ({2},{3}) {4}x{5}  {6}  font={7}' -f $c.GetType().Name, $c.Name, $c.Left, $c.Top, $c.Width, $c.Height, $txt, $c.Font.Size)
        }
    }
    Add-D ('pbFill.Width = ' + $pbFill.Width + ' / pbTrack.Width = ' + $pbTrack.Width)
    Add-D ('btnUpdate: ' + $btnUpdate.Left + ',' + $btnUpdate.Top + ' ' + $btnUpdate.Width + 'x' + $btnUpdate.Height + '  "' + $btnUpdate.Text + '"')
    Add-D ('btnRepair: ' + $btnRepair.Left + ',' + $btnRepair.Top + ' ' + $btnRepair.Width + 'x' + $btnRepair.Height + '  "' + $btnRepair.Text + '"')
    Add-D ('lblStatus: ' + $lblStatus.Left + ',' + $lblStatus.Top + '  "' + $lblStatus.Text + '"')
    Add-D ('字体尺寸: title=' + $F_Title.Size + ' cardT=' + $F_CardT.Size + ' cardD=' + $F_CardD.Size + ' btn=' + $F_Btn.Size + ' stat=' + $F_Stat.Size)
    $fns = @('Start-WebEntry', 'Start-HarnessEntry', 'Open-HarnessWindow', 'Start-Operation', 'Finish-Operation', 'Start-EdgeApp', 'Set-Progress', 'Set-Status')
    $have = @()
    foreach ($f in $fns) { if (Get-Command $f -ErrorAction SilentlyContinue) { $have += $f } }
    Add-D ('已定义函数: ' + ($have -join ', '))
    Add-D ('缺失函数: ' + (($fns | Where-Object { $have -notcontains $_ }) -join ', '))
    [System.IO.File]::WriteAllText($DumpPath, (($out -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

    # 机器可读的控件矩形（给 Python 做重叠检测用）
    $rects = New-Object System.Collections.ArrayList
    foreach ($c in $form.Controls) {
        [void]$rects.Add([pscustomobject]@{ name = [string]$c.Name; x = $c.Left; y = $c.Top; w = $c.Width; h = $c.Height; vis = [bool]$c.Visible })
    }
    foreach ($c in $cardWeb.Controls) {
        [void]$rects.Add([pscustomobject]@{ name = 'web/' + [string]$c.Name; x = ($cardWeb.Left + $c.Left); y = ($cardWeb.Top + $c.Top); w = $c.Width; h = $c.Height; vis = [bool]$c.Visible })
    }
    foreach ($c in $cardDsh.Controls) {
        [void]$rects.Add([pscustomobject]@{ name = 'dsh/' + [string]$c.Name; x = ($cardDsh.Left + $c.Left); y = ($cardDsh.Top + $c.Top); w = $c.Width; h = $c.Height; vis = [bool]$c.Visible })
    }
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'ui_rects.json'), ($rects | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}

# ══════════════════════════════════════════════════════════════════════
#  浏览器窗口的大小记忆
#  ----------------------------------------------------------------------
#  主人的要求很明确：记住我调的大小，以后每次都从屏幕正中间打开。
#  所以只记两样 —— 宽、高（外加"上次是不是最大化"）。位置不记，每次现算成
#  屏幕正中间，这样换显示器、改分辨率都不会跑到看不见的地方去。
#
#  开的时候：把记住的大小和算好的居中位置交给 Edge（--window-size /
#            --window-position；最大化就给 --start-maximized），一开就在那儿。
#  关的时候：记下它关掉那一刻的实际大小。
#
#  这里只负责"看着"窗口：认出是哪个窗口、盯着它什么时候关、顺手记下位置。
#  绝不反过来去动它 —— 一动就会出现"打开时闪一下"和"跟主人抢窗口"。
#
#  教训（别再走回头路）：早先误判"Edge 不认命令行参数"，于是加了一套"窗口
#  开出来之后再把它搬到记忆位置"的补偿；实测 Edge 认这些参数（而且能盖掉它
#  自己的记忆），那套补偿才是闪烁的根源，已彻底删除。
# ══════════════════════════════════════════════════════════════════════
$CLOSE_GRACE     = 2.0      # 窗口找不到了再等这么久，才认定是真的关了
$DETECT_TIMEOUT  = 45       # 一直认不出窗口就放弃，退回按进程判断

# 一次跟踪的全部状态，集中放在这里（不要散成一堆 $script:xxx）
$script:wm = $null

function Find-AppWindowList([string]$hint) {
    # 所有符合的 Edge app 窗口（无边框窗口，类名 Chrome_WidgetWin_1）
    try {
        $l = [DshLauncher.Native]::FindWindows('Chrome_WidgetWin_1', $hint)
        if ($l) { return @($l) }
    } catch {}
    return @()
}

function Find-AppWindow([string]$hint, $exclude, [switch]$strict) {
    # 在符合的窗口里挑出"这次新开的那个"。
    # $strict：已经认领过一次、现在要重新认领时用。此时只认"新冒出来的窗口"，
    #   绝不能拿任意一个标题相符的窗口充数 —— 那会认到主人日常 Edge 里的
    #   DeepSeek 标签页上，结果就是窗口明明关了、启动器却一直不收尾。
    # 首选：属于我们自己启动的那个 Edge 进程的窗口（按进程 ID 认，最准）。
    # 只按标题认会认错 —— 主人日常 Edge 里开着的 DeepSeek 标签页、
    # 另一个启动器实例开的窗口，标题里都有 DeepSeek，采错了记下来的大小就全错。
    $all = @(Find-AppWindowList $hint)
    $ownPid = 0
    if ($script:edgeProc) { try { $ownPid = [int]$script:edgeProc.Id } catch {} }
    if ($ownPid -gt 0) {
        foreach ($h in $all) {
            try {
                if ([int][DshLauncher.Native]::PidOf($h) -eq $ownPid) { return $h }
            } catch {}
        }
    }
    # 兜底：进程 ID 对不上（比如 Edge 把窗口开在了子进程里），退回"看标题 + 排除原有的"
    $fresh = @()
    foreach ($h in $all) {
        $known = $false
        foreach ($x in $exclude) { if ($x.ToInt64() -eq $h.ToInt64()) { $known = $true; break } }
        if (-not $known) { $fresh += $h }
    }
    if ($fresh.Count -gt 0) { return $fresh[0] }
    if (-not $strict -and $all.Count -gt 0) { return $all[0] }
    return [IntPtr]::Zero
}

function Read-WindowRect($hwnd) {
    # 返回 @(左, 上, 宽, 高, 是否最大化)。取"还原状态"下的矩形，
    # 这样主人最大化时记下的仍是他原来的尺寸，不是假的满屏。
    try {
        $r = [DshLauncher.Native]::SaveRect($hwnd)
        if ($r) { return $r }
    } catch {}
    return $null
}

function Start-WindowTrack([string]$kind, [string]$hint) {
    # 必须在启动 Edge 之前调用（要先记下"启动前已经有哪些窗口"）
    $script:wm = @{
        Kind   = $kind                       # 'web' / 'dsh'
        Hint   = $hint                       # 窗口标题关键字
        Before = @(Find-AppWindowList $hint) # 启动前已有的窗口，用来认新窗口
        Hwnd   = [IntPtr]::Zero              # 已认领的窗口
        Rect   = $null                       # 最后一次采到的位置
        Gone   = $null                       # 窗口开始找不到的时刻
        T0     = Get-Date                    # 开始跟踪的时刻
    }
    $script:mode = 'waiting-browser'
}

function Step-WindowTrack {
    # 每个 tick 调一次。返回 'ok' 或 'closed'。
    $w = $script:wm

    # ── 1) 找到那个窗口 ──
    #    Edge 有时会销毁重建窗口、句柄就变了，所以句柄失效要重新认领，
    #    不能抱着旧句柄不放（那样会误判成"窗口已经关了"）。
    $alive = ($w.Hwnd -ne [IntPtr]::Zero) -and [DshLauncher.Native]::IsWindow($w.Hwnd)
    if (-not $alive) {
        $h = Find-AppWindow $w.Hint $w.Before -strict:($w.Hwnd -ne [IntPtr]::Zero)
        if ($h -ne [IntPtr]::Zero) {
            if ($w.Hwnd -ne [IntPtr]::Zero) { Write-Log ('窗口句柄变更，重新认领 0x' + $h.ToString('X')) }
            else                             { Write-Log ('认准浏览器窗口 hwnd=0x' + $h.ToString('X')) }
            $w.Hwnd = $h
            $w.Gone = $null
        } else {
            if ($w.Hwnd -eq [IntPtr]::Zero) {
                # 从头到尾没认出过：超时后退回"看进程退没退"
                if (((Get-Date) - $w.T0).TotalSeconds -gt $DETECT_TIMEOUT) {
                    if ($script:edgeProc -and $script:edgeProc.HasExited) { return 'closed' }
                }
                return 'ok'
            }
            # 认领过又找不到了：给 2 秒宽限（可能正在重建），之后算关了
            if ($w.Gone -eq $null) { $w.Gone = Get-Date }
            if (((Get-Date) - $w.Gone).TotalSeconds -gt $CLOSE_GRACE) { return 'closed' }
            return 'ok'
        }
    }

    # ── 2) 只记录，不动它 ──
    #    主人想拖到哪、想放多大，随他；我们只是持续记下它当前在哪儿，
    #    等他关掉窗口时把最后一次记到的值存起来，下次照着开。
    $r = Read-WindowRect $w.Hwnd
    if ($r) { $w.Rect = $r }
    return 'ok'
}

function Get-WindowSize([string]$kind) {
    # 从 state.json 读回记住的大小：@(宽, 高, 是否最大化)，没记过返回 $null
    # 位置不记 —— 每次都从屏幕正中间开，不会因为换屏幕 / 改分辨率而跑到看不见的地方
    try {
        $st = Read-State
        $e = $st.edge.$kind
        if ($e) {
            $mx = 0
            try { if ($e.mx) { $mx = [int]$e.mx } } catch {}
            $w = 0; $h = 0
            try { $w = [int]$e.w; $h = [int]$e.h } catch {}
            if ($w -ge 320 -and $h -ge 240) { return @($w, $h, $mx) }
        }
    } catch {}
    return $null
}

function Save-WindowMemory {
    # 把"关窗那一刻窗口所在的位置"写进 state.json
    try {
        $w = $script:wm
        $old = Read-State
        $h = @{ window = @{ x = $form.Location.X; y = $form.Location.Y } }
        if ($old -and $old.url) { $h.url = [string]$old.url }
        if ($script:dshUrl)     { $h.url = [string]$script:dshUrl }
        if (-not $w) {
            # 这次没有在跟踪任何窗口（比如已经收过尾了）：只存启动器自身的位置，
            # edge 记忆原样保留，别重复写一遍日志
            if ($old -and $old.edge) { $h['edge'] = $old.edge }
            Save-State $h
            return
        }

        $edge = @{}
        if ($old -and $old.edge) {
            foreach ($k in @('web', 'dsh')) {
                $sub = $old.edge.$k
                if ($sub) {
                    $mx0 = 0
                    try { if ($sub.mx) { $mx0 = [int]$sub.mx } } catch {}
                    $wOld = 0; $hOld = 0
                    try { $wOld = [int]$sub.w; $hOld = [int]$sub.h } catch {}
                    if ($wOld -ge 320 -and $hOld -ge 240) { $edge[$k] = @{ w = $wOld; h = $hOld; mx = $mx0 } }
                }
            }
        }
        if ($w.Rect -and $w.Kind) {
            $r = $w.Rect
            $mx = 0
            if ($r.Count -ge 5) { $mx = [int]$r[4] }
            $edge[$w.Kind] = @{ w = [int]$r[2]; h = [int]$r[3]; mx = $mx }
            Write-Log ('已记住 [' + $w.Kind + '] 窗口大小 ' + $r[2] + 'x' + $r[3] + $(if ($mx -eq 1) { '（最大化）' } else { '（下次居中打开）' }))
        } elseif ($w.Kind) {
            Write-Log ('这次没采到 [' + $w.Kind + '] 窗口大小，沿用旧值')
        }
        if ($edge.Count -gt 0) { $h['edge'] = $edge }
        Save-State $h
    } catch { Write-Log ('保存状态失败: ' + $_.Exception.Message) }
}

# ══════════════════════ Edge app 窗口 ══════════════════════
function Start-EdgeApp([string]$url, [string]$profileDir, [int[]]$size = @(1760, 1100), [int[]]$mem = $null) {
    if (-not (Test-Path $EdgeExe)) { throw ('Edge 未找到: ' + $EdgeExe) }
    if ($profileDir -and -not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
    $argList = New-Object System.Collections.ArrayList
    [void]$argList.Add('--app=' + $url)
    [void]$argList.Add('--no-first-run')
    [void]$argList.Add('--no-default-browser-check')
    if ($profileDir) { [void]$argList.Add('--user-data-dir=' + $profileDir) }

    # 大小用记住的（没记过就用默认的），位置一律算成屏幕正中间。
    # 这两样都直接交给 Edge，窗口一开就在对的地方 —— 不需要事后去搬，搬就会闪。
    $wantW = $size[0]; $wantH = $size[1]; $max = $false
    if ($mem -and $mem.Count -ge 2 -and $mem[0] -ge 320 -and $mem[1] -ge 240) {
        $wantW = [int]$mem[0]; $wantH = [int]$mem[1]
        if ($mem.Count -ge 3 -and [int]$mem[2] -eq 1) { $max = $true }
    }
    if ($max) {
        [void]$argList.Add('--start-maximized')   # 上次是最大化关掉的，照样最大化打开
    } else {
        # 先在物理像素里把"居中在哪、多大"算好，再整体换算成 Edge 认的逻辑像素。
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea   # 工作区：不算任务栏
        $wPhys = [Math]::Min($wantW, $wa.Width)
        $hPhys = [Math]::Min($wantH, $wa.Height)
        $xPhys = $wa.X + [int](($wa.Width  - $wPhys) / 2)
        $yPhys = $wa.Y + [int](($wa.Height - $hPhys) / 2)
        $s = [DshLauncher.Native]::DisplayScale()   # 150% 缩放时 = 1.5
        [void]$argList.Add('--window-position=' + [int]($xPhys / $s) + ',' + [int]($yPhys / $s))
        [void]$argList.Add('--window-size=' + [int]($wPhys / $s) + ',' + [int]($hPhys / $s))
        Write-Log ('屏幕缩放 ' + $s + 'x：记住 ' + $wPhys + 'x' + $hPhys + ' -> 交给 Edge ' +
                   [int]($wPhys / $s) + 'x' + [int]($hPhys / $s) + ' 位置 ' + [int]($xPhys / $s) + ',' + [int]($yPhys / $s))
    }
    $quoted = @()
    foreach ($a in $argList) { if ($a -match '\s') { $quoted += ('"' + $a + '"') } else { $quoted += $a } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $EdgeExe
    $psi.Arguments       = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    Write-Log ('Edge 启动: ' + $psi.Arguments)
    return [System.Diagnostics.Process]::Start($psi)
}

# ══════════════════════ 入口 1：网页版 ══════════════════════
function Start-WebEntry {
    if ($script:busy) { return }
    if ($script:mode -eq 'waiting-browser' -or $script:mode -eq 'starting-dsh') {
        Set-Status '已经有一个窗口开着了，先把它关掉再开新的' 'warn'
        return
    }
    Set-Status '正在打开 DeepSeek 网页版 ...'
    try {
        Start-WindowTrack 'web' 'DeepSeek'   # 必须在启动 Edge 前调用
        $mem = Get-WindowSize 'web'
        # 必须用独立配置(ProfileWeb)，和 Harness 一个做法：
        # Edge 是单实例程序，主人日常那个 Edge 开着时，新起的进程会把命令行转发给已有实例，
        # 而 --window-size / --window-position 在转发中被丢掉 —— 窗口大小和位置就完全不听话了。
        # 用独立配置，每次都是全新实例，参数才生效（代价：这个窗口里要单独登录一次 DeepSeek）。
        $script:edgeProc = Start-EdgeApp $WebUrl $ProfileWeb @(1760, 1100) $mem
        Write-Log '网页版窗口已启动'
        Set-Status '已打开 DeepSeek 网页版 · 关掉它的窗口后本窗口会自动退出' 'ok'
        # 1.2 秒后把启动器藏起来让位给浏览器窗口（不退出：要一直盯着那个窗口的位置）
        $script:closeTimer = New-Object System.Windows.Forms.Timer
        $script:closeTimer.Interval = 1200
        $script:closeTimer.Add_Tick({
            $script:closeTimer.Stop()
            $form.Hide()
        })
        $script:closeTimer.Start()
    } catch {
        $script:mode = 'idle'
        Set-Status ('打开失败: ' + $_.Exception.Message) 'err'
        Write-Log ('网页版失败: ' + $_.Exception.ToString())
    }
}

# ══════════════════════ 入口 2：Harness ══════════════════════
function Start-HarnessEntry {
    if ($script:busy) { return }
    if ($script:mode -eq 'waiting-browser' -or $script:mode -eq 'starting-dsh') {
        Set-Status '已经有一个窗口开着了，先把它关掉再开新的' 'warn'
        return
    }
    $script:dshUrl = $null
    $script:dshT0  = Get-Date
    $script:weStarted = $false

    if (Test-Port $DshPort) {
        Write-Log '端口 3080 已在监听，尝试复用'
        $s = Read-State
        if ($s -and $s.url) {
            $script:dshUrl = [string]$s.url
            Write-Log ('复用已保存地址: ' + $script:dshUrl)
            Open-HarnessWindow
            return
        }
        Set-Status '服务已在运行，但拿不到访问地址；请关掉已有的 Harness 再试' 'warn'
        return
    }

    if (-not (Test-Path $DshBin)) {
        Set-Status '找不到 dsh 程序，请先点「资源修复」' 'err'
        Write-Log ('DshBin 缺失: ' + $DshBin)
        return
    }

    Set-Status '正在启动 DeepSeek Harness（约 5~15 秒）...'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $NodeExe
        $psi.Arguments              = '"' + $DshBin + '" web --no-open'
        $psi.WorkingDirectory       = $DshHome
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        # 用「当前进程环境变量」传给子进程并继承。
        # 实测：ProcessStartInfo.EnvironmentVariables 在 $ErrorActionPreference='Stop' 下
        # 会返回 null 并报「无法对 Null 数组进行索引」，所以走继承这条路。
        $env:DSH_HOME = $DshHome
        $env:PATH     = 'D:\;' + $Prefix + ';' + $script:OrigPath

        $p = [System.Diagnostics.Process]::Start($psi)
        $script:dshProc    = $p
        $script:dshTask    = $p.StandardOutput.ReadLineAsync()
        $script:dshErrTask = $p.StandardError.ReadLineAsync()
        $script:mode       = 'starting-dsh'
        Write-Log ('dsh 已启动 pid=' + $p.Id + '（无窗口模式）')
        Set-Progress 12
    } catch {
        Set-Status ('启动失败: ' + $_.Exception.Message) 'err'
        Write-Log ('dsh 启动失败: ' + $_.Exception.ToString())
    }
}

function Open-HarnessWindow {
    try {
        Set-Progress 90
        Set-Status '正在打开 Harness 窗口 ...'
        Start-WindowTrack 'dsh' 'DeepSeek Harness'   # 必须在启动 Edge 前调用
        $mem = Get-WindowSize 'dsh'
        $script:edgeProc = Start-EdgeApp $script:dshUrl $ProfileDsh @(1760, 1100) $mem
        $script:weStarted = $true
        Set-Progress 100
        Set-Status 'Harness 已打开 · 关闭它的窗口后服务会自动停止' 'ok'
        Save-StateMerged @{ window = @{ x = $form.Location.X; y = $form.Location.Y }; url = $script:dshUrl }
        $form.Hide()
        Write-Log '启动器窗口已隐藏，等待 Harness 窗口关闭'
    } catch {
        $script:mode = 'idle'
        Set-Status ('打开窗口失败: ' + $_.Exception.Message) 'err'
        Write-Log ('Edge 启动失败: ' + $_.Exception.ToString())
    }
}

# ══════════════════════ 自动更新 / 资源修复 ══════════════════════
function Start-Operation([string]$kind) {
    if ($script:busy) { return }
    if (Test-Port $DshPort) {
        Set-Status 'Harness 正在运行，请先关掉它的窗口再做这个操作' 'warn'
        return
    }
    if (-not (Test-Path $NodeExe) -or -not (Test-Path $NpmCli)) {
        Set-Status '找不到 Node.js / npm，无法执行' 'err'
        return
    }

    $verb = '更新'
    if ($kind -eq 'repair') { $verb = '修复' }

    $ver = Get-InstalledVersion
    if ($kind -eq 'update') {
        $spec = '@deepseek-ai/dsh@latest'
        $script:opTarget = 'latest'
        Set-Status '正在检查最新版本 ...'
    } else {
        if ($ver) { $spec = '@deepseek-ai/dsh@' + $ver; $script:opTarget = $ver }
        else { $spec = '@deepseek-ai/dsh@latest'; $script:opTarget = 'latest' }
        $missing = New-Object System.Collections.ArrayList
        if (-not (Test-Path $DshBin))     { [void]$missing.Add('lib/bin.js') }
        if (-not (Test-Path $DshCmd))     { [void]$missing.Add('dsh.cmd') }
        if (-not (Test-Path $DshPkgJson)) { [void]$missing.Add('package.json') }
        if (-not (Test-Path (Join-Path $DshHome 'profiles'))) { [void]$missing.Add('home/profiles') }
        if ($missing.Count -eq 0) { Write-Log '资源检查：无缺失，做一次强制重装确保干净' }
        else { Write-Log ('资源缺失: ' + ($missing -join ', ')) }
    }

    try {
        $lock = @{ kind = $kind; target = $script:opTarget; started = (Get-Date -Format 'o') } | ConvertTo-Json
        [System.IO.File]::WriteAllText($LockPath, $lock, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log ('已写入中断保护标记 op.lock (' + $kind + ')')
    } catch { Write-Log ('写锁失败: ' + $_.Exception.Message) }

    $script:busy = $true
    $script:opKind = $kind
    $script:opLines = 0
    $script:opT0 = Get-Date
    $script:mode = 'busy'
    Set-Progress 3
    $btnUpdate.Enabled = $false
    $btnRepair.Enabled = $false

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $NodeExe
        $psi.Arguments              = '"' + $NpmCli + '" install -g --prefix "' + $Prefix + '" ' + $spec + ' --prefer-offline --loglevel=http --no-audit --no-fund --force'
        $psi.WorkingDirectory       = $Root
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $env:npm_config_cache    = Join-Path $env:LOCALAPPDATA 'npm-cache'
        $env:npm_config_registry = 'https://registry.npmjs.org/'
        $env:PATH                = 'D:\;' + $Prefix + ';' + $script:OrigPath

        $p = [System.Diagnostics.Process]::Start($psi)
        $script:opProc    = $p
        $script:opTask    = $p.StandardOutput.ReadLineAsync()
        $script:opErrTask = $p.StandardError.ReadLineAsync()
        Write-Log ('npm 已启动 pid=' + $p.Id + '  spec=' + $spec)
        Set-Status ('正在' + $verb + ' ... 请勿关闭窗口')
    } catch {
        Finish-Operation $false ('启动失败: ' + $_.Exception.Message)
    }
}

function Finish-Operation([bool]$ok, [string]$msg) {
    $script:busy = $false
    $script:mode = 'idle'
    $btnUpdate.Enabled = $true
    $btnRepair.Enabled = $true
    if (Test-Path $LockPath) { try { [System.IO.File]::Delete($LockPath) } catch {} }
    if ($ok) { Set-Progress 100; Set-Status $msg 'ok' } else { Set-Status $msg 'err' }
    Write-Log ('操作结束 ok=' + $ok + ' : ' + $msg + '  行数=' + $script:opLines)
}

# ══════════════════════ 主循环 ══════════════════════
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250    # 只用来盯"浏览器窗口关了没"，不需要多快；慢点还省电
$timer.Add_Tick({
    # ── 主人又双击了图标 -> 把窗口叫出来（取代原来那个烦人的"已经在运行"提示框） ──
    if ($script:wakeEvent -and $script:wakeEvent.WaitOne(0)) {
        $script:wakeEvent.Reset()
        Write-Log '主人再次双击了图标 -> 把窗口显示出来'
        try {
            if (-not $form.Visible) { $form.Show() }
            if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            }
            [void]$form.Activate()
        } catch { Write-Log ('显示窗口失败: ' + $_.Exception.Message) }
    }

    # ── 启动 dsh：抓地址 ──
    if ($script:mode -eq 'starting-dsh' -and $script:dshProc) {
        try {
            $guard = 0
            while ($guard -lt 30) {
                if (-not ($script:dshTask -and $script:dshTask.IsCompleted)) { break }
                $line = $script:dshTask.Result
                if ($line -eq $null) { break }
                $guard++
                Write-Log ('dsh> ' + $line)
                if (-not $script:dshUrl -and $line -match 'http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9\-_.]+') {
                    $script:dshUrl = $Matches[0]
                    Write-Log ('抓到地址: ' + $script:dshUrl)
                }
                if ($script:dshProc -and -not $script:dshProc.HasExited) { $script:dshTask = $script:dshProc.StandardOutput.ReadLineAsync() }
                else { break }
            }
            $guard2 = 0
            while ($guard2 -lt 30) {
                if (-not ($script:dshErrTask -and $script:dshErrTask.IsCompleted)) { break }
                $el = $script:dshErrTask.Result
                if ($el -eq $null) { break }
                $guard2++
                Write-Log ('dsh! ' + $el)
                if ($script:dshProc -and -not $script:dshProc.HasExited) { $script:dshErrTask = $script:dshProc.StandardError.ReadLineAsync() }
                else { break }
            }
        } catch { Write-Log ('读 dsh 输出异常: ' + $_.Exception.Message) }

        if ($script:dshUrl) { Open-HarnessWindow; return }

        if ($script:dshProc -and $script:dshProc.HasExited) {
            Set-Status ('dsh 进程提前退出（代码 ' + $script:dshProc.ExitCode + '），详见 launcher.log') 'err'
            Write-Log ('dsh 提前退出 code=' + $script:dshProc.ExitCode)
            $script:mode = 'idle'; Set-Progress 0
            return
        }
        $el2 = ((Get-Date) - $script:dshT0).TotalSeconds
        if ($el2 -gt 100) {
            Set-Status '启动超时（100 秒），详见 launcher.log' 'err'
            Write-Log '启动超时'
            $script:mode = 'idle'; Set-Progress 0
            return
        }
        if ($el2 -gt 3 -and $script:progressPct -lt 80) { Set-Progress ([Math]::Min(80, 12 + $el2 * 3)) }
        return
    }

    # ── 等浏览器窗口关闭（网页版 / Harness 共用；顺手记住它的位置和大小） ──
    if ($script:mode -eq 'waiting-browser') {
        if ((Step-WindowTrack) -eq 'closed') {
            Write-Log '浏览器窗口已关闭 -> 收尾'
            Save-WindowMemory
            $script:wm = $null      # 已经收过尾了，退出时别再存一遍
            if ($script:dshProc -and -not $script:dshProc.HasExited) {
                try { $script:dshProc.Kill(); Write-Log 'dsh 已停止' } catch { Write-Log ('停止 dsh 失败: ' + $_.Exception.Message) }
            }
            $script:mode = 'idle'
            $form.Close()
        }
        return
    }

    # ── 更新 / 修复进度 ──
    if ($script:mode -eq 'busy' -and $script:opProc) {
        $got = 0
        try {
            while ($got -lt 30) {
                if (-not ($script:opTask -and $script:opTask.IsCompleted)) { break }
                $l = $script:opTask.Result
                if ($l -eq $null) { break }
                $script:opLines++; $got++
                if ($script:opLines % 50 -eq 0) { Write-Log ('npm[' + $script:opLines + '] ' + $l) }
                if ($script:opProc -and -not $script:opProc.HasExited) { $script:opTask = $script:opProc.StandardOutput.ReadLineAsync() } else { break }
            }
            while ($got -lt 30) {
                if (-not ($script:opErrTask -and $script:opErrTask.IsCompleted)) { break }
                $l2 = $script:opErrTask.Result
                if ($l2 -eq $null) { break }
                $script:opLines++; $got++
                if ($script:opLines % 50 -eq 0) { Write-Log ('npm!' + $l2) }
                if ($script:opProc -and -not $script:opProc.HasExited) { $script:opErrTask = $script:opProc.StandardError.ReadLineAsync() } else { break }
            }
        } catch { Write-Log ('读 npm 输出异常: ' + $_.Exception.Message) }

        $pct = 3 + 92.0 * $script:opLines / $script:opExpected
        if ($pct -gt 95) { $pct = 95 }
        $sec = ((Get-Date) - $script:opT0).TotalSeconds
        $byTime = 3 + 60.0 * ($sec / 240.0)
        if ($byTime -gt $pct -and $byTime -lt 95) { $pct = $byTime }
        Set-Progress $pct
        $verb2 = '更新'
        if ($script:opKind -eq 'repair') { $verb2 = '修复' }
        Set-Status ('正在' + $verb2 + '  ' + [int]$pct + '%  ·  已处理 ' + $script:opLines + ' 行  ·  请勿关闭窗口')

        if ($script:opProc.HasExited) {
            Start-Sleep -Milliseconds 150
            try {
                $rest = $script:opProc.StandardOutput.ReadToEnd()
                if ($rest) { $script:opLines += ($rest -split "`n").Count }
                $restE = $script:opProc.StandardError.ReadToEnd()
                if ($restE) { $script:opLines += ($restE -split "`n").Count }
            } catch {}
            $code = $script:opProc.ExitCode
            if ($code -eq 0) {
                $nv = Get-InstalledVersion
                Finish-Operation $true ('完成 · 当前版本 ' + $nv)
            } else {
                Finish-Operation $false ('失败（退出代码 ' + $code + '），详见 launcher.log')
            }
        }
        return
    }
})
$timer.Start()

# ══════════════════════ 关闭处理 ══════════════════════
$form.Add_FormClosing({
    param($s, $e)
    if ($script:busy) {
        $e.Cancel = $true
        $v = '更新'
        if ($script:opKind -eq 'repair') { $v = '修复' }
        Set-Status ('正在' + $v + '，请等进度条走完再关闭（避免文件损坏）') 'warn'
        [System.Windows.Forms.MessageBox]::Show(('正在' + $v + " 中，中途关闭可能损坏文件。`n`n请等进度条走完再关闭。"), '请稍等', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        Save-WindowMemory
        Write-Log ('保存窗口位置 (' + $form.Location.X + ',' + $form.Location.Y + ')')
    } catch { Write-Log ('保存状态失败: ' + $_.Exception.Message) }

    if ($script:dshProc -and -not $script:dshProc.HasExited) {
        try { $script:dshProc.Kill(); Write-Log '退出时一并停止 dsh' } catch {}
    }
    Write-Log '=== 启动器退出 ==='
})

# ══════════════════════ 界面自检出口（这里函数都定义完了） ══════════════════════
if ($UiTest) { Invoke-UiDump; exit 0 }

# ══════════════════════ 绘制自检：真显示窗口，逼出 Paint 里的报错 ══════════════════════
if ($PaintTest) {
    $R = New-Object System.Collections.ArrayList
    function Add-P([string]$t) { [void]$R.Add($t) }
    Add-P ('=== PaintTest 开始 ' + (Get-Date -Format 'HH:mm:ss') + ' ===')
    try {
        $form.Show()
        for ($i = 0; $i -lt 18; $i++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 120
        }
        Add-P '窗口已显示，消息循环跑过（首次 Paint 应已触发）'
        try {
            $cardWeb.Invalidate($true); $cardDsh.Invalidate($true); $pbFill.Invalidate($true)
            Add-P '已强制三张卡片/进度条重绘'
        } catch { Add-P ('重绘调用异常: ' + $_.Exception.Message) }
        for ($i = 0; $i -lt 12; $i++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 120
        }
        Add-P '重绘循环完成'
        Add-P ('卡片1 背景色 = ' + $cardWeb.BackColor.ToString())
        Add-P ('卡片2 背景色 = ' + $cardDsh.BackColor.ToString())
    } catch {
        Add-P ('★顶层异常: ' + $_.Exception.Message)
        Add-P ('  行号: ' + $_.InvocationInfo.ScriptLineNumber)
        Add-P ('  语句: ' + [string]$_.InvocationInfo.Line)
    }
    try { $form.Hide() } catch {}
    try { $form.Close() } catch {}
    Add-P '=== PaintTest 结束 ==='
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'painttest.txt'), (($R -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    exit 0
}

# ══════════════════════ 功能自检：真跑 dsh + 真开一次 app 窗口 ══════════════════════
if ($FuncTest) {
    $R = New-Object System.Collections.ArrayList
    function Add-F([string]$t) { [void]$R.Add($t); Write-Host $t }
    Add-F ('=== FuncTest 开始 ' + (Get-Date -Format 'HH:mm:ss') + ' ===')
    $dshProc2 = $null
    try {
        if (Test-Port $DshPort) {
            Add-F '端口 3080 已占用，跳过启动部分'
        } else {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $NodeExe
            $psi.Arguments              = '"' + $DshBin + '" web --no-open'
            $psi.WorkingDirectory       = $DshHome
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $env:DSH_HOME = $DshHome
            $env:PATH     = 'D:\;' + $Prefix + ';' + $script:OrigPath
            $t0 = Get-Date
            $dshProc2 = [System.Diagnostics.Process]::Start($psi)
            Add-F ('dsh 已启动 pid=' + $dshProc2.Id + '（CreateNoWindow=true，理论上不该有黑窗口）')
            $url2 = $null
            # 注意：同一个 ReadLineAsync 只能有一个在飞，否则报「流正在由其上的前一操作使用」
            $pendOut = $dshProc2.StandardOutput.ReadLineAsync()
            $pendErr = $dshProc2.StandardError.ReadLineAsync()
            while (((Get-Date) - $t0).TotalSeconds -lt 90 -and -not $url2) {
                if ($pendOut -and $pendOut.Wait(1500)) {
                    $ln = $pendOut.Result
                    if ($ln -eq $null) { break }
                    Add-F ('dsh> ' + $ln)
                    if ($ln -match 'http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9\-_.]+') { $url2 = $Matches[0] }
                    if (-not $dshProc2.HasExited) { $pendOut = $dshProc2.StandardOutput.ReadLineAsync() } else { break }
                }
                if ($pendErr -and $pendErr.Wait(10)) {
                    $le = $pendErr.Result
                    if ($le -ne $null) { Add-F ('dsh! ' + $le) }
                    if ($dshProc2 -and -not $dshProc2.HasExited) { $pendErr = $dshProc2.StandardError.ReadLineAsync() }
                }
                if ($dshProc2.HasExited) { Add-F ('dsh 提前退出 code=' + $dshProc2.ExitCode); break }
            }
            Add-F ('启动耗时 ' + [int](((Get-Date) - $t0).TotalSeconds) + ' 秒')
            Add-F ('url = ' + $url2)
            if ($url2) {
                try {
                    $resp = Invoke-WebRequest -Uri $url2 -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 5
                    Add-F ('HTTP 带 token -> ' + $resp.StatusCode + '   ' + $resp.RawContentLength + ' bytes')
                } catch { Add-F ('HTTP 失败: ' + $_.Exception.Message) }
                $ep = Start-EdgeApp $url2 $ProfileDsh @(1760, 1100)
                Add-F ('Edge --app 已启动 pid=' + $ep.Id + '（这一步会短暂弹出一个无边框窗口）')
                Start-Sleep -Seconds 9
                Add-F ('9 秒后 Edge.HasExited = ' + $ep.HasExited + '   ← False 才说明窗口稳定存活（关窗口自动退出就靠它）')
                try { Add-F ('Edge 主窗口标题 = ' + $ep.MainWindowTitle) } catch {}
                try { if (-not $ep.HasExited) { $ep.Kill(); Add-F '已关闭测试窗口' } } catch {}
            }
            try { if ($dshProc2 -and -not $dshProc2.HasExited) { $dshProc2.Kill(); Add-F '已停止 dsh' } } catch {}
        }
        Start-Sleep -Milliseconds 800
        Add-F ('清理后端口 3080 = ' + (Test-Port $DshPort))
    } catch {
        Add-F ('FuncTest 异常: ' + $_.Exception.Message)
        Add-F ('  出错行号: ' + $_.InvocationInfo.ScriptLineNumber)
        Add-F ('  出错语句: ' + $_.InvocationInfo.Line)
        Add-F ('  脚本堆栈: ' + $_.ScriptStackTrace)
    }
    Add-F '=== FuncTest 结束 ==='
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'functest.txt'), (($R -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    exit 0
}

# ══════════════════════ 打开时的锁检查 ══════════════════════
if (Test-Path $LockPath) {
    try {
        $lk = [System.IO.File]::ReadAllText($LockPath, [System.Text.Encoding]::UTF8)
        Write-Log ('发现未完成的操作标记: ' + $lk)
        $lblWarn.Text = '上次的更新/修复没有正常结束，建议点「资源修复」再检查一遍'
        $lblWarn.Visible = $true
        Set-Status '检测到上次操作被中断' 'warn'
    } catch {}
} else {
    $v0 = Get-InstalledVersion
    Set-Status ('就绪 · DeepSeek Harness ' + $v0)
}

[System.Windows.Forms.Application]::Run($form)
