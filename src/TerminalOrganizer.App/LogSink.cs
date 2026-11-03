using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace TerminalOrganizer.App
{
    /// <summary>
    /// The append-only log wrapper (REQ-NOTI-002): one timestamped line per call to the
    /// configured path, written through (each Append is its own File.AppendAllText, so
    /// Flush is a no-op kept for the REQ-SHELL-003 exit sequence). A write failure drops
    /// the line silently — the sink never throws and never takes the organizer down.
    /// </summary>
    public sealed class LogSink
    {
        private readonly string path;

        public LogSink(string path)
        {
            this.path = path;
        }

        /// <summary>Appends one timestamped line; a write failure drops the line, never throws (REQ-NOTI-002).</summary>
        public void Append(string line)
        {
            try
            {
                if (string.IsNullOrEmpty(path))
                {
                    return;
                }
                string directory = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                File.AppendAllText(path,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)
                    + " " + Sanitize(line) + Environment.NewLine);
            }
            catch
            {
                // REQ-NOTI-002: the line is dropped silently; logging must never break an organize run.
            }
        }

        /// <summary>Write-through sink: nothing to flush. Present for the exit sequence (REQ-SHELL-003).</summary>
        public void Flush()
        {
        }

        // @MX:NOTE: [AUTO] REQ-LOG-001/002 (SPEC-TRAY-017): the D-2 sink-once line-structure mapping.
        // CR and LF each render as their two-character literal escapes \r and \n (greppable, reversible
        // by eye); every other C0 control character except TAB, plus DEL, renders as U+FFFD; all
        // remaining content passes through verbatim. Called only from Append so every log writer
        // (window titles, attention Kind/Needle diagnostics, everything) is covered with no
        // per-callsite escaping (REQ-LOG-003 / D-1).
        private static string Sanitize(string line)
        {
            if (line == null)
            {
                return string.Empty;
            }
            StringBuilder builder = new StringBuilder(line.Length);
            for (int i = 0; i < line.Length; i++)
            {
                char c = line[i];
                if (c == '\r')
                {
                    builder.Append("\\r");
                }
                else if (c == '\n')
                {
                    builder.Append("\\n");
                }
                else if ((c < ' ' && c != '\t') || c == '\u007F')
                {
                    // (char)0xFFFD keeps this source pure ASCII: a literal U+FFFD character
                    // would fail the build on a machine whose default codepage is not UTF-8
                    // (csc reads BOM-less sources with the system ANSI codepage).
                    builder.Append((char)0xFFFD);
                }
                else
                {
                    builder.Append(c);
                }
            }
            return builder.ToString();
        }
    }
}
