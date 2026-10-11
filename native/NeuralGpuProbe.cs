using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace NeuralGaming.Native
{
    public sealed class AdapterIdentity
    {
        public uint Bus, Slot, PhysicalGpuCount;
        public string Luid;
    }
    public sealed class GpuSample
    {
        public int ProcessId, SampleIndex;
        public string Luid, Engine;
        public double Utilization;
    }
    public static class GpuProbe
    {
        // kernel32 is a Windows KnownDLL. Other libraries are loaded by absolute System32 path.
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
        static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr NvQuery(uint id);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NvInitialize();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NvEnumerate([Out] IntPtr[] handles, out uint count);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NvNumber(IntPtr gpu, out uint number);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NvLogical(IntPtr physical, out IntPtr logical);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NvInfo(IntPtr logical, ref LogicalInfo info);
        [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] struct LogicalInfo
        {
            public uint Version;
            public IntPtr Id;
            public uint Count;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst=64)] public IntPtr[] Physical;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public uint[] Reserved;
        }
        [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet=CharSet.Unicode)]
        delegate uint PdhOpen(string source, UIntPtr user, out IntPtr query);
        [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet=CharSet.Unicode)]
        delegate uint PdhAdd(IntPtr query, string path, UIntPtr user, out IntPtr counter);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate uint PdhCollect(IntPtr query);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate uint PdhArray(IntPtr counter, uint format, ref uint bytes, out uint count, IntPtr values);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate uint PdhClose(IntPtr query);
        [StructLayout(LayoutKind.Sequential)] struct CounterValue { public uint Status; public double Value; }
        [StructLayout(LayoutKind.Sequential)] struct CounterItem { public IntPtr Name; public CounterValue Value; }
        static readonly Regex Instance = new Regex(@"^pid_(\d+)_luid_0x([0-9a-f]{8})_0x([0-9a-f]{8})_phys_(\d+)_eng_\d+_engtype_(.+)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        static IntPtr LoadSystem(string name)
        {
            IntPtr module=LoadLibraryEx(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),name),IntPtr.Zero,0x800);
            if (module==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot load System32\\"+name);
            return module;
        }
        static T Bind<T>(IntPtr pointer)
        {
            if (pointer==IntPtr.Zero) throw new InvalidOperationException("Required read-only native API is unavailable.");
            return (T)(object)Marshal.GetDelegateForFunctionPointer(pointer,typeof(T));
        }
        static void CheckNv(int status, string operation)
        {
            if (status!=0) throw new InvalidOperationException(operation+" failed (NVAPI status "+status+").");
        }
        static void CheckPdh(uint status, string operation)
        {
            if (status!=0) throw new InvalidOperationException(operation+" failed (PDH status 0x"+status.ToString("X8")+"). GPU counters may be unavailable or inaccessible.");
        }
        public static AdapterIdentity[] ReadAdapters()
        {
            if (IntPtr.Size!=8) throw new InvalidOperationException("GPU observation requires a 64-bit PowerShell host.");
            IntPtr module=LoadSystem("nvapi64.dll");
            NvInitialize unload=null; bool initialized=false;
            try
            {
                NvQuery query=Bind<NvQuery>(GetProcAddress(module,"nvapi_QueryInterface"));
                unload=Bind<NvInitialize>(query(0xd22bdd7e));
                CheckNv(Bind<NvInitialize>(query(0x0150e828))(),"NvAPI_Initialize");
                initialized=true;
                IntPtr[] handles=new IntPtr[64]; uint count;
                CheckNv(Bind<NvEnumerate>(query(0xe5ac921f))(handles,out count),"NvAPI_EnumPhysicalGPUs");
                if (count>handles.Length) throw new InvalidOperationException("Invalid NVAPI physical GPU count.");
                NvNumber bus=Bind<NvNumber>(query(0x1be0b8e5)), slot=Bind<NvNumber>(query(0x2a0a350f));
                NvLogical logical=Bind<NvLogical>(query(0xadd604d1));
                NvInfo info=Bind<NvInfo>(query(0x842b066e));
                List<AdapterIdentity> result=new List<AdapterIdentity>();
                for (int i=0;i<count;i++)
                {
                    uint busId,slotId; IntPtr logicalHandle;
                    CheckNv(bus(handles[i],out busId),"NvAPI_GPU_GetBusId");
                    CheckNv(slot(handles[i],out slotId),"NvAPI_GPU_GetBusSlotId");
                    CheckNv(logical(handles[i],out logicalHandle),"NvAPI_GetLogicalGPUFromPhysicalGPU");
                    IntPtr id=Marshal.AllocHGlobal(8);
                    try
                    {
                        Marshal.WriteInt64(id,0);
                        LogicalInfo data=new LogicalInfo {Version=(uint)Marshal.SizeOf(typeof(LogicalInfo)) | 0x10000,Id=id,Physical=new IntPtr[64],Reserved=new uint[8]};
                        CheckNv(info(logicalHandle,ref data),"NvAPI_GPU_GetLogicalGpuInfo");
                        Luid luid=(Luid)Marshal.PtrToStructure(id,typeof(Luid));
                        result.Add(new AdapterIdentity {Bus=busId,Slot=slotId,PhysicalGpuCount=data.Count,Luid=unchecked((uint)luid.High).ToString("X8")+"-"+luid.Low.ToString("X8")});
                    }
                    finally { Marshal.FreeHGlobal(id); }
                }
                return result.ToArray();
            }
            finally
            {
                // NvAPI_Initialize increments a library reference count; pair every successful call.
                try { if (initialized) CheckNv(unload(),"NvAPI_Unload"); }
                finally { FreeLibrary(module); }
            }
        }
        public static GpuSample DecodeSample(string name,int processId,long status,double utilization)
        {
            return DecodeSample(name,processId,status,utilization,0);
        }
        public static GpuSample DecodeSample(string name,int processId,long status,double utilization,int sampleIndex)
        {
            if (name==null || (status!=0 && status!=1) || Double.IsNaN(utilization) || Double.IsInfinity(utilization) || utilization<0) return null;
            Match match=Instance.Match(name); int id;
            if (!match.Success || !Int32.TryParse(match.Groups[1].Value,out id) || id!=processId || match.Groups[4].Value!="0") return null;
            return new GpuSample {ProcessId=id,SampleIndex=sampleIndex,Luid=(match.Groups[2].Value+"-"+match.Groups[3].Value).ToUpperInvariant(),Engine=match.Groups[5].Value,Utilization=utilization};
        }
        public static GpuSample[] ReadProcessSamples(int processId,int sampleCount,int intervalMilliseconds)
        {
            if (processId<=0 || sampleCount<1 || sampleCount>120 || intervalMilliseconds<1 || intervalMilliseconds>10000) throw new ArgumentOutOfRangeException("Invalid process GPU observation bounds.");
            IntPtr module=LoadSystem("pdh.dll"), query=IntPtr.Zero;
            try
            {
                PdhOpen open=Bind<PdhOpen>(GetProcAddress(module,"PdhOpenQueryW"));
                PdhAdd add=Bind<PdhAdd>(GetProcAddress(module,"PdhAddEnglishCounterW"));
                PdhCollect collect=Bind<PdhCollect>(GetProcAddress(module,"PdhCollectQueryData"));
                PdhArray array=Bind<PdhArray>(GetProcAddress(module,"PdhGetFormattedCounterArrayW"));
                CheckPdh(open(null,UIntPtr.Zero,out query),"PdhOpenQuery");
                IntPtr counter;
                // PID-scoped wildcard arrays retain dynamic engine instances; decoding also checks PID.
                CheckPdh(add(query,@"\GPU Engine(pid_"+processId+@"_*)\Utilization Percentage",UIntPtr.Zero,out counter),"PdhAddEnglishCounterW");
                uint initial=collect(query);
                if (initial!=0 && initial!=0x800007D5) CheckPdh(initial,"PdhCollectQueryData");
                List<GpuSample> result=new List<GpuSample>();
                for (int sample=0;sample<sampleCount;sample++)
                {
                    Thread.Sleep(intervalMilliseconds);
                    uint status=collect(query);
                    if (status==0x800007D5) continue; // PDH_NO_DATA is missing observation, never zero utilization.
                    CheckPdh(status,"PdhCollectQueryData");
                    uint bytes=0,count=0;
                    status=array(counter,0x200,ref bytes,out count,IntPtr.Zero);
                    if (status==0x800007D5 || (status==0 && count==0)) continue;
                    if (status!=0x800007D2) CheckPdh(status,"PdhGetFormattedCounterArrayW");
                    if (bytes==0 || bytes>64*1024*1024) throw new InvalidOperationException("Invalid PDH result buffer size.");
                    IntPtr buffer=Marshal.AllocHGlobal((int)bytes);
                    try
                    {
                        status=array(counter,0x200,ref bytes,out count,buffer);
                        if (status==0x800007D2 || status==0x800007D5) continue; // Dynamic instance churn: skip this sample.
                        CheckPdh(status,"PdhGetFormattedCounterArrayW");
                        int stride=Marshal.SizeOf(typeof(CounterItem));
                        if ((long)count*stride>bytes) throw new InvalidOperationException("Invalid PDH counter item count.");
                        for (int i=0;i<count;i++)
                        {
                            CounterItem item=(CounterItem)Marshal.PtrToStructure(IntPtr.Add(buffer,i*stride),typeof(CounterItem));
                            GpuSample value=DecodeSample(Marshal.PtrToStringUni(item.Name),processId,item.Value.Status,item.Value.Value,sample);
                            if (value!=null) result.Add(value);
                        }
                    }
                    finally { Marshal.FreeHGlobal(buffer); }
                }
                return result.ToArray();
            }
            finally
            {
                if (query!=IntPtr.Zero) Bind<PdhClose>(GetProcAddress(module,"PdhCloseQuery"))(query);
                FreeLibrary(module);
            }
        }
        public static string ReadProcessPath(int processId)
        {
            if (processId<=0) throw new ArgumentOutOfRangeException("processId");
            IntPtr handle=OpenProcess(0x1000,false,processId); // PROCESS_QUERY_LIMITED_INFORMATION only.
            if (handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot query process executable path.");
            try
            {
                uint size=32768; StringBuilder path=new StringBuilder((int)size);
                if (!QueryFullProcessImageName(handle,0,path,ref size)) throw new Win32Exception(Marshal.GetLastWin32Error(),"QueryFullProcessImageName failed.");
                return path.ToString();
            }
            finally { CloseHandle(handle); }
        }
    }
}
