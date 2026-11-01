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

        /// <summary>The amber ring color #FFBF00 (plan.md section J); the App overlay unpacks it into R/G/B.</summary>
        public const int RingColorRgb = 0xFFBF00;
    }

    /// <summary>
    /// One parsed attention event (REQ-SIG-001): the recorded fields of one signal
    /// payload. The needle is stored verbatim; notification_type is null unless the
    /// producer provided one (logging only, never matching). Public fields so the
    /// Pester suite reads them directly (the SettingsDto pattern).
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
}
