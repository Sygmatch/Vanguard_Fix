#Requires -Version 5.1
<#
.SYNOPSIS
    Vanguard Fix 4.0 - Gestor de servicios de Riot (Vanguard, procesos, DNS y lanzadores).

.DESCRIPTION
    Soluciona los típicos errores de Riot Vanguard (VAN) y de conexión: cierra procesos de Riot que se
    quedaron colgados, reinicia el servicio de Vanguard (vgc), vacía la caché DNS y vuelve a lanzar
    League of Legends o Valorant. Compatible con Windows 10 y Windows 11 (Windows PowerShell 5.1).

    Seguridad:
      * Pide permisos de administrador automáticamente (UAC) y fuerza Windows PowerShell 5.1 (STA).
      * Las acciones que interrumpen juegos o el antitrampas piden confirmación explicando qué harán.
      * Para cerrar procesos eliges cuáles (lista con casillas) y se verifica PID + nombre + hora de inicio.
      * Antes de tocar el servicio vgc o cerrar procesos se guarda una instantánea (JSON) en Backups.
      * No borra archivos ni modifica la configuración de servicios (si vgc está deshabilitado, te avisa).
      * La ruta de Riot indicada a mano se valida (sin UNC, sin enlaces, sin rutas del sistema) y el
        ejecutable solo se lanza si su firma digital es válida y pertenece a Riot Games.
      * Registro diario en %LOCALAPPDATA%\VanguardFix\Logs.

.NOTES
    Autor : MARCKO-SYGMATCH  |  https://github.com/Sygmatch
#>
[CmdletBinding()]
param()

$script:AppName   = 'Vanguard Fix'
$script:AppVer    = '4.0'
$script:AppFolder = 'VanguardFix'
$script:GitHubUrl = 'https://github.com/Sygmatch/Vanguard_Fix'
$script:URI_LOL   = 'riotclient://launch-product=league_of_legends&line=live'
$script:URI_VAL   = 'riotclient://launch-product=valorant&line=live'
$script:URI_RIOT  = 'riotclient://'

# ============================================================================
#  1) ELEVACION AUTOMATICA (UAC) + FORZAR WINDOWS POWERSHELL 5.1 (STA)
# ============================================================================
function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $adminSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        return ([Security.Principal.WindowsPrincipal]$identity).IsInRole($adminSid)
    } catch { return $false }
}

# Mensaje sencillo (sin MessageBox del sistema) para errores de arranque, antes de que exista la interfaz.
function Show-StartupMessage {
    param([string]$Text)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $startupLight = $false
        try {
            $startupLight = ((Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme -eq 1)
        } catch { $startupLight = $false }
        $bgColor = [System.Drawing.Color]::FromArgb(14, 16, 26)
        $fgColor = [System.Drawing.Color]::FromArgb(238, 241, 250)
        if ($startupLight) { $bgColor = [System.Drawing.Color]::FromArgb(242, 244, 251); $fgColor = [System.Drawing.Color]::FromArgb(24, 28, 45) }
        $frmMsg = New-Object System.Windows.Forms.Form
        $frmMsg.Text = $script:AppName
        $frmMsg.FormBorderStyle = 'FixedDialog'
        $frmMsg.MaximizeBox = $false; $frmMsg.MinimizeBox = $false
        $frmMsg.StartPosition = 'CenterScreen'
        $frmMsg.BackColor = $bgColor; $frmMsg.ForeColor = $fgColor
        $frmMsg.ClientSize = New-Object System.Drawing.Size(520, 190)
        $lblMsg = New-Object System.Windows.Forms.Label
        $lblMsg.UseCompatibleTextRendering = $false
        $lblMsg.Text = $Text
        $lblMsg.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $lblMsg.Location = New-Object System.Drawing.Point(20, 18)
        $lblMsg.Size = New-Object System.Drawing.Size(480, 110)
        $frmMsg.Controls.Add($lblMsg)
        $btnMsg = New-Object System.Windows.Forms.Button
        $btnMsg.Text = 'Aceptar'
        $btnMsg.Location = New-Object System.Drawing.Point(400, 140)
        $btnMsg.Size = New-Object System.Drawing.Size(100, 32)
        $btnMsg.add_Click({ $frmMsg.Close() }.GetNewClosure())
        $frmMsg.Controls.Add($btnMsg)
        $frmMsg.AcceptButton = $btnMsg
        [void]$frmMsg.ShowDialog()
        $frmMsg.Dispose()
    } catch {
        Write-Warning $Text
    }
}

$script:IsAdmin = Test-IsAdmin
$script:IsSta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)
if ((-not $script:IsAdmin) -or ($PSVersionTable.PSEdition -eq 'Core') -or (-not $script:IsSta)) {
    $selfPath = $PSCommandPath
    if (-not $selfPath) { $selfPath = $MyInvocation.MyCommand.Path }
    if (-not $selfPath) {
        Show-StartupMessage 'Guarda este código como archivo .ps1 y ejecútalo de nuevo (clic derecho > Ejecutar con PowerShell).'
        exit
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) {
        Show-StartupMessage 'No se encontró Windows PowerShell 5.1 en este equipo. Esta herramienta lo necesita.'
        exit
    }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $selfPath
    try {
        if ($script:IsAdmin) { Start-Process -FilePath $psExe -ArgumentList $argLine }
        else                 { Start-Process -FilePath $psExe -ArgumentList $argLine -Verb RunAs }
    } catch {
        Show-StartupMessage "Esta herramienta necesita permisos de administrador para reiniciar servicios y cerrar procesos.`r`n`r`nAcepta el aviso de UAC para continuar."
    }
    exit
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Show-StartupMessage 'PowerShell está en modo de lenguaje restringido (Constrained Language Mode). Esta herramienta no puede ejecutarse así.'
    exit
}

# ============================================================================
#  2) ENSAMBLADOS, DPI Y CONTROLES MODERNOS (C#)
# ============================================================================
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
} catch {
    Show-StartupMessage ('No se pudieron cargar los componentes de Windows Forms: ' + $_.Exception.Message)
    exit
}

$script:CsSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Vanguard.UI
{
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogRCW { }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("d57c7288-d4ad-4768-be02-9d969532d960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
    }

    public static class Native
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr hAfter, int x, int y, int cx, int cy, uint flags);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string ids);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid, out IShellItem ppv);

        static Dictionary<string, bool> _fonts = new Dictionary<string, bool>();

        public static void TrySetDpiAware()
        {
            try { SetProcessDPIAware(); } catch (Exception) { }
        }

        public static void SetDarkTitleBar(IntPtr h, bool dark)
        {
            try
            {
                int v = dark ? 1 : 0;
                if (DwmSetWindowAttribute(h, 20, ref v, 4) != 0) { DwmSetWindowAttribute(h, 19, ref v, 4); }
                SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020);
            }
            catch (Exception) { }
        }

        public static void SetControlTheme(IntPtr h, bool dark)
        {
            try { SetWindowTheme(h, dark ? "DarkMode_Explorer" : "Explorer", null); } catch (Exception) { }
        }

        public static bool HasFont(string name)
        {
            bool r;
            if (_fonts.TryGetValue(name, out r)) return r;
            r = false;
            try
            {
                using (InstalledFontCollection c = new InstalledFontCollection())
                {
                    foreach (FontFamily f in c.Families)
                    {
                        if (string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase)) { r = true; break; }
                    }
                }
            }
            catch (Exception) { }
            _fonts[name] = r;
            return r;
        }

        // Selector de carpetas moderno (IFileOpenDialog con FOS_PICKFOLDERS). Devuelve null si se cancela.
        public static string PickFolder(IntPtr owner, string title, string initial)
        {
            IFileOpenDialog dlg = null;
            try
            {
                dlg = (IFileOpenDialog)(object)new FileOpenDialogRCW();
                uint opts;
                dlg.GetOptions(out opts);
                dlg.SetOptions(opts | 0x20u | 0x40u | 0x800u);
                if (!string.IsNullOrEmpty(title)) dlg.SetTitle(title);
                if (!string.IsNullOrEmpty(initial) && System.IO.Directory.Exists(initial))
                {
                    Guid iid = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
                    IShellItem si;
                    SHCreateItemFromParsingName(initial, IntPtr.Zero, ref iid, out si);
                    dlg.SetFolder(si);
                }
                int hr = dlg.Show(owner);
                if (hr != 0) return null;
                IShellItem res;
                dlg.GetResult(out res);
                string path;
                res.GetDisplayName(0x80058000u, out path);
                return path;
            }
            finally
            {
                if (dlg != null) { try { Marshal.ReleaseComObject(dlg); } catch (Exception) { } }
            }
        }
    }

    public static class Gfx
    {
        public static GraphicsPath RoundRect(RectangleF r, float radius)
        {
            GraphicsPath p = new GraphicsPath();
            float d = radius * 2f;
            if (d > r.Width) d = r.Width;
            if (d > r.Height) d = r.Height;
            if (d <= 1f) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        public static GraphicsPath Pill(RectangleF r)
        {
            return RoundRect(r, r.Height / 2f);
        }

        public static Color Lerp(Color a, Color b, float t)
        {
            if (t < 0f) t = 0f;
            if (t > 1f) t = 1f;
            return Color.FromArgb(
                (int)(a.A + (b.A - a.A) * t),
                (int)(a.R + (b.R - a.R) * t),
                (int)(a.G + (b.G - a.G) * t),
                (int)(a.B + (b.B - a.B) * t));
        }

        public static float Scale(Graphics g)
        {
            return g.DpiX / 96f;
        }

        public static void ClearBack(Graphics g, Control c)
        {
            if (c.BackColor.A == 255) g.Clear(c.BackColor);
        }
    }

    // ---------------------------------------------------------------- Cabecera con degradado
    public class GradientPanel : Panel
    {
        public Color ColorA = Color.FromArgb(124, 58, 237);
        public Color ColorB = Color.FromArgb(37, 99, 235);
        public Color ColorC = Color.FromArgb(236, 72, 153);

        public GradientPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (ClientRectangle.Width < 2 || ClientRectangle.Height < 2) return;
            using (LinearGradientBrush br = new LinearGradientBrush(ClientRectangle, ColorA, ColorC, 0f))
            {
                ColorBlend cb = new ColorBlend();
                cb.Colors = new Color[] { ColorA, ColorB, ColorC };
                cb.Positions = new float[] { 0f, 0.55f, 1f };
                br.InterpolationColors = cb;
                e.Graphics.FillRectangle(br, ClientRectangle);
            }
        }
    }

    // ---------------------------------------------------------------- Panel redondeado
    public class RoundedPanel : Panel
    {
        public Color Fill = Color.White;
        public Color Border = Color.Silver;
        public float Radius = 12f;
        public float BorderWidth = 1f;

        public RoundedPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width < 4 || Height < 4) return;
            Graphics g = e.Graphics;
            float s = Gfx.Scale(g);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Gfx.ClearBack(g, this);
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 2f, Height - 2f);
            using (GraphicsPath p = Gfx.RoundRect(r, Radius * s))
            using (SolidBrush b = new SolidBrush(Fill))
            using (Pen pen = new Pen(Border, BorderWidth))
            {
                g.FillPath(b, p);
                g.DrawPath(pen, p);
            }
        }
    }

    // ---------------------------------------------------------------- Interruptor (modo sol/luna o normal)
    public class ToggleSwitch : Control
    {
        bool _checked;
        float _t;
        Timer _timer;
        public bool SunMoon = false;
        public Color OnColor = Color.FromArgb(124, 58, 237);
        public Color OffColor = Color.FromArgb(160, 160, 175);
        public event EventHandler CheckedChanged;

        public ToggleSwitch()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.StandardClick | ControlStyles.SupportsTransparentBackColor, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            Size = new Size(64, 32);
            _timer = new Timer();
            _timer.Interval = 15;
            _timer.Tick += new EventHandler(OnTick);
        }

        public bool Checked
        {
            get { return _checked; }
            set
            {
                if (_checked == value) return;
                _checked = value;
                _timer.Start();
                if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty);
            }
        }

        public void SetCheckedSilent(bool v)
        {
            _checked = v;
            _t = v ? 1f : 0f;
            _timer.Stop();
            Invalidate();
        }

        void OnTick(object sender, EventArgs e)
        {
            float target = _checked ? 1f : 0f;
            float step = 0.12f;
            if (_t < target) { _t += step; if (_t >= target) { _t = target; _timer.Stop(); } }
            else if (_t > target) { _t -= step; if (_t <= target) { _t = target; _timer.Stop(); } }
            else { _timer.Stop(); }
            Invalidate();
        }

        protected override void OnClick(EventArgs e)
        {
            base.OnClick(e);
            Checked = !_checked;
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { Checked = !_checked; e.Handled = true; }
        }

        protected override bool IsInputKey(Keys keyData)
        {
            if (keyData == Keys.Space || keyData == Keys.Enter) return true;
            return base.IsInputKey(keyData);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && _timer != null) { _timer.Stop(); _timer.Dispose(); _timer = null; }
            base.Dispose(disposing);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width < 8 || Height < 8) return;
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Gfx.ClearBack(g, this);
            float w = Width - 2f, h = Height - 2f;
            RectangleF tr = new RectangleF(1f, 1f, w, h);
            float eased = _t * _t * (3f - 2f * _t);
            Color fill = Gfx.Lerp(OffColor, OnColor, eased);
            using (GraphicsPath p = Gfx.Pill(tr))
            using (SolidBrush b = new SolidBrush(fill))
            {
                g.FillPath(b, p);
            }
            float pad = h * 0.13f;
            float d = h - 2f * pad;
            float x0 = tr.X + pad;
            float x1 = tr.Right - pad - d;
            float kx = x0 + (x1 - x0) * eased;
            RectangleF knob = new RectangleF(kx, tr.Y + pad, d, d);
            if (SunMoon)
            {
                PaintSunMoon(g, tr, knob, eased);
            }
            else
            {
                using (SolidBrush sh = new SolidBrush(Color.FromArgb(45, 0, 0, 0)))
                    g.FillEllipse(sh, knob.X, knob.Y + 1.5f, knob.Width, knob.Height);
                using (SolidBrush kb = new SolidBrush(Color.White))
                    g.FillEllipse(kb, knob);
            }
        }

        void PaintSunMoon(Graphics g, RectangleF tr, RectangleF knob, float t)
        {
            float u = tr.Height;
            int starA = (int)(255 * t);
            int cloudA = (int)(215 * (1f - t));
            using (SolidBrush sb = new SolidBrush(Color.FromArgb(starA, 255, 255, 255)))
            {
                g.FillEllipse(sb, tr.X + u * 0.28f, tr.Y + u * 0.26f, u * 0.10f, u * 0.10f);
                g.FillEllipse(sb, tr.X + u * 0.50f, tr.Y + u * 0.60f, u * 0.07f, u * 0.07f);
                g.FillEllipse(sb, tr.X + u * 0.72f, tr.Y + u * 0.24f, u * 0.06f, u * 0.06f);
            }
            using (SolidBrush cb = new SolidBrush(Color.FromArgb(cloudA, 255, 255, 255)))
            {
                float cx = tr.Right - u * 1.05f;
                float cy = tr.Y + u * 0.56f;
                g.FillEllipse(cb, cx, cy, u * 0.34f, u * 0.20f);
                g.FillEllipse(cb, cx + u * 0.14f, cy - u * 0.14f, u * 0.28f, u * 0.28f);
                g.FillEllipse(cb, cx + u * 0.30f, cy, u * 0.30f, u * 0.20f);
            }
            using (SolidBrush sh = new SolidBrush(Color.FromArgb(50, 0, 0, 0)))
                g.FillEllipse(sh, knob.X, knob.Y + 1.5f, knob.Width, knob.Height);
            Color baseC = Gfx.Lerp(Color.FromArgb(255, 193, 37), Color.FromArgb(226, 229, 244), t);
            using (SolidBrush kb = new SolidBrush(baseC))
                g.FillEllipse(kb, knob);

            float r = knob.Width / 2f;
            float cxk = knob.X + r;
            float cyk = knob.Y + r;
            if (t < 0.99f)
            {
                int a = (int)(255 * (1f - t));
                using (Pen rp = new Pen(Color.FromArgb(a, 255, 236, 150), Math.Max(1.5f, r * 0.13f)))
                {
                    rp.StartCap = LineCap.Round;
                    rp.EndCap = LineCap.Round;
                    for (int i = 0; i < 8; i++)
                    {
                        double ang = i * Math.PI / 4.0;
                        float ca = (float)Math.Cos(ang);
                        float sa = (float)Math.Sin(ang);
                        g.DrawLine(rp, cxk + ca * r * 0.56f, cyk + sa * r * 0.56f, cxk + ca * r * 0.82f, cyk + sa * r * 0.82f);
                    }
                }
                using (SolidBrush core = new SolidBrush(Color.FromArgb(a, 255, 246, 196)))
                    g.FillEllipse(core, cxk - r * 0.36f, cyk - r * 0.36f, r * 0.72f, r * 0.72f);
            }
            if (t > 0.01f)
            {
                int a2 = (int)(255 * t);
                using (SolidBrush cr = new SolidBrush(Color.FromArgb(a2, 188, 193, 216)))
                {
                    g.FillEllipse(cr, cxk - r * 0.55f, cyk - r * 0.30f, r * 0.42f, r * 0.42f);
                    g.FillEllipse(cr, cxk + r * 0.10f, cyk + r * 0.20f, r * 0.34f, r * 0.34f);
                    g.FillEllipse(cr, cxk + r * 0.05f, cyk - r * 0.58f, r * 0.24f, r * 0.24f);
                }
            }
        }
    }

    // ---------------------------------------------------------------- Boton redondeado
    public class RoundButton : Control
    {
        public Color FillA = Color.FromArgb(124, 58, 237);
        public Color FillB = Color.FromArgb(79, 70, 229);
        public Color TextColor = Color.White;
        public Color BorderColor = Color.Transparent;
        public float Radius = 10f;
        bool _hover, _down;

        public RoundButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.StandardClick | ControlStyles.SupportsTransparentBackColor, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            Font = new Font("Segoe UI Semibold", 9.5f, FontStyle.Regular, GraphicsUnit.Point);
            Size = new Size(120, 36);
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _down = true; Focus(); Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
        protected override bool IsInputKey(Keys keyData) { if (keyData == Keys.Space || keyData == Keys.Enter) return true; return base.IsInputKey(keyData); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { e.Handled = true; OnClick(EventArgs.Empty); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width < 8 || Height < 8) return;
            Graphics g = e.Graphics;
            float s = Gfx.Scale(g);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Gfx.ClearBack(g, this);
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 2f, Height - 2f);
            Color back = BackColor.A == 255 ? BackColor : Color.FromArgb(128, 128, 128);
            Color a = FillA, b = FillB;
            if (!Enabled) { a = Gfx.Lerp(a, back, 0.65f); b = Gfx.Lerp(b, back, 0.65f); }
            else if (_down) { a = Gfx.Lerp(a, Color.Black, 0.18f); b = Gfx.Lerp(b, Color.Black, 0.18f); }
            else if (_hover) { a = Gfx.Lerp(a, Color.White, 0.14f); b = Gfx.Lerp(b, Color.White, 0.14f); }
            using (GraphicsPath p = Gfx.RoundRect(r, Radius * s))
            {
                if (a.ToArgb() == b.ToArgb())
                {
                    using (SolidBrush sb = new SolidBrush(a)) g.FillPath(sb, p);
                }
                else
                {
                    using (LinearGradientBrush lb = new LinearGradientBrush(r, a, b, 0f)) g.FillPath(lb, p);
                }
                if (BorderColor.A > 0)
                {
                    using (Pen pen = new Pen(BorderColor, 1f)) g.DrawPath(pen, p);
                }
            }
            Color tc = Enabled ? TextColor : Gfx.Lerp(TextColor, back, 0.5f);
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, tc,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
            if (Focused && ShowFocusCues)
            {
                RectangleF fr = new RectangleF(3f * s, 3f * s, Width - 7f * s, Height - 7f * s);
                using (Pen fp = new Pen(Color.FromArgb(140, tc), 1f))
                {
                    fp.DashStyle = DashStyle.Dot;
                    using (GraphicsPath fpth = Gfx.RoundRect(fr, Math.Max(2f, Radius * s - 3f * s))) g.DrawPath(fp, fpth);
                }
            }
        }
    }

    // ---------------------------------------------------------------- Tarjeta de accion
    public class ActionCard : Control
    {
        public string Title = "";
        public string Desc = "";
        public string Glyph = "";
        public string Badge = "";
        public bool ShowInfo = true;
        public Color AccentA = Color.FromArgb(124, 58, 237);
        public Color AccentB = Color.FromArgb(79, 70, 229);
        public Color CardBack = Color.White;
        public Color CardBorder = Color.Gainsboro;
        public Color TitleColor = Color.Black;
        public Color DescColor = Color.Gray;
        public event EventHandler InfoClick;
        bool _hover, _down, _overInfo, _swallow;
        Rectangle _info = Rectangle.Empty;
        Font _fTitle, _fDesc, _fInfo;

        public ActionCard()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.StandardClick | ControlStyles.SupportsTransparentBackColor, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            Size = new Size(380, 76);
            _fTitle = new Font("Segoe UI Semibold", 10.5f, FontStyle.Regular, GraphicsUnit.Point);
            _fDesc = new Font("Segoe UI", 8.5f, FontStyle.Regular, GraphicsUnit.Point);
            _fInfo = new Font("Segoe UI Semibold", 8.5f, FontStyle.Regular, GraphicsUnit.Point);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (_fTitle != null) { _fTitle.Dispose(); _fTitle = null; }
                if (_fDesc != null) { _fDesc.Dispose(); _fDesc = null; }
                if (_fInfo != null) { _fInfo.Dispose(); _fInfo = null; }
            }
            base.Dispose(disposing);
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; _overInfo = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            bool oi = ShowInfo && !_info.IsEmpty && _info.Contains(e.Location);
            if (oi != _overInfo) { _overInfo = oi; Invalidate(); }
            base.OnMouseMove(e);
        }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                _down = true;
                _swallow = _overInfo;
                Focus();
                Invalidate();
            }
            base.OnMouseDown(e);
        }
        protected override void OnMouseUp(MouseEventArgs e)
        {
            _down = false;
            Invalidate();
            base.OnMouseUp(e);
        }
        protected override void OnClick(EventArgs e)
        {
            if (_swallow)
            {
                _swallow = false;
                if (_overInfo && InfoClick != null) InfoClick(this, EventArgs.Empty);
                return;
            }
            base.OnClick(e);
        }
        protected override bool IsInputKey(Keys keyData) { if (keyData == Keys.Space || keyData == Keys.Enter) return true; return base.IsInputKey(keyData); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { e.Handled = true; _swallow = false; OnClick(EventArgs.Empty); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width < 60 || Height < 40) return;
            Graphics g = e.Graphics;
            float s = Gfx.Scale(g);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            Gfx.ClearBack(g, this);
            Color back0 = BackColor.A == 255 ? BackColor : CardBack;
            RectangleF r = new RectangleF(1f, 1f, Width - 3f, Height - 3f);
            float rad = 14f * s;
            Color back = CardBack;
            if (!Enabled) back = Gfx.Lerp(CardBack, back0, 0.45f);
            else if (_down) back = Gfx.Lerp(CardBack, AccentA, 0.18f);
            else if (_hover) back = Gfx.Lerp(CardBack, AccentA, 0.08f);
            using (GraphicsPath p = Gfx.RoundRect(r, rad))
            {
                using (SolidBrush b = new SolidBrush(back)) g.FillPath(b, p);
                if ((_hover || Focused) && Enabled)
                {
                    using (LinearGradientBrush lb = new LinearGradientBrush(r, AccentA, AccentB, 0f))
                    using (Pen pen = new Pen(lb, 2f)) g.DrawPath(pen, p);
                }
                else
                {
                    using (Pen pen = new Pen(CardBorder, 1f)) g.DrawPath(pen, p);
                }
            }

            float pad = 14f * s;
            float dia = 46f * s;
            RectangleF ic = new RectangleF(r.X + pad, r.Y + (r.Height - dia) / 2f, dia, dia);
            Color ia = Enabled ? AccentA : Gfx.Lerp(AccentA, back0, 0.55f);
            Color ib = Enabled ? AccentB : Gfx.Lerp(AccentB, back0, 0.55f);
            using (LinearGradientBrush lb2 = new LinearGradientBrush(ic, ia, ib, 45f))
                g.FillEllipse(lb2, ic);
            using (StringFormat sf = new StringFormat())
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                if (!string.IsNullOrEmpty(Glyph) && Native.HasFont("Segoe MDL2 Assets"))
                {
                    using (Font gf = new Font("Segoe MDL2 Assets", 17f, FontStyle.Regular, GraphicsUnit.Point))
                    using (SolidBrush wb = new SolidBrush(Color.White))
                        g.DrawString(Glyph, gf, wb, ic, sf);
                }
                else
                {
                    using (Font bf = new Font("Segoe UI", 15f, FontStyle.Bold, GraphicsUnit.Point))
                    using (SolidBrush wb = new SolidBrush(Color.White))
                        g.DrawString(Badge, bf, wb, ic, sf);
                }
            }

            int infoD = (int)(20f * s);
            _info = new Rectangle((int)(r.Right - pad - infoD + 4f * s), (int)(r.Y + 10f * s), infoD, infoD);
            float tx = ic.Right + 14f * s;
            float tw = (ShowInfo ? _info.X - 6f * s : r.Right - pad) - tx;
            if (tw < 40f) tw = 40f;
            Color tcol = Enabled ? TitleColor : Gfx.Lerp(TitleColor, back0, 0.5f);
            Color dcol = Enabled ? DescColor : Gfx.Lerp(DescColor, back0, 0.5f);
            Rectangle tRect = new Rectangle((int)tx, (int)(r.Y + 11f * s), (int)tw, (int)(22f * s));
            Rectangle dRect = new Rectangle((int)tx, (int)(r.Y + 34f * s), (int)(r.Right - pad - tx), (int)(r.Height - 34f * s - 8f * s));
            TextRenderer.DrawText(g, Title, _fTitle, tRect, tcol, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
            TextRenderer.DrawText(g, Desc, _fDesc, dRect, dcol, TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);

            if (ShowInfo)
            {
                Color ic2 = _overInfo ? AccentA : Gfx.Lerp(DescColor, back0, 0.25f);
                RectangleF infoF = new RectangleF(_info.X, _info.Y, _info.Width, _info.Height);
                using (Pen ip = new Pen(ic2, 1.4f)) g.DrawEllipse(ip, infoF);
                TextRenderer.DrawText(g, "i", _fInfo, _info, ic2, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            }
        }
    }

    // ---------------------------------------------------------------- Boton con mascara (icono GitHub)
    public class MaskButton : Control
    {
        public Bitmap Mask;
        public Color Tint = Color.White;
        public Color HoverFill = Color.FromArgb(55, 255, 255, 255);
        public float IconScale = 0.62f;
        bool _hover, _down;

        public MaskButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.StandardClick | ControlStyles.SupportsTransparentBackColor, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            Size = new Size(40, 40);
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _down = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
        protected override bool IsInputKey(Keys keyData) { if (keyData == Keys.Space || keyData == Keys.Enter) return true; return base.IsInputKey(keyData); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { e.Handled = true; OnClick(EventArgs.Empty); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width < 8 || Height < 8) return;
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            Gfx.ClearBack(g, this);
            RectangleF full = new RectangleF(1f, 1f, Width - 3f, Height - 3f);
            if (_hover || _down || Focused)
            {
                int a = _down ? Math.Min(255, HoverFill.A + 40) : HoverFill.A;
                using (SolidBrush hb = new SolidBrush(Color.FromArgb(a, HoverFill.R, HoverFill.G, HoverFill.B)))
                    g.FillEllipse(hb, full);
            }
            if (Mask == null) return;
            float sz = Math.Min(Width, Height) * IconScale;
            if (_hover) sz *= 1.05f;
            Rectangle dest = new Rectangle((int)((Width - sz) / 2f), (int)((Height - sz) / 2f), (int)sz, (int)sz);
            float cr = Tint.R / 255f, cg = Tint.G / 255f, cb = Tint.B / 255f;
            ColorMatrix cm = new ColorMatrix(new float[][] {
                new float[] { 0, 0, 0, 0, 0 },
                new float[] { 0, 0, 0, 0, 0 },
                new float[] { 0, 0, 0, 0, 0 },
                new float[] { 0, 0, 0, 1, 0 },
                new float[] { cr, cg, cb, 0, 1 } });
            using (ImageAttributes ia = new ImageAttributes())
            {
                ia.SetColorMatrix(cm);
                ia.SetWrapMode(WrapMode.TileFlipXY);
                g.DrawImage(Mask, dest, 0, 0, Mask.Width, Mask.Height, GraphicsUnit.Pixel, ia);
            }
        }
    }

    // ---------------------------------------------------------------- Barra de progreso con degradado
    public class GradientProgress : Control
    {
        int _v;
        bool _marquee;
        float _m;
        Timer _timer;
        public Color Track = Color.FromArgb(40, 44, 66);
        public Color ColorA = Color.FromArgb(167, 139, 250);
        public Color ColorB = Color.FromArgb(56, 189, 248);

        public GradientProgress()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            Size = new Size(300, 8);
            _timer = new Timer();
            _timer.Interval = 20;
            _timer.Tick += new EventHandler(OnTick);
        }

        public int Value
        {
            get { return _v; }
            set { int n = value; if (n < 0) n = 0; if (n > 100) n = 100; _v = n; Invalidate(); }
        }

        public bool Marquee
        {
            get { return _marquee; }
            set
            {
                if (_marquee == value) return;
                _marquee = value;
                if (_marquee) _timer.Start(); else { _timer.Stop(); Invalidate(); }
            }
        }

        void OnTick(object sender, EventArgs e)
        {
            _m += 0.018f;
            if (_m > 1.3f) _m = -0.3f;
            Invalidate();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && _timer != null) { _timer.Stop(); _timer.Dispose(); _timer = null; }
            base.Dispose(disposing);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width < 8 || Height < 3) return;
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Gfx.ClearBack(g, this);
            RectangleF tr = new RectangleF(0f, 0f, Width - 1f, Height - 1f);
            using (GraphicsPath p = Gfx.Pill(tr))
            using (SolidBrush tb = new SolidBrush(Track))
                g.FillPath(tb, p);
            float x, w;
            if (_marquee) { w = tr.Width * 0.30f; x = tr.X + tr.Width * _m; }
            else { w = tr.Width * _v / 100f; x = tr.X; }
            if (w < 1f) return;
            float x2 = x + w;
            if (x < tr.X) x = tr.X;
            if (x2 > tr.Right) x2 = tr.Right;
            if (x2 - x < 2f) return;
            RectangleF fr = new RectangleF(x, tr.Y, x2 - x, tr.Height);
            using (GraphicsPath fp = Gfx.Pill(fr))
            using (LinearGradientBrush lb = new LinearGradientBrush(new RectangleF(fr.X - 1f, fr.Y, fr.Width + 2f, fr.Height), ColorA, ColorB, 0f))
                g.FillPath(lb, fp);
        }
    }
}
'@

try {
    if (-not ('Vanguard.UI.Native' -as [type])) {
        Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition $script:CsSource -Language CSharp
    }
} catch {
    Show-StartupMessage ('No se pudieron compilar los controles de la interfaz: ' + $_.Exception.Message)
    exit
}
[Vanguard.UI.Native]::TrySetDpiAware()

$script:Scale = 1.0
try {
    $gScr = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = [math]::Round($gScr.DpiX / 96.0, 2)
    $gScr.Dispose()
} catch { $script:Scale = 1.0 }
if ($script:Scale -lt 1.0) { $script:Scale = 1.0 }

function px([double]$v)            { return [int][math]::Round($v * $script:Scale) }
function PT([double]$x, [double]$y){ return [System.Drawing.Point]::new((px $x), (px $y)) }
function SZ([double]$w, [double]$h){ return [System.Drawing.Size]::new((px $w), (px $h)) }
function RGB([int]$r, [int]$g, [int]$b) { return [System.Drawing.Color]::FromArgb(255, $r, $g, $b) }

# ============================================================================
#  3) CARPETAS DE DATOS (instantáneas, registros) Y AJUSTES
# ============================================================================
$script:DataBase = $env:LOCALAPPDATA
if (-not $script:DataBase) { $script:DataBase = [System.IO.Path]::GetTempPath() }
$script:DataDir      = Join-Path $script:DataBase $script:AppFolder
$script:BackupDir    = Join-Path $script:DataDir 'Backups'
$script:LogDir       = Join-Path $script:DataDir 'Logs'
$script:SettingsFile = Join-Path $script:DataDir 'settings.json'
$script:LogFile      = Join-Path $script:LogDir ((Get-Date -Format 'yyyyMMdd') + '.log')
foreach ($dataFolder in @($script:DataDir, $script:BackupDir, $script:LogDir)) {
    if (-not (Test-Path -LiteralPath $dataFolder)) {
        try { [void](New-Item -ItemType Directory -Force -Path $dataFolder -ErrorAction Stop) }
        catch { Write-Warning ('No se pudo crear la carpeta de datos: ' + $dataFolder) }
    }
}

# Si falla escribir el registro en archivo no hay otro sitio donde anotarlo.
function Write-FileLog([string]$Level, [string]$Message) {
    try {
        Add-Content -LiteralPath $script:LogFile -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Message) -Encoding UTF8 -ErrorAction Stop
    } catch { $null = $_ }
}

function Get-Setting([string]$Name, $Default) {
    try {
        if (Test-Path -LiteralPath $script:SettingsFile) {
            $json = Get-Content -LiteralPath $script:SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $json.$Name) { return $json.$Name }
        }
    } catch { Write-FileLog 'warn' ('No se pudo leer el ajuste ' + $Name + ': ' + $_.Exception.Message) }
    return $Default
}

function Set-Setting([string]$Name, $Value) {
    try {
        $bag = @{}
        if (Test-Path -LiteralPath $script:SettingsFile) {
            $json = Get-Content -LiteralPath $script:SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) { $bag[$prop.Name] = $prop.Value }
        }
        $bag[$Name] = $Value
        ($bag | ConvertTo-Json) | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8 -ErrorAction Stop
    } catch { Write-FileLog 'warn' ('No se pudo guardar el ajuste ' + $Name + ': ' + $_.Exception.Message) }
}

# ============================================================================
#  4) MOTOR COMPARTIDO (se carga en la ventana Y en el hilo de trabajo)
# ============================================================================
$script:WorkerPrelude = @'
try { Add-Type -AssemblyName System.ServiceProcess } catch { $null = $_ }

function Get-RiotNames {
    return @{
        LoL = @('League of Legends', 'LeagueClient', 'LeagueClientUx', 'LeagueClientUxRender', 'LeagueCrashHandler')
        Val = @('VALORANT', 'Valorant-Win64-Shipping', 'RiotClientServices', 'RiotClientCrashHandler', 'RiotClientUx', 'RiotClientUxRender')
    }
}

# Procesos de Riot en ejecución. Devuelve un contenedor: Ok, Items, Error.
function Get-RiotRunning {
    $names = Get-RiotNames
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList @([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $names.LoL) { $map[$n] = 'LoL' }
    foreach ($n in $names.Val) { $map[$n] = 'Val' }
    $list = New-Object System.Collections.ArrayList
    $procs = $null
    try { $procs = [System.Diagnostics.Process]::GetProcesses() }
    catch { return [pscustomobject]@{ Ok = $false; Items = @(); Error = $_.Exception.Message } }
    foreach ($pr in $procs) {
        try {
            $grp = $null
            if ($map.TryGetValue($pr.ProcessName, [ref]$grp)) {
                $pth = ''
                $tick = 0
                try { $pth = [string]$pr.MainModule.FileName } catch { $pth = '' }
                try { $tick = $pr.StartTime.Ticks } catch { $tick = 0 }
                [void]$list.Add([pscustomobject]@{ Name = $pr.ProcessName; Id = $pr.Id; Group = $grp; Path = $pth; Start = $tick })
            }
        } catch { $null = $_ }
        finally { try { $pr.Dispose() } catch { $null = $_ } }
    }
    $sorted = @($list | Sort-Object @{ Expression = { if ($_.Group -eq 'LoL') { 0 } else { 1 } } }, Name, Id)
    return [pscustomobject]@{ Ok = $true; Items = $sorted; Error = '' }
}

# Procesos de la lista que siguen vivos (mismo PID y mismo nombre).
function Get-RemainingTargets {
    param($Targets)
    $left = New-Object System.Collections.ArrayList
    $now = Get-RiotRunning
    if (-not $now.Ok) { return @() }
    foreach ($tg in @($Targets)) {
        foreach ($cur in @($now.Items)) {
            if ($cur.Id -eq $tg.Id -and $cur.Name -ieq $tg.Name) { [void]$left.Add($tg); break }
        }
    }
    return @($left)
}

function Test-PathInside {
    param([string]$PathValue, [string]$Base)
    if ([string]::IsNullOrWhiteSpace($Base)) { return $false }
    $baseNorm = $Base.TrimEnd('\')
    if ($PathValue -ieq $baseNorm) { return $true }
    return $PathValue.StartsWith($baseNorm + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

# Valida una ruta escrita/elegida por el usuario. Devuelve $null si es válida (o vacía = autodetección).
function Get-RiotPathReason {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($PathValue.Trim().Trim('"')) } catch { return 'La ruta indicada no es válida.' }
    if ($full.StartsWith('\\')) { return 'No se admiten rutas de red (UNC). Usa una carpeta local.' }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return 'La carpeta indicada no existe.' }
    $norm = $full.TrimEnd('\')
    if ($norm -match '^[A-Za-z]:$') { return 'No se admite la raíz completa de una unidad. Elige la carpeta «Riot Games».' }
    $blocked = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA)
    foreach ($bp in $blocked) {
        if ($bp -and (Test-PathInside -PathValue $norm -Base $bp)) {
            return ('Ruta protegida del sistema: ' + $bp.TrimEnd('\') + '. Deja el campo como está (se detecta sola) o elige otra carpeta.')
        }
    }
    if ($norm -imatch '^[A-Za-z]:\\(Windows|Program Files|Program Files \(x86\)|ProgramData)(\\|$)') { return 'Es una carpeta de sistema (Windows, Program Files o ProgramData).' }
    if ($norm -imatch '(^|\\)(System Volume Information|\$Recycle\.Bin|\$WinREAgent|\$Windows\.~BT|\$Windows\.~WS)(\\|$)') { return 'Es una carpeta interna del sistema.' }
    if ($norm -imatch '^[A-Za-z]:\\Users$') { return 'Es la carpeta Users completa. Elige la carpeta de Riot Games.' }
    if ($norm -imatch '^[A-Za-z]:\\Users\\[^\\]+$') { return 'Es la carpeta personal completa de un usuario. Elige la carpeta de Riot Games.' }
    if ($norm -imatch '^[A-Za-z]:\\Users\\[^\\]+\\AppData(\\|$)') { return 'AppData contiene datos internos de programas. Elige la carpeta de Riot Games.' }
    if ($env:USERPROFILE -and ($norm -ieq $env:USERPROFILE.TrimEnd('\'))) { return 'Es tu carpeta personal completa. Elige la carpeta de Riot Games.' }
    # Enlaces simbólicos / uniones: se comprueba la carpeta y todas las superiores (no se siguen).
    $cur = $norm
    while ($cur -and ($cur -notmatch '^[A-Za-z]:\\?$')) {
        try {
            $di = New-Object System.IO.DirectoryInfo($cur)
            if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $lt = ''
                try { $lt = [string]$di.LinkType } catch { $lt = '' }
                if ($lt -eq 'Junction' -or $lt -eq 'SymbolicLink') { return 'La carpeta (o una superior) es un enlace simbólico o unión. Selecciona la carpeta real.' }
            }
        } catch { return 'No se pudo comprobar la carpeta indicada.' }
        $cur = [System.IO.Path]::GetDirectoryName($cur)
    }
    return $null
}

# Busca RiotClientServices.exe: ruta del usuario > RiotClientInstalls.json > ubicaciones habituales.
function Find-RiotClient {
    param([string]$UserPath)
    $res = [pscustomobject]@{ Exe = $null; Source = ''; Issue = $null; UriHandler = $false }
    $cands = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($UserPath)) {
        $why = Get-RiotPathReason -PathValue $UserPath
        if ($why) { $res.Issue = $why }
        else {
            try {
                $up = [System.IO.Path]::GetFullPath($UserPath.Trim().Trim('"')).TrimEnd('\')
                [void]$cands.Add(@(($up + '\Riot Client\RiotClientServices.exe'), 'ruta indicada'))
                [void]$cands.Add(@(($up + '\RiotClientServices.exe'), 'ruta indicada'))
                [void]$cands.Add(@(($up + '\Riot Games\Riot Client\RiotClientServices.exe'), 'ruta indicada'))
            } catch { $res.Issue = 'La ruta indicada no es válida.' }
        }
    }
    try {
        if ($env:ProgramData) {
            $jsonFile = Join-Path $env:ProgramData 'Riot Games\RiotClientInstalls.json'
            if (Test-Path -LiteralPath $jsonFile -PathType Leaf) {
                $inst = Get-Content -LiteralPath $jsonFile -Raw -ErrorAction Stop | ConvertFrom-Json
                foreach ($key in @('rc_default', 'rc_live', 'rc_beta')) {
                    $val = $inst.$key
                    if ($val) { [void]$cands.Add(@([string]$val, 'RiotClientInstalls.json')) }
                }
            }
        }
    } catch { $null = $_ }
    $bases = @(($env:SystemDrive + '\'), $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)
    foreach ($bs in $bases) {
        if ($bs) { [void]$cands.Add(@((Join-Path $bs 'Riot Games\Riot Client\RiotClientServices.exe'), 'ubicación habitual')) }
    }
    foreach ($cd in $cands) {
        try {
            $cp = [System.IO.Path]::GetFullPath([string]$cd[0])
            if (Test-Path -LiteralPath $cp -PathType Leaf) { $res.Exe = $cp; $res.Source = [string]$cd[1]; break }
        } catch { $null = $_ }
    }
    try { $res.UriHandler = [bool](Test-Path -LiteralPath 'Registry::HKEY_CLASSES_ROOT\riotclient') } catch { $res.UriHandler = $false }
    return $res
}

function Get-RiotRootFromExe([string]$Exe) {
    try {
        $dir = [System.IO.Path]::GetDirectoryName($Exe)
        if ((Split-Path -Leaf $dir) -ieq 'Riot Client') { return [System.IO.Path]::GetDirectoryName($dir) }
        return $dir
    } catch { return '' }
}

function Test-RiotSignature {
    param([string]$Exe)
    $res = [pscustomobject]@{ Ok = $false; Detail = '' }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Exe -ErrorAction Stop
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate -and ($sig.SignerCertificate.Subject -match 'Riot Games')) { $res.Ok = $true }
        else { $res.Detail = 'Estado de la firma: ' + [string]$sig.Status }
    } catch { $res.Detail = $_.Exception.Message }
    return $res
}

# Servicio por nombre sin lanzar excepciones: contenedor Ok, Svc, Error.
function Get-ServiceByName([string]$Name) {
    try {
        foreach ($sv in @(Get-Service -ErrorAction Stop)) {
            if ($sv.Name -ieq $Name) { return [pscustomobject]@{ Ok = $true; Svc = $sv; Error = '' } }
        }
        return [pscustomobject]@{ Ok = $true; Svc = $null; Error = '' }
    } catch { return [pscustomobject]@{ Ok = $false; Svc = $null; Error = $_.Exception.Message } }
}

# Estado de un servicio/controlador (p. ej. vgk) o '' si no se pudo determinar.
function Get-DriverState([string]$Name) {
    try {
        $ctl = New-Object System.ServiceProcess.ServiceController($Name)
        $st = [string]$ctl.Status
        $ctl.Dispose()
        return $st
    } catch { return '' }
}

function Invoke-Tool {
    param([string]$Exe, [string]$Arguments, [int]$TimeoutSec = 60)
    $r = [pscustomobject]@{ ExitCode = -1; Output = ''; Cancelled = $false; TimedOut = $false }
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $enc = $null
        try { $enc = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
        catch { $enc = [System.Text.Encoding]::Default }
        $psi.StandardOutputEncoding = $enc
        $psi.StandardErrorEncoding = $enc
        $proc = [System.Diagnostics.Process]::Start($psi)
        $tOut = $proc.StandardOutput.ReadToEndAsync()
        $tErr = $proc.StandardError.ReadToEndAsync()
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.WaitForExit(250)) {
            if ($Ctx.State.Cancel) { try { $proc.Kill() } catch { $null = $_ }; $r.Cancelled = $true; break }
            if ($clock.Elapsed.TotalSeconds -gt $TimeoutSec) { try { $proc.Kill() } catch { $null = $_ }; $r.TimedOut = $true; break }
        }
        if ($r.Cancelled -or $r.TimedOut) { [void]$proc.WaitForExit(2000) }
        else { $proc.WaitForExit(); $r.ExitCode = $proc.ExitCode }
        $txt = ''
        try { if ($tOut.Wait(2000)) { $txt += [string]$tOut.Result } } catch { $null = $_ }
        try { if ($tErr.Wait(2000)) { $txt += "`n" + [string]$tErr.Result } } catch { $null = $_ }
        $r.Output = $txt
    } catch { $r.Output = 'ERROR: ' + $_.Exception.Message }
    finally { if ($proc) { try { $proc.Dispose() } catch { $null = $_ } } }
    return $r
}

function Save-Snapshot {
    param([string]$Dir, [string]$Tag, $Data)
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { [void](New-Item -ItemType Directory -Force -Path $Dir -ErrorAction Stop) }
        $file = Join-Path $Dir ('{0}_{1}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $Tag)
        ($Data | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $file -Encoding UTF8 -ErrorAction Stop
        return $file
    } catch { return '' }
}
'@

# Cargar el motor también en la ventana (detección de procesos y de Riot Client) con un contexto mínimo.
$script:Ctx = @{ State = @{ Cancel = $false } }
$Ctx = $script:Ctx
. ([scriptblock]::Create($script:WorkerPrelude))

# ============================================================================
#  5) OPERACIONES EN SEGUNDO PLANO (solo existen dentro del runspace)
# ============================================================================
$script:WorkerHeader = @'
$ErrorActionPreference = 'Continue'
function Say([string]$m, [string]$lvl = 'info') { $Ctx.Q.Enqueue([pscustomobject]@{ T = 'log'; Text = $m; Level = $lvl }) }
function Prog([int]$p, [string]$m) { $Ctx.Q.Enqueue([pscustomobject]@{ T = 'prog'; Pct = $p; Text = $m }) }
function Done($r) { $Ctx.Q.Enqueue([pscustomobject]@{ T = 'done'; Result = $r }) }
function Cancelled { return [bool]$Ctx.State.Cancel }
function Step-Check { if (Cancelled) { throw 'CANCELLED' } }
function Wait-Seconds {
    param([double]$Seconds)
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $until) {
        if (Cancelled) { return $false }
        Start-Sleep -Milliseconds 100
    }
    return $true
}
function Wait-ServiceStatus {
    param($Svc, [string]$Status, [int]$TimeoutSec, [bool]$HonorCancel)
    $limit = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $limit) {
        try { $Svc.Refresh() } catch { return $false }
        if ([string]$Svc.Status -eq $Status) { return $true }
        if ($HonorCancel -and (Cancelled)) { return $false }
        Start-Sleep -Milliseconds 250
    }
    try { $Svc.Refresh() } catch { return $false }
    return ([string]$Svc.Status -eq $Status)
}
function Say-Lines([string]$Text, [string]$Level = 'info', [int]$Max = 4) {
    if (-not $Text) { return }
    $shown = 0
    foreach ($ln in ($Text -split "\r?\n")) {
        if ($ln.Trim()) { Say ('    ' + $ln.Trim()) $Level; $shown++ }
        if ($shown -ge $Max) { break }
    }
}
'@

$script:WorkerOps = @'
# ---- Cierra los procesos indicados (verifica PID + nombre + hora de inicio antes de cada Kill) ----
function Op-CloseProcesses {
    param($Targets, [bool]$Verify = $true)
    $res = [pscustomobject]@{ Found = $null; Closed = 0; Failed = 0; Gone = 0; Remaining = 0; Manifest = '' }
    $list = @($Targets)
    if ($list.Count -eq 0) { Say 'No había procesos de Riot abiertos.'; return $res }
    foreach ($tg in $list) { if ($tg.Group -eq 'LoL') { $res.Found = 'LoL'; break } }
    if (-not $res.Found) { foreach ($tg in $list) { if ($tg.Group -eq 'Val') { $res.Found = 'Valorant'; break } } }
    if ($res.Found -eq 'LoL') { Say 'League of Legends detectado.' 'warn' }
    elseif ($res.Found -eq 'Valorant') { Say 'Valorant / Riot Client detectado.' 'warn' }
    $res.Manifest = Save-Snapshot -Dir $Ctx.BackupDir -Tag 'procesos' -Data ([pscustomobject]@{ Fecha = (Get-Date).ToString('s'); Procesos = $list })
    if ($res.Manifest) { Say ('Registro de procesos guardado: ' + $res.Manifest) }
    foreach ($tg in $list) {
        Step-Check
        $pr = $null
        try { $pr = [System.Diagnostics.Process]::GetProcessById([int]$tg.Id) } catch { $res.Gone++; continue }
        try {
            if ($pr.ProcessName -ine [string]$tg.Name) { $res.Gone++; continue }
            if ([int64]$tg.Start -gt 0) {
                $tickNow = 0
                try { $tickNow = $pr.StartTime.Ticks } catch { $tickNow = 0 }
                if ($tickNow -ne 0 -and $tickNow -ne [int64]$tg.Start) { $res.Gone++; continue }
            }
            Say ('Cerrando {0} (PID {1})...' -f $tg.Name, $tg.Id)
            $pr.Kill()
            if ($pr.WaitForExit(4000)) { $res.Closed++ }
            else { $res.Failed++; Say ('{0} (PID {1}) no terminó a tiempo.' -f $tg.Name, $tg.Id) 'warn' }
        } catch {
            $res.Failed++
            Say ('No se pudo cerrar {0} (PID {1}): {2}' -f $tg.Name, $tg.Id, $_.Exception.Message) 'err'
        } finally { try { $pr.Dispose() } catch { $null = $_ } }
    }
    if ($Verify) {
        [void](Wait-Seconds 0.5)
        $res.Remaining = @(Get-RemainingTargets -Targets $list).Count
        if ($res.Remaining -gt 0) { Say ('Siguen abiertos {0} proceso(s). Vanguard protege el juego: usa «Reiniciar Vanguard» o «Restart completo».' -f $res.Remaining) 'warn' }
    }
    if ($res.Failed -eq 0 -and $res.Remaining -eq 0) { Say ('Procesos cerrados correctamente ({0}).' -f $res.Closed) 'ok' }
    return $res
}

# ---- Reinicia el servicio vgc. Una vez detenido, SIEMPRE se intenta volver a iniciar (aunque se cancele) ----
function Op-RestartVanguard {
    $res = [pscustomobject]@{ Ok = $false; Found = $false; Message = ''; Snapshot = '' }
    $scm = Get-ServiceByName 'vgc'
    if (-not $scm.Ok) { $res.Message = 'No se pudo consultar la lista de servicios: ' + $scm.Error; Say $res.Message 'err'; return $res }
    if (-not $scm.Svc) { $res.Message = 'El servicio vgc no existe: Vanguard no está instalado (o su instalación está dañada).'; Say $res.Message 'err'; return $res }
    $res.Found = $true
    $svc = $scm.Svc
    $startType = ''
    try { $startType = [string]$svc.StartType } catch { $startType = '' }
    Say ('Estado actual de vgc: {0} (inicio: {1}).' -f $svc.Status, $startType)
    $drv = Get-DriverState 'vgk'
    if ($drv) { Say ('Controlador vgk (kernel de Vanguard): ' + $drv + '.') } else { Say 'Controlador vgk: no se pudo determinar su estado.' 'warn' }
    $res.Snapshot = Save-Snapshot -Dir $Ctx.BackupDir -Tag 'vgc' -Data ([pscustomobject]@{ Servicio = 'vgc'; Estado = [string]$svc.Status; Inicio = $startType; Fecha = (Get-Date).ToString('s') })
    if ($res.Snapshot) { Say ('Instantánea del estado guardada: ' + $res.Snapshot) }
    if ($startType -eq 'Disabled') {
        $res.Message = 'El servicio vgc está deshabilitado y no se puede iniciar. Habilítalo en «Servicios» de Windows o reinstala Vanguard (esta herramienta no cambia la configuración de servicios).'
        Say $res.Message 'err'
        return $res
    }
    Step-Check
    $scExe = Join-Path $env:SystemRoot 'System32\sc.exe'
    $stopped = $true
    if ([string]$svc.Status -ne 'Stopped') {
        Say 'Deteniendo vgc...'
        try { Stop-Service -Name 'vgc' -Force -ErrorAction Stop }
        catch {
            Say ('Stop-Service falló ({0}). Probando con sc.exe...' -f $_.Exception.Message) 'warn'
            [void](Invoke-Tool -Exe $scExe -Arguments 'stop vgc' -TimeoutSec 30)
        }
        if (Wait-ServiceStatus -Svc $svc -Status 'Stopped' -TimeoutSec 20 -HonorCancel $false) { Say 'Servicio detenido.' 'ok' }
        else { $stopped = $false; Say 'vgc no llegó a detenerse por completo.' 'warn' }
    }
    Say 'Iniciando vgc...'
    try { $svc.Refresh() } catch { $null = $_ }
    if ([string]$svc.Status -ne 'Running') {
        try { Start-Service -Name 'vgc' -ErrorAction Stop }
        catch {
            Say ('Start-Service falló ({0}). Probando con sc.exe...' -f $_.Exception.Message) 'warn'
            [void](Invoke-Tool -Exe $scExe -Arguments 'start vgc' -TimeoutSec 30)
        }
    }
    $running = Wait-ServiceStatus -Svc $svc -Status 'Running' -TimeoutSec 20 -HonorCancel $false
    if ($running -and $stopped) { $res.Ok = $true; Say 'Vanguard reiniciado con éxito.' 'ok' }
    elseif ($running -and -not $stopped) { $res.Message = 'vgc sigue en ejecución pero no llegó a detenerse: no se pudo reiniciar. Prueba «Restart completo» o reinicia el equipo.'; Say $res.Message 'warn' }
    else { $res.Message = 'No se pudo confirmar que vgc esté en ejecución. Prueba «Restart completo» o reinicia el equipo.'; Say $res.Message 'warn' }
    return $res
}

# ---- Vacía la caché DNS (y opcionalmente la vuelve a registrar) ----
function Op-FlushDns {
    param([bool]$Register)
    $res = [pscustomobject]@{ Ok = $false; Registered = $false; Message = '' }
    $ipc = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
    Say 'Vaciando la caché DNS (ipconfig /flushdns)...'
    $fl = Invoke-Tool -Exe $ipc -Arguments '/flushdns' -TimeoutSec 30
    if ($fl.Cancelled) { throw 'CANCELLED' }
    if ($fl.ExitCode -eq 0) { $res.Ok = $true; Say 'Caché DNS vaciada.' 'ok' }
    else {
        $res.Message = 'ipconfig /flushdns terminó con el código {0}.' -f $fl.ExitCode
        if ($fl.TimedOut) { $res.Message = 'ipconfig /flushdns tardó demasiado y se detuvo.' }
        Say $res.Message 'err'
        Say-Lines $fl.Output 'err'
    }
    if ($Register) {
        Say 'Registrando DNS (ipconfig /registerdns)...'
        $rg = Invoke-Tool -Exe $ipc -Arguments '/registerdns' -TimeoutSec 30
        if ($rg.Cancelled) { throw 'CANCELLED' }
        if ($rg.ExitCode -eq 0) { $res.Registered = $true; Say 'DNS registrado.' 'ok' }
        else { Say ('ipconfig /registerdns terminó con el código {0}.' -f $rg.ExitCode) 'warn'; Say-Lines $rg.Output 'warn' }
    }
    return $res
}

# ---- Lanza LoL / Valorant / Riot Client (exe verificado por firma; si no, protocolo riotclient://) ----
function Op-Launch {
    param([string]$Product, [string]$UserPath)
    $res = [pscustomobject]@{ Ok = $false; Method = ''; Message = '' }
    $label = 'Riot Client'
    $cliArgs = ''
    $uri = [string]$Ctx.UriRiot
    switch ($Product) {
        'lol' { $label = 'League of Legends'; $cliArgs = '--launch-product=league_of_legends --launch-patchline=live'; $uri = [string]$Ctx.UriLol }
        'val' { $label = 'Valorant'; $cliArgs = '--launch-product=valorant --launch-patchline=live'; $uri = [string]$Ctx.UriVal }
    }
    Say ('Lanzando {0}...' -f $label)
    $info = Find-RiotClient -UserPath $UserPath
    if ($info.Issue) { Say ('Ruta de Riot indicada no usada: ' + $info.Issue) 'warn' }
    $problem = ''
    if ($info.Exe) {
        $sig = Test-RiotSignature -Exe $info.Exe
        if ($sig.Ok) {
            try {
                $workDir = Split-Path -Parent $info.Exe
                if ($cliArgs) { Start-Process -FilePath $info.Exe -ArgumentList $cliArgs -WorkingDirectory $workDir -ErrorAction Stop }
                else { Start-Process -FilePath $info.Exe -WorkingDirectory $workDir -ErrorAction Stop }
                $res.Ok = $true; $res.Method = 'exe'
                Say ('{0} lanzado mediante Riot Client ({1}).' -f $label, $info.Source) 'ok'
            } catch { $problem = 'No se pudo ejecutar Riot Client: ' + $_.Exception.Message; Say $problem 'warn' }
        } else {
            $problem = 'Riot Client encontrado pero su firma digital no se pudo verificar (' + $sig.Detail + '). No se ejecuta por seguridad.'
            Say $problem 'warn'
        }
    }
    if (-not $res.Ok -and $info.UriHandler) {
        try {
            Start-Process -FilePath $uri -ErrorAction Stop
            $res.Ok = $true; $res.Method = 'uri'
            Say ('{0} lanzado mediante el protocolo riotclient://.' -f $label) 'ok'
        } catch { $problem = 'No se pudo abrir el protocolo riotclient://: ' + $_.Exception.Message; Say $problem 'err' }
    }
    if (-not $res.Ok) {
        if (-not $info.Exe -and -not $info.UriHandler) { $res.Message = 'Riot Client no encontrado. Indica la carpeta de Riot Games con «Examinar» o instálalo.' }
        elseif ($problem) { $res.Message = $problem }
        else { $res.Message = 'No se pudo lanzar ' + $label + '.' }
        Say $res.Message 'err'
    }
    return $res
}
'@

# ---------------------------------------------------------------- DIAGNOSTICO (solo lectura)
$script:OpDiag = @'
$R = [ordered]@{ Ok = $false; Cancelled = $false; Message = ''; Lines = @(); Warnings = 0; Errors = 0 }
$lines = New-Object System.Collections.ArrayList
function Add-DiagLine([string]$Level, [string]$Text) {
    [void]$lines.Add(@($Level, $Text))
    Say $Text $Level
}
try {
    Prog 10 'Comprobando Vanguard...'
    $scm = Get-ServiceByName 'vgc'
    if (-not $scm.Ok) { Add-DiagLine 'err' ('No se pudo consultar los servicios: ' + $scm.Error); $R.Errors++ }
    elseif (-not $scm.Svc) { Add-DiagLine 'err' 'Servicio vgc: NO instalado (Vanguard ausente o dañado).'; $R.Errors++ }
    else {
        $stt = ''
        try { $stt = [string]$scm.Svc.StartType } catch { $stt = '?' }
        if ($stt -eq 'Disabled') { Add-DiagLine 'err' ('Servicio vgc: {0}, inicio {1} (no podrá iniciarse).' -f $scm.Svc.Status, $stt); $R.Errors++ }
        elseif ([string]$scm.Svc.Status -eq 'Running') { Add-DiagLine 'ok' ('Servicio vgc: en ejecución (inicio {0}).' -f $stt) }
        else { Add-DiagLine 'warn' ('Servicio vgc: {0} (inicio {1}). Puede ser normal si Vanguard solo se inicia al abrir el juego.' -f $scm.Svc.Status, $stt); $R.Warnings++ }
    }
    Step-Check
    $drv = Get-DriverState 'vgk'
    if ($drv -eq 'Running') { Add-DiagLine 'ok' 'Controlador vgk (kernel de Vanguard): en ejecución.' }
    elseif ($drv) { Add-DiagLine 'warn' ('Controlador vgk: {0}. Si ves errores VAN, reinicia el equipo.' -f $drv); $R.Warnings++ }
    else { Add-DiagLine 'warn' 'Controlador vgk: no se pudo determinar su estado.'; $R.Warnings++ }

    Prog 45 'Buscando procesos de Riot...'
    $run = Get-RiotRunning
    if (-not $run.Ok) { Add-DiagLine 'warn' ('No se pudieron listar los procesos: ' + $run.Error); $R.Warnings++ }
    elseif (@($run.Items).Count -eq 0) { Add-DiagLine 'info' 'Procesos de Riot abiertos: ninguno.' }
    else {
        $uniq = @($run.Items | ForEach-Object { $_.Name } | Sort-Object -Unique)
        Add-DiagLine 'info' ('Procesos de Riot abiertos: {0} ({1}).' -f @($run.Items).Count, ($uniq -join ', '))
    }
    Step-Check

    Prog 70 'Buscando Riot Client...'
    $cli = Find-RiotClient -UserPath ([string]$Ctx.RiotPath)
    if ($cli.Issue) { Add-DiagLine 'warn' ('Ruta de Riot indicada no válida: ' + $cli.Issue); $R.Warnings++ }
    if ($cli.Exe) {
        Add-DiagLine 'ok' ('Riot Client: {0} ({1}).' -f $cli.Exe, $cli.Source)
        $sg = Test-RiotSignature -Exe $cli.Exe
        if ($sg.Ok) { Add-DiagLine 'ok' 'Firma digital de Riot Client: válida (Riot Games).' }
        else { Add-DiagLine 'warn' ('Firma digital de Riot Client no verificada: ' + $sg.Detail); $R.Warnings++ }
    } else { Add-DiagLine 'warn' 'Riot Client: no encontrado en las ubicaciones habituales.'; $R.Warnings++ }
    if ($cli.UriHandler) { Add-DiagLine 'ok' 'Protocolo riotclient://: registrado en Windows.' }
    else { Add-DiagLine 'warn' 'Protocolo riotclient://: no registrado.'; $R.Warnings++ }
    $R.Lines = @($lines)
    $R.Ok = $true
    Prog 100 'Completado'
}
catch {
    $m = $_.Exception.Message
    if ($m -eq 'CANCELLED') { $R.Cancelled = $true; Say 'Diagnóstico cancelado.' 'warn' }
    else { $R.Message = 'Error inesperado: ' + $m; Say $R.Message 'err' }
}
Done ([pscustomobject]$R)
'@

# ---------------------------------------------------------------- CERRAR PROCESOS
$script:OpClose = @'
$R = [ordered]@{ Ok = $false; Cancelled = $false; Message = ''; Closed = 0; Failed = 0; Gone = 0; Remaining = 0 }
try {
    Prog 5 'Cerrando procesos seleccionados...'
    $cl = Op-CloseProcesses -Targets $Ctx.Targets -Verify $true
    $R.Closed = $cl.Closed; $R.Failed = $cl.Failed; $R.Gone = $cl.Gone; $R.Remaining = $cl.Remaining
    $R.Ok = ($cl.Failed -eq 0 -and $cl.Remaining -eq 0)
    Prog 100 'Completado'
}
catch {
    $m = $_.Exception.Message
    if ($m -eq 'CANCELLED') { $R.Cancelled = $true; Say 'Operación cancelada.' 'warn' }
    else { $R.Message = 'Error inesperado: ' + $m; Say $R.Message 'err' }
}
Done ([pscustomobject]$R)
'@

# ---------------------------------------------------------------- REINICIAR VANGUARD (y opcionalmente DNS)
$script:OpVanguard = @'
$R = [ordered]@{ Ok = $false; Cancelled = $false; Message = ''; VgOk = $false; VgFound = $false; WithDns = [bool]$Ctx.WithDns; DnsOk = $true }
try {
    Prog 10 'Reiniciando Vanguard (vgc)...'
    $vg = Op-RestartVanguard
    $R.VgOk = $vg.Ok; $R.VgFound = $vg.Found; $R.Message = $vg.Message
    if ($Ctx.WithDns) {
        if (-not (Wait-Seconds 1)) { throw 'CANCELLED' }
        Prog 70 'Limpiando DNS...'
        $dn = Op-FlushDns -Register ([bool]$Ctx.RegisterDns)
        $R.DnsOk = $dn.Ok
        if (-not $dn.Ok -and -not $R.Message) { $R.Message = $dn.Message }
    }
    $R.Ok = ($R.VgOk -and $R.DnsOk)
    Prog 100 'Completado'
}
catch {
    $m = $_.Exception.Message
    if ($m -eq 'CANCELLED') { $R.Cancelled = $true; Say 'Operación cancelada.' 'warn' }
    else { $R.Message = 'Error inesperado: ' + $m; Say $R.Message 'err' }
}
Done ([pscustomobject]$R)
'@

# ---------------------------------------------------------------- DNS
$script:OpDns = @'
$R = [ordered]@{ Ok = $false; Cancelled = $false; Message = ''; Registered = $false }
try {
    Prog 15 'Limpiando DNS...'
    $dn = Op-FlushDns -Register ([bool]$Ctx.RegisterDns)
    $R.Ok = $dn.Ok; $R.Message = $dn.Message; $R.Registered = $dn.Registered
    Prog 100 'Completado'
}
catch {
    $m = $_.Exception.Message
    if ($m -eq 'CANCELLED') { $R.Cancelled = $true; Say 'Operación cancelada.' 'warn' }
    else { $R.Message = 'Error inesperado: ' + $m; Say $R.Message 'err' }
}
Done ([pscustomobject]$R)
'@

# ---------------------------------------------------------------- LANZAR JUEGO
$script:OpLaunch = @'
$R = [ordered]@{ Ok = $false; Cancelled = $false; Message = ''; Method = '' }
try {
    Prog 30 'Buscando Riot Client...'
    $ln = Op-Launch -Product ([string]$Ctx.Product) -UserPath ([string]$Ctx.RiotPath)
    $R.Ok = $ln.Ok; $R.Message = $ln.Message; $R.Method = $ln.Method
    Prog 100 'Completado'
}
catch {
    $m = $_.Exception.Message
    if ($m -eq 'CANCELLED') { $R.Cancelled = $true; Say 'Operación cancelada.' 'warn' }
    else { $R.Message = 'Error inesperado: ' + $m; Say $R.Message 'err' }
}
Done ([pscustomobject]$R)
'@

# ---------------------------------------------------------------- RESTART COMPLETO
$script:OpFull = @'
$R = [ordered]@{ Ok = $false; Cancelled = $false; Message = ''; Lines = @(); Warnings = 0; Errors = 0 }
$lines = New-Object System.Collections.ArrayList
function Add-StepLine([string]$Level, [string]$Text) { [void]$lines.Add(@($Level, $Text)) }
try {
    Prog 3 'Detectando procesos de Riot...'
    $run = Get-RiotRunning
    if (-not $run.Ok) { Say ('No se pudieron listar los procesos: ' + $run.Error) 'warn' }
    $targets = @($run.Items)

    Prog 10 'Cerrando juegos y Riot Client...'
    Say 'Paso 1/4: cerrar procesos de Riot' 'step'
    $cl = Op-CloseProcesses -Targets $targets -Verify $false
    if ($targets.Count -eq 0) { Add-StepLine 'info' 'Procesos: no había juegos ni Riot Client abiertos.' }
    elseif ($cl.Failed -gt 0) { Add-StepLine 'warn' ('Procesos: {0} cerrados, {1} no se pudieron cerrar (se reintentará al reiniciar Vanguard).' -f $cl.Closed, $cl.Failed); $R.Warnings++ }
    else { Add-StepLine 'ok' ('Procesos: {0} cerrados.' -f $cl.Closed) }
    if (-not (Wait-Seconds 2)) { throw 'CANCELLED' }

    Prog 35 'Reiniciando Vanguard (vgc)...'
    Say 'Paso 2/4: reiniciar Vanguard' 'step'
    $vg = Op-RestartVanguard
    if ($vg.Ok) { Add-StepLine 'ok' 'Vanguard (vgc): reiniciado.' }
    elseif (-not $vg.Found) { Add-StepLine 'err' ('Vanguard (vgc): ' + $vg.Message); $R.Errors++ }
    else { Add-StepLine 'warn' ('Vanguard (vgc): ' + $vg.Message); $R.Warnings++ }
    if ($targets.Count -gt 0) {
        $left = @(Get-RemainingTargets -Targets $targets).Count
        if ($left -gt 0) { Add-StepLine 'warn' ('Quedan {0} proceso(s) de Riot abiertos tras reiniciar Vanguard.' -f $left); $R.Warnings++ }
    }
    if (-not (Wait-Seconds 1)) { throw 'CANCELLED' }

    Prog 65 'Limpiando DNS...'
    Say 'Paso 3/4: limpiar DNS' 'step'
    $dn = Op-FlushDns -Register ([bool]$Ctx.RegisterDns)
    if ($dn.Ok) { Add-StepLine 'ok' 'DNS: caché vaciada.' } else { Add-StepLine 'err' ('DNS: ' + $dn.Message); $R.Errors++ }
    if (-not (Wait-Seconds 1)) { throw 'CANCELLED' }

    if ($Ctx.RelaunchGame) {
        Prog 85 'Re-lanzando juego...'
        Say 'Paso 4/4: re-lanzar el juego' 'step'
        $prod = 'client'
        if ($cl.Found -eq 'LoL') { $prod = 'lol' } elseif ($cl.Found -eq 'Valorant') { $prod = 'val' }
        $ln = Op-Launch -Product $prod -UserPath ([string]$Ctx.RiotPath)
        if ($ln.Ok) { Add-StepLine 'ok' 'Juego: lanzado.' } else { Add-StepLine 'err' ('Juego: ' + $ln.Message); $R.Errors++ }
    } else {
        Say 'Paso 4/4: omitido (re-lanzar el juego está desactivado).' 'step'
        Add-StepLine 'info' 'Juego: no se re-lanzó (opción desactivada).'
    }
    $R.Lines = @($lines)
    $R.Ok = ($R.Errors -eq 0 -and $R.Warnings -eq 0)
    Prog 100 'Completado'
}
catch {
    $m = $_.Exception.Message
    $R.Lines = @($lines)
    if ($m -eq 'CANCELLED') { $R.Cancelled = $true; Say 'Operación cancelada. Si Vanguard se detuvo, ya se intentó volver a iniciarlo.' 'warn' }
    else { $R.Message = 'Error inesperado: ' + $m; Say $R.Message 'err' }
}
Done ([pscustomobject]$R)
'@

# ============================================================================
#  6) TEMAS, REGISTRO (LOG) Y DIALOGOS PROPIOS
# ============================================================================
$script:Themes = @{
    dark = @{
        IsDark = $true
        Bg = (RGB 14 16 26); Surface = (RGB 25 28 42); Border = (RGB 46 51 76)
        Text = (RGB 238 241 250); Sub = (RGB 140 149 178)
        Input = (RGB 20 22 35); LogBg = (RGB 10 11 19); SwOff = (RGB 70 76 104)
        LogText = (RGB 196 204 230); LogOk = (RGB 74 222 128); LogWarn = (RGB 251 191 36); LogErr = (RGB 248 113 113); LogStep = (RGB 167 139 250)
    }
    light = @{
        IsDark = $false
        Bg = (RGB 242 244 251); Surface = (RGB 255 255 255); Border = (RGB 222 226 240)
        Text = (RGB 24 28 45); Sub = (RGB 98 107 133)
        Input = (RGB 255 255 255); LogBg = (RGB 250 251 255); SwOff = (RGB 190 196 214)
        LogText = (RGB 52 62 92); LogOk = (RGB 21 128 61); LogWarn = (RGB 180 83 9); LogErr = (RGB 200 30 30); LogStep = (RGB 109 40 217)
    }
}
$script:Accent = @{
    diag  = @((RGB 251 191 36), (RGB 249 115 22))
    full  = @((RGB 167 139 250), (RGB 99 102 241))
    close = @((RGB 251 113 133), (RGB 225 29 72))
    vg    = @((RGB 45 212 191), (RGB 16 185 129))
    dns   = @((RGB 56 189 248), (RGB 37 99 235))
    vgdns = @((RGB 232 121 249), (RGB 168 85 247))
    lol   = @((RGB 34 211 238), (RGB 8 145 178))
    val   = @((RGB 163 230 53), (RGB 34 197 94))
}
$script:Violet = @((RGB 139 92 246), (RGB 79 70 229))

# Tema inicial: ajuste guardado; si no existe, el tema de Windows.
$themeName = [string](Get-Setting 'theme' '')
if ($themeName -ne 'dark' -and $themeName -ne 'light') {
    $themeName = 'dark'
    try {
        $appsLight = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        if ($appsLight -eq 1) { $themeName = 'light' }
    } catch { Write-FileLog 'info' 'No se pudo leer el tema de Windows; se usa el oscuro.' }
}
$script:Theme = $script:Themes[$themeName]

$script:LogLines = New-Object System.Collections.ArrayList
$script:txtLog = $null
$script:Worker = $null
$script:LastProg = ''
$script:Closing = $false
$script:AutoRiotPath = ''

function Write-LogLine([string]$Level, [string]$Line) {
    $rt = $script:txtLog
    if (-not $rt) { return }
    $t = $script:Theme
    $color = $t.LogText
    switch ($Level) { 'ok' { $color = $t.LogOk } 'warn' { $color = $t.LogWarn } 'err' { $color = $t.LogErr } 'step' { $color = $t.LogStep } }
    $rt.SelectionStart = $rt.TextLength
    $rt.SelectionLength = 0
    $rt.SelectionColor = $color
    $rt.AppendText($Line + "`r`n")
}

function Rebuild-Log {
    if (-not $script:txtLog) { return }
    $script:txtLog.Clear()
    foreach ($l in $script:LogLines) { Write-LogLine $l.Level $l.Line }
    $script:txtLog.SelectionStart = $script:txtLog.TextLength
    $script:txtLog.ScrollToCaret()
}

function New-Label {
    param([string]$Text, [double]$X, [double]$Y, [double]$W, [double]$H, [double]$Size = 9, [string]$Style = 'Regular', [string]$FontName = 'Segoe UI')
    $l = New-Object System.Windows.Forms.Label
    $l.UseCompatibleTextRendering = $false
    $l.AutoSize = $false
    $l.Text = $Text
    $l.Location = PT $X $Y
    $l.Size = SZ $W $H
    $l.Font = [System.Drawing.Font]::new($FontName, [single]$Size, [System.Drawing.FontStyle]$Style)
    return $l
}

function Set-SecondaryButton($btn) {
    $t = $script:Theme
    $btn.BackColor = $t.Bg; $btn.FillA = $t.Surface; $btn.FillB = $t.Surface
    $btn.BorderColor = $t.Border; $btn.TextColor = $t.Text
    $btn.Invalidate()
}

function New-DialogButton {
    param([string]$Text, [double]$X, [double]$Y, [double]$W, [bool]$Primary, $Accent)
    $t = $script:Theme
    $b = New-Object Vanguard.UI.RoundButton
    $b.Text = $Text
    $b.Location = PT $X $Y
    $b.Size = SZ $W 36
    $b.BackColor = $t.Bg
    if ($Primary) { $b.FillA = $Accent[0]; $b.FillB = $Accent[1]; $b.TextColor = [System.Drawing.Color]::White }
    else { Set-SecondaryButton $b }
    return $b
}

# Cuadro de mensaje con el tema de la aplicacion. Devuelve 'OK', 'Yes' o 'No'.
function Show-Dialog {
    param([string]$Title, [string]$Message, [string]$Buttons = 'OK', [string]$Icon = 'info', [string]$YesText = 'Sí', [string]$NoText = 'No')
    $t = $script:Theme
    $accent = (RGB 59 130 246)
    switch ($Icon) {
        'warn'     { $accent = (RGB 245 158 11) }
        'error'    { $accent = (RGB 239 68 68) }
        'ok'       { $accent = (RGB 34 197 94) }
        'question' { $accent = (RGB 139 92 246) }
    }
    $accent2 = [Vanguard.UI.Gfx]::Lerp($accent, [System.Drawing.Color]::Black, 0.25)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $t.Bg; $dlg.ForeColor = $t.Text
    $dlg.KeyPreview = $true
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }
    $fw = 580; $textW = $fw - 28 - 26
    $msgFont = [System.Drawing.Font]::new('Segoe UI', [single]10)
    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    $meas = [System.Windows.Forms.TextRenderer]::MeasureText($Message, $msgFont, [System.Drawing.Size]::new((px $textW), 100000), $flags)
    $mh = $meas.Height + (px 8)
    $maxH = px 330
    $y = 62
    $lblT = New-Label $Title 28 18 $textW 30 13 'Bold' 'Segoe UI Semibold'
    $lblT.ForeColor = $t.Text; $lblT.BackColor = $t.Bg
    $dlg.Controls.Add($lblT)
    if ($mh -gt $maxH) {
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.BorderStyle = 'None'
        $tb.Font = $msgFont; $tb.BackColor = $t.Bg; $tb.ForeColor = $t.Text
        $tb.Location = PT 28 $y; $tb.Size = [System.Drawing.Size]::new((px ($textW + 10)), $maxH)
        $tb.Text = $Message
        $dlg.Controls.Add($tb)
        $boxH = $maxH
    } else {
        $lm = New-Object System.Windows.Forms.Label
        $lm.UseCompatibleTextRendering = $false; $lm.AutoSize = $false
        $lm.Font = $msgFont; $lm.ForeColor = $t.Text; $lm.BackColor = $t.Bg
        $lm.Location = PT 28 $y; $lm.Size = [System.Drawing.Size]::new((px $textW), $mh)
        $lm.Text = $Message
        $dlg.Controls.Add($lm)
        $boxH = $mh
    }
    $btnY = [int](($y * $script:Scale + $boxH) / $script:Scale) + 20
    $strip = New-Object System.Windows.Forms.Panel
    $strip.BackColor = $accent; $strip.Location = PT 0 0
    $dlg.ClientSize = [System.Drawing.Size]::new((px $fw), (px ($btnY + 36 + 22)))
    $strip.Size = [System.Drawing.Size]::new((px 6), $dlg.ClientSize.Height)
    $dlg.Controls.Add($strip)

    $default = 'OK'
    if ($Buttons -eq 'YesNo') {
        $default = 'No'
        $bYes = New-DialogButton $YesText ($fw - 24 - 130) $btnY 130 $true @($accent, $accent2)
        $bNo  = New-DialogButton $NoText  ($fw - 24 - 130 - 10 - 120) $btnY 120 $false $null
        $bYes.add_Click({ $dlg.Tag = 'Yes'; $dlg.Close() }.GetNewClosure())
        $bNo.add_Click({ $dlg.Tag = 'No'; $dlg.Close() }.GetNewClosure())
        $dlg.Controls.Add($bYes); $dlg.Controls.Add($bNo)
    } else {
        $bOk = New-DialogButton 'Aceptar' ($fw - 24 - 130) $btnY 130 $true @($accent, $accent2)
        $bOk.add_Click({ $dlg.Tag = 'OK'; $dlg.Close() }.GetNewClosure())
        $dlg.Controls.Add($bOk)
    }
    $dlg.Tag = $default
    $dlg.add_KeyDown({
        param($sender, $ev)
        if ($ev.KeyCode -eq 'Escape') { $dlg.Tag = $default; $dlg.Close() }
        elseif ($ev.KeyCode -eq 'Return' -and $Buttons -ne 'YesNo') { $dlg.Tag = 'OK'; $dlg.Close() }
    }.GetNewClosure())
    $dlg.add_Shown({ param($sender, $ev) [Vanguard.UI.Native]::SetDarkTitleBar($sender.Handle, [bool]$script:Theme.IsDark) })
    [void]$dlg.ShowDialog($script:Form)
    $res = [string]$dlg.Tag
    $dlg.Dispose()
    return $res
}

# Lista con casillas para que TU decidas que se elimina. Devuelve @{Ok; Indices}.
function Show-Checklist {
    param([string]$Title, [string]$Message, [object[]]$Items, [string]$OkText = 'Aplicar')
    $t = $script:Theme
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $t.Bg; $dlg.ForeColor = $t.Text
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }
    $fw = 700; $textW = $fw - 28 - 26
    $dlg.ClientSize = [System.Drawing.Size]::new((px $fw), (px 470))
    $lblT = New-Label $Title 28 16 $textW 30 13 'Bold' 'Segoe UI Semibold'
    $lblT.ForeColor = $t.Text; $lblT.BackColor = $t.Bg
    $dlg.Controls.Add($lblT)
    $lblM = New-Label $Message 28 48 $textW 52 9.5
    $lblM.ForeColor = $t.Sub; $lblM.BackColor = $t.Bg
    $dlg.Controls.Add($lblM)
    $pnl = New-Object Vanguard.UI.RoundedPanel
    $pnl.Location = PT 28 106; $pnl.Size = SZ ($fw - 56) 290
    $pnl.BackColor = $t.Bg; $pnl.Fill = $t.Surface; $pnl.Border = $t.Border
    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.CheckOnClick = $true; $clb.BorderStyle = 'None'; $clb.IntegralHeight = $false
    $clb.HorizontalScrollbar = $true
    $clb.Font = [System.Drawing.Font]::new('Segoe UI', [single]9.5)
    $clb.BackColor = $t.Surface; $clb.ForeColor = $t.Text
    $clb.Location = PT 10 8; $clb.Size = SZ ($fw - 56 - 20) 274
    foreach ($it in $Items) { [void]$clb.Items.Add(('{0}   ›   {1}' -f $it.Text, $it.Detail), [bool]$it.Checked) }
    $pnl.Controls.Add($clb)
    $dlg.Controls.Add($pnl)
    $bAll  = New-DialogButton 'Todos' 28 410 90 $false $null
    $bNone = New-DialogButton 'Ninguno' 126 410 90 $false $null
    $bAll.add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) } }.GetNewClosure())
    $bNone.add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) } }.GetNewClosure())
    $bOk = New-DialogButton $OkText ($fw - 24 - 190) 410 190 $true $script:Violet
    $bCancel = New-DialogButton 'Cancelar' ($fw - 24 - 190 - 10 - 110) 410 110 $false $null
    $dlg.Tag = 'Cancel'
    $bOk.add_Click({ $dlg.Tag = 'Ok'; $dlg.Close() }.GetNewClosure())
    $bCancel.add_Click({ $dlg.Tag = 'Cancel'; $dlg.Close() }.GetNewClosure())
    foreach ($c in @($bAll, $bNone, $bOk, $bCancel)) { $dlg.Controls.Add($c) }
    $isDarkNow = [bool]$script:Theme.IsDark
    $dlg.add_Shown({ param($sender, $ev)
        [Vanguard.UI.Native]::SetDarkTitleBar($sender.Handle, $isDarkNow)
        [Vanguard.UI.Native]::SetControlTheme($clb.Handle, $isDarkNow)
    }.GetNewClosure())
    [void]$dlg.ShowDialog($script:Form)
    $ok = ([string]$dlg.Tag -eq 'Ok')
    $idx = @()
    if ($ok) { foreach ($i in $clb.CheckedIndices) { $idx += [int]$i } }
    $dlg.Dispose()
    return [pscustomobject]@{ Ok = $ok; Indices = $idx }
}


function Add-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = '[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message
    [void]$script:LogLines.Add([pscustomobject]@{ Level = $Level; Line = $line })
    if ($script:LogLines.Count -gt 1500) { $script:LogLines.RemoveRange(0, 300); Rebuild-Log }
    elseif ($script:txtLog) {
        Write-LogLine $Level $line
        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.ScrollToCaret()
    }
    Write-FileLog $Level $Message
}

# ============================================================================
#  7) GESTION DEL HILO DE TRABAJO (runspace propio + cola de mensajes)
# ============================================================================
function Get-WorkerParams([hashtable]$Extra = @{}) {
    $riotPath = [Environment]::ExpandEnvironmentVariables(([string]$script:txtPath.Text).Trim().Trim('"'))
    if ($script:AutoRiotPath -and ($riotPath -ieq $script:AutoRiotPath)) { $riotPath = '' }
    $bag = @{
        BackupDir = $script:BackupDir; RiotPath = $riotPath
        RelaunchGame = [bool]$script:swRelaunch.Checked; RegisterDns = [bool]$script:swDns.Checked
        UriLol = $script:URI_LOL; UriVal = $script:URI_VAL; UriRiot = $script:URI_RIOT
    }
    foreach ($key in $Extra.Keys) { $bag[$key] = $Extra[$key] }
    return $bag
}

function Set-Progress([int]$Pct, [string]$Text) {
    if ($Text) { $script:lblStatus.Text = $Text }
    if ($Pct -lt 0) { $script:progress.Marquee = $true }
    else { $script:progress.Marquee = $false; $script:progress.Value = $Pct }
}

function Set-Busy([bool]$Busy) {
    foreach ($key in @($script:Cards.Keys)) { $script:Cards[$key].Enabled = (-not $Busy) }
    $script:btnBrowse.Enabled = (-not $Busy)
    $script:txtPath.Enabled = (-not $Busy)
    $script:swRelaunch.Enabled = (-not $Busy)
    $script:swDns.Enabled = (-not $Busy)
    $script:btnCancel.Visible = $Busy
    $script:btnCancel.Enabled = $true
    if (-not $Busy) { $script:progress.Marquee = $false; $script:progress.Value = 0 }
}

function Receive-WorkerMessages {
    $work = $script:Worker
    if (-not $work) { return }
    $item = $null
    $count = 0
    while ($count -lt 500 -and $work.Q.TryDequeue([ref]$item)) {
        $count++
        switch ($item.T) {
            'log'  { Add-Log $item.Text $item.Level }
            'prog' {
                Set-Progress $item.Pct $item.Text
                if ($item.Pct -ge 0 -and $item.Text -ne $script:LastProg) { $script:LastProg = $item.Text; Add-Log $item.Text 'step' }
            }
            'done' { $work.Result = $item.Result }
        }
    }
}

function Poll-Worker {
    $work = $script:Worker
    if (-not $work) { $script:pollTimer.Stop(); return }
    Receive-WorkerMessages
    if ($work.Handle.IsCompleted) {
        $script:pollTimer.Stop()
        Receive-WorkerMessages
        try { [void]$work.PS.EndInvoke($work.Handle) } catch { Add-Log ('Error en el proceso: ' + $_.Exception.Message) 'err' }
        try { foreach ($er in @($work.PS.Streams.Error | Select-Object -First 5)) { Add-Log ('[interno] ' + $er.ToString()) 'warn' } } catch { Write-FileLog 'warn' 'No se pudieron leer los errores internos del hilo.' }
        try { $work.PS.Dispose(); $work.RS.Close(); $work.RS.Dispose() } catch { Write-FileLog 'warn' ('No se pudo liberar el hilo: ' + $_.Exception.Message) }
        $script:Worker = $null
        if ($script:Closing) { return }
        Set-Busy $false
        Set-Progress 0 'Listo'
        if ($work.OnDone) { try { & $work.OnDone $work.Result } catch { Add-Log ('Error: ' + $_.Exception.Message) 'err' } }
    }
}

function Start-Worker {
    param([string]$Body, [hashtable]$Params, [scriptblock]$OnDone)
    if ($script:Worker) { return }
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $state = [hashtable]::Synchronized(@{ Cancel = $false })
    $ctxBag = @{ Q = $queue; State = $state }
    foreach ($key in $Params.Keys) { $ctxBag[$key] = $Params[$key] }
    $code = "param(`$Ctx)`r`n" + $script:WorkerPrelude + "`r`n" + $script:WorkerHeader + "`r`n" + $script:WorkerOps + "`r`n" + $Body
    $runspace = $null
    $shell = $null
    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript($code).AddArgument($ctxBag)
        $script:LastProg = ''
        $script:Worker = @{ PS = $shell; RS = $runspace; Q = $queue; State = $state; Handle = $null; Result = $null; OnDone = $OnDone }
        Set-Busy $true
        Set-Progress -1 'Iniciando...'
        $script:Worker.Handle = $shell.BeginInvoke()
        $script:pollTimer.Start()
    } catch {
        Add-Log ('No se pudo iniciar la operación: ' + $_.Exception.Message) 'err'
        try { if ($shell) { $shell.Dispose() } } catch { $null = $_ }
        try { if ($runspace) { $runspace.Close(); $runspace.Dispose() } } catch { $null = $_ }
        $script:Worker = $null
        Set-Busy $false
        Set-Progress 0 'Listo'
        [void](Show-Dialog 'Error' ('No se pudo iniciar la operación:' + "`r`n`r`n" + $_.Exception.Message) 'OK' 'error')
    }
}

# ============================================================================
#  8) ACCIONES
# ============================================================================
function Open-GitHub {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList $script:GitHubUrl }
    catch {
        try { [void][System.Diagnostics.Process]::Start($script:GitHubUrl) }
        catch { Add-Log ('No se pudo abrir ' + $script:GitHubUrl + ': ' + $_.Exception.Message) 'err' }
    }
}

# ---------------------------------------------------------------- Diagnostico
function Invoke-Diagnose {
    Add-Log 'Diagnóstico (solo lectura)' 'step'
    Start-Worker -Body $script:OpDiag -Params (Get-WorkerParams) -OnDone {
        param($r)
        if (-not $r -or $r.Cancelled) { return }
        if (-not $r.Ok) { [void](Show-Dialog 'Diagnóstico' ([string]$r.Message) 'OK' 'error'); return }
        $sb = New-Object System.Text.StringBuilder
        foreach ($dl in $r.Lines) { [void]$sb.AppendLine(('•  ' + [string]$dl[1])) }
        [void]$sb.AppendLine('')
        $icon = 'ok'
        if ($r.Errors -gt 0) {
            $icon = 'error'
            [void]$sb.AppendLine('Resultado: hay problemas que impiden que Vanguard funcione. Revisa los puntos marcados.')
        } elseif ($r.Warnings -gt 0) {
            $icon = 'warn'
            [void]$sb.AppendLine('Resultado: hay avisos. Si tienes errores VAN, prueba «Reiniciar Vanguard» o «Restart completo».')
        } else {
            [void]$sb.AppendLine('Resultado: todo parece correcto.')
        }
        [void](Show-Dialog 'Diagnóstico completado' $sb.ToString() 'OK' $icon)
    }
}

# ---------------------------------------------------------------- Cerrar procesos (con lista de seleccion)
function Invoke-CloseProcs {
    $run = $null
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { $run = Get-RiotRunning } finally { $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default }
    if (-not $run.Ok) { [void](Show-Dialog 'No se pudieron listar los procesos' ([string]$run.Error) 'OK' 'error'); return }
    $found = @($run.Items)
    if ($found.Count -eq 0) {
        Add-Log 'No hay procesos de Riot abiertos.' 'info'
        [void](Show-Dialog 'Cerrar procesos de Riot' "No hay procesos de League of Legends, Valorant ni Riot Client abiertos.`r`n`r`nNo hace falta cerrar nada." 'OK' 'info')
        return
    }
    $items = @()
    foreach ($proc in $found) {
        $grpText = 'Valorant / Riot Client'
        if ($proc.Group -eq 'LoL') { $grpText = 'League of Legends' }
        $detail = $grpText
        if ($proc.Path) { $detail += '  ·  ' + $proc.Path }
        $items += [pscustomobject]@{ Text = ('{0}  (PID {1})' -f $proc.Name, $proc.Id); Detail = $detail; Checked = $true }
    }
    $msg = "Se encontraron {0} proceso(s) de Riot. Marca los que quieres cerrar.`r`nSi estás en una partida, se abandonará y perderás el progreso no guardado." -f $found.Count
    $sel = Show-Checklist 'Cerrar procesos de Riot' $msg $items 'Cerrar seleccionados'
    if (-not $sel.Ok) { Add-Log 'Cierre de procesos cancelado.' 'info'; return }
    $targets = @()
    foreach ($ix in $sel.Indices) { $targets += $found[[int]$ix] }
    if ($targets.Count -eq 0) { Add-Log 'No se seleccionó ningún proceso.' 'info'; return }
    Add-Log ('Cerrando {0} proceso(s) de Riot...' -f $targets.Count) 'step'
    Start-Worker -Body $script:OpClose -Params (Get-WorkerParams @{ Targets = $targets }) -OnDone {
        param($r)
        if (-not $r) { return }
        if ($r.Cancelled) { [void](Show-Dialog 'Operación cancelada' 'El cierre de procesos se canceló. Es posible que algunos ya se hubieran cerrado.' 'OK' 'warn'); return }
        if ($r.Message) { [void](Show-Dialog 'No se pudo completar' ([string]$r.Message) 'OK' 'error'); return }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine(('Procesos cerrados: {0}.' -f $r.Closed))
        if ($r.Gone -gt 0) { [void]$sb.AppendLine(('Ya no estaban abiertos (o cambiaron): {0}.' -f $r.Gone)) }
        if ($r.Failed -gt 0) { [void]$sb.AppendLine(('No se pudieron cerrar: {0}.' -f $r.Failed)) }
        if ($r.Remaining -gt 0) { [void]$sb.AppendLine(('Siguen abiertos: {0}. Vanguard protege el juego; prueba «Reiniciar Vanguard» o «Restart completo».' -f $r.Remaining)) }
        if ($r.Ok) { [void](Show-Dialog 'Procesos cerrados' $sb.ToString() 'OK' 'ok') }
        else { [void](Show-Dialog 'Cierre incompleto' $sb.ToString() 'OK' 'warn') }
    }
}

# ---------------------------------------------------------------- Reiniciar Vanguard (+ DNS)
function Invoke-RestartVg([bool]$WithDns) {
    $title = 'Reiniciar Vanguard'
    if ($WithDns) { $title = 'Reiniciar Vanguard + DNS' }
    $msg = "Se va a reiniciar el servicio de Vanguard (vgc):`r`n`r`n" +
           "1. Se guarda una instantánea de su estado actual`r`n" +
           "2. Se detiene el servicio vgc y se vuelve a iniciar`r`n"
    if ($WithDns) { $msg += "3. Se vacía la caché DNS`r`n" }
    $msg += "`r`nSi Valorant o League of Legends están abiertos, Vanguard puede cerrarlos o mostrar un error: guarda lo que necesites antes. No se borra ningún archivo ni se cambia la configuración del servicio.`r`n`r`n¿Continuar?"
    if ((Show-Dialog ('Confirmar: ' + $title) $msg 'YesNo' 'question' 'Reiniciar' 'Cancelar') -ne 'Yes') { return }
    Add-Log ($title + '...') 'step'
    Start-Worker -Body $script:OpVanguard -Params (Get-WorkerParams @{ WithDns = $WithDns }) -OnDone {
        param($r)
        if (-not $r -or $r.Cancelled) { if ($r -and $r.Cancelled) { [void](Show-Dialog 'Operación cancelada' 'Se canceló. Si Vanguard se había detenido, ya se intentó volver a iniciarlo.' 'OK' 'warn') }; return }
        if ($r.Ok) {
            $okText = 'Vanguard (vgc) se reinició correctamente.'
            if ($r.WithDns) { $okText += "`r`nLa caché DNS se vació correctamente." }
            [void](Show-Dialog 'Operación completada' $okText 'OK' 'ok')
        } elseif (-not $r.VgFound) {
            [void](Show-Dialog 'Vanguard no encontrado' ([string]$r.Message) 'OK' 'error')
        } else {
            $failText = [string]$r.Message
            if (-not $failText) { $failText = 'La operación no se completó del todo. Revisa el registro.' }
            [void](Show-Dialog 'Operación incompleta' $failText 'OK' 'warn')
        }
    }
}

# ---------------------------------------------------------------- DNS
function Invoke-Dns {
    Add-Log 'Reparando conexión / DNS...' 'step'
    Start-Worker -Body $script:OpDns -Params (Get-WorkerParams) -OnDone {
        param($r)
        if (-not $r -or $r.Cancelled) { return }
        if ($r.Ok) { [void](Show-Dialog 'DNS' 'La caché DNS se vació correctamente.' 'OK' 'ok') }
        else {
            $dnsText = [string]$r.Message
            if (-not $dnsText) { $dnsText = 'No se pudo vaciar la caché DNS. Revisa el registro.' }
            [void](Show-Dialog 'DNS' $dnsText 'OK' 'error')
        }
    }
}

# ---------------------------------------------------------------- Lanzar juego
function Invoke-LaunchGame([string]$Product) {
    $label = 'Riot Client'
    if ($Product -eq 'lol') { $label = 'League of Legends' } elseif ($Product -eq 'val') { $label = 'Valorant' }
    Add-Log ('Lanzando ' + $label + '...') 'step'
    Start-Worker -Body $script:OpLaunch -Params (Get-WorkerParams @{ Product = $Product }) -OnDone {
        param($r)
        if (-not $r -or $r.Cancelled) { return }
        if ($r.Ok) { Add-Log 'Lanzamiento solicitado. El juego puede tardar unos segundos en abrirse.' 'ok' }
        else {
            $lnText = [string]$r.Message
            if (-not $lnText) { $lnText = 'No se pudo lanzar el juego.' }
            [void](Show-Dialog 'No se pudo lanzar' $lnText 'OK' 'error')
        }
    }
}

# ---------------------------------------------------------------- Restart completo
function Invoke-FullRestart {
    $count = 0
    try { $runNow = Get-RiotRunning; if ($runNow.Ok) { $count = @($runNow.Items).Count } } catch { $count = 0 }
    $msg = ("RESTART COMPLETO hará lo siguiente, en este orden:`r`n`r`n" +
            "1. Cerrar League of Legends, Valorant y Riot Client (ahora hay {0} proceso(s) abiertos)`r`n" +
            "2. Reiniciar el servicio de Vanguard (vgc), guardando antes una instantánea de su estado`r`n") -f $count
    $msg += "3. Vaciar la caché DNS`r`n"
    if ($script:swRelaunch.Checked) { $msg += "4. Volver a abrir el juego que tenías abierto (o Riot Client)`r`n" }
    else { $msg += "4. (Re-lanzar el juego está desactivado)`r`n" }
    $msg += "`r`nSi estás en una partida, se abandonará y perderás el progreso no guardado. No se borra ningún archivo.`r`n`r`n¿Continuar?"
    if ((Show-Dialog 'Confirmar RESTART COMPLETO' $msg 'YesNo' 'warn' 'Ejecutar' 'Cancelar') -ne 'Yes') { return }
    Add-Log 'RESTART COMPLETO' 'step'
    Start-Worker -Body $script:OpFull -Params (Get-WorkerParams) -OnDone {
        param($r)
        if (-not $r) { return }
        if ($r.Cancelled) { [void](Show-Dialog 'Operación cancelada' 'El proceso se canceló antes de terminar. Si Vanguard se había detenido, ya se intentó volver a iniciarlo.' 'OK' 'warn'); return }
        if ($r.Message) { [void](Show-Dialog 'No se pudo completar' ([string]$r.Message) 'OK' 'error'); return }
        $sb = New-Object System.Text.StringBuilder
        foreach ($sl in $r.Lines) { [void]$sb.AppendLine(('•  ' + [string]$sl[1])) }
        $icon = 'ok'
        if ($r.Errors -gt 0) { $icon = 'error'; [void]$sb.AppendLine("`r`nHubo errores: revisa el registro inferior. Si el problema persiste, reinicia el equipo.") }
        elseif ($r.Warnings -gt 0) { $icon = 'warn'; [void]$sb.AppendLine("`r`nTerminó con avisos: revisa el registro inferior.") }
        else { [void]$sb.AppendLine("`r`nProceso completado con éxito.") }
        Add-Log 'Restart completo finalizado.' 'ok'
        [void](Show-Dialog 'Restart completo' $sb.ToString() 'OK' $icon)
    }
}

function Invoke-CardAction([string]$Key) {
    if ($script:Worker) { return }
    switch ($Key) {
        'diag'  { Invoke-Diagnose }
        'full'  { Invoke-FullRestart }
        'close' { Invoke-CloseProcs }
        'vg'    { Invoke-RestartVg $false }
        'dns'   { Invoke-Dns }
        'vgdns' { Invoke-RestartVg $true }
        'lol'   { Invoke-LaunchGame 'lol' }
        'val'   { Invoke-LaunchGame 'val' }
    }
}

# ============================================================================
#  9) VENTANA PRINCIPAL
# ============================================================================
try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) }
catch { Write-FileLog 'warn' ('No se pudo activar la captura de excepciones: ' + $_.Exception.Message) }
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $ev)
    Add-Log ('Error: ' + $ev.Exception.Message) 'err'
    Write-FileLog 'err' ([string]$ev.Exception.StackTrace)
})

function New-AppIcon {
    try {
        $bmp = New-Object System.Drawing.Bitmap 64, 64
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.SmoothingMode = 'AntiAlias'; $gfx.TextRenderingHint = 'AntiAliasGridFit'
        $path = [Vanguard.UI.Gfx]::RoundRect([System.Drawing.RectangleF]::new(2, 2, 60, 60), 15)
        $br = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.Rectangle]::new(0, 0, 64, 64), (RGB 124 58 237), (RGB 236 72 153), [single]45)
        $gfx.FillPath($br, $path)
        $fnt = [System.Drawing.Font]::new('Segoe UI', [single]36, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $gfx.DrawString('V', $fnt, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]::new(0, 2, 64, 64), $sf)
        $gfx.Dispose()
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } catch { Write-FileLog 'warn' ('No se pudo crear el icono: ' + $_.Exception.Message); return $null }
}

function Apply-Theme {
    $thm = $script:Theme
    $dark = [bool]$thm.IsDark
    $script:Form.BackColor = $thm.Bg; $script:Form.ForeColor = $thm.Text
    foreach ($ctl in @($script:lblPath, $script:lblStatus, $script:lblFooter)) { $ctl.BackColor = $thm.Bg; $ctl.ForeColor = $thm.Sub }
    foreach ($ctl in @($script:lblOpt1, $script:lblOpt2)) { $ctl.BackColor = $thm.Bg; $ctl.ForeColor = $thm.Text }
    $script:pnlPath.BackColor = $thm.Bg; $script:pnlPath.Fill = $thm.Input; $script:pnlPath.Border = $thm.Border; $script:pnlPath.Invalidate()
    $script:txtPath.BackColor = $thm.Input; $script:txtPath.ForeColor = $thm.Text
    $script:pnlLog.BackColor = $thm.Bg; $script:pnlLog.Fill = $thm.LogBg; $script:pnlLog.Border = $thm.Border; $script:pnlLog.Invalidate()
    $script:txtLog.BackColor = $thm.LogBg; $script:txtLog.ForeColor = $thm.LogText
    foreach ($sw in @($script:swRelaunch, $script:swDns)) { $sw.BackColor = $thm.Bg; $sw.OffColor = $thm.SwOff; $sw.Invalidate() }
    foreach ($key in $script:Cards.Keys) {
        $card = $script:Cards[$key]
        $card.BackColor = $thm.Bg; $card.CardBack = $thm.Surface; $card.CardBorder = $thm.Border; $card.TitleColor = $thm.Text; $card.DescColor = $thm.Sub
        $card.Invalidate()
    }
    $script:progress.BackColor = $thm.Bg; $script:progress.Track = $thm.SwOff; $script:progress.Invalidate()
    foreach ($btn in @($script:btnBrowse, $script:btnCancel)) { $btn.BackColor = $thm.Bg; $btn.Invalidate() }
    Set-SecondaryButton $script:btnClear
    Set-SecondaryButton $script:btnCopy
    Set-SecondaryButton $script:btnExit
    [Vanguard.UI.Native]::SetControlTheme($script:txtLog.Handle, $dark)
    if ($script:Form.IsHandleCreated) { [Vanguard.UI.Native]::SetDarkTitleBar($script:Form.Handle, $dark) }
    Rebuild-Log
}

try {
    $script:AppIcon = New-AppIcon

    $ghB64 = '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'
    $script:ghStream = [System.IO.MemoryStream]::new([Convert]::FromBase64String($ghB64))
    $script:ghBmp = [System.Drawing.Bitmap]::new($script:ghStream)

    $formWidth = 820
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $formHeight = [int][math]::Min(800, [math]::Floor($workArea.Height / $script:Scale) - 56)
    if ($formHeight -lt 680) { $formHeight = 680 }

    $Form = New-Object System.Windows.Forms.Form
    $script:Form = $Form
    $Form.Text = ('{0} {1}' -f $script:AppName, $script:AppVer)
    $Form.StartPosition = 'Manual'
    $Form.FormBorderStyle = 'FixedSingle'
    $Form.MaximizeBox = $false
    $Form.Font = [System.Drawing.Font]::new('Segoe UI', [single]9)
    $Form.ClientSize = SZ $formWidth $formHeight
    if ($script:AppIcon) { $Form.Icon = $script:AppIcon }
    $locX = $workArea.Left + [int](($workArea.Width - $Form.Width) / 2)
    $locY = $workArea.Top + [int](($workArea.Height - $Form.Height) / 2)
    if ($locX -lt $workArea.Left) { $locX = $workArea.Left }
    if ($locY -lt $workArea.Top) { $locY = $workArea.Top }
    $Form.Location = [System.Drawing.Point]::new($locX, $locY)
    $Form.SuspendLayout()

    $script:tip = New-Object System.Windows.Forms.ToolTip
    $script:tip.InitialDelay = 400

    # ---- cabecera ----
    $script:header = New-Object Vanguard.UI.GradientPanel
    $script:header.Location = PT 0 0
    $script:header.Size = SZ $formWidth 80
    $script:header.Anchor = 'Top, Left, Right'
    $lblTitle = New-Label $script:AppName 22 12 520 36 19 'Regular' 'Segoe UI Semibold'
    $lblTitle.ForeColor = [System.Drawing.Color]::White; $lblTitle.BackColor = [System.Drawing.Color]::Transparent
    $lblSub = New-Label 'Riot Services Manager  ·  MARCKO-SYGMATCH  ·  Windows 10 / 11' 25 48 560 22 9.5
    $lblSub.ForeColor = (RGB 236 232 255); $lblSub.BackColor = [System.Drawing.Color]::Transparent
    $script:btnGit = New-Object Vanguard.UI.MaskButton
    $script:btnGit.Mask = $script:ghBmp
    $script:btnGit.Location = PT ($formWidth - 24 - 64 - 14 - 44) 18
    $script:btnGit.Size = SZ 44 44
    $script:btnGit.BackColor = [System.Drawing.Color]::Transparent
    $script:btnGit.Anchor = 'Top, Right'
    $script:btnGit.add_Click({ Open-GitHub })
    $script:tip.SetToolTip($script:btnGit, 'Abrir github.com/Sygmatch')
    $script:swTheme = New-Object Vanguard.UI.ToggleSwitch
    $script:swTheme.SunMoon = $true
    $script:swTheme.OffColor = (RGB 99 179 237)
    $script:swTheme.OnColor = (RGB 32 36 74)
    $script:swTheme.Location = PT ($formWidth - 24 - 64) 24
    $script:swTheme.Size = SZ 64 32
    $script:swTheme.BackColor = [System.Drawing.Color]::Transparent
    $script:swTheme.Anchor = 'Top, Right'
    $script:tip.SetToolTip($script:swTheme, 'Cambiar entre modo claro (sol) y oscuro (luna)')
    foreach ($hdrCtl in @($lblTitle, $lblSub, $script:btnGit, $script:swTheme)) { $script:header.Controls.Add($hdrCtl) }
    $Form.Controls.Add($script:header)

    # ---- ruta de Riot ----
    $script:lblPath = New-Label 'CARPETA DE RIOT GAMES  ·  SE DETECTA SOLA (CÁMBIALA SOLO SI RIOT ESTÁ EN OTRA UBICACIÓN)' 24 92 ($formWidth - 48) 18 8.5 'Regular' 'Segoe UI Semibold'
    $Form.Controls.Add($script:lblPath)
    $script:pnlPath = New-Object Vanguard.UI.RoundedPanel
    $script:pnlPath.Location = PT 24 112
    $script:pnlPath.Size = SZ ($formWidth - 48 - 132) 42
    $script:pnlPath.Anchor = 'Top, Left, Right'
    $script:txtPath = New-Object System.Windows.Forms.TextBox
    $script:txtPath.BorderStyle = 'None'
    $script:txtPath.Font = [System.Drawing.Font]::new('Segoe UI', [single]10.5)
    $script:txtPath.Location = PT 14 10
    $script:txtPath.Width = (px ($formWidth - 48 - 132 - 28))
    $script:txtPath.Anchor = 'Top, Left, Right'
    $script:pnlPath.Controls.Add($script:txtPath)
    $Form.Controls.Add($script:pnlPath)
    $script:btnBrowse = New-Object Vanguard.UI.RoundButton
    $script:btnBrowse.Text = 'Examinar...'
    $script:btnBrowse.Location = PT ($formWidth - 24 - 122) 112
    $script:btnBrowse.Size = SZ 122 42
    $script:btnBrowse.FillA = $script:Violet[0]; $script:btnBrowse.FillB = (RGB 236 72 153)
    $script:btnBrowse.Anchor = 'Top, Right'
    $Form.Controls.Add($script:btnBrowse)

    # ---- opciones ----
    $script:swRelaunch = New-Object Vanguard.UI.ToggleSwitch
    $script:swRelaunch.Location = PT 24 164; $script:swRelaunch.Size = SZ 44 24
    $script:swRelaunch.OnColor = (RGB 34 197 94)
    $script:swRelaunch.SetCheckedSilent($true)
    $script:lblOpt1 = New-Label 'Re-lanzar el juego al terminar el Restart completo' 76 164 340 24 9.5
    $script:lblOpt1.TextAlign = 'MiddleLeft'
    $script:swDns = New-Object Vanguard.UI.ToggleSwitch
    $script:swDns.Location = PT 424 164; $script:swDns.Size = SZ 44 24
    $script:swDns.OnColor = (RGB 245 158 11)
    $script:swDns.SetCheckedSilent($true)
    $script:lblOpt2 = New-Label 'Volver a registrar DNS (ipconfig /registerdns)' 476 164 ($formWidth - 476 - 24) 24 9.5
    $script:lblOpt2.TextAlign = 'MiddleLeft'
    foreach ($optCtl in @($script:swRelaunch, $script:lblOpt1, $script:swDns, $script:lblOpt2)) { $Form.Controls.Add($optCtl) }
    $script:tip.SetToolTip($script:swRelaunch, 'Tras el Restart completo vuelve a abrir el juego que estaba abierto (o Riot Client si no había ninguno).')
    $script:tip.SetToolTip($script:swDns, 'Después de vaciar la caché DNS, ejecuta también ipconfig /registerdns (como hacía la versión original).')

    # ---- tarjetas ----
    $script:Cards = @{}
    $script:CardHelp = @{
        diag  = "DIAGNÓSTICO (solo lectura)`r`n`r`nComprueba, sin modificar nada:`r`n• Si el servicio vgc (Vanguard) existe, su estado y su tipo de inicio`r`n• El estado del controlador vgk (kernel de Vanguard)`r`n• Qué procesos de Riot están abiertos`r`n• Si Riot Client está instalado, dónde y si su firma digital es válida`r`n• Si el protocolo riotclient:// está registrado`r`n`r`nÚsalo primero para saber qué le pasa al sistema antes de reiniciar nada."
        full  = "RESTART COMPLETO (la opción más efectiva)`r`n`r`n1. Cierra League of Legends, Valorant y Riot Client`r`n2. Reinicia el servicio de Vanguard (vgc), guardando antes una instantánea de su estado`r`n3. Vacía la caché DNS (y la registra de nuevo si la opción está activa)`r`n4. Vuelve a abrir el juego que tenías abierto, o Riot Client si no había ninguno (se puede desactivar)`r`n`r`nPide confirmación porque si estás en una partida se abandonará. No borra archivos. Al final muestra un resumen real de cada paso (éxito, aviso o error)."
        close = "CERRAR PROCESOS DE RIOT`r`n`r`nMuestra una lista con los procesos de League of Legends, Valorant y Riot Client que están abiertos y TÚ eliges cuáles cerrar. Útil cuando el juego se queda colgado.`r`n`r`nAntes de cerrar cada uno se comprueba que el PID siga siendo el mismo proceso (nombre y hora de inicio), y se guarda un registro en la carpeta de instantáneas.`r`n`r`nNota: Vanguard protege el proceso de Valorant y puede impedir que se cierre desde fuera; en ese caso usa «Reiniciar Vanguard» o «Restart completo»."
        vg    = "REINICIAR VANGUARD (vgc)`r`n`r`nDetiene y vuelve a iniciar el servicio de Vanguard. Úsalo cuando aparezcan errores VAN.`r`n`r`n• Guarda una instantánea del estado del servicio`r`n• Si lo detiene, SIEMPRE intenta volver a iniciarlo (aunque canceles)`r`n• Si el servicio está deshabilitado te avisa; no cambia su configuración`r`n`r`nSi hay un juego abierto, Vanguard puede cerrarlo o mostrar un error."
        dns   = "REPARAR CONEXIÓN / DNS`r`n`r`nVacía la caché DNS (ipconfig /flushdns) y, si la opción está activa, vuelve a registrar el DNS (ipconfig /registerdns).`r`n`r`nAyuda con problemas de conexión o latencia alta. No cambia tu configuración de red."
        vgdns = "REINICIAR VANGUARD + DNS`r`n`r`nReinicia el servicio de Vanguard y vacía la caché DNS, sin cerrar los procesos de los juegos. Ideal para problemas leves.`r`n`r`nSi el error persiste, usa «Restart completo»."
        lol   = "RE-LANZAR LEAGUE OF LEGENDS`r`n`r`nAbre League of Legends con Riot Client. Si Riot Client está instalado y su firma digital es válida, se ejecuta directamente; si no, se usa el protocolo riotclient://.`r`n`r`nRiot Client se inicia con los mismos privilegios de esta herramienta (administrador)."
        val   = "RE-LANZAR VALORANT`r`n`r`nAbre Valorant con Riot Client. Si Riot Client está instalado y su firma digital es válida, se ejecuta directamente; si no, se usa el protocolo riotclient://.`r`n`r`nRiot Client se inicia con los mismos privilegios de esta herramienta (administrador)."
    }
    $cardDefs = @(
        @{ Key = 'diag';  Title = 'Diagnóstico (solo lectura)'; Desc = 'Comprueba Vanguard, procesos y Riot Client sin modificar nada.'; Glyph = [string][char]0xE721; Badge = '1' },
        @{ Key = 'full';  Title = 'RESTART COMPLETO'; Desc = 'Cierra juegos, reinicia Vanguard, limpia DNS y re-lanza el juego.'; Glyph = [string][char]0xE72C; Badge = '2' },
        @{ Key = 'close'; Title = 'Cerrar procesos Riot'; Desc = 'Elige qué procesos de LoL, Valorant y Riot Client cerrar.'; Glyph = [string][char]0xE711; Badge = '3' },
        @{ Key = 'vg';    Title = 'Reiniciar Vanguard (vgc)'; Desc = 'Reinicia el servicio de Vanguard. Útil ante errores VAN.'; Glyph = [string][char]0xE72E; Badge = '4' },
        @{ Key = 'dns';   Title = 'Reparar conexión / DNS'; Desc = 'Vacía la caché DNS. Ayuda con fallos de conexión o latencia alta.'; Glyph = [string][char]0xE774; Badge = '5' },
        @{ Key = 'vgdns'; Title = 'Reiniciar Vanguard + DNS'; Desc = 'Reinicia Vanguard y limpia DNS sin cerrar los juegos.'; Glyph = [string][char]0xE895; Badge = '6' },
        @{ Key = 'lol';   Title = 'Re-lanzar League of Legends'; Desc = 'Abre League of Legends mediante Riot Client.'; Glyph = [string][char]0xE768; Badge = '7' },
        @{ Key = 'val';   Title = 'Re-lanzar Valorant'; Desc = 'Abre Valorant mediante Riot Client.'; Glyph = [string][char]0xE768; Badge = '8' }
    )
    $cardWidth = [int](($formWidth - 48 - 12) / 2)
    for ($ci = 0; $ci -lt $cardDefs.Count; $ci++) {
        $cardDef = $cardDefs[$ci]
        $cardCol = $ci % 2
        $cardRow = [int][math]::Floor($ci / 2)
        $card = New-Object Vanguard.UI.ActionCard
        $card.Title = $cardDef.Title; $card.Desc = $cardDef.Desc; $card.Glyph = $cardDef.Glyph; $card.Badge = $cardDef.Badge
        $card.AccentA = $script:Accent[$cardDef.Key][0]; $card.AccentB = $script:Accent[$cardDef.Key][1]
        $card.Location = PT (24 + $cardCol * ($cardWidth + 12)) (200 + $cardRow * 82)
        $card.Size = SZ $cardWidth 76
        $card.Tag = $cardDef.Key
        $card.add_Click({ param($sender, $ev) Invoke-CardAction ([string]$sender.Tag) })
        $card.add_InfoClick({ param($sender, $ev) [void](Show-Dialog $sender.Title $script:CardHelp[[string]$sender.Tag] 'OK' 'info') })
        $script:tip.SetToolTip($card, $cardDef.Desc)
        $script:Cards[$cardDef.Key] = $card
        $Form.Controls.Add($card)
    }

    # ---- progreso ----
    $script:progress = New-Object Vanguard.UI.GradientProgress
    $script:progress.Location = PT 24 534; $script:progress.Size = SZ ($formWidth - 48) 8
    $script:progress.Anchor = 'Top, Left, Right'
    $script:progress.ColorA = $script:Violet[0]; $script:progress.ColorB = (RGB 236 72 153)
    $Form.Controls.Add($script:progress)
    $script:lblStatus = New-Label 'Listo' 24 546 ($formWidth - 48 - 110) 22 9
    $script:lblStatus.TextAlign = 'MiddleLeft'
    $Form.Controls.Add($script:lblStatus)
    $script:btnCancel = New-Object Vanguard.UI.RoundButton
    $script:btnCancel.Text = 'Cancelar'
    $script:btnCancel.Location = PT ($formWidth - 24 - 100) 544
    $script:btnCancel.Size = SZ 100 26
    $script:btnCancel.FillA = (RGB 251 113 133); $script:btnCancel.FillB = (RGB 225 29 72)
    $script:btnCancel.Anchor = 'Top, Right'
    $script:btnCancel.Visible = $false
    $Form.Controls.Add($script:btnCancel)

    # ---- registro ----
    $script:pnlLog = New-Object Vanguard.UI.RoundedPanel
    $script:pnlLog.Location = PT 24 576
    $script:pnlLog.Size = SZ ($formWidth - 48) ($formHeight - 576 - 46)
    $script:pnlLog.Anchor = 'Top, Bottom, Left, Right'
    $script:pnlLog.Radius = 12
    $script:txtLog = New-Object System.Windows.Forms.RichTextBox
    $script:txtLog.ReadOnly = $true
    $script:txtLog.BorderStyle = 'None'
    $script:txtLog.Font = [System.Drawing.Font]::new('Consolas', [single]9)
    $script:txtLog.DetectUrls = $false
    $script:txtLog.HideSelection = $false
    $script:txtLog.Location = PT 10 8
    $script:txtLog.Size = [System.Drawing.Size]::new($script:pnlLog.Width - (px 20), $script:pnlLog.Height - (px 16))
    $script:txtLog.Anchor = 'Top, Bottom, Left, Right'
    $script:pnlLog.Controls.Add($script:txtLog)
    $Form.Controls.Add($script:pnlLog)

    # ---- pie ----
    $script:lblFooter = New-Label ('v{0}  ·  Windows 10 / 11  ·  Modo administrador activo' -f $script:AppVer) 24 ($formHeight - 34) 420 22 8.5
    $script:lblFooter.TextAlign = 'MiddleLeft'; $script:lblFooter.Anchor = 'Bottom, Left'
    $Form.Controls.Add($script:lblFooter)
    $script:btnExit = New-Object Vanguard.UI.RoundButton
    $script:btnExit.Text = 'Salir'; $script:btnExit.Font = [System.Drawing.Font]::new('Segoe UI Semibold', [single]8.5)
    $script:btnExit.Location = PT ($formWidth - 24 - 84) ($formHeight - 38); $script:btnExit.Size = SZ 84 28; $script:btnExit.Anchor = 'Bottom, Right'
    $script:btnClear = New-Object Vanguard.UI.RoundButton
    $script:btnClear.Text = 'Limpiar'; $script:btnClear.Font = [System.Drawing.Font]::new('Segoe UI Semibold', [single]8.5)
    $script:btnClear.Location = PT ($formWidth - 24 - 84 - 8 - 84) ($formHeight - 38); $script:btnClear.Size = SZ 84 28; $script:btnClear.Anchor = 'Bottom, Right'
    $script:btnCopy = New-Object Vanguard.UI.RoundButton
    $script:btnCopy.Text = 'Copiar registro'; $script:btnCopy.Font = [System.Drawing.Font]::new('Segoe UI Semibold', [single]8.5)
    $script:btnCopy.Location = PT ($formWidth - 24 - 84 - 8 - 84 - 8 - 128) ($formHeight - 38); $script:btnCopy.Size = SZ 128 28; $script:btnCopy.Anchor = 'Bottom, Right'
    $Form.Controls.Add($script:btnExit); $Form.Controls.Add($script:btnClear); $Form.Controls.Add($script:btnCopy)

    # ============================================================================
    #  10) EVENTOS Y ARRANQUE
    # ============================================================================
    $script:pollTimer = New-Object System.Windows.Forms.Timer
    $script:pollTimer.Interval = 120
    $script:pollTimer.add_Tick({ Poll-Worker })

    $script:swTheme.SetCheckedSilent([bool]$script:Theme.IsDark)
    $script:swTheme.add_CheckedChanged({
        $isDarkChoice = [bool]$script:swTheme.Checked
        if ($isDarkChoice) { $script:Theme = $script:Themes['dark'] } else { $script:Theme = $script:Themes['light'] }
        if ($isDarkChoice) { Set-Setting 'theme' 'dark' } else { Set-Setting 'theme' 'light' }
        Apply-Theme
    })

    $script:btnBrowse.add_Click({
        $initial = [string]$script:txtPath.Text
        $picked = $null
        try { $picked = [Vanguard.UI.Native]::PickFolder($script:Form.Handle, 'Selecciona la carpeta de Riot Games', $initial) }
        catch {
            Write-FileLog 'warn' ('Selector moderno no disponible, se usa el clásico: ' + $_.Exception.Message)
            $fallback = New-Object System.Windows.Forms.FolderBrowserDialog
            $fallback.Description = 'Selecciona la carpeta de Riot Games'
            if ($initial -and (Test-Path -LiteralPath $initial)) { $fallback.SelectedPath = $initial }
            if ($fallback.ShowDialog($script:Form) -eq 'OK') { $picked = $fallback.SelectedPath }
            $fallback.Dispose()
        }
        if ($picked) {
            $why = Get-RiotPathReason -PathValue $picked
            if ($why) { [void](Show-Dialog 'Carpeta no válida' $why 'OK' 'warn') }
            else { $script:txtPath.Text = $picked }
        }
    })

    $script:btnCancel.add_Click({
        if ($script:Worker) {
            $script:Worker.State.Cancel = $true
            $script:btnCancel.Enabled = $false
            Add-Log 'Cancelando... (se detendrá al terminar el paso actual)' 'warn'
        }
    })
    $script:btnCopy.add_Click({
        try {
            if ($script:txtLog.TextLength -gt 0) { [System.Windows.Forms.Clipboard]::SetText($script:txtLog.Text); Set-Progress 0 'Registro copiado al portapapeles' }
        } catch { Add-Log ('No se pudo copiar el registro: ' + $_.Exception.Message) 'warn' }
    })
    $script:btnClear.add_Click({ $script:LogLines.Clear(); $script:txtLog.Clear() })
    $script:btnExit.add_Click({ $script:Form.Close() })

    $Form.add_FormClosing({
        param($sender, $ev)
        if ($script:Worker) {
            $ans = Show-Dialog 'Operación en curso' "Hay una operación en curso. ¿Quieres cancelarla y salir?`r`n`r`nSi Vanguard se estaba reiniciando, se esperará a que termine para no dejarlo detenido (hasta 30 segundos)." 'YesNo' 'warn' 'Cancelar y salir' 'Seguir'
            if ($ans -ne 'Yes') { $ev.Cancel = $true; return }
            $script:Closing = $true
            $script:Worker.State.Cancel = $true
            $script:lblStatus.Text = 'Finalizando la operación...'
            $deadline = (Get-Date).AddSeconds(30)
            while ($script:Worker -and -not $script:Worker.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 100
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    })

    $script:txtPath.Text = ''

    $Form.add_Shown({
        Apply-Theme
        Add-Log ('{0} {1} listo. Windows {2}.' -f $script:AppName, $script:AppVer, [Environment]::OSVersion.Version) 'ok'
        Add-Log 'Consejo: empieza por «Diagnóstico» para ver el estado de Vanguard y de Riot sin modificar nada.' 'info'
        try {
            $detected = Find-RiotClient -UserPath ''
            if ($detected.Exe) {
                $root = Get-RiotRootFromExe $detected.Exe
                if ($root) { $script:AutoRiotPath = $root; $script:txtPath.Text = $root }
                Add-Log ('Riot Client detectado: ' + $detected.Exe) 'info'
            } else {
                Add-Log 'No se detectó Riot Client en las ubicaciones habituales. Pulsa «Examinar» si está en otra carpeta.' 'warn'
            }
        } catch { Add-Log ('No se pudo buscar Riot Client: ' + $_.Exception.Message) 'warn' }
        Add-Log ('Instantáneas de estado en: ' + $script:BackupDir) 'info'
    })

    Apply-Theme
    $Form.ResumeLayout($true)
    [void]$Form.ShowDialog()
}
catch {
    $fatal = $_.Exception.Message
    Write-FileLog 'err' ('Error fatal: ' + $fatal)
    Show-StartupMessage ('Error inesperado: ' + $fatal)
}
finally {
    try { if ($script:pollTimer) { $script:pollTimer.Stop(); $script:pollTimer.Dispose() } } catch { $null = $_ }
    try { if ($script:Worker) { $script:Worker.State.Cancel = $true } } catch { $null = $_ }
    try { if ($script:ghBmp) { $script:ghBmp.Dispose() } } catch { $null = $_ }
    try { if ($script:ghStream) { $script:ghStream.Dispose() } } catch { $null = $_ }
}
