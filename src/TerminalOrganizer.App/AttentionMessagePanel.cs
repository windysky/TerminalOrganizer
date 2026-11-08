using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using TerminalOrganizer.Core.Attention;

namespace TerminalOrganizer.App
{
    /// <summary>
    /// SPEC-TRAY-016 (REQ-MSG-001, AM-6): the companion message panel — a separate
    /// borderless form riding the ring's handle-keyed lifecycle but NEVER blinking
    /// with it (steady while the ring toggles at 1 Hz). The panel is the ELECTED
    /// SELECTABLE departure from the ring's no-interference pins: it carries
    /// WS_EX_TOOLWINDOW ONLY — it DROPS the ring's WS_EX_NOACTIVATE and
    /// WS_EX_TRANSPARENT — so it activates on click and its text is selectable and
    /// copyable; it is SHOWN through SW_SHOWNOACTIVATE so creation never steals
    /// focus, and it deliberately does NOT override ShowWithoutActivation
    /// (activation on a later click is the point). Panel focus is NOT
    /// target-window focus: the ask-kind stop condition polls the TARGET handle's
    /// state in the controller — copying from the panel during an ask blink never
    /// stops the ring. The close affordance dismisses the PANEL ONLY (this source
    /// holds no reference to the ring form, making that structural). TrayShell
    /// never runs under Pester (A3): rendering is manual-AC coverage (AC-011).
    /// </summary>
    // @MX:NOTE: [AUTO] steady companion surface (REQ-MSG-001, AM-6): activatable/selectable panel; panel focus never stops the ask ring (the stop check polls the TARGET handle); manual-AC coverage (no automated WinForms test).
    internal sealed class AttentionMessagePanelForm : Form
    {
        // The pinned Win32 values (plan.md section J / the ring form's set, message subset).
        private const int SwShownoactivate = 4;
        private const int SwpNoactivate = 0x0010;
        private const int SwpShowwindow = 0x0040;
        private const int SwpHideWindow = 0x0080;
        private const int SwpNosize = 0x0001;
        private const int SwpNomove = 0x0002;
        private const uint GwHwndPrev = 3;
        private const uint SwpNozorder = 0x0004;

        // SPEC-TRAY-018 (D-2): insertAfter for a card that must sit ABOVE the target —
        // SetWindowPos inserts the positioned window DIRECTLY BELOW hWndInsertAfter, so
        // the slot directly above the target belongs to the window currently directly
        // above it. Zero (nothing above the target / dead handle) is HWND_TOP — the top
        // of the non-topmost band, which is still above the target.
        private static IntPtr AboveTargetInsertAfter(bool topmost, IntPtr target)
        {
            if (topmost)
            {
                return AttentionOverlayGeometry.InsertAfterFor(true, target);
            }
            return Native.GetWindow(target, GwHwndPrev);
        }

        private readonly IntPtr target;
        private readonly bool topmostMode;
        private readonly Font textFont;
        // DPI-scaled geometry (the 2026-11-07 laptop-scaling fix): the pinned
        // AttentionConstants stay the 96-DPI baseline; these carry the same values
        // multiplied by the target monitor's DPI factor so a scaled display
        // (125%/150%) renders the card at the same PHYSICAL size as 100%.
        private readonly int fontPx;
        private readonly int paddingPx;
        private readonly int closeSizePx;
        private readonly int accentPx;
        private readonly TextBox text;
        private bool desktopHidden;
        private bool userClosed;
        private Rectangle closeGlyph;

        internal AttentionMessagePanelForm(IntPtr targetHandle, bool topmostMode)
        {
            this.target = targetHandle;
            this.topmostMode = topmostMode;
            this.desktopHidden = false;
            this.userClosed = false;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopLevel = true;
            // The solid near-black card: NO TransparencyKey — the whole form is solid
            // (the ring's key trick does not apply to a text surface).
            BackColor = RgbColor(AttentionConstants.MessagePanelBackRgb);
            // Pixel-exact typography (NFR-7, amended 2026-11-07): the form lives in
            // physical pixels and the font stays GraphicsUnit.Pixel, but the pinned
            // sizes are now the 96-DPI BASELINE, scaled by the target monitor's DPI
            // factor — a 150% laptop renders 14px as 21 physical px so the card keeps
            // its physical size (the original "no DPI math" wording covered only the
            // 100%-scaling monitors it was designed on).
            int dpi = DpiOfWindow(targetHandle);
            fontPx = ScalePx(AttentionConstants.MessageFontPx, dpi);
            paddingPx = ScalePx(AttentionConstants.MessagePaddingPx, dpi);
            closeSizePx = ScalePx(AttentionConstants.MessageCloseSizePx, dpi);
            accentPx = ScalePx(AttentionConstants.MessageAccentPx, dpi);
            textFont = new Font(FontFamily.GenericSansSerif, fontPx,
                FontStyle.Regular, GraphicsUnit.Pixel);
            text = new TextBox();
            text.Multiline = true;
            // Read-only WinForms text IS selectable and copyable (mouse + keyboard,
            // Ctrl+C) — the AM-2/AM-6 interaction surface: select, copy, close; no
            // editing, no scrolling (the panel is sized to the capped text).
            text.ReadOnly = true;
            text.BorderStyle = BorderStyle.None;
            text.ScrollBars = ScrollBars.None;
            text.BackColor = RgbColor(AttentionConstants.MessagePanelBackRgb);
            text.ForeColor = RgbColor(AttentionConstants.MessageTextRgb);
            text.Font = textFont;
            text.ShortcutsEnabled = true;
            text.Cursor = Cursors.IBeam;
            // t13 (the 2026-11-01 UX round): the card text is CENTER-aligned.
            text.TextAlign = HorizontalAlignment.Center;
            Controls.Add(text);
            // The close-affordance hit test runs on both surfaces: the glyph's corner
            // overlaps the TextBox's top-right edge, and clicks there land on the TextBox.
            text.MouseDown += OnCloseAffordance;
        }

        /// <summary>
        /// AM-6: WS_EX_TOOLWINDOW ONLY — the panel deliberately drops the ring's
        /// no-activate and click-through extended styles so it can activate on click
        /// and receive text selection.
        /// </summary>
        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle = cp.ExStyle | 0x00000080;
                return cp;
            }
        }

        /// <summary>
        /// Creation show (REQ-MSG-001): measure, place, then SW_SHOWNOACTIVATE — the
        /// panel never steals focus at creation. t13 (the 2026-11-01 UX round): the
        /// kind rides the call so the text color follows the signal.
        /// </summary>
        internal void ShowPanel(string message, string kind, int[] targetRect)
        {
            userClosed = false;
            desktopHidden = false;
            ApplyMessage(message, kind, targetRect);
            Native.ShowWindow(Handle, SwShownoactivate);
        }

        /// <summary>
        /// Restart twin (REQ-MSG-001): re-measure and re-place on the new signal's
        /// message. A user-closed panel resurrects — a new signal is new attention
        /// content; the panel then dies with the overlay lifecycle regardless.
        /// </summary>
        internal void RestartPanel(string message, string kind, int[] targetRect)
        {
            userClosed = false;
            desktopHidden = false;
            ApplyMessage(message, kind, targetRect);
            ShowWindowNoActivate();
        }

        /// <summary>
        /// t10 (the 2026-11-01 live-session round): the hidden-birth twin of ShowPanel —
        /// measure, place and style exactly as the shown path, but the card is BORN
        /// HIDDEN (desktopHidden = true, no show call): the target arrived on another
        /// virtual desktop; the first on-desktop blink tick's desktop-gate restore
        /// reveals it.
        /// </summary>
        internal void ShowPanelHidden(string message, string kind, int[] targetRect)
        {
            userClosed = false;
            desktopHidden = true;
            ApplyMessage(message, kind, targetRect);
        }

        /// <summary>
        /// t10: the hidden restart twin — re-measure, re-place and re-style on the new
        /// signal's message while staying hidden (a card that was visible hides now);
        /// the gate restores it on the first on-desktop tick.
        /// </summary>
        internal void RestartPanelHidden(string message, string kind, int[] targetRect)
        {
            userClosed = false;
            ApplyMessage(message, kind, targetRect);
            HidePanel();
        }

        /// <summary>
        /// The off-desktop desktop-gate twin (REQ-MSG-001): hidden by the same gate as
        /// the ring — the panel STAYS alive; position and size untouched.
        /// </summary>
        internal void HidePanel()
        {
            desktopHidden = true;
            HideWindowNoActivate();
        }

        /// <summary>
        /// The gate's other half, riding the on-desktop tick: restore a desktop-hidden
        /// panel (REQ-MSG-001: hidden AND re-shown by the same gate). This is NOT a
        /// blink toggle — at steady state it is a no-op bool check (no per-tick panel
        /// work), and a user-closed panel stays closed.
        /// </summary>
        internal void RestoreIfDesktopHidden()
        {
            if (!desktopHidden || userClosed)
            {
                return;
            }
            desktopHidden = false;
            ShowWindowNoActivate();
        }

        /// <summary>
        /// REQ-OVL-003 (SPEC-TRAY-017): the show flag-only reposition — one named helper
        /// per flag combination (show / hide). Re-shows the window in place with no
        /// activation, no move, no resize and no z-order change (SPEC-TRAY-018 D-3:
        /// SWP_NOZORDER — "in place" includes the z band, so a restart-show or gate
        /// restore never yanks the card to the top of the non-topmost band; NFR-7:
        /// SWP_NOACTIVATE on every call).
        /// </summary>
        private void ShowWindowNoActivate()
        {
            Native.SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0,
                (uint)(SwpNoactivate | SwpShowwindow | SwpNosize | SwpNomove | SwpNozorder));
        }

        /// <summary>REQ-OVL-003 (SPEC-TRAY-017): the hide flag-only reposition — the
        /// show helper's hide twin (SWP_HIDEWINDOW in place of SWP_SHOWWINDOW), equally
        /// z-neutral (SPEC-TRAY-018 D-3: SWP_NOZORDER).</summary>
        private void HideWindowNoActivate()
        {
            Native.SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0,
                (uint)(SwpNoactivate | SwpHideWindow | SwpNosize | SwpNomove | SwpNozorder));
        }

        /// <summary>
        /// The painted card: the solid background, the amber border on all four edges
        /// (RingColorRgb, echoing the ring; MessageAccentPx thick, inside the padding, so
        /// the card stays distinct on a black terminal), and the close glyph — an X sized by MessageCloseSizePx at
        /// the top-right corner, sitting inside the existing padding (no geometry
        /// change; the panel rect math never reserves space for it).
        /// </summary>
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            int width = ClientSize.Width;
            int height = ClientSize.Height;
            using (SolidBrush back = new SolidBrush(RgbColor(AttentionConstants.MessagePanelBackRgb)))
            {
                e.Graphics.FillRectangle(back, 0, 0, width, height);
            }
            using (SolidBrush accent = new SolidBrush(RgbColor(AttentionConstants.RingColorRgb)))
            {
                int border = accentPx;
                e.Graphics.FillRectangle(accent, 0, 0, width, border);
                e.Graphics.FillRectangle(accent, 0, height - border, width, border);
                e.Graphics.FillRectangle(accent, 0, 0, border, height);
                e.Graphics.FillRectangle(accent, width - border, 0, border, height);
            }
            using (Pen glyphPen = new Pen(RgbColor(AttentionConstants.MessageTextRgb)))
            {
                int inset = closeSizePx / 4;
                e.Graphics.DrawLine(glyphPen,
                    closeGlyph.Left + inset, closeGlyph.Top + inset,
                    closeGlyph.Right - inset, closeGlyph.Bottom - inset);
                e.Graphics.DrawLine(glyphPen,
                    closeGlyph.Right - inset, closeGlyph.Top + inset,
                    closeGlyph.Left + inset, closeGlyph.Bottom - inset);
            }
        }

        /// <summary>Disposes the held font with the form (the TextBox rides Controls disposal).</summary>
        protected override void Dispose(bool disposing)
        {
            if (disposing && textFont != null)
            {
                textFont.Dispose();
            }
            base.Dispose(disposing);
        }

        /// <summary>
        /// Measure the prepared text at the interior width, place the panel through the
        /// pure layout (below / inside-right / inside-bottom, AC-009 + t11), style the
        /// text color from the kind (t13), and size the selectable text surface to the
        /// measurement. t11: a narrowed inside-right column re-wraps the text, so the
        /// measurement repeats at the placed interior (the width decision is
        /// height-independent, and the below-fit check only tightens with a taller
        /// card, so the branch is stable across the re-place). NFR-7: positioned ONLY
        /// through SetWindowPos carrying SWP_NOACTIVATE, z-ordered directly above the
        /// target (SPEC-TRAY-018 D-2: the neighbor-derived selector — SetWindowPos
        /// places the positioned window directly below hWndInsertAfter, so the window
        /// above the target is the slot that lands the card above it).
        /// </summary>
        private void ApplyMessage(string message, string kind, int[] targetRect)
        {
            int[] quad = targetRect == null || targetRect.Length < 4
                ? new int[] { 0, 0, 0, 0 }
                : targetRect;
            string prepared = AttentionMessageText.Prepare(message);
            text.Text = prepared;
            // t13: the kind-scoped text color (ask red / info amber / default near-white).
            text.ForeColor = RgbColor(AttentionMessageStyle.TextColorRgbForKind(kind));
            int interiorWidth = (quad[2] - quad[0]) - 2 * paddingPx;
            if (interiorWidth < 1)
            {
                interiorWidth = 1;
            }
            Size measured = TextRenderer.MeasureText(prepared, textFont,
                new Size(interiorWidth, int.MaxValue),
                TextFormatFlags.WordBreak | TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix);
            Rectangle workArea = Screen.FromHandle(target).WorkingArea;
            int[] workRect = new int[] { workArea.Left, workArea.Top, workArea.Right, workArea.Bottom };
            int[] place = AttentionMessageLayout.PlacePanel(quad, workRect, measured.Width, measured.Height);
            int placedInterior = place[2] - 2 * paddingPx;
            if (placedInterior >= 1 && placedInterior < interiorWidth)
            {
                // t11: the card was capped narrower than the target interior — re-wrap
                // at the placed width, keep the original preferred width for the cap
                // decision, and re-place with the (taller) re-measured height.
                int preferredWidth = measured.Width;
                measured = TextRenderer.MeasureText(prepared, textFont,
                    new Size(placedInterior, int.MaxValue),
                    TextFormatFlags.WordBreak | TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix);
                place = AttentionMessageLayout.PlacePanel(quad, workRect, preferredWidth, measured.Height);
            }
            int surfaceWidth = place[2] - 2 * paddingPx;
            if (surfaceWidth < 1)
            {
                surfaceWidth = 1;
            }
            text.SetBounds(paddingPx, paddingPx,
                surfaceWidth, measured.Height);
            closeGlyph = new Rectangle(place[2] - closeSizePx, 0,
                closeSizePx, closeSizePx);
            Native.SetWindowPos(Handle, AboveTargetInsertAfter(topmostMode, target),
                place[0], place[1], place[2], place[3], (uint)SwpNoactivate);
            // M2b (SPEC-TRAY-018): the panel never goes through Form.Show(), so the
            // WinForms child-handle creation path never runs — probe-proven on the
            // hidden-birth restore (the flag-only show leaves the TextBox with NO
            // native handle, and Form.CreateControl() no-ops while the form is
            // WinForms-invisible). Forcing the child's own handle gives the text a
            // WS_VISIBLE native surface on every twin path; idempotent once created.
            GC.KeepAlive(text.Handle);
        }

        /// <summary>
        /// The close affordance (AM-6): dismisses the PANEL ONLY — the ring and the
        /// overlay lifecycle continue under their own stop conditions.
        /// </summary>
        private void ClosePanel()
        {
            userClosed = true;
            desktopHidden = false;
            HideWindowNoActivate();
        }

        private void OnCloseAffordance(object sender, MouseEventArgs e)
        {
            Point formPoint = e.Location;
            Control source = sender as Control;
            if (source != null && !ReferenceEquals(source, this))
            {
                formPoint = new Point(formPoint.X + source.Left, formPoint.Y + source.Top);
            }
            if (closeGlyph.Contains(formPoint))
            {
                ClosePanel();
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (closeGlyph.Contains(e.Location))
            {
                ClosePanel();
            }
        }

        private static Color RgbColor(int rgb)
        {
            return Color.FromArgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
        }

        /// <summary>Hand-written P/Invoke declarations (tech.md; no assembly reference needed).</summary>
        private static class Native
        {
            [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags); // every call passes SwpNoactivate (SWP_NOACTIVATE)
            [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
            [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr GetWindow(IntPtr window, uint command);
            [DllImport("user32.dll")] public static extern int GetDpiForWindow(IntPtr window); // Win10 1607+; the safe wrapper below falls back to 96
        }

        /// <summary>The target window's DPI (96 when the API is unavailable or the handle
        /// is dead). Never throws — a pre-1607 entry-point miss or a zero return keeps the
        /// unscaled 96-DPI baseline rendering.</summary>
        internal static int DpiOfWindow(IntPtr hwnd)
        {
            try
            {
                int dpi = Native.GetDpiForWindow(hwnd);
                return dpi > 0 ? dpi : 96;
            }
            catch
            {
                return 96;
            }
        }

        /// <summary>Scales a pinned 96-DPI pixel constant to the given DPI. The pinned
        /// constants stay untouched (SPEC doctrine: no value edits); this multiplies.
        /// DPI at or below 96 returns the baseline unchanged (never shrinks).</summary>
        internal static int ScalePx(int px96, int dpi)
        {
            if (dpi <= 96)
            {
                return px96;
            }
            return (int)Math.Round(px96 * (double)dpi / 96.0);
        }
    }
}
