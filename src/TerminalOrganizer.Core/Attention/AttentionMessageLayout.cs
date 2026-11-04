using System;

namespace TerminalOrganizer.Core.Attention
{
    /// <summary>
    /// SPEC-TRAY-016 (REQ-MSG-002): the pure panel placement of the solid near-black
    /// card. t17 (2026-11-04) REMOVED the AC-009 below-the-target branch: in a zoned
    /// layout the space below a window belongs to the neighbouring window, so the
    /// card now ALWAYS stays inside its own target. It docks INSIDE the target's
    /// right edge (the t11 rule, formerly only the maximized-target fallback) —
    /// starting MessageTopInsetPx below the top (never covering the title bar / tab
    /// strip), as wide as the preferred text width capped at half the target; a right
    /// column narrower than MessageMinColumnPx falls back INSIDE-BOTTOM (full target
    /// width, one ring thickness above the bottom edge). A pure function of its
    /// inputs (the AttentionOverlayGeometry discipline): no screen reads, never
    /// throws; a null or short target rect or work area degrades to zeros (the work
    /// area is still validated but no longer steers the placement).
    /// </summary>
    public static class AttentionMessageLayout
    {
        /// <summary>
        /// The panel rectangle as (x, y, width, height): height = textHeight +
        /// 2 x MessagePaddingPx. Inside-right —
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
            // t17: the card always stays inside its own target — the space below a
            // zoned window belongs to the neighbouring window. Inside-right, unless
            // the right column is too narrow to host a readable card.
            int column = width / 2;
            if (column >= AttentionConstants.MessageMinColumnPx)
            {
                int preferred = textWidth + 2 * AttentionConstants.MessagePaddingPx;
                int panelWidth = Math.Min(preferred, column);
                return new int[] { right - panelWidth, top + AttentionConstants.MessageTopInsetPx, panelWidth, height };
            }
            int y = bottom - AttentionConstants.RingThicknessPx - height;
            return new int[] { left, y, width, height };
        }
    }
}
