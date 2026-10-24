// Test helper: talk to an open File Explorer window's view through the shell's own COM interfaces.
// Used by tests\explorer-renavigate.ps1. Reads and sets the view's columns (IColumnManager) and
// re-navigates the window (IShellBrowser::BrowseObject), the same calls sizelens.exe makes.
using System;
using System.Runtime.InteropServices;

namespace SizeLensTest
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CM_COLUMNINFO
    {
        public uint cbSize; public uint dwMask; public uint dwState; public uint uWidth; public uint uDefaultWidth; public uint uIdealWidth;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string wszName;
    }

    [ComImport, Guid("6d5140c1-7436-11ce-8034-00aa006009fa"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IServiceProvider { [PreserveSig] int QueryService(ref Guid sid, ref Guid iid, out IntPtr ppv); }

    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellBrowser
    {
        [PreserveSig] int GetWindow(out IntPtr hwnd);
        [PreserveSig] int ContextSensitiveHelp(int enter);
        [PreserveSig] int InsertMenusSB(IntPtr a, IntPtr b);
        [PreserveSig] int SetMenuSB(IntPtr a, IntPtr b, IntPtr c);
        [PreserveSig] int RemoveMenusSB(IntPtr a);
        [PreserveSig] int SetStatusTextSB(IntPtr a);
        [PreserveSig] int EnableModelessSB(int a);
        [PreserveSig] int TranslateAcceleratorSB(IntPtr a, ushort b);
        [PreserveSig] int BrowseObject(IntPtr pidl, uint flags);
        [PreserveSig] int GetViewStateStream(uint a, out IntPtr b);
        [PreserveSig] int GetControlWindow(uint a, out IntPtr b);
        [PreserveSig] int SendControlMsg(uint a, uint b, IntPtr c, IntPtr d, out IntPtr e);
        [PreserveSig] int QueryActiveShellView([MarshalAs(UnmanagedType.IUnknown)] out object view);
    }

    [ComImport, Guid("d8ec27bb-3f3b-4042-b10a-4acfd924d453"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IColumnManager
    {
        [PreserveSig] int SetColumnInfo(ref PROPERTYKEY key, ref CM_COLUMNINFO info);
        [PreserveSig] int GetColumnInfo(ref PROPERTYKEY key, ref CM_COLUMNINFO info);
        [PreserveSig] int GetColumnCount(uint flags, out uint count);
        [PreserveSig] int GetColumns(uint flags, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] PROPERTYKEY[] keys, uint count);
        [PreserveSig] int SetColumns([In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] PROPERTYKEY[] keys, uint count);
    }

    public static class ExplorerView
    {
        static readonly Guid SID_STopLevelBrowser = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");
        static readonly Guid IID_IShellBrowser = new Guid("000214E2-0000-0000-C000-000000000046");
        public static readonly PROPERTYKEY PKEY_Comment = new PROPERTYKEY { fmtid = new Guid("F29F85E0-4FF9-1068-AB91-08002B27B3D9"), pid = 6 };

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHParseDisplayName(string name, IntPtr bc, out IntPtr pidl, uint sfgaoIn, out uint sfgaoOut);
        [DllImport("ole32.dll")] static extern void CoTaskMemFree(IntPtr p);
        [DllImport("propsys.dll", CharSet = CharSet.Unicode)] static extern int PSGetNameFromPropertyKey(ref PROPERTYKEY key, out IntPtr name);

        static IShellBrowser Browser(object window)
        {
            var sp = (IServiceProvider)window;
            Guid sid = SID_STopLevelBrowser, iid = IID_IShellBrowser;
            IntPtr p;
            int hr = sp.QueryService(ref sid, ref iid, out p);
            if (hr != 0) throw new COMException("QueryService(IShellBrowser)", hr);
            var b = (IShellBrowser)Marshal.GetObjectForIUnknown(p);
            Marshal.Release(p);
            return b;
        }

        static IColumnManager Columns(object window)
        {
            object view;
            int hr = Browser(window).QueryActiveShellView(out view);
            if (hr != 0) throw new COMException("QueryActiveShellView", hr);
            return (IColumnManager)view;
        }

        /// The view's visible columns, as canonical property names (System.ItemNameDisplay, ...).
        public static string[] VisibleColumns(object window)
        {
            var cm = Columns(window);
            uint n; cm.GetColumnCount(2 /*CM_ENUM_VISIBLE*/, out n);
            var keys = new PROPERTYKEY[n];
            cm.GetColumns(2, keys, n);
            var names = new string[n];
            for (int i = 0; i < n; i++)
            {
                IntPtr s;
                names[i] = PSGetNameFromPropertyKey(ref keys[i], out s) == 0 ? Marshal.PtrToStringUni(s) : keys[i].fmtid + "," + keys[i].pid;
                if (s != IntPtr.Zero) CoTaskMemFree(s);
            }
            return names;
        }

        /// Make Comments a visible column in this window's view (what More... > Comments does).
        public static int ShowComments(object window)
        {
            var cm = Columns(window);
            var info = new CM_COLUMNINFO { cbSize = (uint)Marshal.SizeOf(typeof(CM_COLUMNINFO)), dwMask = 0x2 /*CM_MASK_STATE*/, dwState = 0x2 /*CM_STATE_VISIBLE*/, wszName = "" };
            var k = PKEY_Comment;
            return cm.SetColumnInfo(ref k, ref info);
        }

        /// IShellBrowser::BrowseObject on a path, with the given SBSP_ flags.
        public static int Browse(object window, string path, uint flags)
        {
            IntPtr pidl; uint o;
            int hr = SHParseDisplayName(path, IntPtr.Zero, out pidl, 0, out o);
            if (hr != 0) return hr;
            try { return Browser(window).BrowseObject(pidl, flags); }
            finally { CoTaskMemFree(pidl); }
        }
    }
}
