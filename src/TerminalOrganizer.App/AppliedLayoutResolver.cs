using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using TerminalOrganizer.Core.Layouts;
using TerminalOrganizer.Core.Monitors;

namespace TerminalOrganizer.App
{
    /// <summary>
    /// Resolves the layout of a monitor on a desktop from the FancyZones directory (SPEC-MON-011 REQ-RES-001,
    /// REQ-RES-002): reads applied-layouts.json and custom-layouts.json, finds the live (number, serial) hint
    /// in the FancyZones log through the reader on EVERY call (no cache), selects the applied row through the
    /// hinted selector, and resolves the layout from the selected row's own key. It also appends one English
    /// line to the app log whenever the decision for a monitor and desktop changes.
    /// </summary>
    public sealed class AppliedLayoutResolver
    {
        private readonly string fancyZonesDir;
        private readonly Action<string> log;
        private readonly object gate = new object();
        private readonly Dictionary<string, string> lastDecisionKeys = new Dictionary<string, string>(StringComparer.Ordinal);

        /// <summary>The FancyZones directory (the parent of applied-layouts.json and Logs) and the app-log delegate (may be null).</summary>
        public AppliedLayoutResolver(string fancyZonesDir, Action<string> log)
        {
            if (fancyZonesDir == null)
            {
                throw new ArgumentNullException("fancyZonesDir");
            }
            this.fancyZonesDir = fancyZonesDir;
            this.log = log;
        }

        /// <summary>
        /// The layout for the monitor on the desktop. A missing applied-layouts file or no selected row is
        /// the unsupported no-applied-layout result; an invalid document is the invalid malformed-json result.
        /// </summary>
        // @MX:ANCHOR: [AUTO] Single layout-resolution entry point (callers: TrayContext composition, organize-once.ps1, tests).
        // @MX:REASON: under a matching hint the same row identity is chosen for every call within a press, independent of the
        // row order in applied-layouts.json, so the commit guard's layout signature stays stable across prepare, guard and capture.
        public LayoutResult Resolve(MonitorInfo monitor, string desktop)
        {
            string appliedPath = Path.Combine(fancyZonesDir, "applied-layouts.json");
            string customPath = Path.Combine(fancyZonesDir, "custom-layouts.json");
            if (!File.Exists(appliedPath))
            {
                return LayoutResult.Unsupported(LayoutReason.NoAppliedLayout, null, null, null);
            }
            string appliedJson = File.ReadAllText(appliedPath);
            string customJson = File.Exists(customPath) ? File.ReadAllText(customPath) : string.Empty;
            AppliedLayoutsDocument document = FancyZonesJsonReader.ParseAppliedLayouts(appliedJson);
            if (!document.IsValid)
            {
                return LayoutResult.Invalid(LayoutReason.MalformedJson, document.Detail, null);
            }
            LogReadResult read = FancyZonesLogReader.Read(Path.Combine(fancyZonesDir, "Logs"), monitor.MonitorId, monitor.Instance);
            SelectionDecision decision = AppliedEntrySelector.Decide(document, monitor.ToIdentity(), desktop, read.Hint);
            RecordDecision(monitor, desktop, read, decision);
            if (decision.Entry == null)
            {
                return LayoutResult.Unsupported(LayoutReason.NoAppliedLayout, null, null, null);
            }
            OrganizerDeviceContext context = OrganizerContext.Build(decision.Entry, monitor);
            return LayoutResolver.ResolveByDeviceKey(appliedJson, customJson, context.Key, context.WorkArea);
        }

        /// <summary>Appends the decision line when the change key for this monitor and desktop differs from the last one; never throws.</summary>
        // @MX:NOTE: [AUTO] The change key is (monitor stable key, desktop GUID by value, rule, chosen row number + serial or none);
        // the position, the layout uuid, the hint, the log file name and the reader result code are printed only, so a row reorder
        // or a changed reason code adds no line. A flip A to B to A logs each change.
        private void RecordDecision(MonitorInfo monitor, string desktop, LogReadResult read, SelectionDecision decision)
        {
            try
            {
                if (log == null)
                {
                    return;
                }
                AppliedLayoutEntry entry = decision.Entry;
                string monitorKey = monitor.StableKey.CanonicalValue ?? ("number:" + monitor.Number.ToString(CultureInfo.InvariantCulture));
                string desktopText = NormalizeDesktop(desktop);
                string rowKey = entry == null
                    ? "none"
                    : entry.Device.MonitorNumber.ToString(CultureInfo.InvariantCulture) + "|" + (entry.Device.SerialNumber ?? string.Empty);
                string changeKey = decision.Rule.ToString() + "|" + rowKey;
                string slot = monitorKey + "\n" + desktopText;
                lock (gate)
                {
                    string last;
                    if (lastDecisionKeys.TryGetValue(slot, out last) && string.Equals(last, changeKey, StringComparison.Ordinal))
                    {
                        return;
                    }
                    lastDecisionKeys[slot] = changeKey;
                }
                string hintText = read.Hint != null
                    ? "hint " + read.Hint.Number.ToString(CultureInfo.InvariantCulture) + ", " + read.Hint.Serial + ", " + read.Hint.SourceFileName
                    : "no hint: " + read.Code.ToString();
                string rowText = entry == null
                    ? "row none"
                    : "position " + entry.Position.ToString(CultureInfo.InvariantCulture)
                        + " number " + entry.Device.MonitorNumber.ToString(CultureInfo.InvariantCulture)
                        + " serial " + (entry.Device.SerialNumber ?? string.Empty)
                        + " layout " + entry.Uuid;
                log("applied row: monitor " + monitor.Number.ToString(CultureInfo.InvariantCulture)
                    + " desktop " + (desktopText.Length == 0 ? "<unknown>" : desktopText)
                    + " by " + decision.Rule.ToString() + " (" + hintText + ") " + rowText);
            }
            catch (Exception)
            {
                // The decision line is diagnostics only; it must never break a layout resolution.
            }
        }

        /// <summary>The desktop by GUID value as an upper-case braced GUID; other text unchanged; null as empty.</summary>
        private static string NormalizeDesktop(string desktop)
        {
            if (string.IsNullOrEmpty(desktop))
            {
                return string.Empty;
            }
            Guid parsed;
            return Guid.TryParse(desktop, out parsed) ? parsed.ToString("B").ToUpperInvariant() : desktop;
        }
    }
}
