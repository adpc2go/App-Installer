using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Text.RegularExpressions;

namespace PC2Go.Deploy.Services
{
    /// <summary>One row of the script's $script:DiagRemedies: what the tool does about one sentence the diagnosis can say.</summary>
    public sealed class Remedy
    {
        public string Layer = "", Match = "", Kind = "none", Target = "", Label = "", Note = "";
    }

    /// <summary>One finding on a red card, with its remedy: the sentence, what to do about it, and the button when the tool can do it.</summary>
    public sealed class DiagFinding
    {
        // properties, not fields - the card template binds to them, and WPF binds to properties only
        public string Text { get; set; }
        public string Note { get; set; }
        public string Label { get; set; }
        public string Kind { get; set; }
        public string Target { get; set; }
        public string[] Names { get; set; }
        /// <summary>Its number on the "What to do" card, 1-based; 0 when it is not a step there.</summary>
        public int Step { get; set; }
        public DiagFinding() { Text = ""; Note = ""; Label = ""; Kind = "none"; Target = ""; Names = new string[0]; }
        public bool HasButton { get { return Kind != "none" && Label.Length > 0; } }
        public string ButtonVis { get { return HasButton ? "Visible" : "Collapsed"; } }
    }

    /// <summary>
    /// What to do about the report as a whole: the findings the tool can act on as numbered steps
    /// in layer order (hardware first, then what runs in the background), the rest as things to
    /// know - and, when no finding carries a button, the approach worth taking on any slow PC.
    /// The per-finding buttons on the cards answered "what about THIS?"; the technician's actual
    /// question was "so what do I do?", and that needs one place.
    /// </summary>
    public sealed class DiagPlan
    {
        public bool Visible;
        public string Summary = "";
        public List<DiagFinding> Steps = new List<DiagFinding>();
        public List<DiagFinding> Notes = new List<DiagFinding>();
    }

    /// <summary>
    /// One of the Slow PC report's seven layers, as the Diagnose screen draws it - and it is drawn
    /// BEFORE anything has run: seven grey cards that say "not read yet", so the screen shows its
    /// shape from the first frame, then each card turns as the worker reports that layer.
    /// State: pending | reading | ok | finding. A finding card lists its findings, each with the
    /// remedy the table gives it.
    /// </summary>
    public sealed class DiagLayer : INotifyPropertyChanged
    {
        // properties, not fields: WPF binds to properties only, and a field binds to nothing at all
        public string Key { get; set; }
        public string Name { get; set; }
        private string _state = "pending", _verdict = "", _lines = "";
        public ObservableCollection<DiagFinding> Findings { get; private set; }
        public DiagLayer() { Findings = new ObservableCollection<DiagFinding>(); }
        public string State { get { return _state; } set { _state = value; Raise("State"); Raise("Bar"); Raise("VerdictText"); Raise("Ok"); Raise("VerdictVis"); } }
        public string Verdict { get { return _verdict; } set { _verdict = value ?? ""; Raise("Verdict"); Raise("VerdictText"); } }
        public string Lines { get { return _lines; } set { _lines = value ?? ""; Raise("Lines"); Raise("LinesVis"); } }
        public bool Ok { get { return _state == "ok"; } }
        public string Bar { get { return _state == "ok" ? "#FF34D399" : (_state == "finding" ? "#FFF87171" : (_state == "reading" ? "#FF4C8DFF" : "#FF3C3C45")); } }
        public string VerdictText
        {
            get
            {
                switch (_state)
                {
                    case "ok": return "OK - nothing here explains it";
                    case "finding": return _verdict;
                    case "reading": return "Reading...";
                    default: return "Not read yet";
                }
            }
        }
        // the joined verdict line steps aside once the findings are listed one by one under it
        public string VerdictVis { get { return (_state == "finding" && Findings.Count > 0) ? "Collapsed" : "Visible"; } }
        public string LinesVis { get { return _lines.Length > 0 ? "Visible" : "Collapsed"; } }
        public void RaiseFindings() { Raise("VerdictVis"); }
        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    }

    /// <summary>
    /// The worker's slow-PC report: while it runs, one "Checking: VERDICT Lk: ..." status per layer
    /// in reading order; when it ends, a file with a header line, the VERDICT lines and the seven
    /// sections. The screen follows both - the statuses as they arrive, the file for the lines -
    /// and under every finding puts the remedy the script's table gives it.
    /// </summary>
    public static class Diagnosis
    {
        public static readonly string[] Keys = { "L0", "L1", "L2", "L3", "L4", "L5", "L6" };
        private static readonly Dictionary<string, string> Names = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            { "L0", "Hardware" }, { "L1", "What is running" }, { "L2", "Security software" }, { "L3", "Memory" },
            { "L4", "Background work" }, { "L5", "Startup and persistence" }, { "L6", "Faults and throttling" },
        };

        /// <summary>The remedy table, read once from the reader; empty until then, and Explain says "no automatic fix" for everything meanwhile.</summary>
        public static List<Remedy> Remedies = new List<Remedy>();
        public const string NoRemedyNote = "No automatic fix for this one - read the lines below and decide.";

        public static List<Remedy> ParseRemedies(string json)
        {
            var list = new List<Remedy>();
            var root = Json.ParseObject(json);
            if (root == null) return list;
            foreach (var o in Json.Arr(root, "items"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                list.Add(new Remedy { Layer = Json.Str(d, "layer"), Match = Json.Str(d, "match"), Kind = Json.Str(d, "kind"), Target = Json.Str(d, "target"), Label = Json.Str(d, "label"), Note = Json.Str(d, "note") });
            }
            return list;
        }

        /// <summary>Seven layers, none read yet.</summary>
        public static List<DiagLayer> Skeleton()
        {
            var layers = new List<DiagLayer>();
            foreach (var k in Keys) layers.Add(new DiagLayer { Key = k, Name = Names[k] });
            return layers;
        }

        /// <summary>
        /// The findings of one layer, each with its remedy: the verdict split on "; ", every piece
        /// matched against the layer's remedy rows, first match wins. A piece no row knows still
        /// gets a line, without a button. An OK layer has no findings.
        /// </summary>
        public static void Explain(DiagLayer layer, IList<Remedy> remedies)
        {
            layer.Findings.Clear();
            if (layer.State == "finding" && layer.Verdict.Length > 0 && layer.Verdict != "not reported")
            {
                foreach (var piece in layer.Verdict.Split(new[] { "; " }, StringSplitOptions.RemoveEmptyEntries))
                {
                    var text = piece.Trim();
                    var f = new DiagFinding { Text = text, Note = NoRemedyNote };
                    foreach (var r in remedies ?? new List<Remedy>())
                    {
                        if (r.Layer != layer.Key || r.Match.Length == 0) continue;
                        Match m;
                        try { m = Regex.Match(text, r.Match); } catch { continue; }
                        if (!m.Success) continue;
                        f.Note = r.Note; f.Label = r.Label; f.Kind = r.Kind; f.Target = r.Target;
                        // the names a tab should be filtered to, from the group the row points at
                        int g;
                        if ((r.Kind == "startup" || r.Kind == "uninstall") && int.TryParse(r.Target, out g) && g > 0 && g < m.Groups.Count)
                            f.Names = m.Groups[g].Value.Split(',').Select(n => n.Trim()).Where(n => n.Length > 0).ToArray();
                        break;
                    }
                    layer.Findings.Add(f);
                }
            }
            layer.RaiseFindings();
        }

        public static void ExplainAll(IEnumerable<DiagLayer> layers) { foreach (var l in layers) Explain(l, Remedies); }

        /// <summary>The general approach when no finding carries a button: what is worth doing on any slow PC, each a step the tool takes itself.</summary>
        public static List<DiagFinding> GeneralSteps()
        {
            return new List<DiagFinding>
            {
                new DiagFinding { Text = "Free up space", Kind = "cleanup", Label = "Open Cleanup", Note = "The safe set: temp files, caches, dumps, the recycle bin - and it says what it gave back." },
                new DiagFinding { Text = "Switch off what starts with Windows", Kind = "startup", Label = "Review startup entries", Note = "Fewer programs at sign-in is the cheapest speed there is. Nothing is uninstalled, and Task Manager can undo it." },
                new DiagFinding { Text = "Apply the performance tweaks", Kind = "tweaks", Label = "Open Tweaks", Note = "The pre-ticked set: power plan, indexer, background apps, telemetry - each with Undo." },
                new DiagFinding { Text = "Restart, then diagnose again", Kind = "fix", Target = "restart", Label = "Restart now", Note = "Days of uptime hide what a fresh start shows. Restart Now warns for 60 seconds first." },
            };
        }

        /// <summary>
        /// The plan for a finished report: every finding with a button becomes a numbered step, in
        /// layer order; the others are listed as things to know. Nothing to act on - or nothing
        /// found at all - gets the general steps instead of an empty card. Not visible while a run
        /// is still reading, or before any report exists.
        /// </summary>
        public static DiagPlan Plan(IList<DiagLayer> layers, bool complete)
        {
            var plan = new DiagPlan();
            if (layers == null || !complete || layers.Any(l => l.State == "pending" || l.State == "reading")) return plan;
            plan.Visible = true;
            foreach (var l in layers)
                foreach (var f in l.Findings)
                    (f.HasButton ? plan.Steps : plan.Notes).Add(f);
            var red = layers.Count(l => l.State == "finding");
            if (plan.Steps.Count > 0)
                plan.Summary = Format.Count(plan.Steps.Count, "thing", "things") + " the tool can do, in order - hardware first, then what runs in the background" +
                               (plan.Notes.Count > 0 ? " - and " + plan.Notes.Count + " to know about." : ".");
            else if (plan.Notes.Count > 0)
                plan.Summary = "Nothing here is fixed by a setting: " + Format.Count(plan.Notes.Count, "finding", "findings") + " to know about, in " + Format.Count(red, "layer", "layers") + ". Below, what is worth doing on any slow PC.";
            else
                plan.Summary = "All seven layers are clean - nothing measured explains a slow PC. Below, what is worth doing on any slow PC.";
            if (plan.Steps.Count == 0) plan.Steps.AddRange(GeneralSteps());
            for (var i = 0; i < plan.Steps.Count; i++) plan.Steps[i].Step = i + 1;
            return plan;
        }

        /// <summary>A verdict line from the worker's live status ("Checking: VERDICT L3: OK" or the bare "VERDICT L3: ..."): paints that layer and marks the next one as reading. False when the text is not a verdict.</summary>
        public static bool ApplyVerdict(List<DiagLayer> layers, string statusText)
        {
            var m = Regex.Match(statusText ?? "", @"VERDICT (L\d): (.*?)\s*$");
            if (!m.Success) return false;
            var key = m.Groups[1].Value;
            for (var i = 0; i < layers.Count; i++)
            {
                if (layers[i].Key != key) continue;
                var v = m.Groups[2].Value.Trim();
                layers[i].Verdict = v;
                layers[i].State = v == "OK" ? "ok" : "finding";
                Explain(layers[i], Remedies);
                if (i + 1 < layers.Count && layers[i + 1].State == "pending") layers[i + 1].State = "reading";
                return true;
            }
            return false;
        }

        /// <summary>The finished report file, into the seven layers with their verdicts, remedies and the lines behind each.</summary>
        public static List<DiagLayer> Parse(string text)
        {
            var layers = Skeleton();
            Fill(layers, text);
            return layers;
        }

        /// <summary>The same, onto layers already on screen - so the cards the live statuses painted gain their lines without being replaced.</summary>
        public static void Fill(List<DiagLayer> layers, string text)
        {
            var lines = (text ?? "").Replace("\r\n", "\n").Split('\n');
            var byKey = new Dictionary<string, DiagLayer>(StringComparer.Ordinal);
            foreach (var l in layers) byKey[l.Key] = l;
            DiagLayer cur = null;
            var body = new Dictionary<string, List<string>>(StringComparer.Ordinal);
            foreach (var raw in lines)
            {
                var line = raw.TrimEnd();
                var v = Regex.Match(line, @"^VERDICT (L\d): (.*)$");
                if (v.Success)
                {
                    DiagLayer l;
                    if (byKey.TryGetValue(v.Groups[1].Value, out l)) { l.Verdict = v.Groups[2].Value.Trim(); l.State = l.Verdict == "OK" ? "ok" : "finding"; }
                    continue;
                }
                var h = Regex.Match(line, @"^== (L\d)\s+(.*?) ==$");
                if (h.Success) { byKey.TryGetValue(h.Groups[1].Value, out cur); if (cur != null && !body.ContainsKey(cur.Key)) body[cur.Key] = new List<string>(); continue; }
                if (cur != null && line.Length > 0) body[cur.Key].Add(line.Trim());
            }
            foreach (var l in layers)
            {
                List<string> b;
                l.Lines = body.TryGetValue(l.Key, out b) ? string.Join("\n", b) : "";
                if (l.State == "pending" || l.State == "reading") { l.Verdict = "not reported"; l.State = "finding"; }
                Explain(l, Remedies);
            }
        }

        /// <summary>The first line of the report: "PC2Go slow-PC triage   2026-09-05 01:10   MACHINE".</summary>
        public static string Header(string text)
        {
            var i = (text ?? "").IndexOf('\n');
            return (i < 0 ? (text ?? "") : text.Substring(0, i)).Trim();
        }

        /// <summary>Where the worker said it wrote the report: the "(report: path)" tail of the row's detail.</summary>
        public static string ReportPathFrom(string detail)
        {
            var m = Regex.Match(detail ?? "", @"\(report: (.+?)\)\s*$");
            return m.Success ? m.Groups[1].Value.Trim() : "";
        }
    }
}
