#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <filesystem>
#include <string>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Resolve runtime data from the executable, not the caller's working directory.
  // Named copies can therefore also be reopened directly or from a shortcut.
  std::wstring module_path(32768, L'\0');
  const DWORD path_length = ::GetModuleFileNameW(
      nullptr, module_path.data(), static_cast<DWORD>(module_path.size()));
  if (path_length == 0 || path_length >= module_path.size()) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  module_path.resize(path_length);
  const std::filesystem::path executable_path(module_path);
  flutter::DartProject project((executable_path.parent_path() / L"data").wstring());
  const std::wstring executable_name = executable_path.filename().wstring();
  std::wstring window_title = L"NetTest - \u7f51\u7edc\u8fde\u63a5\u6d4b\u8bd5 [" +
                              std::to_wstring(::GetCurrentProcessId()) + L"]";
  if (::CompareStringOrdinal(executable_name.c_str(), -1, L"nettest.exe", -1,
                            TRUE) != CSTR_EQUAL) {
    window_title = executable_name + L" - " + window_title;
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(40, 20);
  Win32Window::Size size(1180, 900);
  if (!window.Create(window_title, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
