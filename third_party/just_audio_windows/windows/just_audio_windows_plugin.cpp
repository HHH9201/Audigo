#pragma comment(lib, "windowsapp")

#include "include/just_audio_windows/just_audio_windows_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <sstream>

#include "player.hpp"

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

// static std::unordered_map<std::string, AudioPlayer> players;
std::vector<std::unique_ptr<AudioPlayer>> players_;

class JustAudioWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  JustAudioWindowsPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~JustAudioWindowsPlugin();

  void PostToPlatformThread(std::function<void()> task);

  std::optional<LRESULT> HandleWindowMessage(UINT message, WPARAM wparam,
                                              LPARAM lparam);

 private:
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
      flutter::BinaryMessenger* messenger);
  // Loops through cameras and returns camera
  // with matching camera_id or nullptr.
  AudioPlayer* GetPlayerByPlayerId(std::string id);

  // Disposes camera by camera id.
  void DisposePlayerByPlayerId(std::string id);

  flutter::PluginRegistrarWindows* registrar_;
  HWND window_;
  int window_proc_delegate_id_;
  static constexpr UINT kRunTaskMessage = WM_APP + 0x4A57;
};

// static
void JustAudioWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.ryanheise.just_audio.methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<JustAudioWindowsPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get(), messenger_pointer = registrar->messenger()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result), std::move(messenger_pointer));
      });

  registrar->AddPlugin(std::move(plugin));
}

JustAudioWindowsPlugin::JustAudioWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar), window_(nullptr), window_proc_delegate_id_(0) {
  window_proc_delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
          -> std::optional<LRESULT> {
        return HandleWindowMessage(message, wparam, lparam);
      });
}

JustAudioWindowsPlugin::~JustAudioWindowsPlugin() {
  if (window_proc_delegate_id_ != 0) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_id_);
  }
}

void JustAudioWindowsPlugin::PostToPlatformThread(std::function<void()> task) {
  auto* task_ptr = new std::function<void()>(std::move(task));
  if (window_ == nullptr) {
    auto* view = registrar_->GetView();
    if (view == nullptr) {
      delete task_ptr;
      return;
    }
    window_ = view->GetNativeWindow();
  }
  if (!PostMessage(window_, kRunTaskMessage, 0,
                   reinterpret_cast<LPARAM>(task_ptr))) {
    delete task_ptr;
  }
}

std::optional<LRESULT> JustAudioWindowsPlugin::HandleWindowMessage(
    UINT message, WPARAM, LPARAM lparam) {
  if (message != kRunTaskMessage) return std::nullopt;
  auto* task = reinterpret_cast<std::function<void()>*>(lparam);
  (*task)();
  delete task;
  return 0;
}

void JustAudioWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    flutter::BinaryMessenger* messenger) {
  const auto* args =std::get_if<flutter::EncodableMap>(method_call.arguments());
  if (args) {
    if (method_call.method_name().compare("init") == 0) {
      const auto* id = std::get_if<std::string>(ValueOrNull(*args, "id"));
      if (!id) {
        return result->Error("argument_error", "id argument missing");
      }
      auto player = std::make_unique<AudioPlayer>(
          *id, messenger, [this](std::function<void()> task) {
            PostToPlatformThread(std::move(task));
          });
      players_.push_back(std::move(player));
      result->Success();
    } else if (method_call.method_name().compare("disposePlayer") == 0) {
      const auto* id = std::get_if<std::string>(ValueOrNull(*args, "id"));
      if (!id) {
        return result->Error("argument_error", "id argument missing");
      }
      DisposePlayerByPlayerId(*id);
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("disposeAllPlayers") == 0) {
      players_.clear();
      result->Success(flutter::EncodableMap());
    } else {
      result->NotImplemented();
    }
  } else {
    result->NotImplemented();
  }
}

AudioPlayer* JustAudioWindowsPlugin::GetPlayerByPlayerId(std::string id) {
  for (auto it = begin(players_); it != end(players_); ++it) {
    if ((*it)->HasPlayerId(id)) {
      return it->get();
    }
  }
  return nullptr;
}

void JustAudioWindowsPlugin::DisposePlayerByPlayerId(std::string id) {
  for (auto it = begin(players_); it != end(players_); ++it) {
    if ((*it)->HasPlayerId(id)) {
      players_.erase(it);
      return;
    }
  }
}

}  // namespace

void JustAudioWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  JustAudioWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
