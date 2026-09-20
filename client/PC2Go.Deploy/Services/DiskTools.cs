using System;
using System.Collections.Generic;
using System.Linq;

namespace PC2Go.Deploy.Services
{
    /// <summary>One partition as the reader lists it, in offset order within its disk.</summary>
    public sealed class PartInfo
    {
        public int Number;
        public long Offset, Size, Free, MinSize, MaxSize, GapAfter;
        public string Letter = "", Label = "", FileSystem = "", Kind = "";
        public bool IsBoot, IsSystem, IsWinRE;
        public string Title { get { return Letter.Length > 0 ? Letter + ":" : (Kind == "recovery" ? "Recovery" : (Kind == "system" ? "System" : (Kind == "reserved" ? "Reserved" : "Partition " + Number))); } }
    }

    public sealed class DiskInfo
    {
        public int Number;
        public string Name = "", Style = "", Bus = "";
        public long Size;
        public bool IsBoot, IsDynamic;
        public List<PartInfo> Partitions = new List<PartInfo>();
    }

    /// <summary>
    /// What Extend can do for one volume: extend straight into the gap behind it, move the recovery
    /// partition out of the way first, or nothing - with the reason in words, because "greyed out"
    /// is the whole complaint about Disk Management.
    /// </summary>
    public sealed class ExtendPlan
    {
        public string Kind = "none";   // extend | move | none
        public long Bytes;
        public string Reason = "";
        public PartInfo Blocker;
    }

    /// <summary>The Disk Management sub-tab's pure pieces: the layout parse, the shrink room, the extend plan, the worker entry.</summary>
    public static class DiskTools
    {
        public const long RecoveryReserve = 1L << 30;
        /// <summary>Alignment slack: a gap under this is not free space anyone can use, so it is neither drawn on the bar nor offered to Extend. (A 1 MB gap behind a USB volume drew an accent "Extend..." button - for one megabyte.)</summary>
        public const long Slack = 8L << 20;

        public static List<DiskInfo> ParseLayout(string json)
        {
            var list = new List<DiskInfo>();
            var root = Json.ParseObject(json);
            if (root == null) return list;
            foreach (var o in Json.Arr(root, "disks"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                var disk = new DiskInfo
                {
                    Number = (int)Json.Long(d, "Number"), Name = Json.Str(d, "Name"), Size = Json.Long(d, "Size"), Style = Json.Str(d, "Style"), Bus = Json.Str(d, "Bus"),
                    IsBoot = Json.Bool(d, "IsBoot"), IsDynamic = Json.Bool(d, "IsDynamic"),
                };
                foreach (var po in Json.Arr(d, "Partitions"))
                {
                    var p = po as Dictionary<string, object>;
                    if (p == null) continue;
                    disk.Partitions.Add(new PartInfo
                    {
                        Number = (int)Json.Long(p, "Number"), Offset = Json.Long(p, "Offset"), Size = Json.Long(p, "Size"), Free = Json.Long(p, "Free"),
                        MinSize = Json.Long(p, "MinSize"), MaxSize = Json.Long(p, "MaxSize"), GapAfter = Json.Long(p, "GapAfter"),
                        Letter = Json.Str(p, "Letter"), Label = Json.Str(p, "Label"), FileSystem = Json.Str(p, "FileSystem"), Kind = Json.Str(p, "Kind"),
                        IsBoot = Json.Bool(p, "IsBoot"), IsSystem = Json.Bool(p, "IsSystem"), IsWinRE = Json.Bool(p, "IsWinRE"),
                    });
                }
                disk.Partitions = disk.Partitions.OrderBy(p => p.Offset).ToList();
                list.Add(disk);
            }
            return list;
        }

        /// <summary>How far Windows says the volume can shrink - past the unmovable files, not just the free space. 0 when unknown (the read ran without elevation).</summary>
        public static long ShrinkRoom(PartInfo p)
        {
            if (p.Kind != "volume" || p.MinSize <= 0) return 0;
            return Math.Max(0, p.Size - p.MinSize);
        }

        public static PartInfo NextAfter(DiskInfo d, PartInfo p)
        {
            var end = p.Offset + p.Size;
            return d.Partitions.Where(q => q.Offset >= end).OrderBy(q => q.Offset).FirstOrDefault();
        }

        public static ExtendPlan Extend(DiskInfo d, PartInfo p)
        {
            if (d.IsDynamic) return new ExtendPlan { Reason = "dynamic disk - Windows cannot resize it from here; convert it to basic first" };
            if (p.Kind != "volume") return new ExtendPlan { Reason = "not a data volume" };
            if (p.GapAfter >= Slack) return new ExtendPlan { Kind = "extend", Bytes = p.GapAfter };
            var next = NextAfter(d, p);
            if (next == null) return new ExtendPlan { Reason = "the volume already reaches the end of the disk - nothing to extend into" };
            if (next.Kind == "recovery")
            {
                if (next.GapAfter >= 64L << 20)
                {
                    // the gap plus the old recovery partition, less the gigabyte a new one takes at the end
                    var gain = Math.Max(0, next.GapAfter + next.Size - RecoveryReserve);
                    return new ExtendPlan { Kind = "move", Bytes = gain, Blocker = next,
                        Reason = "the Windows Recovery partition (" + Format.Size(next.Size) + ") sits between " + p.Title + " and " + Format.Size(next.GapAfter) + " of free space" };
                }
                return new ExtendPlan { Blocker = next, Reason = "the recovery partition behind " + p.Title + " has no free space behind it either" };
            }
            return new ExtendPlan { Blocker = next, Reason = next.Title + " (" + Format.Size(next.Size) + ") sits directly behind " + p.Title + " - only free space directly behind a volume can be joined to it" };
        }

        /// <summary>
        /// The worker entry. It carries the disk and partition NUMBERS to find the target, and its
        /// OFFSET and SIZE to prove the thing it found is the thing that was read.
        ///
        /// The numbers alone are not an identity, whatever the old comment here claimed. Disk
        /// numbers are handed out by enumeration order: unplug a USB disk and plug in another and
        /// the new one takes the free number. The panel is cached until Rescan, so a card saying
        /// "Shrink E: by 200 GB" can be pointing at a partition that no longer exists while disk 2
        /// partition 1 resolves perfectly well to somebody else's photo stick. Offset and size are
        /// fixed properties of a partition on a disk, so the worker can refuse instead of resizing
        /// the wrong volume.
        /// </summary>
        public static Dictionary<string, object> Entry(string action, DiskInfo d, PartInfo p, long bytes)
        {
            return new Dictionary<string, object> {
                { "id", "disk-" + d.Number + "-" + p.Number }, { "action", action },
                { "disk", d.Number }, { "partition", p.Number }, { "bytes", bytes },
                { "offset", p.Offset }, { "size", p.Size } };
        }

        public static string RowText(PartInfo p)
        {
            var bits = new List<string>();
            if (p.Label.Length > 0) bits.Add(p.Label);
            if (p.FileSystem.Length > 0) bits.Add(p.FileSystem);
            bits.Add(Format.Size(p.Size) + (p.Kind == "volume" ? ", " + Format.Size(p.Free) + " free" : ""));
            return string.Join("  ·  ", bits);
        }
    }
}
