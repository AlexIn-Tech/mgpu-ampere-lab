// Experimental per-game bootstrap. This reports only that a child was spawned;
// the manager must verify the actual render adapter from fresh runtime evidence.
#include <windows.h>
#include <detours.h>
#include <algorithm>
#include <cstdio>
#include <cwchar>
#include <string>
#include <vector>

namespace {
struct Handle {
    HANDLE value = INVALID_HANDLE_VALUE;
    Handle() = default;
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;
    ~Handle() { close(); }
    void close() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); value = INVALID_HANDLE_VALUE; }
};
std::wstring expectedChild;
Handle ownedChild;

bool AbsoluteCanonical(const std::wstring &input, std::wstring &output) {
    // The manager supplies local drive paths. Reject drive-relative, device,
    // network and alternate-stream paths rather than reinterpret them.
    if (input.size() < 3 || input.size() > 32700 || input[1] != L':' || input[2] != L'\\' ||
        !((input[0] >= L'A' && input[0] <= L'Z') || (input[0] >= L'a' && input[0] <= L'z')) ||
        input.find_first_of(L"\"\r\n") != std::wstring::npos || input.find(L':', 2) != std::wstring::npos) return false;
    std::vector<wchar_t> full(32768);
    DWORD length = GetFullPathNameW(input.c_str(), static_cast<DWORD>(full.size()), full.data(), nullptr);
    if (!length || length >= full.size()) return false;
    output.assign(full.data(), length);
    if (_wcsicmp(input.c_str(), output.c_str()) != 0) return false;
    return true;
}

bool NoReparseParents(const std::wstring &path) {
    for (size_t end = 3; end < path.size(); ++end) {
        if (path[end] != L'\\') continue;
        const DWORD attributes = GetFileAttributesW(path.substr(0, end).c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
            (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    }
    return true;
}

bool ReadAt(HANDLE file, ULONGLONG offset, void *buffer, DWORD bytes, ULONGLONG size) {
    if (offset > size || bytes > size - offset) return false;
    LARGE_INTEGER position{}; position.QuadPart = static_cast<LONGLONG>(offset);
    DWORD read = 0;
    return SetFilePointerEx(file, position, nullptr, FILE_BEGIN) &&
        ReadFile(file, buffer, bytes, &read, nullptr) && read == bytes;
}

bool ValidatePe(const std::wstring &path, bool expectDll, Handle &locked) {
    if (!NoReparseParents(path)) return false;
    locked.value = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
        OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (locked.value == INVALID_HANDLE_VALUE) return false;
    BY_HANDLE_FILE_INFORMATION info{};
    LARGE_INTEGER length{};
    if (!GetFileInformationByHandle(locked.value, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
        !GetFileSizeEx(locked.value, &length) || length.QuadPart <= 0) return false;
    wchar_t finalPath[32768]{};
    // Volume-relative normalization avoids requiring permission to inspect the
    // global volume mount table. The handle was opened on this explicit drive,
    // and every supplied parent component was checked for reparses above.
    DWORD finalLength = GetFinalPathNameByHandleW(locked.value, finalPath, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_NONE);
    if (!finalLength || finalLength >= 32768 || _wcsicmp(finalPath, path.c_str() + 2) != 0) return false;
    const ULONGLONG size = static_cast<ULONGLONG>(length.QuadPart);
    IMAGE_DOS_HEADER dos{};
    IMAGE_NT_HEADERS64 nt{};
    if (!ReadAt(locked.value, 0, &dos, sizeof(dos), size) || dos.e_magic != IMAGE_DOS_SIGNATURE ||
        dos.e_lfanew < static_cast<LONG>(sizeof(dos)) ||
        !ReadAt(locked.value, static_cast<ULONGLONG>(dos.e_lfanew), &nt, sizeof(nt), size) ||
        nt.Signature != IMAGE_NT_SIGNATURE || nt.FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
        !(nt.FileHeader.Characteristics & IMAGE_FILE_EXECUTABLE_IMAGE) ||
        !!(nt.FileHeader.Characteristics & IMAGE_FILE_DLL) != expectDll ||
        nt.FileHeader.SizeOfOptionalHeader < sizeof(IMAGE_OPTIONAL_HEADER64) ||
        nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
        nt.FileHeader.NumberOfSections == 0 || nt.FileHeader.NumberOfSections > 96) return false;
    if (!expectDll) return true;
    if (nt.OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_EXPORT) return false;
    const auto &exports = nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (!exports.VirtualAddress || exports.Size < sizeof(IMAGE_EXPORT_DIRECTORY)) return false;
    std::vector<IMAGE_SECTION_HEADER> sections(nt.FileHeader.NumberOfSections);
    const ULONGLONG sectionOffset = static_cast<ULONGLONG>(dos.e_lfanew) +
        sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER) + nt.FileHeader.SizeOfOptionalHeader;
    if (!ReadAt(locked.value, sectionOffset, sections.data(),
        static_cast<DWORD>(sections.size() * sizeof(IMAGE_SECTION_HEADER)), size)) return false;
    auto rvaOffset = [&](DWORD rva, DWORD bytes, ULONGLONG &offset) {
        if (rva < nt.OptionalHeader.SizeOfHeaders && bytes <= nt.OptionalHeader.SizeOfHeaders - rva) {
            offset = rva; return offset <= size && bytes <= size - offset;
        }
        for (const auto &section : sections) {
            if (rva < section.VirtualAddress) continue;
            const ULONGLONG delta = static_cast<ULONGLONG>(rva) - section.VirtualAddress;
            if (delta > section.SizeOfRawData || bytes > section.SizeOfRawData - delta) continue;
            offset = static_cast<ULONGLONG>(section.PointerToRawData) + delta;
            return offset <= size && bytes <= size - offset;
        }
        return false;
    };
    ULONGLONG exportOffset = 0;
    IMAGE_EXPORT_DIRECTORY directory{};
    if (!rvaOffset(exports.VirtualAddress, sizeof(directory), exportOffset) ||
        !ReadAt(locked.value, exportOffset, &directory, sizeof(directory), size) ||
        directory.Base > 1 || directory.NumberOfFunctions <= 1 - directory.Base ||
        !directory.AddressOfFunctions) return false;
    const ULONGLONG functionRva = static_cast<ULONGLONG>(directory.AddressOfFunctions) +
        static_cast<ULONGLONG>(1 - directory.Base) * sizeof(DWORD);
    DWORD address = 0;
    if (functionRva > MAXDWORD || !rvaOffset(static_cast<DWORD>(functionRva), sizeof(address), exportOffset) ||
        !ReadAt(locked.value, exportOffset, &address, sizeof(address), size) || !address) return false;
    // Ordinal #1 must point into the image; no dependency-forwarded helper.
    if (address >= exports.VirtualAddress &&
        static_cast<ULONGLONG>(address) - exports.VirtualAddress < exports.Size) return false;
    return rvaOffset(address, 1, exportOffset);
}

bool CanonicalLuid(const std::wstring &value) {
    if (value.size() != 17 || value[8] != L'-') return false;
    bool nonzero = false;
    for (size_t i = 0; i < value.size(); ++i) {
        if (i == 8) continue;
        if (!((value[i] >= L'0' && value[i] <= L'9') || (value[i] >= L'A' && value[i] <= L'F'))) return false;
        nonzero |= value[i] != L'0';
    }
    return nonzero;
}

bool ChildEnvironment(const std::wstring &exe, const std::wstring &luid, std::vector<wchar_t> &block) {
    wchar_t *environment = GetEnvironmentStringsW();
    if (!environment) return false;
    std::vector<std::wstring> entries;
    for (const wchar_t *entry = environment; *entry; entry += std::wcslen(entry) + 1) {
        std::wstring value(entry);
        const size_t separator = value.find(L'=', value[0] == L'=' ? 1 : 0);
        const std::wstring key = value.substr(0, separator);
        if (_wcsicmp(key.c_str(), L"NEURAL_PIN_EXECUTABLE") != 0 &&
            _wcsicmp(key.c_str(), L"NEURAL_PIN_LUID") != 0) entries.push_back(std::move(value));
    }
    FreeEnvironmentStringsW(environment);
    entries.push_back(L"NEURAL_PIN_EXECUTABLE=" + exe);
    entries.push_back(L"NEURAL_PIN_LUID=" + luid);
    std::sort(entries.begin(), entries.end(), [](const std::wstring &a, const std::wstring &b) {
        return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_LESS_THAN;
    });
    for (const auto &entry : entries) {
        if (block.size() + entry.size() + 2 > 32767) return false;
        block.insert(block.end(), entry.begin(), entry.end()); block.push_back(L'\0');
    }
    block.push_back(L'\0');
    return true;
}

BOOL WINAPI CreateOwnedChild(LPCWSTR application, LPWSTR commandLine,
    LPSECURITY_ATTRIBUTES processAttributes, LPSECURITY_ATTRIBUTES threadAttributes,
    BOOL inherit, DWORD flags, LPVOID environment, LPCWSTR directory,
    LPSTARTUPINFOW startup, LPPROCESS_INFORMATION process) {
    // Same-architecture insertion must not create Detours helper processes.
    if (!application || _wcsicmp(application, expectedChild.c_str()) != 0 ||
        (ownedChild.value != INVALID_HANDLE_VALUE)) { SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
    if (!CreateProcessW(application, commandLine, processAttributes, threadAttributes,
        inherit, flags, environment, directory, startup, process)) return FALSE;
    if (!DuplicateHandle(GetCurrentProcess(), process->hProcess, GetCurrentProcess(),
        &ownedChild.value, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
        DWORD error = GetLastError();
        TerminateProcess(process->hProcess, 1);
        CloseHandle(process->hThread); CloseHandle(process->hProcess);
        ZeroMemory(process, sizeof(*process)); SetLastError(error); return FALSE;
    }
    return TRUE;
}

void StopOwnedChild() {
    if (ownedChild.value != INVALID_HANDLE_VALUE) {
        TerminateProcess(ownedChild.value, 1);
        WaitForSingleObject(ownedChild.value, 1000);
    }
}
}

int wmain(int argc, wchar_t **argv) {
    std::wstring exeInput, dllInput, luid, resultInput;
    if (argc != 9) { std::fprintf(stderr, "Expected --exe --dll --luid --result.\n"); return 2; }
    for (int i = 1; i < argc; i += 2) {
        std::wstring *slot = nullptr;
        if (std::wcscmp(argv[i], L"--exe") == 0) slot = &exeInput;
        else if (std::wcscmp(argv[i], L"--dll") == 0) slot = &dllInput;
        else if (std::wcscmp(argv[i], L"--luid") == 0) slot = &luid;
        else if (std::wcscmp(argv[i], L"--result") == 0) slot = &resultInput;
        if (!slot || !slot->empty() || !argv[i + 1][0]) return 2;
        *slot = argv[i + 1];
    }
    std::wstring exe, dll, result;
    Handle exeFile, dllFile;
    if (!CanonicalLuid(luid) || !AbsoluteCanonical(exeInput, exe) ||
        !AbsoluteCanonical(dllInput, dll) || !AbsoluteCanonical(resultInput, result)) {
        std::fprintf(stderr, "Invalid canonical LUID or absolute local path.\n"); return 3;
    }
    if (!ValidatePe(exe, false, exeFile)) {
        std::fprintf(stderr, "Executable must be a regular non-reparse x64 PE.\n"); return 3;
    }
    if (!ValidatePe(dll, true, dllFile)) {
        std::fprintf(stderr, "DLL must be a regular non-reparse x64 PE with ordinal 1.\n"); return 3;
    }
    if (!NoReparseParents(result)) {
        std::fprintf(stderr, "Result directory must be regular and non-reparse.\n"); return 3;
    }
    int byteCount = WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, dll.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (byteCount < 1) return 3;
    std::vector<char> dllAnsi(static_cast<size_t>(byteCount));
    BOOL defaulted = FALSE;
    if (!WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, dll.c_str(), -1,
        dllAnsi.data(), byteCount, nullptr, &defaulted) || defaulted) return 3;
    std::vector<wchar_t> environment;
    if (!ChildEnvironment(exe, luid, environment)) return 4;
    Handle resultFile;
    resultFile.value = CreateFileW(result.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
        CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (resultFile.value == INVALID_HANDLE_VALUE) {
        std::fprintf(stderr, "Result must be a new file in an existing regular directory.\n"); return 5;
    }
    auto failure = [&](int code) {
        StopOwnedChild(); resultFile.close(); DeleteFileW(result.c_str()); return code;
    };
    expectedChild = exe;
    std::wstring commandLine = L"\"" + exe + L"\"";
    const std::wstring directory = exe.substr(0, exe.find_last_of(L'\\'));
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!DetourCreateProcessWithDllExW(exe.c_str(), &commandLine[0], nullptr, nullptr, FALSE,
        CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED | CREATE_NO_WINDOW,
        environment.data(), directory.c_str(), &startup, &process, dllAnsi.data(), CreateOwnedChild)) {
        std::fprintf(stderr, "Suspended child creation or DLL insertion failed (%lu).\n", static_cast<unsigned long>(GetLastError()));
        // Detours closes its handles on insertion failure; the independently
        // duplicated handle still identifies only our newly created child.
        return failure(6);
    }
    Handle thread, child;
    thread.value = process.hThread; child.value = process.hProcess;
    char json[128]{};
    const int count = std::snprintf(json, sizeof(json), "{\"ProcessId\":%lu,\"Status\":\"Spawned\"}\r\n",
        static_cast<unsigned long>(process.dwProcessId));
    DWORD written = 0;
    if (count <= 0 || !WriteFile(resultFile.value, json, static_cast<DWORD>(count), &written, nullptr) ||
        written != static_cast<DWORD>(count) || !FlushFileBuffers(resultFile.value)) return failure(7);
    if (ResumeThread(thread.value) != 1) return failure(8);
    return 0;
}
