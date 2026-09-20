using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;

namespace PC2Go.Deploy.Models
{
    /// <summary>
    /// One catalog row. The property names are the ones the script's AppItem exposes, so the tile
    /// template, the batch strip and the pre-flight sheet bind to the same names in both clients.
    /// </summary>
    public sealed class AppItem : INotifyPropertyChanged
    {
        public string Id { get; set; }
        public string Url { get; set; }
        public string IconUrl { get; set; }
        public string Sha256 { get; set; }
        public string SilentArgs { get; set; }
        public string Entry { get; set; }
        public string FileName { get; set; }
        public string Instructions { get; set; }
        public string[] VerifyPaths { get; set; } = new string[0];
        public long SizeBytes { get; set; }
        public string DetectPath { get; set; }
        public string[] Requires { get; set; } = new string[0];
        public object[] PostInstall { get; set; } = new object[0];
        public int InstallTimeoutSec { get; set; }
        public bool AllowUi { get; set; }
        public string SilentSource { get; set; } = "";
        public string InstallerFamily { get; set; } = "";
        public bool Chain { get; set; }
        public string[] After { get; set; } = new string[0];
        public bool Dirty { get; set; }
        public bool PreExisting { get; set; }
        public string[] CreatedPaths { get; set; } = new string[0];

        public string Name { get; set; }
        public string Version { get; set; }
        public string Size { get; set; }
        public string Publisher { get; set; }
        public string Category { get; set; }
        public string IconData { get; set; }

        // ---- the Uninstall tab's row ----
        public string UnCommand { get; set; }
        public string UnArgs { get; set; }
        // the Firewall row's disabled-rule count rides here, as it does in the script's AppItem
        public string OrigState { get; set; } = "";
        public string RegKey { get; set; }
        public string UnFamily { get; set; } = "";
        public string Source { get; set; }
        public string BatchAction { get; set; }
        public bool IsSilent { get; set; }
        public string[] CleanPaths { get; set; } = new string[0];
        public string[] CleanReg { get; set; } = new string[0];
        public string[] CleanTokens { get; set; } = new string[0];
        public string[] CleanHosts { get; set; } = new string[0];
        public object[] Removers { get; set; } = new object[0];
        public string[] IconSources { get; set; } = new string[0];
        public string StoreLocation { get; set; }
        public string StoreLogo { get; set; }
        public DateTime? Installed { get; set; }
        private string _colInstalled = "";
        public string ColInstalled { get { return _colInstalled; } set { _colInstalled = value; Raise("ColInstalled"); } }
        private string _colSize = "";
        public string ColSize { get { return _colSize; } set { _colSize = value; Raise("ColSize"); } }
        private double _sizePercent;
        public double SizePercent { get { return _sizePercent; } set { _sizePercent = value; Raise("SizePercent"); } }
        private string _tagText = "";
        public string TagText { get { return _tagText; } set { _tagText = value; Raise("TagText"); } }
        private string _tagVis = "Collapsed";
        public string TagVis { get { return _tagVis; } set { _tagVis = value; Raise("TagVis"); } }
        private double _rowOpacity = 1.0;
        public double RowOpacity { get { return _rowOpacity; } set { _rowOpacity = value; Raise("RowOpacity"); } }

        private object _iconImage;
        public object IconImage { get { return _iconImage; } set { _iconImage = value; Raise("IconImage"); } }
        private string _glyphVis = "Visible";
        public string GlyphVis { get { return _glyphVis; } set { _glyphVis = value; Raise("GlyphVis"); } }
        private string _iconText = "";
        public string IconText { get { return _iconText; } set { _iconText = value; Raise("IconText"); } }
        private string _textVis = "Collapsed";
        public string TextVis { get { return _textVis; } set { _textVis = value; Raise("TextVis"); } }
        private string _imgVis = "Collapsed";
        public string ImgVis { get { return _imgVis; } set { _imgVis = value; Raise("ImgVis"); } }
        private string _iconBg;
        public string IconBg { get { return _iconBg; } set { _iconBg = value; Raise("IconBg"); } }
        private bool _sel;
        public bool IsSelected { get { return _sel; } set { if (_sel == value) return; _sel = value; Raise("IsSelected"); } }
        private string _status = "";
        public string Status { get { return _status; } set { _status = value ?? ""; Raise("Status"); } }
        private string _statusDetail = "";
        public string StatusDetail { get { return _statusDetail; } set { _statusDetail = value ?? ""; Raise("StatusDetail"); } }
        private string _fg = "#FF8A8A94";
        public string StatusFg { get { return _fg; } set { _fg = value; Raise("StatusFg"); } }
        private double _prog;
        public double Progress { get { return _prog; } set { _prog = value; Raise("Progress"); RingData = ArcPath(value); } }
        private string _progVis = "Collapsed";
        public string ProgressVis { get { return _progVis; } set { _progVis = value; Raise("ProgressVis"); } }
        private string _spinVis = "Collapsed";
        public string SpinnerVis { get { return _spinVis; } set { _spinVis = value; Raise("SpinnerVis"); } }
        private string _ring = "M 13,3";
        public string RingData { get { return _ring; } set { _ring = value; Raise("RingData"); } }
        private string _ringTrack = "Collapsed";
        public string RingTrackVis { get { return _ringTrack; } set { _ringTrack = value; Raise("RingTrackVis"); } }
        private string _badgeVis = "Collapsed";
        public string BadgeVis { get { return _badgeVis; } set { _badgeVis = value; Raise("BadgeVis"); } }
        private string _badgeBg = "#FF22C55E";
        public string BadgeBg { get { return _badgeBg; } set { _badgeBg = value; Raise("BadgeBg"); } }
        private string _badgeData = "M 0,0";
        public string BadgeData { get { return _badgeData; } set { _badgeData = value; Raise("BadgeData"); } }
        private string _removeVis = "Collapsed";
        public string RemoveVis { get { return _removeVis; } set { _removeVis = value; Raise("RemoveVis"); } }

        // App Store-style ring: arc from 12 o'clock, sweeping clockwise with progress
        public static string ArcPath(double pct)
        {
            if (pct <= 0.5) return "M 13,3";
            if (pct > 99.5) pct = 99.5;
            double ang = pct / 100.0 * 360.0;
            double rad = (ang - 90.0) * Math.PI / 180.0;
            double x = 13 + 10 * Math.Cos(rad), y = 13 + 10 * Math.Sin(rad);
            int large = ang > 180 ? 1 : 0;
            return string.Format(CultureInfo.InvariantCulture, "M 13,3 A 10,10 0 {0} 1 {1:F2},{2:F2}", large, x, y);
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    }

    /// <summary>A row on the pre-flight sheet: the catalog row plus the words the sheet adds to it.</summary>
    public sealed class PreflightRow : INotifyPropertyChanged
    {
        public AppItem Item { get; set; }
        public string Name { get { return Item.Name; } }
        public string IconBg { get { return Item.IconBg; } }
        public string IconText { get { return Item.IconText; } }
        public string SizeText { get; set; }
        private string _have = "";
        public string HaveText { get { return _have; } set { _have = value; Raise("HaveText"); } }
        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    }
}
