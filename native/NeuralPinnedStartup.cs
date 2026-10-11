using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace NeuralGaming.Native
{
    // Windows 10+ startup ownership only. This job is unnamed, non-inheritable,
    // and contains only the exact new helper and its descendants. It is not a
    // sandbox for untrusted executables or a lifetime policy for a verified game.
    public static class PinnedStartup
    {
        internal sealed class KernelHandle : SafeHandleZeroOrMinusOneIsInvalid
        {
            public KernelHandle() : base(true) {}
            public KernelHandle(IntPtr value) : base(true) {SetHandle(value);}
            protected override bool ReleaseHandle(){return CloseHandle(handle);}
        }
        [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes
        {public int Length;public IntPtr Descriptor;[MarshalAs(UnmanagedType.Bool)] public bool Inherit;}
        [StructLayout(LayoutKind.Sequential)] struct StartupInfo
        {
            public int Size;public IntPtr Reserved,Desktop,Title;
            public uint X,Y,XSize,YSize,XChars,YChars,Fill,Flags;
            public ushort Show,ReservedBytes;public IntPtr ReservedPointer,Input,Output,Error;
        }
        [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx
        {public StartupInfo Info;public IntPtr Attributes;}
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo
        {public IntPtr Process,Thread;public uint ProcessId,ThreadId;}
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits
        {
            public long ProcessTime,JobTime;public uint Flags;
            public UIntPtr MinimumWorkingSet,MaximumWorkingSet;public uint ActiveProcesses;
            public UIntPtr Affinity;public uint Priority,Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters
        {public ulong Reads,Writes,Other,ReadBytes,WriteBytes,OtherBytes;}
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits
        {public BasicLimits Basic;public IoCounters Io;public UIntPtr ProcessMemory,JobMemory,PeakProcessMemory,PeakJobMemory;}
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern KernelHandle CreateJobObjectW(IntPtr attributes,string name);
        [DllImport("kernel32.dll",SetLastError=true)]
        static extern bool SetInformationJobObject(KernelHandle job,int information,ref ExtendedLimits limits,uint size);
        [DllImport("kernel32.dll",SetLastError=true)]
        static extern bool IsProcessInJob(IntPtr process,KernelHandle job,out bool contained);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern KernelHandle CreateFileW(string path,uint access,uint share,ref SecurityAttributes attributes,uint disposition,uint flags,IntPtr template);
        [DllImport("kernel32.dll",SetLastError=true)]
        static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref UIntPtr bytes);
        [DllImport("kernel32.dll",SetLastError=true)]
        static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,UIntPtr attribute,IntPtr value,UIntPtr size,IntPtr previous,IntPtr returned);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern bool CreateProcessW(string executable,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfoEx startup,out ProcessInfo process);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(KernelHandle thread);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(KernelHandle handle,uint milliseconds);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(KernelHandle process,out uint code);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

        static Win32Exception Error(string operation){return new Win32Exception(Marshal.GetLastWin32Error(),operation+" failed.");}
        static string LocalPath(string path)
        {
            if(String.IsNullOrEmpty(path) || path.Length<3 || !Char.IsLetter(path[0]) || path[1]!=':' || path[2]!='\\' ||
                path.IndexOfAny(new char[]{'"','\r','\n'})>=0 || path.IndexOf(':',2)>=0 ||
                !String.Equals(Path.GetFullPath(path),path,StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Startup requires canonical absolute drive paths.");
            return path;
        }
        static string Quote(string value)
        {
            if(value==null || value.IndexOf('\0')>=0)throw new ArgumentException("Invalid startup argument.");
            StringBuilder result=new StringBuilder("\"");int slashes=0;
            foreach(char character in value)
            {
                if(character=='\\'){slashes++;continue;}
                result.Append('\\',character=='"'?slashes*2+1:slashes);slashes=0;result.Append(character);
            }
            result.Append('\\',slashes*2);return result.Append('"').ToString();
        }
        static void Limits(KernelHandle job,bool cancelOnClose)
        {
            ExtendedLimits limits=new ExtendedLimits();limits.Basic.Flags=cancelOnClose?0x2000U:0;
            if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimits))))throw Error("SetInformationJobObject");
        }
        public sealed class Launch : IDisposable
        {
            KernelHandle job,process;
            public uint ProcessId {get;private set;}
            internal Launch(KernelHandle ownedJob,KernelHandle ownedProcess,uint id){job=ownedJob;process=ownedProcess;ProcessId=id;}
            void Open(){if(job==null || process==null)throw new ObjectDisposedException("Startup launch");}
            public bool WaitForExit(int milliseconds)
            {
                Open();if(milliseconds<0)throw new ArgumentOutOfRangeException("milliseconds");
                uint status=WaitForSingleObject(process,(uint)milliseconds);
                if(status==0)return true;if(status==258)return false;throw Error("WaitForSingleObject");
            }
            public uint ExitCode {get{Open();uint code;if(!GetExitCodeProcess(process,out code))throw Error("GetExitCodeProcess");return code;}}
            public bool ContainsProcess(IntPtr handle)
            {Open();bool contained;if(!IsProcessInJob(handle,job,out contained))throw Error("IsProcessInJob");return contained;}
            public void Handoff()
            {
                Open();
                // Only the manager calls this after validating the child handle,
                // executable identity and startup survival. Descendants retain
                // normal execution after the manager releases this startup job.
                Limits(job,false);
            }
            public void Dispose()
            {
                if(job!=null){job.Dispose();job=null;}
                if(process!=null){WaitForSingleObject(process,1000);process.Dispose();process=null;}
            }
        }
        public static Launch Start(string executable,string[] arguments,string directory,string stdout,string stderr)
        {
            if(IntPtr.Size!=8)throw new InvalidOperationException("Pinned startup requires a 64-bit host.");
            LocalPath(executable);LocalPath(directory);LocalPath(stdout);LocalPath(stderr);
            if(arguments==null)throw new ArgumentNullException("arguments");
            StringBuilder command=new StringBuilder(Quote(executable));
            foreach(string argument in arguments)command.Append(' ').Append(Quote(argument));
            if(command.Length>=32767)throw new ArgumentException("Startup command exceeds Windows limits.");
            KernelHandle job=null,process=null,thread=null;
            IntPtr attributes=IntPtr.Zero,handles=IntPtr.Zero,jobs=IntPtr.Zero;bool initialized=false;
            try
            {
                job=CreateJobObjectW(IntPtr.Zero,null);if(job.IsInvalid)throw Error("CreateJobObject");Limits(job,true);
                SecurityAttributes security=new SecurityAttributes{Length=Marshal.SizeOf(typeof(SecurityAttributes)),Inherit=true};
                using(KernelHandle output=CreateFileW(stdout,0x40000000,1,ref security,1,128,IntPtr.Zero))
                using(KernelHandle error=CreateFileW(stderr,0x40000000,1,ref security,1,128,IntPtr.Zero))
                using(KernelHandle input=CreateFileW("NUL",0x80000000,3,ref security,3,128,IntPtr.Zero))
                {
                    if(output.IsInvalid || error.IsInvalid || input.IsInvalid)throw Error("Open redirected startup streams");
                    UIntPtr bytes=UIntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,2,0,ref bytes);
                    ulong required=bytes.ToUInt64();if(required==0 || required>65536)throw Error("Size startup attributes");
                    attributes=Marshal.AllocHGlobal((int)required);
                    if(!InitializeProcThreadAttributeList(attributes,2,0,ref bytes))throw Error("Initialize startup attributes");initialized=true;
                    handles=Marshal.AllocHGlobal(3*IntPtr.Size);
                    Marshal.WriteIntPtr(handles,0,input.DangerousGetHandle());Marshal.WriteIntPtr(handles,IntPtr.Size,output.DangerousGetHandle());Marshal.WriteIntPtr(handles,2*IntPtr.Size,error.DangerousGetHandle());
                    if(!UpdateProcThreadAttribute(attributes,0,new UIntPtr(0x20002),handles,new UIntPtr((uint)(3*IntPtr.Size)),IntPtr.Zero,IntPtr.Zero))throw Error("Restrict startup handle inheritance");
                    jobs=Marshal.AllocHGlobal(IntPtr.Size);Marshal.WriteIntPtr(jobs,job.DangerousGetHandle());
                    // Atomic assignment also covers manager death between process
                    // creation and resume; no launcher code runs outside our job.
                    if(!UpdateProcThreadAttribute(attributes,0,new UIntPtr(0x2000D),jobs,new UIntPtr((uint)IntPtr.Size),IntPtr.Zero,IntPtr.Zero))throw Error("Assign startup job attribute (Windows 10+ required)");
                    StartupInfoEx startup=new StartupInfoEx();startup.Info.Size=Marshal.SizeOf(typeof(StartupInfoEx));
                    startup.Info.Flags=0x100;startup.Info.Input=input.DangerousGetHandle();startup.Info.Output=output.DangerousGetHandle();startup.Info.Error=error.DangerousGetHandle();startup.Attributes=attributes;
                    ProcessInfo child;
                    if(!CreateProcessW(executable,command,IntPtr.Zero,IntPtr.Zero,true,0x08080004,IntPtr.Zero,directory,ref startup,out child))throw Error("Create owned suspended startup helper");
                    process=new KernelHandle(child.Process);thread=new KernelHandle(child.Thread);
                    if(ResumeThread(thread)!=1)throw Error("Resume owned startup helper");
                    Launch launch=new Launch(job,process,child.ProcessId);job=null;process=null;return launch;
                }
            }
            finally
            {
                if(job!=null)job.Dispose();if(thread!=null)thread.Dispose();if(process!=null)process.Dispose();
                if(initialized)DeleteProcThreadAttributeList(attributes);
                if(attributes!=IntPtr.Zero)Marshal.FreeHGlobal(attributes);if(handles!=IntPtr.Zero)Marshal.FreeHGlobal(handles);if(jobs!=IntPtr.Zero)Marshal.FreeHGlobal(jobs);
            }
        }
    }
}
