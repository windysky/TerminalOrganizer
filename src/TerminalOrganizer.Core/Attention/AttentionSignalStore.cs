using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;

namespace TerminalOrganizer.Core.Attention
{
    /// <summary>
    /// Consumes the WSL producer's signal directory (REQ-SIG-002): one poll considers
    /// exactly the files whose names match the att-EPOCHMS-REST.json pattern (epochms
    /// digits only), computes each file's age as the supplied instant minus the FILENAME
    /// epochms, and read+deletes every considered file whatever its outcome (consume).
    /// A file older than the 30 s cutoff is deleted without parsing and counted stale
    /// (age exactly 30 s is fresh). Non-matching names are ignored and never deleted.
    /// A missing directory yields an empty result; one file's IO error degrades to that
    /// file being reported — the store never throws and touches exactly the one
    /// directory and one injected clock supplied as parameters (NFR-2).
    /// </summary>
    public sealed class AttentionSignalStore
    {
        private static readonly Regex FileNamePattern = new Regex(
            AttentionConstants.SignalFilePattern, RegexOptions.CultureInvariant | RegexOptions.Compiled);

        private readonly string directoryPath;
        private readonly Func<long> clock;

        public AttentionSignalStore(string directoryPath, Func<long> clock)
        {
            if (clock == null)
            {
                throw new ArgumentNullException("clock");
            }
            this.directoryPath = directoryPath;
            this.clock = clock;
        }

        /// <summary>One poll; never throws (REQ-SIG-002).</summary>
        public AttentionPollResult Poll()
        {
            List<AttentionSignal> accepted = new List<AttentionSignal>();
            List<AttentionRejectedFile> rejected = new List<AttentionRejectedFile>();
            List<AttentionStaleFile> stale = new List<AttentionStaleFile>();
            List<AttentionIoErrorFile> ioErrors = new List<AttentionIoErrorFile>();
            try
            {
                if (string.IsNullOrEmpty(directoryPath) || !Directory.Exists(directoryPath))
                {
                    return BuildResult(accepted, rejected, stale, ioErrors);
                }
                string[] files = Directory.GetFiles(directoryPath);
                Array.Sort(files, StringComparer.Ordinal);
                long now = clock();
                foreach (string path in files)
                {
                    Consider(path, now, accepted, rejected, stale, ioErrors);
                }
            }
            catch (Exception)
            {
                // A listing failure degrades to what was collected so far; the store never throws.
            }
            return BuildResult(accepted, rejected, stale, ioErrors);
        }

        private static void Consider(string path, long now,
            List<AttentionSignal> accepted, List<AttentionRejectedFile> rejected,
            List<AttentionStaleFile> stale, List<AttentionIoErrorFile> ioErrors)
        {
            string name = Path.GetFileName(path);
            Match match = FileNamePattern.Match(name);
            if (!match.Success)
            {
                // Not considered (REQ-SIG-002): never parsed, never deleted.
                return;
            }
            long epochMs;
            if (!long.TryParse(match.Groups[1].Value, NumberStyles.Integer,
                CultureInfo.InvariantCulture, out epochMs))
            {
                return;
            }
            long age = now - epochMs;
            if (age > AttentionConstants.SignalMaxAgeMs)
            {
                TryDelete(path);
                stale.Add(new AttentionStaleFile(name, age));
                return;
            }
            try
            {
                string content = File.ReadAllText(path);
                AttentionParseResult parsed = AttentionSignalParser.Parse(content);
                if (parsed.Accepted)
                {
                    accepted.Add(parsed.Signal);
                }
                else
                {
                    rejected.Add(new AttentionRejectedFile(name, parsed.Reason));
                }
            }
            catch (Exception ex)
            {
                ioErrors.Add(new AttentionIoErrorFile(name, ex.Message));
            }
            finally
            {
                // Consume (REQ-SIG-002): every considered file is deleted whatever its outcome.
                TryDelete(path);
            }
        }

        private static AttentionPollResult BuildResult(List<AttentionSignal> accepted,
            List<AttentionRejectedFile> rejected, List<AttentionStaleFile> stale,
            List<AttentionIoErrorFile> ioErrors)
        {
            return new AttentionPollResult(accepted.ToArray(), rejected.ToArray(),
                stale.ToArray(), ioErrors.ToArray());
        }

        private static void TryDelete(string path)
        {
            try
            {
                File.Delete(path);
            }
            catch (Exception)
            {
                // A locked file stays for the next poll; deletion is best-effort.
            }
        }
    }
}
