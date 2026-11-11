using System;
using System.Collections.Generic;
using TerminalOrganizer.Core.Monitors;
using TerminalOrganizer.Core.Rules;

namespace TerminalOrganizer.Core.Windows
{
    /// <summary>The backing kind of a launcher session (REQ-CLI-001): local and remote
    /// sessions are tmux-backed; Windows-native ones are not (product.md decision 2/4).</summary>
    public enum SessionKind
    {
        /// <summary>wsl.exe invoking run_dev_launch.sh --attach &lt;session&gt;.</summary>
        Local,

        /// <summary>wsl.exe invoking rdl_attach.sh &lt;ssh-target&gt; &lt;session&gt;.</summary>
        Remote,

        /// <summary>powershell.exe with LAUNCHER_SESSION='&lt;session&gt;' in its command line.</summary>
        WindowsNative
    }

    /// <summary>
    /// One open launcher session (REQ-CLI-001/002): its name, its kind, and the FULL original
    /// command line captured verbatim — a merged tab must reproduce the argument list exactly
    /// (launcher duplicate-detection contract), so the line is copied, never reconstructed.
    /// </summary>
    public sealed class SessionRecord
    {
        private readonly string name;
        private readonly SessionKind kind;
        private readonly string commandLine;

        public SessionRecord(string name, SessionKind kind, string commandLine)
        {
            this.name = name;
            this.kind = kind;
            this.commandLine = commandLine;
        }

        public string Name { get { return name; } }
        public SessionKind Kind { get { return kind; } }

        /// <summary>The verbatim full command line (image and every argument, unmodified).</summary>
        public string CommandLine { get { return commandLine; } }

        /// <summary>REQ-MCH-002: only Local and Remote sessions are tmux-backed.</summary>
        public bool TmuxBacked
        {
            get { return kind == SessionKind.Local || kind == SessionKind.Remote; }
        }

        public override string ToString()
        {
            return string.Format("{0}|{1}|{2}", name, kind, commandLine);
        }
    }

    /// <summary>
    /// One child process of WindowsTerminal.exe as the query reports it (REQ-ACQ-003):
    /// the image name and the full command line. A null command line degrades to an
    /// unclassifiable record, never to an exception.
    /// </summary>
    public sealed class ChildProcess
    {
        private readonly string imageName;
        private readonly string commandLine;

        public ChildProcess(string imageName, string commandLine)
        {
            this.imageName = imageName;
            this.commandLine = commandLine;
        }

        public string ImageName { get { return imageName; } }
        public string CommandLine { get { return commandLine; } }
    }

    /// <summary>
    /// The outcome of a tab-title read (REQ-ACQ-002): success with the ordered tab-title
    /// list, or failure with the GetWindowText raw title as fallback and a reason. The
    /// fallback source is an injectable seam (plan.md B.4); the production default is
    /// GetWindowText. The titles array property returns a copy.
    /// </summary>
    public enum TabReadQuality { Trusted, Incomplete, Fallback, TimedOut }

    public sealed class TabEvidence
    {
        public TabEvidence(string identityKey, string title) { IdentityKey = identityKey; Title = title; }
        public string IdentityKey { get; private set; }
        public string Title { get; private set; }
    }

    public sealed class TabTitleResult
    {
        private readonly bool success;
        private readonly string[] titles;
        private readonly string fallbackTitle;
        private readonly string error;
        private readonly TabEvidence[] evidence;
        public TabReadQuality Quality { get; private set; }
        public bool Trusted { get { return Quality == TabReadQuality.Trusted; } }
        public int ObservedTabItemCount { get; private set; }
        public TabEvidence[] Evidence { get { return (TabEvidence[])evidence.Clone(); } }

        private TabTitleResult(TabReadQuality quality, TabEvidence[] evidence, int observed, string fallbackTitle, string error)
        {
            this.Quality = quality;
            this.success = quality == TabReadQuality.Trusted || quality == TabReadQuality.Incomplete;
            this.evidence = evidence == null ? new TabEvidence[0] : (TabEvidence[])evidence.Clone();
            List<string> names = new List<string>();
            foreach (TabEvidence item in this.evidence) if (item != null) names.Add(item.Title);
            this.titles = names.ToArray();
            this.ObservedTabItemCount = observed;
            this.fallbackTitle = fallbackTitle;
            this.error = error;
        }

        public bool Success { get { return success; } }

        /// <summary>The ordered tab titles when Success; an empty array otherwise.</summary>
        public string[] Titles
        {
            get { return titles == null ? new string[0] : (string[])titles.Clone(); }
        }

        /// <summary>The raw GetWindowText title carried on the failure path; null on success.</summary>
        public string FallbackTitle { get { return fallbackTitle; } }

        /// <summary>The failure reason when not Success; null otherwise.</summary>
        public string Error { get { return error; } }

        public static TabTitleResult Ok(string[] titles)
        {
            List<TabEvidence> items = new List<TabEvidence>();
            if (titles != null) foreach (string title in titles) items.Add(new TabEvidence(null, title));
            return TrustedResult(items.ToArray());
        }

        public static TabTitleResult TrustedResult(TabEvidence[] evidence)
        {
            int count = evidence == null ? 0 : evidence.Length;
            bool complete = count > 0;
            if (evidence != null) foreach (TabEvidence item in evidence)
                if (item == null || string.IsNullOrEmpty(item.Title)) complete = false;
            return new TabTitleResult(complete ? TabReadQuality.Trusted : TabReadQuality.Incomplete,
                evidence, count, null, complete ? null : "incomplete tab evidence");
        }

        public static TabTitleResult Incomplete(TabEvidence[] evidence, int observedTabItemCount, string fallbackTitle, string error)
        {
            return new TabTitleResult(TabReadQuality.Incomplete, evidence, observedTabItemCount, fallbackTitle, error);
        }

        public static TabTitleResult Failure(string fallbackTitle, string error)
        {
            return new TabTitleResult(TabReadQuality.Fallback, null, 0, fallbackTitle, error);
        }

        public static TabTitleResult TimedOut(string fallbackTitle, string error)
        {
            return new TabTitleResult(TabReadQuality.TimedOut, null, 0, fallbackTitle, error);
        }
    }

    /// <summary>
    /// One tab title parsed by the C1 grammar: the original title, the session title after
    /// exactly one launcher prefix, whether a valid prefix was present, and the declared
    /// rank digit (null when the prefix carried none). Invalid prefixes leave the title
    /// unchanged (PrefixPresent false, SessionTitle == Original). Immutable; the family and
    /// context letters are NEVER reinterpreted as priority — only the rank digit is.
    /// </summary>
    public sealed class NormalizedTitle
    {
        private readonly string original;
        private readonly string sessionTitle;
        private readonly bool prefixPresent;
        private readonly int? declaredRank;

        public NormalizedTitle(string original, string sessionTitle, bool prefixPresent, int? declaredRank)
        {
            this.original = original;
            this.sessionTitle = sessionTitle;
            this.prefixPresent = prefixPresent;
            this.declaredRank = declaredRank;
        }

        /// <summary>The title exactly as read; null stays null.</summary>
        public string Original { get { return original; } }

        /// <summary>The session title: stripped when a valid prefix was present, else the original.</summary>
        public string SessionTitle { get { return sessionTitle; } }

        /// <summary>True only when a valid [OHNW][CGDA][digit?]_ prefix was stripped.</summary>
        public bool PrefixPresent { get { return prefixPresent; } }

        /// <summary>The single declared rank digit (0-9); lower means higher priority. Null when absent.</summary>
        public int? DeclaredRank { get { return declaredRank; } }
    }

    /// <summary>
    /// One tab's match outcome (REQ-MCH-001): the raw title, the stripped title, and the
    /// matched session record — null when the stripped title names no open session.
    /// </summary>
    public sealed class TabSnapshot
    {
        private readonly string title;
        private readonly string strippedTitle;
        private readonly SessionRecord session;

        public TabSnapshot(string title, string strippedTitle, SessionRecord session)
        {
            this.title = title;
            this.strippedTitle = strippedTitle;
            this.session = session;
        }

        /// <summary>The raw tab title as read.</summary>
        public string Title { get { return title; } }

        /// <summary>The title after one prefix strip (TitleNormalizer).</summary>
        public string StrippedTitle { get { return strippedTitle; } }

        /// <summary>The matched session; null when unmatched.</summary>
        public SessionRecord Session { get { return session; } }

        public bool Matched { get { return session != null; } }
    }

    /// <summary>
    /// One window's match outcome (REQ-MCH-001/002): the per-tab snapshots in tab order,
    /// the window-level identification flag (identified only when EVERY tab matched),
    /// the stripped titles of the unmatched tabs, and merge eligibility (single tab AND
    /// identified AND tmux-backed). Array properties return copies.
    /// </summary>
    public sealed class WindowMatchResult
    {
        private readonly TabSnapshot[] tabs;
        private readonly bool identified;
        private readonly string[] unmatchedTitles;
        private readonly bool mergeable;

        public WindowMatchResult(TabSnapshot[] tabs, bool identified, string[] unmatchedTitles, bool mergeable)
        {
            this.tabs = tabs == null ? new TabSnapshot[0] : (TabSnapshot[])tabs.Clone();
            this.identified = identified;
            this.unmatchedTitles = unmatchedTitles == null ? new string[0] : (string[])unmatchedTitles.Clone();
            this.mergeable = mergeable;
        }

        public TabSnapshot[] Tabs { get { return (TabSnapshot[])tabs.Clone(); } }
        public bool Identified { get { return identified; } }

        /// <summary>The stripped titles of the unmatched tabs, in tab order.</summary>
        public string[] UnmatchedTitles { get { return (string[])unmatchedTitles.Clone(); } }
        public bool Mergeable { get { return mergeable; } }
    }

    /// <summary>
    /// One window's acquisition outputs, ready for composition (REQ-CMP-001): the handle,
    /// the tab-title read result (success list or failure with fallback title), the monitor
    /// attribution, and the current-desktop status — each passed through from the wrappers.
    /// </summary>
    public sealed class AcquiredWindow
    {
        private readonly IntPtr handle;
        private readonly TabTitleResult titles;
        private readonly MonitorInfo monitor;
        private readonly DesktopFlagResult desktopStatus;

        public AcquiredWindow(IntPtr handle, TabTitleResult titles, MonitorInfo monitor, DesktopFlagResult desktopStatus)
            : this(new WindowIdentity(handle, 0, 0, null, null), titles, monitor, desktopStatus)
        {
        }

        public AcquiredWindow(WindowIdentity identity, TabTitleResult titles, MonitorInfo monitor, DesktopFlagResult desktopStatus)
        {
            this.Identity = identity;
            this.handle = identity == null ? IntPtr.Zero : identity.Handle;
            this.titles = titles;
            this.monitor = monitor;
            this.desktopStatus = desktopStatus;
        }

        public IntPtr Handle { get { return handle; } }

        /// <summary>The tab-title read result (REQ-ACQ-002); a null degrades to zero tabs.</summary>
        public TabTitleResult Titles { get { return titles; } }
        public WindowIdentity Identity { get; private set; }

        /// <summary>The monitor attribution (REQ-ACQ-001); null when unattributed.</summary>
        public MonitorInfo Monitor { get { return monitor; } }

        /// <summary>The current-desktop status; passed through to the snapshot.</summary>
        public DesktopFlagResult DesktopStatus { get { return desktopStatus; } }
    }

    /// <summary>
    /// The composed window identity (REQ-CMP-001): the handle, attribution and desktop
    /// status passed through, plus the per-tab sessions, identification flag, unmatched
    /// stripped titles and merge eligibility from the matcher. Unidentified windows stay
    /// in the list (still placed, never merged or closed). Array properties return copies.
    /// </summary>
    public sealed class WindowSnapshot
    {
        private readonly IntPtr handle;
        private readonly MonitorInfo monitor;
        private readonly DesktopFlagResult desktopStatus;
        private readonly TabSnapshot[] tabs;
        private readonly bool identified;
        private readonly string[] unmatchedTitles;
        private readonly bool mergeable;
        private readonly bool hasRuleOutcome;
        private readonly string identityName;
        private readonly int? ruleRank;
        private readonly string ruleReference;
        private readonly RuleDiagnostic[] ruleDiagnostics;

        public WindowSnapshot(IntPtr handle, MonitorInfo monitor, DesktopFlagResult desktopStatus,
            TabSnapshot[] tabs, bool identified, string[] unmatchedTitles, bool mergeable)
            : this(new WindowIdentity(handle, 0, 0, null, null), monitor, desktopStatus,
                tabs, identified, unmatchedTitles, false, TabReadQuality.Fallback)
        {
        }

        /// <summary>
        /// Today's constructor: identity derives from session evidence alone (the first tab's session
        /// name when every tab is bound, otherwise none) and the snapshot carries no rule outcome.
        /// </summary>
        public WindowSnapshot(WindowIdentity identity, MonitorInfo monitor, DesktopFlagResult desktopStatus,
            TabSnapshot[] tabs, bool identified, string[] unmatchedTitles, bool mergeable, TabReadQuality tabReadQuality)
            : this(identity, monitor, desktopStatus, tabs, identified, unmatchedTitles, mergeable, tabReadQuality, null)
        {
        }

        /// <summary>
        /// The rule-aware constructor (SPEC-RULES-008): the identity name, rule rank and rule reference
        /// come from the window rule outcome, and the snapshot reports that it carries one even when no
        /// rule matched. A null outcome behaves like today's constructor (no rule outcome).
        /// </summary>
        public WindowSnapshot(WindowIdentity identity, MonitorInfo monitor, DesktopFlagResult desktopStatus,
            TabSnapshot[] tabs, bool identified, string[] unmatchedTitles, bool mergeable, TabReadQuality tabReadQuality,
            WindowRuleOutcome ruleOutcome)
        {
            this.Identity = identity;
            this.TabReadQuality = tabReadQuality;
            this.handle = identity == null ? IntPtr.Zero : identity.Handle;
            this.monitor = monitor;
            this.desktopStatus = desktopStatus;
            this.tabs = tabs == null ? new TabSnapshot[0] : (TabSnapshot[])tabs.Clone();
            this.identified = identified;
            this.unmatchedTitles = unmatchedTitles == null ? new string[0] : (string[])unmatchedTitles.Clone();
            this.mergeable = mergeable && HasTrustedCompleteTabs && identity != null && identity.EqualsForMutation(identity)
                && identified && this.tabs.Length == 1 && this.tabs[0] != null && this.tabs[0].Session != null
                && this.tabs[0].Session.TmuxBacked && !string.IsNullOrWhiteSpace(this.tabs[0].Session.CommandLine);
            if (ruleOutcome != null)
            {
                this.hasRuleOutcome = true;
                this.identityName = ruleOutcome.IdentityName;
                this.ruleRank = ruleOutcome.Rank;
                this.ruleReference = ruleOutcome.Reference;
                this.ruleDiagnostics = ruleOutcome.Diagnostics;
            }
            else
            {
                this.hasRuleOutcome = false;
                this.identityName = identified && this.tabs.Length > 0 && this.tabs[0] != null && this.tabs[0].Session != null
                    ? this.tabs[0].Session.Name : null;
                this.ruleRank = null;
                this.ruleReference = null;
                this.ruleDiagnostics = new RuleDiagnostic[0];
            }
        }

        /// <summary>
        /// True when the snapshot was built by either composer overload or by the rule-aware constructor
        /// (even when no rule matched); false when built through today's constructors. This flag alone
        /// tells the two cases apart — never the contents of the outcome.
        /// </summary>
        public bool HasRuleOutcome { get { return hasRuleOutcome; } }

        /// <summary>The identity name after rule evaluation; null when none (see the constructors for the legacy derivation).</summary>
        public string IdentityName { get { return identityName; } }

        /// <summary>The rank the window's rules supplied; null when none (always null without a rule outcome).</summary>
        public int? RuleRank { get { return ruleRank; } }

        /// <summary>The reference of the rule that decided the window ("preset launcher-prefix", "rule n: ..."); null when none.</summary>
        public string RuleReference { get { return ruleReference; } }

        /// <summary>Timeout diagnostics raised while evaluating this window's tabs; empty without a rule outcome.</summary>
        public RuleDiagnostic[] RuleDiagnostics { get { return (RuleDiagnostic[])ruleDiagnostics.Clone(); } }

        public WindowIdentity Identity { get; private set; }
        public TabReadQuality TabReadQuality { get; private set; }
        public bool HasTrustedCompleteTabs { get { return TabReadQuality == TabReadQuality.Trusted && tabs.Length > 0; } }
        public IntPtr Handle { get { return handle; } }

        /// <summary>The monitor attribution passed through from acquisition; null when unattributed.</summary>
        public MonitorInfo Monitor { get { return monitor; } }

        /// <summary>The current-desktop status passed through from acquisition.</summary>
        public DesktopFlagResult DesktopStatus { get { return desktopStatus; } }
        public TabSnapshot[] Tabs { get { return (TabSnapshot[])tabs.Clone(); } }
        public bool Identified { get { return identified; } }

        /// <summary>The stripped titles of the unmatched tabs, in tab order.</summary>
        public string[] UnmatchedTitles { get { return (string[])unmatchedTitles.Clone(); } }
        public bool Mergeable { get { return mergeable; } }

        public override string ToString()
        {
            return string.Format("{0}|tabs={1}|identified={2}|mergeable={3}", handle, tabs.Length, identified, mergeable);
        }
    }

    /// <summary>
    /// Composes the acquisition outputs into the ordered window list (REQ-CMP-001):
    /// per window, the tab titles (the UIA success list, or the single GetWindowText
    /// fallback title on a failed read) are matched against the open-session set, and
    /// the snapshot carries per-tab sessions, identification, unmatched titles and
    /// merge eligibility, ready for zone assignment (SPEC-ZONE-005). Window order is
    /// the given ZOrder; inputs are never mutated.
    /// </summary>
    public static class WindowSnapshotBuilder
    {
        // @MX:NOTE: REQ-CMP-001 composition home (plan.md F file 1); ordering belongs to the caller's ZOrder.
        // Equals the overload with a preset-only rule set (SPEC-RULES-008 REQ-ID-001).
        public static WindowSnapshot[] Compose(AcquiredWindow[] windows, SessionRecord[] sessions)
        {
            return Compose(windows, sessions, RuleSet.PresetOnly());
        }

        /// <summary>
        /// Composes with a rule set: session binding is exactly as the two-argument overload (the matcher
        /// never sees the rules), and each snapshot carries the rule outcome of its window. A null rule set
        /// means no rules at all (preset off).
        /// </summary>
        // @MX:NOTE: one breaker state per compose (SPEC-RULES-010): a regex rule that times out twice is skipped for the rest of the call and nothing carries to the next one.
        public static WindowSnapshot[] Compose(AcquiredWindow[] windows, SessionRecord[] sessions, RuleSet rules)
        {
            return Compose(windows, sessions, rules, null);
        }

        /// <summary>
        /// Composes with a rule set and a caller-supplied breaker state shared by every window and tab of
        /// the call; the state is neither reset nor discarded. A null state becomes a fresh state for this
        /// call, which is exactly the three-argument overload.
        /// </summary>
        // @MX:NOTE: the seam for a later cross-compose cache: a caller that keeps one state across calls carries its trips with it (SPEC-RULES-010).
        public static WindowSnapshot[] Compose(AcquiredWindow[] windows, SessionRecord[] sessions, RuleSet rules, RuleEvaluationState state)
        {
            List<WindowSnapshot> snapshots = new List<WindowSnapshot>();
            if (windows == null)
            {
                return snapshots.ToArray();
            }
            RuleSet effectiveRules = rules ?? RuleSetBuilder.Build(null, false);
            RuleEvaluationState scope = state ?? new RuleEvaluationState();
            foreach (AcquiredWindow window in windows)
            {
                if (window == null)
                {
                    continue;
                }
                WindowMatchResult match = SessionMatcher.Match(ResolveTitles(window.Titles), sessions);
                string windowTitle = window.Identity == null ? null : window.Identity.RawWindowTitle;
                WindowRuleOutcome outcome = RuleEvaluator.EvaluateWindow(effectiveRules, match.Tabs, windowTitle, scope);
                snapshots.Add(new WindowSnapshot(window.Identity, window.Monitor, window.DesktopStatus,
                    match.Tabs, match.Identified, match.UnmatchedTitles, match.Mergeable,
                    window.Titles == null ? TabReadQuality.Fallback : window.Titles.Quality, outcome));
            }
            return snapshots.ToArray();
        }

        /// <summary>The effective titles: the success list, the single fallback title on failure, or none.</summary>
        private static string[] ResolveTitles(TabTitleResult titles)
        {
            if (titles == null)
            {
                return new string[0];
            }
            if (titles.Success)
            {
                return titles.Titles;
            }
            if (!string.IsNullOrEmpty(titles.FallbackTitle))
            {
                return new string[] { titles.FallbackTitle };
            }
            return new string[0];
        }
    }
}
