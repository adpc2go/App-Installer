using System;
using System.ComponentModel;

namespace PC2Go.Deploy.Models
{
    /// <summary>
    /// One row of the leftover review - the script's WipeItem, with change notification on Del
    /// so the sheet's buttons never have to refresh the whole view by hand.
    /// </summary>
    public sealed class WipeItem : INotifyPropertyChanged
    {
        public string OwnerId { get; set; }     // which app this leftover belongs to
        public string OwnerName { get; set; }   // grouping header in the preview
        public string Kind { get; set; }        // FOLDER|EMPTY|REG|SERVICE|TASK|HOSTS|SHORTCUT|TEMP|FOUND|AUTORUN|CREATED|REMOVER
        public string Type { get; set; }        // file|reg|regvalue|service|task|hosts|run  (for the worker)
        public string Path { get; set; }
        // for a regvalue target, Path is the KEY and this is the value inside it
        public string Name { get; set; }
        public long SizeBytes { get; set; }
        public string SizeText { get; set; }
        private bool _del;
        public bool Del { get { return _del; } set { if (_del == value) return; _del = value; Raise("Del"); } }
        // For a 'run' target: the arguments, and - when the tool is fetched rather than already
        // on the machine - the SHA-256 the worker must verify before a byte of it executes.
        public string Args { get; set; }
        public string Sha256 { get; set; }
        public string LocalFile { get; set; }
        public string NameVis { get { return Type == "run" ? "Visible" : "Collapsed"; } }
        // A name-only match on a SHORT token: listed last, hidden behind a toggle, never pre-ticked.
        public bool Weak { get; set; }
        public string WeakVis { get { return Weak ? "Visible" : "Collapsed"; } }
        public double RowOpacity { get { return Weak ? 0.6 : 1.0; } }
        // component shared with sibling products of the same suite - removing it breaks them
        public bool Shared { get; set; }
        public string SharedVis { get { return Shared ? "Visible" : "Collapsed"; } }
        public bool IsDir { get; set; }

        public int SectionOrder
        {
            get
            {
                switch (Type ?? "")
                {
                    case "file": return 0;
                    case "reg": case "regvalue": return 1;
                    case "service": case "task": return 2;
                    case "hosts": return 3;
                    default: return 4;
                }
            }
        }
        public string Section
        {
            get
            {
                switch (SectionOrder)
                {
                    case 0: return "Files and folders";
                    case 1: return "Registry entries";
                    case 2: return "Services and tasks";
                    case 3: return "Hosts file";
                    default: return "Removal tool";
                }
            }
        }
        // Segoe MDL2 Assets glyphs: folder, key, gear, globe, run
        public string SectionGlyph
        {
            get
            {
                switch (SectionOrder)
                {
                    case 0: return "";
                    case 1: return "";
                    case 2: return "";
                    case 3: return "";
                    default: return "";
                }
            }
        }
        // per row: folder / shortcut / page for files, clock for a task, the section's own otherwise
        public string Glyph
        {
            get
            {
                if (Type == "file")
                {
                    if (IsDir) return "";
                    if ((Path ?? "").EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)) return "";
                    return "";
                }
                if (Type == "task") return "";
                return SectionGlyph;
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    }
}
