using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using TerminalOrganizer.Core.Update;

namespace TerminalOrganizer.App
{
    /// <summary>
    /// One resolved update-check outcome (REQ-UPD-003): the classified status plus the
    /// three runner-level failures. Immutable.
    /// </summary>
    public enum UpdateCheckOutcomeKind
    {
        /// <summary>origin/main and HEAD agree; nothing to do.</summary>
        Synced,

        /// <summary>HEAD is behind origin/main by BehindCount commits; an update is available.</summary>
        Behind,

        /// <summary>HEAD is ahead of origin/main by AheadCount commits (not pushed).</summary>
        Ahead,

        /// <summary>Both sides moved (BehindCount / AheadCount); manual judgement needed.</summary>
        Diverged,

        /// <summary>The rev-list output did not classify (including a failed rev-list).</summary>
        Unknown,

        /// <summary>git.exe could not be started at all (A1: surfaced, never a crash).</summary>
        GitMissing,

        /// <summary>git fetch exited non-zero; Detail carries its first error line.</summary>
        FetchFailed,

        /// <summary>A bounded wait on a git subprocess expired.</summary>
        Timeout
    }

    /// <summary>The resolved outcome of one check; immutable.</summary>
    public sealed class UpdateCheckOutcome
    {
        private readonly UpdateCheckOutcomeKind kind;
        private readonly int behindCount;
        private readonly int aheadCount;
        private readonly string detail;

        public UpdateCheckOutcome(UpdateCheckOutcomeKind kind, int behindCount, int aheadCount, string detail)
        {
            this.kind = kind;
            this.behindCount = behindCount;
            this.aheadCount = aheadCount;
            this.detail = detail;
        }

        public UpdateCheckOutcomeKind Kind
        {
            get { return kind; }
        }

        public int BehindCount
        {
            get { return behindCount; }
        }

        public int AheadCount
        {
            get { return aheadCount; }
        }

        /// <summary>The fetch failure's first stderr line (FetchFailed only); null otherwise.</summary>
        public string Detail
        {
            get { return detail; }
        }
    }

    /// <summary>
    /// The result of ONE git subprocess invocation through the runner seam: whether the
    /// process started at all, whether the bounded wait expired, the exit code, the
    /// stdout (the rev-list probe reads it), and stderr's first line.
    /// </summary>
    public sealed class UpdateGitResult
    {
        public readonly bool Started;
        public readonly bool TimedOut;
        public readonly int ExitCode;
        public readonly string StdOut;
        public readonly string FirstErrorLine;

        private UpdateGitResult(bool started, bool timedOut, int exitCode, string stdOut, string firstErrorLine)
        {
            this.Started = started;
            this.TimedOut = timedOut;
            this.ExitCode = exitCode;
            this.StdOut = stdOut;
            this.FirstErrorLine = firstErrorLine;
        }

        public static UpdateGitResult Ok(int exitCode, string stdOut, string firstErrorLine)
        {
            return new UpdateGitResult(true, false, exitCode, stdOut ?? string.Empty, firstErrorLine ?? string.Empty);
        }

        /// <summary>The process never started (git unresolvable — the GitMissing outcome).</summary>
        public static UpdateGitResult NotStarted()
        {
            return new UpdateGitResult(false, false, 0, string.Empty, string.Empty);
        }

        public static UpdateGitResult TimedOutResult()
        {
            return new UpdateGitResult(true, true, 0, string.Empty, string.Empty);
        }
    }

    /// <summary>The injectable git runner seam: runs one hidden git subprocess with a bounded wait.</summary>
    public delegate UpdateGitResult UpdateGitDelegate(string arguments, int timeoutMs);

    /// <summary>
    /// The update checker (SPEC-TRAY-020 REQ-UPD-003..005): runs the standing probe —
    /// fetch origin main, then rev-list --count --left-right origin/main...HEAD — through
    /// an injectable runner seam, classifies the output through the Core parser, appends
    /// exactly one log line in the section-J shape on EVERY path, and guards against a
    /// second concurrent chain (ignored with its own line). The git vocabulary of this
    /// class is exactly fetch and rev-list (REQ-UPD-008): read-only, never a mutation.
    /// </summary>
    public sealed class UpdateChecker
    {
        /// <summary>The pinned remote (bin-sync policy, section J).</summary>
        public const string RemoteName = "origin";

        /// <summary>The pinned branch (bin-sync policy, section J).</summary>
        public const string BranchName = "main";

        /// <summary>The bounded wait for each git subprocess (section J).</summary>
        public const int FetchTimeoutMs = 20000;

        /// <summary>The wait after killing a timed-out owned process (the UiaProbeClient PostKillWait idea).</summary>
        private const int PostKillWaitMilliseconds = 200;

        /// <summary>The bound on draining stdout / stderr after a normal exit (a grandchild may hold the pipe open).</summary>
        private const int PostExitReadWaitMilliseconds = 1000;

        /// <summary>The one-shot startup check delay, after the shell is whole (D-6, section J).</summary>
        public const int StartupCheckDelayMs = 8000;

        /// <summary>The helper spawn vehicle: the %SystemRoot%-rooted absolute powershell.exe (D-1, section J).</summary>
        public const string HelperPowerShellExe = "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";

        /// <summary>The helper's app-exit wait bound in seconds (D-5, section J).</summary>
        public const int HelperPidWaitSeconds = 60;

        /// <summary>The helper's exe-lock wait bound in seconds (D-5, section J).</summary>
        public const int HelperLockWaitSeconds = 30;

        /// <summary>The helper's lock poll interval in milliseconds (D-5, section J).</summary>
        public const int HelperLockPollMs = 250;

        private readonly LogSink log;
        private readonly string repoRoot;
        private readonly UpdateGitDelegate runGit;
        private readonly int timeoutMs;
        private int checkRunning;

        public UpdateChecker(LogSink log, string repoRoot, UpdateGitDelegate runGit, int timeoutMs)
        {
            this.log = log;
            this.repoRoot = repoRoot;
            this.runGit = runGit;
            this.timeoutMs = timeoutMs;
        }

        /// <summary>The production checker: the hidden-subprocess runner with the section-J bound.</summary>
        public static UpdateChecker CreateProduction(LogSink log, string repoRoot)
        {
            return new UpdateChecker(log, repoRoot, RunGitProcess, FetchTimeoutMs);
        }

        /// <summary>
        /// The repo root derivation (A3): the normalized parent of the base directory
        /// (the app runs from <repo>\bin or an equivalent layout), but only when that
        /// parent actually carries .git (a directory in a plain clone, or the worktree
        /// file in a linked worktree); otherwise null — not a repo checkout.
        /// </summary>
        public static string DeriveRepoRoot()
        {
            string parent = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));
            if (Directory.Exists(Path.Combine(parent, ".git")) || File.Exists(Path.Combine(parent, ".git")))
            {
                return parent;
            }
            return null;
        }

        /// <summary>
        /// Runs the standing probe and resolves exactly one outcome, appending exactly
        /// one log line (section J) on every path. A request arriving while one chain is
        /// in flight is ignored with its own line and starts no second chain
        /// (REQ-UPD-003) — the ignored call returns null.
        /// </summary>
        public UpdateCheckOutcome Check()
        {
            if (InterlockedCompareExchange() != 0)
            {
                this.log.Append("update: check ignored reason=in-flight");
                return null;
            }
            try
            {
                if (string.IsNullOrEmpty(this.repoRoot))
                {
                    this.log.Append("update: check failed reason=fetch-failed detail=\"not a repo checkout\"");
                    return new UpdateCheckOutcome(UpdateCheckOutcomeKind.FetchFailed, 0, 0, "not a repo checkout");
                }
                UpdateGitResult fetch;
                try
                {
                    fetch = this.runGit(FetchArguments(), this.timeoutMs);
                }
                catch (Exception)
                {
                    // The runner itself failed to start the process (git unresolvable):
                    // the surfaced GitMissing outcome, never a thrown exception (AC-002).
                    return Failed(UpdateCheckOutcomeKind.GitMissing, "git-missing", null);
                }
                if (!fetch.Started)
                {
                    return Failed(UpdateCheckOutcomeKind.GitMissing, "git-missing", null);
                }
                if (fetch.TimedOut)
                {
                    return Failed(UpdateCheckOutcomeKind.Timeout, "timeout", null);
                }
                if (fetch.ExitCode != 0)
                {
                    return Failed(UpdateCheckOutcomeKind.FetchFailed, "fetch-failed",
                        string.IsNullOrEmpty(fetch.FirstErrorLine) ? null : fetch.FirstErrorLine);
                }
                UpdateGitResult revList;
                try
                {
                    revList = this.runGit(RevListArguments(), this.timeoutMs);
                }
                catch (Exception)
                {
                    return Failed(UpdateCheckOutcomeKind.GitMissing, "git-missing", null);
                }
                if (!revList.Started)
                {
                    return Failed(UpdateCheckOutcomeKind.GitMissing, "git-missing", null);
                }
                if (revList.TimedOut)
                {
                    return Failed(UpdateCheckOutcomeKind.Timeout, "timeout", null);
                }
                UpdateStatus status = UpdateStatus.ParseRevList(revList.StdOut);
                switch (status.Kind)
                {
                    case UpdateStatusKind.Synced:
                        this.log.Append("update: check outcome=synced");
                        return new UpdateCheckOutcome(UpdateCheckOutcomeKind.Synced, 0, 0, null);
                    case UpdateStatusKind.Behind:
                        this.log.Append("update: check outcome=behind behind=" + status.BehindCount + " ahead=0");
                        return new UpdateCheckOutcome(UpdateCheckOutcomeKind.Behind, status.BehindCount, 0, null);
                    case UpdateStatusKind.Ahead:
                        this.log.Append("update: check outcome=ahead behind=0 ahead=" + status.AheadCount);
                        return new UpdateCheckOutcome(UpdateCheckOutcomeKind.Ahead, 0, status.AheadCount, null);
                    case UpdateStatusKind.Diverged:
                        this.log.Append("update: check outcome=diverged behind=" + status.BehindCount
                            + " ahead=" + status.AheadCount);
                        return new UpdateCheckOutcome(UpdateCheckOutcomeKind.Diverged,
                            status.BehindCount, status.AheadCount, null);
                    default:
                        // Includes a failed rev-list (non-zero exit, unparseable output).
                        this.log.Append("update: check outcome=unknown");
                        return new UpdateCheckOutcome(UpdateCheckOutcomeKind.Unknown, 0, 0, null);
                }
            }
            finally
            {
                this.checkRunning = 0;
            }
        }

        /// <summary>
        /// The startup-check seam (REQ-UPD-005): one check whose ONLY notifying outcome
        /// is Behind — every other outcome leaves its one log line and no balloon. The
        /// delayed arming, the background thread and the marshal back to the UI thread
        /// live in the shell (D-6); this method never spawns anything and never exits.
        /// </summary>
        public UpdateCheckOutcome RunStartupCheck(Action<UpdateCheckOutcome> notifyBehind)
        {
            UpdateCheckOutcome outcome = Check();
            if (outcome != null && outcome.Kind == UpdateCheckOutcomeKind.Behind && notifyBehind != null)
            {
                notifyBehind(outcome);
            }
            return outcome;
        }

        private int InterlockedCompareExchange()
        {
            return System.Threading.Interlocked.CompareExchange(ref this.checkRunning, 1, 0);
        }

        private UpdateCheckOutcome Failed(UpdateCheckOutcomeKind kind, string reason, string detail)
        {
            if (detail == null)
            {
                this.log.Append("update: check failed reason=" + reason);
            }
            else
            {
                this.log.Append("update: check failed reason=" + reason + " detail=\"" + detail + "\"");
            }
            return new UpdateCheckOutcome(kind, 0, 0, detail);
        }

        private string FetchArguments()
        {
            return "-C \"" + this.repoRoot + "\" fetch " + RemoteName + " " + BranchName;
        }

        private string RevListArguments()
        {
            return "-C \"" + this.repoRoot + "\" rev-list --count --left-right " + RemoteName + "/" + BranchName + "...HEAD";
        }

        /// <summary>
        /// The production runner: one hidden git subprocess with a bounded wait. A start
        /// failure (git unresolvable) maps to NotStarted — the surfaced GitMissing
        /// outcome, never a crash. Never called on the UI thread (REQ-UPD-006).
        /// </summary>
        private static UpdateGitResult RunGitProcess(string arguments, int timeoutMs)
        {
            return RunBoundedProcess("git.exe", arguments, timeoutMs);
        }

        /// <summary>
        /// Runs one hidden child process under a hard bound: the stdout / stderr reads
        /// start asynchronously BEFORE the wait, so a child that never exits (or never
        /// closes its pipes) cannot block the wait itself. On expiry the OWNED process is
        /// killed (a grandchild such as git-remote-https is not tracked and may outlive
        /// it) and TimedOutResult comes back. After a normal exit the reads get one short
        /// bounded wait: a grandchild that still holds the pipe open yields empty text
        /// rather than a hang. A start failure maps to NotStarted. Public only as the
        /// test seam of the production runner.
        /// </summary>
        // @MX:WARN: [AUTO] real subprocess surface (git fetch / rev-list, read-only vocabulary); bounded wait; never on the UI thread.
        // @MX:REASON: an unbounded or mutating git call here blocks the app or changes machine state.
        public static UpdateGitResult RunBoundedProcess(string fileName, string arguments, int timeoutMs)
        {
            Process child = null;
            bool disposeChild = true;
            try
            {
                ProcessStartInfo start = new ProcessStartInfo(fileName, arguments);
                start.CreateNoWindow = true;
                start.UseShellExecute = false;
                start.RedirectStandardOutput = true;
                start.RedirectStandardError = true;
                child = Process.Start(start);
                if (child == null)
                {
                    return UpdateGitResult.NotStarted();
                }
                Task<string> stdoutRead = child.StandardOutput.ReadToEndAsync();
                Task<string> stderrRead = child.StandardError.ReadToEndAsync();
                if (!child.WaitForExit(timeoutMs))
                {
                    KillOwnedProcess(child);
                    disposeChild = stdoutRead.IsCompleted && stderrRead.IsCompleted;
                    return UpdateGitResult.TimedOutResult();
                }
                string stdout = ReadBounded(stdoutRead);
                string stderr = ReadBounded(stderrRead);
                disposeChild = stdoutRead.IsCompleted && stderrRead.IsCompleted;
                return UpdateGitResult.Ok(child.ExitCode, stdout, FirstLine(stderr));
            }
            catch (Exception)
            {
                // The start itself failed (git unresolvable on this PATH): surfaced, never thrown.
                return UpdateGitResult.NotStarted();
            }
            finally
            {
                // A read still pending on a pipe a grandchild holds open keeps the Process
                // undisposed (its finalizer reclaims it) rather than closing a live stream.
                if (child != null && disposeChild)
                {
                    try
                    {
                        child.Dispose();
                    }
                    catch (Exception)
                    {
                        // Disposal is best effort.
                    }
                }
            }
        }

        /// <summary>Kills only the OWNED process and waits briefly for its exit; never throws.</summary>
        private static void KillOwnedProcess(Process child)
        {
            try
            {
                child.Kill();
                child.WaitForExit(PostKillWaitMilliseconds);
            }
            catch (Exception)
            {
                // The process is dying (or already gone) either way; the result is TimedOut.
            }
        }

        /// <summary>The finished read's text, or empty when it did not finish within the bound or faulted.</summary>
        private static string ReadBounded(Task<string> read)
        {
            try
            {
                if (read.Wait(PostExitReadWaitMilliseconds))
                {
                    return read.Result ?? string.Empty;
                }
            }
            catch (Exception)
            {
                // A faulted read degrades to empty text.
            }
            return string.Empty;
        }

        private static string FirstLine(string text)
        {
            if (string.IsNullOrEmpty(text))
            {
                return string.Empty;
            }
            string[] lines = text.Split('\n');
            return lines.Length > 0 ? lines[0].Trim() : string.Empty;
        }
    }

    /// <summary>
    /// The update notice mapping (REQ-UPD-004, section J texts): a pure function of the
    /// outcome — Information for synced/behind/ahead, Warning for diverged, Error for
    /// git-missing/fetch-failed/timeout — plus the update-and-restart already-up-to-date
    /// text. The log line is Check()'s own (exactly one per path); these texts ride only
    /// the balloon surface.
    /// </summary>
    public static class UpdateNotices
    {
        /// <summary>The Synced/Ahead/Diverged update-and-restart not-spawned texts also come from here.</summary>
        public const string AlreadyUpToDateText = "Already up to date — nothing to update.";

        public static string TextFor(UpdateCheckOutcome outcome)
        {
            if (outcome == null)
            {
                return string.Empty;
            }
            switch (outcome.Kind)
            {
                case UpdateCheckOutcomeKind.Synced:
                    return "TerminalOrganizer is up to date (origin/main).";
                case UpdateCheckOutcomeKind.Behind:
                    return "Update available: " + outcome.BehindCount
                        + " commit(s) behind origin/main. Tray menu: Update and restart.";
                case UpdateCheckOutcomeKind.Ahead:
                    return "Local checkout is " + outcome.AheadCount
                        + " commit(s) ahead of origin/main (not pushed).";
                case UpdateCheckOutcomeKind.Diverged:
                    return "Checkout diverged from origin/main (" + outcome.BehindCount + " behind, "
                        + outcome.AheadCount + " ahead). Manual judgement needed — no update applied.";
                case UpdateCheckOutcomeKind.GitMissing:
                    return "Update check failed (git-missing). See the log for detail.";
                case UpdateCheckOutcomeKind.FetchFailed:
                    return "Update check failed (fetch-failed). See the log for detail.";
                default:
                    return "Update check failed (timeout). See the log for detail.";
            }
        }

        public static NoticeLevel LevelFor(UpdateCheckOutcome outcome)
        {
            if (outcome == null)
            {
                return NoticeLevel.Information;
            }
            switch (outcome.Kind)
            {
                case UpdateCheckOutcomeKind.Diverged:
                    return NoticeLevel.Warning;
                case UpdateCheckOutcomeKind.GitMissing:
                case UpdateCheckOutcomeKind.FetchFailed:
                case UpdateCheckOutcomeKind.Timeout:
                    return NoticeLevel.Error;
                default:
                    return NoticeLevel.Information;
            }
        }
    }

    /// <summary>
    /// The update-and-restart gate (REQ-UPD-007, controller-seam level): the pure
    /// decision the shell handler maps onto spawn/exit/notice. ONLY Behind spawns the
    /// helper and exits; Synced surfaces the already-up-to-date notice; every other
    /// outcome — Ahead, Diverged, Unknown, GitMissing, FetchFailed, Timeout — surfaces
    /// its reason; a null outcome (an ignored in-flight request) does nothing.
    /// </summary>
    public enum UpdateDecisionAction
    {
        /// <summary>The in-flight guard dropped the request; its line is already logged.</summary>
        IgnoreInFlight,

        /// <summary>Spawn the detached helper, then exit through the pinned sequence.</summary>
        SpawnHelperAndExit,

        /// <summary>Surface the already-up-to-date notice; no spawn, no exit.</summary>
        AlreadyUpToDate,

        /// <summary>Surface the outcome's reason notice; no spawn, no exit.</summary>
        SurfaceReason
    }

    public static class UpdateDecision
    {
        public static UpdateDecisionAction For(UpdateCheckOutcome outcome)
        {
            if (outcome == null)
            {
                return UpdateDecisionAction.IgnoreInFlight;
            }
            switch (outcome.Kind)
            {
                case UpdateCheckOutcomeKind.Behind:
                    return UpdateDecisionAction.SpawnHelperAndExit;
                case UpdateCheckOutcomeKind.Synced:
                    return UpdateDecisionAction.AlreadyUpToDate;
                default:
                    // Unknown included: an unclear state never spawns and never exits.
                    return UpdateDecisionAction.SurfaceReason;
            }
        }
    }
}
