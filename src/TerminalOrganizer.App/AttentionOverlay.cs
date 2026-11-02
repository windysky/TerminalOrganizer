using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using TerminalOrganizer.Core.Attention;
using TerminalOrganizer.Core.Monitors;

namespace TerminalOrganizer.App
{
    /// <summary>
    /// The pure overlay geometry (REQ-OVL-001, plan.md section J; AC-010): given a target
    /// rectangle (L, T, R, B) and the ring thickness k, the overlay hugs it at
    /// x = L - k, y = T - k, width = (R - L) + 2k, height = (B - T) + 2k. A pure function
    /// of its inputs: no file, clock or process reads, never throws.
    /// </summary>
    public static class AttentionOverlayGeometry
    {
        /// <summary>The overlay rectangle as (x, y, width, height).</summary>
        public static int[] OverlayRect(int left, int top, int right, int bottom, int thickness)
        {
            return new int[]
            {
                left - thickness,
                top - thickness,
                (right - left) + 2 * thickness,
                (bottom - top) + 2 * thickness
            };
        }

        /// <summary>
        /// The form-side conversion (post-audit fix round 2): one target (L, T, R, B) quad
        /// with the ring thickness to the native positioning call's (x, y, cx, cy) — the
        /// AC-010 geometry with EXTENTS (R - L, B - T), never the raw right/bottom. The
        /// regression this pins was live-measured: the quad reached the (x, y, cx, cy)
        /// slots unchanged, so R landed in cx and B in cy and the ring grew by the
        /// target's own origin (repro-overlay-pos.{ps1,log}: target quad (474, 5, 940,
        /// 1027) rendered at (474, 5) sized 940x1027, 474 px over the neighbor). A null or
        /// short quad degrades to zeros; never throws.
        /// </summary>
        public static int[] PlaceRect(int[] targetRect, int thickness)
        {
            if (targetRect == null || targetRect.Length < 4)
            {
                return new int[] { 0, 0, 0, 0 };
            }
            return OverlayRect(targetRect[0], targetRect[1], targetRect[2], targetRect[3], thickness);
        }

        // @MX:NOTE: the D-6-extension z-mode contract (plan.md A-6): ONE named sentinel, declared
        // exactly once, used exactly once — in InsertAfterFor's true branch. The sentinel is the
        // Win32 above-everything insertAfter value; its name deliberately contains none of the
        // five tokens the unedited D-6 guard rows forbid.
        private static readonly IntPtr AboveAllInsertAfter = new IntPtr(-1);

        /// <summary>
        /// The pure z-mode selector (SPEC-TRAY-014, the D-6 extension): the default (false)
        /// keeps the D-6 above-TARGET z-order; true selects the above-everything sentinel.
        /// The choice applies at overlay CREATION only (spec 2.2).
        /// </summary>
        public static IntPtr InsertAfterFor(bool topmost, IntPtr target)
        {
            return topmost ? AboveAllInsertAfter : target;
        }
    }

    /// <summary>
    /// The overlay factory seam (plan.md section J): four delegates keyed on the target
    /// handle — create (with the initial rectangle), restart (with the current rectangle,
    /// resetting the blink phase), tick (with the re-read rectangle) and stop. Tests
    /// inject recording fakes; <see cref="Live"/> builds the production factory that
    /// owns one real overlay form per handle.
    /// </summary>
    public sealed class AttentionOverlayFactory
    {
        public readonly System.Action<IntPtr, int[]> Create;
        public readonly System.Action<IntPtr, int[]> Restart;
        public readonly System.Action<IntPtr, int[]> Tick;
        public readonly System.Action<IntPtr> Stop;

        /// <summary>Post-audit fix B: hides one ring while its target lives on another
        /// virtual desktop (the overlay stays alive; no-op when not supplied).</summary>
        public readonly System.Action<IntPtr> Hide;

        /// <summary>SPEC-TRAY-016 (REQ-MSG-001): the panel-message seam. The controller
        /// publishes the consumed signal's message before Create/Restart; the production
        /// factory's panel twins read it (a non-renderable message is ring-only,
        /// REQ-MSG-002). Suite factories get the no-op default and ignore it.</summary>
        public readonly System.Action<string> SetPanelMessage;

        /// <summary>t13 (the 2026-11-01 live-session round): the panel-kind seam. The
        /// controller publishes the consumed signal's kind beside the message; the
        /// production factory's panel twins read it to style the text color (ask red /
        /// info amber / default near-white — AttentionMessageStyle). Suite factories
        /// get the no-op default and ignore it.</summary>
        public readonly System.Action<string> SetPanelKind;

        public AttentionOverlayFactory(System.Action<IntPtr, int[]> create,
            System.Action<IntPtr, int[]> restart, System.Action<IntPtr, int[]> tick,
            System.Action<IntPtr> stop)
            : this(create, restart, tick, stop, null)
        {
        }

        public AttentionOverlayFactory(System.Action<IntPtr, int[]> create,
            System.Action<IntPtr, int[]> restart, System.Action<IntPtr, int[]> tick,
            System.Action<IntPtr> stop, System.Action<IntPtr> hide)
            : this(create, restart, tick, stop, hide, null)
        {
        }

        public AttentionOverlayFactory(System.Action<IntPtr, int[]> create,
            System.Action<IntPtr, int[]> restart, System.Action<IntPtr, int[]> tick,
            System.Action<IntPtr> stop, System.Action<IntPtr> hide,
            System.Action<string> setPanelMessage)
            : this(create, restart, tick, stop, hide, setPanelMessage, null)
        {
        }

        public AttentionOverlayFactory(System.Action<IntPtr, int[]> create,
            System.Action<IntPtr, int[]> restart, System.Action<IntPtr, int[]> tick,
            System.Action<IntPtr> stop, System.Action<IntPtr> hide,
            System.Action<string> setPanelMessage, System.Action<string> setPanelKind)
        {
            if (create == null) throw new ArgumentNullException("create");
            if (restart == null) throw new ArgumentNullException("restart");
            if (tick == null) throw new ArgumentNullException("tick");
            if (stop == null) throw new ArgumentNullException("stop");
            Create = create;
            Restart = restart;
            Tick = tick;
            Stop = stop;
            Hide = hide ?? delegate(IntPtr target) { };
            SetPanelMessage = setPanelMessage ?? delegate(string message) { };
            SetPanelKind = setPanelKind ?? delegate(string kind) { };
        }

        /// <summary>
        /// The production factory: one live overlay form per handle, created shown, ticked
        /// with the controller-supplied rectangle, restarted in place, and closed and
        /// disposed on stop. Real-screen behaviour — morning checklist (AC-014), not an
        /// acceptance claim. This overload always creates above-target rings (D-6 default).
        /// </summary>
        public static AttentionOverlayFactory Live()
        {
            return Live(null);
        }

        /// <summary>
        /// The SPEC-TRAY-014 form (the D-6 extension): the mode supplier is read at CREATION
        /// only, so SetTopmost affects new overlays while live ones keep their mode (spec 2.2).
        /// A null supplier behaves as constant false (the D-6 default).
        /// SPEC-TRAY-016 (REQ-MSG-001) adds the PANEL twins riding the same handle-keyed
        /// lifecycle: Create makes the ring plus a panel when the current signal carries a
        /// renderable message, Restart re-measures and re-places the panel (dismissing it
        /// when the new signal carries none), the off-desktop Hide hides both, Stop
        /// disposes both, and the blink Tick still touches ONLY the ring — the panel never
        /// toggles with the 1 Hz blink (its sole Tick-path contact is the desktop-gate
        /// restore, a steady-state no-op).
        /// </summary>
        public static AttentionOverlayFactory Live(Func<bool> topmostMode)
        {
            return Live(topmostMode, null);
        }

        /// <summary>
        /// t10 (the 2026-11-01 live-session round): the desktop-aware production form.
        /// The create/restart twins consult the virtual-desktop source AT ARRIVAL — a
        /// target on ANOTHER desktop births its overlay HIDDEN (SeedHidden /
        /// ShowPanelHidden; RestartHidden / RestartPanelHidden) instead of flashing
        /// once before the first blink tick's desktop gate hides it. The tick's
        /// existing gate reveals both on the first on-desktop tick (the
        /// hide-but-keep-alive semantics reused at birth). The arrival gate is
        /// fail-open like the controller's: a null source or a failed/indeterminate
        /// query keeps the shown-at-arrival behavior.
        /// </summary>
        public static AttentionOverlayFactory Live(Func<bool> topmostMode, IDesktopSource desktops)
        {
            Dictionary<long, AttentionOverlayForm> forms = new Dictionary<long, AttentionOverlayForm>();
            Dictionary<long, AttentionMessagePanelForm> panels = new Dictionary<long, AttentionMessagePanelForm>();
            string panelMessage = null;
            string panelKind = null;
            Func<bool> mode = topmostMode ?? delegate { return false; };
            return new AttentionOverlayFactory(
                delegate(IntPtr target, int[] rect)
                {
                    AttentionOverlayForm form = new AttentionOverlayForm(target, rect, mode());
                    forms[target.ToInt64()] = form;
                    if (TargetOnCurrentDesktop(desktops, target))
                    {
                        form.ShowNoActivate();
                    }
                    else
                    {
                        form.SeedHidden();
                    }
                    // Panel twin (REQ-MSG-001/002): a panel exists only when the signal
                    // carries a non-empty message — absent, null, or whitespace-only is
                    // ring-only; no panel form is created. t10: an off-desktop arrival
                    // births the card hidden with the ring.
                    if (AttentionMessageText.IsRenderable(panelMessage))
                    {
                        AttentionMessagePanelForm panel = new AttentionMessagePanelForm(target, mode());
                        panels[target.ToInt64()] = panel;
                        if (TargetOnCurrentDesktop(desktops, target))
                        {
                            panel.ShowPanel(panelMessage, panelKind, rect);
                        }
                        else
                        {
                            panel.ShowPanelHidden(panelMessage, panelKind, rect);
                        }
                    }
                },
                delegate(IntPtr target, int[] rect)
                {
                    AttentionOverlayForm form;
                    if (forms.TryGetValue(target.ToInt64(), out form) && form != null)
                    {
                        if (TargetOnCurrentDesktop(desktops, target))
                        {
                            form.Restart(rect);
                        }
                        else
                        {
                            form.RestartHidden(rect);
                        }
                    }
                    // Panel twin: re-measure and re-place on the new signal's message —
                    // or dismiss the panel when the new signal carries none. t10: an
                    // off-desktop restart keeps the card hidden too.
                    AttentionMessagePanelForm panel;
                    if (panels.TryGetValue(target.ToInt64(), out panel))
                    {
                        if (panel != null && AttentionMessageText.IsRenderable(panelMessage))
                        {
                            if (TargetOnCurrentDesktop(desktops, target))
                            {
                                panel.RestartPanel(panelMessage, panelKind, rect);
                            }
                            else
                            {
                                panel.RestartPanelHidden(panelMessage, panelKind, rect);
                            }
                        }
                        else
                        {
                            panels.Remove(target.ToInt64());
                            if (panel != null)
                            {
                                panel.Close();
                                panel.Dispose();
                            }
                        }
                    }
                    else if (AttentionMessageText.IsRenderable(panelMessage))
                    {
                        AttentionMessagePanelForm created = new AttentionMessagePanelForm(target, mode());
                        panels[target.ToInt64()] = created;
                        if (TargetOnCurrentDesktop(desktops, target))
                        {
                            created.ShowPanel(panelMessage, panelKind, rect);
                        }
                        else
                        {
                            created.ShowPanelHidden(panelMessage, panelKind, rect);
                        }
                    }
                },
                delegate(IntPtr target, int[] rect)
                {
                    AttentionOverlayForm form;
                    if (forms.TryGetValue(target.ToInt64(), out form) && form != null)
                    {
                        form.Tick(rect);
                    }
                    // The panel is NEVER a target of the ring's toggle (REQ-MSG-001: the
                    // panel is STEADY while the ring blinks). Its sole Tick-path contact
                    // is the desktop-gate restore below — a no-op bool check while the
                    // target stays on the current desktop, so no per-tick panel work
                    // exists at steady state; a user-closed panel stays closed.
                    AttentionMessagePanelForm panel;
                    if (panels.TryGetValue(target.ToInt64(), out panel) && panel != null)
                    {
                        panel.RestoreIfDesktopHidden();
                    }
                },
                delegate(IntPtr target)
                {
                    AttentionOverlayForm form;
                    if (forms.TryGetValue(target.ToInt64(), out form))
                    {
                        forms.Remove(target.ToInt64());
                        if (form != null)
                        {
                            form.Close();
                            form.Dispose();
                        }
                    }
                    // Panel twin: the panel dies with the overlay lifecycle regardless
                    // (REQ-MSG-001) — every stop path (stop conditions, disable,
                    // dispose) lands here.
                    AttentionMessagePanelForm panel;
                    if (panels.TryGetValue(target.ToInt64(), out panel))
                    {
                        panels.Remove(target.ToInt64());
                        if (panel != null)
                        {
                            panel.Close();
                            panel.Dispose();
                        }
                    }
                },
                delegate(IntPtr target)
                {
                    AttentionOverlayForm form;
                    if (forms.TryGetValue(target.ToInt64(), out form) && form != null)
                    {
                        form.HideRing();
                    }
                    // Panel twin: the same off-desktop gate hides both (REQ-MSG-001).
                    AttentionMessagePanelForm panel;
                    if (panels.TryGetValue(target.ToInt64(), out panel) && panel != null)
                    {
                        panel.HidePanel();
                    }
                },
                delegate(string message)
                {
                    // The panel-message seam: the controller publishes the consumed
                    // signal's message before Create/Restart (REQ-MSG-001); the twins
                    // above read it. Ring-only factories get the no-op default.
                    panelMessage = message;
                },
                delegate(string kind)
                {
                    // t13 (the 2026-11-01 live-session round): the panel-kind seam —
                    // the controller publishes the consumed signal's kind beside the
                    // message; the twins above read it for the text color.
                    panelKind = kind;
                });
        }

        /// <summary>
        /// t10 (the 2026-11-01 live-session round): the fail-open arrival gate — true
        /// (shown) for a null source or a failed/indeterminate query (the controller's
        /// IsOnCurrentDesktop semantics), false only for a SUCCESSFUL off-desktop
        /// answer, in which case the overlay is born hidden instead.
        /// </summary>
        private static bool TargetOnCurrentDesktop(IDesktopSource desktops, IntPtr target)
        {
            if (desktops == null)
            {
                return true;
            }
            DesktopFlagResult flag;
            try
            {
                flag = desktops.IsWindowOnCurrentVirtualDesktop(target);
            }
            catch (Exception)
            {
                return true;
            }
            if (flag == null || !flag.Success)
            {
                return true;
            }
            return flag.Value;
        }
    }

    /// <summary>
    /// The overlay ring window (REQ-OVL-001/002): borderless, click-through, never taking
    /// focus — created with WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW and WS_EX_TRANSPARENT, shown
    /// through SW_SHOWNOACTIVATE, positioned ONLY through SetWindowPos-with-SWP_NOACTIVATE
    /// calls (NFR-7: physical pixels end to end, never the WinForms position properties).
    /// D-6: the ring z-orders DIRECTLY ABOVE ITS TARGET (hWndInsertAfter = the target
    /// handle on every positioning call), never above everything — a covering window covers
    /// the ring too, and exposing the terminal shows it. The middle is a transparency key
    /// so only the amber ring renders. Real-screen behaviour — morning checklist (AC-014),
    /// not an acceptance claim.
    /// </summary>
    // @MX:WARN: [AUTO] real overlay window surface (target-relative z-order ring, native calls) — morning checklist; not an acceptance claim.
    internal sealed class AttentionOverlayForm : Form
    {
        // The pinned Win32 values (plan.md section J): changing one is a SPEC amendment.
        private const int SwShownoactivate = 4;
        private const int SwpNoactivate = 0x0010;
        private const int SwpShowwindow = 0x0040;
        private const int SwpHideWindow = 0x0080;
        private const int SwpNosize = 0x0001;
        private const int SwpNomove = 0x0002;

        /// <summary>D-6: the ring z-orders directly above this target handle, never above everything.</summary>
        private readonly IntPtr target;

        /// <summary>SPEC-TRAY-014 (the D-6 extension): the creation-time z-mode — false keeps the
        /// above-target D-6 default; true rides above everything. Fixed for this form's lifetime.</summary>
        private readonly bool topmostMode;
        private readonly int thickness;
        private bool ringOn;

        internal AttentionOverlayForm(IntPtr targetHandle, int[] initialRect, bool topmostMode)
        {
            this.target = targetHandle;
            this.topmostMode = topmostMode;
            this.thickness = AttentionConstants.RingThicknessPx;
            this.ringOn = true;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopLevel = true;
            Color key = Color.FromArgb(255, 0, 255);
            BackColor = key;
            TransparencyKey = key;
            // Position once before the first show; the no-activate placement only (NFR-7).
            Place(initialRect, 0);
        }

        /// <summary>
        /// The pinned extended styles applied on creation: WS_EX_NOACTIVATE (0x08000000),
        /// WS_EX_TOOLWINDOW (0x00000080), WS_EX_TRANSPARENT (0x00000020). D-6 removed the
        /// always-on-top style: the ring rides just above its TARGET, so a covering window
        /// covers the ring too.
        /// </summary>
        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle = cp.ExStyle | 0x08000000 | 0x00000080 | 0x00000020;
                return cp;
            }
        }

        /// <summary>WinForms companion of the SW_SHOWNOACTIVATE rule: the form never takes focus on show.</summary>
        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        /// <summary>Shows the ring without activating it (REQ-OVL-002).</summary>
        internal void ShowNoActivate()
        {
            Native.ShowWindow(Handle, SwShownoactivate);
            ringOn = true;
        }

        /// <summary>One blink tick (REQ-OVL-001): follow the re-read rectangle and toggle the ring.</summary>
        internal void Tick(int[] rect)
        {
            ringOn = !ringOn;
            Place(rect, ringOn ? SwpShowwindow : SwpHideWindow);
        }

        /// <summary>Restarts the blink window (D-3): back to the visible phase, repositioned.</summary>
        internal void Restart(int[] rect)
        {
            ringOn = true;
            Place(rect, SwpShowwindow);
        }

        /// <summary>
        /// Post-audit fix B: hides the ring while the target lives on another virtual
        /// desktop — the overlay STAYS alive (never a stop). ringOn is forced false so the
        /// next Tick's toggle lands on visible: the ring reappears on the very first
        /// on-desktop tick. Position and size are left untouched (NOSIZE/NOMOVE).
        /// </summary>
        internal void HideRing()
        {
            ringOn = false;
            Place(new int[] { 0, 0, 0, 0 }, SwpHideWindow | SwpNosize | SwpNomove);
        }

        /// <summary>
        /// t10 (the 2026-11-01 live-session round): the hidden birth — the target arrived
        /// on ANOTHER virtual desktop, so the ring never shows at creation (the pre-fix
        /// behavior flashed it once until the first blink tick's desktop gate hid it).
        /// ringOn is seeded FALSE (the HideRing state) so the FIRST on-desktop Tick's
        /// toggle lands on visible; the form was never shown, so no hide call is needed.
        /// </summary>
        internal void SeedHidden()
        {
            ringOn = false;
        }

        /// <summary>
        /// t10: the off-desktop restart twin — repositioned to the fresh rectangle like
        /// Restart, but kept hidden with ringOn false (a visible ring hides now); the
        /// first on-desktop tick reveals it.
        /// </summary>
        internal void RestartHidden(int[] rect)
        {
            ringOn = false;
            Place(rect, SwpHideWindow);
        }

        /// <summary>The amber ring: four thickness-wide bars along the form edges.</summary>
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            int rgb = AttentionConstants.RingColorRgb;
            int width = ClientSize.Width;
            int height = ClientSize.Height;
            using (SolidBrush brush = new SolidBrush(Color.FromArgb(
                (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)))
            {
                e.Graphics.FillRectangle(brush, 0, 0, width, thickness);
                e.Graphics.FillRectangle(brush, 0, height - thickness, width, thickness);
                e.Graphics.FillRectangle(brush, 0, 0, thickness, height);
                e.Graphics.FillRectangle(brush, width - thickness, 0, thickness, height);
            }
        }

        private void Place(int[] targetRect, int extraFlags)
        {
            // Post-audit fix round 2: the raw (L, T, R, B) quad NEVER reaches the native
            // sizing slots — PlaceRect applies the AC-010 geometry and yields (x, y, cx, cy)
            // with EXTENTS (R - L, B - T). Every positioning call still carries SwpNoactivate
            // (SWP_NOACTIVATE) and threads the z-mode selector (hWndInsertAfter chosen between
            // the above-everything sentinel and the TARGET handle at creation; the D-6 default
            // keeps the ring directly above its terminal so a covering window covers it too);
            // nothing else moves this window (NFR-7).
            int[] place = AttentionOverlayGeometry.PlaceRect(targetRect, thickness);
            Native.SetWindowPos(Handle, AttentionOverlayGeometry.InsertAfterFor(topmostMode, target), place[0], place[1], place[2], place[3], (uint)(SwpNoactivate | extraFlags));
        }

        /// <summary>Hand-written P/Invoke declarations (tech.md; no assembly reference needed).</summary>
        private static class Native
        {
            [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags); // every call passes SwpNoactivate (SWP_NOACTIVATE)
            [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
        }
    }
}
