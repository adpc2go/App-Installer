using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace PC2Go.Deploy.Services
{
    public sealed class EdgeAccessException : Exception
    {
        public EdgeAccessException(string msg) : base(msg) { }
    }

    /// <summary>
    /// One HttpClient for the whole session: gzip asked for and undone here, the same user agent
    /// the script sends, and the access code only ever on the catalog request - installers come
    /// from signed /files/ URLs or vendor CDNs, icons are public.
    /// </summary>
    public sealed class EdgeClient : IDisposable
    {
        public readonly HttpClient Http;
        public string BaseUrl { get; private set; }
        public string Code { get; set; }

        public EdgeClient(string baseUrl, string code)
        {
            BaseUrl = (baseUrl ?? "").TrimEnd('/');
            Code = code ?? "";
            try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
            // .NET allows two connections per host by default, which would quietly turn sixteen
            // download workers into two and make the multi-connection path pointless
            ServicePointManager.DefaultConnectionLimit = 64;
            ServicePointManager.Expect100Continue = false;
            ServicePointManager.UseNagleAlgorithm = false;
            var h = new HttpClientHandler
            {
                AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
                AllowAutoRedirect = true,
            };
            Http = new HttpClient(h) { Timeout = Timeout.InfiniteTimeSpan };
            Http.DefaultRequestHeaders.UserAgent.ParseAdd("PC2GoDeploy/1.0");
        }

        /// <summary>The catalog text. A 403 marked x-pc2go-auth is the access gate and is reported as such.</summary>
        public async Task<string> GetCatalogAsync(CancellationToken ct)
        {
            using (var req = new HttpRequestMessage(HttpMethod.Get, BaseUrl + "/apps.json"))
            using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                if (!string.IsNullOrEmpty(Code)) req.Headers.TryAddWithoutValidation("x-pc2go-code", Code);
                cts.CancelAfter(TimeSpan.FromSeconds(30));
                using (var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseContentRead, cts.Token).ConfigureAwait(false))
                {
                    if (resp.StatusCode == HttpStatusCode.Forbidden)
                    {
                        IEnumerable<string> v;
                        var gate = resp.Headers.TryGetValues("x-pc2go-auth", out v);
                        throw new EdgeAccessException(gate ? "403 Forbidden - the catalog refused the access code"
                                                           : "403 Forbidden");
                    }
                    if (!resp.IsSuccessStatusCode) throw new HttpRequestException(((int)resp.StatusCode) + " " + resp.ReasonPhrase);
                    var bytes = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                    var text = Encoding.UTF8.GetString(bytes);
                    return text.TrimStart('﻿');
                }
            }
        }

        /// <summary>A small public file (an icon, a post-install payload) to disk, or false on any failure.</summary>
        public async Task<bool> GetFileAsync(string url, string dest, int timeoutSec, CancellationToken ct)
        {
            var status = await GetFileStatusAsync(url, dest, timeoutSec, ct).ConfigureAwait(false);
            return status >= 200 && status < 300;
        }

        /// <summary>
        /// The same fetch, reporting how the server answered: the HTTP status when it answered
        /// (2xx means the file is on disk), 0 when no answer came at all - no network, a timeout,
        /// this client already disposed. The icon cache needs the difference: only a server's
        /// "no such file" is worth remembering.
        /// </summary>
        public async Task<int> GetFileStatusAsync(string url, string dest, int timeoutSec, CancellationToken ct)
        {
            try
            {
                using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    cts.CancelAfter(TimeSpan.FromSeconds(timeoutSec));
                    using (var resp = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false))
                    {
                        var code = (int)resp.StatusCode;
                        if (!resp.IsSuccessStatusCode) return code;
                        var tmp = dest + ".tmp";
                        using (var s = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
                        using (var f = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, true))
                            await s.CopyToAsync(f, 1 << 16, cts.Token).ConfigureAwait(false);
                        if (File.Exists(dest)) File.Delete(dest);
                        File.Move(tmp, dest);
                        return code;
                    }
                }
            }
            catch
            {
                try { File.Delete(dest + ".tmp"); } catch { }
                return 0;
            }
        }

        public void Dispose() { Http.Dispose(); }
    }
}
