// Experimental, main-executable-only adapter pin. CPU fixtures do not establish
// Cyberpunk compatibility. No driver preferences or system exports are changed.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdint.h>
#include "detours.h"

#if !defined(_WIN64)
#error NeuralGpuPin requires an x64 build.
#endif

namespace {
using CreateDevice = HRESULT (WINAPI *)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
using CreateFactory = HRESULT (WINAPI *)(REFIID, void **);
CreateDevice originalCreateDevice = nullptr;
LUID requestedLuid{};
INIT_ONCE adapterOnce = INIT_ONCE_STATIC_INIT;
HRESULT adapterResult = E_UNEXPECTED;
IDXGIAdapter1 *selectedAdapter = nullptr;
HMODULE systemDxgi = nullptr;

bool Readable(const void *address, SIZE_T length, const void *imageBase) {
    uintptr_t cursor = reinterpret_cast<uintptr_t>(address);
    if (!length || cursor > UINTPTR_MAX - length) return false;
    const uintptr_t end = cursor + length;
    while (cursor < end) {
        MEMORY_BASIC_INFORMATION region{};
        if (!VirtualQuery(reinterpret_cast<const void *>(cursor), &region, sizeof(region)) ||
            region.AllocationBase != imageBase || region.State != MEM_COMMIT ||
            (region.Protect & PAGE_GUARD)) return false;
        switch (region.Protect & 0xff) {
        case PAGE_READONLY: case PAGE_READWRITE: case PAGE_WRITECOPY:
        case PAGE_EXECUTE_READ: case PAGE_EXECUTE_READWRITE: case PAGE_EXECUTE_WRITECOPY:
            break;
        default: return false;
        }
        const uintptr_t regionBase = reinterpret_cast<uintptr_t>(region.BaseAddress);
        if (regionBase > UINTPTR_MAX - region.RegionSize) return false;
        const uintptr_t regionEnd = regionBase + region.RegionSize;
        if (regionEnd <= cursor) return false;
        cursor = regionEnd < end ? regionEnd : end;
    }
    return true;
}

struct Image {
    BYTE *base;
    DWORD size;
    bool Contains(uint64_t rva, SIZE_T length) const {
        return rva < size && length <= size - rva &&
            Readable(base + static_cast<SIZE_T>(rva), length, base);
    }
    const char *String(uint64_t rva) const {
        if (!rva) return nullptr;
        for (SIZE_T i = 0; i < 512; ++i) {
            if (!Contains(rva + i, 1)) return nullptr;
            if (!base[rva + i]) return reinterpret_cast<const char *>(base + rva);
        }
        return nullptr;
    }
};

bool ReadIntent(HMODULE mainModule) {
    // DLL_PROCESS_ATTACH may run on a loader worker with a small stack.
    // These buffers alone need 128 KiB; keep them in the image's zeroed data.
    // ReadIntent is called once, under the loader lock, during process attach.
    static wchar_t expected[32768]{};
    static wchar_t actual[32768]{};
    const DWORD expectedLength = GetEnvironmentVariableW(L"NEURAL_PIN_EXECUTABLE", expected, 32768);
    const DWORD actualLength = GetModuleFileNameW(mainModule, actual, 32768);
    const bool absolute = ((expected[0] >= L'A' && expected[0] <= L'Z') ||
        (expected[0] >= L'a' && expected[0] <= L'z')) && expected[1] == L':' && expected[2] == L'\\';
    const bool unc = expected[0] == L'\\' && expected[1] == L'\\' && expected[2];
    if (!expectedLength || expectedLength >= 32768 || !actualLength || actualLength >= 32768 ||
        (!absolute && !unc) || expectedLength != actualLength ||
        CompareStringOrdinal(expected, expectedLength, actual, actualLength, TRUE) != CSTR_EQUAL)
        return false;
    wchar_t text[19]{};
    if (GetEnvironmentVariableW(L"NEURAL_PIN_LUID", text, 19) != 17 || text[8] != L'-') return false;
    DWORD parts[2]{};
    for (unsigned part = 0; part < 2; ++part) {
        for (unsigned digit = 0; digit < 8; ++digit) {
            const wchar_t value = text[part * 9 + digit];
            unsigned nibble;
            if (value >= L'0' && value <= L'9') nibble = value - L'0';
            else if (value >= L'A' && value <= L'F') nibble = value - L'A' + 10;
            else return false; // Canonical eight uppercase hex digits per part.
            parts[part] = (parts[part] << 4) | nibble;
        }
    }
    if (!(parts[0] | parts[1])) return false;
    requestedLuid.HighPart = static_cast<LONG>(parts[0]);
    requestedLuid.LowPart = parts[1];
    return true;
}

bool FindSlot(HMODULE mainModule, void *volatile **foundSlot, HMODULE *importModule) {
    BYTE *base = reinterpret_cast<BYTE *>(mainModule);
    if (!Readable(base, sizeof(IMAGE_DOS_HEADER), base)) return false;
    const auto *dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE ||
        dos->e_lfanew < static_cast<LONG>(sizeof(IMAGE_DOS_HEADER))) return false;
    const SIZE_T ntOffset = static_cast<DWORD>(dos->e_lfanew);
    if (reinterpret_cast<uintptr_t>(base) > UINTPTR_MAX - ntOffset ||
        !Readable(base + ntOffset, sizeof(IMAGE_NT_HEADERS64), base)) return false;
    const auto *nt = reinterpret_cast<const IMAGE_NT_HEADERS64 *>(base + ntOffset);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
        nt->FileHeader.SizeOfOptionalHeader < sizeof(IMAGE_OPTIONAL_HEADER64) ||
        nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
        nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_IMPORT ||
        nt->OptionalHeader.SizeOfImage < ntOffset + sizeof(*nt) ||
        nt->OptionalHeader.SizeOfHeaders < ntOffset + sizeof(*nt) ||
        nt->OptionalHeader.SizeOfHeaders > nt->OptionalHeader.SizeOfImage) return false;
    Image image{base, nt->OptionalHeader.SizeOfImage};
    const IMAGE_DATA_DIRECTORY directory = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!directory.VirtualAddress || directory.Size < sizeof(IMAGE_IMPORT_DESCRIPTOR) ||
        !image.Contains(directory.VirtualAddress, directory.Size)) return false;
    unsigned matches = 0;
    bool terminated = false;
    for (SIZE_T index = 0; index < directory.Size / sizeof(IMAGE_IMPORT_DESCRIPTOR); ++index) {
        const auto *entry = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR *>(base +
            directory.VirtualAddress + index * sizeof(IMAGE_IMPORT_DESCRIPTOR));
        if (!entry->OriginalFirstThunk && !entry->TimeDateStamp && !entry->ForwarderChain &&
            !entry->Name && !entry->FirstThunk) { terminated = true; break; }
        const char *name = image.String(entry->Name);
        if (!name) return false;
        const wchar_t *moduleName = nullptr;
        if (lstrcmpiA(name, "sl.interposer.dll") == 0) moduleName = L"sl.interposer.dll";
        else if (lstrcmpiA(name, "d3d12.dll") == 0) moduleName = L"d3d12.dll";
        if (!moduleName) continue;
        if (!entry->OriginalFirstThunk || !entry->FirstThunk ||
            entry->OriginalFirstThunk % sizeof(IMAGE_THUNK_DATA64) ||
            entry->FirstThunk % sizeof(IMAGE_THUNK_DATA64)) return false;
        bool thunkTerminated = false;
        for (SIZE_T item = 0; item < image.size / sizeof(IMAGE_THUNK_DATA64); ++item) {
            const uint64_t lookupRva = entry->OriginalFirstThunk + item * sizeof(IMAGE_THUNK_DATA64);
            const uint64_t addressRva = entry->FirstThunk + item * sizeof(IMAGE_THUNK_DATA64);
            if (!image.Contains(lookupRva, sizeof(IMAGE_THUNK_DATA64)) ||
                !image.Contains(addressRva, sizeof(IMAGE_THUNK_DATA64))) return false;
            const auto *lookup = reinterpret_cast<const IMAGE_THUNK_DATA64 *>(base + lookupRva);
            auto *address = reinterpret_cast<IMAGE_THUNK_DATA64 *>(base + addressRva);
            if (!lookup->u1.AddressOfData) {
                if (address->u1.Function) return false;
                thunkTerminated = true; break;
            }
            if (IMAGE_SNAP_BY_ORDINAL64(lookup->u1.Ordinal)) continue;
            if (lookup->u1.AddressOfData > MAXDWORD ||
                !image.Contains(lookup->u1.AddressOfData, sizeof(WORD))) return false;
            const char *function = image.String(lookup->u1.AddressOfData + sizeof(WORD));
            if (!function) return false;
            if (lstrcmpA(function, "D3D12CreateDevice") != 0) continue;
            if (++matches != 1) return false;
            *foundSlot = reinterpret_cast<void *volatile *>(&address->u1.Function);
            *importModule = GetModuleHandleW(moduleName); // Already mapped by the PE loader.
            if (!*importModule) return false;
        }
        if (!thunkTerminated) return false;
    }
    return terminated && matches == 1;
}

HRESULT LastErrorResult() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_MOD_NOT_FOUND);
}

BOOL CALLBACK ResolveAdapter(PINIT_ONCE, PVOID, PVOID *) {
    // The first main-EXE call runs this outside DllMain. The absolute system DLL
    // avoids accidentally using the game-directory ReShade DXGI proxy.
    wchar_t path[MAX_PATH]{};
    const DWORD length = GetSystemDirectoryW(path, MAX_PATH);
    if (!length || length + 10 > MAX_PATH) { adapterResult = LastErrorResult(); return TRUE; }
    lstrcatW(path, L"\\dxgi.dll");
    systemDxgi = LoadLibraryExW(path, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!systemDxgi) { adapterResult = LastErrorResult(); return TRUE; }
    auto create = reinterpret_cast<CreateFactory>(GetProcAddress(systemDxgi, "CreateDXGIFactory1"));
    if (!create) { adapterResult = LastErrorResult(); return TRUE; }
    IDXGIFactory4 *factory = nullptr;
    adapterResult = create(IID_IDXGIFactory4, reinterpret_cast<void **>(&factory));
    if (FAILED(adapterResult)) return TRUE;
    IDXGIAdapter1 *adapter = nullptr;
    adapterResult = factory->EnumAdapterByLuid(requestedLuid, IID_IDXGIAdapter1,
        reinterpret_cast<void **>(&adapter));
    factory->Release();
    if (FAILED(adapterResult)) return TRUE;
    DXGI_ADAPTER_DESC1 description{};
    adapterResult = adapter->GetDesc1(&description);
    if (SUCCEEDED(adapterResult) && ((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) ||
        description.AdapterLuid.HighPart != requestedLuid.HighPart ||
        description.AdapterLuid.LowPart != requestedLuid.LowPart)) adapterResult = DXGI_ERROR_UNSUPPORTED;
    if (FAILED(adapterResult)) { adapter->Release(); return TRUE; }
    selectedAdapter = adapter;
    // Hold one adapter and the System32 module for process lifetime. Releasing
    // COM objects under DLL_PROCESS_DETACH's loader lock is intentionally avoided.
    return TRUE;
}

HRESULT WINAPI PinnedCreateDevice(IUnknown *, D3D_FEATURE_LEVEL minimum, REFIID iid, void **device) {
    if (!InitOnceExecuteOnce(&adapterOnce, ResolveAdapter, nullptr, nullptr) ||
        FAILED(adapterResult) || !selectedAdapter || !originalCreateDevice) {
        if (device) *device = nullptr;
        return FAILED(adapterResult) ? adapterResult : E_UNEXPECTED;
    }
    // Preserve Streamline's original wrapper and all arguments except pAdapter.
    // DLLs such as MGPU call through their own IAT slots and remain untouched.
    return originalCreateDevice(selectedAdapter, minimum, iid, device);
}

bool InstallPin(HMODULE mainModule) {
    void *volatile *slot = nullptr;
    HMODULE importModule = nullptr;
    if (!ReadIntent(mainModule) || !FindSlot(mainModule, &slot, &importModule)) return false;
    const auto exported = GetProcAddress(importModule, "D3D12CreateDevice");
    void *expected = reinterpret_cast<void *>(exported);
    if (!expected || *slot != expected || reinterpret_cast<uintptr_t>(slot) % sizeof(void *)) return false;
    originalCreateDevice = reinterpret_cast<CreateDevice>(exported);
    MEMORY_BASIC_INFORMATION region{};
    if (!VirtualQuery(const_cast<void **>(slot), &region, sizeof(region))) return false;
    const DWORD writable = (region.Protect & 0xff) >= PAGE_EXECUTE ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE;
    DWORD previousProtection = 0;
    if (!VirtualProtect(const_cast<void **>(slot), sizeof(void *), writable, &previousProtection)) return false;
    void *hook = reinterpret_cast<void *>(&PinnedCreateDevice);
    const bool replaced = InterlockedCompareExchangePointer(slot, hook, expected) == expected;
    DWORD ignored = 0;
    if (!VirtualProtect(const_cast<void **>(slot), sizeof(void *), previousProtection, &ignored)) {
        if (replaced) InterlockedCompareExchangePointer(slot, expected, hook);
        VirtualProtect(const_cast<void **>(slot), sizeof(void *), previousProtection, &ignored);
        return false;
    }
    return replaced;
}
} // namespace

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (DetourIsHelperProcess()) return TRUE;
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    if (!DetourRestoreAfterWith()) return FALSE;
    // Startup validation failures abort the injected process before game entry.
    // No LoadLibrary, COM, adapter enumeration, file I/O or GPU workload here.
    return InstallPin(GetModuleHandleW(nullptr)) ? TRUE : FALSE;
}
