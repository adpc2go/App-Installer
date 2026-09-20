using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Web.Script.Serialization;

namespace PC2Go.Deploy.Services
{
    /// <summary>
    /// The in-box serializer, so the client ships as one file. It is also what ConvertFrom-Json
    /// uses underneath in Windows PowerShell 5.1, which means the worker reads exactly the escapes
    /// this writes (an apostrophe goes out as ' from both).
    /// </summary>
    public static class Json
    {
        private static JavaScriptSerializer New()
        {
            return new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 64 };
        }

        public static Dictionary<string, object> ParseObject(string text)
        {
            if (text == null) return null;
            text = text.TrimStart('﻿', ' ', '\r', '\n', '\t');
            if (text.Length == 0) return null;
            return New().DeserializeObject(text) as Dictionary<string, object>;
        }

        public static string Serialize(object value)
        {
            return New().Serialize(value);
        }

        public static string Str(Dictionary<string, object> d, string key)
        {
            object v;
            if (d == null || !d.TryGetValue(key, out v) || v == null) return "";
            if (v is string) return (string)v;
            if (v is bool) return ((bool)v) ? "True" : "False";
            return Convert.ToString(v, CultureInfo.InvariantCulture) ?? "";
        }

        public static long Long(Dictionary<string, object> d, string key)
        {
            object v;
            if (d == null || !d.TryGetValue(key, out v) || v == null) return 0;
            try
            {
                if (v is string)
                {
                    long l; double dd;
                    var s = ((string)v).Trim();
                    if (s.Length == 0) return 0;
                    if (long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out l)) return l;
                    if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out dd)) return (long)dd;
                    return 0;
                }
                return Convert.ToInt64(v, CultureInfo.InvariantCulture);
            }
            catch { return 0; }
        }

        public static bool Has(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) && v != null;
        }

        // PowerShell's [bool] on a string: anything non-empty is true, so "false" is TRUE there.
        // The catalog editor writes real booleans, and that is what is honoured here; a string is
        // read the way a person means it.
        public static bool Bool(Dictionary<string, object> d, string key)
        {
            object v;
            if (d == null || !d.TryGetValue(key, out v) || v == null) return false;
            if (v is bool) return (bool)v;
            if (v is string) { var s = ((string)v).Trim(); return s.Length > 0 && !s.Equals("false", StringComparison.OrdinalIgnoreCase) && s != "0"; }
            try { return Convert.ToInt64(v, CultureInfo.InvariantCulture) != 0; } catch { return false; }
        }

        public static object[] Arr(Dictionary<string, object> d, string key)
        {
            object v;
            if (d == null || !d.TryGetValue(key, out v) || v == null) return new object[0];
            var arr = v as object[];
            if (arr != null) return arr;
            var list = v as System.Collections.IList;
            if (list != null) return list.Cast<object>().ToArray();
            // a scalar where an array was expected: PowerShell's @() would wrap it, so do the same
            return new[] { v };
        }

        public static string[] Strings(Dictionary<string, object> d, string key)
        {
            return Arr(d, key).Select(x => x == null ? "" : (x as string ?? Convert.ToString(x, CultureInfo.InvariantCulture)))
                              .Where(s => !string.IsNullOrEmpty(s)).ToArray();
        }
    }
}
