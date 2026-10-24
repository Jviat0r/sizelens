using System;
using System.Runtime.InteropServices;

// The string comparisons Explorer could be using to sort a text column.
public static class SizeLensComparers
{
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    public static extern int StrCmpLogicalW(string a, string b);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int CompareStringEx(string locale, uint flags, string a, int alen, string b, int blen, IntPtr v, IntPtr r, IntPtr p);

    [StructLayout(LayoutKind.Sequential)]
    struct PROPVARIANT { public ushort vt; public ushort r1, r2, r3; public IntPtr p; public IntPtr p2; }

    [DllImport("propsys.dll")]
    static extern int PropVariantCompareEx(ref PROPVARIANT a, ref PROPVARIANT b, int unit, int flags);

    const ushort VT_LPWSTR = 31;

    // PropVariantCompareEx: what the Windows property system (and Explorer's property columns) use.
    public static int PropVariant(string a, string b, int flags)
    {
        PROPVARIANT x = new PROPVARIANT(); x.vt = VT_LPWSTR; x.p = Marshal.StringToCoTaskMemUni(a);
        PROPVARIANT y = new PROPVARIANT(); y.vt = VT_LPWSTR; y.p = Marshal.StringToCoTaskMemUni(b);
        try { return PropVariantCompareEx(ref x, ref y, 0, flags); }
        finally { Marshal.FreeCoTaskMem(x.p); Marshal.FreeCoTaskMem(y.p); }
    }

    // CompareStringEx with the user's locale: <0, 0, >0.
    public static int Linguistic(string a, string b, uint flags)
    {
        return CompareStringEx(null, flags, a, a.Length, b, b.Length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) - 2;
    }

    public static int Ordinal(string a, string b) { return string.CompareOrdinal(a, b); }
    public static int OrdinalIgnoreCase(string a, string b) { return string.Compare(a, b, StringComparison.OrdinalIgnoreCase); }
}
