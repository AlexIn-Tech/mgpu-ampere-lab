using System;
using System.IO;
using System.Text;
namespace NeuralGaming.Native
{
    // Static import inspection, never loads or executes the inspected image.
    public static class PinImports
    {
        private sealed class Image : IDisposable
        {
            private readonly FileStream stream;
            private readonly BinaryReader reader;
            private readonly long length;
            private uint sections;
            private ushort count;
            private uint headers;
            // Bounds on individual tables still permit repeated descriptors to
            // rescan the same thunks billions of times. Charge every seek/bounds
            // operation, including section lookups and names, to one image budget.
            private int remainingReadOperations=2000000;
            public Image(string path)
            {
                stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
                reader=new BinaryReader(stream); length=stream.Length;
            }
            public void Dispose(){reader.Dispose();}
            private void Bound(long pos,int bytes)
            {
                if(--remainingReadOperations<0)throw new InvalidDataException("PE inspection work budget exceeded.");
                if(pos<0 || bytes<0 || pos>length-bytes)throw new InvalidDataException("Invalid PE bounds.");
                stream.Position=pos;
            }
            private ushort U16(long pos){Bound(pos,2);return reader.ReadUInt16();}
            private uint U32(long pos){Bound(pos,4);return reader.ReadUInt32();}
            private ulong U64(long pos){Bound(pos,8);return reader.ReadUInt64();}
            private long Rva(uint rva,int size)
            {
                if(rva<headers){Bound(rva,size);return rva;}
                for(int i=0;i<count;i++)
                {
                    long section=sections+40L*i;
                    uint va=U32(section+12),rawSize=U32(section+16),raw=U32(section+20);
                    if(rva>=va && (ulong)rva+ (uint)size <= (ulong)va+rawSize)
                    {long offset=raw+(long)rva-va;Bound(offset,size);return offset;}
                }
                throw new InvalidDataException("PE RVA is outside file-backed sections.");
            }
            private string Name(uint rva)
            {
                var text=new StringBuilder();
                for(int i=0;i<512;i++)
                {
                    uint current=checked(rva+(uint)i);Bound(Rva(current,1),1); byte b=reader.ReadByte();
                    if(b==0)return text.ToString();
                    if(b<32 || b>126)throw new InvalidDataException("Invalid PE import name.");text.Append((char)b);
                }
                throw new InvalidDataException("PE import name exceeds limit.");
            }
            public string Inspect()
            {
                if(U16(0)!=0x5A4D)throw new InvalidDataException("Executable has no PE header.");
                uint pe=U32(60);
                if(U32(pe)!=0x4550 || U16(pe+4)!=0x8664)throw new InvalidDataException("Selector requires an AMD64 PE image.");
                count=U16(pe+6);uint optional=checked(pe+24);ushort optionalSize=U16(pe+20);
                if(count==0 || count>96 || optionalSize<128 || U16(optional)!=0x20B)throw new InvalidDataException("Invalid PE32+ header.");
                headers=U32(optional+60);sections=checked(optional+optionalSize);Bound(sections,count*40);
                if(U32(optional+108)<2)return "";
                uint imports=U32(optional+120),importSize=U32(optional+124);
                if(imports==0 || importSize==0)return "";
                if(importSize<20 || importSize>1024*1024)throw new InvalidDataException("Invalid PE import table size.");
                string found="";int matches=0; bool ended=false;
                for(uint offset=0;offset+20<=importSize;offset+=20)
                {
                    long at=Rva(checked(imports+offset),20);
                    uint original=U32(at),name=U32(at+12),iat=U32(at+16);
                    if(original==0 && name==0 && iat==0 && U32(at+4)==0 && U32(at+8)==0){ended=true;break;}
                    string dll=Name(name);
                    if(!dll.Equals("sl.interposer.dll",StringComparison.OrdinalIgnoreCase) && !dll.Equals("d3d12.dll",StringComparison.OrdinalIgnoreCase))continue;
                    if(original==0 || iat==0)throw new InvalidDataException("Supported import requires an original thunk table.");
                    bool thunkEnded=false;
                    for(uint index=0;index<65536;index++)
                    {
                        ulong thunk=U64(Rva(checked(original+8*index),8));
                        if(thunk==0){thunkEnded=true;break;}
                        if((thunk & 0x8000000000000000UL)!=0)continue;
                        if(thunk>UInt32.MaxValue)throw new InvalidDataException("Invalid import thunk RVA.");
                        string function=Name(checked((uint)thunk+2));
                        if(function=="D3D12CreateDevice")
                        {
                            Rva(checked(iat+8*index),8); matches++;found=dll.ToLowerInvariant();
                        }
                    }
                    if(!thunkEnded)throw new InvalidDataException("Unterminated PE import thunk table.");
                }
                if(!ended)throw new InvalidDataException("Unterminated PE import descriptor table.");
                if(matches>1)throw new InvalidDataException("Ambiguous main executable device-creation imports.");
                return found;
            }
        }
        public static string Inspect(string path){using(var image=new Image(path)){return image.Inspect();}}
    }
}
