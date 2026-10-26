using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace TerminalOrganizer.Core.Monitors
{
    /// <summary>Why the log reader returned what it did (SPEC-MON-011 REQ-RDR-003); a closed set.</summary>
    public enum LogReadCode
    {
        /// <summary>A hint is returned.</summary>
        Found,

        /// <summary>The Logs folder is missing or cannot be listed.</summary>
        NoLogsFolder,

        /// <summary>The folder exists but holds no log_*.log file in a version folder.</summary>
        NoLogFiles,

        /// <summary>Candidate files exist but every consulted file failed to open or read (for example locked).</summary>
        Unreadable,

        /// <summary>At least one consulted file was read and none yielded a hint (includes a zero-byte or garbage-only file).</summary>
        NoMatchingLine
    }

    /// <summary>The hint (null unless Code is Found) and the one result code of a log read.</summary>
    public sealed class LogReadResult
    {
        private readonly LogReadCode code;
        private readonly LiveRowHint hint;

        public LogReadResult(LogReadCode code, LiveRowHint hint)
        {
            this.code = code;
            this.hint = hint;
        }

        public LogReadCode Code { get { return code; } }

        public LiveRowHint Hint { get { return hint; } }
    }

    /// <summary>
    /// Thin IO wrapper over FancyZonesLogParser (SPEC-MON-011 REQ-RDR-001..003). Orders the candidate
    /// files of the FancyZones Logs folder (Logs\&lt;version folder&gt;\log_YYYY-MM-DD.log) newest first by the
    /// date text in the file name (ordinal), then by numeric version folder; consults at most the 3 newest;
    /// reads at most the final 262144 bytes of each with the first, possibly partial, line dropped; stops at
    /// the first file that yields a hint. It never reads the system clock, never orders by a parsed date value or by
    /// file times (only by the name text), never throws, never retries and never delays.
    /// </summary>
    public static class FancyZonesLogReader
    {
        private const int MaxFiles = 3;
        private const int WindowBytes = 262144;

        private sealed class Candidate
        {
            public string Path;
            public string FileName;
            public string DateText;
            public string VersionFolder;
            public int[] Version;
        }

        /// <summary>Finds the newest hint for the monitor (id and instance) under the given Logs folder.</summary>
        public static LogReadResult Read(string logsFolder, string monitorId, string instance)
        {
            List<Candidate> candidates;
            LogReadResult listing = ListCandidates(logsFolder, out candidates);
            if (listing != null)
            {
                return listing;
            }
            candidates.Sort(NewestFirst);
            bool anyRead = false;
            int consulted = Math.Min(MaxFiles, candidates.Count);
            for (int i = 0; i < consulted; i++)
            {
                string text = ReadTail(candidates[i].Path);
                if (text == null)
                {
                    continue;
                }
                anyRead = true;
                LiveRowHint hint = FancyZonesLogParser.FindNewestHint(text, monitorId, instance);
                if (hint != null)
                {
                    return new LogReadResult(LogReadCode.Found,
                        new LiveRowHint(hint.Number, hint.Serial, candidates[i].FileName));
                }
            }
            return new LogReadResult(anyRead ? LogReadCode.NoMatchingLine : LogReadCode.Unreadable, null);
        }

        /// <summary>Lists the log files; returns a terminal result when the folder is missing, unlistable or empty, otherwise null.</summary>
        private static LogReadResult ListCandidates(string logsFolder, out List<Candidate> candidates)
        {
            candidates = new List<Candidate>();
            try
            {
                if (string.IsNullOrEmpty(logsFolder) || !Directory.Exists(logsFolder))
                {
                    return new LogReadResult(LogReadCode.NoLogsFolder, null);
                }
                foreach (string folder in Directory.GetDirectories(logsFolder))
                {
                    string versionFolder = Path.GetFileName(folder);
                    foreach (string file in Directory.GetFiles(folder, "log_*.log"))
                    {
                        // The wildcard also matches longer extensions that start with "log"; keep exact ".log" names only.
                        if (!file.EndsWith(".log", StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }
                        Candidate candidate = new Candidate();
                        candidate.Path = file;
                        candidate.FileName = Path.GetFileName(file);
                        candidate.DateText = DateTextOf(candidate.FileName);
                        candidate.VersionFolder = versionFolder;
                        candidate.Version = ParseVersion(versionFolder);
                        candidates.Add(candidate);
                    }
                }
            }
            catch (Exception)
            {
                candidates = new List<Candidate>();
                return new LogReadResult(LogReadCode.NoLogsFolder, null);
            }
            return candidates.Count == 0 ? new LogReadResult(LogReadCode.NoLogFiles, null) : null;
        }

        /// <summary>The text between "log_" and ".log" (ordinal-comparable for YYYY-MM-DD).</summary>
        private static string DateTextOf(string fileName)
        {
            return fileName.Substring(4, fileName.Length - 8);
        }

        /// <summary>Numeric version of a folder name such as v0.102.2862; a non-numeric segment counts as 0.</summary>
        private static int[] ParseVersion(string folderName)
        {
            string trimmed = folderName.TrimStart('v', 'V');
            string[] parts = trimmed.Split('.');
            int[] version = new int[parts.Length];
            for (int i = 0; i < parts.Length; i++)
            {
                int value;
                if (int.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out value))
                {
                    version[i] = value;
                }
            }
            return version;
        }

        /// <summary>Newest first: date text descending (ordinal), then numeric version descending, then folder name descending (ordinal, a total order).</summary>
        private static int NewestFirst(Candidate a, Candidate b)
        {
            int byDate = string.CompareOrdinal(b.DateText, a.DateText);
            if (byDate != 0)
            {
                return byDate;
            }
            int segments = Math.Max(a.Version.Length, b.Version.Length);
            for (int i = 0; i < segments; i++)
            {
                int left = i < a.Version.Length ? a.Version[i] : 0;
                int right = i < b.Version.Length ? b.Version[i] : 0;
                if (left != right)
                {
                    return right.CompareTo(left);
                }
            }
            return string.CompareOrdinal(b.VersionFolder, a.VersionFolder);
        }

        /// <summary>
        /// The final WindowBytes of the file as text, with the first, possibly partial, line dropped when the
        /// window does not start at byte 0; null when the file cannot be opened or read.
        /// </summary>
        // @MX:WARN: [AUTO] Reads a file a live writer (FancyZones) holds open; the file is not ours.
        // @MX:REASON: open with shared read, write and delete access, never lock or mutate it, and never throw.
        private static string ReadTail(string path)
        {
            try
            {
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                {
                    long length = stream.Length;
                    long start = Math.Max(0L, length - WindowBytes);
                    stream.Seek(start, SeekOrigin.Begin);
                    byte[] buffer = new byte[(int)(length - start)];
                    int filled = 0;
                    while (filled < buffer.Length)
                    {
                        int read = stream.Read(buffer, filled, buffer.Length - filled);
                        if (read <= 0)
                        {
                            break;
                        }
                        filled += read;
                    }
                    int offset = 0;
                    if (start > 0)
                    {
                        int newline = Array.IndexOf(buffer, (byte)'\n', 0, filled);
                        offset = newline < 0 ? filled : newline + 1;
                    }
                    return Encoding.UTF8.GetString(buffer, offset, filled - offset);
                }
            }
            catch (Exception)
            {
                return null;
            }
        }
    }
}
