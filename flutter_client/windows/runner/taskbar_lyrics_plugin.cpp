#include "taskbar_lyrics_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <dwmapi.h>
#include <windows.h>
#include <winhttp.h>

#include <memory>
#include <sstream>
#include <string>

namespace {

constexpr wchar_t kDebugHost[] = L"127.0.0.1";
constexpr INTERNET_PORT kDebugPort = 7777;
constexpr wchar_t kDebugPath[] = L"/event";
constexpr int kLyricsWidth = 720;
constexpr int kLyricsOffsetX = 12;

using flutter::EncodableMap;
using flutter::EncodableValue;

void ReportResult(const char* operation, bool success, const std::string& error,
                  HWND host, HWND flutter_view, HWND taskbar) {
  const HWND parent = flutter_view ? GetParent(flutter_view) : nullptr;
  RECT window_rect{};
  RECT taskbar_client{};
  const BOOL has_window_rect =
      flutter_view && GetWindowRect(flutter_view, &window_rect);
  const BOOL has_taskbar_client =
      taskbar && GetClientRect(taskbar, &taskbar_client);
  const LONG_PTR style =
      flutter_view ? GetWindowLongPtrW(flutter_view, GWL_STYLE) : 0;
  const LONG_PTR ex_style =
      flutter_view ? GetWindowLongPtrW(flutter_view, GWL_EXSTYLE) : 0;
  DWORD host_cloaked = 0;
  DWORD view_cloaked = 0;
  if (host) {
    DwmGetWindowAttribute(host, DWMWA_CLOAKED, &host_cloaked,
                          sizeof(host_cloaked));
  }
  if (flutter_view) {
    DwmGetWindowAttribute(flutter_view, DWMWA_CLOAKED, &view_cloaked,
                          sizeof(view_cloaked));
  }

  std::ostringstream data;
  data << "{\"sessionId\":\"taskbar-lyrics-embed\"," 
       << "\"runId\":\"post-fix\",\"hypothesisId\":\"B,C,E\"," 
       << "\"location\":\"taskbar_lyrics_plugin.cpp:ReportResult\"," 
       << "\"msg\":\"[DEBUG] Windows taskbar lyrics " << operation
       << "\",\"data\":{"
       << "\"operation\":\"" << operation << "\"," 
       << "\"success\":" << (success ? "true" : "false") << ','
       << "\"error\":\"" << error << "\"," 
       << "\"host\":" << reinterpret_cast<uintptr_t>(host) << ','
       << "\"view\":" << reinterpret_cast<uintptr_t>(flutter_view) << ','
       << "\"hostVisible\":" << (host && IsWindowVisible(host) ? "true" : "false")
       << ',' << "\"viewVisible\":"
       << (flutter_view && IsWindowVisible(flutter_view) ? "true" : "false")
       << ',' << "\"hostCloaked\":" << host_cloaked << ','
       << "\"viewCloaked\":" << view_cloaked << ','
       << "\"parent\":" << reinterpret_cast<uintptr_t>(parent) << ','
       << "\"taskbar\":" << reinterpret_cast<uintptr_t>(taskbar) << ','
       << "\"style\":" << static_cast<long long>(style) << ','
       << "\"exStyle\":" << static_cast<long long>(ex_style) << ','
       << "\"windowRect\":[" << (has_window_rect ? window_rect.left : 0)
       << ',' << (has_window_rect ? window_rect.top : 0) << ','
       << (has_window_rect ? window_rect.right : 0) << ','
       << (has_window_rect ? window_rect.bottom : 0) << "],"
       << "\"taskbarClient\":["
       << (has_taskbar_client ? taskbar_client.left : 0) << ','
       << (has_taskbar_client ? taskbar_client.top : 0) << ','
       << (has_taskbar_client ? taskbar_client.right : 0) << ','
       << (has_taskbar_client ? taskbar_client.bottom : 0) << "]}}";
  const std::string body = data.str();

  HINTERNET session = WinHttpOpen(L"MusicHub taskbar lyrics probe/1.0",
                                  WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                  WINHTTP_NO_PROXY_NAME,
                                  WINHTTP_NO_PROXY_BYPASS, 0);
  if (!session) return;
  HINTERNET connection = WinHttpConnect(session, kDebugHost, kDebugPort, 0);
  if (!connection) {
    WinHttpCloseHandle(session);
    return;
  }
  HINTERNET request = WinHttpOpenRequest(connection, L"POST", kDebugPath,
                                         nullptr, WINHTTP_NO_REFERER,
                                         WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
  if (request) {
    const wchar_t headers[] = L"Content-Type: application/json\r\n";
    WinHttpSendRequest(request, headers, static_cast<DWORD>(-1L),
                       const_cast<char*>(body.data()),
                       static_cast<DWORD>(body.size()),
                       static_cast<DWORD>(body.size()), 0);
    WinHttpReceiveResponse(request, nullptr);
    WinHttpCloseHandle(request);
  }
  WinHttpCloseHandle(connection);
  WinHttpCloseHandle(session);
}

class TaskbarLyricsPlugin : public flutter::Plugin {
 public:
  explicit TaskbarLyricsPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<>>(
        registrar_->messenger(), "musichub/taskbar_lyrics",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<>& call,
               std::unique_ptr<flutter::MethodResult<>> result) {
          if (call.method_name() == "attach") {
            std::string error;
            const bool success = Attach(&error);
            ReportResult("attach", success, error, host_window_, FlutterView(),
                         FindTaskbar());
            result->Success(Status(error));
          } else if (call.method_name() == "detach") {
            std::string error;
            const bool success = Detach(&error);
            ReportResult("detach", success, error, host_window_, FlutterView(),
                         FindTaskbar());
            result->Success(Status(error));
          } else if (call.method_name() == "status") {
            result->Success(Status(""));
          } else {
            result->NotImplemented();
          }
        });
  }

 private:
  HWND FlutterView() const {
    return registrar_->GetView() ? registrar_->GetView()->GetNativeWindow()
                                 : nullptr;
  }

  HWND FindTaskbar() const { return FindWindowW(L"Shell_TrayWnd", nullptr); }

  bool SetWindowStyle(HWND window, int index, LONG_PTR value,
                      std::string* error) {
    if (GetWindowLongPtrW(window, index) == value) {
      return true;
    }
    SetLastError(ERROR_SUCCESS);
    const LONG_PTR previous = SetWindowLongPtrW(window, index, value);
    const DWORD last_error = GetLastError();
    if (previous == 0 && last_error != ERROR_SUCCESS) {
      *error = "SetWindowLongPtr failed: " + std::to_string(last_error);
      return false;
    }
    return true;
  }

  bool RestoreWindow(std::string* error) {
    if (!flutter_view_ || !IsWindow(flutter_view_) || !has_original_state_) {
      return true;
    }

    SetLastError(ERROR_SUCCESS);
    const HWND previous_parent = SetParent(flutter_view_, original_parent_);
    const DWORD parent_error = GetLastError();
    if (!previous_parent && parent_error != ERROR_SUCCESS) {
      *error = "SetParent restore failed: " + std::to_string(parent_error);
      return false;
    }
    if (!SetWindowStyle(flutter_view_, GWL_STYLE, original_style_, error) ||
        !SetWindowStyle(flutter_view_, GWL_EXSTYLE, original_ex_style_, error)) {
      return false;
    }
    const int width = original_rect_.right - original_rect_.left;
    const int height = original_rect_.bottom - original_rect_.top;
    if (!SetWindowPos(flutter_view_, nullptr, original_rect_.left,
                      original_rect_.top, width, height,
                      SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW |
                          SWP_FRAMECHANGED)) {
      *error = "SetWindowPos restore failed: " +
               std::to_string(GetLastError());
      return false;
    }
    if (host_window_ && IsWindow(host_window_)) {
      ShowWindow(host_window_, SW_SHOWNA);
    }
    return true;
  }

  bool Attach(std::string* error) {
    const HWND window = FlutterView();
    if (!window || !IsWindow(window)) {
      *error = "Flutter view not found";
      return false;
    }

    const HWND taskbar = FindTaskbar();
    if (!taskbar) {
      *error = "Shell_TrayWnd not found";
      return false;
    }
    RECT taskbar_client{};
    if (!GetClientRect(taskbar, &taskbar_client)) {
      *error = "GetClientRect failed: " + std::to_string(GetLastError());
      return false;
    }
    const int taskbar_height = taskbar_client.bottom - taskbar_client.top;
    if (taskbar_height <= 0) {
      *error = "invalid taskbar height";
      return false;
    }

    flutter_view_ = window;
    if (!has_original_state_) {
      original_parent_ = GetParent(window);
      host_window_ = original_parent_;
      original_style_ = GetWindowLongPtrW(window, GWL_STYLE);
      original_ex_style_ = GetWindowLongPtrW(window, GWL_EXSTYLE);
      if (!GetWindowRect(window, &original_rect_)) {
        *error = "GetWindowRect failed: " + std::to_string(GetLastError());
        return false;
      }
      MapWindowPoints(HWND_DESKTOP, original_parent_,
                      reinterpret_cast<POINT*>(&original_rect_), 2);
      has_original_state_ = true;
    }

    const LONG_PTR child_style =
        (original_style_ | WS_CHILD) &
        ~(static_cast<LONG_PTR>(WS_POPUP) | WS_CAPTION | WS_THICKFRAME);
    if (!SetWindowStyle(window, GWL_STYLE, child_style, error) ||
        !SetWindowStyle(window, GWL_EXSTYLE,
                        original_ex_style_ & ~WS_EX_TOPMOST, error)) {
      std::string restore_error;
      RestoreWindow(&restore_error);
      if (!restore_error.empty()) *error += "; " + restore_error;
      return false;
    }

    SetLastError(ERROR_SUCCESS);
    const HWND previous_parent = SetParent(window, taskbar);
    const DWORD parent_error = GetLastError();
    if (!previous_parent && parent_error != ERROR_SUCCESS) {
      *error = "SetParent failed: " + std::to_string(parent_error);
      std::string restore_error;
      RestoreWindow(&restore_error);
      if (!restore_error.empty()) *error += "; " + restore_error;
      return false;
    }

    if (host_window_ && IsWindow(host_window_)) {
      ShowWindow(host_window_, SW_HIDE);
    }
    if (!SetWindowPos(window, HWND_TOP, kLyricsOffsetX, 0, kLyricsWidth,
                      taskbar_height, SWP_NOACTIVATE | SWP_SHOWWINDOW |
                          SWP_FRAMECHANGED)) {
      *error = "SetWindowPos after SetParent failed: " +
               std::to_string(GetLastError());
      std::string restore_error;
      RestoreWindow(&restore_error);
      if (!restore_error.empty()) *error += "; " + restore_error;
      return false;
    }
    return true;
  }

  bool Detach(std::string* error) { return RestoreWindow(error); }

  EncodableValue Status(const std::string& error) const {
    const HWND taskbar = FindTaskbar();
    const bool attached = flutter_view_ && IsWindow(flutter_view_) && taskbar &&
                          GetParent(flutter_view_) == taskbar &&
                          (GetWindowLongPtrW(flutter_view_, GWL_STYLE) &
                           WS_CHILD) != 0;
    EncodableMap status;
    status[EncodableValue("attached")] = EncodableValue(attached);
    status[EncodableValue("error")] = EncodableValue(error);
    status[EncodableValue("window")] = EncodableValue(static_cast<int64_t>(
        reinterpret_cast<intptr_t>(flutter_view_)));
    status[EncodableValue("taskbar")] = EncodableValue(static_cast<int64_t>(
        reinterpret_cast<intptr_t>(taskbar)));
    return EncodableValue(status);
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<>> channel_;
  HWND flutter_view_ = nullptr;
  HWND host_window_ = nullptr;
  HWND original_parent_ = nullptr;
  LONG_PTR original_style_ = 0;
  LONG_PTR original_ex_style_ = 0;
  RECT original_rect_{};
  bool has_original_state_ = false;
};

}  // namespace

void RegisterTaskbarLyricsPlugin(FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows_registrar->AddPlugin(
      std::make_unique<TaskbarLyricsPlugin>(windows_registrar));
}
