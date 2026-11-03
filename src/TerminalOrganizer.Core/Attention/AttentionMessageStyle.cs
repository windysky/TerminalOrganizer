using System;

namespace TerminalOrganizer.Core.Attention
{
    /// <summary>
    /// t13 (the 2026-11-01 UX round): the kind-scoped text color of the message card.
    /// The kind axis reaches the panel through the widened panel seam (SPEC-TRAY-017
    /// REQ-OVL-002: the controller publishes the kind with the message through one
    /// atomic publish); the mapping is pinned: ask renders red, info renders the ring
    /// amber, and stop / absent / unknown degrade to the near-white default (the
    /// closed token set mirrors the controller's — an unknown kind is never a
    /// rendering failure).
    /// </summary>
    public static class AttentionMessageStyle
    {
        /// <summary>The text color for one attention kind: ask → MessageAskTextRgb (red);
        /// info → RingColorRgb (the ring amber); stop, absent, and any unknown kind →
        /// MessageTextRgb (near-white).</summary>
        public static int TextColorRgbForKind(string kind)
        {
            if (string.Equals(kind, "ask", StringComparison.Ordinal))
            {
                return AttentionConstants.MessageAskTextRgb;
            }
            if (string.Equals(kind, "info", StringComparison.Ordinal))
            {
                return AttentionConstants.RingColorRgb;
            }
            return AttentionConstants.MessageTextRgb;
        }
    }
}
