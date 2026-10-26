using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using TerminalOrganizer.Core.Windows;

namespace TerminalOrganizer.Core.Rules
{
    /// <summary>
    /// Evaluates a compiled RuleSet against tab titles and launcher-session command lines
    /// (REQ-RUL-001..005). Pure and deterministic (NFR-4): no clock, file or registry access.
    /// The first matching rule decides; later rules are not consulted. Evaluation never throws
    /// to its caller for any input, null included.
    /// </summary>
    public static class RuleEvaluator
    {
        private const string NameGroup = "name";
        private const string RankGroup = "rank";
        private const string TimeoutReason = "regex timeout";
        private const string SkippedReason = "regex timeout (skipped after repeated timeouts)";

        /// <summary>
        /// Evaluates one tab. The commandLine is the command line of the launcher session the tab
        /// is bound to, or null when the tab is bound to no session; a commandline rule never
        /// matches a null command line. An unmatched tab, or a matched rule that names no one,
        /// is named by its trimmed title (null when the title is blank). Stateless: no rule is
        /// ever skipped.
        /// </summary>
        // @MX:NOTE: deliberately stateless; one tab runs each rule once, so per-tab semantics are unchanged by the breaker (SPEC-RULES-010).
        public static TabRuleResult EvaluateTab(RuleSet rules, string title, string commandLine)
        {
            return EvaluateTab(rules, title, commandLine, null);
        }

        /// <summary>
        /// Evaluates one tab against a caller-supplied breaker state: a regex rule tripped in the
        /// state is skipped, and a regex timeout is recorded in it. A null state means no breaker.
        /// </summary>
        public static TabRuleResult EvaluateTab(RuleSet rules, string title, string commandLine, RuleEvaluationState state)
        {
            string fallbackName = IsBlank(title) ? null : title.Trim();
            List<RuleDiagnostic> diagnostics = new List<RuleDiagnostic>();
            if (rules != null)
            {
                foreach (CompiledRule rule in rules.Rules)
                {
                    string name;
                    int? rank;
                    if (Apply(rule, title, commandLine, fallbackName, state, diagnostics, out name, out rank))
                    {
                        return new TabRuleResult(true, name, rank, rule.Reference, diagnostics.ToArray());
                    }
                }
            }
            return new TabRuleResult(false, fallbackName, null, null, diagnostics.ToArray());
        }

        /// <summary>
        /// Evaluates one window from its matched tabs (REQ-ID-001): the identity name of the first
        /// tab; the rank of the first tab, in tab order, whose matched rule yields one; one
        /// reference (the rank-supplying rule's when a rank exists, else the first tab's matched
        /// rule, else null). A window with no tab is named by its trimmed window title and carries
        /// no rank or reference. The tab session, when bound, supplies the command-line subject.
        /// </summary>
        // @MX:ANCHOR: [AUTO] window rule-outcome entry — the identity and rule rank of every window funnel here.
        // @MX:REASON: SPEC-RULES-009 consumers (manager candidacy, labels, assignment, overflow priority) depend on this one result.
        public static WindowRuleOutcome EvaluateWindow(RuleSet rules, TabSnapshot[] tabs, string windowTitle)
        {
            return EvaluateWindow(rules, tabs, windowTitle, null);
        }

        /// <summary>
        /// Evaluates one window against a caller-supplied breaker state shared by all its tabs (and by
        /// every other window the caller evaluates with the same state). A null state becomes a fresh
        /// state for this window alone.
        /// </summary>
        public static WindowRuleOutcome EvaluateWindow(RuleSet rules, TabSnapshot[] tabs, string windowTitle, RuleEvaluationState state)
        {
            List<RuleDiagnostic> diagnostics = new List<RuleDiagnostic>();
            if (tabs == null || tabs.Length == 0)
            {
                return new WindowRuleOutcome(IsBlank(windowTitle) ? null : windowTitle.Trim(), null, null, diagnostics.ToArray());
            }
            RuleEvaluationState scope = state ?? new RuleEvaluationState();
            string identityName = null;
            string firstReference = null;
            int? rank = null;
            string rankReference = null;
            for (int i = 0; i < tabs.Length; i++)
            {
                TabSnapshot tab = tabs[i];
                string title = tab == null ? null : tab.Title;
                string commandLine = tab == null || tab.Session == null ? null : tab.Session.CommandLine;
                TabRuleResult result = EvaluateTab(rules, title, commandLine, scope);
                diagnostics.AddRange(result.Diagnostics);
                if (i == 0)
                {
                    identityName = result.Name;
                    firstReference = result.Reference;
                }
                if (!rank.HasValue && result.Rank.HasValue)
                {
                    rank = result.Rank;
                    rankReference = result.Reference;
                }
            }
            return new WindowRuleOutcome(identityName, rank, rank.HasValue ? rankReference : firstReference, diagnostics.ToArray());
        }

        /// <summary>Applies one rule; true when it matched, with the sourced name and rank.</summary>
        private static bool Apply(CompiledRule rule, string title, string commandLine, string fallbackName,
            RuleEvaluationState state, List<RuleDiagnostic> diagnostics, out string name, out int? rank)
        {
            name = null;
            rank = null;
            string subject = rule.Subject == RuleSubject.CommandLine ? commandLine : title;
            if (subject == null)
            {
                return false;
            }

            string captureName = null;
            int? captureRank = null;
            switch (rule.Kind)
            {
                case RuleKind.Glob:
                    if (!GlobMatch(rule.Pattern, subject))
                    {
                        return false;
                    }
                    break;
                case RuleKind.Regex:
                    // A rule tripped in this scope does not run its regular expression again; it still reports.
                    if (state != null && state.IsTripped(rule))
                    {
                        state.RecordSkip();
                        diagnostics.Add(new RuleDiagnostic(rule.Position, SkippedReason));
                        return false;
                    }
                    try
                    {
                        // @MX:WARN: user-supplied pattern runs here; the 100 ms timeout compiled into the Regex is the bound, and a rule is skipped after its second timeout in the scope.
                        // @MX:REASON: catastrophic backtracking would otherwise stall every window evaluation; a timeout becomes a diagnostic and a no-match, and the second one trips the rule for the rest of the scope.
                        Match match = rule.Regex.Match(subject);
                        if (!match.Success)
                        {
                            return false;
                        }
                        Group nameGroup = match.Groups[NameGroup];
                        if (nameGroup.Success && !IsBlank(nameGroup.Value))
                        {
                            captureName = nameGroup.Value;
                        }
                        Group rankGroup = match.Groups[RankGroup];
                        if (rankGroup.Success)
                        {
                            captureRank = ParseRank(rankGroup.Value);
                        }
                    }
                    catch (RegexMatchTimeoutException)
                    {
                        if (state != null)
                        {
                            state.RecordTimeout(rule);
                        }
                        diagnostics.Add(new RuleDiagnostic(rule.Position, TimeoutReason));
                        return false;
                    }
                    break;
                case RuleKind.Marker:
                    int markerRank;
                    string markerName;
                    if (!TryMarker(rule.Marker, subject, out markerRank, out markerName))
                    {
                        return false;
                    }
                    // REQ-RUL-003: the marker supplies both the rank and the name; fixed name/rank are not consulted.
                    name = IsBlank(markerName) ? fallbackName : markerName;
                    rank = markerRank;
                    return true;
                default:
                    return false;
            }

            if (captureName != null)
            {
                name = captureName;
            }
            else if (!IsBlank(rule.FixedName))
            {
                name = rule.FixedName;
            }
            else
            {
                name = fallbackName;
            }
            rank = captureRank.HasValue ? captureRank : rule.FixedRank;
            return true;
        }

        /// <summary>
        /// Whole-subject glob: * matches any run including none, ? matches exactly one character
        /// (one UTF-16 unit), everything else matches itself; case is folded ordinally, so the
        /// outcome never depends on the current culture (REQ-RUL-002).
        /// </summary>
        public static bool GlobMatch(string pattern, string text)
        {
            if (pattern == null || text == null)
            {
                return false;
            }
            int p = 0;
            int t = 0;
            int star = -1;
            int mark = 0;
            while (t < text.Length)
            {
                if (p < pattern.Length && pattern[p] == '*')
                {
                    star = p;
                    p++;
                    mark = t;
                }
                else if (p < pattern.Length && (pattern[p] == '?' || SameChar(pattern[p], text[t])))
                {
                    p++;
                    t++;
                }
                else if (star >= 0)
                {
                    p = star + 1;
                    mark++;
                    t = mark;
                }
                else
                {
                    return false;
                }
            }
            while (p < pattern.Length && pattern[p] == '*')
            {
                p++;
            }
            return p == pattern.Length;
        }

        private static bool SameChar(char a, char b)
        {
            return a == b || char.ToUpperInvariant(a) == char.ToUpperInvariant(b);
        }

        /// <summary>
        /// Finds the first marker token: the marker text (ordinal, case-sensitive) followed by one
        /// to three ASCII digits, bounded by the title start or whitespace before and the title end
        /// or whitespace after. The name is the title with the token removed, the whitespace left
        /// behind collapsed to one space, and the result trimmed (REQ-RUL-003).
        /// </summary>
        private static bool TryMarker(string marker, string title, out int rank, out string name)
        {
            rank = 0;
            name = null;
            if (string.IsNullOrEmpty(marker))
            {
                return false;
            }
            int from = 0;
            while (from <= title.Length - marker.Length)
            {
                int index = title.IndexOf(marker, from, StringComparison.Ordinal);
                if (index < 0)
                {
                    return false;
                }
                int digitsStart = index + marker.Length;
                int end = digitsStart;
                while (end < title.Length && title[end] >= '0' && title[end] <= '9')
                {
                    end++;
                }
                int digits = end - digitsStart;
                bool leftBounded = index == 0 || char.IsWhiteSpace(title[index - 1]);
                bool rightBounded = end == title.Length || char.IsWhiteSpace(title[end]);
                if (digits >= 1 && digits <= 3 && leftBounded && rightBounded)
                {
                    rank = int.Parse(title.Substring(digitsStart, digits), System.Globalization.CultureInfo.InvariantCulture);
                    string before = title.Substring(0, index).TrimEnd();
                    string after = title.Substring(end).TrimStart();
                    string joined = before.Length > 0 && after.Length > 0 ? before + " " + after : before + after;
                    name = joined.Trim();
                    return true;
                }
                from = index + 1;
            }
            return false;
        }

        /// <summary>A rank capture counts only when it is ASCII digits only and within 0..999.</summary>
        private static int? ParseRank(string text)
        {
            if (string.IsNullOrEmpty(text))
            {
                return null;
            }
            long value = 0;
            foreach (char c in text)
            {
                if (c < '0' || c > '9')
                {
                    return null;
                }
                value = value * 10 + (c - '0');
                if (value > RuleSetBuilder.RankMax)
                {
                    return null;
                }
            }
            return (int)value;
        }

        private static bool IsBlank(string text)
        {
            return string.IsNullOrWhiteSpace(text);
        }
    }
}
