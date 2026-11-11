using System;
using TerminalOrganizer.Core.Rules;

namespace TerminalOrganizer.Core.Windows
{
    /// <summary>
    /// Strips the launcher's window-name prefix from a tab title (REQ-TTL-001): exactly one
    /// leading prefix of the form [OHNW][CGDA]_ or [OHNW][CGDA]&lt;digit&gt;_ — case-sensitive,
    /// uppercase classes, a SINGLE rank digit (C1; multi-digit needs a future grammar change).
    /// A title without a valid prefix returns unchanged; a second prefix survives (a
    /// window_name may itself contain '_'). An empty session title after a prefix is invalid
    /// and is not stripped. Never throws; null passes through as null. The grammar itself lives
    /// in the launcher-prefix preset (SPEC-RULES-008); this class is the adapter.
    /// </summary>
    public static class TitleNormalizer
    {
        // @MX:NOTE: adapter over LauncherPrefixPreset (the single home of the C1 grammar); the matcher path
        // (StripPrefix) and the priority model (DeclaredRank) both consume it. Session binding stays on this
        // path whatever rule set is configured; the rank digit is never a family/context letter.
        public static NormalizedTitle Parse(string title)
        {
            return LauncherPrefixPreset.Parse(title);
        }

        // @MX:NOTE: one-prefix rule, product.md decision 1 (OC_YODA1 -> YODA1; NG_AB_X -> AB_X, not X);
        // delegates to Parse so matcher code and the grammar can never disagree.
        public static string StripPrefix(string title)
        {
            NormalizedTitle parsed = Parse(title);
            return parsed.SessionTitle;
        }
    }
}
