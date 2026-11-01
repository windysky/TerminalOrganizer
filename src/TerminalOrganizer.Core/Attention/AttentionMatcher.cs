using System;
using System.Collections.Generic;
using System.Text;

namespace TerminalOrganizer.Core.Attention
{
    /// <summary>
    /// The producer-exact matching rule (REQ-MAT-001/002, spec.md 1.3 evidence): a title
    /// is normalized as lowercase invariant with every non-letter/non-digit character
    /// removed (NO camel-case or digit-boundary splitting — the revision-0.1.0 camel
    /// rule was stricter than the producer and is withdrawn, plan.md A-3), and a title
    /// matches a needle when every whitespace-split needle token's normalized form
    /// occurs in the normalized title as an Ordinal substring. All tokens must co-occur
    /// in ONE title (the window title or a single tab title). Pure by contract (NFR-2):
    /// reads no file, clock or process, never throws.
    /// </summary>
    // @MX:NOTE: this rule is the producer contract, replicated exactly; one deliberate divergence below.
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
        /// The handles of every candidate whose window title, or at least one of its tab
        /// titles, matches the needle (REQ-MAT-002) — deduplicated by handle, in the
        /// candidates' input order. A null needle or candidate list yields an empty
        /// result; never throws.
        /// </summary>
        public static long[] Match(string needle, AttentionCandidate[] candidates)
        {
            List<long> handles = new List<long>();
            if (string.IsNullOrEmpty(needle) || candidates == null)
            {
                return handles.ToArray();
            }
            string[] tokens = NeedleTokens(needle);
            if (tokens.Length == 0)
            {
                // Zero tokens: no match (the pinned divergence; the producer would match everything).
                return handles.ToArray();
            }
            foreach (AttentionCandidate candidate in candidates)
            {
                if (candidate == null)
                {
                    continue;
                }
                if (!TitleMatches(tokens, candidate.WindowTitle)
                    && !AnyTabMatches(tokens, candidate.TabTitles))
                {
                    continue;
                }
                long handle = candidate.Handle.ToInt64();
                if (!handles.Contains(handle))
                {
                    handles.Add(handle);
                }
            }
            return handles.ToArray();
        }

        private static bool AnyTabMatches(string[] tokens, string[] tabTitles)
        {
            if (tabTitles == null)
            {
                return false;
            }
            foreach (string title in tabTitles)
            {
                if (TitleMatches(tokens, title))
                {
                    return true;
                }
            }
            return false;
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
