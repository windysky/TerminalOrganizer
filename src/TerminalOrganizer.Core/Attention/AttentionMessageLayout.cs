using System;

namespace TerminalOrganizer.Core.Attention
{
    /// <summary>
    /// SPEC-TRAY-016 (REQ-MSG-001): the message-text preparation — pure, never throws.
    /// A message renders verbatim up to MessageMaxChars (600) characters; beyond that
    /// the first MessageMaxChars - 3 characters render followed by one ellipsis
    /// character (597 + U+2026; plan.md section J).
    /// </summary>
    public static class AttentionMessageText
    {
        /// <summary>
        /// True when the message renders a panel at all (REQ-MSG-002): absent, null,
        /// or whitespace-only is ring-only — no panel form is created.
        /// </summary>
        public static bool IsRenderable(string message)
        {
            if (string.IsNullOrEmpty(message))
            {
                return false;
            }
            return message.Trim().Length > 0;
        }

        /// <summary>
        /// The capped rendering text: verbatim up to MessageMaxChars, then
        /// MessageMaxChars - 3 characters + one ellipsis (U+2026). Null and empty
        /// pass through unchanged (the caller renders no panel for them anyway).
        /// </summary>
        public static string Prepare(string message)
        {
            if (string.IsNullOrEmpty(message))
            {
                return message;
            }
            if (message.Length <= AttentionConstants.MessageMaxChars)
            {
                return message;
            }
            return message.Substring(0, AttentionConstants.MessageMaxChars - 3) + "…";
        }
    }

    /// <summary>
    /// SPEC-TRAY-016 (REQ-MSG-002, AC-009): the pure panel placement — the solid
    /// near-black card as wide as the target window, anchored just below the
    /// target's bottom edge (one RingThicknessPx below, beside the ring's lower
    /// bar). t11 (the 2026-11-01 UX round) REPLACED the flip-above branch: when the
    /// below placement would cross the work-area bottom (a maximized target), the
    /// card docks INSIDE the target's right edge — starting MessageTopInsetPx below
    /// the top (never covering the title bar / tab strip), as wide as the preferred
    /// text width capped at half the target; a right column narrower than
    /// MessageMinColumnPx falls back INSIDE-BOTTOM (full target width, one ring
    /// thickness above the bottom edge). A pure function of its inputs (the
    /// AttentionOverlayGeometry discipline): no screen reads, never throws; a null
    /// or short target rect or work area degrades to zeros.
    /// </summary>
    public static class AttentionMessageLayout
    {
        /// <summary>
        /// The panel rectangle as (x, y, width, height): height = textHeight +
        /// 2 x MessagePaddingPx. Fits below when y = B + RingThicknessPx keeps
        /// y + height within the work area (equality fits); otherwise inside-right —
        /// x = R - panelWidth, y = T + MessageTopInsetPx, panelWidth = min(preferred,
        /// targetWidth / 2) with preferred = textWidth + 2 x MessagePaddingPx — or,
        /// when targetWidth / 2 is narrower than MessageMinColumnPx, inside-bottom:
        /// x = target L, width = the target's own width, y = B - RingThicknessPx -
        /// height. textWidth is the measured text surface the form sizes its TextBox
        /// to (the preferred width the cap shrinks).
        /// </summary>
        public static int[] PlacePanel(int[] targetRect, int[] workArea, int textWidth, int textHeight)
        {
            if (targetRect == null || targetRect.Length < 4 || workArea == null || workArea.Length < 4)
            {
                return new int[] { 0, 0, 0, 0 };
            }
            int left = targetRect[0];
            int top = targetRect[1];
            int right = targetRect[2];
            int bottom = targetRect[3];
            int width = right - left;
            int height = textHeight + 2 * AttentionConstants.MessagePaddingPx;
            int y = bottom + AttentionConstants.RingThicknessPx;
            if (y + height <= workArea[3])
            {
                return new int[] { left, y, width, height };
            }
            // t11: the work area ends below — inside-right, unless the right column
            // is too narrow to host a readable card.
            int column = width / 2;
            if (column >= AttentionConstants.MessageMinColumnPx)
            {
                int preferred = textWidth + 2 * AttentionConstants.MessagePaddingPx;
                int panelWidth = Math.Min(preferred, column);
                return new int[] { right - panelWidth, top + AttentionConstants.MessageTopInsetPx, panelWidth, height };
            }
            y = bottom - AttentionConstants.RingThicknessPx - height;
            return new int[] { left, y, width, height };
        }
    }

    /// <summary>
    /// t13 (the 2026-11-01 UX round): the kind-scoped text color of the message card.
    /// The kind axis reaches the panel through the extended panel-message seam (the
    /// controller publishes the kind beside the message); the mapping is pinned:
    /// ask renders red, info renders the ring amber, and stop / absent / unknown
    /// degrade to the near-white default (the closed token set mirrors the
    /// controller's — an unknown kind is never a rendering failure).
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
