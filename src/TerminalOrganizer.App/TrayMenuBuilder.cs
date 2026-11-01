using System;
using System.Collections.Generic;
using System.Globalization;
using TerminalOrganizer.Core.Assignment;
using TerminalOrganizer.Core.Monitors;
using TerminalOrganizer.Core.Windows;

namespace TerminalOrganizer.App
{
    /// <summary>What one menu entry does (REQ-SHELL-001; B2 hierarchical tree).</summary>
    public enum TrayMenuEntryKind
    {
        /// <summary>Informational disabled row (the Ready/Organizing banner, the no-monitors placeholder).</summary>
        Status,

        Separator,
        OrganizeUnderCursor,
        OrganizeMonitorRoot,
        OrganizeMonitor,
        ManagerRoot,
        ManagerCurrent,
        ShowManager,
        ClearManager,
        ManagerCandidateGroup,
        SetManager,
        OverflowRoot,
        OverflowPolicy,

        /// <summary>SPEC-TRAY-013: the root-level checkable attention-overlay toggle row.</summary>
        AttentionOverlay,

        /// <summary>SPEC-TRAY-014 D-8: the "Attention overlay" options submenu root.</summary>
        AttentionRoot,

        /// <summary>SPEC-TRAY-014 D-8: the enable toggle, first child of the submenu.</summary>
        AttentionEnabled,

        /// <summary>SPEC-TRAY-014 D-8: the event-policy cycle row.</summary>
        AttentionEventPolicy,

        /// <summary>SPEC-TRAY-014 D-8: the stop-blink cycle row.</summary>
        AttentionStopBlinks,

        /// <summary>SPEC-TRAY-014 D-8: the always-on-top checkable row.</summary>
        AttentionTopmost,
        LabelsAndPrioritiesRoot,
        LabelWindow,
        LastResult,
        OpenLog,
        Settings,
        Exit,

        /// <summary>Informational disabled product-version row (not flipped by the busy banner).</summary>
        Version
    }

    /// <summary>
    /// The menu payload for one window row (B2): the stable identity captured at menu
    /// build time. The handle alone is short-lived, so the click handler re-validates the
    /// whole identity through WindowIdentity before persisting a manager choice.
    /// Immutable.
    /// </summary>
    public sealed class WindowMenuKey
    {
        public WindowMenuKey(WindowIdentity identity)
        {
            Identity = identity;
        }

        public WindowIdentity Identity { get; private set; }
    }

    /// <summary>
    /// One menu entry as pure data (REQ-SHELL-001): the kind, the display label, the
    /// enabled and checked flags, the payload fields named by the kind (MonitorKey for
    /// organize entries, WindowKey for window entries, Value for policy rows), and the
    /// child rows of a submenu root. Immutable; arrays return copies. The legacy
    /// constructors (monitorNumber/windowHandle payloads) keep the B2-pre flat model
    /// shape alive for its pinned acceptance rows.
    /// </summary>
    public sealed class TrayMenuEntry
    {
        private readonly TrayMenuEntryKind kind;
        private readonly string label;
        private readonly bool enabled;
        private readonly bool checkedState;
        private readonly int monitorNumber;
        private readonly IntPtr windowHandle;
        private readonly MonitorKey monitorKey;
        private readonly WindowMenuKey windowKey;
        private readonly string value;
        private readonly TrayMenuEntry[] children;

        public TrayMenuEntry(TrayMenuEntryKind kind, string label, bool enabled, bool checkedState,
            MonitorKey monitorKey, WindowMenuKey windowKey, string value, TrayMenuEntry[] children)
        {
            this.kind = kind;
            this.label = label;
            this.enabled = enabled;
            this.checkedState = checkedState;
            this.monitorNumber = 0;
            this.windowHandle = IntPtr.Zero;
            this.monitorKey = monitorKey;
            this.windowKey = windowKey;
            this.value = value;
            this.children = children == null ? new TrayMenuEntry[0] : (TrayMenuEntry[])children.Clone();
        }

        public TrayMenuEntry(TrayMenuEntryKind kind, string label, int monitorNumber, IntPtr windowHandle)
            : this(kind, label, true, false, null, null, null, null, monitorNumber, windowHandle)
        {
        }

        public TrayMenuEntry(TrayMenuEntryKind kind, string label, int monitorNumber, IntPtr windowHandle, MonitorKey monitorKey)
            : this(kind, label, true, false, monitorKey, null, null, null, monitorNumber, windowHandle)
        {
        }

        public TrayMenuEntry(TrayMenuEntryKind kind, string label, int monitorNumber, IntPtr windowHandle,
            MonitorKey monitorKey, bool enabled)
            : this(kind, label, enabled, false, monitorKey, null, null, null, monitorNumber, windowHandle)
        {
        }

        private TrayMenuEntry(TrayMenuEntryKind kind, string label, bool enabled, bool checkedState,
            MonitorKey monitorKey, WindowMenuKey windowKey, string value, TrayMenuEntry[] children,
            int monitorNumber, IntPtr windowHandle)
        {
            this.kind = kind;
            this.label = label;
            this.enabled = enabled;
            this.checkedState = checkedState;
            this.monitorNumber = monitorNumber;
            this.windowHandle = windowHandle;
            this.monitorKey = monitorKey;
            this.windowKey = windowKey;
            this.value = value;
            this.children = children == null ? new TrayMenuEntry[0] : (TrayMenuEntry[])children.Clone();
        }

        public TrayMenuEntryKind Kind { get { return kind; } }
        public string Label { get { return label; } }
        public bool Enabled { get { return enabled; } }
        public bool Checked { get { return checkedState; } }
        public int MonitorNumber { get { return monitorNumber; } }
        public MonitorKey MonitorKey { get { return monitorKey; } }
        public IntPtr WindowHandle { get { return windowHandle; } }
        public WindowMenuKey WindowKey { get { return windowKey; } }

        /// <summary>The kind-named string payload (e.g. the policy id of an OverflowPolicy row).</summary>
        public string Value { get { return value; } }

        public TrayMenuEntry[] Children { get { return (TrayMenuEntry[])children.Clone(); } }

        public override string ToString()
        {
            return string.Format("{0}|{1}", kind, label);
        }
    }

    /// <summary>
    /// Everything one menu build needs (B2): the busy banner state, the hotkey display,
    /// the monitor set, the window snapshots (post label overlay), the persisted manager
    /// selector with its current resolution, the last organize summary, and the merge
    /// setting driving the merge row's checked state. Immutable; arrays return copies.
    /// </summary>
    public sealed class TrayMenuState
    {
        private readonly bool busy;
        private readonly string hotkeyDisplay;
        private readonly MonitorInfo[] monitors;
        private readonly WindowSnapshot[] windows;
        private readonly ManagerSelector managerSelector;
        private readonly ManagerResolution managerResolution;
        private readonly string lastResultText;
        private readonly bool mergeMenuEnabled;
        private readonly OverflowPolicy overflowPolicy;
        private readonly bool? attentionOverlay;
        private readonly bool hasAttentionOptions;
        private readonly string attentionEventPolicy;
        private readonly int attentionStopBlinkLimit;
        private readonly bool attentionOverlayTopmost;
        private readonly Dictionary<long, string> rowTexts;

        public TrayMenuState(bool busy, string hotkeyDisplay, MonitorInfo[] monitors, WindowSnapshot[] windows,
            ManagerSelector managerSelector, ManagerResolution managerResolution, string lastResultText, bool mergeMenuEnabled)
            : this(busy, hotkeyDisplay, monitors, windows, managerSelector, managerResolution,
                lastResultText, mergeMenuEnabled, OverflowPolicy.Ask)
        {
        }

        /// <summary>C3 form: also carries the persisted overflow policy driving the
        /// policy rows' checked state. The legacy constructor defaults to Ask and keeps the
        /// pre-attention root order (attention-era-unaware, like the 8-argument form).</summary>
        public TrayMenuState(bool busy, string hotkeyDisplay, MonitorInfo[] monitors, WindowSnapshot[] windows,
            ManagerSelector managerSelector, ManagerResolution managerResolution, string lastResultText,
            bool mergeMenuEnabled, OverflowPolicy overflowPolicy)
            : this(busy, hotkeyDisplay, monitors, windows, managerSelector, managerResolution,
                lastResultText, mergeMenuEnabled, overflowPolicy, null, (bool?)null)
        {
        }

        /// <summary>
        /// SPEC-RULES-009 form: also carries one priority row text per window, parallel to the windows array
        /// (RuleProvenance.RowTexts). With row texts, "Labels and priorities" lists every window; without them
        /// (the older constructors) it keeps listing only unidentified windows. States built here are
        /// attention-era: the toggle row renders checked (D-2 default ON).
        /// </summary>
        public TrayMenuState(bool busy, string hotkeyDisplay, MonitorInfo[] monitors, WindowSnapshot[] windows,
            ManagerSelector managerSelector, ManagerResolution managerResolution, string lastResultText,
            bool mergeMenuEnabled, OverflowPolicy overflowPolicy, string[] windowRowTexts)
            : this(busy, hotkeyDisplay, monitors, windows, managerSelector, managerResolution,
                lastResultText, mergeMenuEnabled, overflowPolicy, windowRowTexts, true)
        {
        }

        /// <summary>
        /// SPEC-TRAY-013 form: also carries the attention-overlay flag driving the toggle
        /// row's checked state (REQ-UI-001). The 10-argument constructor defaults the flag
        /// to true (D-2: default ON); the pre-SPEC-RULES-009 constructors keep the
        /// pre-attention root order (the same constructor-era scoping the row-texts
        /// overload uses, so every pinned legacy suite passes unedited). States built here
        /// render the FLAT toggle row (no options submenu).
        /// </summary>
        public TrayMenuState(bool busy, string hotkeyDisplay, MonitorInfo[] monitors, WindowSnapshot[] windows,
            ManagerSelector managerSelector, ManagerResolution managerResolution, string lastResultText,
            bool mergeMenuEnabled, OverflowPolicy overflowPolicy, string[] windowRowTexts,
            bool attentionOverlay)
            : this(busy, hotkeyDisplay, monitors, windows, managerSelector, managerResolution,
                lastResultText, mergeMenuEnabled, overflowPolicy, windowRowTexts, (bool?)attentionOverlay)
        {
        }

        /// <summary>
        /// SPEC-TRAY-014 options form (D-8): carries the full attention options bundle
        /// (enable, event policy, stop blink limit, always-on-top) and renders the
        /// "Attention overlay" submenu instead of the SPEC-TRAY-013-era flat row.
        /// </summary>
        public TrayMenuState(bool busy, string hotkeyDisplay, MonitorInfo[] monitors, WindowSnapshot[] windows,
            ManagerSelector managerSelector, ManagerResolution managerResolution, string lastResultText,
            bool mergeMenuEnabled, OverflowPolicy overflowPolicy, string[] windowRowTexts,
            bool attentionOverlay, string attentionEventPolicy, int attentionStopBlinkLimit,
            bool attentionOverlayTopmost)
            : this(busy, hotkeyDisplay, monitors, windows, managerSelector, managerResolution,
                lastResultText, mergeMenuEnabled, overflowPolicy, windowRowTexts, (bool?)attentionOverlay)
        {
            this.hasAttentionOptions = true;
            this.attentionEventPolicy = attentionEventPolicy == null
                ? AttentionPolicyResolver.DefaultPolicy : attentionEventPolicy;
            this.attentionStopBlinkLimit = attentionStopBlinkLimit;
            this.attentionOverlayTopmost = attentionOverlayTopmost;
        }

        private TrayMenuState(bool busy, string hotkeyDisplay, MonitorInfo[] monitors, WindowSnapshot[] windows,
            ManagerSelector managerSelector, ManagerResolution managerResolution, string lastResultText,
            bool mergeMenuEnabled, OverflowPolicy overflowPolicy, string[] windowRowTexts,
            bool? attentionOverlay)
        {
            if (windowRowTexts != null)
            {
                this.rowTexts = new Dictionary<long, string>();
                WindowSnapshot[] given = windows ?? new WindowSnapshot[0];
                for (int i = 0; i < given.Length && i < windowRowTexts.Length; i++)
                {
                    if (given[i] != null)
                    {
                        this.rowTexts[given[i].Handle.ToInt64()] = windowRowTexts[i];
                    }
                }
            }
            this.busy = busy;
            this.hotkeyDisplay = hotkeyDisplay;
            this.monitors = monitors == null ? new MonitorInfo[0] : (MonitorInfo[])monitors.Clone();
            this.windows = windows == null ? new WindowSnapshot[0] : (WindowSnapshot[])windows.Clone();
            this.managerSelector = managerSelector;
            this.managerResolution = managerResolution;
            this.lastResultText = lastResultText;
            this.mergeMenuEnabled = mergeMenuEnabled;
            this.overflowPolicy = overflowPolicy;
            this.attentionOverlay = attentionOverlay;
        }

        public bool Busy { get { return busy; } }
        public string HotkeyDisplay { get { return hotkeyDisplay; } }
        public MonitorInfo[] Monitors { get { return (MonitorInfo[])monitors.Clone(); } }
        public WindowSnapshot[] Windows { get { return (WindowSnapshot[])windows.Clone(); } }
        public ManagerSelector ManagerSelector { get { return managerSelector; } }
        public ManagerResolution ManagerResolution { get { return managerResolution; } }
        public string LastResultText { get { return lastResultText; } }
        public bool MergeMenuEnabled { get { return mergeMenuEnabled; } }

        /// <summary>The persisted overflow policy (C3); Ask on the legacy constructor.</summary>
        public OverflowPolicy OverflowPolicy { get { return overflowPolicy; } }

        /// <summary>True when this state is attention-era (the SPEC-RULES-009 or SPEC-TRAY-013 constructors) and the toggle row renders.</summary>
        public bool HasAttentionOverlay { get { return attentionOverlay.HasValue; } }

        /// <summary>The SPEC-TRAY-013 attention-overlay setting driving the toggle row's checked state; absent reads as true (D-2 default ON).</summary>
        public bool AttentionOverlay { get { return attentionOverlay ?? true; } }

        /// <summary>True when this state carries the SPEC-TRAY-014 options bundle and the submenu renders instead of the flat row.</summary>
        public bool HasAttentionOptions { get { return hasAttentionOptions; } }

        /// <summary>The SPEC-TRAY-014 event policy; mixed outside the options era.</summary>
        public string AttentionEventPolicy
        {
            get { return attentionEventPolicy ?? AttentionPolicyResolver.DefaultPolicy; }
        }

        /// <summary>The SPEC-TRAY-014 stop blink limit as loaded (clamped 1..50); 10 outside the options era.</summary>
        public int AttentionStopBlinkLimit
        {
            get { return attentionStopBlinkLimit; }
        }

        /// <summary>The SPEC-TRAY-014 always-on-top setting; false outside the options era.</summary>
        public bool AttentionOverlayTopmost { get { return attentionOverlayTopmost; } }

        /// <summary>True when the state carries priority row texts (the SPEC-RULES-009 constructor).</summary>
        public bool HasRowTexts { get { return rowTexts != null; } }

        /// <summary>The row text of one window by handle; null when the state carries none for it.</summary>
        public string RowTextFor(WindowSnapshot window)
        {
            string text;
            if (rowTexts == null || window == null || !rowTexts.TryGetValue(window.Handle.ToInt64(), out text))
            {
                return null;
            }
            return text;
        }
    }

    /// <summary>
    /// Builds the tray context-menu model (REQ-SHELL-001; B2 hierarchical tree): the
    /// pinned root order Status .. Exit with physical-monitor rows under "Organize
    /// monitor", the canonical manager rows under "Manager", the settings-shaped
    /// overflow rows, and the unidentified-window rows under "Labels and priorities".
    /// Pure data — no WinForms types; the shell binds this model to a ContextMenuStrip
    /// (morning-checklist surface). The legacy flat-model overloads stay for their
    /// pinned acceptance rows.
    /// </summary>
    public static class TrayMenuBuilder
    {
        /// <summary>At this many manager candidates the Choose-manager submenu switches to the five deterministic buckets.</summary>
        private const int BucketThreshold = 15;

        /// <summary>The B4 busy banner (the runtime in-place flip and the built model share it).</summary>
        internal const string BusyStatusText = "Organizing…";

        // @MX:ANCHOR: [AUTO] the B2 hierarchical menu model the tray shell renders.
        // @MX:REASON: root order, physical labels and manager rows are pinned product behavior; every menu rebuild funnels through this call.
        public static TrayMenuEntry[] Build(TrayMenuState state)
        {
            List<TrayMenuEntry> entries = new List<TrayMenuEntry>();
            if (state == null)
            {
                return entries.ToArray();
            }
            bool busy = state.Busy;
            List<MonitorInfo> monitors = CollectMonitors(state.Monitors);
            List<WindowSnapshot> snapshots = CollectSnapshots(state.Windows);
            ManagerSelector selector = state.ManagerSelector == null ? ManagerSelector.None() : state.ManagerSelector;

            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.Status,
                busy ? BusyStatusText : "TerminalOrganizer — Ready", false, false, null, null, null, null));
            entries.Add(Separator());
            string hotkeySuffix = string.IsNullOrEmpty(state.HotkeyDisplay)
                ? string.Empty : "    " + state.HotkeyDisplay;
            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.OrganizeUnderCursor,
                "Organize monitor under cursor" + hotkeySuffix, !busy, false, null, null, null, null));
            entries.Add(Separator());
            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.OrganizeMonitorRoot, "Organize monitor",
                !busy, false, null, null, null, BuildMonitorChildren(monitors, busy)));
            entries.Add(Separator());
            // B4 busy UX: while phase != Idle every MUTATING root disables (manager
            // mutations, overflow settings, labels); Open log and Exit stay enabled.
            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.ManagerRoot, "Manager", !busy, false, null, null, null,
                BuildManagerChildren(selector, state.ManagerResolution, CollectCandidates(snapshots))));
            entries.Add(Separator());
            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.OverflowRoot, "Overflow behavior", !busy, false, null, null, null,
                BuildOverflowChildren(state.OverflowPolicy)));
            entries.Add(Separator());
            // SPEC-TRAY-013 REQ-UI-001 / SPEC-TRAY-014 D-8: the attention surface sits
            // between the Overflow root and the Labels-and-priorities root, enabled
            // regardless of busy (a display preference: same UI-thread sole-writer
            // read-modify-write as the overflow rows, mutates no organize state). Era
            // scoping: the options bundle renders the submenu; the SPEC-TRAY-013-era
            // constructor keeps the flat checkable row; pre-attention constructors keep
            // the pre-attention root order (every pinned legacy suite passes unedited).
            if (state.HasAttentionOptions)
            {
                entries.Add(new TrayMenuEntry(TrayMenuEntryKind.AttentionRoot, "Attention overlay",
                    true, false, null, null, null, BuildAttentionChildren(state)));
                entries.Add(Separator());
            }
            else if (state.HasAttentionOverlay)
            {
                entries.Add(new TrayMenuEntry(TrayMenuEntryKind.AttentionOverlay, "Attention overlay",
                    true, state.AttentionOverlay, null, null, null, null));
                entries.Add(Separator());
            }
            TrayMenuEntry[] labelRows = BuildLabelChildren(snapshots, state);
            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.LabelsAndPrioritiesRoot, "Labels and priorities",
                labelRows.Length > 0 && !busy, false, null, null, null, labelRows));
            entries.Add(Separator());
            string lastResult = state.LastResultText;
            // B3: the stored value is a full MenuSummary (already "Last result: "-prefixed);
            // the never-run placeholder is pinned ("Last result: Not run yet").
            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.LastResult,
                string.IsNullOrEmpty(lastResult) ? "Last result: Not run yet" : lastResult,
                false, false, null, null, lastResult, null));
            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.OpenLog, "Open log", true, false, null, null, null, null));
            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.Settings, "Settings…", false, false, null, null, null, null));
            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.Version, AppVersion.DisplayName, false, false, null, null, null, null));
            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.Exit, "Exit", true, false, null, null, null, null));
            return entries.ToArray();
        }

        /// <summary>
        /// The B2 physical label: a position word relative to the union of all monitor
        /// rectangles (no enumeration number ever appears), " (Primary)" for the primary
        /// monitor, then " — W×H" in invariant formatting; colliding labels get
        /// the final eight characters of the stable key in brackets.
        /// </summary>
        public static string DerivePhysicalLabel(MonitorInfo target, MonitorInfo[] allMonitors)
        {
            if (target == null)
            {
                return string.Empty;
            }
            List<MonitorInfo> valid = CollectMonitors(allMonitors);
            if (!ContainsKey(valid, target.StableKey))
            {
                valid.Add(target);
            }
            string label = BuildBaseLabel(target, valid);
            if (Collides(label, target, valid))
            {
                string suffix = StableKeySuffix(target);
                if (suffix != null)
                {
                    label = label + " [" + suffix + "]";
                }
            }
            return label;
        }

        /// <summary>The B2 candidate label: the first tab title plus " (+N tabs)" for the additional tabs.</summary>
        public static string DisplayWindowCandidate(WindowSnapshot window)
        {
            if (window == null)
            {
                return string.Empty;
            }
            TabSnapshot[] tabs = window.Tabs;
            string title = tabs.Length > 0 && tabs[0] != null ? tabs[0].Title : null;
            if (string.IsNullOrEmpty(title))
            {
                return string.Format("Window {0}", window.Handle);
            }
            if (tabs.Length > 1)
            {
                return title + " (+" + (tabs.Length - 1).ToString(CultureInfo.InvariantCulture) + " tabs)";
            }
            return title;
        }

        /// <summary>Legacy flat model (B2-pre, REQ-SHELL-001): one Organize-on-Monitor-N row per attached monitor.</summary>
        public static TrayMenuEntry[] Build(MonitorInfo[] monitors, WindowSnapshot[] windows)
        {
            return Build(monitors, windows, false);
        }

        /// <summary>Legacy flat model (B2-pre): the busy overload disables the organize entries; Exit always stays enabled.</summary>
        /// <param name="busy">True while an organize operation is serialized: organize entries come out disabled.</param>
        public static TrayMenuEntry[] Build(MonitorInfo[] monitors, WindowSnapshot[] windows, bool busy)
        {
            List<TrayMenuEntry> entries = new List<TrayMenuEntry>();

            List<MonitorInfo> monitorList = CollectMonitors(monitors);
            foreach (MonitorInfo monitor in monitorList)
            {
                entries.Add(new TrayMenuEntry(TrayMenuEntryKind.OrganizeMonitor,
                    string.Format("Organize on Monitor {0}", monitor.Number), monitor.Number, IntPtr.Zero,
                    monitor.StableKey, !busy));
            }

            if (windows != null)
            {
                foreach (WindowSnapshot window in windows)
                {
                    if (window != null && window.Identified)
                    {
                        entries.Add(new TrayMenuEntry(TrayMenuEntryKind.SetManager, DisplayName(window), 0, window.Handle));
                    }
                }
                foreach (WindowSnapshot window in windows)
                {
                    if (window != null && !window.Identified)
                    {
                        entries.Add(new TrayMenuEntry(TrayMenuEntryKind.LabelWindow, DisplayName(window), 0, window.Handle));
                    }
                }
            }

            entries.Add(new TrayMenuEntry(TrayMenuEntryKind.Exit, "Exit", 0, IntPtr.Zero));
            return entries.ToArray();
        }

        /// <summary>Legacy flat-model display name: the first tab title; the handle when there is no title.</summary>
        private static string DisplayName(WindowSnapshot window)
        {
            TabSnapshot[] tabs = window.Tabs;
            if (tabs.Length > 0 && !string.IsNullOrEmpty(tabs[0].Title))
            {
                return tabs[0].Title;
            }
            return string.Format("Window {0}", window.Handle);
        }

        private static TrayMenuEntry Separator()
        {
            return new TrayMenuEntry(TrayMenuEntryKind.Separator, "-", false, false, null, null, null, null);
        }

        private static TrayMenuEntry[] BuildMonitorChildren(List<MonitorInfo> monitors, bool busy)
        {
            if (monitors.Count == 0)
            {
                return new TrayMenuEntry[]
                {
                    new TrayMenuEntry(TrayMenuEntryKind.Status, "No attached monitors", false, false, null, null, null, null)
                };
            }
            MonitorInfo[] array = monitors.ToArray();
            List<TrayMenuEntry> rows = new List<TrayMenuEntry>();
            foreach (MonitorInfo monitor in array)
            {
                rows.Add(new TrayMenuEntry(TrayMenuEntryKind.OrganizeMonitor,
                    DerivePhysicalLabel(monitor, array), !busy, false, monitor.StableKey, null, null, null));
            }
            return rows.ToArray();
        }

        private static TrayMenuEntry[] BuildManagerChildren(ManagerSelector selector,
            ManagerResolution resolution, List<WindowSnapshot> candidates)
        {
            ManagerResolution status = resolution;
            if (status == null)
            {
                status = new ManagerResolution(ManagerResolutionStatus.None, null, IntPtr.Zero, 0, null);
            }
            List<TrayMenuEntry> children = new List<TrayMenuEntry>();
            children.Add(new TrayMenuEntry(TrayMenuEntryKind.ManagerCurrent,
                CurrentManagerLabel(selector, status), false, false, null, null, null, null));
            children.Add(new TrayMenuEntry(TrayMenuEntryKind.ShowManager, "Show / flash manager",
                status.Status == ManagerResolutionStatus.Resolved, false, null, null, null, null));
            children.Add(new TrayMenuEntry(TrayMenuEntryKind.ClearManager, "Clear manager",
                !selector.IsEmpty, false, null, null, null, null));
            children.Add(Separator());
            children.Add(new TrayMenuEntry(TrayMenuEntryKind.ManagerCandidateGroup, "Choose manager",
                candidates.Count > 0, false, null, null, null, BuildCandidateChildren(candidates, selector)));
            return children.ToArray();
        }

        private static string CurrentManagerLabel(ManagerSelector selector, ManagerResolution resolution)
        {
            if (selector.IsEmpty)
            {
                return "Current: None";
            }
            string text = "Current: " + selector.Value;
            if (resolution.Status == ManagerResolutionStatus.Ambiguous)
            {
                return text + " — ambiguous ("
                    + resolution.CandidateCount.ToString(CultureInfo.InvariantCulture) + " windows)";
            }
            if (resolution.Status == ManagerResolutionStatus.NotFound)
            {
                return text + " — not found";
            }
            if (resolution.Status == ManagerResolutionStatus.FullScreen)
            {
                return text + " — full screen";
            }
            if (resolution.Status == ManagerResolutionStatus.Unidentified)
            {
                return text + " — unidentified";
            }
            return text;
        }

        private static TrayMenuEntry[] BuildCandidateChildren(List<WindowSnapshot> candidates, ManagerSelector persisted)
        {
            List<TrayMenuEntry> rows = new List<TrayMenuEntry>();
            AppendCandidateRows(candidates, persisted, rows);
            if (candidates.Count < BucketThreshold)
            {
                return rows.ToArray();
            }
            List<TrayMenuEntry>[] buckets = new List<TrayMenuEntry>[5];
            for (int i = 0; i < buckets.Length; i++)
            {
                buckets[i] = new List<TrayMenuEntry>();
            }
            for (int i = 0; i < rows.Count; i++)
            {
                buckets[BucketIndex(rows[i].Label)].Add(rows[i]);
            }
            string[] names = { "A–F", "G–L", "M–R", "S–Z", "#" };
            TrayMenuEntry[] groups = new TrayMenuEntry[5];
            for (int i = 0; i < groups.Length; i++)
            {
                groups[i] = new TrayMenuEntry(TrayMenuEntryKind.ManagerCandidateGroup, names[i],
                    buckets[i].Count > 0, false, null, null, null, buckets[i].ToArray());
            }
            return groups;
        }

        private static void AppendCandidateRows(List<WindowSnapshot> candidates, ManagerSelector persisted, List<TrayMenuEntry> rows)
        {
            foreach (WindowSnapshot candidate in candidates)
            {
                // Checked state (B2): the candidate whose newly created selector equals the persisted one.
                ManagerSelector created = ManagerResolver.CreateSelector(candidate, ManagerResolver.DeriveUserLabel(candidate));
                rows.Add(new TrayMenuEntry(TrayMenuEntryKind.SetManager, DisplayWindowCandidate(candidate),
                    true, persisted != null && persisted.Equals(created), null,
                    new WindowMenuKey(candidate.Identity), null, null));
            }
        }

        /// <summary>Bucket by the first invariant-uppercase character of the display text; empty/non-letter goes to #.</summary>
        private static int BucketIndex(string displayText)
        {
            if (string.IsNullOrEmpty(displayText))
            {
                return 4;
            }
            char first = char.ToUpper(displayText[0], CultureInfo.InvariantCulture);
            if (first >= 'A' && first <= 'F') return 0;
            if (first >= 'G' && first <= 'L') return 1;
            if (first >= 'M' && first <= 'R') return 2;
            if (first >= 'S' && first <= 'Z') return 3;
            return 4;
        }

        /// <summary>
        /// The SPEC-TRAY-014 pure policy cycle (plan.md A-8, D-8): Mixed -> All ->
        /// Notifications only -> Mixed; any other value (including null) enters the
        /// pinned order at its start. Deterministic; never throws.
        /// </summary>
        // @MX:NOTE: the pinned cycle order; changing it is a SPEC amendment.
        public static string NextPolicy(string current)
        {
            if (string.Equals(current, AttentionPolicyResolver.PolicyMixed, StringComparison.Ordinal))
            {
                return AttentionPolicyResolver.PolicyAll;
            }
            if (string.Equals(current, AttentionPolicyResolver.PolicyAll, StringComparison.Ordinal))
            {
                return AttentionPolicyResolver.PolicyNotifications;
            }
            return AttentionPolicyResolver.PolicyMixed;
        }

        /// <summary>
        /// The SPEC-TRAY-014 pure blink-limit cycle (plan.md A-8, D-9): 5 -> 10 -> 20 -> 5;
        /// a non-cycle value (any integer from the file, e.g. 7) enters the order at its
        /// start. Deterministic.
        /// </summary>
        // @MX:NOTE: the pinned cycle order; changing it is a SPEC amendment.
        public static int NextBlinkLimit(int current)
        {
            if (current == 5)
            {
                return 10;
            }
            if (current == 10)
            {
                return 20;
            }
            return 5;
        }

        /// <summary>The submenu's four children (D-8): Enabled, Event policy, Stop blinks, Always on top.</summary>
        private static TrayMenuEntry[] BuildAttentionChildren(TrayMenuState state)
        {
            return new TrayMenuEntry[]
            {
                new TrayMenuEntry(TrayMenuEntryKind.AttentionEnabled, "Enabled",
                    true, state.AttentionOverlay, null, null, null, null),
                new TrayMenuEntry(TrayMenuEntryKind.AttentionEventPolicy,
                    "Event policy: " + PolicyDisplayName(state.AttentionEventPolicy),
                    true, false, null, null, state.AttentionEventPolicy, null),
                new TrayMenuEntry(TrayMenuEntryKind.AttentionStopBlinks,
                    "Stop blinks: " + state.AttentionStopBlinkLimit.ToString(CultureInfo.InvariantCulture),
                    true, false, null, null, state.AttentionStopBlinkLimit.ToString(CultureInfo.InvariantCulture), null),
                new TrayMenuEntry(TrayMenuEntryKind.AttentionTopmost, "Always on top",
                    true, state.AttentionOverlayTopmost, null, null, null, null)
            };
        }

        /// <summary>The display name of one policy token (the raw token as the fallback).</summary>
        private static string PolicyDisplayName(string policy)
        {
            if (string.Equals(policy, AttentionPolicyResolver.PolicyMixed, StringComparison.Ordinal))
            {
                return "Mixed";
            }
            if (string.Equals(policy, AttentionPolicyResolver.PolicyAll, StringComparison.Ordinal))
            {
                return "All";
            }
            if (string.Equals(policy, AttentionPolicyResolver.PolicyNotifications, StringComparison.Ordinal))
            {
                return "Notifications only";
            }
            return policy == null ? string.Empty : policy;
        }

        private static TrayMenuEntry[] BuildOverflowChildren(OverflowPolicy policy)
        {
            // C3: the four persisted policies — exactly one checked (the saved policy),
            // selection saves immediately and never organizes. Merge ships DISABLED
            // while the release gate is closed (a saved-but-disabled Merge stays
            // checked; the run degrades to Stack with one warning).
            return new TrayMenuEntry[]
            {
                new TrayMenuEntry(TrayMenuEntryKind.OverflowPolicy, "Ask before overflow actions",
                    true, policy == OverflowPolicy.Ask, null, null, "ask", null),
                new TrayMenuEntry(TrayMenuEntryKind.OverflowPolicy, "Stack only",
                    true, policy == OverflowPolicy.Stack, null, null, "stackOnly", null),
                new TrayMenuEntry(TrayMenuEntryKind.OverflowPolicy, "Merge eligible tmux windows",
                    false, policy == OverflowPolicy.Merge, null, null, "merge", null),
                new TrayMenuEntry(TrayMenuEntryKind.OverflowPolicy, "Move lowest-priority windows to free zones…",
                    true, policy == OverflowPolicy.Redistribute, null, null, "moveLowest", null)
            };
        }

        private static TrayMenuEntry[] BuildLabelChildren(List<WindowSnapshot> snapshots, TrayMenuState state)
        {
            List<TrayMenuEntry> rows = new List<TrayMenuEntry>();
            if (state != null && state.HasRowTexts)
            {
                // SPEC-RULES-009 REQ-UI-001: every discovered window, one row of rank and provenance text. A window
                // with canonical session evidence is informational (disabled); every other row keeps the label
                // action, which prompts with the plain display text carried in Value.
                foreach (WindowSnapshot snapshot in snapshots)
                {
                    string text = state.RowTextFor(snapshot) ?? DisplayWindowCandidate(snapshot);
                    rows.Add(new TrayMenuEntry(TrayMenuEntryKind.LabelWindow, text,
                        !RuleProvenance.HasCanonicalSessionEvidence(snapshot), false, null,
                        new WindowMenuKey(snapshot.Identity), DisplayWindowCandidate(snapshot), null));
                }
                return rows.ToArray();
            }
            foreach (WindowSnapshot snapshot in snapshots)
            {
                if (snapshot != null && !snapshot.Identified)
                {
                    rows.Add(new TrayMenuEntry(TrayMenuEntryKind.LabelWindow, DisplayWindowCandidate(snapshot),
                        true, false, null, new WindowMenuKey(snapshot.Identity), null, null));
                }
            }
            return rows.ToArray();
        }

        /// <summary>Base label (no collision suffix): position word, " (Primary)", then " — W×H".</summary>
        private static string BuildBaseLabel(MonitorInfo target, List<MonitorInfo> valid)
        {
            string label = PositionName(target, valid);
            if (target.Primary)
            {
                label = label + " (Primary)";
            }
            return label + " — " + target.MonitorWidth.ToString(CultureInfo.InvariantCulture)
                + "×" + target.MonitorHeight.ToString(CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// The position word: target center relative to the union center, normalized to
        /// [-1, 1] against the union half-extent — corners when both axes exceed 0.25,
        /// otherwise the dominant axis against the 0.10 threshold (screen Y grows down:
        /// positive ny is Below).
        /// </summary>
        private static string PositionName(MonitorInfo target, List<MonitorInfo> valid)
        {
            int left = int.MaxValue, top = int.MaxValue, right = int.MinValue, bottom = int.MinValue;
            foreach (MonitorInfo monitor in valid)
            {
                if (monitor.MonitorLeft < left) left = monitor.MonitorLeft;
                if (monitor.MonitorTop < top) top = monitor.MonitorTop;
                int monitorRight = monitor.MonitorLeft + monitor.MonitorWidth;
                int monitorBottom = monitor.MonitorTop + monitor.MonitorHeight;
                if (monitorRight > right) right = monitorRight;
                if (monitorBottom > bottom) bottom = monitorBottom;
            }
            double unionWidth = right - left;
            double unionHeight = bottom - top;
            if (unionWidth <= 0 || unionHeight <= 0)
            {
                return "Center";
            }
            double nx = (target.MonitorLeft + target.MonitorWidth / 2.0 - (left + unionWidth / 2.0)) / (unionWidth / 2.0);
            double ny = (target.MonitorTop + target.MonitorHeight / 2.0 - (top + unionHeight / 2.0)) / (unionHeight / 2.0);
            if (Math.Abs(nx) > 0.25 && Math.Abs(ny) > 0.25)
            {
                if (nx < 0) return ny < 0 ? "Upper left" : "Lower left";
                return ny < 0 ? "Upper right" : "Lower right";
            }
            if (Math.Abs(nx) >= Math.Abs(ny))
            {
                if (nx < -0.10) return "Left";
                if (nx > 0.10) return "Right";
                return "Center";
            }
            if (ny < -0.10) return "Above";
            if (ny > 0.10) return "Below";
            return "Center";
        }

        private static bool Collides(string baseLabel, MonitorInfo target, List<MonitorInfo> valid)
        {
            foreach (MonitorInfo monitor in valid)
            {
                if (monitor.StableKey.EqualsKey(target.StableKey))
                {
                    continue;
                }
                if (string.Equals(BuildBaseLabel(monitor, valid), baseLabel, StringComparison.Ordinal))
                {
                    return true;
                }
            }
            return false;
        }

        /// <summary>The final eight characters of the stable key; null when the monitor has no stable key (never the monitor number).</summary>
        private static string StableKeySuffix(MonitorInfo monitor)
        {
            string canonical = monitor.StableKey == null ? null : monitor.StableKey.CanonicalValue;
            if (string.IsNullOrEmpty(canonical))
            {
                return null;
            }
            return canonical.Length <= 8 ? canonical : canonical.Substring(canonical.Length - 8);
        }

        private static bool ContainsKey(List<MonitorInfo> monitors, MonitorKey key)
        {
            foreach (MonitorInfo monitor in monitors)
            {
                if (monitor.StableKey.EqualsKey(key))
                {
                    return true;
                }
            }
            return false;
        }

        private static List<MonitorInfo> CollectMonitors(MonitorInfo[] monitors)
        {
            List<MonitorInfo> result = new List<MonitorInfo>();
            if (monitors != null)
            {
                foreach (MonitorInfo monitor in monitors)
                {
                    if (monitor != null)
                    {
                        result.Add(monitor);
                    }
                }
            }
            result.Sort(new Comparison<MonitorInfo>(CompareByNumber));
            return result;
        }

        private static List<WindowSnapshot> CollectSnapshots(WindowSnapshot[] windows)
        {
            List<WindowSnapshot> result = new List<WindowSnapshot>();
            if (windows != null)
            {
                foreach (WindowSnapshot window in windows)
                {
                    if (window != null)
                    {
                        result.Add(window);
                    }
                }
            }
            return result;
        }

        private static List<WindowSnapshot> CollectCandidates(List<WindowSnapshot> snapshots)
        {
            List<WindowSnapshot> candidates = new List<WindowSnapshot>();
            foreach (WindowSnapshot snapshot in snapshots)
            {
                if (ManagerResolver.HasIdentityName(snapshot))
                {
                    candidates.Add(snapshot);
                }
            }
            return candidates;
        }

        private static int CompareByNumber(MonitorInfo a, MonitorInfo b)
        {
            return a.Number.CompareTo(b.Number);
        }
    }
}
