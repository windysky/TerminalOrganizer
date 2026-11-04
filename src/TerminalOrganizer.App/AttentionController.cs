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

        /// <summary>Per-overlay attention state: last quad, visible ticks, stop condition.</summary>
        private sealed class OverlayState
        {
            public int[] LastQuad;
            public int VisibleTicks;
            public StopCondition StopCondition;

            /// <summary>t18: true once the cap ran out — the ring is the steady dim ring
            /// (re-asserted per on-desktop tick, never counted); a restart clears it.</summary>
            public bool Steady;
        }

        /// <summary>
        /// SPEC-TRAY-016 (REQ-KIND-001..003): how THIS overlay's blink stops, derived at
        /// creation and every restart from the signal. The kind axis governs only the stop
        /// condition of an overlay already shown — the event-policy filter (all |
        /// notifications | mixed) stays event-based and unchanged (the policy decides IF,
        /// the kind decides HOW LONG).
        /// </summary>
        private enum StopCondition
        {
            /// <summary>The shipped conditions only (closed / foreground / minimized / moved); never counted, never capped.</summary>
            UntilFocus,

            /// <summary>The attentionStopBlinkLimit visible-tick count (the shipped fixed-count behavior).</summary>
            FixedCount,

            /// <summary>The attentionInfoVisibleSeconds visible-seconds cap (kind "info" only — AM-3's kind-scoped new behavior).</summary>
            InfoSeconds
        }

        // SPEC-TRAY-016 (D-2/D-5): the closed kind token set. Anything else non-null degrades
        // absent-equivalent with one log line per consumed signal — never a parse rejection (a
        // future producer kind must never cause the organizer to drop an attention signal).
        private const string KindAsk = "ask";
        private const string KindInfo = "info";
        private const string KindStop = "stop";

        // SPEC-TRAY-014 D-7/D-9 and the D-6 extension: the loaded options.
        private string eventPolicy;
        private int stopBlinkLimit;
        private bool topmostMode;

        // SPEC-TRAY-016 (REQ-PREF-001, D-9): the info visible-seconds cap (SECONDS, distinct
        // from the TICK-unit stopBlinkLimit — D-7's two axes). Defaults to the absent-key
        // default at construction; SetInfoVisibleSeconds clamps like SetStopBlinkLimit.
        private int infoVisibleSeconds;
        // Single-writer discipline: inFlight, pending and activeOverlays are mutated only
        // on the UI thread (the timer ticks and the marshalled completion) — the queue-work
        // thread never touches them, so no cross-thread fence is needed.
        private bool inFlight;
        private bool disposed;
        private System.Windows.Forms.Timer pollTimer;
        private System.Windows.Forms.Timer blinkTimer;
        // SPEC-TRAY-016 M1 (REQ-HB-001..003): the heartbeat timer (the AM-5 third slot,
        // torn down after poll and blink), the injected write seam (one best-effort
        // write per call returning success; production wires the AttentionHeartbeatWriter
        // over the signal directory), and the consecutive-failure dedupe flag (one log
        // line per failing run, silent until a write succeeds again — REQ-HB-002).
        private System.Windows.Forms.Timer heartbeatTimer;
        private readonly Func<bool> writeHeartbeat;
        private bool heartbeatFailureLogged;

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
        /// event policy, the stop blink limit and the always-on-top mode. The heartbeat
        /// seam is null — no heartbeat writes (the pre-SPEC-TRAY-016 behavior).</summary>
        public AttentionController(Func<AttentionPollResult> pollSignals,
            Func<AttentionCandidate[]> probeWindows, Action<WaitCallback> queueWork,
            Action<Action> marshal, Func<IntPtr> getForegroundWindow,
            Func<IntPtr, bool> isWindowAlive, Func<IntPtr, bool> isWindowMinimized,
            Func<IntPtr, int[]> getTargetRect, AttentionOverlayFactory overlays,
            Action<string> logSink, IDesktopSource desktops, bool enabled,
            string eventPolicy, int stopBlinkLimit, bool topmostMode)
            : this(pollSignals, probeWindows, queueWork, marshal, getForegroundWindow,
                isWindowAlive, isWindowMinimized, getTargetRect, overlays, logSink, desktops,
                enabled, eventPolicy, stopBlinkLimit, topmostMode, null)
        {
        }

        /// <summary>SPEC-TRAY-016 M1 full form: the options plus the heartbeat write seam
        /// (one best-effort write per call, returning success; production wires
        /// AttentionHeartbeatWriter over the signal directory, the suite records).</summary>
        public AttentionController(Func<AttentionPollResult> pollSignals,
            Func<AttentionCandidate[]> probeWindows, Action<WaitCallback> queueWork,
            Action<Action> marshal, Func<IntPtr> getForegroundWindow,
            Func<IntPtr, bool> isWindowAlive, Func<IntPtr, bool> isWindowMinimized,
            Func<IntPtr, int[]> getTargetRect, AttentionOverlayFactory overlays,
            Action<string> logSink, IDesktopSource desktops, bool enabled,
            string eventPolicy, int stopBlinkLimit, bool topmostMode,
            Func<bool> writeHeartbeat)
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
            this.infoVisibleSeconds = SettingsStore.DefaultInfoVisibleSeconds;
            this.writeHeartbeat = writeHeartbeat;
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
            string signalDirectory, bool enabled, string eventPolicy, int stopBlinkLimit, bool topmost,
            int infoVisibleSeconds)
        {
            AttentionSignalStore store = new AttentionSignalStore(signalDirectory,
                delegate { return UtcNowEpochMs(); });
            AttentionController controller = null;
            // t10 (the 2026-11-01 live-session round): one shared virtual-desktop reader
            // feeds BOTH the controller's blink-tick gate and the factory's arrival gate
            // (the create/restart twins birth an off-desktop target hidden).
            VirtualDesktopReader desktopReader = new VirtualDesktopReader();
            AttentionOverlayFactory factory = AttentionOverlayFactory.Live(
                delegate { return controller == null ? false : controller.TopmostMode; },
                desktopReader);
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
                desktopReader,
                enabled, eventPolicy, stopBlinkLimit, topmost,
                delegate { return AttentionHeartbeatWriter.Write(AttentionHeartbeatWriter.HeartbeatPath(signalDirectory)); });
            // SPEC-TRAY-016 (REQ-PREF-001): the loaded info visible-seconds cap rides the
            // same production wiring as the other attention options (clamped again).
            controller.SetInfoVisibleSeconds(infoVisibleSeconds);
            return controller;
        }

        /// <summary>Starts the three WinForms timers (poll, blink, then heartbeat — the AM-5
        /// amended set) and writes the first heartbeat immediately (REQ-HB-001: one write
        /// at start, then one per heartbeat tick); production only — the suite drives the ticks.</summary>
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
            heartbeatTimer = new System.Windows.Forms.Timer();
            heartbeatTimer.Interval = AttentionConstants.HeartbeatIntervalMs;
            heartbeatTimer.Tick += delegate { HeartbeatTick(); };
            WriteHeartbeatOnce();
            pollTimer.Start();
            blinkTimer.Start();
            heartbeatTimer.Start();
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

        /// <summary>SPEC-TRAY-016 (REQ-PREF-001): runtime change of the info visible-seconds
        /// cap (already-clamped ints expected; clamped again, the SetStopBlinkLimit pattern).</summary>
        public void SetInfoVisibleSeconds(int value)
        {
            infoVisibleSeconds = SettingsStore.ClampInfoSeconds(value);
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
            // SPEC-TRAY-016 (REQ-KIND-002, D-5): exactly one log line per consumed signal
            // carrying an unrecognized non-null kind; the behavior degrades absent-equivalent
            // either way (the additive-fields discipline — never a rejection).
            for (int i = 0; i < signals.Length; i++)
            {
                if (IsUnknownKind(signals[i]))
                {
                    Log("attention: unknown kind \"" + signals[i].Kind + "\" (treated as absent) event="
                        + signals[i].Event + " needle=\"" + signals[i].Needle + "\"");
                }
            }
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
        /// stop (REQ-CTL-002) — t18 turns that cap into the steady dim ring instead of a
        /// removal (SteadyOverlay): a blink-limited overlay caps on its Nth VISIBLE tick —
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
            List<KeyValuePair<long, string>> capped = null;
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
                if (pair.Value.Steady)
                {
                    // t18: past the cap the ring stays lit, steady and dim — re-asserted
                    // (it may be returning from a desktop-hide), never toggled or counted.
                    overlays.Steady(handle, rect);
                    continue;
                }
                overlays.Tick(handle, rect);
                if (pair.Value.StopCondition == StopCondition.FixedCount)
                {
                    CountVisibleTick(ref capped, pair.Key, pair.Value, stopBlinkLimit, "blinklimit");
                }
                else if (pair.Value.StopCondition == StopCondition.InfoSeconds)
                {
                    CountVisibleTick(ref capped, pair.Key, pair.Value, InfoTickCap(infoVisibleSeconds), "infocap");
                }
            }
            if (stops != null)
            {
                for (int i = 0; i < stops.Count; i++)
                {
                    StopOverlay(stops[i].Key, stops[i].Value);
                }
            }
            if (capped != null)
            {
                for (int i = 0; i < capped.Count; i++)
                {
                    SteadyOverlay(capped[i].Key, capped[i].Value);
                }
            }
        }

        /// <summary>
        /// One heartbeat tick (REQ-HB-001): one best-effort write. Failures degrade per
        /// REQ-HB-002 — nothing throws, no other attention work is touched, exactly one
        /// log line covers a consecutive failure run, and the retry on the next tick is
        /// unconditional.
        /// </summary>
        public void HeartbeatTick()
        {
            if (disposed)
            {
                return;
            }
            WriteHeartbeatOnce();
        }

        /// <summary>
        /// One best-effort heartbeat write (the Start write and every heartbeat tick):
        /// a null seam writes nothing (the pre-SPEC-TRAY-016 constructors); a failure —
        /// returned or thrown — logs one line for the FIRST failure of a consecutive run
        /// and stays silent until a write succeeds again (the deduped line REQ-HB-002 pins).
        /// </summary>
        private void WriteHeartbeatOnce()
        {
            if (writeHeartbeat == null)
            {
                return;
            }
            bool success;
            try
            {
                success = writeHeartbeat();
            }
            catch (Exception)
            {
                // The writer contract is best-effort (REQ-HB-002); a throwing seam is a failure.
                success = false;
            }
            if (success)
            {
                heartbeatFailureLogged = false;
                return;
            }
            if (!heartbeatFailureLogged)
            {
                heartbeatFailureLogged = true;
                Log("attention: heartbeat write failed (will retry next tick)");
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
        /// The pinned teardown order (REQ-CTL-001, AM-5): stop the poll timer first, then
        /// the blink timer, then the heartbeat timer, then ignore any still-in-flight
        /// marshalled completion (the disposed flag), and dispose the overlays and their
        /// forms last. organizer.json is NEVER deleted — staleness is the organizer-dead
        /// signal the producer's fallback rides on (REQ-HB-003).
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
            if (heartbeatTimer != null)
            {
                heartbeatTimer.Stop();
                heartbeatTimer.Dispose();
                heartbeatTimer = null;
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
        /// REQ-CTL-001 (SPEC-TRAY-017): the ONE shared stop-counting path for both capped
        /// stop conditions — increment the visible-tick count, compare against the
        /// caller's cap expression, and collect the stop with the caller's reason. The
        /// cap expressions (stopBlinkLimit ticks; InfoTickCap(infoVisibleSeconds) =
        /// ceil(seconds x 1000 / BlinkIntervalMs)) and the stop reasons ("blinklimit" /
        /// "infocap") stay verbatim at the BlinkTick call sites (plan section J); a
        /// no-cap condition (UntilFocus — the ask kind) never reaches this path.
        /// </summary>
        // @MX:NOTE: [AUTO] the unified blink-cycle counting site (A-4, extended SPEC-TRAY-016, unified SPEC-TRAY-017 REQ-CTL-001): one blink = ONE VISIBLE tick — hidden off-desktop ticks pause (the desktop gate skipped them), a failed desktop check keeps the ring visible and counts (fix-B), and a restart resets the count (ShowOverlays re-derives and zeroes it).
        private static void CountVisibleTick(ref List<KeyValuePair<long, string>> stops, long handle,
            OverlayState state, int cap, string reason)
        {
            state.VisibleTicks++;
            if (state.VisibleTicks >= cap)
            {
                CollectStop(ref stops, handle, reason);
            }
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
                AttentionMatchDetail[][] details = new AttentionMatchDetail[signals.Length][];
                for (int i = 0; i < signals.Length; i++)
                {
                    // SPEC-TRAY-019 (REQ-STM-005): the detailed verdicts feed the per-window
                    // log lines; the matcher stays pure, so the worker thread is safe here.
                    details[i] = AttentionMatcher.MatchDetailed(signals[i].Needle, candidates);
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
                        long[] matches = HandlesOf(details[i]);
                        LogSignal(signals[i], details[i]);
                        ShowOverlays(signals[i], matches);
                    }
                    if (pending.Count > 0)
                    {
                        StartRun();
                    }
                });
            });
        }

        /// <summary>The matched handles of one detail run — deduplicated by handle, input order (the Match projection).</summary>
        private static long[] HandlesOf(AttentionMatchDetail[] details)
        {
            List<long> handles = new List<long>();
            for (int i = 0; i < details.Length; i++)
            {
                if (details[i].Matched && !handles.Contains(details[i].Handle))
                {
                    handles.Add(details[i].Handle);
                }
            }
            return handles.ToArray();
        }

        private void LogSignal(AttentionSignal signal, AttentionMatchDetail[] details)
        {
            long[] matches = HandlesOf(details);
            if (matches.Length > 0)
            {
                Log("attention: event=" + signal.Event + " needle=\"" + signal.Needle
                    + "\" matched=" + matches.Length.ToString(CultureInfo.InvariantCulture));
                // SPEC-TRAY-019 (REQ-STM-005/006): additive per-window detail lines (plan.md A-3);
                // the primary line above stays byte-identical. Lines exist only for this signal's
                // matched windows and actually-suppressed over-matches — never per poll tick.
                for (int i = 0; i < details.Length; i++)
                {
                    if (details[i].Matched)
                    {
                        Log("attention: match hwnd=" + details[i].Handle.ToString(CultureInfo.InvariantCulture)
                            + " session-tab=\"" + details[i].MatchedSessionTitle + "\"");
                    }
                    else if (details[i].SuppressedTitle != null)
                    {
                        Log("attention: over-match suppressed hwnd=" + details[i].Handle.ToString(CultureInfo.InvariantCulture)
                            + " non-session-title=\"" + details[i].SuppressedTitle + "\"");
                    }
                }
                return;
            }
            // Zero-match (REQ-CTL-003): the producer's taskbar flash stays the fallback cue (D-1).
            Log("attention: event=" + signal.Event + " needle=\"" + signal.Needle
                + "\" matched=0 (no window; taskbar flash remains)");
            // SPEC-TRAY-019 (REQ-STM-005): one line per session-bearing window, naming its
            // stripped session titles — the zero-match dump (plan.md A-3).
            for (int i = 0; i < details.Length; i++)
            {
                if (details[i].SessionTitles.Length > 0)
                {
                    Log("attention: no-match hwnd=" + details[i].Handle.ToString(CultureInfo.InvariantCulture)
                        + " session-tabs=\"" + string.Join("|", details[i].SessionTitles) + "\"");
                }
            }
        }

        /// <summary>REQ-CTL-004: one overlay per handle; an active handle restarts its blink
        /// window (D-3). D-10: creation seeds the last-seen quad and every restart re-seeds
        /// it, so the moved-stop compares against the quad the ring was last placed on.
        /// SPEC-TRAY-014 (A-5): a restart also RESETS the visible-tick count and ADOPTS the
        /// new signal's event kind; a creation seeds both from its own signal. SPEC-TRAY-016
        /// (REQ-KIND-003): the restart also ADOPTS the new signal's KIND — the stop condition
        /// is re-derived from the new signal on every restart, in both directions.</summary>
        private void ShowOverlays(AttentionSignal signal, long[] matches)
        {
            // SPEC-TRAY-016 (REQ-MSG-001) + t13, widened by SPEC-TRAY-017 (REQ-OVL-002,
            // D-5): ONE atomic publish carries the consumed signal's message AND kind —
            // the production factory reads both at Create/Restart (ring-only when the
            // message is absent, null, or whitespace, REQ-MSG-002; the kind styles the
            // text — ask red / info amber / default near-white, AttentionMessageStyle;
            // the suite factories' no-op default ignores it).
            overlays.SetPanelMessage(signal == null ? null : signal.Message, signal == null ? null : signal.Kind);
            StopCondition stopCondition = ResolveStopCondition(signal);
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
                state.StopCondition = stopCondition;
                state.Steady = false;
            }
        }

        /// <summary>
        /// SPEC-TRAY-016 kind resolution (REQ-KIND-001..003): the stop condition of an
        /// overlay already shown, derived at creation and every restart. Truth table
        /// (plan.md A-2 Fork 4): kind "ask" -> until focus (never counted, never capped);
        /// kind "info" -> the visible-seconds cap (InfoSeconds); kind "stop" -> the fixed
        /// visible-tick count; absent -> the shipped event x policy derivation below
        /// (IsBlinkLimited — the kind axis is INERT while null, NEVER derived from the
        /// event); unknown non-null -> absent-equivalent (PollTick already logged the line).
        /// The one intended delta: kind "stop" under policy "all" is fixed-count — the
        /// explicit kind replaces the mixed-only approximation.
        /// </summary>
        // @MX:NOTE: [AUTO] the stop-condition truth table (plan.md A-2 Fork 4, REQ-KIND-001..003); fan-in site (create + restart paths).
        private StopCondition ResolveStopCondition(AttentionSignal signal)
        {
            string kind = signal == null ? null : signal.Kind;
            if (kind != null)
            {
                if (string.Equals(kind, KindAsk, StringComparison.Ordinal))
                {
                    return StopCondition.UntilFocus;
                }
                if (string.Equals(kind, KindInfo, StringComparison.Ordinal))
                {
                    return StopCondition.InfoSeconds;
                }
                if (string.Equals(kind, KindStop, StringComparison.Ordinal))
                {
                    return StopCondition.FixedCount;
                }
            }
            if (IsBlinkLimited(signal))
            {
                return StopCondition.FixedCount;
            }
            return StopCondition.UntilFocus;
        }

        /// <summary>SPEC-TRAY-016 (REQ-KIND-003, D-7): the seconds-to-visible-ticks conversion,
        /// integer ceil form — 10 s at the 500 ms blink cadence is 20 visible ticks (the same
        /// numeral 10 as the TICK-unit stop limit is coincidence; the axes are distinct).</summary>
        private static int InfoTickCap(int seconds)
        {
            return (seconds * 1000 + AttentionConstants.BlinkIntervalMs - 1) / AttentionConstants.BlinkIntervalMs;
        }

        /// <summary>D-7 (REQ-CTL-002), unchanged: only a stop-kind EVENT under the mixed policy
        /// is blink-limited — this is the ABSENT-kind derivation the kind axis falls back to.</summary>
        private bool IsBlinkLimited(AttentionSignal signal)
        {
            return string.Equals(eventPolicy, AttentionPolicyResolver.PolicyMixed, StringComparison.Ordinal)
                && signal != null
                && string.Equals(signal.Event, "stop", StringComparison.Ordinal);
        }

        /// <summary>SPEC-TRAY-016 (D-5): a non-null kind outside the closed token set.</summary>
        private static bool IsUnknownKind(AttentionSignal signal)
        {
            string kind = signal == null ? null : signal.Kind;
            if (kind == null)
            {
                return false;
            }
            return !string.Equals(kind, KindAsk, StringComparison.Ordinal)
                && !string.Equals(kind, KindInfo, StringComparison.Ordinal)
                && !string.Equals(kind, KindStop, StringComparison.Ordinal);
        }

        /// <summary>
        /// t18 (the 2026-11-04 UX round): the cap (stop blink limit / info cap) no longer
        /// removes the overlay — it turns the ring into the steady dim ring and keeps the
        /// card; the user-attention stops (closed / foreground / minimized / moved) still
        /// end it, and a new signal restarts the blink (ShowOverlays clears the flag).
        /// One log line per transition, carrying the cap reason.
        /// </summary>
        private void SteadyOverlay(long handle, string reason)
        {
            OverlayState state;
            if (!trackedOverlays.TryGetValue(handle, out state))
            {
                return;
            }
            state.Steady = true;
            overlays.Steady(new IntPtr(handle), state.LastQuad);
            Log("attention: overlay steady hwnd=" + handle.ToString(CultureInfo.InvariantCulture)
                + " reason=" + reason);
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
