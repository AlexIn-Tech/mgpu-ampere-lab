#include <windows.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <cwchar>
#ifndef PIN_FIXTURE_NO_IMPORT
#include "PinFixtureAdapter.cpp"
#include <d3d12.h>
extern "C" __declspec(dllimport) HRESULT WINAPI PinFixtureBridgeRun();
#endif

int wmain(int argc, wchar_t **argv) {
    if (argc == 4 && std::wcscmp(argv[1], L"--load-pin") == 0) {
        wchar_t actualExe[32768]{};
        if (!GetModuleFileNameW(nullptr, actualExe, 32768)) return 71;
        SetEnvironmentVariableW(L"NEURAL_PIN_EXECUTABLE", actualExe);
        SetEnvironmentVariableW(L"NEURAL_PIN_LUID", argv[3]);
        HMODULE pin = LoadLibraryW(argv[2]);
        if (pin) { FreeLibrary(pin); return 70; }
        return 0;
    }
    if (argc == 2 && std::wcscmp(argv[1], L"--enumerate") == 0) {
        IDXGIFactory4 *factory = nullptr;
        if (FAILED(CreateDXGIFactory1(IID_IDXGIFactory4, reinterpret_cast<void **>(&factory)))) return 40;
        for (UINT index = 0;; ++index) {
            IDXGIAdapter1 *adapter = nullptr;
            HRESULT hr = factory->EnumAdapters1(index, &adapter);
            if (hr == DXGI_ERROR_NOT_FOUND) break;
            if (FAILED(hr)) { factory->Release(); return 41; }
            DXGI_ADAPTER_DESC1 desc{};
            hr = adapter->GetDesc1(&desc); adapter->Release();
            if (FAILED(hr)) { factory->Release(); return 42; }
            std::printf("%08lX-%08lX|%u|%u\n", static_cast<unsigned long>(desc.AdapterLuid.HighPart),
                static_cast<unsigned long>(desc.AdapterLuid.LowPart), index, desc.Flags);
        }
        factory->Release(); return 0;
    }
    wchar_t marker[32768]{};
    if (!GetEnvironmentVariableW(L"PIN_FIXTURE_MAIN_MARKER", marker, 32768)) return 43;
    HANDLE file = CreateFileW(marker, GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return 44;
    CloseHandle(file);
#ifdef PIN_FIXTURE_NO_IMPORT
    return 0;
#else
    SetEnvironmentVariableW(L"PIN_FIXTURE_CALLER", L"Main");
    PinFixtureAdapter adapter(0xF17F0001);
    void *device = nullptr;
    HRESULT hr = D3D12CreateDevice(&adapter, D3D_FEATURE_LEVEL_11_0, IID_ID3D12Device, &device);
    if (hr != S_OK || device != reinterpret_cast<void *>(static_cast<ULONG_PTR>(0xC0FFEE))) return 45;
    if (FAILED(PinFixtureBridgeRun())) return 46;
    wchar_t waitText[32]{};
    DWORD waitLength = GetEnvironmentVariableW(L"PIN_FIXTURE_WAIT_MS", waitText, 32);
    if (waitLength) {
        wchar_t *end = nullptr;
        unsigned long waitMs = std::wcstoul(waitText, &end, 10);
        if (waitLength >= 32 || !end || *end || waitMs > 5000) return 47;
        Sleep(static_cast<DWORD>(waitMs));
    }
    return 0;
#endif
}
