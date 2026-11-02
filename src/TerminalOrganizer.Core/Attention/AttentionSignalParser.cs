using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace TerminalOrganizer.Core.Attention
{
    /// <summary>
    /// Parses one signal payload (REQ-SIG-001): exactly one outcome — accepted carrying
    /// the recorded fields, or rejected with a non-empty reason (parse / shape / version /
    /// event / needle). Acceptance requires: the content parses as a JSON object, the
    /// version is exactly 1, the event is "stop" or "notification", and the needle holds
    /// at least one non-whitespace character. Unknown keys are ignored; the needle is
    /// kept verbatim; notification_type is recorded as null when absent or null (the
    /// producer emits it only when provided; it is logging-only and never affects
    /// matching). Pure by contract (NFR-2): reads no file, clock or process and never
    /// throws — the content arrives as a parameter, so the same text always yields the
    /// same outcome.
    /// </summary>
    public static class AttentionSignalParser
    {
        /// <summary>The pinned payload version (spec.md 1.3); anything else, absent included, is rejected.</summary>
        private const int PayloadVersion = 1;

        private const string EventStop = "stop";
        private const string EventNotification = "notification";

        /// <summary>Parses the payload; never throws (REQ-SIG-001).</summary>
        public static AttentionParseResult Parse(string content)
        {
            if (string.IsNullOrEmpty(content))
            {
                return AttentionParseResult.Reject("parse");
            }
            object root;
            try
            {
                root = new JavaScriptSerializer().DeserializeObject(content);
            }
            catch (Exception)
            {
                return AttentionParseResult.Reject("parse");
            }
            Dictionary<string, object> map = root as Dictionary<string, object>;
            if (map == null)
            {
                return AttentionParseResult.Reject("shape");
            }
            object versionValue;
            if (!map.TryGetValue("version", out versionValue)
                || !(versionValue is int)
                || (int)versionValue != PayloadVersion)
            {
                return AttentionParseResult.Reject("version");
            }
            object eventValue;
            if (!map.TryGetValue("event", out eventValue) || !(eventValue is string))
            {
                return AttentionParseResult.Reject("event");
            }
            string eventName = (string)eventValue;
            if (!string.Equals(eventName, EventStop, StringComparison.Ordinal)
                && !string.Equals(eventName, EventNotification, StringComparison.Ordinal))
            {
                return AttentionParseResult.Reject("event");
            }
            object needleValue;
            if (!map.TryGetValue("needle", out needleValue) || !(needleValue is string))
            {
                return AttentionParseResult.Reject("needle");
            }
            string needle = (string)needleValue;
            if (string.IsNullOrWhiteSpace(needle))
            {
                return AttentionParseResult.Reject("needle");
            }
            AttentionSignal signal = new AttentionSignal();
            signal.Version = PayloadVersion;
            signal.Event = eventName;
            signal.NotificationType = ReadOptionalString(map, "notification_type");
            signal.SessionId = ReadOptionalString(map, "session_id");
            signal.Cwd = ReadOptionalString(map, "cwd");
            signal.Needle = needle;
            signal.Timestamp = ReadOptionalString(map, "timestamp");
            // SPEC-TRAY-016 (REQ-FLD-001): the additive kind/message keys, recorded through
            // the same optional-string rule — no new rejection reasons, unknown keys stay
            // ignored, and every payload accepted today stays accepted (degrade-safe).
            signal.Kind = ReadOptionalString(map, "kind");
            signal.Message = ReadOptionalString(map, "message");
            return AttentionParseResult.Accept(signal);
        }

        /// <summary>The optional string field: null when the key is absent, null, or not a string.</summary>
        private static string ReadOptionalString(Dictionary<string, object> map, string key)
        {
            object value;
            if (!map.TryGetValue(key, out value))
            {
                return null;
            }
            return value as string;
        }
    }
}
