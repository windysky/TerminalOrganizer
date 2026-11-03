using System;

namespace TerminalOrganizer.Core.Attention
{
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
}
