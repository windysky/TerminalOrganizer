using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;
using TerminalOrganizer.Core.Assignment;
using TerminalOrganizer.Core.Overflow;
using TerminalOrganizer.Core.Rules;

namespace TerminalOrganizer.App
{
    /// <summary>
    /// The loaded settings (REQ-SET-001, spec D-3): the hotkey string, the log path, and
    /// the manager choice riding the same file with SPEC-ZONE-005 ManagerStore semantics
    /// (ManagerWindowName keeps the legacy raw-title view; ManagerSelector is the B2
    /// canonical identity), the B1 onboarding flags (firstRunCompleted,
    /// startWithWindows — the latter retained for a later startup unit), and the C3
    /// schema-v2 overflow fields: the persisted OverflowPolicy (unknown text loads as
    /// Ask) and the CrossMonitorRedistribution mirror (maintained true exactly while the
    /// policy is Redistribute). MergeEnabled stays the A1 release gate and is NEVER
    /// turned on by the policy. Immutable; callers build a modified copy for the
    /// read-modify-write save.
    /// </summary>
    public sealed class AppSettings
    {
        /// <summary>The settings schema version written by default (3 since SPEC-RULES-009: the title-rules block).</summary>
        public const int DefaultSchemaVersion = 3;

        private readonly string hotkey;
        private readonly string logPath;
        private readonly string managerWindowName;
        private readonly bool firstRunCompleted;
        private readonly bool startWithWindows;
        private readonly ManagerSelector managerSelector;
        private readonly PriorityOverride[] priorityOverrides;
        private readonly int schemaVersion;
        private readonly OverflowPolicy overflowPolicy;
        private readonly bool crossMonitorRedistribution;
        private readonly TitleRulesSettings titleRules;
        private readonly bool attentionOverlay;
        private readonly string attentionEventPolicy;
        private readonly int attentionStopBlinkLimit;
        private readonly bool attentionOverlayTopmost;
        private readonly int attentionInfoVisibleSeconds;
        private readonly bool updateAutoCheckEnabled;

        public AppSettings(string hotkey, string logPath, string managerWindowName)
            : this(hotkey, logPath, managerWindowName, false)
        {
        }

        public AppSettings(string hotkey, string logPath, string managerWindowName, bool mergeEnabled)
            : this(hotkey, logPath, managerWindowName, mergeEnabled, false, false)
        {
        }

        public AppSettings(string hotkey, string logPath, string managerWindowName, bool mergeEnabled,
            bool firstRunCompleted, bool startWithWindows)
            : this(hotkey, logPath, managerWindowName, mergeEnabled, firstRunCompleted, startWithWindows,
                null, null, DefaultSchemaVersion, OverflowPolicy.Ask, false)
        {
        }

        /// <summary>
        /// B2 canonical-manager form: the explicit selector is authoritative; callers
        /// keep ManagerWindowName coherent with it (the raw-title fallback, or null when
        /// empty) so the legacy ManagerStore view of the same file never disagrees.
        /// </summary>
        public AppSettings(string hotkey, string logPath, string managerWindowName, bool mergeEnabled,
            bool firstRunCompleted, bool startWithWindows, ManagerSelector managerSelector)
            : this(hotkey, logPath, managerWindowName, mergeEnabled, firstRunCompleted,
                startWithWindows, managerSelector, null)
        {
        }

        /// <summary>
        /// C1 form: also carries the manual priority overrides. Rows are held in the
        /// canonical sorted order (kind, then selector value ordinal, then rank); a null
        /// array means none.
        /// </summary>
        public AppSettings(string hotkey, string logPath, string managerWindowName, bool mergeEnabled,
            bool firstRunCompleted, bool startWithWindows, ManagerSelector managerSelector,
            PriorityOverride[] priorityOverrides)
            : this(hotkey, logPath, managerWindowName, mergeEnabled, firstRunCompleted, startWithWindows,
                managerSelector, priorityOverrides, DefaultSchemaVersion, OverflowPolicy.Ask, false)
        {
        }

        /// <summary>
        /// C3 schema-v2 form: also carries the settings schema version, the persisted
        /// overflow policy and the cross-monitor mirror. The legacy constructors default
        /// to DefaultSchemaVersion (3) / Ask / false, so every pre-C3 read-modify-write keeps working.
        /// </summary>
        public AppSettings(string hotkey, string logPath, string managerWindowName, bool mergeEnabled,
            bool firstRunCompleted, bool startWithWindows, ManagerSelector managerSelector,
            PriorityOverride[] priorityOverrides, int schemaVersion, OverflowPolicy overflowPolicy,
            bool crossMonitorRedistribution)
            : this(hotkey, logPath, managerWindowName, mergeEnabled, firstRunCompleted, startWithWindows,
                managerSelector, priorityOverrides, schemaVersion, overflowPolicy, crossMonitorRedistribution, null)
        {
        }

        /// <summary>
        /// SPEC-RULES-009 form: also carries the title-rules value (the block exactly as read plus the
        /// effective preset, default rank and rule set). A null value means "this settings value carries no
        /// block": a save then writes the block that loading the current file yields (REQ-SET-002).
        /// </summary>
        public AppSettings(string hotkey, string logPath, string managerWindowName, bool mergeEnabled,
            bool firstRunCompleted, bool startWithWindows, ManagerSelector managerSelector,
            PriorityOverride[] priorityOverrides, int schemaVersion, OverflowPolicy overflowPolicy,
            bool crossMonitorRedistribution, TitleRulesSettings titleRules)
            : this(hotkey, logPath, managerWindowName, mergeEnabled, firstRunCompleted, startWithWindows,
                managerSelector, priorityOverrides, schemaVersion, overflowPolicy, crossMonitorRedistribution,
                titleRules, true)
        {
        }

        /// <summary>
        /// SPEC-TRAY-013 form (REQ-SET-001): also carries the attention-overlay flag.
        /// The legacy constructors default it to TRUE (D-2: default ON, absent = true);
        /// only an explicit boolean false in the file loads as false. The SPEC-TRAY-014
        /// options default to mixed / 10 / false (D-7/D-9 and the D-6 extension).
        /// </summary>
        public AppSettings(string hotkey, string logPath, string managerWindowName, bool mergeEnabled,
            bool firstRunCompleted, bool startWithWindows, ManagerSelector managerSelector,
            PriorityOverride[] priorityOverrides, int schemaVersion, OverflowPolicy overflowPolicy,
            bool crossMonitorRedistribution, TitleRulesSettings titleRules, bool attentionOverlay)
            : this(hotkey, logPath, managerWindowName, mergeEnabled, firstRunCompleted, startWithWindows,
                managerSelector, priorityOverrides, schemaVersion, overflowPolicy, crossMonitorRedistribution,
                titleRules, attentionOverlay, AttentionPolicyResolver.DefaultPolicy,
                SettingsStore.DefaultStopBlinkLimit, false)
        {
        }

        /// <summary>
        /// SPEC-TRAY-014 form (REQ-SET-001): also carries the three attention options —
        /// the event policy (mixed|all|notifications), the stop blink limit (already
        /// clamped 1..50 by the loader) and the always-on-top setting (default false =
        /// the shipped above-target z-order). SPEC-TRAY-016: the fifth attention value
        /// (the info visible-seconds cap) defaults to 10 s through the full-tail form.
        /// </summary>
        public AppSettings(string hotkey, string logPath, string managerWindowName, bool mergeEnabled,
            bool firstRunCompleted, bool startWithWindows, ManagerSelector managerSelector,
            PriorityOverride[] priorityOverrides, int schemaVersion, OverflowPolicy overflowPolicy,
            bool crossMonitorRedistribution, TitleRulesSettings titleRules, bool attentionOverlay,
            string attentionEventPolicy, int attentionStopBlinkLimit, bool attentionOverlayTopmost)
            : this(hotkey, logPath, managerWindowName, mergeEnabled, firstRunCompleted, startWithWindows,
                managerSelector, priorityOverrides, schemaVersion, overflowPolicy, crossMonitorRedistribution,
                titleRules, attentionOverlay, attentionEventPolicy, attentionStopBlinkLimit,
                attentionOverlayTopmost, SettingsStore.DefaultInfoVisibleSeconds)
        {
        }

        /// <summary>
        /// SPEC-TRAY-016 full-tail form (REQ-PREF-001): also carries the FIFTH attention
        /// value — the info visible-seconds cap (already clamped 1..120 by the loader).
        /// Every mid-chain constructor and FirstRunDialog's form inherit the 10 s default
        /// by construction, so no new store.Save site appears (the count stays 6).
        /// SPEC-TRAY-020: this form now inherits the update auto-check default TRUE through
        /// the full-tail form below (REQ-UPD-013), so every legacy call site keeps working.
        /// </summary>
        public AppSettings(string hotkey, string logPath, string managerWindowName, bool mergeEnabled,
            bool firstRunCompleted, bool startWithWindows, ManagerSelector managerSelector,
            PriorityOverride[] priorityOverrides, int schemaVersion, OverflowPolicy overflowPolicy,
            bool crossMonitorRedistribution, TitleRulesSettings titleRules, bool attentionOverlay,
            string attentionEventPolicy, int attentionStopBlinkLimit, bool attentionOverlayTopmost,
            int attentionInfoVisibleSeconds)
            : this(hotkey, logPath, managerWindowName, mergeEnabled, firstRunCompleted, startWithWindows,
                managerSelector, priorityOverrides, schemaVersion, overflowPolicy, crossMonitorRedistribution,
                titleRules, attentionOverlay, attentionEventPolicy, attentionStopBlinkLimit,
                attentionOverlayTopmost, attentionInfoVisibleSeconds, true)
        {
        }

        /// <summary>
        /// SPEC-TRAY-020 full-tail form (REQ-UPD-013): also carries the startup update
        /// auto-check switch. The 18-argument form above (and through it every mid-chain
        /// constructor and every legacy caller) inherits TRUE by construction — the D-8
        /// absent-key default — so no call site changes and no new store.Save site appears.
        /// </summary>
        public AppSettings(string hotkey, string logPath, string managerWindowName, bool mergeEnabled,
            bool firstRunCompleted, bool startWithWindows, ManagerSelector managerSelector,
            PriorityOverride[] priorityOverrides, int schemaVersion, OverflowPolicy overflowPolicy,
            bool crossMonitorRedistribution, TitleRulesSettings titleRules, bool attentionOverlay,
            string attentionEventPolicy, int attentionStopBlinkLimit, bool attentionOverlayTopmost,
            int attentionInfoVisibleSeconds, bool updateAutoCheckEnabled)
        {
            this.titleRules = titleRules;
            this.MergeEnabled = mergeEnabled;
            this.hotkey = hotkey;
            this.logPath = logPath;
            this.managerWindowName = managerWindowName;
            this.firstRunCompleted = firstRunCompleted;
            this.startWithWindows = startWithWindows;
            this.managerSelector = managerSelector == null ? DeriveSelector(managerWindowName) : managerSelector;
            this.priorityOverrides = SettingsStore.NormalizeOverrides(priorityOverrides);
            this.schemaVersion = schemaVersion > 0 ? schemaVersion : DefaultSchemaVersion;
            this.overflowPolicy = overflowPolicy;
            this.crossMonitorRedistribution = crossMonitorRedistribution;
            this.attentionOverlay = attentionOverlay;
            this.attentionEventPolicy = attentionEventPolicy == null
                ? AttentionPolicyResolver.DefaultPolicy : attentionEventPolicy;
            this.attentionStopBlinkLimit = attentionStopBlinkLimit;
            this.attentionOverlayTopmost = attentionOverlayTopmost;
            this.attentionInfoVisibleSeconds = attentionInfoVisibleSeconds;
            this.updateAutoCheckEnabled = updateAutoCheckEnabled;
        }

        public string Hotkey { get { return hotkey; } }
        public bool MergeEnabled { get; private set; }
        public string LogPath { get { return logPath; } }

        /// <summary>The persisted manager choice (exact ordinal window name); null for no choice.</summary>
        public string ManagerWindowName { get { return managerWindowName; } }

        /// <summary>The B2 canonical manager choice; never null.</summary>
        public ManagerSelector ManagerSelector { get { return managerSelector; } }

        /// <summary>B1 onboarding: false until the first-run dialog has been acknowledged and saved.</summary>
        public bool FirstRunCompleted { get { return firstRunCompleted; } }

        /// <summary>B1 onboarding: the retained startup checkbox value; no Run key is ever written for it.</summary>
        public bool StartWithWindows { get { return startWithWindows; } }

        /// <summary>The C1 manual priority overrides in canonical sorted order; never null.</summary>
        public PriorityOverride[] PriorityOverrides
        {
            get { return (PriorityOverride[])priorityOverrides.Clone(); }
        }

        /// <summary>The C3 settings schema version (a file at version 0, 1 or 2, or without the field, loads as 3; a higher version is kept).</summary>
        public int SchemaVersion { get { return schemaVersion; } }

        /// <summary>The C3 persisted overflow policy; the default and every unknown text load as Ask.</summary>
        public OverflowPolicy OverflowPolicy { get { return overflowPolicy; } }

        /// <summary>The C3 cross-monitor mirror: true exactly while the policy is Redistribute.</summary>
        public bool CrossMonitorRedistribution { get { return crossMonitorRedistribution; } }

        /// <summary>True when this value was built with a title-rules value (Load and the 12-argument constructor do).</summary>
        public bool HasTitleRules { get { return titleRules != null; } }

        /// <summary>
        /// The SPEC-TRAY-013 attention-overlay flag (REQ-SET-001): true when the file carries
        /// no key or a null, true for boolean true, false only for boolean false. Default ON
        /// (D-2); every legacy constructor and the defaults pass true.
        /// </summary>
        public bool AttentionOverlay { get { return attentionOverlay; } }

        /// <summary>The SPEC-TRAY-014 event policy (mixed|all|notifications); legacy constructors default mixed (D-7).</summary>
        public string AttentionEventPolicy { get { return attentionEventPolicy; } }

        /// <summary>The SPEC-TRAY-014 stop blink limit, clamped 1..50 at load; legacy constructors default 10 (D-9).</summary>
        public int AttentionStopBlinkLimit { get { return attentionStopBlinkLimit; } }

        /// <summary>The SPEC-TRAY-014 always-on-top setting; default false = the shipped above-target z-order (the D-6 extension).</summary>
        public bool AttentionOverlayTopmost { get { return attentionOverlayTopmost; } }

        /// <summary>The SPEC-TRAY-016 info visible-seconds cap (REQ-PREF-001), clamped 1..120 at
        /// load; absent-key and every constructor default is 10 seconds (D-9) — a SECONDS axis,
        /// never the tick-unit AttentionStopBlinkLimit.</summary>
        public int AttentionInfoVisibleSeconds { get { return attentionInfoVisibleSeconds; } }

        /// <summary>The SPEC-TRAY-020 startup auto-check switch (REQ-UPD-013): absent, null and
        /// non-boolean values load as true; only an explicit boolean false loads as false (the
        /// D-8 file-edit-only key — no settings-form field, no new save site).</summary>
        public bool UpdateAutoCheckEnabled { get { return updateAutoCheckEnabled; } }

        /// <summary>The title-rules value; never null (a value built without one behaves as preset none).</summary>
        public TitleRulesSettings TitleRules
        {
            get { return titleRules ?? TitleRulesSettings.Fresh(); }
        }

        private static ManagerSelector DeriveSelector(string managerWindowName)
        {
            return string.IsNullOrEmpty(managerWindowName)
                ? ManagerSelector.None()
                : new ManagerSelector(ManagerSelectorKind.RawTitle, managerWindowName, managerWindowName);
        }

        public override string ToString()
        {
            return string.Format("hotkey={0}|log={1}|manager={2}", hotkey, logPath, managerWindowName == null ? "-" : managerWindowName);
        }
    }

    /// <summary>
    /// The title-rules value of one settings read (SPEC-RULES-009 REQ-SET-001..003): the block exactly as the
    /// file's generic JSON form held it (malformed definitions, unknown keys and invalid parts included, so a
    /// save writes it back verbatim), plus the effective preset, default rank and rule set that behaviour uses.
    /// An invalid part loads as its default for behaviour with one diagnostic, never an exception. Immutable;
    /// array properties return copies. The rule set is built once per read (NFR-2).
    /// </summary>
    // @MX:NOTE: generic-form parse; block kept verbatim, invalid parts included; fallback block on save.
    public sealed class TitleRulesSettings
    {
        public const string PresetNone = "none";
        public const string PresetLauncherPrefix = "launcher-prefix";
        public const int DefaultRankValue = 500;

        private readonly bool hasRawBlock;
        private readonly object rawBlock;
        private readonly bool presetEnabled;
        private readonly int defaultRank;
        private readonly object[] ruleDefinitions;
        private readonly RuleSet ruleSet;
        private readonly string[] diagnosticLines;
        private readonly string[] diagnosticKeys;

        private TitleRulesSettings(bool hasRawBlock, object rawBlock, bool presetEnabled, int defaultRank,
            object[] ruleDefinitions, List<string> settingDiagnostics, List<string> settingKeys)
        {
            this.hasRawBlock = hasRawBlock;
            this.rawBlock = rawBlock;
            this.presetEnabled = presetEnabled;
            this.defaultRank = defaultRank;
            this.ruleDefinitions = ruleDefinitions ?? new object[0];
            this.ruleSet = RuleSetBuilder.Build(this.ruleDefinitions, presetEnabled);
            List<string> lines = new List<string>(settingDiagnostics);
            List<string> keys = new List<string>(settingKeys);
            foreach (RuleDiagnostic diagnostic in ruleSet.Diagnostics)
            {
                string line = "title rule " + diagnostic.Position + " skipped: " + diagnostic.Reason;
                lines.Add(line);
                keys.Add(line + "|" + Describe(DefinitionAt(diagnostic.Position)));
            }
            this.diagnosticLines = lines.ToArray();
            this.diagnosticKeys = keys.ToArray();
        }

        /// <summary>The fresh-install value: preset none, no rules, default rank 500 (written as an explicit block).</summary>
        public static TitleRulesSettings Fresh()
        {
            return new TitleRulesSettings(false, null, false, DefaultRankValue, null, new List<string>(), new List<string>());
        }

        /// <summary>The migration value for a file of schema version 0, 1 or 2: preset on, no user rules.</summary>
        public static TitleRulesSettings Migrated()
        {
            return new TitleRulesSettings(false, null, true, DefaultRankValue, null, new List<string>(), new List<string>());
        }

        /// <summary>
        /// The migration value for a file below schema 3 that already carries a titleRules block (sync review F1):
        /// the block is ignored (REQ-SET-003) and the next save replaces it, so the read reports that once.
        /// </summary>
        public static TitleRulesSettings Migrated(object ignoredBlock)
        {
            if (ignoredBlock == null)
            {
                return Migrated();
            }
            List<string> lines = new List<string>();
            List<string> keys = new List<string>();
            AddSettingDiagnostic(lines, keys,
                "titleRules is ignored because schemaVersion is below 3; set schemaVersion to 3 to use it (the next save replaces it)",
                ignoredBlock);
            return new TitleRulesSettings(false, null, true, DefaultRankValue, null, lines, keys);
        }

        /// <summary>
        /// The deepest nesting, counted from the block itself, that the title-rules reader accepts. A real block
        /// (block, rules, rule, a few values) is under 8 levels; anything deeper is read as invalid (sync review F2).
        /// </summary>
        public const int MaxBlockDepth = 32;

        /// <summary>
        /// Reads the title-rules block from its generic JSON form (null when the file has none). Never throws:
        /// a part that is not valid loads as its default with one diagnostic and keeps its original value.
        /// </summary>
        // JSON null and an absent key both reach this method as a null block: the serializer maps them to the same
        // null field, so a null titleRules is read as absent (the fresh value, no diagnostic) and the next save
        // writes an explicit block in its place (sync review F8; documented, not distinguishable).
        public static TitleRulesSettings FromBlock(object block)
        {
            if (block == null)
            {
                return Fresh();
            }
            List<string> lines = new List<string>();
            List<string> keys = new List<string>();
            if (ExceedsDepth(block, MaxBlockDepth))
            {
                // The value is kept verbatim for a save; it is not described in the log key (it may be huge).
                AddSettingDiagnostic(lines, keys, "titleRules is nested more than " + MaxBlockDepth + " levels deep", null);
                return new TitleRulesSettings(true, block, false, DefaultRankValue, null, lines, keys);
            }
            try
            {
                System.Collections.IDictionary map = block as System.Collections.IDictionary;
                if (map == null)
                {
                    AddSettingDiagnostic(lines, keys, "titleRules must be an object", block);
                    return new TitleRulesSettings(true, block, false, DefaultRankValue, null, lines, keys);
                }
                bool presetOn = false;
                object preset = Field(map, "preset");
                if (preset != null)
                {
                    if (preset is string && string.Equals((string)preset, PresetLauncherPrefix, StringComparison.Ordinal))
                    {
                        presetOn = true;
                    }
                    else if (!(preset is string && string.Equals((string)preset, PresetNone, StringComparison.Ordinal)))
                    {
                        AddSettingDiagnostic(lines, keys, "preset must be launcher-prefix or none", preset);
                    }
                }
                int rank = DefaultRankValue;
                object rankValue = Field(map, "defaultRank");
                if (rankValue != null)
                {
                    long parsed;
                    if (TryReadInteger(rankValue, out parsed) && parsed >= RuleSetBuilder.RankMin && parsed <= RuleSetBuilder.RankMax)
                    {
                        rank = (int)parsed;
                    }
                    else
                    {
                        AddSettingDiagnostic(lines, keys, "defaultRank must be an integer from 0 to 999", rankValue);
                    }
                }
                object[] definitions = new object[0];
                object rulesValue = Field(map, "rules");
                if (rulesValue != null)
                {
                    System.Collections.IEnumerable list = rulesValue as System.Collections.IEnumerable;
                    if (list == null || rulesValue is string || rulesValue is System.Collections.IDictionary)
                    {
                        AddSettingDiagnostic(lines, keys, "rules must be an array", rulesValue);
                    }
                    else
                    {
                        List<object> items = new List<object>();
                        foreach (object item in list)
                        {
                            items.Add(item);
                        }
                        definitions = items.ToArray();
                    }
                }
                return new TitleRulesSettings(true, block, presetOn, rank, definitions, lines, keys);
            }
            catch (Exception ex)
            {
                // NFR-3: a hostile value never escapes; fall back to the defaults for behaviour.
                List<string> failed = new List<string>();
                List<string> failedKeys = new List<string>();
                AddSettingDiagnostic(failed, failedKeys, "could not be read: " + ex.Message, block);
                return new TitleRulesSettings(true, block, false, DefaultRankValue, null, failed, failedKeys);
            }
        }

        /// <summary>The effective preset name: "launcher-prefix" or "none".</summary>
        public string Preset { get { return presetEnabled ? PresetLauncherPrefix : PresetNone; } }

        public bool PresetEnabled { get { return presetEnabled; } }

        /// <summary>The effective default rank (0..999) applied to a window without a rule rank.</summary>
        public int DefaultRank { get { return defaultRank; } }

        /// <summary>The rule definitions as read, in order (empty when the block had none or they were not an array).</summary>
        public object[] RuleDefinitions { get { return (object[])ruleDefinitions.Clone(); } }

        /// <summary>The rule set built from this read (the preset first when enabled).</summary>
        public RuleSet RuleSet { get { return ruleSet; } }

        /// <summary>One line per diagnostic of this read, in the log format of plan.md J.4.</summary>
        public string[] DiagnosticLines { get { return (string[])diagnosticLines.Clone(); } }

        /// <summary>Writes this read's diagnostics through the de-duplicating sink (one line per distinct diagnostic per process).</summary>
        internal void ReportDiagnostics(Action<string> sink)
        {
            if (sink == null)
            {
                return;
            }
            for (int i = 0; i < diagnosticLines.Length; i++)
            {
                RuleDiagnosticLog.Report(sink, diagnosticLines[i], diagnosticKeys[i]);
            }
        }

        /// <summary>The JSON value a save writes: the block as read, or an explicit block built from the effective values.</summary>
        internal object ToJsonValue()
        {
            if (hasRawBlock)
            {
                return rawBlock;
            }
            Dictionary<string, object> block = new Dictionary<string, object>();
            block["preset"] = Preset;
            block["defaultRank"] = defaultRank;
            block["rules"] = ruleDefinitions;
            return block;
        }

        private object DefinitionAt(int position)
        {
            return position >= 1 && position <= ruleDefinitions.Length ? ruleDefinitions[position - 1] : null;
        }

        private static void AddSettingDiagnostic(List<string> lines, List<string> keys, string reason, object value)
        {
            string line = "title rules: " + reason;
            lines.Add(line);
            keys.Add(line + "|" + Describe(value));
        }

        private static string Describe(object value)
        {
            try
            {
                return new JavaScriptSerializer().Serialize(value);
            }
            catch (Exception)
            {
                return string.Empty;
            }
        }

        /// <summary>
        /// True when the value nests containers (objects or arrays) more than limit levels deep, the value itself
        /// being level 1. Iterative, so a hostile value cannot exhaust the stack.
        /// </summary>
        private static bool ExceedsDepth(object value, int limit)
        {
            Stack<KeyValuePair<object, int>> pending = new Stack<KeyValuePair<object, int>>();
            pending.Push(new KeyValuePair<object, int>(value, 1));
            while (pending.Count > 0)
            {
                KeyValuePair<object, int> current = pending.Pop();
                System.Collections.IEnumerable children = null;
                System.Collections.IDictionary map = current.Key as System.Collections.IDictionary;
                if (map != null)
                {
                    children = map.Values;
                }
                else if (current.Key is System.Collections.IEnumerable && !(current.Key is string))
                {
                    children = (System.Collections.IEnumerable)current.Key;
                }
                if (children == null)
                {
                    continue;
                }
                if (current.Value > limit)
                {
                    return true;
                }
                foreach (object child in children)
                {
                    pending.Push(new KeyValuePair<object, int>(child, current.Value + 1));
                }
            }
            return false;
        }

        private static object Field(System.Collections.IDictionary map, string key)
        {
            return map.Contains(key) ? map[key] : null;
        }

        /// <summary>True for the integral CLR types a JSON reader yields for an integer (never for decimals, doubles, strings).</summary>
        private static bool TryReadInteger(object value, out long result)
        {
            result = 0;
            if (value is int)
            {
                result = (int)value;
                return true;
            }
            if (value is long)
            {
                result = (long)value;
                return true;
            }
            return false;
        }
    }

    /// <summary>
    /// One persisted manual priority override (C1): the manager-style selector it keys on
    /// and the pinned manual rank. Valid ranks are 0..999 (lower = higher priority); the
    /// store ignores out-of-range rows with a diagnostic. Immutable; rows serialize in the
    /// canonical sorted order (selector kind, then value ordinal, then rank).
    /// </summary>
    public sealed class PriorityOverride
    {
        private readonly ManagerSelector selector;
        private readonly int rank;

        public PriorityOverride(ManagerSelector selector, int rank)
        {
            this.selector = selector;
            this.rank = rank;
        }

        public ManagerSelector Selector { get { return selector; } }
        public int Rank { get { return rank; } }
    }

    /// <summary>
    /// The SPEC-TRAY-014 event-policy resolver (plan.md A-2: it lives beside the DTO it
    /// serves): the closed token set mixed|all|notifications (ordinal); a null, empty or
    /// unknown value loads as the default "mixed" — a PER-KEY degrade, never a whole-file
    /// degradation (REQ-SET-001, the OverflowPolicyParser precedent).
    /// </summary>
    // @MX:NOTE: closed token set + the mixed default (D-7); changing a token is a SPEC amendment.
    public static class AttentionPolicyResolver
    {
        public const string PolicyMixed = "mixed";
        public const string PolicyAll = "all";
        public const string PolicyNotifications = "notifications";
        public const string DefaultPolicy = PolicyMixed;

        public static string Parse(string text)
        {
            if (string.Equals(text, PolicyMixed, StringComparison.Ordinal)
                || string.Equals(text, PolicyAll, StringComparison.Ordinal)
                || string.Equals(text, PolicyNotifications, StringComparison.Ordinal))
            {
                return text;
            }
            return DefaultPolicy;
        }
    }

    /// <summary>
    /// Loads and saves the single settings file (REQ-SET-001, spec D-3):
    /// %LOCALAPPDATA%\TerminalOrganizer\settings.json holding hotkey / logPath /
    /// managerWindowName as one JSON shape. Sole-writer rule: ALL persistence goes through
    /// this store's read-modify-write Save — the Core ManagerStore only ever READS this
    /// file, so no field is ever clobbered. Tolerant by contract: a missing or malformed
    /// file loads as the defaults and never throws; a field absent from the file (a legacy
    /// ManagerStore-shaped {"managerWindowName":...}) keeps its default. Save is
    /// best-effort: a failure is reported to the optional diagnostic sink and swallowed.
    /// </summary>
    public sealed class SettingsStore
    {
        /// <summary>The D-3 default hotkey string.</summary>
        public const string DefaultHotkey = "Ctrl+Alt+O";

        /// <summary>
        /// The JSON reader and writer nesting limit (the serializer default is 100). It sits well above
        /// TitleRulesSettings.MaxBlockDepth so a deeply nested titleRules value is read, reported and kept as one
        /// invalid part instead of failing the whole file (REQ-SET-001, sync review F2); it stays far below any
        /// stack risk. A file nested deeper than this still degrades to the defaults, as any malformed file does.
        /// </summary>
        private const int SerializerRecursionLimit = 256;

        private static JavaScriptSerializer NewSerializer()
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.RecursionLimit = SerializerRecursionLimit;
            return serializer;
        }

        /// <summary>SPEC-TRAY-014 D-9: the absent-key stop blink limit (clamped 1..50 on load).</summary>
        public const int DefaultStopBlinkLimit = 10;

        /// <summary>
        /// SPEC-TRAY-014 D-9 (plan.md A-2, pure): clamps any integer into 1..50 —
        /// 0 and negatives load 1, anything above 50 loads 50.
        /// </summary>
        // @MX:NOTE: the 1..50 clamp bounds (D-9); changing a bound is a SPEC amendment.
        public static int ClampBlinkLimit(int value)
        {
            if (value < 1)
            {
                return 1;
            }
            if (value > 50)
            {
                return 50;
            }
            return value;
        }

        /// <summary>SPEC-TRAY-016 (REQ-PREF-001, plan.md section J): the absent-key info
        /// visible-seconds default. 10 SECONDS — a distinct axis from the 10-TICK
        /// DefaultStopBlinkLimit (D-7's two "10"s); schemaVersion stays 3.</summary>
        public const int DefaultInfoVisibleSeconds = 10;

        /// <summary>
        /// SPEC-TRAY-016 (plan.md section J, pure): clamps any integer into 1..120 —
        /// 0 and negatives load 1, anything above 120 loads 120.
        /// </summary>
        // @MX:NOTE: the 1..120 clamp bounds (the D-9 blink-limit pattern); changing a bound is a SPEC amendment.
        public static int ClampInfoSeconds(int value)
        {
            if (value < 1)
            {
                return 1;
            }
            if (value > 120)
            {
                return 120;
            }
            return value;
        }

        private readonly string path;
        private readonly Action<string> log;

        public SettingsStore(string path)
            : this(path, null)
        {
        }

        /// <param name="log">Optional diagnostic sink for degraded loads and failed saves (advisory: surface the drop, never throw).</param>
        public SettingsStore(string path, Action<string> log)
        {
            this.path = path;
            this.log = log;
        }

        /// <summary>%LOCALAPPDATA%\TerminalOrganizer (spec D-3).</summary>
        public static string DefaultDirectory()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TerminalOrganizer");
        }

        /// <summary>The D-3 settings file path.</summary>
        public static string DefaultPath()
        {
            return Path.Combine(DefaultDirectory(), "settings.json");
        }

        /// <summary>The D-3 default log path.</summary>
        public static string DefaultLogPath()
        {
            return Path.Combine(DefaultDirectory(), "terminal-organizer.log");
        }

        /// <summary>The D-3 defaults: hotkey "Ctrl+Alt+O", default log path, no manager.</summary>
        public static AppSettings Defaults()
        {
            return new AppSettings(DefaultHotkey, DefaultLogPath(), null, false, false, false,
                null, null, AppSettings.DefaultSchemaVersion, OverflowPolicy.Ask, false, TitleRulesSettings.Fresh());
        }

        /// <summary>Loads the settings; tolerant — never throws for file content.</summary>
        public AppSettings Load()
        {
            return LoadCore(true);
        }

        private AppSettings LoadCore(bool report)
        {
            try
            {
                if (string.IsNullOrEmpty(path) || !File.Exists(path))
                {
                    return Defaults();
                }
                string json = File.ReadAllText(path);
                SettingsDto dto = NewSerializer().Deserialize<SettingsDto>(json);
                if (dto == null)
                {
                    Degrade("settings file content was not a settings object; loading defaults");
                    return Defaults();
                }
                string hotkey = string.IsNullOrEmpty(dto.hotkey) ? DefaultHotkey : dto.hotkey;
                string logPath = string.IsNullOrEmpty(dto.logPath) ? DefaultLogPath() : dto.logPath;
                string manager = string.IsNullOrEmpty(dto.managerWindowName) ? null : dto.managerWindowName;
                // C3: unknown policy text loads as Ask; the cross-monitor mirror is kept
                // coherent with the loaded policy (true only while Redistribute).
                OverflowPolicy policy = OverflowPolicyParser.Parse(dto.overflowPolicy);
                // @MX:NOTE: raw version 0/1/2 means preset on; decided before normalization (SPEC-RULES-009 REQ-SET-003).
                bool legacy = dto.schemaVersion <= 2;
                TitleRulesSettings rules = legacy ? TitleRulesSettings.Migrated(dto.titleRules) : TitleRulesSettings.FromBlock(dto.titleRules);
                if (report)
                {
                    rules.ReportDiagnostics(log);
                }
                return new AppSettings(hotkey, logPath, manager, dto.mergeEnabled,
                    dto.firstRunCompleted, dto.startWithWindows, ParseSelector(dto.managerSelector),
                    ParseOverrides(dto.priorityOverrides), legacy ? AppSettings.DefaultSchemaVersion : dto.schemaVersion, policy,
                    policy == OverflowPolicy.Redistribute && dto.crossMonitorRedistribution, rules,
                    dto.attentionOverlay != false,
                    AttentionPolicyResolver.Parse(dto.attentionEventPolicy),
                    dto.attentionStopBlinkLimit.HasValue
                        ? ClampBlinkLimit(dto.attentionStopBlinkLimit.Value)
                        : DefaultStopBlinkLimit,
                    dto.attentionOverlayTopmost == true,
                    // SPEC-TRAY-016 (REQ-PREF-001): the fifth attention value rides the same
                    // camelCase DTO ternary as the D-9 blink limit — absent-key default 10,
                    // clamp 1..120, per-key degrade (never a whole-file degradation).
                    dto.attentionInfoVisibleSeconds.HasValue
                        ? ClampInfoSeconds(dto.attentionInfoVisibleSeconds.Value)
                        : DefaultInfoVisibleSeconds,
                    // SPEC-TRAY-020 (REQ-UPD-013): the update auto-check switch rides the
                    // same camelCase DTO ternary family — absent-key default true, only an
                    // explicit boolean false loads false (D-8).
                    dto.updateAutoCheckEnabled.HasValue ? dto.updateAutoCheckEnabled.Value : true);
            }
            catch (Exception ex)
            {
                // Tolerant load (REQ-SET-001): malformed content degrades to defaults, never throws.
                Degrade("settings load degraded to defaults: " + ex.Message);
                return Defaults();
            }
        }

        /// <summary>Saves all three fields as one JSON document; best-effort, never throws.</summary>
        public void Save(AppSettings settings)
        {
            try
            {
                if (string.IsNullOrEmpty(path))
                {
                    return;
                }
                AppSettings values = settings == null ? Defaults() : settings;
                SettingsDto dto = new SettingsDto();
                dto.hotkey = values.Hotkey;
                dto.logPath = values.LogPath;
                dto.managerWindowName = values.ManagerWindowName;
                dto.mergeEnabled = values.MergeEnabled;
                dto.firstRunCompleted = values.FirstRunCompleted;
                dto.startWithWindows = values.StartWithWindows;
                ManagerSelector selector = values.ManagerSelector;
                dto.managerSelector = new ManagerSelectorDto();
                dto.managerSelector.kind = selector.Kind.ToString();
                dto.managerSelector.value = selector.Value;
                dto.managerSelector.rawTitleFallback = selector.RawTitleFallback;
                dto.priorityOverrides = SerializeOverrides(values.PriorityOverrides);
                dto.schemaVersion = values.SchemaVersion;
                dto.overflowPolicy = OverflowPolicyParser.Format(values.OverflowPolicy);
                dto.crossMonitorRedistribution = values.CrossMonitorRedistribution;
                // @MX:NOTE: SPEC-TRAY-013 REQ-SET-001 — every save writes the resolved boolean (absent key loads as true).
                dto.attentionOverlay = values.AttentionOverlay;
                // @MX:NOTE: SPEC-TRAY-014/016 REQ-SET-002 — every save also writes all five resolved attention values
                // (overlay, policy, limit, topmost, info seconds) so no unrelated save reverts one.
                dto.attentionEventPolicy = values.AttentionEventPolicy;
                dto.attentionStopBlinkLimit = values.AttentionStopBlinkLimit;
                dto.attentionOverlayTopmost = values.AttentionOverlayTopmost;
                dto.attentionInfoVisibleSeconds = values.AttentionInfoVisibleSeconds;
                // @MX:NOTE: SPEC-TRAY-020 REQ-UPD-013 — every save writes the resolved switch so
                // no unrelated read-modify-write save reverts a user's explicit false (the
                // file-edit-only key; the key loads as true while absent).
                dto.updateAutoCheckEnabled = values.UpdateAutoCheckEnabled;
                // @MX:NOTE: generic-form parse; block kept verbatim, invalid parts included; fallback block on save.
                // A value without a title-rules value (an older constructor) writes what loading the current file yields.
                TitleRulesSettings block = values.HasTitleRules ? values.TitleRules : LoadCore(false).TitleRules;
                dto.titleRules = block.ToJsonValue();
                string directory = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                File.WriteAllText(path, NewSerializer().Serialize(dto));
            }
            catch (Exception ex)
            {
                // Best-effort save: surface the failure on the diagnostic sink, never throw.
                Degrade("settings save failed: " + ex.Message);
            }
        }

        private void Degrade(string message)
        {
            Action<string> sink = log;
            if (sink != null)
            {
                sink(message);
            }
        }

        /// <summary>
        /// Maps the persisted B2 selector object; null when the file carries none (the
        /// legacy managerWindowName field then applies through the AppSettings
        /// constructor). Tolerant by contract: an unknown kind or a valueless selector
        /// degrades to the raw-title fallback when one is present, never throws.
        /// </summary>
        private static ManagerSelector ParseSelector(ManagerSelectorDto dto)
        {
            if (dto == null)
            {
                return null;
            }
            ManagerSelectorKind kind;
            if (!Enum.TryParse<ManagerSelectorKind>(dto.kind, true, out kind))
            {
                return DegradeToRawTitle(dto.rawTitleFallback);
            }
            if (kind == ManagerSelectorKind.None)
            {
                return ManagerSelector.None();
            }
            if (kind != ManagerSelectorKind.RawTitle && string.IsNullOrEmpty(dto.value))
            {
                return DegradeToRawTitle(dto.rawTitleFallback);
            }
            return new ManagerSelector(kind, dto.value, dto.rawTitleFallback);
        }

        private static ManagerSelector DegradeToRawTitle(string rawTitleFallback)
        {
            return string.IsNullOrEmpty(rawTitleFallback)
                ? ManagerSelector.None()
                : new ManagerSelector(ManagerSelectorKind.RawTitle, rawTitleFallback, rawTitleFallback);
        }

        /// <summary>
        /// Maps the persisted C1 override rows, dropping every invalid one with a
        /// diagnostic: an unknown selector kind, a valueless selector, or a rank outside
        /// 0..999 (the manual rank bounds). Surviving rows return in canonical order.
        /// </summary>
        private PriorityOverride[] ParseOverrides(PriorityOverrideDto[] overrides)
        {
            List<PriorityOverride> rows = new List<PriorityOverride>();
            if (overrides != null)
            {
                foreach (PriorityOverrideDto dto in overrides)
                {
                    if (dto == null)
                    {
                        continue;
                    }
                    ManagerSelectorKind kind;
                    if (!Enum.TryParse<ManagerSelectorKind>(dto.kind, true, out kind)
                        || kind == ManagerSelectorKind.None)
                    {
                        Degrade("priority override ignored: unknown selector kind '" + dto.kind + "'");
                        continue;
                    }
                    if (dto.rank < PriorityResolver.ManualRankMin || dto.rank > PriorityResolver.ManualRankMax)
                    {
                        Degrade("priority override ignored: rank " + dto.rank + " outside 0..999");
                        continue;
                    }
                    ManagerSelector selector = new ManagerSelector(kind, dto.value, dto.rawTitleFallback);
                    if (selector.IsEmpty)
                    {
                        Degrade("priority override ignored: selector has no value");
                        continue;
                    }
                    rows.Add(new PriorityOverride(selector, dto.rank));
                }
            }
            return NormalizeOverrides(rows.ToArray());
        }

        /// <summary>The DTO rows for one save, in the canonical sorted order.</summary>
        private static PriorityOverrideDto[] SerializeOverrides(PriorityOverride[] overrides)
        {
            PriorityOverride[] sorted = NormalizeOverrides(overrides);
            PriorityOverrideDto[] dtos = new PriorityOverrideDto[sorted.Length];
            for (int i = 0; i < sorted.Length; i++)
            {
                dtos[i] = new PriorityOverrideDto();
                dtos[i].kind = sorted[i].Selector.Kind.ToString();
                dtos[i].value = sorted[i].Selector.Value;
                dtos[i].rawTitleFallback = sorted[i].Selector.RawTitleFallback;
                dtos[i].rank = sorted[i].Rank;
            }
            return dtos;
        }

        /// <summary>The in-memory canonical form: sorted, no null/empty rows, never null.</summary>
        public static PriorityOverride[] NormalizeOverrides(PriorityOverride[] overrides)
        {
            List<PriorityOverride> rows = new List<PriorityOverride>();
            if (overrides != null)
            {
                foreach (PriorityOverride row in overrides)
                {
                    if (row != null && row.Selector != null && !row.Selector.IsEmpty)
                    {
                        rows.Add(row);
                    }
                }
            }
            rows.Sort(CompareOverrides);
            return rows.ToArray();
        }

        /// <summary>The canonical override order: selector kind, then value ordinal, then rank.</summary>
        private static int CompareOverrides(PriorityOverride x, PriorityOverride y)
        {
            int byKind = x.Selector.Kind.CompareTo(y.Selector.Kind);
            if (byKind != 0)
            {
                return byKind;
            }
            int byValue = string.CompareOrdinal(x.Selector.Value, y.Selector.Value);
            if (byValue != 0)
            {
                return byValue;
            }
            return x.Rank.CompareTo(y.Rank);
        }

        /// <summary>The settings JSON shape; public fields so JavaScriptSerializer maps them.</summary>
        private sealed class SettingsDto
        {
            public string hotkey;
            public string logPath;
            public string managerWindowName;
            public bool mergeEnabled;
            public bool firstRunCompleted;
            public bool startWithWindows;
            public ManagerSelectorDto managerSelector;
            public PriorityOverrideDto[] priorityOverrides;
            public int schemaVersion;
            public string overflowPolicy;
            public bool crossMonitorRedistribution;

            /// <summary>The SPEC-TRAY-013 attention-overlay flag; null (absent key) loads as true (REQ-SET-001).</summary>
            public bool? attentionOverlay;

            /// <summary>SPEC-TRAY-014: the event policy token; null/absent/unknown loads as mixed (per-key degrade).</summary>
            public string attentionEventPolicy;

            /// <summary>SPEC-TRAY-014: the stop blink limit; absent loads 10, any integer clamps 1..50; a non-integer takes the whole-file tolerant degradation.</summary>
            public int? attentionStopBlinkLimit;

            /// <summary>SPEC-TRAY-014: the always-on-top setting; null/absent loads false.</summary>
            public bool? attentionOverlayTopmost;

            /// <summary>SPEC-TRAY-016: the info visible-seconds cap; absent loads 10, any integer
            /// clamps 1..120 (a per-key degrade, like the blink limit); a non-integer takes the
            /// whole-file tolerant degradation.</summary>
            public int? attentionInfoVisibleSeconds;

            /// <summary>The title-rules block in generic form (never a typed shape): a bad value inside it cannot degrade the file.</summary>
            public object titleRules;

            /// <summary>SPEC-TRAY-020: the startup auto-check switch; null (absent key) loads as true (REQ-UPD-013).</summary>
            public bool? updateAutoCheckEnabled;
        }

        /// <summary>The persisted B2 canonical manager selector shape; public fields so JavaScriptSerializer maps them.</summary>
        private sealed class ManagerSelectorDto
        {
            public string kind;
            public string value;
            public string rawTitleFallback;
        }

        /// <summary>One persisted C1 priority override row; public fields so JavaScriptSerializer maps them.</summary>
        private sealed class PriorityOverrideDto
        {
            public string kind;
            public string value;
            public string rawTitleFallback;
            public int rank;
        }
    }
}
