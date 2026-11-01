using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using TerminalOrganizer.Core.Attention;
using TerminalOrganizer.Core.Windows;

namespace TerminalOrganizer.App
{
    /// <summary>
    /// The live window probe (plan.md A-2): a thin adapter that enumerates the Windows
    /// Terminal windows once per match run (Win32WindowEnumerator over the
    /// WindowsTerminal pid set), reads each window title (the raw GetWindowText read)
    /// and every tab title (the bounded UiaProbeClient helper read), and returns the
    /// matcher candidates. Also exposes the per-handle native lookups the controller
    /// needs (foreground, alive, minimized, target rectangle). Real-screen behaviour —
    /// morning checklist (AC-014), not an acceptance claim.
    /// </summary>
    // @MX:WARN: [AUTO] live enumeration + UIA subprocess reads — morning checklist; not an acceptance claim.
    public sealed class AttentionWindowProbe
    {
        /// <summary>One candidate per enumerated window: handle, window title, tab titles.</summary>
        public AttentionCandidate[] Candidates()
        {
            EnumeratedWindow[] windows = new Win32WindowEnumerator().Enumerate(
                Composition.ReadTerminalPids(), null, null);
            UiaProbeClient tabProbe = new UiaProbeClient(Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory, "TerminalOrganizer.UiaProbe.exe"));
            List<AttentionCandidate> candidates = new List<AttentionCandidate>();
            foreach (EnumeratedWindow window in windows)
            {
                if (window == null)
                {
                    continue;
                }
                candidates.Add(new AttentionCandidate(window.Handle,
                    UiaTabTitleReader.GetWindowTextTitle(window.Handle),
                    ReadTabTitles(tabProbe, window.Handle)));
            }
            return candidates.ToArray();
        }

        /// <summary>The current foreground window handle (the focus stop of REQ-CTL-004).</summary>
        public static IntPtr GetForeground()
        {
            return Native.GetForegroundWindow();
        }

        /// <summary>True while the target window still exists (the closed stop).</summary>
        public static bool IsAlive(IntPtr window)
        {
            return Native.IsWindow(window);
        }

        /// <summary>True while the target window is minimized (the minimized stop).</summary>
        public static bool IsMinimized(IntPtr window)
        {
            return Native.IsIconic(window);
        }

        /// <summary>
        /// The target's visible rectangle as (L, T, R, B) in physical pixels: the DWM
        /// extended frame bounds (the visible window WITHOUT the invisible resize borders —
        /// GetWindowRect reads +7 px out on left/right/bottom under FancyZones tiling, the
        /// post-audit fix A reproduction), with the GetWindowRect rect as the fallback when
        /// the DWM read fails (the WindowStateReader.cs pattern). Zeros when both fail.
        /// </summary>
        public static int[] TargetRect(IntPtr window)
        {
            return TargetRect(window,
                new Func<IntPtr, int[]>(delegate(IntPtr handle) { return ReadDwmFrameBounds(handle); }),
                new Func<IntPtr, int[]>(delegate(IntPtr handle) { return ReadWindowRect(handle); }));
        }

        /// <summary>
        /// The rect-source selection seam (post-audit fix A tests): the DWM frame bounds
        /// when that read succeeds, the GetWindowRect rect when it fails, throws, or returns
        /// a non-4-length array; never throws.
        /// </summary>
        public static int[] TargetRect(IntPtr window, Func<IntPtr, int[]> dwmFrameBounds,
            Func<IntPtr, int[]> windowRect)
        {
            int[] frame = ReadRectSource(dwmFrameBounds, window);
            if (frame != null)
            {
                return frame;
            }
            int[] rect = ReadRectSource(windowRect, window);
            if (rect != null)
            {
                return rect;
            }
            return new int[] { 0, 0, 0, 0 };
        }

        private static int[] ReadRectSource(Func<IntPtr, int[]> source, IntPtr window)
        {
            try
            {
                int[] rect = source == null ? null : source(window);
                if (rect != null && rect.Length == 4)
                {
                    return rect;
                }
            }
            catch (Exception)
            {
                // A failing source falls through to the next one (never throws).
            }
            return null;
        }

        /// <summary>DWMWA_EXTENDED_FRAME_BOUNDS: the visible frame rect (the WindowStateReader constant).</summary>
        private const int DwmwaExtendedFrameBounds = 9;

        private static int[] ReadDwmFrameBounds(IntPtr window)
        {
            Native.Rect frame;
            int hr = Native.DwmGetWindowAttribute(window, DwmwaExtendedFrameBounds, out frame,
                Marshal.SizeOf(typeof(Native.Rect)));
            return hr == 0 ? new int[] { frame.Left, frame.Top, frame.Right, frame.Bottom } : null;
        }

        private static int[] ReadWindowRect(IntPtr window)
        {
            Native.Rect rect;
            if (!Native.GetWindowRect(window, out rect))
            {
                return null;
            }
            return new int[] { rect.Left, rect.Top, rect.Right, rect.Bottom };
        }

        /// <summary>
        /// The effective tab titles (the discovery ResolveTitles pattern): the success
        /// list, the single fallback title on failure, or none.
        /// </summary>
        private static string[] ReadTabTitles(UiaProbeClient tabProbe, IntPtr window)
        {
            try
            {
                TabTitleResult tabs = tabProbe.ReadTabs(window, CancellationToken.None);
                if (tabs == null)
                {
                    return new string[0];
                }
                if (tabs.Success)
                {
                    return tabs.Titles;
                }
                if (!string.IsNullOrEmpty(tabs.FallbackTitle))
                {
                    return new string[] { tabs.FallbackTitle };
                }
                return new string[0];
            }
            catch (Exception)
            {
                // A tab-read failure degrades to no tab titles; the window title still matches.
                return new string[0];
            }
        }

        /// <summary>Hand-written P/Invoke declarations (tech.md; no assembly reference needed).</summary>
        private static class Native
        {
            [DllImport("user32.dll")]
            public static extern IntPtr GetForegroundWindow();

            [DllImport("user32.dll")]
            public static extern bool IsWindow(IntPtr window);

            [DllImport("user32.dll")]
            public static extern bool IsIconic(IntPtr window);

            [DllImport("user32.dll")]
            public static extern bool GetWindowRect(IntPtr window, out Rect rect);

            [DllImport("dwmapi.dll")]
            public static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect rect, int size);

            [StructLayout(LayoutKind.Sequential)]
            public struct Rect
            {
                public int Left;
                public int Top;
                public int Right;
                public int Bottom;
            }
        }
    }
}
