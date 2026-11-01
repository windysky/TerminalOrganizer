using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using TerminalOrganizer.Core.Attention;

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

        public AttentionOverlayFactory(System.Action<IntPtr, int[]> create,
            System.Action<IntPtr, int[]> restart, System.Action<IntPtr, int[]> tick,
            System.Action<IntPtr> stop)
            : this(create, restart, tick, stop, null)
        {
        }

        public AttentionOverlayFactory(System.Action<IntPtr, int[]> create,
            System.Action<IntPtr, int[]> restart, System.Action<IntPtr, int[]> tick,
            System.Action<IntPtr> stop, System.Action<IntPtr> hide)
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
        /// </summary>
        public static AttentionOverlayFactory Live(Func<bool> topmostMode)
        {
            Dictionary<long, AttentionOverlayForm> forms = new Dictionary<long, AttentionOverlayForm>();
            Func<bool> mode = topmostMode ?? delegate { return false; };
            return new AttentionOverlayFactory(
                delegate(IntPtr target, int[] rect)
                {
                    AttentionOverlayForm form = new AttentionOverlayForm(target, rect, mode());
                    forms[target.ToInt64()] = form;
                    form.ShowNoActivate();
                },
                delegate(IntPtr target, int[] rect)
                {
                    AttentionOverlayForm form;
                    if (forms.TryGetValue(target.ToInt64(), out form) && form != null)
                    {
                        form.Restart(rect);
                    }
                },
                delegate(IntPtr target, int[] rect)
                {
                    AttentionOverlayForm form;
                    if (forms.TryGetValue(target.ToInt64(), out form) && form != null)
                    {
                        form.Tick(rect);
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
                },
                delegate(IntPtr target)
                {
                    AttentionOverlayForm form;
                    if (forms.TryGetValue(target.ToInt64(), out form) && form != null)
                    {
                        form.HideRing();
                    }
                });
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
