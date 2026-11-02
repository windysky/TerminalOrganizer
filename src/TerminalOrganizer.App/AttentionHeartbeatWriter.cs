using System;
using System.IO;
using TerminalOrganizer.Core.Attention;

namespace TerminalOrganizer.App
{
    /// <summary>
    /// The SPEC-TRAY-016 heartbeat file writer (REQ-HB-001, REQ-HB-002): best-effort,
    /// idempotent, never-deleting. It creates the signal directory when absent, then
    /// overwrites organizer.json with a fresh timestamp payload. A write failure is
    /// swallowed and reported as false — the controller logs one line per consecutive
    /// failure run and retries unconditionally on the next tick. The file is NEVER
    /// deleted on exit: staleness IS the organizer-dead signal the producer's fallback
    /// rides on, and cleanup would break it. The name never matches att-*.json (the
    /// store would consume it; the producer's prune glob must never see it).
    /// </summary>
    // @MX:NOTE: no-delete-on-exit + staleness-is-the-signal rationale (SPEC-TRAY-016 M1, AM-1).
    public static class AttentionHeartbeatWriter
    {
        /// <summary>The heartbeat file name inside the producer's signal directory (never att-*.json).</summary>
        public const string HeartbeatFileName = "organizer.json";

        /// <summary>The full heartbeat path inside the given signal directory.</summary>
        public static string HeartbeatPath(string signalDirectory)
        {
            return Path.Combine(signalDirectory == null ? string.Empty : signalDirectory, HeartbeatFileName);
        }

        /// <summary>
        /// Writes a fresh heartbeat payload to the path (creating the directory
        /// idempotently). True on success; false on any failure — never throws.
        /// </summary>
        public static bool Write(string path)
        {
            try
            {
                string directory = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                File.WriteAllText(path, AttentionHeartbeat.Payload(DateTimeOffset.Now));
                return true;
            }
            catch (Exception)
            {
                // Best-effort (REQ-HB-002): the failure is reported, never thrown.
                return false;
            }
        }
    }
}
