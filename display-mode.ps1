# ArcRift 1.4 (Rift CV1, experimental): read and switch the Windows display mode of one display.
# The Rift S shows a placeholder display, so a session gives it a temporary EDID. The Rift CV1's own EDID already
# holds its real mode (2160x1200 at 90 Hz), so a CV1 session only asks Windows to use that mode and to go back
# afterwards. Dot-source this file; it only defines the ArcRiftDisplayMode type and changes nothing by itself.
#   Source(part)   the display source (\\.\DISPLAYn) of the monitor whose device path contains "part" (lower case)
#   Current(src)   its mode now, as "width height hertz"
#   Modes(src)     every mode Windows offers for it, same format (the list Advanced display settings shows)
#   Set(src, w, h, hz, testOnly)   switch to an offered mode. Temporary: it is not saved, so Windows returns to its
#                  saved mode after Restore, a restart, or when the display is unplugged and plugged back in.
#                  0 = done (or, with testOnly, "would work"); -100 = Windows does not offer that mode.
#   Restore(src)   back to the mode Windows has saved for this display.
if (-not ('ArcRiftDisplayMode' -as [type])) {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ArcRiftDisplayMode {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevicesW(string device, uint index, ref DISPLAY_DEVICE info, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettingsExW(string device, int mode, ref DEVMODE info, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")] static extern int ChangeMode(string device, ref DEVMODE mode, IntPtr window, uint flags, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")] static extern int ChangeToSaved(string device, IntPtr mode, IntPtr window, uint flags, IntPtr param);

    static DEVMODE Empty() { var mode = new DEVMODE(); mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return mode; }

    public static string Source(string monitorPathPart) {
        if (string.IsNullOrEmpty(monitorPathPart)) return null;
        for (uint a = 0; ; a++) {
            var adapter = new DISPLAY_DEVICE(); adapter.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevicesW(null, a, ref adapter, 0)) return null;
            for (uint m = 0; ; m++) {
                var monitor = new DISPLAY_DEVICE(); monitor.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevicesW(adapter.DeviceName, m, ref monitor, 1)) break; // 1: return the device interface path
                if ((monitor.DeviceID ?? "").ToLowerInvariant().IndexOf(monitorPathPart, StringComparison.Ordinal) >= 0) return adapter.DeviceName;
            }
        }
    }
    public static string Current(string source) {
        var mode = Empty();
        if (!EnumDisplaySettingsExW(source, -1, ref mode, 0)) return ""; // -1: the mode in use now
        return mode.dmPelsWidth + " " + mode.dmPelsHeight + " " + mode.dmDisplayFrequency;
    }
    public static string[] Modes(string source) {
        var lines = new List<string>();
        var seen = new HashSet<string>();
        for (int i = 0; ; i++) {
            var mode = Empty();
            if (!EnumDisplaySettingsExW(source, i, ref mode, 0)) break;
            if ((mode.dmDisplayFlags & 2) != 0) continue; // interlaced
            string key = mode.dmPelsWidth + " " + mode.dmPelsHeight + " " + mode.dmDisplayFrequency;
            if (seen.Add(key)) lines.Add(key);
        }
        return lines.ToArray();
    }
    public static int Set(string source, int width, int height, int hertz, bool testOnly) {
        var best = Empty();
        bool found = false;
        for (int i = 0; ; i++) {
            var mode = Empty();
            if (!EnumDisplaySettingsExW(source, i, ref mode, 0)) break;
            if ((mode.dmDisplayFlags & 2) != 0 || mode.dmPelsWidth != width || mode.dmPelsHeight != height || mode.dmDisplayFrequency != hertz) continue;
            if (!found || mode.dmBitsPerPel > best.dmBitsPerPel) { best = mode; found = true; }
        }
        if (!found) return -100;
        best.dmFields = 0x40000 | 0x80000 | 0x100000 | 0x200000 | 0x400000; // colour depth, width, height, flags, refresh rate
        return ChangeMode(source, ref best, IntPtr.Zero, testOnly ? 2u : 0u, IntPtr.Zero); // 2: CDS_TEST; 0: temporary change
    }
    public static int Restore(string source) { return ChangeToSaved(source, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@
}
