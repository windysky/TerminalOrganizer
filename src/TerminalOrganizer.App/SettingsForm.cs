using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows.Forms;
using TerminalOrganizer.Core.Assignment;

namespace TerminalOrganizer.App
{
    /// <summary>
    /// SPEC-TRAY-015 M3 (REQ-WIN-001; AM-2, the ELECTED supersession of the
    /// TRAY-007 section 1.1/6 and TRAY-014 section 5 windowless commitments):
    /// ONE modeless settings form over the EXISTING settings surface only —
    /// attention enable / event policy / stop blinks / topmost, overflow policy,
    /// manager selection. Every write routes through the six existing static
    /// save helpers (REQ-PERSIST-001; the every-save-path-carries-all-four rule
    /// holds by construction) and applies to the live attention controller;
    /// no new settings key exists. Reads render through the SAME shared
    /// TrayMenuBuilder derivation the menu renders from (plan.md B7: the window
    /// grows no second settings state — it never constructs an AppSettings).
    /// Hand-written WinForms layout, functional minimum (plan.md section F M3);
    /// visual polish is an OPTIONAL manager-design follow-up, not a dependency.
    /// The manager candidate list inherits the accepted next-open refresh
    /// semantics (spec 2.2): it is the menu state's snapshot set, refreshed on
    /// form open. Never executed under Pester.
    /// </summary>
    // @MX:WARN: [AUTO] real WinForms settings surface — morning checklist; never executed under Pester (B5/NFR-5).
    internal sealed class SettingsForm : Form
    {
        /// <summary>The shipped event-policy tokens in the pinned order (the M2 radio rows' set).</summary>
        private static readonly string[] PolicyTokens = new string[]
        {
            AttentionPolicyResolver.PolicyMixed,
            AttentionPolicyResolver.PolicyAll,
            AttentionPolicyResolver.PolicyNotifications
        };

        /// <summary>The overflow row value ids in the shipped order (the C3 rows; merge disabled by the release gate).</summary>
        private static readonly string[] OverflowRowIds = new string[] { "ask", "stackOnly", "merge", "moveLowest" };

        private readonly TrayShell shell;
        private readonly SettingsStore settings;
        private readonly AttentionController attention;
        private readonly LogSink log;
        private readonly Func<AppSettings, TrayMenuState> menuStateFor;
        private readonly CheckBox attentionEnabled;
        private readonly CheckBox attentionTopmost;
        private readonly RadioButton[] policyRows;
        private readonly RadioButton[] blinkRows;
        private readonly RadioButton[] overflowRows;
        private readonly ComboBox managerChoice;
        private bool suppressEvents;

        /// <summary>
        /// The shared write surface is the six existing static save helpers in
        /// TrayShell; the manager selection's click-time validation rides back
        /// through the shell (SelectManagerFromSettingsForm) so the menu path and
        /// the form validate identically. This path never arms the menu
        /// stay-open flag (the menu is closed while the form is up).
        /// </summary>
        internal SettingsForm(TrayShell shell, SettingsStore settings, AttentionController attention,
            LogSink log, Func<AppSettings, TrayMenuState> menuStateFor)
        {
            this.shell = shell;
            this.settings = settings;
            this.attention = attention;
            this.log = log;
            this.menuStateFor = menuStateFor;

            Text = "TerminalOrganizer settings";
            Width = 460;
            Height = 442;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterScreen;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = true;

            // --- Attention overlay group (the existing attention settings surface) ---
            GroupBox attentionGroup = new GroupBox();
            attentionGroup.Text = "Attention overlay";
            attentionGroup.Left = 12;
            attentionGroup.Top = 12;
            attentionGroup.Width = 420;
            attentionGroup.Height = 160;

            this.attentionEnabled = new CheckBox();
            this.attentionEnabled.AutoSize = true;
            this.attentionEnabled.Left = 16;
            this.attentionEnabled.Top = 26;
            this.attentionEnabled.CheckedChanged += delegate { ApplyAttentionEnable(); };
            attentionGroup.Controls.Add(this.attentionEnabled);

            System.Windows.Forms.Label policyCaption = new System.Windows.Forms.Label();
            policyCaption.AutoSize = true;
            policyCaption.Left = 16;
            policyCaption.Top = 58;
            policyCaption.Text = "Event policy:";
            attentionGroup.Controls.Add(policyCaption);

            int[] policyLefts = new int[] { 120, 190, 260 };
            this.policyRows = new RadioButton[PolicyTokens.Length];
            for (int i = 0; i < PolicyTokens.Length; i++)
            {
                string token = PolicyTokens[i];
                RadioButton row = new RadioButton();
                row.AutoSize = true;
                row.Left = policyLefts[i];
                row.Top = 54;
                row.CheckedChanged += delegate
                {
                    if (row.Checked)
                    {
                        ApplyAttentionPolicy(token);
                    }
                };
                attentionGroup.Controls.Add(row);
                this.policyRows[i] = row;
            }

            System.Windows.Forms.Label blinkCaption = new System.Windows.Forms.Label();
            blinkCaption.AutoSize = true;
            blinkCaption.Left = 16;
            blinkCaption.Top = 88;
            blinkCaption.Text = "Stop blinks:";
            attentionGroup.Controls.Add(blinkCaption);

            int[] blinkLefts = new int[] { 120, 162, 204 };
            this.blinkRows = new RadioButton[AttentionBlinkLimits.Shipped.Length];
            for (int i = 0; i < AttentionBlinkLimits.Shipped.Length; i++)
            {
                int limit = AttentionBlinkLimits.Shipped[i];
                RadioButton row = new RadioButton();
                row.AutoSize = true;
                row.Left = blinkLefts[i];
                row.Top = 84;
                row.CheckedChanged += delegate
                {
                    if (row.Checked)
                    {
                        ApplyAttentionBlinkLimit(limit);
                    }
                };
                attentionGroup.Controls.Add(row);
                this.blinkRows[i] = row;
            }

            this.attentionTopmost = new CheckBox();
            this.attentionTopmost.AutoSize = true;
            this.attentionTopmost.Left = 16;
            this.attentionTopmost.Top = 118;
            this.attentionTopmost.CheckedChanged += delegate { ApplyAttentionTopmost(); };
            attentionGroup.Controls.Add(this.attentionTopmost);
            Controls.Add(attentionGroup);

            // --- Overflow behavior group (the four persisted policies) ---
            GroupBox overflowGroup = new GroupBox();
            overflowGroup.Text = "Overflow behavior";
            overflowGroup.Left = 12;
            overflowGroup.Top = 178;
            overflowGroup.Width = 420;
            overflowGroup.Height = 128;

            this.overflowRows = new RadioButton[OverflowRowIds.Length];
            for (int i = 0; i < OverflowRowIds.Length; i++)
            {
                string id = OverflowRowIds[i];
                RadioButton row = new RadioButton();
                row.AutoSize = true;
                row.Left = 16;
                row.Top = 26 + i * 24;
                row.CheckedChanged += delegate
                {
                    if (row.Checked)
                    {
                        ApplyOverflowPolicy(id);
                    }
                };
                overflowGroup.Controls.Add(row);
                this.overflowRows[i] = row;
            }
            Controls.Add(overflowGroup);

            // --- Manager group (selection through the same candidate rows) ---
            GroupBox managerGroup = new GroupBox();
            managerGroup.Text = "Manager";
            managerGroup.Left = 12;
            managerGroup.Top = 312;
            managerGroup.Width = 420;
            managerGroup.Height = 64;

            System.Windows.Forms.Label managerCaption = new System.Windows.Forms.Label();
            managerCaption.AutoSize = true;
            managerCaption.Left = 16;
            managerCaption.Top = 30;
            managerCaption.Text = "Manager window:";
            managerGroup.Controls.Add(managerCaption);

            this.managerChoice = new ComboBox();
            this.managerChoice.DropDownStyle = ComboBoxStyle.DropDownList;
            this.managerChoice.Left = 130;
            this.managerChoice.Top = 26;
            this.managerChoice.Width = 270;
            this.managerChoice.SelectedIndexChanged += delegate { ApplyManagerSelection(); };
            managerGroup.Controls.Add(this.managerChoice);
            Controls.Add(managerGroup);

            // Resync on every activation: the values shown re-read the store, so a
            // change made from the tray menu while this modeless form stayed open is
            // picked up the moment the user returns to the form.
            Activated += delegate { RefreshFromSettings(); };
            RefreshFromSettings();
        }

        /// <summary>
        /// Re-renders every row from a fresh store read through the SAME shared
        /// derivation the menu renders from (labels, checked markers, the merge
        /// release-gate disabled state) plus the manager candidate walk over the
        /// built menu model. All programmatic state changes run suppressed.
        /// </summary>
        private void RefreshFromSettings()
        {
            this.suppressEvents = true;
            try
            {
                AppSettings current = this.settings.Load();
                TrayMenuState state = this.menuStateFor(current);

                TrayMenuEntry enabledRow = TrayMenuBuilder.DeriveSettingsEntry(
                    TrayMenuEntryKind.AttentionEnabled, null, state);
                this.attentionEnabled.Text = enabledRow.Label;
                this.attentionEnabled.Checked = enabledRow.Checked;

                for (int i = 0; i < this.policyRows.Length; i++)
                {
                    TrayMenuEntry row = TrayMenuBuilder.DeriveSettingsEntry(
                        TrayMenuEntryKind.AttentionEventPolicy, PolicyTokens[i], state);
                    this.policyRows[i].Text = row.Label;
                    this.policyRows[i].Checked = row.Checked;
                }

                for (int i = 0; i < this.blinkRows.Length; i++)
                {
                    TrayMenuEntry row = TrayMenuBuilder.DeriveSettingsEntry(
                        TrayMenuEntryKind.AttentionStopBlinks,
                        AttentionBlinkLimits.Shipped[i].ToString(CultureInfo.InvariantCulture), state);
                    this.blinkRows[i].Text = row.Label;
                    this.blinkRows[i].Checked = row.Checked;
                }

                TrayMenuEntry topmostRow = TrayMenuBuilder.DeriveSettingsEntry(
                    TrayMenuEntryKind.AttentionTopmost, null, state);
                this.attentionTopmost.Text = topmostRow.Label;
                this.attentionTopmost.Checked = topmostRow.Checked;

                for (int i = 0; i < this.overflowRows.Length; i++)
                {
                    TrayMenuEntry row = TrayMenuBuilder.DeriveSettingsEntry(
                        TrayMenuEntryKind.OverflowPolicy, OverflowRowIds[i], state);
                    this.overflowRows[i].Text = row.Label;
                    this.overflowRows[i].Checked = row.Checked;
                    this.overflowRows[i].Enabled = row.Enabled;
                }

                PopulateManagerChoices(state);
            }
            finally
            {
                this.suppressEvents = false;
            }
        }

        /// <summary>
        /// The manager candidates are the built menu model's own SetManager rows
        /// (labels, checked markers and window keys included — no second candidate
        /// logic); "(none)" is the clear affordance, mirroring Clear manager.
        /// </summary>
        private void PopulateManagerChoices(TrayMenuState state)
        {
            this.managerChoice.Items.Clear();
            this.managerChoice.Items.Add("(none)");
            TrayMenuEntry checkedRow = null;
            foreach (TrayMenuEntry candidate in CollectManagerCandidates(state))
            {
                this.managerChoice.Items.Add(candidate);
                if (candidate.Checked)
                {
                    checkedRow = candidate;
                }
            }
            this.managerChoice.SelectedItem = checkedRow != null ? (object)checkedRow : (object)"(none)";
        }

        /// <summary>Collects the built model's SetManager rows (recursively — the
        /// candidate list may be bucketed at fifteen-plus candidates).</summary>
        private static List<TrayMenuEntry> CollectManagerCandidates(TrayMenuState state)
        {
            List<TrayMenuEntry> found = new List<TrayMenuEntry>();
            foreach (TrayMenuEntry root in TrayMenuBuilder.Build(state))
            {
                CollectManagerCandidates(root, found);
            }
            return found;
        }

        private static void CollectManagerCandidates(TrayMenuEntry entry, List<TrayMenuEntry> found)
        {
            if (entry == null)
            {
                return;
            }
            if (entry.Kind == TrayMenuEntryKind.SetManager)
            {
                found.Add(entry);
            }
            foreach (TrayMenuEntry child in entry.Children)
            {
                CollectManagerCandidates(child, found);
            }
        }

        /// <summary>The enable toggle — the existing static helper (a negating
        /// read-modify-write); the written value resyncs the checkbox, flips the
        /// controller and logs the menu's line.</summary>
        private void ApplyAttentionEnable()
        {
            if (this.suppressEvents)
            {
                return;
            }
            bool written = TrayShell.ToggleAttentionOverlayTo(this.settings);
            if (this.attention != null)
            {
                this.attention.SetEnabled(written);
            }
            this.log.Append(written ? "attention overlay enabled" : "attention overlay disabled");
            RefreshFromSettings();
        }

        private void ApplyAttentionPolicy(string token)
        {
            if (this.suppressEvents)
            {
                return;
            }
            TrayShell.SaveAttentionEventPolicyTo(this.settings, token);
            if (this.attention != null)
            {
                this.attention.SetEventPolicy(token);
            }
            this.log.Append("attention overlay event policy set to " + token);
            RefreshFromSettings();
        }

        private void ApplyAttentionBlinkLimit(int limit)
        {
            if (this.suppressEvents)
            {
                return;
            }
            TrayShell.SaveAttentionStopBlinksTo(this.settings, limit);
            if (this.attention != null)
            {
                this.attention.SetStopBlinkLimit(limit);
            }
            this.log.Append("attention overlay stop blinks set to "
                + limit.ToString(CultureInfo.InvariantCulture));
            RefreshFromSettings();
        }

        private void ApplyAttentionTopmost()
        {
            if (this.suppressEvents)
            {
                return;
            }
            bool value = this.attentionTopmost.Checked;
            TrayShell.SaveAttentionTopmostTo(this.settings, value);
            if (this.attention != null)
            {
                this.attention.SetTopmost(value);
            }
            this.log.Append(value ? "attention overlay always on top enabled"
                : "attention overlay always on top disabled");
            RefreshFromSettings();
        }

        private void ApplyOverflowPolicy(string id)
        {
            if (this.suppressEvents)
            {
                return;
            }
            OverflowPolicy policy = TrayShell.ParsePolicyValue(id);
            TrayShell.SaveOverflowPolicyTo(this.settings, policy);
            this.log.Append("overflow policy set to " + policy);
            RefreshFromSettings();
        }

        /// <summary>The manager selection — a candidate re-validates through the
        /// shell (the menu path's click-time identity re-resolve); "(none)" clears
        /// through the same static helper. Both log the menu's lines.</summary>
        private void ApplyManagerSelection()
        {
            if (this.suppressEvents)
            {
                return;
            }
            TrayMenuEntry selected = this.managerChoice.SelectedItem as TrayMenuEntry;
            if (selected != null)
            {
                this.shell.SelectManagerFromSettingsForm(selected.WindowKey);
            }
            else if (this.managerChoice.SelectedItem is string)
            {
                TrayShell.SaveManagerSelectorTo(this.settings, ManagerSelector.None());
                this.log.Append("manager window cleared");
            }
            RefreshFromSettings();
        }
    }
}
