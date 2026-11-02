using System;
using System.Globalization;

namespace TerminalOrganizer.Core.Attention
{
    /// <summary>
    /// The SPEC-TRAY-016 heartbeat payload builder (REQ-HB-001): one pure function
    /// turning a point in time into the producer-contract heartbeat line — exactly
    /// the key "timestamp" in the ISO-8601 round-trip offset ("o") shape, no other
    /// key, hand-built without a serializer (the value contains only digits and the
    /// + - : T . punctuation, so nothing needs escaping). The live producer gate
    /// reads only this key and tolerates tz-aware or naive stamps (research R2/R6);
    /// the payload is byte-deterministic for a given input (NFR-2 pattern).
    /// </summary>
    // @MX:NOTE: the producer-contract surface (timestamp key, round-trip offset format, no other key).
    public static class AttentionHeartbeat
    {
        /// <summary>The heartbeat payload: {"timestamp":"&lt;DateTimeOffset o-format&gt;"} — tz offset always present, 7 fractional digits.</summary>
        public static string Payload(DateTimeOffset now)
        {
            return "{\"timestamp\":\"" + now.ToString("o", CultureInfo.InvariantCulture) + "\"}";
        }
    }
}
