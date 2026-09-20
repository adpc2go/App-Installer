using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace PC2Go.Deploy.Services
{
    /// <summary>
    /// The access code, read the two ways the script reads it: the environment (survives the
    /// PowerShell 7 hand-off), then the DPAPI hand-off file go.ps1 writes before an elevated
    /// launch, because RunAs builds a fresh environment. Never a command-line argument - process
    /// listings show those.
    /// </summary>
    public static class AccessCode
    {
        public static string AccessPath
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "PC2GoDeploy", "access.bin"); }
        }

        public static string Read()
        {
            var env = Environment.GetEnvironmentVariable("PC2GO_CODE");
            if (!string.IsNullOrEmpty(env)) return env;
            var path = AccessPath;
            if (!File.Exists(path)) return "";
            try
            {
                // Freshness gate: LocalMachine DPAPI decrypts for anybody on the machine, so a token
                // left by a dead run would let a second technician authenticate with a code they
                // never typed. Older than two minutes either way is debris, and is wiped.
                var age = DateTime.UtcNow - File.GetLastWriteTimeUtc(path);
                if (Math.Abs(age.TotalMinutes) > 2) { Clear(); return ""; }
                var blob = File.ReadAllBytes(path);
                var raw = ProtectedData.Unprotect(blob, null, DataProtectionScope.LocalMachine);
                var code = Encoding.UTF8.GetString(raw);
                if (!string.IsNullOrEmpty(code)) Environment.SetEnvironmentVariable("PC2GO_CODE", code);
                return code;
            }
            catch { return ""; }
        }

        /// <summary>Zero-fill the exact byte length, then delete. The code is not ours to leave on a client's disk.</summary>
        public static void Clear()
        {
            var path = AccessPath;
            try
            {
                if (!File.Exists(path)) return;
                var len = new FileInfo(path).Length;
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None))
                {
                    var zero = new byte[Math.Max(1, Math.Min(len, 1 << 16))];
                    long left = len;
                    while (left > 0) { var n = (int)Math.Min(left, zero.Length); fs.Write(zero, 0, n); left -= n; }
                    fs.Flush(true);
                }
                File.Delete(path);
            }
            catch { }
        }
    }
}
