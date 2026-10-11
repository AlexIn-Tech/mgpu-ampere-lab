#include "PinFixtureAdapter.cpp"
#include <d3d12.h>

extern "C" HRESULT WINAPI PinFixtureBridgeRun() {
    SetEnvironmentVariableW(L"PIN_FIXTURE_CALLER", L"Bridge");
    PinFixtureAdapter adapter(0xF17F0002);
    void *device = nullptr;
    HRESULT hr = D3D12CreateDevice(&adapter, D3D_FEATURE_LEVEL_11_0,
        IID_ID3D12Device, &device);
    if (hr != S_OK || device != reinterpret_cast<void *>(static_cast<ULONG_PTR>(0xC0FFEE))) return E_FAIL;
    return S_OK;
}
