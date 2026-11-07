using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using TerminalOrganizer.Core.Assignment;
using TerminalOrganizer.Core.Layouts;
using TerminalOrganizer.Core.Monitors;
using TerminalOrganizer.Core.Overflow;
using TerminalOrganizer.Core.Rules;
using TerminalOrganizer.Core.Windows;

namespace TerminalOrganizer.App
{
    /// <summary>Injectable seam over the user32 RegisterHotKey call (id + flags + vk).</summary>
    public delegate bool RegisterHotKeyCall(int id, int modifierFlags, int virtualKeyCode);

    /// <summary>Injectable seam over the user32 UnregisterHotKey call (id).</summary>
    public delegate bool UnregisterHotKeyCall(int id);

    /// <summary>
    /// The WinForms-free tray lifecycle (REQ-SHELL-002/003 — the AC-002/AC-003 headless
    /// surface): hotkey registration with the HotkeyConflict notice on failure, WM_HOTKEY
    /// dispatch to "organize monitor under cursor" (the injected delegate owns the cursor
    /// resolution, D-4), and the clean-exit sequence — unregister the hotkey, dispose the
    /// icon, flush the log — in that order. No WinForms type appears in this class; the
    /// NotifyIcon/menu glue lives in TrayShell (morning-checklist surface).
    /// </summary>
    public sealed class TrayLifecycle
    {
        /// <summary>The hotkey id used for RegisterHotKey; the WM_HOTKEY wParam.</summary>
        public const int HotkeyId = 1;

        private readonly RegisterHotKeyCall register;
        private readonly UnregisterHotKeyCall unregister;
        private readonly string hotkeyDisplay;
        private readonly NoticeSink notify;
        private readonly Action organizeUnderCursor;
        private readonly Action disposeIcon;
        private readonly Action flushLog;

        /// <param name="hotkeyDisplay">The configured hotkey string ("Ctrl+Alt+O"); carried into the conflict notice.</param>
        public TrayLifecycle(RegisterHotKeyCall register, UnregisterHotKeyCall unregister,
            string hotkeyDisplay, NoticeSink notify, Action organizeUnderCursor,
            Action disposeIcon, Action flushLog)
        {
            if (register == null) throw new ArgumentNullException("register");
            if (unregister == null) throw new ArgumentNullException("unregister");
            if (notify == null) throw new ArgumentNullException("notify");
            if (organizeUnderCursor == null) throw new ArgumentNullException("organizeUnderCursor");
            if (disposeIcon == null) throw new ArgumentNullException("disposeIcon");
            if (flushLog == null) throw new ArgumentNullException("flushLog");
            this.register = register;
            this.unregister = unregister;
            this.hotkeyDisplay = hotkeyDisplay;
            this.notify = notify;
            this.organizeUnderCursor = organizeUnderCursor;
            this.disposeIcon = disposeIcon;
            this.flushLog = flushLog;
        }

        /// <summary>REQ-SHELL-002: registers the hotkey; false + the HotkeyConflict notice on a conflict (the menu path keeps working).</summary>
        public bool RegisterHotKey(int modifierFlags, int virtualKeyCode)
        {
            bool ok = register(HotkeyId, modifierFlags, virtualKeyCode);
            if (!ok)
            {
                notify(NoticeTable.Text(NoticeKind.HotkeyConflict, hotkeyDisplay));
            }
            return ok;
        }

        /// <summary>WM_HOTKEY dispatch (REQ-SHELL-002): organizes the monitor under the cursor (D-4).</summary>
        public void DispatchHotkey()
        {
            organizeUnderCursor();
        }

        /// <summary>REQ-SHELL-003 exit sequence: unregister the hotkey, dispose the icon, flush the log — in that order.</summary>
        public void Exit()
        {
            unregister(HotkeyId);
            disposeIcon();
            flushLog();
        }
    }

    /// <summary>
    /// REQ-NOTI-001 composition: ONE notice text fanned out to the log and the balloon —
    /// identical by construction, so the balloon text can never drift from the log text.
    /// The B3 Route form is level-aware: the log always receives the text; the balloon
    /// receives the IDENTICAL text only when the notice's balloon policy allows it.
    /// </summary>
    public static class NoticeDispatch
    {
        public static NoticeSink Combine(Action<string> log, Action<string> balloon)
        {
            if (log == null) throw new ArgumentNullException("log");
            if (balloon == null) throw new ArgumentNullException("balloon");
            return delegate(string text)
            {
                log(text);
                balloon(text);
            };
        }

        /// <summary>B3: the message-typed fan-out — log always, balloon only when requested
        /// (Information kinds never balloon; log and balloon texts stay identical).</summary>
        public static NoticeMessageSink Route(Action<string> log, Action<NoticeMessage> balloon)
        {
            if (log == null) throw new ArgumentNullException("log");
            if (balloon == null) throw new ArgumentNullException("balloon");
            return delegate(NoticeMessage message)
            {
                if (message == null)
                {
                    return;
                }
                log(message.Text);
                if (message.ShowBalloon)
                {
                    balloon(message);
                }
            };
        }
    }

    /// <summary>
    /// Card ask-sound: the one winmm call behind the attention ask sound. PlaySound with SND_ALIAS and SND_ASYNC
    /// plays the user's own "Notification.Default" sound-scheme entry in the background (silent when the scheme
    /// sets it to none); SND_NODEFAULT keeps Windows from falling back to the default beep when the alias is missing.
    /// </summary>
    // @MX:WARN: [AUTO] real winmm P/Invoke (PlaySound) - morning checklist; never exercised by the suite.
    internal static class SoundNative
    {
        internal const uint SND_ASYNC = 0x0001;
        internal const uint SND_NODEFAULT = 0x0002;
        internal const uint SND_ALIAS = 0x00010000;

        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        internal static extern bool PlaySound(string sound, IntPtr module, uint flags);

        /// <summary>Queues the notification sound; true when Windows accepted it.</summary>
        internal static bool PlayNotification()
        {
            return PlaySound("Notification.Default", IntPtr.Zero, SND_ALIAS | SND_ASYNC | SND_NODEFAULT);
        }
    }

    // @MX:WARN: [AUTO] real hotkey P/Invoke (RegisterHotKey/UnregisterHotKey) — morning checklist; never exercised by the suite.
    internal static class HotkeyNative
    {
        [DllImport("user32.dll")]
        public static extern bool RegisterHotKey(IntPtr window, int id, int modifierFlags, int virtualKeyCode);

        [DllImport("user32.dll")]
        public static extern bool UnregisterHotKey(IntPtr window, int id);
    }

    /// <summary>
    /// The user32 surface for the B2 manager actions (morning checklist; never exercised
    /// by the suite): restore-if-minimized, SetForegroundWindow, FlashWindowEx.
    /// </summary>
    // @MX:WARN: [AUTO] real user32 window-activation P/Invoke (ShowWindow/SetForegroundWindow/FlashWindowEx) — morning checklist; never exercised by the suite.
    internal static class ManagerNative
    {
        public const int SwRestore = 9;
        public const uint FlashAll = 0x3;        // FLASHW_ALL
        public const uint FlashTimerNoFg = 0xC;  // FLASHW_TIMERNOFG

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr window);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr window, int command);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("user32.dll")]
        public static extern bool FlashWindowEx(ref FlashInfo info);

        [StructLayout(LayoutKind.Sequential)]
        public struct FlashInfo
        {
            public uint Size;
            public IntPtr Handle;
            public uint Flags;
            public uint Count;
            public uint Timeout;
        }
    }

    /// <summary>The composed production ports (built once per process by Composition).</summary>
    internal sealed class ProductionPorts
    {
        /// <summary>Assigned by Composition after construction (the controller's notify closes over this instance).</summary>
        public OrganizeController Controller;

        public readonly WindowDiscovery Windows;
        public readonly IMonitorProvider Monitors;

        /// <summary>The balloon hook (B3: message-typed so the level maps to the icon);
        /// TrayShell assigns it once the NotifyIcon exists (null-safe before that).</summary>
        public Action<NoticeMessage> Balloon;

        /// <summary>
        /// The B4 run token for the CURRENT serialized worker unit: ExecuteOrganize
        /// assigns it at entry and the composed discovery/placement ports read it while
        /// that one unit runs (the coordinator serializes units, so single-writer holds;
        /// the menu path never reads it — ReadWindowsForMenu passes None explicitly).
        /// </summary>
        public System.Threading.CancellationToken RunToken;

        internal ProductionPorts(WindowDiscovery windows, IMonitorProvider monitors)
        {
            this.Windows = windows;
            this.Monitors = monitors;
        }

        /// <summary>Shows the balloon if a hook is attached; a balloon failure never breaks anything (the log already has the text).</summary>
        internal void ShowBalloon(NoticeMessage message)
        {
            Action<NoticeMessage> hook = Balloon;
            if (hook == null || message == null)
            {
                return;
            }
            try
            {
                hook(message);
            }
            catch
            {
                // Balloon display is best-effort; the identical text is already in the log.
            }
        }
    }

    /// <summary>
    /// Composes the REAL ports behind the OrganizeController (REQ-PIPE-001 production
    /// wiring): the registry desktop source, the FancyZones layout resolution, the
    /// monitor-scoped window discovery with the label overlay, the ZoneAssigner /
    /// MergePlanner / MergeExecutor / WindowPlacer defaults, the bounded wsl.exe helper
    /// probe (fail-open, never kills the probe process) and the log+balloon notice fan-out.
    /// Real-screen behaviour is the morning checklist (tools/organize-once.ps1, then the exe).
    /// </summary>
    // @MX:WARN: [AUTO] composes live-screen mutation ports — morning checklist; the suite only drives fakes.
    internal static class Composition
    {
        private const int ProbeTimeoutMs = 2000;

        internal static ProductionPorts Build(LogSink log, LabelRegistry labels)
        {
            VirtualDesktopReader desktopReader = new VirtualDesktopReader();
            IMonitorProvider monitorProvider = new Win32MonitorProvider();
            Win32WindowEnumerator enumerator = new Win32WindowEnumerator();
            ProcessSessionQuery sessionQuery = new ProcessSessionQuery();
            WindowStateReader stateReader = new WindowStateReader();
            // B4: tab reads go through the helper subprocess (hard 1.5s bound), never
            // an unbounded in-process COM walk; the helper exe sits next to the app.
            UiaProbeClient titleProbe = new UiaProbeClient(Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory, "TerminalOrganizer.UiaProbe.exe"));
            string fancyZonesDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Microsoft\\PowerToys\\FancyZones");

            CurrentDesktopSource desktopSource = delegate
            {
                DesktopReadResult win10 = desktopReader.TryReadWin10SessionValue();
                DesktopReadResult win11 = desktopReader.TryReadWin11Value();
                Guid? resolved = DesktopIdResolver.Resolve(win10.Value, win11.Value, null);
                if (!resolved.HasValue)
                {
                    DesktopIdResult foreground = desktopReader.TryGetCurrentDesktopIdFromForegroundWindow();
                    resolved = DesktopIdResolver.Resolve(win10.Value, win11.Value, foreground.Success ? foreground.Value.ToString("B") : null);
                }
                return resolved.HasValue ? resolved.Value.ToString("B") : null;
            };

            // SPEC-MON-011: the resolution (applied row choice with the FancyZones log hint, layout lookup, decision
            // log line) lives in AppliedLayoutResolver; the log delegate is the app log.
            AppliedLayoutResolver layoutResolver = new AppliedLayoutResolver(fancyZonesDir,
                delegate(string message) { log.Append(message); });
            LayoutResolution layoutResolve = layoutResolver.Resolve;

            // Pre-declared so the discovery closure can capture it (assigned immediately
            // below; the closure cannot run before Build completes).
            ProductionPorts ports = null;
            WindowDiscovery windows = delegate(MonitorInfo monitor, string desktop)
            {
                // REQ-SET-004: the rule set is rebuilt from this discovery's own settings read.
                AppSettings read = LoadSettings(delegate(string message) { log.Append(message); });
                DiscoveredWindows discovered = Discover(monitor, desktop, monitorProvider,
                    desktopReader, titleProbe, enumerator, sessionQuery, stateReader, labels,
                    read.TitleRules.RuleSet, ports.RunToken, delegate(string message) { log.Append(message); });
                return discovered;
            };

            ports = new ProductionPorts(windows, monitorProvider);

            // C3: the multi-monitor planning world for Prepare — every OTHER monitor
            // with a Supported layout (its zones, physical label and discovery) plus the
            // persisted manual priority overrides. The target's own row comes from the
            // run's own layout/discovery; the capture never re-discovers the target.
            OverflowWorldCapture worldCapture = delegate(MonitorInfo target, string currentDesktop)
            {
                MonitorInfo[] all = monitorProvider.GetMonitors();
                List<CapturedMonitorRow> rows = new List<CapturedMonitorRow>();
                PriorityOverride[] overrides = new PriorityOverride[0];
                RuleSet rules = RuleSet.PresetOnly();
                int defaultRank = TitleRulesSettings.DefaultRankValue;
                if (target == null || target.StableKey == null)
                {
                    return new CapturedOverflowWorld(rows.ToArray(), overrides, defaultRank);
                }
                try
                {
                    // One settings read feeds the overrides, the rule set and the default rank of this capture.
                    AppSettings read = LoadSettings(delegate(string message) { log.Append(message); });
                    overrides = read.PriorityOverrides;
                    rules = read.TitleRules.RuleSet;
                    defaultRank = read.TitleRules.DefaultRank;
                }
                catch (Exception)
                {
                    // Tolerant: overrides degrade to none, never break the capture.
                }
                foreach (MonitorInfo other in all)
                {
                    if (other == null || other.StableKey == null
                        || target.StableKey.EqualsKey(other.StableKey))
                    {
                        continue;
                    }
                    LayoutResult layout = layoutResolve(other, currentDesktop);
                    if (layout == null || layout.Kind != LayoutResultKind.Supported)
                    {
                        continue;
                    }
                    DiscoveredWindows found = Discover(other, currentDesktop, monitorProvider,
                        desktopReader, titleProbe, enumerator, sessionQuery, stateReader, labels,
                        rules, ports.RunToken, delegate(string message) { log.Append(message); });
                    rows.Add(new CapturedMonitorRow(other, layout.Zones,
                        TrayMenuBuilder.DerivePhysicalLabel(other, all), found));
                }
                return new CapturedOverflowWorld(rows.ToArray(), overrides, defaultRank);
            };

            // C3: one guarded cross-monitor SetWindowPos per planned move, reusing the
            // placer's identity check over the prepared run's snapshots.
            CrossMonitorMoveExecution crossMoveExecutor = delegate(CrossMonitorMove move,
                MutationGuard guard, WindowSnapshot[] snapshots, System.Threading.CancellationToken token)
            {
                PlannedMove one = new PlannedMove(move.WindowId, move.Handle, move.DestinationZoneId,
                    move.TargetLeft, move.TargetTop, move.TargetWidth, move.TargetHeight,
                    true, false, false, false);
                AssignmentPlan single = new AssignmentPlan(new PlannedMove[] { one }, false, null, null);
                WindowPlacementResult[] results = new WindowPlacer().Apply(single, guard,
                    delegate(IntPtr handle)
                    {
                        foreach (WindowSnapshot snapshot in snapshots)
                            if (snapshot.Handle == handle && snapshot.Identity != null)
                                return snapshot.Identity.EqualsForMutation(WindowInspector.ReadIdentity(handle));
                        return false;
                    }, token);
                if (results != null && results.Length > 0)
                {
                    return results[0];
                }
                return new WindowPlacementResult(move.Handle, move.WindowId, true, false,
                    "no cross-monitor move result");
            };

            OrganizeController controller = new OrganizeController(
                desktopSource,
                layoutResolve,
                windows,
                new AssignmentComputation(ZoneAssigner.Assign),
                new MergePlanning(MergePlanner.Plan),
                delegate(PlannedMerge merge) { return ProbeHelper(merge, log); },
                new MergeExecution(new MergeExecutor().RunMerge),
                new PlacementPass(new WindowPlacer().Apply),
                delegate(string text)
                {
                    // Legacy string sink: log-only (the B3 message sink below carries the
                    // balloon policy); kept so pre-B3 call sites keep working.
                    log.Append(text);
                },
                labels,
                delegate(string message) { log.Append(message); },
                delegate(MonitorInfo selected, string desktop, LayoutResult layout)
                {
                    MonitorKey key = selected.StableKey;
                    MonitorInfo[] initialMonitors = monitorProvider.GetMonitors();
                    MonitorInfo initialSelected = MonitorSelector.ResolveUnique(initialMonitors, key);
                    CommitSignature expected = initialSelected == null ? null : new CommitSignature(
                        MonitorTopologySignature.Capture(initialMonitors),
                        new LayoutSignature(key.CanonicalValue, desktop, layout.Kind, layout.LayoutType, layout.Zones));
                    return new CommitGuard(expected, delegate
                    {
                        MonitorInfo[] currentMonitors = monitorProvider.GetMonitors();
                        MonitorInfo current = MonitorSelector.ResolveUnique(currentMonitors, key);
                        if (current == null) return null;
                        string currentDesktop = desktopSource();
                        LayoutResult currentLayout = layoutResolve(current, currentDesktop);
                        return new CommitSignature(MonitorTopologySignature.Capture(currentMonitors),
                            new LayoutSignature(key.CanonicalValue, currentDesktop, currentLayout.Kind, currentLayout.LayoutType, currentLayout.Zones));
                    });
                },
                delegate(AssignmentPlan plan, MutationGuard guard, WindowSnapshot[] snapshots)
                {
                    return new WindowPlacer().Apply(plan, guard, delegate(IntPtr handle)
                    {
                        foreach (WindowSnapshot snapshot in snapshots)
                            if (snapshot.Handle == handle && snapshot.Identity != null)
                                return snapshot.Identity.EqualsForMutation(WindowInspector.ReadIdentity(handle));
                        return false;
                    }, ports.RunToken);
                },
                NoticeDispatch.Route(
                    delegate(string text) { log.Append(text); },
                    delegate(NoticeMessage message) { ports.ShowBalloon(message); }),
                worldCapture,
                crossMoveExecutor);
            ports.Controller = controller;
            return ports;
        }

        /// <summary>The menu and the manager actions use the same fail-closed policy across all monitors (B2: facts + snapshots joined by handle). The menu path never carries a run token (B4).</summary>
        // @MX:NOTE: the sink receives rule timeouts only; the discovery trace stays null so the non-deduplicated UIA-probe and process-query lines never reach the log from the menu path (SPEC-RULES-010).
        internal static DiscoveredWindows ReadWindowsForMenu(LabelRegistry labels, Action<string> ruleLog)
        {
            // REQ-SET-004: every menu read rebuilds the rule set from its own settings read.
            AppSettings read = LoadSettings(null);
            DiscoveredWindows discovered = Discover(null, null, new Win32MonitorProvider(), new VirtualDesktopReader(),
                new UiaProbeClient(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
                    "TerminalOrganizer.UiaProbe.exe")),
                new Win32WindowEnumerator(), new ProcessSessionQuery(),
                new WindowStateReader(), labels, read.TitleRules.RuleSet, System.Threading.CancellationToken.None, null);
            // REQ-LOG-002: one line per rule position per process, through the shared deduplicating log.
            ReportRuleTimeouts(discovered.Snapshots, ruleLog);
            return discovered;
        }

        /// <summary>One settings read for one discovery; the store is tolerant and never throws for file content.</summary>
        private static AppSettings LoadSettings(Action<string> diagnostics)
        {
            return new SettingsStore(SettingsStore.DefaultPath(), diagnostics).Load();
        }

        // SPEC-TRAY-013: internal so the attention window probe reuses the same pid discovery.
        internal static int[] ReadTerminalPids()
        {
            List<int> pids = new List<int>();
            Process[] processes = Process.GetProcessesByName("WindowsTerminal");
            try
            {
                foreach (Process process in processes)
                {
                    try { pids.Add(process.Id); }
                    catch (InvalidOperationException) { }
                }
            }
            finally { foreach (Process process in processes) process.Dispose(); }
            return pids.ToArray();
        }

        private static DiscoveredWindows Discover(MonitorInfo monitor, string desktop,
            IMonitorProvider monitorProvider, VirtualDesktopReader desktopReader,
            UiaProbeClient titleProbe, Win32WindowEnumerator enumerator,
            ProcessSessionQuery sessionQuery, WindowStateReader stateReader, LabelRegistry labels,
            RuleSet rules, System.Threading.CancellationToken token, Action<string> trace)
        {
            int[] pids = ReadTerminalPids();
            EnumeratedWindow[] enumerated;
            using (WindowDesktopSessionSource session = new WindowDesktopSessionSource(desktopReader.OpenSession()))
                enumerated = enumerator.Enumerate(pids, session, monitorProvider.GetMonitors());
            // B5: the one shared production scope rule (stable monitor key + current desktop
            // only); the dump-windows / organize-dryrun / organize-once tools call the same
            // WindowScope.Filter instead of re-implementing the rule.
            WindowScopeResult scope = WindowScope.Filter(enumerated,
                monitor == null ? null : monitor.StableKey, false);
            DiscoveredWindows acquired = DiscoveryPolicy.Acquire(scope.Included, monitor, stateReader.Read,
                delegate(IntPtr handle)
                {
                    // B4: one bounded helper read per window; the elapsed time and the
                    // degradation ride the log when the hard bound fires.
                    Stopwatch clock = Stopwatch.StartNew();
                    TabTitleResult tabs = titleProbe.ReadTabs(handle, token);
                    if (tabs != null && tabs.Quality == TabReadQuality.TimedOut && trace != null)
                    {
                        trace("uia probe timed out for window " + handle + " after "
                            + clock.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture)
                            + "ms (fallback title, unmergeable)");
                    }
                    return tabs;
                },
                delegate(int[] eligiblePids)
                {
                    ProcessSessionQueryResult queried = sessionQuery.QueryChildren(eligiblePids, token);
                    if (queried.TimedOut && trace != null)
                    {
                        trace("wmi session query degraded (timeout/failure): "
                            + (queried.Error ?? string.Empty));
                    }
                    return CommandLineClassifier.ClassifyAll(queried.Children);
                },
                delegate(WindowSnapshot[] snapshots) { return ApplyLabels(snapshots, labels); },
                rules);
            ReportRuleTimeouts(acquired.Snapshots, trace);
            // The scoped input already passed the monitor/desktop checks, so re-stitch the
            // pre-scope skip counters onto the result (B3 status keeps its full sweep view).
            return new DiscoveredWindows(acquired.Facts, acquired.Snapshots,
                scope.Included.Length + scope.SkippedOtherDesktop + scope.SkippedUnknownDesktop,
                scope.SkippedOtherDesktop, scope.SkippedUnknownDesktop, acquired.SkippedUnknownStateCount);
        }

        /// <summary>Writes one line per rule that timed out while evaluating a window, once per distinct rule and position (REQ-LOG-001).</summary>
        // @MX:NOTE: the line text and the position-only dedupe key are pinned by tests (audit finding F9); changing the key needs its own SPEC. Executed and skipped diagnostics of one position share one line.
        private static void ReportRuleTimeouts(WindowSnapshot[] snapshots, Action<string> trace)
        {
            if (trace == null || snapshots == null)
            {
                return;
            }
            foreach (WindowSnapshot snapshot in snapshots)
            {
                if (snapshot == null)
                {
                    continue;
                }
                foreach (RuleDiagnostic diagnostic in snapshot.RuleDiagnostics)
                {
                    string line = "title rule " + diagnostic.Position.ToString(CultureInfo.InvariantCulture)
                        + " timed out; treated as no match";
                    RuleDiagnosticLog.Report(trace, line, line);
                }
            }
        }

        // @MX:NOTE: the overlay keeps the synthetic session (Mergeable stays false); identity = label; the window's rule outcome is carried through.
        /// <summary>
        /// REQ-PIPE-004 overlay: the user asserted the match, so a labeled window without canonical
        /// session evidence is rebuilt for display with a synthetic session (no command line). The
        /// identity name becomes the label and the rule rank and reference ride along (SPEC-RULES-009
        /// REQ-LBL-001). Labels never authorize merge.
        /// </summary>
        private static WindowSnapshot[] ApplyLabels(WindowSnapshot[] snapshots, LabelRegistry labels)
        {
            if (snapshots == null)
            {
                return new WindowSnapshot[0];
            }
            if (labels == null || labels.Count == 0)
            {
                return snapshots;
            }
            List<WindowSnapshot> result = new List<WindowSnapshot>();
            foreach (WindowSnapshot snapshot in snapshots)
            {
                if (snapshot == null)
                {
                    continue;
                }
                string label = labels.TryGetLabel(snapshot.Handle);
                if (label == null || snapshot.Identified)
                {
                    result.Add(snapshot);
                    continue;
                }
                string title = snapshot.Tabs.Length > 0 ? snapshot.Tabs[0].Title : label;
                TabSnapshot tab = new TabSnapshot(title, title, new SessionRecord(label, SessionKind.Local, null));
                WindowRuleOutcome outcome = new WindowRuleOutcome(label, snapshot.RuleRank,
                    snapshot.RuleReference, snapshot.RuleDiagnostics);
                result.Add(new WindowSnapshot(snapshot.Identity, snapshot.Monitor, snapshot.DesktopStatus,
                    new TabSnapshot[] { tab }, true, new string[0], false, snapshot.TabReadQuality, outcome));
            }
            return result.ToArray();
        }

        /// <summary>
        /// The bounded helper probe (REQ-PIPE-005): wsl.exe -d distro --exec /usr/bin/test -f
        /// script, distro and script parsed from the session's command line. Exit 0 = true;
        /// non-zero = false (definitively absent); timeout, start failure or unparseable
        /// command line = null (FAIL OPEN). The probe process is never forcibly terminated —
        /// a timed-out probe may briefly linger by design (no destructive process calls here).
        /// </summary>
        // @MX:WARN: [AUTO] spawns wsl.exe (read-only test -f) — morning checklist surface.
        private static bool? ProbeHelper(PlannedMerge merge, LogSink log)
        {
            try
            {
                if (merge == null || merge.Session == null || string.IsNullOrEmpty(merge.Session.CommandLine))
                {
                    return null; // unknown target: fail open
                }
                string distro;
                string script;
                ParseWslTarget(merge.Session.CommandLine, out distro, out script);
                if (string.IsNullOrEmpty(distro) || string.IsNullOrEmpty(script))
                {
                    return null; // unparseable command line: fail open
                }
                ProcessStartInfo start = new ProcessStartInfo(
                    "wsl.exe", "-d " + distro + " --exec /usr/bin/test -f \"" + script + "\"");
                start.CreateNoWindow = true;
                start.UseShellExecute = false;
                using (Process probe = Process.Start(start))
                {
                    if (probe == null)
                    {
                        return null;
                    }
                    if (!probe.WaitForExit(ProbeTimeoutMs))
                    {
                        log.Append("helper probe timed out after " + ProbeTimeoutMs + "ms (fail-open): "
                            + merge.Session.CommandLine);
                        return null;
                    }
                    return probe.ExitCode == 0;
                }
            }
            catch (Exception ex)
            {
                log.Append("helper probe failed (fail-open): " + ex.Message);
                return null;
            }
        }

        /// <summary>Pulls the -d distro and the --exec script tokens out of a wsl.exe command line.</summary>
        private static void ParseWslTarget(string commandLine, out string distro, out string script)
        {
            distro = null;
            script = null;
            if (string.IsNullOrEmpty(commandLine))
            {
                return;
            }
            string[] tokens = commandLine.Split(' ');
            for (int i = 0; i < tokens.Length; i++)
            {
                if (tokens[i] == "-d" && i + 1 < tokens.Length)
                {
                    distro = tokens[i + 1];
                }
                else if (tokens[i] == "--exec" && i + 1 < tokens.Length)
                {
                    script = tokens[i + 1];
                    return;
                }
            }
        }
    }

    /// <summary>
    /// The NotifyIcon glue (REQ-SHELL-001; morning-checklist surface): builds the context
    /// menu from the TrayMenuBuilder model, hosts the hidden WM_HOTKEY message window,
    /// wires the lifecycle (register/dispatch/exit), organizes per menu entry and under the
    /// cursor (D-4 fallback: the monitor containing the cursor, else the first attached),
    /// persists the manager choice through the SettingsStore's read-modify-write (sole
    /// writer), runs the one-time first-run onboarding (B1), labels unidentified windows
    /// run-scoped (D-1), and disposes the old menu on every rebuild (NFR-3). Never
    /// exercised by the suite — the suite drives TrayLifecycle.
    /// </summary>
    // @MX:WARN: [AUTO] real tray/NotifyIcon/RegisterHotKey/balloon surface — morning checklist; not an acceptance claim.
    internal sealed class TrayShell : ApplicationContext
    {
        private readonly SettingsStore settings;
        private readonly LogSink log;
        private readonly ProductionPorts ports;
        private readonly TrayLifecycle lifecycle;
        private readonly HotkeyWindow messageWindow;
        private readonly OperationCoordinator coordinator;
        private readonly NotifyIcon icon;
        private readonly Icon applicationIcon;
        private readonly MarshalledOverflowChoicePrompt choiceAsker;
        private readonly AttentionController attention;
        private ContextMenuStrip menu;
        private OrganizeRequest activeRequest;
        private bool topologyRerunArmed;
        private string lastResultText;
        // SPEC-TRAY-015 M1: the one-shot stay-open flag (armed by a settings activation,
        // consumed by the Closing handler) and the last-open manager state feeding the
        // in-place live update (REQ-STAY-001/002).
        private bool keepMenuOpenOnClose;
        private ManagerResolution lastManagerResolution;
        private WindowSnapshot[] lastMenuSnapshots;
        // SPEC-TRAY-015 M3 (REQ-WIN-001): the single-instance settings-form reference.
        private SettingsForm settingsForm;
        // SPEC-TRAY-020: the update checker, the app-log path handed to the detached
        // helper (LogSink keeps its path private), and the one-shot startup-check timer.
        private readonly UpdateChecker updateChecker;
        // True only for a repo checkout (UpdateChecker.DeriveRepoRoot() != null), derived once at
        // construction: it gates the two update menu rows and the startup check, so a release-zip
        // install (no .git) shows no update UI at all.
        private readonly bool updateSupported;
        private readonly string logPath;
        private System.Windows.Forms.Timer startupUpdateTimer;
        private const string TopologyRerunSource = "topology-rerun";

        internal TrayShell()
        {
            // REQ-LOG-001: title-rule diagnostics of every later read go to the log (once each per process).
            // The bootstrap read below has no sink, so it consumes no diagnostic before the log exists.
            this.settings = new SettingsStore(SettingsStore.DefaultPath(),
                delegate(string line) { LogSink sink = this.log; if (sink != null) { sink.Append(line); } });
            AppSettings current = new SettingsStore(SettingsStore.DefaultPath()).Load();
            // B1: themed application icon + the one-time onboarding dialog (an
            // incomplete first run persists firstRunCompleted=true after the dialog
            // closes). The checkbox applies the Startup-folder shortcut — an
            // explicit toggle event only, never on a plain settings load.
            this.applicationIcon = IconLoader.LoadApplicationIcon(IconLoader.IsDarkApplicationTheme());
            current = FirstRunFlow.EnsureCompletedWithStartup(current, this.applicationIcon, this.settings,
                delegate(Icon dialogIcon, string dialogHotkey, bool startWith)
                {
                    return FirstRunDialog.Show(dialogIcon, dialogHotkey, startWith);
                },
                StartupShortcutPort.Default());
            this.log = new LogSink(string.IsNullOrEmpty(current.LogPath) ? SettingsStore.DefaultLogPath() : current.LogPath);
            // SPEC-TRAY-020: the update checker over the same log; the log path is the
            // helper's -LogPath argument (the detached helper appends to the app log).
            this.logPath = string.IsNullOrEmpty(current.LogPath) ? SettingsStore.DefaultLogPath() : current.LogPath;
            string updateRepoRoot = UpdateChecker.DeriveRepoRoot();
            this.updateSupported = updateRepoRoot != null;
            this.updateChecker = UpdateChecker.CreateProduction(this.log, updateRepoRoot);
            this.ports = Composition.Build(this.log, new LabelRegistry());
            this.ports.Balloon = delegate(NoticeMessage message) { ShowBalloon(message.Text, message.Level); };
            this.messageWindow = new HotkeyWindow(null);
            // The coordinator marshals completions through this control: force the handle
            // now (A5) so BeginInvoke is valid from the first request on. The C3 choice
            // dialog marshals through the same control from the worker.
            IntPtr marshallingHandle = this.messageWindow.Handle;
            this.choiceAsker = new MarshalledOverflowChoicePrompt(this.messageWindow, this.messageWindow);
            this.coordinator = new OperationCoordinator(
                this.messageWindow,
                new OperationWork(ExecuteOrganize),
                new Action<OperationPhase>(CoordinatorPhaseChanged),
                new Action<OperationCompletion>(OrganizeCompleted));
            // SPEC-TRAY-013/014: the attention controller (REQ-CTL-001) polls the WSL producer's
            // signal directory and blinks the overlay; constructed AFTER the log and the
            // marshalling message window exist (its marshal seam needs the live control). The
            // SPEC-TRAY-014 options (D-7/D-9, the D-6 extension) arrive from the loaded settings;
            // SPEC-TRAY-016 adds the info visible-seconds cap (REQ-PREF-001, the fifth value).
            this.attention = AttentionController.CreateProduction(this.log, this.messageWindow,
                AttentionSignalDirectory(), current.AttentionOverlay, current.AttentionEventPolicy,
                current.AttentionStopBlinkLimit, current.AttentionOverlayTopmost,
                current.AttentionInfoVisibleSeconds, current.AttentionRemoteAlerts);
            // Card t18: a signal that rings no window gets a tray balloon, because the producer skips its own
            // toast and flash while the organizer heartbeat is fresh.
            this.attention.SetZeroMatchNotice(
                delegate(string title, string text) { ShowAttentionBalloon(title, text); }, null);
            // Card ask-sound: an alert that needs an answer (kind "ask") also plays the Windows notification
            // sound, because the producer stays quiet while the organizer heartbeat is fresh.
            this.attention.SetAskSound(delegate { PlayNotificationSound(); }, null);
            if (!current.AttentionOverlay)
            {
                // D-2 default ON; an explicit false in the file starts the controller disabled.
                this.attention.SetEnabled(false);
            }
            this.lifecycle = new TrayLifecycle(
                delegate(int id, int mods, int vk) { return HotkeyNative.RegisterHotKey(messageWindow.Handle, id, mods, vk); },
                delegate(int id) { return HotkeyNative.UnregisterHotKey(messageWindow.Handle, id); },
                current.Hotkey,
                // The lifecycle channel carries only the hotkey-registration failure,
                // pinned Error + balloon in the B3 notice table — hence the fixed level here.
                delegate(string text) { log.Append(text); ShowBalloon(text, NoticeLevel.Error); },
                delegate { RequestOrganizeUnderCursor(); },
                delegate { DisposeIcon(); },
                delegate { log.Flush(); });
            this.messageWindow.Attach(this.lifecycle);
            this.menu = BuildMenu();
            this.icon = new NotifyIcon();
            this.icon.Icon = this.applicationIcon;
            this.icon.Text = AppVersion.DisplayName;
            this.icon.ContextMenuStrip = this.menu;
            this.icon.Visible = true;
            RegisterConfiguredHotkey(current);
            // SPEC-TRAY-013: the poll and blink timers start once the shell is whole.
            this.attention.Start();
            // SPEC-TRAY-020 D-6 (REQ-UPD-005): the one-shot delayed startup update check,
            // armed only when the file-edit-only setting resolves true (absent = true).
            // The check NEVER spawns the helper and never exits or restarts the app;
            // ONLY a Behind outcome balloons (every other outcome logs its one line).
            if (current.UpdateAutoCheckEnabled)
            {
                ArmStartupUpdateCheck();
            }
            this.log.Append("tray shell started (hotkey " + current.Hotkey + ")");
        }

        /// <summary>B3: one notice — always logged; ballooned with the level-mapped icon
        /// only when the notice's policy allows it (log text and balloon text identical).</summary>
        private void Notice(NoticeMessage message)
        {
            if (message == null)
            {
                return;
            }
            log.Append(message.Text);
            if (message.ShowBalloon)
            {
                ShowBalloon(message.Text, message.Level);
            }
        }

        /// <summary>B3: the level-to-icon mapping on the balloon surface (Info/Warning/Error).</summary>
        private void ShowBalloon(string text, NoticeLevel level)
        {
            if (this.icon != null)
            {
                ToolTipIcon icon = level == NoticeLevel.Error ? ToolTipIcon.Error
                    : level == NoticeLevel.Warning ? ToolTipIcon.Warning
                    : ToolTipIcon.Info;
                this.icon.ShowBalloonTip(5000, "TerminalOrganizer", text, icon);
            }
        }

        /// <summary>Card ask-sound: plays the user's Windows notification sound, asynchronously (the UI thread never waits). A failure throws to the attention controller, which contains and logs it.</summary>
        private static void PlayNotificationSound()
        {
            if (!SoundNative.PlayNotification())
            {
                throw new InvalidOperationException("PlaySound did not queue the Notification.Default sound");
            }
        }

        /// <summary>Card t18: the attention zero-match notice as an Info balloon with its own title (the notice-table balloons all carry the app title).</summary>
        private void ShowAttentionBalloon(string title, string text)
        {
            if (this.icon != null)
            {
                this.icon.ShowBalloonTip(5000, title, text, ToolTipIcon.Info);
            }
        }

        private void RegisterConfiguredHotkey(AppSettings current)
        {
            HotkeyParseResult parsed = HotkeyParser.Parse(current.Hotkey);
            if (!parsed.Success)
            {
                log.Append("configured hotkey '" + current.Hotkey + "' failed to parse; using the default");
                parsed = HotkeyParser.Parse(SettingsStore.DefaultHotkey);
            }
            if (parsed.Success)
            {
                this.lifecycle.RegisterHotKey(parsed.ModifierFlags, parsed.VirtualKey);
            }
        }

        private ContextMenuStrip BuildMenu()
        {
            AppSettings current = settings.Load();
            DiscoveredWindows discovered = Composition.ReadWindowsForMenu(ports.Controller.Labels,
                delegate(string line) { log.Append(line); });
            ManagerSelector selector = current.ManagerSelector == null ? ManagerSelector.None() : current.ManagerSelector;
            ManagerResolution resolution = ManagerResolver.Resolve(selector, discovered.Facts, discovered.Snapshots);
            // SPEC-TRAY-015 M1: the last-open resolution and snapshots feed the in-place
            // live update (REQ-STAY-002). The candidate list and manager status stay
            // those of this menu open — the accepted next-open refresh semantics (spec 2.2).
            this.lastManagerResolution = resolution;
            this.lastMenuSnapshots = discovered.Snapshots;
            // REQ-UI-001: one row text per window (rank and provenance from this read's overrides and default rank).
            string[] rowTexts = RuleProvenance.RowTexts(discovered.Snapshots, current.PriorityOverrides,
                current.TitleRules.DefaultRank);
            // SPEC-TRAY-015 M2 (REQ-IA-001) + SPEC-TRAY-017 (REQ-MENU-002): the shell
            // builds the radio-submenu era through the ONE shared state factory — fresh
            // monitors and row texts for the menu build (the cached resolution and
            // snapshots were just seeded above, so the factory reads them directly).
            TrayMenuState state = BuildMenuState(current, ports.Monitors.GetMonitors(), rowTexts);
            TrayMenuEntry[] entries = TrayMenuBuilder.Build(state);
            ContextMenuStrip built = new ContextMenuStrip();
            foreach (TrayMenuEntry entry in entries)
            {
                ToolStripItem item = RenderEntry(entry);
                if (item != null)
                {
                    built.Items.Add(item);
                }
            }
            WireStayOpenClosing(built);
            return built;
        }

        /// <summary>Binds one model entry (recursively for submenu roots) to a WinForms item; morning-checklist surface.</summary>
        private ToolStripItem RenderEntry(TrayMenuEntry entry)
        {
            if (entry == null)
            {
                return null;
            }
            if (entry.Kind == TrayMenuEntryKind.Separator)
            {
                return new ToolStripSeparator();
            }
            ToolStripMenuItem item = new ToolStripMenuItem(entry.Label);
            item.Enabled = entry.Enabled;
            if (entry.Checked)
            {
                item.CheckState = CheckState.Checked;
            }
            item.Tag = entry;
            foreach (TrayMenuEntry child in entry.Children)
            {
                ToolStripItem rendered = RenderEntry(child);
                if (rendered != null)
                {
                    item.DropDownItems.Add(rendered);
                }
            }
            WireEntryAction(item, entry);
            return item;
        }

        private void WireEntryAction(ToolStripMenuItem item, TrayMenuEntry entry)
        {
            switch (entry.Kind)
            {
                case TrayMenuEntryKind.OrganizeUnderCursor:
                    item.Click += delegate { RequestOrganizeUnderCursor(); };
                    break;
                case TrayMenuEntryKind.OrganizeMonitor:
                    {
                        MonitorKey key = entry.MonitorKey;
                        item.Click += delegate { coordinator.Request(new OrganizeRequest(key, false, "menu")); };
                        break;
                    }
                case TrayMenuEntryKind.ShowManager:
                    item.Click += delegate { ShowManagerWindow(); };
                    break;
                case TrayMenuEntryKind.ClearManager:
                    item.Click += delegate { SaveManagerSelector(ManagerSelector.None()); };
                    break;
                case TrayMenuEntryKind.SetManager:
                    {
                        WindowMenuKey windowKey = entry.WindowKey;
                        item.Click += delegate { SetManagerFromMenu(windowKey); };
                        break;
                    }
                case TrayMenuEntryKind.LabelWindow:
                    {
                        WindowMenuKey labelKey = entry.WindowKey;
                        string title = entry.Value ?? entry.Label;
                        IntPtr handle = labelKey == null || labelKey.Identity == null ? IntPtr.Zero : labelKey.Identity.Handle;
                        item.Click += delegate { LabelWindow(handle, title); };
                        break;
                    }
                case TrayMenuEntryKind.OverflowPolicy:
                    {
                        string value = entry.Value;
                        item.Click += delegate { SelectOverflowPolicy(value); };
                        break;
                    }
                case TrayMenuEntryKind.AttentionOverlay:
                    // SPEC-TRAY-013 REQ-UI-001: same UI-thread sole-writer read-modify-write as the
                    // overflow rows; saves the negated value, flips the controller, rebuilds, never organizes.
                    item.Click += delegate { ToggleAttentionOverlay(); };
                    break;
                case TrayMenuEntryKind.AttentionEnabled:
                    // SPEC-TRAY-014 D-8: the enable row moved INSIDE the submenu; same behavior.
                    item.Click += delegate { ToggleAttentionOverlay(); };
                    break;
                case TrayMenuEntryKind.AttentionEventPolicy:
                    {
                        string current = entry.Value;
                        item.Click += delegate { SelectAttentionEventPolicy(current); };
                        break;
                    }
                case TrayMenuEntryKind.AttentionStopBlinks:
                    {
                        string current = entry.Value;
                        item.Click += delegate { SelectAttentionStopBlinks(current); };
                        break;
                    }
                case TrayMenuEntryKind.AttentionTopmost:
                    item.Click += delegate { ToggleAttentionTopmost(); };
                    break;
                case TrayMenuEntryKind.OpenLog:
                    item.Click += delegate { OpenLogFile(); };
                    break;
                case TrayMenuEntryKind.Settings:
                    // SPEC-TRAY-015 M3 (REQ-WIN-001; AM-2): the activated row opens the
                    // single-instance modeless settings form; the menu itself dismisses
                    // (the Settings kind keeps its DISMISS classification, REQ-STAY-004).
                    item.Click += delegate { ShowSettingsForm(); };
                    break;
                case TrayMenuEntryKind.CheckForUpdates:
                    // SPEC-TRAY-020 (REQ-UPD-004): the read-only manual check — runs off
                    // the UI thread, its outcome balloons through the existing surface.
                    item.Click += delegate { RunUpdateCheckOnBackground(HandleManualUpdateCheckCompleted); };
                    break;
                case TrayMenuEntryKind.UpdateAndRestart:
                    // SPEC-TRAY-020 (REQ-UPD-007): re-check, then spawn+exit / notice per
                    // the decision. The row is only enabled while idle (D-7).
                    item.Click += delegate { RunUpdateCheckOnBackground(HandleUpdateAndRestartCompleted); };
                    break;
                case TrayMenuEntryKind.Exit:
                    item.Click += delegate { RequestApplicationExit(); };
                    break;
            }
        }

        /// <summary>NFR-3: rebuilds the menu, disposing the old items and strip.</summary>
        private void RebuildMenu()
        {
            ContextMenuStrip old = this.menu;
            this.menu = BuildMenu();
            if (this.icon != null)
            {
                this.icon.ContextMenuStrip = this.menu;
            }
            if (old != null)
            {
                // Snapshot before disposing: disposing a ToolStripItem removes it from
                // old.Items, and enumerating a collection while modifying it throws.
                ToolStripItem[] snapshot = new ToolStripItem[old.Items.Count];
                old.Items.CopyTo(snapshot, 0);
                foreach (ToolStripItem item in snapshot)
                {
                    if (item != null)
                    {
                        item.Dispose();
                    }
                }
                old.Dispose();
            }
        }

        /// <summary>
        /// SPEC-TRAY-015 M1 (REQ-STAY-001): registers the stay-open cancellation on the
        /// root strip and every dropdown (nested dropdowns raise Closing on their OWN
        /// dropdown — plan.md B6). One subscription expression, one handler; called from
        /// every build so every rebuilt strip is wired.
        /// </summary>
        private void WireStayOpenClosing(ToolStripDropDown strip)
        {
            strip.Closing += new ToolStripDropDownClosingEventHandler(this.MenuDropdownClosing);
            foreach (ToolStripItem item in strip.Items)
            {
                ToolStripDropDownItem dropDown = item as ToolStripDropDownItem;
                if (dropDown != null)
                {
                    WireStayOpenClosing(dropDown.DropDown);
                }
            }
        }

        /// <summary>
        /// SPEC-TRAY-015 M1 (REQ-STAY-001): while the one-shot keep-open flag is set (a
        /// settings activation just ran), cancels ONLY the item-activation closes (mouse
        /// or keyboard). A genuine dismissal — click outside, focus loss, the Esc key —
        /// always closes; the menu is never made unclosable.
        /// </summary>
        // @MX:NOTE: [SPEC-TRAY-015 M1/AM-1] the stay-open keep-open flag + Closing handler — cancel is flag-scoped to item activations (mouse or keyboard); explicit dismissal always closes.
        private void MenuDropdownClosing(object sender, ToolStripDropDownClosingEventArgs e)
        {
            if (!this.keepMenuOpenOnClose)
            {
                return;
            }
            if (e.CloseReason == ToolStripDropDownCloseReason.ItemClicked
                || e.CloseReason == ToolStripDropDownCloseReason.Keyboard)
            {
                e.Cancel = true;
                // One activation closes a CHAIN of dropdowns: keep the flag until the
                // chain settles (the posted callback runs after this input event has
                // finished dispatching) so every level cancels, yet a later Esc or
                // click-away — which cannot overtake a posted message — still closes.
                this.messageWindow.BeginInvoke(new Action(ClearKeepOpenFlag));
            }
            else
            {
                this.keepMenuOpenOnClose = false;
            }
        }

        private void ClearKeepOpenFlag()
        {
            this.keepMenuOpenOnClose = false;
        }

        /// <summary>
        /// SPEC-TRAY-015 M3 (REQ-WIN-001; AM-2 — the ELECTED supersession of the
        /// TRAY-007 section 1.1/6 and TRAY-014 section 5 windowless commitments):
        /// the settings-form entry point — ONE modeless SettingsForm over the
        /// EXISTING settings surface, single-instance: a live instance is focused
        /// (restored if minimized, then activated), never re-created; a fresh
        /// instance is shown only when none is alive. The Settings row DISMISSES
        /// the menu (the REQ-STAY-004 partition is unchanged by M3), so this path
        /// never arms the stay-open flag. Sync-audit fix F1: the form's write
        /// paths persist through the static helpers without touching the strip,
        /// so the fresh instance wires ONE FormClosed rebuild of the menu — the
        /// strip reflects every form write on the NEXT open (the AC-008 manual
        /// row), while a settings click still never rebuilds under the open
        /// menu (REQ-STAY-003).
        /// </summary>
        // @MX:NOTE: [SPEC-TRAY-015 M3/AM-2] the settings-form entry point + single-instance wiring — focus-existing on reopen; the row's dismiss classification is unchanged (REQ-WIN-001).
        private void ShowSettingsForm()
        {
            if (this.settingsForm != null && !this.settingsForm.IsDisposed)
            {
                if (!this.settingsForm.Visible)
                {
                    this.settingsForm.Show();
                }
                if (this.settingsForm.WindowState == FormWindowState.Minimized)
                {
                    this.settingsForm.WindowState = FormWindowState.Normal;
                }
                this.settingsForm.Activate();
                return;
            }
            this.settingsForm = new SettingsForm(this, this.settings, this.attention, this.log,
                new Func<AppSettings, TrayMenuState>(this.MenuStateForLiveUpdate));
            // SPEC-TRAY-015 F1 (sync-audit MAJOR, Functionality): the form's writes
            // persist through the static helpers but never refreshed the strip, so
            // the menu showed stale settings until the next organize run. The menu
            // is dismissed while the form is up, so ONE rebuild when the form
            // closes makes the next open fresh — and because the subscription rides
            // the owned form instance, ALL form write paths (attention enable /
            // policy / blinks / topmost, overflow policy, manager selection) are
            // covered by the single rebuild; the reopen path (focus-existing) keeps
            // the subscription its instance already wired.
            // @MX:NOTE: [SPEC-TRAY-015 F1] form-closed menu refresh — the settings-form writes persist but never refreshed the live strip; ONE FormClosed rebuild makes the next menu open reflect them.
            this.settingsForm.FormClosed += delegate
            {
                RebuildMenu();
            };
            this.settingsForm.Show();
        }

        /// <summary>
        /// SPEC-TRAY-015 M1 (AM-1, REQ-STAY-002/003): the settings clicks' post-save
        /// path — update the LIVE strip in place through the shared derivation (never a
        /// rebuild, never a dispose) and arm the one-shot keep-open flag so the closing
        /// menu stays open.
        /// </summary>
        private void KeepMenuOpenWithSettingsUpdate()
        {
            ApplySettingsUpdateInPlace();
            this.keepMenuOpenOnClose = true;
        }

        /// <summary>
        /// The in-place live-strip update (REQ-STAY-002): re-derives every settings row
        /// through the shared TrayMenuBuilder derivation over the post-save settings and
        /// mutates the live items — the busy-flip precedent (DisableOrganizeMenuItems),
        /// never a rebuild. While busy, the busy flip owns the Enabled flags, so the
        /// update skips Enabled (busy-disabled rows stay disabled).
        /// </summary>
        private void ApplySettingsUpdateInPlace()
        {
            if (this.menu == null)
            {
                return;
            }
            TrayMenuState state = MenuStateForLiveUpdate(settings.Load());
            foreach (ToolStripItem item in this.menu.Items)
            {
                UpdateSettingsItemInPlace(item, state);
            }
        }

        /// <summary>The derivation state for one live update: the post-save settings
        /// joined with the last-open resolution and snapshots (spec 2.2 next-open
        /// refresh semantics). Built in the SAME M2 radio era as the menu build so the
        /// live radio rows derive against the era that rendered them (REQ-IA-001);
        /// SPEC-TRAY-017 (REQ-MENU-002): through the ONE shared state factory.</summary>
        private TrayMenuState MenuStateForLiveUpdate(AppSettings current)
        {
            return BuildMenuState(current, null, null);
        }

        /// <summary>
        /// REQ-MENU-002 (SPEC-TRAY-017): the ONE shared TrayMenuState construction for
        /// the menu build and the live update. The radio-era literal — the
        /// attentionRadioSubmenus flag, always true here — lives in this one
        /// construction, so the two callers structurally cannot disagree on the era
        /// (the AM-2 count drops 2 -> 1). The genuinely-differing inputs are the
        /// parameters — fresh monitors and row texts for the menu build, null/null for
        /// the live update; the selector normalization, the cached last-open
        /// resolution and snapshots (seeded by the menu build immediately before its
        /// call), and the busy/result-text reads are common to both paths.
        /// </summary>
        // @MX:NOTE: [AUTO] the shared menu-state factory (SPEC-TRAY-017 REQ-MENU-002): menu build and live update flow through one construction carrying the radio-era flag exactly once.
        private TrayMenuState BuildMenuState(AppSettings current, MonitorInfo[] monitors, string[] rowTexts)
        {
            ManagerSelector selector = current.ManagerSelector == null
                ? ManagerSelector.None() : current.ManagerSelector;
            return new TrayMenuState(this.coordinator.IsBusy, current.Hotkey,
                monitors, this.lastMenuSnapshots, selector, this.lastManagerResolution,
                this.lastResultText, current.MergeEnabled, current.OverflowPolicy, rowTexts,
                current.AttentionOverlay, current.AttentionEventPolicy,
                current.AttentionStopBlinkLimit, current.AttentionOverlayTopmost,
                attentionRadioSubmenus: true, supportsUpdate: this.updateSupported,
                attentionRemoteAlerts: current.AttentionRemoteAlerts);
        }

        /// <summary>Walks the live tree (the busy-flip shape): every settings-mutation
        /// row and the manager current caption re-render through the shared derivation;
        /// the SetManager rows flip their checked markers through the shared predicate.</summary>
        private static void UpdateSettingsItemInPlace(ToolStripItem item, TrayMenuState state)
        {
            TrayMenuEntry entry = item == null ? null : item.Tag as TrayMenuEntry;
            ToolStripMenuItem menuItem = item as ToolStripMenuItem;
            if (entry != null && menuItem != null)
            {
                bool isSettingsRow = TrayMenuBuilder.IsKeepOpenKind(entry.Kind);
                bool isManagerCaption = entry.Kind == TrayMenuEntryKind.ManagerCurrent;
                if (isSettingsRow || isManagerCaption)
                {
                    TrayMenuEntry updated = TrayMenuBuilder.DeriveSettingsEntry(entry.Kind, entry.Value, state);
                    if (updated != null)
                    {
                        menuItem.Text = updated.Label;
                        menuItem.CheckState = updated.Checked ? CheckState.Checked : CheckState.Unchecked;
                        if (!state.Busy)
                        {
                            menuItem.Enabled = updated.Enabled;
                        }
                    }
                }
                if (entry.Kind == TrayMenuEntryKind.SetManager)
                {
                    menuItem.CheckState = TrayMenuBuilder.IsSelectedManagerCandidate(
                        state.ManagerSelector, FindLiveCandidate(state.Windows, entry.WindowKey))
                        ? CheckState.Checked : CheckState.Unchecked;
                }
            }
            ToolStripDropDownItem dropDown = item as ToolStripDropDownItem;
            if (dropDown != null)
            {
                foreach (ToolStripItem child in dropDown.DropDownItems)
                {
                    UpdateSettingsItemInPlace(child, state);
                }
            }
        }

        /// <summary>The last-open snapshot of one candidate row, joined by handle; null when absent.</summary>
        private static WindowSnapshot FindLiveCandidate(WindowSnapshot[] windows, WindowMenuKey key)
        {
            if (windows == null || key == null || key.Identity == null)
            {
                return null;
            }
            foreach (WindowSnapshot window in windows)
            {
                if (window != null && window.Identity != null && window.Identity.Handle == key.Identity.Handle)
                {
                    return window;
                }
            }
            return null;
        }

        /// <summary>Hotkey entry (A5): queue an under-cursor organize request on the coordinator.</summary>
        private void RequestOrganizeUnderCursor()
        {
            coordinator.Request(new OrganizeRequest(null, true, "hotkey"));
        }

        /// <summary>Menu Exit entry (A5): exit now when idle, else deferred to the marshalled completion.</summary>
        private void RequestApplicationExit()
        {
            coordinator.RequestExit(delegate { ExitApplication(); });
        }

        /// <summary>
        /// The serialized work unit (A5): resolves the target monitor AT RUN TIME (a
        /// pending under-cursor request re-reads the cursor only now, not when queued),
        /// honours the cancellation token before the first mutation, and runs the pipeline
        /// off the UI thread. WinForms controls are never touched here — UI feedback goes
        /// through the marshalled completion.
        /// </summary>
        private OperationCompletion ExecuteOrganize(OrganizeRequest request, CancellationToken token)
        {
            if (request == null)
            {
                return new OperationCompletion(null, false, null);
            }
            // F1 (P0 audit): remember the in-flight request so a topology abort can rerun
            // it exactly once; any fresh user source re-arms the one-shot rerun latch.
            this.activeRequest = request;
            if (request.Source != TopologyRerunSource)
            {
                this.topologyRerunArmed = false;
            }
            if (token.IsCancellationRequested)
            {
                return new OperationCompletion(null, true, null);
            }
            // B4: publish the unit's token so the composed discovery/placement ports
            // (WMI sweep, UIA helper waits, guarded placement) observe cancellation
            // while this one serialized unit runs.
            this.ports.RunToken = token;
            MonitorInfo target = request.ResolveMonitorUnderCursor
                ? ResolveMonitorUnderCursor()
                : MonitorSelector.ResolveUnique(ports.Monitors.GetMonitors(), request.MonitorKey);
            if (target == null)
            {
                // The completion publisher shows the TopologyChanged notice on the UI thread.
                return new OperationCompletion(null, false, null);
            }
            try
            {
                AppSettings current = settings.Load();
                // B2: the canonical selector rides along (REQ-ID-004); its raw-title fallback is the legacy
                // string the controller falls back to when the selector is empty or does not resolve to one window.
                ManagerSelector selector = current.ManagerSelector == null ? ManagerSelector.None() : current.ManagerSelector;
                // B3: the full-set physical label (same derivation the menu rows use) and
                // the configured log path ride the run so the status can carry both.
                string monitorLabel = TrayMenuBuilder.DerivePhysicalLabel(target, ports.Monitors.GetMonitors());
                string logPath = string.IsNullOrEmpty(current.LogPath) ? SettingsStore.DefaultLogPath() : current.LogPath;
                // C3: the worker's pre-mutation choice flow — the saved policy is read
                // NOW (request start); the Ask dialog only appears after pure planning
                // proves overflow, marshalled through the B4 control (never a form from
                // this worker).
                // REQ-ID-004: the selector rides along so the run resolves the manager like the menu;
                // the string stays the raw-title fallback.
                OrganizeRunResult result = ports.Controller.RunWithChoice(target,
                    selector.IsEmpty ? null : selector.RawTitleFallback, monitorLabel, logPath,
                    current.OverflowPolicy, current.MergeEnabled,
                    delegate(PreparedOrganizeRun prepared, bool mergeEnabled)
                    {
                        return choiceAsker.Prompt(prepared, mergeEnabled, token);
                    },
                    SaveOverflowPolicy,
                    token, selector);
                if (result != null)
                {
                    this.lastResultText = result.Status != null ? result.Status.MenuSummary : result.ToString();
                }
                log.Append("organize monitor " + target.Number + " (" + request.Source + "): " + result);
                // B4: a token cancelled while the pipeline ran (exit during the UIA
                // wait) maps to a Cancelled completion — no notices, no rerun arming.
                if (token.IsCancellationRequested)
                {
                    return new OperationCompletion(result, true, null);
                }
                return new OperationCompletion(result, false, null);
            }
            catch (Exception ex)
            {
                log.Append("organize monitor " + target.Number + " (" + request.Source + ") failed: " + ex.Message);
                return new OperationCompletion(null, false, ex);
            }
        }

        /// <summary>D-4: the monitor under the cursor; the first attached monitor as fallback.</summary>
        private MonitorInfo ResolveMonitorUnderCursor()
        {
            System.Drawing.Point point = Cursor.Position;
            MonitorInfo[] monitors = ports.Monitors.GetMonitors();
            MonitorInfo target = null;
            foreach (MonitorInfo monitor in monitors)
            {
                if (monitor == null)
                {
                    continue;
                }
                bool inside = point.X >= monitor.MonitorLeft
                    && point.X < monitor.MonitorLeft + monitor.MonitorWidth
                    && point.Y >= monitor.MonitorTop
                    && point.Y < monitor.MonitorTop + monitor.MonitorHeight;
                if (inside)
                {
                    target = monitor;
                    break;
                }
            }
            if (target == null)
            {
                foreach (MonitorInfo monitor in monitors)
                {
                    if (monitor != null)
                    {
                        target = monitor;
                        break;
                    }
                }
            }
            return target;
        }

        /// <summary>Menu state (A5): organize entries disable when an operation starts; the menu refreshes when it returns to Idle.</summary>
        private void CoordinatorPhaseChanged(OperationPhase phase)
        {
            if (phase == OperationPhase.Acquiring)
            {
                DisableOrganizeMenuItems();
            }
            else if (phase == OperationPhase.Idle)
            {
                RebuildMenu();
            }
        }

        /// <summary>Marshalled completion (A5): the null-result shape shows TopologyChanged; a TopologyAborted result arms exactly one rerun (F1).</summary>
        private void OrganizeCompleted(OperationCompletion completion)
        {
            if (completion == null)
            {
                return;
            }
            if (completion.Error == null && !completion.Cancelled && completion.Result == null)
            {
                Notice(NoticeTable.Get(NoticeKind.TopologyChanged, null));
            }
            if (completion.Error == null && !completion.Cancelled
                && completion.Result != null && completion.Result.TopologyAborted
                && !this.topologyRerunArmed && this.activeRequest != null)
            {
                // A4's guard stopped the run mid-organize; the layout has settled, so ask
                // the coordinator for exactly one rerun of the same request (F1). The
                // latch keeps an aborting rerun from looping; a fresh user request
                // re-arms it in ExecuteOrganize.
                this.topologyRerunArmed = true;
                this.coordinator.Request(new OrganizeRequest(
                    this.activeRequest.MonitorKey,
                    this.activeRequest.ResolveMonitorUnderCursor,
                    TopologyRerunSource));
            }
        }

        /// <summary>Busy state (A5/B4): flip the existing items in place — no discovery, the
        /// banner says Organizing…, every mutating entry disables; Open log and Exit stay enabled.</summary>
        private void DisableOrganizeMenuItems()
        {
            if (this.menu == null)
            {
                return;
            }
            foreach (ToolStripItem item in this.menu.Items)
            {
                DisableOrganizeItem(item);
            }
        }

        /// <summary>B2 tree shape: the busy flip walks the dropdowns too; B4 widens it
        /// from the organize rows to EVERY mutating entry (manager mutations, overflow
        /// settings, labels) while the status banner flips to the busy text.</summary>
        private static void DisableOrganizeItem(ToolStripItem item)
        {
            TrayMenuEntry entry = item == null ? null : item.Tag as TrayMenuEntry;
            if (entry != null)
            {
                if (entry.Kind == TrayMenuEntryKind.Status)
                {
                    item.Text = TrayMenuBuilder.BusyStatusText;
                }
                if (IsMutatingEntry(entry.Kind))
                {
                    item.Enabled = false;
                }
            }
            ToolStripDropDownItem dropDown = item as ToolStripDropDownItem;
            if (dropDown != null)
            {
                foreach (ToolStripItem child in dropDown.DropDownItems)
                {
                    DisableOrganizeItem(child);
                }
            }
        }

        /// <summary>B4 busy UX: the entry kinds that mutate organize state or settings while a unit runs.</summary>
        private static bool IsMutatingEntry(TrayMenuEntryKind kind)
        {
            return kind == TrayMenuEntryKind.OrganizeUnderCursor
                || kind == TrayMenuEntryKind.OrganizeMonitor
                || kind == TrayMenuEntryKind.OrganizeMonitorRoot
                || kind == TrayMenuEntryKind.ManagerRoot
                || kind == TrayMenuEntryKind.ShowManager
                || kind == TrayMenuEntryKind.ClearManager
                || kind == TrayMenuEntryKind.SetManager
                || kind == TrayMenuEntryKind.OverflowRoot
                || kind == TrayMenuEntryKind.OverflowPolicy
                || kind == TrayMenuEntryKind.LabelsAndPrioritiesRoot
                || kind == TrayMenuEntryKind.LabelWindow;
        }

        /// <summary>
        /// B2 click-time selector creation: re-resolves the WindowMenuKey against a FRESH
        /// discovery (the menu payload HWND is short-lived — validate the whole
        /// WindowIdentity) and persists the canonical selector, never the display label.
        /// SPEC-TRAY-015 M3: the validation core is extracted (CreateValidatedManager)
        /// so the settings form's manager selection reuses the identical re-resolve.
        /// </summary>
        private void SetManagerFromMenu(WindowMenuKey key)
        {
            try
            {
                ManagerSelector created = CreateValidatedManager(key);
                if (created != null)
                {
                    SaveManagerSelector(created);
                }
            }
            catch (Exception ex)
            {
                log.Append("set manager failed: " + ex.Message);
            }
        }

        /// <summary>
        /// The B2 click-time validation core (shared by the menu path and the
        /// SPEC-TRAY-015 M3 settings form): re-resolves the key against a FRESH
        /// discovery and creates the canonical selector (with the user label when
        /// one is registered); null — with one log line — when the key carries no
        /// identity or no longer matches exactly one discovered window.
        /// </summary>
        private ManagerSelector CreateValidatedManager(WindowMenuKey key)
        {
            if (key == null || key.Identity == null)
            {
                log.Append("set manager skipped: menu identity missing");
                return null;
            }
            WindowSnapshot[] fresh = Composition.ReadWindowsForMenu(ports.Controller.Labels,
                delegate(string line) { log.Append(line); }).Snapshots;
            WindowSnapshot match = null;
            bool multiple = false;
            foreach (WindowSnapshot snapshot in fresh)
            {
                if (snapshot == null || snapshot.Identity == null)
                {
                    continue;
                }
                if (snapshot.Identity.EqualsForMutation(key.Identity))
                {
                    if (match != null)
                    {
                        multiple = true;
                        break;
                    }
                    match = snapshot;
                }
            }
            if (multiple || match == null)
            {
                log.Append("set manager skipped: window no longer matches its menu identity");
                return null;
            }
            string userLabel = ports.Controller.Labels.TryGetLabel(match.Handle);
            return ManagerResolver.CreateSelector(match, userLabel);
        }

        /// <summary>
        /// SPEC-TRAY-015 M3 (REQ-WIN-001): the settings form's manager selection — the
        /// menu path's click-time validation reused (CreateValidatedManager), persisted
        /// through the same existing static helper with the same log line, but with NO
        /// keep-open arming: the menu is closed while the form is up, and the one-shot
        /// flag must never be armed outside a live menu session (a leaked flag would
        /// swallow the next session's first item-activation close).
        /// </summary>
        internal void SelectManagerFromSettingsForm(WindowMenuKey key)
        {
            try
            {
                ManagerSelector created = CreateValidatedManager(key);
                if (created != null)
                {
                    SaveManagerSelectorTo(settings, created);
                    log.Append("manager window set to " + created.Kind + " '" + created.Value + "'");
                }
            }
            catch (Exception ex)
            {
                log.Append("set manager failed: " + ex.Message);
            }
        }

        /// <summary>
        /// B2 Show / flash: re-resolves the persisted selector at click time, restores a
        /// minimized window, then SetForegroundWindow + FlashWindowEx. Failures log and
        /// never mutate settings.
        /// </summary>
        private void ShowManagerWindow()
        {
            try
            {
                AppSettings current = settings.Load();
                ManagerSelector selector = current.ManagerSelector == null ? ManagerSelector.None() : current.ManagerSelector;
                if (selector.IsEmpty)
                {
                    return;
                }
                DiscoveredWindows discovered = Composition.ReadWindowsForMenu(ports.Controller.Labels,
                    delegate(string line) { log.Append(line); });
                ManagerResolution resolution = ManagerResolver.Resolve(selector, discovered.Facts, discovered.Snapshots);
                if (resolution.Status != ManagerResolutionStatus.Resolved)
                {
                    log.Append("show manager skipped: " + (resolution.Reason ?? resolution.Status.ToString()));
                    return;
                }
                IntPtr handle = resolution.Handle;
                if (ManagerNative.IsIconic(handle))
                {
                    ManagerNative.ShowWindow(handle, ManagerNative.SwRestore);
                }
                ManagerNative.SetForegroundWindow(handle);
                ManagerNative.FlashInfo flash = new ManagerNative.FlashInfo();
                flash.Size = (uint)Marshal.SizeOf(typeof(ManagerNative.FlashInfo));
                flash.Handle = handle;
                flash.Flags = ManagerNative.FlashAll | ManagerNative.FlashTimerNoFg;
                flash.Count = 3;
                ManagerNative.FlashWindowEx(ref flash);
                log.Append("show manager: " + selector);
            }
            catch (Exception ex)
            {
                log.Append("show manager failed: " + ex.Message);
            }
        }

        /// <summary>Sole-writer read-modify-write (spec D-3) for the canonical selector (B2): only the manager fields change.</summary>
        private void SaveManagerSelector(ManagerSelector selector)
        {
            ManagerSelector value = selector == null ? ManagerSelector.None() : selector;
            SaveManagerSelectorTo(settings, value);
            log.Append(value.IsEmpty
                ? "manager window cleared"
                : "manager window set to " + value.Kind + " '" + value.Value + "'");
            KeepMenuOpenWithSettingsUpdate();
        }

        /// <summary>
        /// C3 menu policy selection: saves immediately but does NOT organize — the next
        /// organize request (hotkey or menu) reads this saved policy at request start.
        /// </summary>
        private void SelectOverflowPolicy(string value)
        {
            SaveOverflowPolicy(ParsePolicyValue(value));
            KeepMenuOpenWithSettingsUpdate();
        }

        /// <summary>SPEC-TRAY-013 toggle (REQ-UI-001): save the negated value, flip the
        /// controller (stop-or-allow overlays, REQ-CTL-001), update the open menu in place
        /// (SPEC-TRAY-015 M1); never organizes.</summary>
        private void ToggleAttentionOverlay()
        {
            bool value = ToggleAttentionOverlayTo(settings);
            if (this.attention != null)
            {
                this.attention.SetEnabled(value);
            }
            log.Append(value ? "attention overlay enabled" : "attention overlay disabled");
            KeepMenuOpenWithSettingsUpdate();
        }

        /// <summary>SPEC-TRAY-015 M2 (REQ-IA-001; the TRAY-014 D-8 row re-presented): the
        /// Event policy radio row — save the clicked row's own token directly (radio
        /// selection replaces the cycle advance), apply to the controller, one log line,
        /// in-place update through the M1 machinery (REQ-STAY-001/002); never organizes.</summary>
        private void SelectAttentionEventPolicy(string value)
        {
            SaveAttentionEventPolicyTo(settings, value);
            if (this.attention != null)
            {
                this.attention.SetEventPolicy(value);
            }
            log.Append("attention overlay event policy set to " + value);
            KeepMenuOpenWithSettingsUpdate();
        }

        /// <summary>SPEC-TRAY-015 M2 (REQ-IA-001; the TRAY-014 D-9 row re-presented): the
        /// Stop blinks radio row — save the clicked row's own limit directly (radio
        /// selection replaces the cycle advance), apply, one log line, in-place update
        /// through the M1 machinery (REQ-STAY-001/002); never organizes.</summary>
        private void SelectAttentionStopBlinks(string value)
        {
            int limit;
            if (!int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out limit))
            {
                return;
            }
            SaveAttentionStopBlinksTo(settings, limit);
            if (this.attention != null)
            {
                this.attention.SetStopBlinkLimit(limit);
            }
            log.Append("attention overlay stop blinks set to "
                + limit.ToString(CultureInfo.InvariantCulture));
            KeepMenuOpenWithSettingsUpdate();
        }

        /// <summary>SPEC-TRAY-014 (the D-6 extension): the always-on-top row — save the negated
        /// value, apply to the controller (new creations pick it up; live rings keep their
        /// mode), one log line, in-place update (SPEC-TRAY-015 M1); never organizes.</summary>
        private void ToggleAttentionTopmost()
        {
            bool value = !settings.Load().AttentionOverlayTopmost;
            SaveAttentionTopmostTo(settings, value);
            if (this.attention != null)
            {
                this.attention.SetTopmost(value);
            }
            log.Append(value ? "attention overlay always on top enabled"
                : "attention overlay always on top disabled");
            KeepMenuOpenWithSettingsUpdate();
        }

        // @MX:NOTE: static toggle save so the round trip is testable (the SaveManagerSelectorTo pattern); carries every other field through.
        // SPEC-TRAY-014/016 REQ-SET-002: the toggle and the option saves each carry ALL SIX attention values.
        internal static bool ToggleAttentionOverlayTo(SettingsStore store)
        {
            AppSettings current = store.Load();
            bool value = !current.AttentionOverlay;
            SaveAttentionBundle(store, current, value, current.AttentionEventPolicy,
                current.AttentionStopBlinkLimit, current.AttentionOverlayTopmost,
                current.AttentionRemoteAlerts);
            return value;
        }

        /// <summary>SPEC-TRAY-014 D-8: persists the event policy (a cycle token from the submenu).</summary>
        internal static void SaveAttentionEventPolicyTo(SettingsStore store, string policy)
        {
            AppSettings current = store.Load();
            SaveAttentionBundle(store, current, current.AttentionOverlay,
                AttentionPolicyResolver.Parse(policy), current.AttentionStopBlinkLimit,
                current.AttentionOverlayTopmost, current.AttentionRemoteAlerts);
        }

        /// <summary>SPEC-TRAY-014 D-9: persists the stop blink limit (clamped 1..50 before it reaches here).</summary>
        internal static void SaveAttentionStopBlinksTo(SettingsStore store, int limit)
        {
            AppSettings current = store.Load();
            SaveAttentionBundle(store, current, current.AttentionOverlay, current.AttentionEventPolicy,
                SettingsStore.ClampBlinkLimit(limit), current.AttentionOverlayTopmost,
                current.AttentionRemoteAlerts);
        }

        /// <summary>SPEC-TRAY-014 (the D-6 extension): persists the always-on-top setting.</summary>
        internal static void SaveAttentionTopmostTo(SettingsStore store, bool topmost)
        {
            AppSettings current = store.Load();
            SaveAttentionBundle(store, current, current.AttentionOverlay, current.AttentionEventPolicy,
                current.AttentionStopBlinkLimit, topmost, current.AttentionRemoteAlerts);
        }

        /// <summary>v0.2.8: persists the remote-alerts level (a token from the settings form).</summary>
        internal static void SaveAttentionRemoteAlertsTo(SettingsStore store, string value)
        {
            AppSettings current = store.Load();
            SaveAttentionBundle(store, current, current.AttentionOverlay, current.AttentionEventPolicy,
                current.AttentionStopBlinkLimit, current.AttentionOverlayTopmost,
                SettingsStore.ParseRemoteAlerts(value));
        }

        /// <summary>The one read-modify-write every attention save funnels through (sole writer; all other fields carried).</summary>
        private static void SaveAttentionBundle(SettingsStore store, AppSettings current,
            bool enable, string policy, int limit, bool topmost, string remoteAlerts)
        {
            // SPEC-TRAY-016 (REQ-PREF-001) + v0.2.8: the fifth and sixth attention values
            // thread through the same construction — every attention save carries all six.
            store.Save(new AppSettings(current.Hotkey, current.LogPath, current.ManagerWindowName,
                current.MergeEnabled, current.FirstRunCompleted, current.StartWithWindows,
                current.ManagerSelector, current.PriorityOverrides, current.SchemaVersion,
                current.OverflowPolicy, current.CrossMonitorRedistribution, current.TitleRules,
                enable, policy, limit, topmost, current.AttentionInfoVisibleSeconds,
                current.UpdateAutoCheckEnabled, remoteAlerts));
        }

        /// <summary>The producer's signal directory (plan.md section J): %LOCALAPPDATA%\wsl-toast\attention.
        /// SPEC-TRAY-016 M1 (AM-1): the heartbeat writer's organizer.json lives in this same
        /// directory — the one sanctioned Windows-side writer beside the store's consume-delete;
        /// it never matches att-*.json and is never deleted (staleness is the signal).</summary>
        private static string AttentionSignalDirectory()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "wsl-toast", "attention");
        }

        /// <summary>
        /// C3 policy persistence (also the remember-choice callback from the worker):
        /// settings and log only — NO UI work, so it is safe on the worker thread (the
        /// menu rebuild happens on the UI thread at run completion or menu click).
        /// </summary>
        private void SaveOverflowPolicy(OverflowPolicy policy)
        {
            SaveOverflowPolicyTo(settings, policy);
            log.Append("overflow policy set to " + policy);
        }

        // @MX:NOTE: the two tray saves are static so the title-rules block they carry is testable (REQ-SET-002); both keep the block of the settings they read.
        // SPEC-TRAY-013 (plan.md F row 10) + SPEC-TRAY-014/016 (REQ-SET-002): both carry ALL SIX attention values
        // (and, since v0.2.8, the loaded update auto-check switch — the old chain re-derived it as true).
        internal static void SaveManagerSelectorTo(SettingsStore store, ManagerSelector selector)
        {
            ManagerSelector value = selector == null ? ManagerSelector.None() : selector;
            AppSettings current = store.Load();
            store.Save(new AppSettings(current.Hotkey, current.LogPath,
                value.IsEmpty ? null : value.RawTitleFallback,
                current.MergeEnabled, current.FirstRunCompleted, current.StartWithWindows, value,
                current.PriorityOverrides, current.SchemaVersion, current.OverflowPolicy,
                current.CrossMonitorRedistribution, current.TitleRules, current.AttentionOverlay,
                current.AttentionEventPolicy, current.AttentionStopBlinkLimit, current.AttentionOverlayTopmost,
                current.AttentionInfoVisibleSeconds, current.UpdateAutoCheckEnabled,
                current.AttentionRemoteAlerts));
        }

        internal static void SaveOverflowPolicyTo(SettingsStore store, OverflowPolicy policy)
        {
            AppSettings current = store.Load();
            store.Save(new AppSettings(current.Hotkey, current.LogPath, current.ManagerWindowName,
                current.MergeEnabled, current.FirstRunCompleted, current.StartWithWindows,
                current.ManagerSelector, current.PriorityOverrides, current.SchemaVersion,
                policy, policy == OverflowPolicy.Redistribute, current.TitleRules, current.AttentionOverlay,
                current.AttentionEventPolicy, current.AttentionStopBlinkLimit, current.AttentionOverlayTopmost,
                current.AttentionInfoVisibleSeconds, current.UpdateAutoCheckEnabled,
                current.AttentionRemoteAlerts));
        }

        /// <summary>The row value ids (B2 shipped) mapped back to the policy — the
        /// shell-side id-to-policy map, reused by the SPEC-TRAY-015 M3 settings form.
        /// A second map exists by design (TrayMenuBuilder.OverflowPolicyValue): the
        /// pure model keeps its own copy so it stays WinForms-free — the builder
        /// never depends back on this shell class.</summary>
        internal static OverflowPolicy ParsePolicyValue(string value)
        {
            if (string.Equals(value, "stackOnly", StringComparison.Ordinal))
            {
                return OverflowPolicy.Stack;
            }
            if (string.Equals(value, "merge", StringComparison.Ordinal))
            {
                return OverflowPolicy.Merge;
            }
            if (string.Equals(value, "moveLowest", StringComparison.Ordinal))
            {
                return OverflowPolicy.Redistribute;
            }
            return OverflowPolicy.Ask;
        }

        /// <summary>B2 Open log: launches the configured log file; failures log only.</summary>
        private void OpenLogFile()
        {
            try
            {
                AppSettings current = settings.Load();
                string path = string.IsNullOrEmpty(current.LogPath) ? SettingsStore.DefaultLogPath() : current.LogPath;
                if (File.Exists(path))
                {
                    Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
                }
                else
                {
                    log.Append("log file not found: " + path);
                }
            }
            catch (Exception ex)
            {
                log.Append("open log failed: " + ex.Message);
            }
        }

        /// <summary>D-1: run-scoped only; the label dies with the process.</summary>
        private void LabelWindow(IntPtr handle, string title)
        {
            string label = PromptForLabel(title);
            if (!string.IsNullOrEmpty(label))
            {
                ports.Controller.Labels.SetLabel(handle, label);
                log.Append("labeled window " + handle + " as '" + label + "'");
                RebuildMenu();
            }
        }

        /// <summary>v1 minimal one-line prompt (REQ-SHELL-001 label submenu; the only non-tray surface).</summary>
        private static string PromptForLabel(string title)
        {
            using (Form prompt = new Form())
            using (System.Windows.Forms.Label text = new System.Windows.Forms.Label())
            using (TextBox box = new TextBox())
            using (Button ok = new Button())
            using (Button cancel = new Button())
            {
                prompt.Width = 380;
                prompt.Height = 160;
                prompt.Text = "Label window";
                prompt.FormBorderStyle = FormBorderStyle.FixedDialog;
                prompt.StartPosition = FormStartPosition.CenterScreen;
                prompt.MinimizeBox = false;
                prompt.MaximizeBox = false;
                text.Left = 12;
                text.Top = 12;
                text.Width = 340;
                text.Text = "Session name for '" + title + "':";
                box.Left = 12;
                box.Top = 38;
                box.Width = 340;
                ok.Text = "OK";
                ok.Left = 276;
                ok.Top = 76;
                ok.Width = 80;
                ok.DialogResult = DialogResult.OK;
                cancel.Text = "Cancel";
                cancel.Left = 188;
                cancel.Top = 76;
                cancel.Width = 80;
                cancel.DialogResult = DialogResult.Cancel;
                prompt.Controls.Add(text);
                prompt.Controls.Add(box);
                prompt.Controls.Add(ok);
                prompt.Controls.Add(cancel);
                prompt.AcceptButton = ok;
                prompt.CancelButton = cancel;
                return prompt.ShowDialog() == DialogResult.OK ? box.Text.Trim() : null;
            }
        }

        /// <summary>
        /// SPEC-TRAY-020 D-6 (REQ-UPD-005/006): arms the one-shot delayed startup check
        /// on a WinForms timer (C3 — the only timer kind here). The tick stops the timer
        /// and runs the check on a background thread; the shell constructor and menu
        /// build NEVER wait on any git subprocess.
        /// </summary>
        // @MX:NOTE: [SPEC-TRAY-020] one-shot delayed startup check; behind-only notify (D-6), never a spawn or an exit.
        private void ArmStartupUpdateCheck()
        {
            if (!this.updateSupported)
            {
                // Not a repo checkout (release-zip install): nothing to compare against, so the
                // startup check stays silent - one log line, no timer, no balloon.
                this.log.Append("update: startup check skipped reason=not-a-repo-checkout");
                return;
            }
            this.startupUpdateTimer = new System.Windows.Forms.Timer();
            this.startupUpdateTimer.Interval = UpdateChecker.StartupCheckDelayMs;
            this.startupUpdateTimer.Tick += delegate
            {
                this.startupUpdateTimer.Stop();
                RunUpdateCheckOnBackground(HandleStartupUpdateCheckCompleted);
            };
            this.startupUpdateTimer.Start();
        }

        /// <summary>
        /// SPEC-TRAY-020 (REQ-UPD-006): one check on a background thread; the outcome
        /// marshals back through the message window (the C3 seam) — the UI thread never
        /// blocks on git and no completion touches WinForms from the worker.
        /// </summary>
        private void RunUpdateCheckOnBackground(Action<UpdateCheckOutcome> completion)
        {
            ThreadPool.QueueUserWorkItem(delegate(object state)
            {
                UpdateCheckOutcome outcome = this.updateChecker.Check();
                this.messageWindow.BeginInvoke(completion, new object[] { outcome });
            });
        }

        /// <summary>SPEC-TRAY-020 D-6: the startup completion — ONLY a Behind outcome
        /// balloons (the check already logged its one line on every path).</summary>
        private void HandleStartupUpdateCheckCompleted(UpdateCheckOutcome outcome)
        {
            if (outcome != null && outcome.Kind == UpdateCheckOutcomeKind.Behind)
            {
                ShowBalloon(UpdateNotices.TextFor(outcome), UpdateNotices.LevelFor(outcome));
            }
        }

        /// <summary>SPEC-TRAY-020 (REQ-UPD-004): the manual-check completion — every
        /// outcome balloons with its section-J text and level (the in-flight null is
        /// already logged and stays silent).</summary>
        private void HandleManualUpdateCheckCompleted(UpdateCheckOutcome outcome)
        {
            if (outcome == null)
            {
                return;
            }
            ShowBalloon(UpdateNotices.TextFor(outcome), UpdateNotices.LevelFor(outcome));
        }

        /// <summary>
        /// SPEC-TRAY-020 (REQ-UPD-007): the update-and-restart completion — on Behind the
        /// detached helper is spawned FIRST and the app then exits through the pinned
        /// sequence (spawn strictly before the exit; AC-011); every other outcome
        /// surfaces its notice and neither spawns nor exits.
        /// </summary>
        // @MX:WARN: [AUTO] real exit+restart surface — spawn-before-exit order is AC-011; the pinned exit steps themselves are unedited.
        // @MX:REASON: a spawn-after-exit or exit-without-spawn leaves the machine dark or the lock held.
        private void HandleUpdateAndRestartCompleted(UpdateCheckOutcome outcome)
        {
            switch (UpdateDecision.For(outcome))
            {
                case UpdateDecisionAction.SpawnHelperAndExit:
                    if (SpawnUpdateHelper())
                    {
                        RequestApplicationExit();
                    }
                    return;
                case UpdateDecisionAction.AlreadyUpToDate:
                    ShowBalloon(UpdateNotices.AlreadyUpToDateText, NoticeLevel.Information);
                    return;
                case UpdateDecisionAction.SurfaceReason:
                    ShowBalloon(UpdateNotices.TextFor(outcome), UpdateNotices.LevelFor(outcome));
                    return;
                default:
                    return;
            }
        }

        /// <summary>
        /// SPEC-TRAY-020 D-1 (REQ-UPD-009): spawns the detached repo-local helper through
        /// the %SystemRoot%-rooted absolute powershell.exe with -NoProfile
        /// -ExecutionPolicy Bypass -File, the four pinned parameters (repo root, exe
        /// path, app PID, log path), CreateNoWindow, UseShellExecute=false. A child
        /// process outlives its parent on Windows — the helper survives this app's exit
        /// and waits out the exe lock itself. False (with the reason surfaced) when the
        /// repo root is not a checkout or the start fails — the app then does not exit.
        /// </summary>
        private bool SpawnUpdateHelper()
        {
            try
            {
                string repoRoot = UpdateChecker.DeriveRepoRoot();
                if (repoRoot == null)
                {
                    log.Append("update: helper not spawned: not a repo checkout");
                    ShowBalloon("Update check failed (not a repo checkout). See the log for detail.", NoticeLevel.Error);
                    return false;
                }
                string script = Path.Combine(repoRoot, "tools", "update-helper.ps1");
                string exe = Process.GetCurrentProcess().MainModule.FileName;
                int appPid = Process.GetCurrentProcess().Id;
                string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\""
                    + " -RepoPath \"" + repoRoot + "\""
                    + " -ExePath \"" + exe + "\""
                    + " -AppPid " + appPid
                    + " -LogPath \"" + this.logPath + "\"";
                ProcessStartInfo start = new ProcessStartInfo(
                    Environment.ExpandEnvironmentVariables(UpdateChecker.HelperPowerShellExe), arguments);
                start.CreateNoWindow = true;
                start.UseShellExecute = false;
                using (Process helper = Process.Start(start))
                {
                    log.Append("update: helper spawned pid=" + (helper == null ? -1 : helper.Id));
                }
                return true;
            }
            catch (Exception ex)
            {
                log.Append("update: helper spawn failed: " + ex.Message);
                ShowBalloon("Update check failed (helper did not start). See the log for detail.", NoticeLevel.Error);
                return false;
            }
        }

        private void ExitApplication()
        {
            lifecycle.Exit(); // unregister, dispose icon, flush log — in that order (REQ-SHELL-003)
            log.Append("tray shell exiting");
            ExitThread();
        }

        private void DisposeIcon()
        {
            // B1 pinned order: hide and dispose the NotifyIcon BEFORE disposing the
            // owned application icon it renders.
            if (this.icon != null)
            {
                this.icon.Visible = false;
                this.icon.Dispose();
            }
            if (this.applicationIcon != null)
            {
                this.applicationIcon.Dispose();
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                // A5: stop accepting requests and cancel any in-flight unit BEFORE the UI
                // objects go away (the marshalling control dies with messageWindow below).
                this.coordinator.Dispose();
                // SPEC-TRAY-013: the controller's own pinned order applies inside (poll
                // timer, blink timer, in-flight marshals ignored, overlays disposed last).
                this.attention.Dispose();
                // SPEC-TRAY-015 M3: the owned settings form closes with the shell.
                if (this.settingsForm != null && !this.settingsForm.IsDisposed)
                {
                    this.settingsForm.Dispose();
                }
                DisposeIcon();
                if (this.menu != null)
                {
                    this.menu.Dispose();
                }
                this.messageWindow.Dispose();
            }
            base.Dispose(disposing);
        }

        /// <summary>The hidden message window receiving WM_HOTKEY (never shown).</summary>
        private sealed class HotkeyWindow : Form
        {
            private const int WmHotkey = 0x0312;
            private TrayLifecycle lifecycle;

            internal HotkeyWindow(TrayLifecycle lifecycle)
            {
                this.lifecycle = lifecycle;
                this.ShowInTaskbar = false;
                this.WindowState = FormWindowState.Minimized;
                this.FormBorderStyle = FormBorderStyle.None;
                this.Visible = false;
            }

            internal void Attach(TrayLifecycle attached)
            {
                this.lifecycle = attached;
            }

            protected override void WndProc(ref Message m)
            {
                if (m.Msg == WmHotkey && this.lifecycle != null && m.WParam.ToInt64() == TrayLifecycle.HotkeyId)
                {
                    this.lifecycle.DispatchHotkey();
                }
                base.WndProc(ref m);
            }
        }
    }
}
