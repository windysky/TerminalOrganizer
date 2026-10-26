using System;
using System.Globalization;

namespace TerminalOrganizer.Core.Monitors
{
    /// <summary>
    /// The live (monitor-number, serial-number) pair FancyZones logged for a monitor instance
    /// (SPEC-MON-011 REQ-LOG-001, REQ-HIN-001): the pair of the live applied-layouts row. The
    /// serial comes from the log, never from the EDID (FancyZones cross-wires serials). An empty
    /// serial is a value, not an absence; a null serial is stored as empty. The source file name
    /// is attached by the reader and is informational only.
    /// </summary>
    public sealed class LiveRowHint
    {
        private readonly int number;
        private readonly string serial;
        private readonly string sourceFileName;

        public LiveRowHint(int number, string serial)
            : this(number, serial, null)
        {
        }

        public LiveRowHint(int number, string serial, string sourceFileName)
        {
            this.number = number;
            this.serial = serial ?? string.Empty;
            this.sourceFileName = sourceFileName ?? string.Empty;
        }

        public int Number { get { return number; } }

        public string Serial { get { return serial; } }

        /// <summary>The log file the hint came from, or empty when none was attached.</summary>
        public string SourceFileName { get { return sourceFileName; } }
    }

    /// <summary>
    /// Pure FancyZones log parser (SPEC-MON-011 REQ-LOG-001, REQ-LOG-002). Reads no file, clock or
    /// environment value and never throws on any text: a line that cannot be parsed is ignored.
    /// </summary>
    public static class FancyZonesLogParser
    {
        private const string Marker = "Initialize layout on ";
        private const string Tail = ", work area rect";
        private const int BracedGuidLength = 38;

        /// <summary>
        /// Returns the hint of the newest (last in text order) line shaped
        /// "Initialize layout on &lt;id&gt;_&lt;instance&gt;_&lt;number&gt;_&lt;serial&gt;_&lt;{GUID}&gt;, work area rect ..."
        /// whose key begins with "&lt;id&gt;_&lt;instance&gt;_" ordinally, on any desktop, or null when no
        /// line qualifies. The desktop GUID need only be well-formed; it is not compared. The number is
        /// the digits before the next underscore; the serial is everything after it up to the final
        /// "_{GUID}" and may be empty or contain underscores. Accepts CRLF, LF and an unterminated last
        /// line. The returned hint carries no file name (the reader attaches it).
        /// </summary>
        // @MX:NOTE: [AUTO] Line shape observed on 1600 of 1600 lines over 7 days; prefix-anchored on the known id and
        // instance because splitting on '_' is ambiguous (Default_Monitor); the newest line on any desktop wins since
        // the pair is constant per FancyZones process.
        public static LiveRowHint FindNewestHint(string logText, string monitorId, string instance)
        {
            if (string.IsNullOrEmpty(logText) || string.IsNullOrEmpty(monitorId) || instance == null)
            {
                return null;
            }
            string prefix = monitorId + "_" + instance + "_";
            LiveRowHint newest = null;
            int lineStart = 0;
            while (lineStart < logText.Length)
            {
                int lineEnd = logText.IndexOf('\n', lineStart);
                if (lineEnd < 0)
                {
                    lineEnd = logText.Length;
                }
                LiveRowHint hint = ParseLine(logText, lineStart, lineEnd, prefix);
                if (hint != null)
                {
                    newest = hint;
                }
                lineStart = lineEnd + 1;
            }
            return newest;
        }

        /// <summary>Parses one line [lineStart, lineEnd) of the text, or returns null when it does not qualify.</summary>
        private static LiveRowHint ParseLine(string text, int lineStart, int lineEnd, string prefix)
        {
            int marker = text.IndexOf(Marker, lineStart, lineEnd - lineStart, StringComparison.Ordinal);
            if (marker < 0)
            {
                return null;
            }
            int keyStart = marker + Marker.Length;
            if (keyStart + prefix.Length > lineEnd
                || string.CompareOrdinal(text, keyStart, prefix, 0, prefix.Length) != 0)
            {
                return null;
            }
            int bodyStart = keyStart + prefix.Length;
            int tail = text.IndexOf(Tail, bodyStart, lineEnd - bodyStart, StringComparison.Ordinal);
            if (tail < 0)
            {
                return null;
            }
            // Body is "<number>_<serial>_{GUID}": at least "N_" plus "_" plus the braced GUID.
            int guidStart = tail - BracedGuidLength;
            if (guidStart - 1 < bodyStart + 2 || text[guidStart - 1] != '_')
            {
                return null;
            }
            Guid ignored;
            if (!Guid.TryParseExact(text.Substring(guidStart, BracedGuidLength), "B", out ignored))
            {
                return null;
            }
            int separator = text.IndexOf('_', bodyStart, guidStart - 1 - bodyStart);
            if (separator <= bodyStart)
            {
                return null;
            }
            int number;
            if (!int.TryParse(text.Substring(bodyStart, separator - bodyStart), NumberStyles.None, CultureInfo.InvariantCulture, out number))
            {
                return null;
            }
            return new LiveRowHint(number, text.Substring(separator + 1, guidStart - 1 - (separator + 1)));
        }
    }
}
