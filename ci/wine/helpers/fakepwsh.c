/* fake pwsh.exe for the default-shell Wine test: writes C:\fake-pwsh-ran.txt
   with its own path, then runs cmd.exe in the same console so the terminal stays usable. */
#include <windows.h>
#include <stdio.h>
int main(void) {
	wchar_t self[MAX_PATH];
	GetModuleFileNameW(NULL, self, MAX_PATH);
	FILE *f = _wfopen(L"C:\\fake-pwsh-ran.txt", L"w");
	if (f) { fwprintf(f, L"fake pwsh ran: %ls\n", self); fclose(f); }
	STARTUPINFOW si = { sizeof si };
	PROCESS_INFORMATION pi;
	wchar_t cmd[] = L"cmd.exe";
	if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) return 1;
	WaitForSingleObject(pi.hProcess, INFINITE);
	DWORD code = 0;
	GetExitCodeProcess(pi.hProcess, &code);
	return (int)code;
}
