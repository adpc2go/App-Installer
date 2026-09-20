using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace PC2Go.Deploy.Services
{
    /// <summary>
    /// One of the three things the latency probe measures, as the Gaming sub-tab draws it: a card
    /// that exists before anything has run (grey, "not measured yet"), narrates while the probe
    /// runs ("round 2 of 3"), and then carries the number, what it means in one line, a verdict in
    /// a colour, and what to do about it when it is amber or red - the Diagnose cards, for a probe.
    /// Properties, not fields: the template binds to them.
    /// </summary>
    public sealed class GameCard : INotifyPropertyChanged
    {
        public string Key { get; set; }
        public string Name { get; set; }
        public string About { get; set; }
        private string _state = "pending", _progress = "Not measured yet", _value = "", _after = "", _meaning = "", _verdict = "", _level = "info", _advice = "";
        // pending | reading | measured (read, number pending) | filled
        public string State { get { return _state; } set { _state = value; RaiseAll(); } }
        public string Progress { get { return _progress; } set { _progress = value ?? ""; Raise("Progress"); } }
        public string Value { get { return _value; } set { _value = value ?? ""; Raise("Value"); } }
        public string After { get { return _after; } set { _after = value ?? ""; Raise("After"); Raise("AfterVis"); } }
        public string Meaning { get { return _meaning; } set { _meaning = value ?? ""; Raise("Meaning"); } }
        public string Verdict { get { return _verdict; } set { _verdict = value ?? ""; Raise("Verdict"); } }
        // ok | warn | bad | info
        public string Level { get { return _level; } set { _level = value ?? "info"; Raise("Level"); Raise("Bar"); } }
        public string Advice { get { return _advice; } set { _advice = value ?? ""; Raise("Advice"); Raise("AdviceVis"); } }
        public string Bar
        {
            get
            {
                if (_state == "pending") return "#FF3C3C45";
                if (_state == "reading" || _state == "measured") return "#FF4C8DFF";
                switch (_level) { case "ok": return "#FF34D399"; case "warn": return "#FFF59E0B"; case "bad": return "#FFF87171"; default: return "#FF94A3B8"; }
            }
        }
        public string ProgressVis { get { return _state == "filled" ? "Collapsed" : "Visible"; } }
        public string ValueVis { get { return _state == "filled" ? "Visible" : "Collapsed"; } }
        public string AfterVis { get { return _state == "filled" && _after.Length > 0 ? "Visible" : "Collapsed"; } }
        public string AdviceVis { get { return _state == "filled" && _advice.Length > 0 ? "Visible" : "Collapsed"; } }
        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
        private void RaiseAll() { foreach (var n in new[] { "State", "Bar", "ProgressVis", "ValueVis", "AfterVis", "AdviceVis" }) Raise(n); }
    }

    /// <summary>
    /// The probe, explained. The thresholds are the ones a player feels: the worst 1% of moments
    /// under 0.2 ms is smooth, up to 1 ms is felt in competitive play, over that is visible
    /// stutter; driver load under 1% is quiet, a few percent is one busy driver, over 5% is a
    /// misbehaving one. The timer is context, never a fault - a game raises it on its own.
    /// </summary>
    public static class GameCards
    {
        public static List<GameCard> Skeleton()
        {
            return new List<GameCard>
            {
                new GameCard { Key = "stutter", Name = "Micro-stutter", About = "How late a thread finishes when the CPU is taken away from it - the worst 1% of moments is what a player feels as a hitch." },
                new GameCard { Key = "timer",   Name = "Timer granularity", About = "How coarse Windows' sleep timer is right now. Context, not a fault: a game raises it on its own." },
                new GameCard { Key = "load",    Name = "Background load", About = "CPU time spent servicing drivers and interrupts - where stutter usually comes from." },
            };
        }

        /// <summary>Everything back to grey and "not measured yet"; the first card turns "reading" the moment the probe starts.</summary>
        public static void Begin(IList<GameCard> cards)
        {
            foreach (var c in cards) { c.After = ""; c.Progress = "Not measured yet"; c.State = "pending"; }
            var t = cards.FirstOrDefault(c => c.Key == "timer");
            if (t != null) { t.Progress = "reading..."; t.State = "reading"; }
        }

        /// <summary>
        /// The probe's own narration ("measuring... preemption jitter round 2/3"), turned into the
        /// cards: the phase being read says so, the phases before it say "measured", the ones after
        /// stay grey. The probe reads the timer first, then the jitter, then the load.
        /// </summary>
        public static bool ApplyProgress(IList<GameCard> cards, string text)
        {
            var t = (text ?? "").Trim();
            if (t.Length == 0) return false;
            GameCard timer = cards.FirstOrDefault(c => c.Key == "timer"), stutter = cards.FirstOrDefault(c => c.Key == "stutter"), load = cards.FirstOrDefault(c => c.Key == "load");
            if (timer == null || stutter == null || load == null) return false;
            Action<GameCard> measured = c => { if (c.State != "filled") { c.Progress = "measured - the number comes with the summary"; c.State = "measured"; } };
            Action<GameCard, string> reading = (c, p) => { c.Progress = p; c.State = "reading"; };
            var round = Regex.Match(t, @"round (\d+)/(\d+)");
            var dpc = Regex.Match(t, @"DPC load (\d+)/(\d+)");
            if (dpc.Success) { measured(timer); measured(stutter); reading(load, "sampling " + dpc.Groups[1].Value + " of " + dpc.Groups[2].Value + "..."); return true; }
            if (round.Success) { measured(timer); reading(stutter, "round " + round.Groups[1].Value + " of " + round.Groups[2].Value + "..."); return true; }
            if (t.IndexOf("warming up", StringComparison.OrdinalIgnoreCase) >= 0) { measured(timer); reading(stutter, "warming up..."); return true; }
            if (t.IndexOf("timer", StringComparison.OrdinalIgnoreCase) >= 0) { reading(timer, "reading..."); return true; }
            return false;
        }

        /// <summary>One measurement's verdict: level, value text, verdict sentence, meaning, advice. Pure, so the suite can pin the thresholds.</summary>
        public static GameCard Evaluate(string key, Optimize.GameProbe p)
        {
            var c = Skeleton().First(x => x.Key == key);
            switch (key)
            {
                case "stutter":
                    c.Value = p.PreP99.ToString("N3") + " ms";
                    c.Meaning = "The worst 1% of moments were " + p.PreP99.ToString("N3") + " ms late; the single worst was " + p.PreMax.ToString("N3") + " ms.";
                    if (p.PreP99 < 0.2) { c.Level = "ok"; c.Verdict = "Smooth"; }
                    else if (p.PreP99 < 1.0) { c.Level = "warn"; c.Verdict = "Felt in competitive play"; }
                    else { c.Level = "bad"; c.Verdict = "Visible stutter"; }
                    c.Advice = c.Level == "ok" ? "" : "Close what runs in the background, then look at the CAUTION rows: GPU and NIC Interrupts (MSI + high priority) and Hardware-Accelerated GPU Scheduling are the two that move this number.";
                    break;
                case "timer":
                    c.Value = p.TimerP50.ToString("N1") + " ms";
                    c.Level = "info";
                    if (p.TimerP50 <= 2.0) { c.Verdict = "High resolution"; c.Meaning = "Something has asked Windows for a precise timer - a game, a browser, or this tool a moment ago."; }
                    else { c.Verdict = "Idle default"; c.Meaning = "Nothing is asking for precision right now. A game raises this to 1 ms by itself; it is not a setting to change."; }
                    break;
                default:
                    if (p.Dpc < 0) { c.Value = "not read"; c.Level = "info"; c.Verdict = "Counters unavailable"; c.Meaning = "The performance counters did not answer on this machine."; break; }
                    var sum = p.Dpc + Math.Max(0, p.Isr);
                    c.Value = sum.ToString("N1") + "%";
                    c.Meaning = "DPC " + p.Dpc.ToString("N1") + "%, interrupts " + Math.Max(0, p.Isr).ToString("N1") + "% of CPU time went to drivers.";
                    if (sum < 1.0) { c.Level = "ok"; c.Verdict = "Quiet"; }
                    else if (sum < 5.0) { c.Level = "warn"; c.Verdict = "One driver is busy"; }
                    else { c.Level = "bad"; c.Verdict = "A driver is misbehaving"; }
                    c.Advice = c.Level == "ok" ? "" : "This is a driver - usually network, audio or storage - and no setting fixes it. Update the driver, or unplug what is not needed, and measure again.";
                    break;
            }
            return c;
        }

        /// <summary>The cards painted from a finished probe. As a baseline or a fresh Measure the numbers stand alone; as the "after" of Apply Gaming the before stays and the after joins it, and the colour is the after's.</summary>
        public static void Fill(IList<GameCard> cards, Optimize.GameProbe p, bool asAfter)
        {
            foreach (var c in cards)
            {
                var e = Evaluate(c.Key, p);
                if (asAfter && c.State == "filled" && c.Value.Length > 0) c.After = "-> " + e.Value;   // ASCII: the suite reads its own file as ANSI
                else { c.Value = e.Value; c.After = ""; }
                c.Meaning = e.Meaning; c.Verdict = e.Verdict; c.Level = e.Level; c.Advice = e.Advice;
                c.Progress = "";
                c.State = "filled";
            }
        }

        /// <summary>The report file's text: the header the slow-PC report uses, three lines a person can read, and the before/after when there is one.</summary>
        public static string ReportText(string machine, DateTime when, Optimize.GameProbe before, Optimize.GameProbe after, KeyValuePair<string, string>? cmp)
        {
            var sb = new StringBuilder();
            sb.AppendLine("PC2Go gaming probe   " + when.ToString("yyyy-MM-dd HH:mm") + "   " + machine);
            sb.AppendLine();
            Action<string, Optimize.GameProbe> block = (label, p) =>
            {
                sb.AppendLine("== " + label + " ==");
                foreach (var k in new[] { "stutter", "timer", "load" })
                {
                    var e = Evaluate(k, p);
                    sb.AppendLine("   " + (e.Name + "          ").Substring(0, 18) + " " + e.Value.PadRight(10) + " " + e.Verdict + " - " + e.Meaning);
                }
                sb.AppendLine("   raw   " + Optimize.FormatProbe(p));
            };
            block(after == null ? "measured" : "before", before);
            if (after != null)
            {
                block("after", after);
                if (cmp.HasValue) { sb.AppendLine(); sb.AppendLine("VERDICT " + cmp.Value.Value); sb.AppendLine("   " + cmp.Value.Key); }
            }
            sb.AppendLine();
            sb.AppendLine("This measures how Windows schedules, not frames per second. Rows that need a reboot show their effect only after it.");
            return sb.ToString();
        }
    }
}
