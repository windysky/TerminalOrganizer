using System;
using System.Collections.Generic;
using System.Text;
using TerminalOrganizer.Core.Windows;

namespace TerminalOrganizer.Core.Attention
{
    /// <summary>
    /// The producer-exact matching rule (REQ-MAT-001/002, spec.md 1.3 evidence): a title
    /// is normalized as lowercase invariant with every non-letter/non-digit character
    /// removed (NO camel-case or digit-boundary splitting — the revision-0.1.0 camel
    /// rule was stricter than the producer and is withdrawn, plan.md A-3), and a title
    /// matches a needle when every whitespace-split needle token's normalized form
    /// occurs in the normalized title as an Ordinal substring. All tokens must co-occur
    /// in ONE title. SPEC-TRAY-019 (REQ-STM-001): the eligible titles are exactly the
    /// candidate's SESSION titles — every title among its window title and tab titles
    /// for which TitleNormalizer.Parse reports PrefixPresent — and the token rule
    /// applies to the stripped SessionTitle; a title without a valid launcher prefix
    /// never produces a match (a path tab legitimately contains session-name
    /// substrings after normalization, and never rings its window). Pure by contract
    /// (NFR-2, REQ-STM-007): reads no file, clock or process, never throws, and
    /// obtains session titles solely through TitleNormalizer.Parse.
    /// </summary>
    // @MX:NOTE: this rule is the producer contract, replicated exactly; one deliberate divergence below.
    // @MX:NOTE: SPEC-TRAY-019 session-title lens — grammar knowledge stays in TitleNormalizer (REQ-STM-007).
    public static class AttentionMatcher
    {
        /// <summary>
        /// The normalized form (REQ-MAT-001): the string lowercased with the invariant
        /// culture, every character for which char.IsLetterOrDigit is false removed, the
        /// rest concatenated in order. Deterministic; never throws.
        /// </summary>
        public static string Normalize(string value)
        {
            if (string.IsNullOrEmpty(value))
            {
                return string.Empty;
            }
            string lowered = value.ToLowerInvariant();
            StringBuilder builder = new StringBuilder(lowered.Length);
            for (int i = 0; i < lowered.Length; i++)
            {
                if (char.IsLetterOrDigit(lowered[i]))
                {
                    builder.Append(lowered[i]);
                }
            }
            return builder.ToString();
        }

        /// <summary>
        /// The needle tokens (REQ-MAT-002): the whitespace-split parts of the needle,
        /// each normalized, with empty-normalized tokens dropped. A needle that leaves
        /// zero tokens matches nothing — the ONE deliberate divergence from the producer,
        /// whose all-empty token set vacuously matches every window; the safer variant
        /// is pinned here. Duplicate tokens and token order are both harmless.
        /// </summary>
        public static string[] NeedleTokens(string needle)
        {
            List<string> tokens = new List<string>();
            if (string.IsNullOrEmpty(needle))
            {
                return tokens.ToArray();
            }
            string[] parts = needle.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
            foreach (string part in parts)
            {
                string normalized = Normalize(part);
                if (normalized.Length > 0)
                {
                    tokens.Add(normalized);
                }
            }
            return tokens.ToArray();
        }

        /// <summary>
        /// The handles of every candidate with at least one matching session title
        /// (REQ-STM-001: the prefix-present titles of the window and its tabs, stripped) —
        /// deduplicated by handle, in the candidates' input order. A thin handles-only
        /// projection of MatchDetailed (the signature is pinned by the suites); a null
        /// needle or candidate list yields an empty result; never throws.
        /// </summary>
        public static long[] Match(string needle, AttentionCandidate[] candidates)
        {
            AttentionMatchDetail[] details = MatchDetailed(needle, candidates);
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

        /// <summary>
        /// The per-candidate verdicts of one match run (SPEC-TRAY-019 REQ-STM-005 evidence
        /// model, plan.md A-2): one detail per non-null candidate, in input order. The FIRST
        /// eligible matching surface attributes the match reason (window title first, then
        /// tabs in input order — deterministic). A needle of zero tokens matches nothing (the
        /// pinned divergence) and suppresses nothing, but still reports session titles. Never
        /// throws.
        /// </summary>
        // @MX:NOTE: SPEC-TRAY-019 MatchDetailed — the controller logs these verdicts as the plan.md A-3 detail lines.
        public static AttentionMatchDetail[] MatchDetailed(string needle, AttentionCandidate[] candidates)
        {
            List<AttentionMatchDetail> results = new List<AttentionMatchDetail>();
            if (string.IsNullOrEmpty(needle) || candidates == null)
            {
                return results.ToArray();
            }
            string[] tokens = NeedleTokens(needle);
            foreach (AttentionCandidate candidate in candidates)
            {
                if (candidate == null)
                {
                    continue;
                }
                results.Add(EvaluateCandidate(tokens, candidate));
            }
            return results.ToArray();
        }

        /// <summary>Evaluates one candidate: session titles collected in order, first match attributed, first would-have-rung non-session title recorded when unmatched.</summary>
        private static AttentionMatchDetail EvaluateCandidate(string[] tokens, AttentionCandidate candidate)
        {
            // Zero tokens: no match and no suppression (a token occurrence is only meaningful with tokens).
            bool canMatch = tokens.Length > 0;
            long handle = candidate.Handle.ToInt64();
            string matchedSessionTitle = null;
            string suppressedTitle = null;
            List<string> sessionTitles = new List<string>();
            EvaluateTitle(tokens, canMatch, candidate.WindowTitle, sessionTitles, ref matchedSessionTitle, ref suppressedTitle);
            string[] tabTitles = candidate.TabTitles;
            for (int i = 0; i < tabTitles.Length; i++)
            {
                EvaluateTitle(tokens, canMatch, tabTitles[i], sessionTitles, ref matchedSessionTitle, ref suppressedTitle);
            }
            bool matched = matchedSessionTitle != null;
            if (matched)
            {
                // A matched window has no suppressed over-match to report — its ring is correct.
                suppressedTitle = null;
            }
            return new AttentionMatchDetail(handle, matched, matchedSessionTitle, suppressedTitle, sessionTitles.ToArray());
        }

        /// <summary>One title through the lens: a prefix-present title joins the session list and may attribute the match; a non-session title may attribute a suppression.</summary>
        private static void EvaluateTitle(string[] tokens, bool canMatch, string title,
            List<string> sessionTitles, ref string matchedSessionTitle, ref string suppressedTitle)
        {
            NormalizedTitle parsed = TitleNormalizer.Parse(title);
            if (parsed.PrefixPresent)
            {
                sessionTitles.Add(parsed.SessionTitle);
                if (canMatch && matchedSessionTitle == null && TitleMatches(tokens, parsed.SessionTitle))
                {
                    matchedSessionTitle = parsed.SessionTitle;
                }
                return;
            }
            if (canMatch && suppressedTitle == null && TitleMatches(tokens, title))
            {
                suppressedTitle = title;
            }
        }

        /// <summary>Every token's normalized form occurs in the title's normalized form (Ordinal substring).</summary>
        private static bool TitleMatches(string[] tokens, string title)
        {
            if (string.IsNullOrEmpty(title))
            {
                return false;
            }
            string normalized = Normalize(title);
            if (normalized.Length == 0)
            {
                return false;
            }
            for (int i = 0; i < tokens.Length; i++)
            {
                if (normalized.IndexOf(tokens[i], StringComparison.Ordinal) < 0)
                {
                    return false;
                }
            }
            return true;
        }
    }
}
