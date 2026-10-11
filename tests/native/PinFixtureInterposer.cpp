// Replaces only the GPU-workload boundary in tests. Reads adapter metadata,
// records the received arguments, and returns an opaque dummy device.
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <cstdio>

extern "C" HRESULT WINAPI D3D12CreateDevice(IUnknown *adapter,
    D3D_FEATURE_LEVEL featureLevel, REFIID, void **device) {
    if (!adapter || featureLevel != D3D_FEATURE_LEVEL_11_0) return E_INVALIDARG;
    IDXGIAdapter1 *dxgi = nullptr;
    HRESULT hr = adapter->QueryInterface(IID_IDXGIAdapter1, reinterpret_cast<void **>(&dxgi));
    DXGI_ADAPTER_DESC1 desc{};
    if (SUCCEEDED(hr)) { hr = dxgi->GetDesc1(&desc); dxgi->Release(); }
    if (FAILED(hr)) return hr;
    wchar_t path[32768]{}; wchar_t caller[64]{};
    if (!GetEnvironmentVariableW(L"PIN_FIXTURE_OUTPUT", path, 32768) ||
        !GetEnvironmentVariableW(L"PIN_FIXTURE_CALLER", caller, 64)) return E_FAIL;
    HANDLE file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
    char line[256]{};
    const int length = std::snprintf(line, sizeof(line), "%ls|%08lX-%08lX|sl.interposer|%s\r\n",
        caller, static_cast<unsigned long>(desc.AdapterLuid.HighPart),
        static_cast<unsigned long>(desc.AdapterLuid.LowPart), device ? "device" : "probe");
    DWORD written = 0;
    const BOOL ok = length > 0 && WriteFile(file, line, static_cast<DWORD>(length), &written, nullptr);
    CloseHandle(file);
    if (!ok || written != static_cast<DWORD>(length)) return E_FAIL;
    if (device) *device = reinterpret_cast<void *>(static_cast<ULONG_PTR>(0xC0FFEE));
    return device ? S_OK : S_FALSE;
}
