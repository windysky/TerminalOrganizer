using System;

namespace TerminalOrganizer.Core.Update
{
    /// <summary>The classified relationship between HEAD and origin/main (SPEC-TRAY-020 D-3).</summary>
    public enum UpdateStatusKind
    {
        /// <summary>origin/main and HEAD point at the same commit.</summary>
        Synced,

        /// <summary>HEAD is behind origin/main by BehindCount commits (an update is available).</summary>
        Behind,

        /// <summary>HEAD is ahead of origin/main by AheadCount commits (not pushed).</summary>
        Ahead,

        /// <summary>Both sides moved: BehindCount behind, AheadCount ahead (manual judgement).</summary>
        Diverged,

        /// <summary>The rev-list output did not parse; every runner-level failure keeps this default.</summary>
        Unknown
    }

    /// <summary>
    /// The update status for one check (REQ-UPD-001): the parsed outcome of the standing
    /// probe "git rev-list --count --left-right origin/main...HEAD", where the left count
    /// is origin-only commits (behind) and the right count is HEAD-only commits (ahead).
    /// Pure by contract (REQ-UPD-002): the type performs no file, clock, or process reads,
    /// and it never throws — every malformed input classifies as Unknown. Immutable.
    /// </summary>
    // @MX:NOTE: pure classifier; the outcome set is pinned by SPEC-TRAY-020 AC-001 (D-3).
    public sealed class UpdateStatus
    {
        private readonly UpdateStatusKind kind;
        private readonly int behindCount;
        private readonly int aheadCount;

        private UpdateStatus(UpdateStatusKind kind, int behindCount, int aheadCount)
        {
            this.kind = kind;
            this.behindCount = behindCount;
            this.aheadCount = aheadCount;
        }

        /// <summary>The classified outcome; Unknown for every unparsable input.</summary>
        public UpdateStatusKind Kind
        {
            get { return kind; }
        }

        /// <summary>The origin-only commits (the behind count); 0 unless Behind or Diverged.</summary>
        public int BehindCount
        {
            get { return behindCount; }
        }

        /// <summary>The HEAD-only commits (the ahead count); 0 unless Ahead or Diverged.</summary>
        public int AheadCount
        {
            get { return aheadCount; }
        }

        /// <summary>
        /// Classifies the exact stdout of the standing probe (D-3): a string of exactly
        /// two whitespace-separated non-negative integers. "0 0" is Synced, "L 0" with
        /// L greater than 0 is Behind(L), "0 R" with R greater than 0 is Ahead(R), and
        /// both positive is Diverged(L, R). Anything else — null, empty, non-numeric,
        /// wrong arity, negative — is Unknown.
        /// </summary>
        public static UpdateStatus ParseRevList(string output)
        {
            if (output == null)
            {
                return UnknownStatus();
            }
            string trimmed = output.Trim();
            if (trimmed.Length == 0)
            {
                return UnknownStatus();
            }
            string[] parts = trimmed.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 2)
            {
                return UnknownStatus();
            }
            int behind;
            int ahead;
            if (!int.TryParse(parts[0], out behind) || !int.TryParse(parts[1], out ahead))
            {
                return UnknownStatus();
            }
            if (behind < 0 || ahead < 0)
            {
                return UnknownStatus();
            }
            if (behind == 0 && ahead == 0)
            {
                return new UpdateStatus(UpdateStatusKind.Synced, 0, 0);
            }
            if (behind > 0 && ahead == 0)
            {
                return new UpdateStatus(UpdateStatusKind.Behind, behind, 0);
            }
            if (behind == 0 && ahead > 0)
            {
                return new UpdateStatus(UpdateStatusKind.Ahead, 0, ahead);
            }
            return new UpdateStatus(UpdateStatusKind.Diverged, behind, ahead);
        }

        private static UpdateStatus UnknownStatus()
        {
            return new UpdateStatus(UpdateStatusKind.Unknown, 0, 0);
        }
    }
}
