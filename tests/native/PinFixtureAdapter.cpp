// Test-only COM adapter. It carries a synthetic identity and never touches a GPU.
#include <windows.h>
#include <dxgi1_4.h>
#include <cstring>

class PinFixtureAdapter final : public IDXGIAdapter1 {
    ULONG references_ = 1;
    LUID luid_;
public:
    explicit PinFixtureAdapter(DWORD low) : luid_{low, 0x0000F17F} {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **value) override {
        if (!value) return E_POINTER;
        *value = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) || IsEqualIID(iid, IID_IDXGIObject) ||
            IsEqualIID(iid, IID_IDXGIAdapter) || IsEqualIID(iid, IID_IDXGIAdapter1)) {
            *value = static_cast<IDXGIAdapter1 *>(this); AddRef(); return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override { return --references_; }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID, UINT, const void *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID, const IUnknown *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID, UINT *, void *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetParent(REFIID, void **) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE EnumOutputs(UINT, IDXGIOutput **value) override {
        if (value) *value = nullptr; return DXGI_ERROR_NOT_FOUND;
    }
    HRESULT STDMETHODCALLTYPE GetDesc(DXGI_ADAPTER_DESC *desc) override {
        if (!desc) return E_POINTER;
        std::memset(desc, 0, sizeof(*desc)); desc->AdapterLuid = luid_;
        lstrcpyW(desc->Description, L"CPU-only pinning fixture"); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE CheckInterfaceSupport(REFGUID, LARGE_INTEGER *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDesc1(DXGI_ADAPTER_DESC1 *desc) override {
        if (!desc) return E_POINTER;
        std::memset(desc, 0, sizeof(*desc)); desc->AdapterLuid = luid_;
        lstrcpyW(desc->Description, L"CPU-only pinning fixture"); return S_OK;
    }
};
