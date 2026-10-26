using System;
using System.Collections.Generic;

namespace TerminalOrganizer.Core.Rules
{
    /// <summary>
    /// The breaker memory of one evaluation scope (SPEC-RULES-010): how many times each regex rule
    /// ran to its time bound, which rules are tripped, and three counters. A regex rule that times
    /// out a second time in the scope is tripped and skipped for the rest of the scope. The state
    /// is the only mutable data the evaluator touches; the caller owns its lifetime (one compose,
    /// one window, or whatever span the caller chooses). Not thread-safe: one scope runs on one
    /// thread. Glob rules, marker rules and the built-in preset are never counted or tripped.
    /// </summary>
    // @MX:ANCHOR: [AUTO] every regex-timeout decision of the evaluator funnels through this one state (fan_in: EvaluateTab, EvaluateWindow, Compose, tests).
    // @MX:REASON: a later cross-compose cache seeds this type; the recording operations stay internal so a caller cannot forge a trip.
    public sealed class RuleEvaluationState
    {
        /// <summary>The executed timeout at which a regex rule trips (the second one in the scope).</summary>
        private const int TripThreshold = 2;

        private const string KeySeparator = "|";

        private readonly Dictionary<string, int> timeoutsByRule = new Dictionary<string, int>(StringComparer.Ordinal);
        private readonly HashSet<string> tripped = new HashSet<string>(StringComparer.Ordinal);
        private int timeoutCount;
        private int skippedCount;

        /// <summary>Regex runs that reached their time bound in this scope.</summary>
        public int TimeoutCount { get { return timeoutCount; } }

        /// <summary>Evaluations in which a tripped rule was skipped instead of running its regular expression.</summary>
        public int SkippedCount { get { return skippedCount; } }

        /// <summary>Regex rules that have had their second executed timeout in this scope.</summary>
        public int TrippedCount { get { return tripped.Count; } }

        /// <summary>True when the rule is tripped in this scope; false for a null, non-regex or preset rule.</summary>
        public bool IsTripped(CompiledRule rule)
        {
            string key = KeyOf(rule);
            return key != null && tripped.Contains(key);
        }

        /// <summary>Records one executed timeout and trips the rule at its second; a non-regex or preset rule is ignored.</summary>
        internal void RecordTimeout(CompiledRule rule)
        {
            string key = KeyOf(rule);
            if (key == null)
            {
                return;
            }
            int seen;
            timeoutsByRule.TryGetValue(key, out seen);
            seen++;
            timeoutsByRule[key] = seen;
            timeoutCount++;
            if (seen >= TripThreshold)
            {
                tripped.Add(key);
            }
        }

        /// <summary>Records one skipped evaluation of a tripped rule.</summary>
        internal void RecordSkip()
        {
            skippedCount++;
        }

        /// <summary>
        /// The rule identity: position, subject and pattern text. A different pattern at the same
        /// position, or the same pattern on another subject, is a different rule. Null for a rule
        /// the state never tracks.
        /// </summary>
        private static string KeyOf(CompiledRule rule)
        {
            if (rule == null || rule.IsPreset || rule.Kind != RuleKind.Regex || rule.Regex == null)
            {
                return null;
            }
            return rule.Position.ToString(System.Globalization.CultureInfo.InvariantCulture)
                + KeySeparator + rule.Subject.ToString() + KeySeparator + rule.Pattern;
        }
    }
}
