using System;
using System.Text.RegularExpressions;
using TerminalOrganizer.Core.Windows;

namespace TerminalOrganizer.Core.Rules
{
    /// <summary>
    /// The built-in preset launcher-prefix (REQ-PRE-001): the launcher's title grammar as a rule.
    /// One leading token of a family letter from O H N W, a context letter from C G D A, an optional
    /// single ASCII digit and '_', followed by a non-empty session title; case-sensitive. The session
    /// title is the identity name (later underscores kept) and the digit is the rank. The expression
    /// runs without a match timeout on purpose: its shape is linear, and a bound would make session
    /// binding depend on machine load.
    /// </summary>
    // @MX:NOTE: the single home of the launcher grammar; infinite timeout on purpose; parity pinned by AC-008.
    public static class LauncherPrefixPreset
    {
        /// <summary>The preset name.</summary>
        public const string Name = "launcher-prefix";

        /// <summary>The provenance reference of a decision made by this preset.</summary>
        public const string Reference = "preset launcher-prefix";

        /// <summary>The grammar (plan.md J.1).</summary>
        public const string Pattern = @"^(?<family>[OHNW])(?<context>[CGDA])(?<rank>[0-9])?_(?<name>[\s\S]+)\z";

        private static readonly Regex PresetRegex =
            new Regex(Pattern, RegexOptions.CultureInvariant, Regex.InfiniteMatchTimeout);

        /// <summary>The match timeout of the preset expression (Regex.InfiniteMatchTimeout).</summary>
        public static TimeSpan MatchTimeout { get { return PresetRegex.MatchTimeout; } }

        /// <summary>The preset as a compiled rule, evaluated before every user rule.</summary>
        public static CompiledRule CreateRule()
        {
            return new CompiledRule(0, RuleKind.Regex, RuleSubject.Title, Pattern, null, PresetRegex,
                null, null, Reference, true);
        }

        /// <summary>
        /// Parses a tab title with the grammar. A title without a valid prefix comes back unchanged
        /// (PrefixPresent false); null passes through as null. Never throws.
        /// </summary>
        public static NormalizedTitle Parse(string title)
        {
            if (title == null)
            {
                return new NormalizedTitle(null, null, false, null);
            }
            Match match = PresetRegex.Match(title);
            if (!match.Success)
            {
                return new NormalizedTitle(title, title, false, null);
            }
            Group rank = match.Groups["rank"];
            int? declaredRank = rank.Success ? (int?)(rank.Value[0] - '0') : null;
            return new NormalizedTitle(title, match.Groups["name"].Value, true, declaredRank);
        }
    }
}
