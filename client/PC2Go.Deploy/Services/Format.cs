using System;

namespace PC2Go.Deploy.Services
{
    /// <summary>The script's Format-Size / Format-Eta / Format-Elapsed, so the same number reads the same way.</summary>
    public static class Format
    {
        public static string Size(long bytes)
        {
            if (bytes >= 1L << 30) return (bytes / (double)(1L << 30)).ToString("N1") + " GB";
            if (bytes >= 1L << 20) return (bytes / (double)(1L << 20)).ToString("N1") + " MB";
            return (bytes / 1024.0).ToString("N0") + " KB";
        }

        public static string Eta(long remaining, double bytesPerSec)
        {
            if (bytesPerSec <= 0 || remaining <= 0) return "";
            var secs = (int)Math.Ceiling(remaining / bytesPerSec);
            if (secs > 86400) return "";
            if (secs < 60) return secs + "s left";
            var m = secs / 60;
            if (m < 60) return m + "m " + (secs % 60) + "s left";
            var h = m / 60;
            return h + "h " + (m % 60) + "m left";
        }

        /// <summary>"1 fix", "3 fixes": the number and the right form of the word - never "3 fix(es)". The plural defaults to one + "s".</summary>
        public static string Count(long n, string one, string many = null)
        {
            return n + " " + (n == 1 ? one : (many ?? one + "s"));
        }

        public static string Elapsed(int secs)
        {
            if (secs < 0) secs = 0;
            if (secs < 60) return secs + "s";
            var m = secs / 60;
            if (m < 60) return m + "m " + (secs % 60) + "s";
            var h = m / 60;
            return h + "h " + (m % 60) + "m";
        }
    }
}
