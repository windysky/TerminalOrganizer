using System;

namespace TerminalOrganizer.Core.Attention
{
    /// <summary>
    /// The SPEC-TRAY-013 named constants (plan.md section J): one class, one place —
    /// changing a value here is a SPEC amendment, never a tuning knob.
    /// </summary>
    // @MX:NOTE: pinned constants (plan.md section J); changing any value is a SPEC amendment.
    public static class AttentionConstants
    {
        /// <summary>Files older than this are stale: deleted without parsing (REQ-SIG-002; age exactly this is fresh).</summary>
        public const long SignalMaxAgeMs = 30000;

        /// <summary>The considered-file name pattern: att, a dash, digits-only epochms, a dash, the rest, .json.</summary>
        public const string SignalFilePattern = "^att-([0-9]+)-(.*)\\.json$";

        /// <summary>The signal-directory poll cadence of the attention controller (REQ-CTL-001).</summary>
        public const int PollIntervalMs = 500;

        /// <summary>The shared blink cadence of every active overlay (REQ-OVL-001).</summary>
        public const int BlinkIntervalMs = 500;

        /// <summary>The ring thickness of the overlay in physical pixels (REQ-OVL-001).</summary>
        public const int RingThicknessPx = 6;

        /// <summary>The organizer heartbeat cadence (REQ-HB-001): sits 3x inside the producer's 15 s window.</summary>
        // @MX:NOTE: pinned constant (SPEC-TRAY-016 plan.md section J); changing the value is a SPEC amendment.
        public const int HeartbeatIntervalMs = 5000;

        /// <summary>The amber ring color #FFBF00 (plan.md section J); the App overlay unpacks it into R/G/B.</summary>
        public const int RingColorRgb = 0xFFBF00;

        /// <summary>t18 (the 2026-11-04 UX round): the steady dim ring color #7F5F00 — the amber
        /// RingColorRgb at half brightness. A capped overlay (stop blink limit / info cap)
        /// keeps this non-blinking ring until the user attends to the window.</summary>
        public const int RingDimColorRgb = 0x7F5F00;

        /// <summary>t17 (the reverse-containment rule): the reverse rule applies only to a session
        /// title whose normalized form is at least this many characters long, so a very short tab name
        /// cannot ring a window just because it happens to occur inside a long needle.</summary>
        public const int MinReverseSessionLength = 4;

        /// <summary>t18: the tray notice raised when a consumed signal matches no window is shown at most
        /// once per needle (normalized as the matcher does) within this many milliseconds.</summary>
        public const long ZeroMatchNoticeCooldownMs = 60000;

        /// <summary>Card ask-sound: an ask-kind signal plays the notification sound at most once per needle
        /// (normalized as the matcher does) within this many milliseconds.</summary>
        public const long AskSoundCooldownMs = 10000;

        /// <summary>SPEC-TRAY-021 (plan.md section J): a pending zero-match ask re-raises the
        /// zero-match cue once this many minutes have passed since its last notify without a
        /// stop resolving it (REQ-WAK-003). At this pinned cadence neither per-needle cooldown
        /// can suppress a boundary re-notify (300 s over the 60 s notice and 10 s sound
        /// cooldowns); they guard re-fires only.</summary>
        // @MX:NOTE: pinned constant (SPEC-TRAY-021 plan.md section J); changing the value is a SPEC amendment.
        public const int AskRenotifyMinutes = 5;

        /// <summary>SPEC-TRAY-021 (plan.md section J): a pending ask with no stop expires --
        /// dropped with one log line and no final re-notify -- at this many minutes since its
        /// NEWEST ask (REQ-WAK-004; a re-fire refreshes the registration, so the bound reads
        /// how long the session has waited on its current question).</summary>
        // @MX:NOTE: pinned constant (SPEC-TRAY-021 plan.md section J); changing the value is a SPEC amendment.
        public const int AskPendingMaxAgeMinutes = 30;

        // @MX:NOTE: SPEC-TRAY-016 message-constant block (plan.md section J): the pinned
        // panel geometry/typography set — changing any value here is a SPEC amendment,
        // never a tuning knob (the same doctrine as every constant above).
        /// <summary>The rendered-text cap (REQ-MSG-001): verbatim up to this many characters,
        /// then three fewer characters plus a single ellipsis (597 + one U+2026).</summary>
        public const int MessageMaxChars = 600;

        /// <summary>The panel font size in physical pixels, GraphicsUnit.Pixel (NFR-7: no point/DPI math).</summary>
        public const int MessageFontPx = 14;

        /// <summary>The panel inner padding on all sides.</summary>
        public const int MessagePaddingPx = 10;

        /// <summary>The amber card border width (all four edges since 2026-11-05; was a left stripe); the color is RingColorRgb.</summary>
        public const int MessageAccentPx = 3;

        /// <summary>The panel background #1E1E1E (near-black, solid — the panel has NO TransparencyKey).</summary>
        public const int MessagePanelBackRgb = 0x1E1E1E;

        /// <summary>The panel text #EEEEEE (near-white).</summary>
        public const int MessageTextRgb = 0xEEEEEE;

        /// <summary>The close-affordance glyph and hit-target size (AM-6: panel-only dismissal).</summary>
        public const int MessageCloseSizePx = 16;

        /// <summary>t11 (the 2026-11-01 UX round): the inside-right top inset — the message
        /// card starts this far below the target's top edge, clear of the title bar and
        /// tab strip, when the below placement would cross the work-area bottom.</summary>
        public const int MessageTopInsetPx = 40;

        /// <summary>t11 (the 2026-11-01 UX round): the minimum half-target column that may
        /// host the inside-right card; a narrower right column falls back to inside-bottom
        /// placement (full target width, one ring thickness above the bottom edge).</summary>
        public const int MessageMinColumnPx = 280;

        /// <summary>t13 (the 2026-11-01 UX round): the ask-kind text color (red on the
        /// near-black card); info keeps the ring amber and every other kind the near-white
        /// default (AttentionMessageStyle).</summary>
        public const int MessageAskTextRgb = 0xE5484D;
    }

    /// <summary>
    /// One parsed attention event (REQ-SIG-001, extended SPEC-TRAY-016 REQ-FLD-001):
    /// the recorded fields of one signal payload. The needle is stored verbatim;
    /// notification_type is null unless the producer provided one (logging only, never
    /// matching). The additive kind/message fields ride the same optional-string rule
    /// (null when the key is absent, null, or non-string) so the producer may ship them
    /// on its own schedule. Public fields so the Pester suite reads them directly (the
    /// SettingsDto pattern).
    /// </summary>
    public sealed class AttentionSignal
    {
        public int Version;
        public string Event;
        public string NotificationType;
        public string SessionId;
        public string Cwd;
        public string Needle;
        public string Timestamp;

        /// <summary>The additive kind field (SPEC-TRAY-016 REQ-FLD-001): "ask" | "info" | "stop"
        /// once the producer ships it, null when the key is absent, null, or non-string. Recorded
        /// verbatim; the controller resolves the stop condition from it and degrades any
        /// unrecognized non-null value as absent with one log line (D-5) — never a rejection.</summary>
        public string Kind;

        /// <summary>The additive message field (SPEC-TRAY-016 REQ-FLD-001): the producer's reply
        /// first paragraph (at most 600 characters), null when the key is absent, null, or
        /// non-string. Recorded verbatim at parse; panel rendering is M3 (REQ-MSG-001).</summary>
        public string Message;

        /// <summary>The additive remote flag (wsl-toast v1.6.1): true exactly when the signal
        /// was PUSHED from another machine (a remote-viewer push or a background broadcast).
        /// False when the key is absent, false, or non-bool — a producer without the field is
        /// local, degrade-safe (the same additive-fields discipline as kind/message).</summary>
        public bool Remote;
    }

    /// <summary>
    /// Exactly one signal parse outcome (REQ-SIG-001): accepted carrying the recorded
    /// signal, or rejected with a non-empty reason. Immutable.
    /// </summary>
    public sealed class AttentionParseResult
    {
        private AttentionParseResult(bool accepted, AttentionSignal signal, string reason)
        {
            Accepted = accepted;
            Signal = signal;
            Reason = reason;
        }

        public bool Accepted { get; private set; }

        /// <summary>The recorded fields; null when rejected.</summary>
        public AttentionSignal Signal { get; private set; }

        /// <summary>The non-empty rejection reason; null when accepted.</summary>
        public string Reason { get; private set; }

        internal static AttentionParseResult Accept(AttentionSignal signal)
        {
            return new AttentionParseResult(true, signal, null);
        }

        internal static AttentionParseResult Reject(string reason)
        {
            return new AttentionParseResult(false, null, reason);
        }
    }

    /// <summary>One considered file whose content did not parse or validate (REQ-SIG-002); consumed regardless.</summary>
    public sealed class AttentionRejectedFile
    {
        public AttentionRejectedFile(string fileName, string reason)
        {
            FileName = fileName;
            Reason = reason;
        }

        public string FileName { get; private set; }
        public string Reason { get; private set; }
    }

    /// <summary>One considered file older than the freshness cutoff (REQ-SIG-002): deleted without parsing.</summary>
    public sealed class AttentionStaleFile
    {
        public AttentionStaleFile(string fileName, long ageMs)
        {
            FileName = fileName;
            AgeMs = ageMs;
        }

        public string FileName { get; private set; }
        public long AgeMs { get; private set; }
    }

    /// <summary>One considered file whose read failed (REQ-SIG-002): reported, never thrown.</summary>
    public sealed class AttentionIoErrorFile
    {
        public AttentionIoErrorFile(string fileName, string message)
        {
            FileName = fileName;
            Message = message;
        }

        public string FileName { get; private set; }
        public string Message { get; private set; }
    }

    /// <summary>
    /// One poll result of the signal store (REQ-SIG-002, plan.md section J store shape):
    /// the accepted signals, the rejected files with reasons, the stale deletions with
    /// ages, and the per-file IO errors. The controller owns the logging; the store
    /// never logs. Immutable.
    /// </summary>
    public sealed class AttentionPollResult
    {
        private readonly AttentionSignal[] accepted;
        private readonly AttentionRejectedFile[] rejected;
        private readonly AttentionStaleFile[] stale;
        private readonly AttentionIoErrorFile[] ioErrors;

        public AttentionPollResult(AttentionSignal[] accepted, AttentionRejectedFile[] rejected,
            AttentionStaleFile[] stale, AttentionIoErrorFile[] ioErrors)
        {
            this.accepted = accepted == null ? new AttentionSignal[0] : accepted;
            this.rejected = rejected == null ? new AttentionRejectedFile[0] : rejected;
            this.stale = stale == null ? new AttentionStaleFile[0] : stale;
            this.ioErrors = ioErrors == null ? new AttentionIoErrorFile[0] : ioErrors;
        }

        public AttentionSignal[] Accepted { get { return accepted; } }
        public AttentionRejectedFile[] Rejected { get { return rejected; } }
        public AttentionStaleFile[] Stale { get { return stale; } }
        public AttentionIoErrorFile[] IoErrors { get { return ioErrors; } }
    }

    /// <summary>
    /// One enumerated Windows Terminal window as the matcher sees it (REQ-MAT-002):
    /// the handle, the window title, and every tab title. Immutable; the tab array
    /// is copied on construction.
    /// </summary>
    public sealed class AttentionCandidate
    {
        public AttentionCandidate(IntPtr handle, string windowTitle, string[] tabTitles)
        {
            Handle = handle;
            WindowTitle = windowTitle == null ? string.Empty : windowTitle;
            this.tabTitles = tabTitles == null ? new string[0] : (string[])tabTitles.Clone();
        }

        public IntPtr Handle { get; private set; }
        public string WindowTitle { get; private set; }

        private readonly string[] tabTitles;

        public string[] TabTitles { get { return (string[])tabTitles.Clone(); } }
    }

    /// <summary>
    /// One candidate window's match verdict (SPEC-TRAY-019 REQ-STM-005, plan.md A-2): whether
    /// the window matched, the stripped session title that produced the match (null when
    /// unmatched), the first raw non-session title whose normalized form contains every needle
    /// token (recorded only when the window did not match — the would-have-rung evidence of a
    /// suppressed over-match; null when none), and every stripped session title in evaluation
    /// order (window title first, then tabs in input order) for the zero-match dump. Immutable;
    /// the title array is copied on construction.
    /// </summary>
    public sealed class AttentionMatchDetail
    {
        /// <summary>The rule name of a match by the forward rule (every needle token inside the session title).</summary>
        public const string RuleForward = "forward";

        /// <summary>The rule name of a match by the reverse rule (the session title inside the joined needle, t17).</summary>
        public const string RuleReverse = "reverse";

        /// <summary>The original form: a matched window is attributed to the forward rule.</summary>
        public AttentionMatchDetail(long handle, bool matched, string matchedSessionTitle,
            string suppressedTitle, string[] sessionTitles)
            : this(handle, matched, matchedSessionTitle, suppressedTitle, sessionTitles, matched ? RuleForward : null)
        {
        }

        /// <summary>Also names the rule that produced the match (RuleForward or RuleReverse); null for an unmatched window.</summary>
        public AttentionMatchDetail(long handle, bool matched, string matchedSessionTitle,
            string suppressedTitle, string[] sessionTitles, string matchRule)
        {
            Handle = handle;
            Matched = matched;
            MatchedSessionTitle = matchedSessionTitle;
            SuppressedTitle = suppressedTitle;
            MatchRule = matched ? matchRule : null;
            this.sessionTitles = sessionTitles == null ? new string[0] : (string[])sessionTitles.Clone();
        }

        public long Handle { get; private set; }
        public bool Matched { get; private set; }
        public string MatchedSessionTitle { get; private set; }
        public string SuppressedTitle { get; private set; }

        /// <summary>RuleForward or RuleReverse for a matched window; null when unmatched.</summary>
        public string MatchRule { get; private set; }

        private readonly string[] sessionTitles;

        public string[] SessionTitles { get { return (string[])sessionTitles.Clone(); } }
    }
}
