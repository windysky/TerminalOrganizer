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
}
