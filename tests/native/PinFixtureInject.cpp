// Test-only negative-case injector. Only the test harness invokes this helper,
// exclusively against its freshly built CPU fixture executable.
#include <windows.h>
#include <detours.h>
#include <string>
#include <vector>
#include <cstdio>

int wmain(int argc, wchar_t **argv) {
    if (argc != 5) return 60;
    SetEnvironmentVariableW(L"NEURAL_PIN_EXECUTABLE", argv[3]);
    SetEnvironmentVariableW(L"NEURAL_PIN_LUID", argv[4]);
    int bytes = WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, argv[2], -1, nullptr, 0, nullptr, nullptr);
    if (bytes < 1) return 61;
    std::vector<char> dll(static_cast<size_t>(bytes));
    BOOL defaulted = FALSE;
    if (!WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, argv[2], -1, dll.data(), bytes, nullptr, &defaulted) || defaulted) return 62;
    std::wstring line = L"\"" + std::wstring(argv[1]) + L"\"";
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION child{};
    if (!DetourCreateProcessWithDllExW(argv[1], &line[0], nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child, dll.data(), nullptr)) return 63;
    const DWORD wait = WaitForSingleObject(child.hProcess, 10000);
    DWORD code = 64;
    if (wait == WAIT_OBJECT_0) GetExitCodeProcess(child.hProcess, &code);
    else { TerminateProcess(child.hProcess, 64); WaitForSingleObject(child.hProcess, 1000); }
    CloseHandle(child.hThread); CloseHandle(child.hProcess);
    std::printf("%lu\n", static_cast<unsigned long>(code));
    return wait == WAIT_OBJECT_0 ? 0 : 64;
}
