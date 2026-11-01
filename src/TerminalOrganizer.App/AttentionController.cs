using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Windows.Forms;
using TerminalOrganizer.Core.Attention;
using TerminalOrganizer.Core.Monitors;

namespace TerminalOrganizer.App
{
    /// <summary>
    /// The attention controller (REQ-CTL-001..004): polls the WSL producer's signal
    /// directory on a Windows Forms timer (~500 ms, UI thread — no watcher: the
    /// producer's writes cross the drvfs/9p boundary and polling self-heals), consumes
    /// every signal (read + delete) whether enabled or not, runs single-flight match
    /// runs off the UI thread (window enumeration + UIA tab reads), marshals every
    /// overlay creation/mutation/destruction back to the UI thread, blinks every active
    /// overlay from one shared timer, and stops an overlay when its target gains
    /// foreground focus, closes, is minimized — or, per D-10, MOVES OR RESIZES (any edge
    /// of the target quad changed since the seeded/last-seen quad; the follow semantics
    /// is superseded: the ring stops instead of following) — with NO time cap (D-4). Every
    /// dependency arrives as an injected seam; the WinForms timers call the same public
    /// tick methods the suite drives, so the logic is testable headlessly. Real-screen
    /// behaviour (live timers, live probe, real overlays) is the morning checklist
    /// (AC-014), not an acceptance claim.
    /// </summary>
    // @MX:WARN: [AUTO] live timers + real overlay map — morning checklist; not an acceptance claim.
    public sealed class AttentionController : IDisposable
    {
        private readonly Func<AttentionPollResult> pollSignals;
        private readonly Func<AttentionCandidate[]> probeWindows;
        private readonly Action<WaitCallback> queueWork;
        private readonly Action<Action> marshal;
        private readonly Func<IntPtr> getForegroundWindow;
        private readonly Func<IntPtr, bool> isWindowAlive;
        private readonly Func<IntPtr, bool> isWindowMinimized;
        private readonly Func<IntPtr, int[]> getTargetRect;
        private readonly AttentionOverlayFactory overlays;
        private readonly Action<string> logSink;

        /// <summary>
        /// Post-audit fix B: the virtual-desktop source asked per blink tick for the TARGET
        /// window — on the current desktop the ring is visible, on another desktop it is
        /// HIDDEN while the overlay stays alive (until-focus semantics unchanged). Null
        /// keeps today's desktop-unaware behavior (always visible).
        /// </summary>
        private readonly IDesktopSource desktops;
        private readonly HashSet<long> desktopFailureLogged = new HashSet<long>();

        /// <summary>D-10 + SPEC-TRAY-014: the active overlays, each carrying its last-seen
        /// target quad, its visible-tick count and its event kind (blink-limited or not) —
        /// the quad is seeded at creation and re-seeded at every restart, any edge change
        /// between ticks stops the overlay (moving/resizing the target IS attention), and a
        /// blink-limited overlay stops on its Nth VISIBLE tick (one blink = one visible
        /// tick; plan review Q1 binding).</summary>
        private readonly Dictionary<long, OverlayState> trackedOverlays = new Dictionary<long, OverlayState>();
        private readonly List<AttentionSignal> pending = new List<AttentionSignal>();
        private bool enabled;

        /// <summary>Per-overlay attention state: last quad, visible ticks, blink-limited flag.</summary>
        private sealed class OverlayState
        {
            public int[] LastQuad;
            public int VisibleTicks;
            public bool BlinkLimited;
        }

        // SPEC-TRAY-014 D-7/D-9 and the D-6 extension: the loaded options.
        private string eventPolicy;
        private int stopBlinkLimit;
        private bool topmostMode;
        // Single-writer discipline: inFlight, pending and activeOverlays are mutated only
        // on the UI thread (the timer ticks and the marshalled completion) — the queue-work
        // thread never touches them, so no cross-thread fence is needed.
        private bool inFlight;
        private bool disposed;
        private System.Windows.Forms.Timer pollTimer;
        private System.Windows.Forms.Timer blinkTimer;

        /// <summary>
        /// The bare SPEC-TRAY-013 configuration: policy "all" — unlimited blinking for both
        /// event kinds, the exact pre-D-7 behavior (A-3), so every existing unlimited row
        /// holds unedited.
        /// </summary>
        public AttentionController(Func<AttentionPollResult> pollSignals,
            Func<AttentionCandidate[]> probeWindows, Action<WaitCallback> queueWork,
            Action<Action> marshal, Func<IntPtr> getForegroundWindow,
            Func<IntPtr, bool> isWindowAlive, Func<IntPtr, bool> isWindowMinimized,
            Func<IntPtr, int[]> getTargetRect, AttentionOverlayFactory overlays,
            Action<string> logSink, IDesktopSource desktops, bool enabled)
            : this(pollSignals, probeWindows, queueWork, marshal, getForegroundWindow,
                isWindowAlive, isWindowMinimized, getTargetRect, overlays, logSink, desktops,
                enabled, AttentionPolicyResolver.PolicyAll, SettingsStore.DefaultStopBlinkLimit, false)
        {
        }

        /// <summary>SPEC-TRAY-014 options form (D-7/D-9, the D-6 extension): carries the
        /// event policy, the stop blink limit and the always-on-top mode.</summary>
        public AttentionController(Func<AttentionPollResult> pollSignals,
            Func<AttentionCandidate[]> probeWindows, Action<WaitCallback> queueWork,
            Action<Action> marshal, Func<IntPtr> getForegroundWindow,
            Func<IntPtr, bool> isWindowAlive, Func<IntPtr, bool> isWindowMinimized,
            Func<IntPtr, int[]> getTargetRect, AttentionOverlayFactory overlays,
            Action<string> logSink, IDesktopSource desktops, bool enabled,
            string eventPolicy, int stopBlinkLimit, bool topmostMode)
        {
            if (pollSignals == null) throw new ArgumentNullException("pollSignals");
            if (probeWindows == null) throw new ArgumentNullException("probeWindows");
            if (queueWork == null) throw new ArgumentNullException("queueWork");
            if (marshal == null) throw new ArgumentNullException("marshal");
            if (getForegroundWindow == null) throw new ArgumentNullException("getForegroundWindow");
            if (isWindowAlive == null) throw new ArgumentNullException("isWindowAlive");
            if (isWindowMinimized == null) throw new ArgumentNullException("isWindowMinimized");
            if (getTargetRect == null) throw new ArgumentNullException("getTargetRect");
            if (overlays == null) throw new ArgumentNullException("overlays");
            if (logSink == null) throw new ArgumentNullException("logSink");
            this.pollSignals = pollSignals;
            this.probeWindows = probeWindows;
            this.queueWork = queueWork;
            this.marshal = marshal;
            this.getForegroundWindow = getForegroundWindow;
            this.isWindowAlive = isWindowAlive;
            this.isWindowMinimized = isWindowMinimized;
            this.getTargetRect = getTargetRect;
            this.overlays = overlays;
            this.logSink = logSink;
            this.desktops = desktops;
            this.enabled = enabled;
            this.eventPolicy = AttentionPolicyResolver.Parse(eventPolicy);
            this.stopBlinkLimit = SettingsStore.ClampBlinkLimit(stopBlinkLimit);
            this.topmostMode = topmostMode;
        }

        /// <summary>
        /// Production wiring (plan.md A-7): the thread-pool queue-work and the message-window
        /// marshal seam; the poll seam is the real store over the signal directory. The
        /// SPEC-TRAY-014 options form passes the loaded settings, and the live factory's
        /// topmost supplier closes over the controller so NEW creations pick up SetTopmost
        /// while live overlays keep their mode. Called by TrayShell after the log and message
        /// window exist (morning-checklist surface).
        /// </summary>
        internal static AttentionController CreateProduction(LogSink log, Control marshallingControl,
            string signalDirectory, bool enabled, string eventPolicy, int stopBlinkLimit, bool topmost)
        {
            AttentionSignalStore store = new AttentionSignalStore(signalDirectory,
                delegate { return UtcNowEpochMs(); });
            AttentionController controller = null;
            AttentionOverlayFactory factory = AttentionOverlayFactory.Live(
                delegate { return controller == null ? false : controller.TopmostMode; });
            controller = new AttentionController(
                store.Poll,
                new AttentionWindowProbe().Candidates,
                delegate(WaitCallback work) { ThreadPool.QueueUserWorkItem(work); },
                delegate(Action action) { marshallingControl.BeginInvoke(action); },
                AttentionWindowProbe.GetForeground,
                AttentionWindowProbe.IsAlive,
                AttentionWindowProbe.IsMinimized,
                AttentionWindowProbe.TargetRect,
                factory,
                delegate(string line) { log.Append(line); },
                new VirtualDesktopReader(),
                enabled, eventPolicy, stopBlinkLimit, topmost);
            return controller;
        }

        /// <summary>Starts the two WinForms timers (poll then blink); production only — the suite drives the ticks.</summary>
        public void Start()
        {
            if (disposed)
            {
                return;
            }
            pollTimer = new System.Windows.Forms.Timer();
            pollTimer.Interval = AttentionConstants.PollIntervalMs;
            pollTimer.Tick += delegate { PollTick(); };
            blinkTimer = new System.Windows.Forms.Timer();
            blinkTimer.Interval = AttentionConstants.BlinkIntervalMs;
            blinkTimer.Tick += delegate { BlinkTick(); };
            pollTimer.Start();
            blinkTimer.Start();
        }

        /// <summary>
        /// The enable toggle (REQ-CTL-001): while false the controller still consumes every
        /// signal, creates no overlay and stops every active overlay with the disabled reason;
        /// one suppressed line is logged per consumed signal.
        /// </summary>
        public void SetEnabled(bool value)
        {
            enabled = value;
            if (!value)
            {
                StopAllOverlays("disabled");
            }
        }

        /// <summary>SPEC-TRAY-014 D-7 runtime change: the event policy (applies to signals consumed from here on).</summary>
        public void SetEventPolicy(string value)
        {
            eventPolicy = AttentionPolicyResolver.Parse(value);
        }

        /// <summary>SPEC-TRAY-014 D-9 runtime change: the stop blink limit (already-clamped ints expected; clamped again).</summary>
        public void SetStopBlinkLimit(int value)
        {
            stopBlinkLimit = SettingsStore.ClampBlinkLimit(value);
        }

        /// <summary>
        /// SPEC-TRAY-014 (the D-6 extension) runtime change: the always-on-top mode. Stored
        /// only — apply-at-creation (new overlays pick it up through the factory's mode
        /// supplier; live overlays keep their mode until they stop, spec 2.2), so this never
        /// issues a positioning call.
        /// </summary>
        public void SetTopmost(bool value)
        {
            topmostMode = value;
        }

        /// <summary>The current always-on-top mode (the supplier the live factory reads per creation).</summary>
        public bool TopmostMode
        {
            get { return topmostMode; }
        }

        /// <summary>One poll tick: consume the directory, log rejected/stale lines, queue a match run.</summary>
        public void PollTick()
        {
            if (disposed)
            {
                return;
            }
            AttentionPollResult result;
            try
            {
                result = pollSignals();
            }
            catch (Exception ex)
            {
                Log("attention: poll failed: " + ex.Message);
                return;
            }
            AttentionRejectedFile[] rejected = result.Rejected;
            for (int i = 0; i < rejected.Length; i++)
            {
                Log("attention: rejected " + rejected[i].FileName + ": " + rejected[i].Reason);
            }
            AttentionStaleFile[] stale = result.Stale;
            for (int i = 0; i < stale.Length; i++)
            {
                Log("attention: stale " + stale[i].FileName + " ("
                    + stale[i].AgeMs.ToString(CultureInfo.InvariantCulture) + " ms old; deleted)");
            }
            AttentionIoErrorFile[] errors = result.IoErrors;
            for (int i = 0; i < errors.Length; i++)
            {
                Log("attention: io error " + errors[i].FileName + ": " + errors[i].Message);
            }
            AttentionSignal[] signals = result.Accepted;
            if (!enabled)
            {
                for (int i = 0; i < signals.Length; i++)
                {
                    Log("attention: suppressed (disabled) event=" + signals[i].Event
                        + " needle=\"" + signals[i].Needle + "\"");
                }
                return;
            }
            for (int i = 0; i < signals.Length; i++)
            {
                // SPEC-TRAY-014 D-7 (REQ-CTL-001, A-8): under "notifications" a stop event is
                // consumed and logged but never becomes pending — a pure stop batch skips the
                // match run entirely. The disabled suppression above always wins.
                if (string.Equals(eventPolicy, AttentionPolicyResolver.PolicyNotifications, StringComparison.Ordinal)
                    && string.Equals(signals[i].Event, "stop", StringComparison.Ordinal))
                {
                    Log("attention: suppressed (policy notifications) event=stop needle=\""
                        + signals[i].Needle + "\"");
                    continue;
                }
                pending.Add(signals[i]);
            }
            if (!inFlight && pending.Count > 0)
            {
                StartRun();
            }
        }

        /// <summary>
        /// One shared blink tick (REQ-CTL-004): every active overlay re-reads its target
        /// rectangle; a target that died, gained foreground focus, was minimized — or,
        /// per D-10, MOVED OR RESIZED (any edge of the quad changed since the last
        /// seen/seeded quad) — stops with its reason. SPEC-TRAY-014 adds the blink-limit
        /// stop (REQ-CTL-002): a blink-limited overlay stops on its Nth VISIBLE tick —
        /// one blink is one visible tick (plan review Q1, binding) — with the Nth tick
        /// recording its Tick BEFORE the stop (tick-then-stop, the shipped order); hidden
        /// off-desktop ticks do not count, and a failed desktop check keeps the ring
        /// visible and counts. Otherwise there is no other stop: an untouched unlimited
        /// target keeps its overlay blinking indefinitely (D-4). D-10 supersedes the follow
        /// semantics: "follows the target" is bounded to the ticks before the first change.
        /// </summary>
        public void BlinkTick()
        {
            if (disposed)
            {
                return;
            }
            List<KeyValuePair<long, string>> stops = null;
            foreach (KeyValuePair<long, OverlayState> pair in trackedOverlays)
            {
                IntPtr handle = new IntPtr(pair.Key);
                if (!isWindowAlive(handle))
                {
                    CollectStop(ref stops, pair.Key, "closed");
                    continue;
                }
                if (getForegroundWindow() == handle)
                {
                    CollectStop(ref stops, pair.Key, "foreground");
                    continue;
                }
                if (isWindowMinimized(handle))
                {
                    CollectStop(ref stops, pair.Key, "minimized");
                    continue;
                }
                int[] rect = getTargetRect(handle);
                if (RectChanged(pair.Value.LastQuad, rect))
                {
                    // D-10: moving or resizing the target is attention too.
                    CollectStop(ref stops, pair.Key, "moved");
                    continue;
                }
                // Post-audit fix B: the stop conditions come FIRST (a target that dies,
                // gains focus, minimizes or moves on another desktop still stops cleanly);
                // then the desktop gate decides visibility, never lifetime. A HIDDEN tick
                // never counts toward the blink limit (A-5).
                if (!IsOnCurrentDesktop(handle))
                {
                    overlays.Hide(handle);
                    continue;
                }
                overlays.Tick(handle, rect);
                if (pair.Value.BlinkLimited)
                {
                    // @MX:NOTE: the blink-cycle counting site (A-4): one blink = ONE VISIBLE tick.
                    pair.Value.VisibleTicks++;
                    if (pair.Value.VisibleTicks >= stopBlinkLimit)
                    {
                        CollectStop(ref stops, pair.Key, "blinklimit");
                    }
                }
            }
            if (stops != null)
            {
                for (int i = 0; i < stops.Count; i++)
                {
                    StopOverlay(stops[i].Key, stops[i].Value);
                }
            }
        }

        /// <summary>D-10: any edge of the (L, T, R, B) quad changed between sightings (null/short quads never count as a change).</summary>
        private static bool RectChanged(int[] last, int[] current)
        {
            if (last == null || current == null || last.Length < 4 || current.Length < 4)
            {
                return false;
            }
            for (int i = 0; i < 4; i++)
            {
                if (last[i] != current[i])
                {
                    return true;
                }
            }
            return false;
        }

        /// <summary>
        /// The pinned teardown order (REQ-CTL-001): stop the poll timer first, then the
        /// blink timer, then ignore any still-in-flight marshalled completion (the disposed
        /// flag), and dispose the overlays and their forms last.
        /// </summary>
        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            if (pollTimer != null)
            {
                pollTimer.Stop();
                pollTimer.Dispose();
                pollTimer = null;
            }
            if (blinkTimer != null)
            {
                blinkTimer.Stop();
                blinkTimer.Dispose();
                blinkTimer = null;
            }
            disposed = true;
            List<long> handles = new List<long>(trackedOverlays.Keys);
            for (int i = 0; i < handles.Count; i++)
            {
                trackedOverlays.Remove(handles[i]);
                overlays.Stop(new IntPtr(handles[i]));
            }
        }

        private static void CollectStop(ref List<KeyValuePair<long, string>> stops, long handle, string reason)
        {
            if (stops == null)
            {
                stops = new List<KeyValuePair<long, string>>();
            }
            stops.Add(new KeyValuePair<long, string>(handle, reason));
        }

        /// <summary>
        /// The desktop gate (post-audit fix B): true when the target is on the current
        /// virtual desktop (ring visible). False only for a SUCCESSFUL off-desktop answer —
        /// a failed or indeterminate query keeps the ring visible (today's behavior) with
        /// one log line per handle (the blink ticks every 500 ms; per-tick logging would
        /// spam the log).
        /// </summary>
        private bool IsOnCurrentDesktop(IntPtr handle)
        {
            if (desktops == null)
            {
                return true;
            }
            DesktopFlagResult flag = null;
            try
            {
                flag = desktops.IsWindowOnCurrentVirtualDesktop(handle);
            }
            catch (Exception ex)
            {
                LogDesktopFailure(handle, ex.Message);
                return true;
            }
            if (flag == null || !flag.Success)
            {
                LogDesktopFailure(handle, flag == null ? "null result" : flag.Error);
                return true;
            }
            return flag.Value;
        }

        private void LogDesktopFailure(IntPtr handle, string reason)
        {
            long key = handle.ToInt64();
            if (desktopFailureLogged.Contains(key))
            {
                return;
            }
            desktopFailureLogged.Add(key);
            Log("attention: desktop check failed hwnd=" + key.ToString(CultureInfo.InvariantCulture)
                + " (" + reason + "); overlay kept visible");
        }

        /// <summary>
        /// The production clock: Unix epoch MILLISECONDS (the signal-file filename unit). The
        /// naive ticks-per-millisecond division returns ms-since-YEAR-1 (about 1970 years
        /// larger) and marked every signal stale — the live-smoke regression this method fixes.
        /// </summary>
        public static long UtcNowEpochMs()
        {
            return (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).Ticks
                / TimeSpan.TicksPerMillisecond;
        }

        /// <summary>REQ-CTL-002: one run at a time; signals consumed meanwhile accumulate and ride the next run.</summary>
        private void StartRun()
        {
            inFlight = true;
            AttentionSignal[] signals = pending.ToArray();
            pending.Clear();
            queueWork(delegate(object state)
            {
                AttentionCandidate[] candidates;
                try
                {
                    candidates = probeWindows();
                }
                catch (Exception ex)
                {
                    marshal(delegate
                    {
                        if (disposed)
                        {
                            return;
                        }
                        inFlight = false;
                        Log("attention: match run failed: " + ex.Message);
                        if (pending.Count > 0)
                        {
                            StartRun();
                        }
                    });
                    return;
                }
                long[][] matches = new long[signals.Length][];
                for (int i = 0; i < signals.Length; i++)
                {
                    matches[i] = AttentionMatcher.Match(signals[i].Needle, candidates);
                }
                marshal(delegate
                {
                    if (disposed)
                    {
                        return;
                    }
                    inFlight = false;
                    for (int i = 0; i < signals.Length; i++)
                    {
                        LogSignal(signals[i], matches[i]);
                        ShowOverlays(signals[i], matches[i]);
                    }
                    if (pending.Count > 0)
                    {
                        StartRun();
                    }
                });
            });
        }

        private void LogSignal(AttentionSignal signal, long[] matches)
        {
            if (matches.Length > 0)
            {
                Log("attention: event=" + signal.Event + " needle=\"" + signal.Needle
                    + "\" matched=" + matches.Length.ToString(CultureInfo.InvariantCulture));
                return;
            }
            // Zero-match (REQ-CTL-003): the producer's taskbar flash stays the fallback cue (D-1).
            Log("attention: event=" + signal.Event + " needle=\"" + signal.Needle
                + "\" matched=0 (no window; taskbar flash remains)");
        }

        /// <summary>REQ-CTL-004: one overlay per handle; an active handle restarts its blink
        /// window (D-3). D-10: creation seeds the last-seen quad and every restart re-seeds
        /// it, so the moved-stop compares against the quad the ring was last placed on.
        /// SPEC-TRAY-014 (A-5): a restart also RESETS the visible-tick count and ADOPTS the
        /// new signal's event kind; a creation seeds both from its own signal.</summary>
        private void ShowOverlays(AttentionSignal signal, long[] matches)
        {
            bool blinkLimited = IsBlinkLimited(signal);
            for (int i = 0; i < matches.Length; i++)
            {
                long handle = matches[i];
                IntPtr pointer = new IntPtr(handle);
                int[] rect = getTargetRect(pointer);
                OverlayState state;
                if (trackedOverlays.TryGetValue(handle, out state))
                {
                    overlays.Restart(pointer, rect);
                    Log("attention: overlay restarted hwnd=" + handle.ToString(CultureInfo.InvariantCulture));
                }
                else
                {
                    overlays.Create(pointer, rect);
                    state = new OverlayState();
                    trackedOverlays[handle] = state;
                }
                state.LastQuad = rect;
                state.VisibleTicks = 0;
                state.BlinkLimited = blinkLimited;
            }
        }

        /// <summary>D-7 (REQ-CTL-002): only a stop-kind overlay under the mixed policy is blink-limited.</summary>
        private bool IsBlinkLimited(AttentionSignal signal)
        {
            return string.Equals(eventPolicy, AttentionPolicyResolver.PolicyMixed, StringComparison.Ordinal)
                && signal != null
                && string.Equals(signal.Event, "stop", StringComparison.Ordinal);
        }

        private void StopOverlay(long handle, string reason)
        {
            trackedOverlays.Remove(handle);
            overlays.Stop(new IntPtr(handle));
            Log("attention: overlay stopped hwnd=" + handle.ToString(CultureInfo.InvariantCulture)
                + " reason=" + reason);
        }

        private void StopAllOverlays(string reason)
        {
            List<long> handles = new List<long>(trackedOverlays.Keys);
            for (int i = 0; i < handles.Count; i++)
            {
                StopOverlay(handles[i], reason);
            }
        }

        private void Log(string line)
        {
            try
            {
                logSink(line);
            }
            catch (Exception)
            {
                // A logging failure never breaks a tick (the LogSink contract).
            }
        }
    }
}
