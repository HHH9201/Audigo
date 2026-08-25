#pragma comment(lib, "windowsapp")

#include <algorithm>
#include <chrono>
#include <cmath>
#include <functional>
#include <memory>
#include <mutex>

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "uri_utils.hpp"

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Audio.h>
#include <winrt/Windows.Media.Core.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.System.h>
#define TO_MILLISECONDS(timespan) timespan.count() / 10000
#define TO_MICROSECONDS(timespan) TO_MILLISECONDS(timespan) * 1000

using flutter::EncodableMap;
using flutter::EncodableValue;

using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Media;

using winrt::Windows::Media::Core::MediaSource;

// Looks for |key| in |map|, returning the associated value if it is present, or
// a nullptr if not.
//
// The variant types are mapped with Dart types in following ways:
// std::monostate       -> null
// bool                 -> bool
// int32_t              -> int
// int64_t              -> int
// double               -> double
// std::string          -> String
// std::vector<uint8_t> -> Uint8List
// std::vector<int32_t> -> Int32List
// std::vector<int64_t> -> Int64List
// std::vector<float>   -> Float32List
// std::vector<double>  -> Float64List
// EncodableList        -> List
// EncodableMap         -> Map
const EncodableValue* ValueOrNull(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return &(it->second);
}

// Converts a std::string to std::wstring
auto TO_WIDESTRING = [](std::string string) -> std::wstring {
  if (string.empty()) {
    return std::wstring();
  }
  int32_t target_length =
    ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, string.data(),
      static_cast<int32_t>(string.length()), nullptr, 0);
  if (target_length == 0) {
    return std::wstring();
  }
  std::wstring utf16_string;
  utf16_string.resize(target_length);
  int32_t converted_length =
    ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, string.data(),
      static_cast<int32_t>(string.length()),
      utf16_string.data(), target_length);
  if (converted_length == 0) {
    return std::wstring();
  }
  return utf16_string;
};


class JustAudioEventSink {
public:
  // Prevent copying.
  JustAudioEventSink(JustAudioEventSink const&) = delete;
  JustAudioEventSink& operator=(JustAudioEventSink const&) = delete;

  JustAudioEventSink::JustAudioEventSink(flutter::BinaryMessenger* messenger, const std::string& id) {
    auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(messenger, id, &flutter::StandardMethodCodec::GetInstance());

    auto event_handler = std::make_unique<flutter::StreamHandlerFunctions<>>(
      [self = this](const EncodableValue* arguments, std::unique_ptr<flutter::EventSink<>>&& events) -> std::unique_ptr<flutter::StreamHandlerError<>> {
      self->sink = std::move(events);
      return nullptr;
    }, [self = this](const EncodableValue* arguments) -> std::unique_ptr<flutter::StreamHandlerError<>> {
      self->sink.reset();
      return nullptr;
    });

    event_channel->SetStreamHandler(std::move(event_handler));
  }

  void Success(const EncodableValue& event) {
    if (sink) {
      sink->Success(event);
    }
  }

  void Error(const std::string& error_code,
    const std::string& error_message) {
    if (sink) {
      sink->Error(error_code, error_message);
    }
  }
private:
  std::unique_ptr<flutter::EventSink<>> sink = nullptr;
};

class AudioPlayer {
private:
  struct CallbackState {
    std::mutex mutex;
    AudioPlayer* player = nullptr;
  };

  bool disposed_ = false;
  bool source_assigned_ = false;
  bool pending_play_ = false;
  std::function<void(std::function<void()>)> post_to_platform_thread_;
  std::shared_ptr<CallbackState> callback_state_ =
    std::make_shared<CallbackState>();

  void Dispose() {
    if (disposed_) return;
    disposed_ = true;
    {
      std::lock_guard<std::mutex> lock(callback_state_->mutex);
      callback_state_->player = nullptr;
    }
    auto session = mediaPlayer.PlaybackSession();
    session.PlaybackStateChanged(playback_state_token_);
    mediaPlayer.MediaOpened(media_opened_token_);
    mediaPlayer.MediaFailed(media_failed_token_);
    mediaPlaybackList.CurrentItemChanged(item_changed_token_);
    mediaPlaybackList.ItemFailed(item_failed_token_);
    player_channel_->SetMethodCallHandler(nullptr);
    event_sink_.reset();
    data_sink_.reset();
    mediaPlayer.Close();
  }
public:
  std::string id;
  Playback::MediaPlayer mediaPlayer{};
  Playback::MediaPlaybackList mediaPlaybackList{};

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> player_channel_;
  std::unique_ptr<JustAudioEventSink> event_sink_ = nullptr;
  std::unique_ptr<JustAudioEventSink> data_sink_ = nullptr;

  // Tokens for event unsubscription
  winrt::event_token playback_state_token_{};
  winrt::event_token media_opened_token_{};
  winrt::event_token media_failed_token_{};
  winrt::event_token item_changed_token_{};
  winrt::event_token item_failed_token_{};

public:
  AudioPlayer::AudioPlayer(
    std::string idx,
    flutter::BinaryMessenger* messenger,
    std::function<void(std::function<void()>)> post_to_platform_thread)
    : post_to_platform_thread_(std::move(post_to_platform_thread)) {
    id = idx;
    callback_state_->player = this;

    // Set up channels
    player_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "com.ryanheise.just_audio.methods." + idx,
        &flutter::StandardMethodCodec::GetInstance()
        );

    player_channel_->SetMethodCallHandler(
      [player = this](const auto& call, auto result) {
      player->HandleMethodCall(call, std::move(result));
    });

    event_sink_ = std::make_unique<JustAudioEventSink>(messenger, "com.ryanheise.just_audio.events." + idx);
    data_sink_ = std::make_unique<JustAudioEventSink>(messenger, "com.ryanheise.just_audio.data." + idx);

    /// Set up event callbacks
    // Playback event
    std::weak_ptr<CallbackState> weak_state = callback_state_;
    playback_state_token_ = mediaPlayer.PlaybackSession().PlaybackStateChanged(
      [weak_state, post = post_to_platform_thread_](auto, const auto&) {
        post([weak_state]() {
          auto state = weak_state.lock();
          if (!state) return;
          std::lock_guard<std::mutex> lock(state->mutex);
          if (state->player) state->player->broadcastState();
        });
      });

    media_opened_token_ = mediaPlayer.MediaOpened(
      [weak_state, post = post_to_platform_thread_](auto, const auto&) {
        post([weak_state]() {
          auto state = weak_state.lock();
          if (!state) return;
          std::lock_guard<std::mutex> lock(state->mutex);
          if (!state->player) return;
          state->player->broadcastState();
          if (state->player->pending_play_) {
            state->player->pending_play_ = false;
            state->player->mediaPlayer.Play();
          }
        });
      });

    // Player error event
    media_failed_token_ = mediaPlayer.MediaFailed(
      [weak_state, post = post_to_platform_thread_](
        auto, const Playback::MediaPlayerFailedEventArgs& args) {
        std::string error_message = winrt::to_string(args.ErrorMessage());
        auto error = args.Error();
        post([weak_state, error, error_message = std::move(error_message)]() {
          auto state = weak_state.lock();
          if (!state) return;
          std::lock_guard<std::mutex> lock(state->mutex);
          if (state->player) state->player->BroadcastMediaError(error, error_message);
        });
      });

    mediaPlaybackList.MaxPlayedItemsToKeepOpen(2);
    item_changed_token_ = mediaPlaybackList.CurrentItemChanged(
      [weak_state, post = post_to_platform_thread_](auto, const auto&) {
        post([weak_state]() {
          auto state = weak_state.lock();
          if (!state) return;
          std::lock_guard<std::mutex> lock(state->mutex);
          if (state->player) state->player->broadcastState();
        });
      });
    item_failed_token_ = mediaPlaybackList.ItemFailed(
      [weak_state, post = post_to_platform_thread_](
        auto, const Playback::MediaPlaybackItemFailedEventArgs& args) {
        auto item_error = args.Error();
        auto error = winrt::hresult_error(item_error.ExtendedError());
        auto message = winrt::to_string(error.message());
        auto code = item_error.ErrorCode();
        post([weak_state, code, message = std::move(message)]() {
          auto state = weak_state.lock();
          if (!state) return;
          std::lock_guard<std::mutex> lock(state->mutex);
          if (state->player) state->player->BroadcastItemError(code, message);
        });
      });
  }

  AudioPlayer::~AudioPlayer() {
    Dispose();
  }

  bool HasPlayerId(std::string playerId) {
    return id == playerId;
  }

  void AudioPlayer::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result
  ) {
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());

    std::cerr << "[just_audio_windows] Called " << method_call.method_name() << std::endl;

    if (method_call.method_name().compare("load") == 0) {
      const auto* audioSourceData = std::get_if<flutter::EncodableMap>(ValueOrNull(*args, "audioSource"));
      const auto* initialPosition = std::get_if<int>(ValueOrNull(*args, "initialPosition"));
      const auto* initialIndex = std::get_if<int>(ValueOrNull(*args, "initialIndex"));

      try {
        loadSource(*audioSourceData);
      } catch (char* error) {
        return result->Error("load_error", error);
      }

      if (initialIndex != nullptr) {
        seekToItem((uint32_t)*initialIndex);
      }

      if (initialPosition != nullptr) {
        seekToPosition(*initialPosition);
      }

      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("play") == 0) {
      if (!disposed_) {
        if (source_assigned_) {
          mediaPlayer.Play();
        } else {
          pending_play_ = true;
        }
      }
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("pause") == 0) {
      if (!disposed_) {
        mediaPlayer.Pause();
      }
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setVolume") == 0) {
      const auto* volume = std::get_if<double>(ValueOrNull(*args, "volume"));
      if (!volume) {
        return result->Error("volume_error", "volume argument missing");
      }
      float volumeFloat = (float)*volume;
      if (!disposed_) {
        mediaPlayer.Volume(volumeFloat);
      }
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setSpeed") == 0) {
      const auto* speed = std::get_if<double>(ValueOrNull(*args, "speed"));
      if (!speed) {
        return result->Error("speed_error", "speed argument missing");
      }
      float speedFloat = (float)*speed;
      if (!disposed_) {
        mediaPlayer.PlaybackRate(speedFloat);
      }
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setPitch") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setSkipSilence") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setLoopMode") == 0) {
      const auto* loopModePtr = std::get_if<int32_t>(ValueOrNull(*args, "loopMode"));
      if (loopModePtr == nullptr) {
        return result->Error("loopMode_error", "loopMode argument missing");
      }

      if (!disposed_) {
        switch (*loopModePtr) {
        case 0: // off
          mediaPlayer.IsLoopingEnabled(false);
          mediaPlaybackList.AutoRepeatEnabled(false);
          break;
        case 1: // one
          mediaPlayer.IsLoopingEnabled(true);
          mediaPlaybackList.AutoRepeatEnabled(false);
          break;
        case 2: // all
          mediaPlayer.IsLoopingEnabled(false);
          mediaPlaybackList.AutoRepeatEnabled(true);
          break;
        default:
          return result->Error("loopMode_error", "loopMode is invalid");
        }
      }  
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setShuffleMode") == 0) {
      const auto* shuffleModePtr = std::get_if<int32_t>(ValueOrNull(*args, "shuffleMode"));
      if (shuffleModePtr == nullptr) {
        return result->Error("shuffleMode_error", "shuffleMode argument missing");
      }

      switch (*shuffleModePtr) {
      case 0: // none
        mediaPlaybackList.ShuffleEnabled(false);
        break;
      case 1: // all
        mediaPlaybackList.ShuffleEnabled(true);
        break;
      default:
        return result->Error("shuffleMode_error", "shuffleMode is invalid");
      }

      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setShuffleOrder") == 0) {
      const auto* source = std::get_if<flutter::EncodableMap>(ValueOrNull(*args, "audioSource"));

      setShuffleOrder(*source);

      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setAutomaticallyWaitsToMinimizeStalling") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setCanUseNetworkResourcesForLiveStreamingWhilePaused") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setPreferredPeakBitRate") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("seek") == 0) {
      const auto* index = std::get_if<int>(ValueOrNull(*args, "index"));
      if (index != nullptr) {
        seekToItem((uint32_t)*index);
      }

      const auto* position = ValueOrNull(*args, "position");

      if (position != nullptr && !position->IsNull()) {
        seekToPosition((*position).LongValue());
      }
      
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("concatenatingInsertAll") == 0) {
      const auto* index = std::get_if<int>(ValueOrNull(*args, "index"));
      const auto* children = std::get_if<flutter::EncodableList>(ValueOrNull(*args, "children"));

      auto items = mediaPlaybackList.Items();

      int currentIndex = *index;
      for (auto& child : *children) {
        const auto* childMap = std::get_if<flutter::EncodableMap>(&child);
        auto mediaSource = createMediaPlaybackItem(*childMap);
        auto item = Playback::MediaPlaybackItem(mediaSource);

        items.InsertAt(currentIndex, item);
        currentIndex++;
      }

      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("concatenatingRemoveRange") == 0) {
      const auto* start = std::get_if<int>(ValueOrNull(*args, "startIndex"));
      const auto* end = std::get_if<int>(ValueOrNull(*args, "endIndex")); // Does not include this item

      int startIndex = *start;
      int endIndex = *end;

      auto items = mediaPlaybackList.Items();
      auto size = (int) items.Size();

      if (endIndex > startIndex && startIndex >= 0 && endIndex <= size) {
        int count = endIndex - startIndex;

        for (int i = 0; i < count; i++) {
          // The item to remove should always be located at `startIndex`.
          items.RemoveAt(startIndex);
        }
        return result->Success(flutter::EncodableMap());
      } else {
        return result->Error("concatenatingRemoveRange_error", "invalid range");
      }
    } else if (method_call.method_name().compare("concatenatingMove") == 0) {
      const auto* from = std::get_if<int>(ValueOrNull(*args, "currentIndex"));
      const auto* to = std::get_if<int>(ValueOrNull(*args, "newIndex"));

      auto items = mediaPlaybackList.Items();
      auto size = (int) items.Size();

      int currentIndex = *from;
      int newIndex = *to;

      auto item = items.GetAt(currentIndex);

      if (currentIndex >= size || newIndex > size) {
        return result->Error("concatenatingMove_error", "index out of bounds");
      }

      items.RemoveAt(currentIndex);
      items.InsertAt(newIndex, item);
      // Do nothing if the two equals
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setAndroidAudioAttributes") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("audioEffectSetEnabled") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("androidLoudnessEnhancerSetTargetGain") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("androidEqualizerGetParameters") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("androidEqualizerBandSetGain") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("dispose") == 0) {
      Dispose();
      result->Success(flutter::EncodableMap());
    } else {
      result->NotImplemented();
    }
  }

  void AudioPlayer::loadSource(const flutter::EncodableMap& source) {
    if(disposed_) return;
    source_assigned_ = false;
    auto items = mediaPlaybackList.Items();
    items.Clear(); // Always clear the list since we are resetting

    const std::string* type = std::get_if<std::string>(ValueOrNull(source, "type"));

    if (type->compare("concatenating") == 0) {
      const auto* children = std::get_if<flutter::EncodableList>(ValueOrNull(source, "children"));

      for (auto& child : *children) {
        const auto* childMap = std::get_if<flutter::EncodableMap>(&child);
        auto item = createMediaPlaybackItem(*childMap);
        items.Append(item);
      }

      mediaPlayer.Source(mediaPlaybackList.as<Playback::IMediaPlaybackSource>());
    } else {
      mediaPlayer.Source(createMediaPlaybackItem(source).as<Playback::IMediaPlaybackSource>());
    }
    source_assigned_ = true;
    if (pending_play_) {
      pending_play_ = false;
      mediaPlayer.Play();
    }
  }

  /**
  * Creates a single MediaPlaybackItem, which can be used directly or inside a list.
  */
  Playback::MediaPlaybackItem AudioPlayer::createMediaPlaybackItem(const flutter::EncodableMap& source) const& {
    const std::string* type = std::get_if<std::string>(ValueOrNull(source, "type"));

    if (type->compare("clipping") == 0) {
      const auto* child = std::get_if<flutter::EncodableMap>(ValueOrNull(source, "child"));
      auto childSource = createMediaSource(*child);

      const auto* startUs = std::get_if<int32_t>(ValueOrNull(*child, "start"));
      const auto* endUs = std::get_if<int32_t>(ValueOrNull(*child, "end"));

      auto start = 0; // Default to 0
      if (startUs != nullptr) {
        start = *startUs;
      }

      if (endUs != nullptr) {
        // We have a duration limit
        auto duration = *endUs - start;

        return Playback::MediaPlaybackItem(
          childSource,
          TimeSpan(std::chrono::microseconds(start)),
          TimeSpan(std::chrono::microseconds(duration))
        );
      } else {
        return Playback::MediaPlaybackItem(
          childSource,
          TimeSpan(std::chrono::microseconds(start))
        );
      }
    } else {
      return Playback::MediaPlaybackItem(createMediaSource(source));
    }
  }

  /**
  * Creates a single MediaSource.
  */
  MediaSource AudioPlayer::createMediaSource(const flutter::EncodableMap& source) const {
      const std::string* type = std::get_if<std::string>(ValueOrNull(source, "type"));
      if (type->compare("progressive") == 0 || type->compare("dash") == 0 || type->compare("hls") == 0) {
          const auto* uri = std::get_if<std::string>(ValueOrNull(source, "uri"));
          return MediaSource::CreateFromUri(
              Uri(TO_WIDESTRING(EncodeSpacesInUri(*uri)))
          );
      }
      else {
          throw std::invalid_argument("Source is unsupported or can not be nested: " + *type);
      }
  }


  void AudioPlayer::BroadcastMediaError(
    Playback::MediaPlayerError error,
    const std::string& message) {
    std::cerr << "[just_audio_windows] Media error: " << message << std::endl;
    auto code = "unknown";
    switch (error) {
    case Playback::MediaPlayerError::Unknown:
      break;
    case Playback::MediaPlayerError::Aborted:
      code = "aborted";
      break;
    case Playback::MediaPlayerError::NetworkError:
      code = "networkError";
      break;
    case Playback::MediaPlayerError::DecodingError:
      code = "decodingError";
      break;
    case Playback::MediaPlayerError::SourceNotSupported:
      code = "sourceNotSupported";
      break;
    }
    if (event_sink_) event_sink_->Error(code, message);
  }

  void AudioPlayer::BroadcastItemError(
    Playback::MediaPlaybackItemErrorCode error,
    const std::string& message) {
    std::cerr << "[just_audio_windows] Item error: " << message << std::endl;
    auto code = "unknown";
    switch (error) {
    case Playback::MediaPlaybackItemErrorCode::Aborted:
      code = "aborted";
      break;
    case Playback::MediaPlaybackItemErrorCode::NetworkError:
      code = "networkError";
      break;
    case Playback::MediaPlaybackItemErrorCode::DecodeError:
      code = "decodeError";
      break;
    case Playback::MediaPlaybackItemErrorCode::SourceNotSupportedError:
      code = "sourceNotSupportedError";
      break;
    case Playback::MediaPlaybackItemErrorCode::EncryptionError:
      code = "encryptionError";
      break;
    }
    if (event_sink_) event_sink_->Error(code, message);
  }

  void AudioPlayer::broadcastState() {
    try {
      broadcastPlaybackEvent();
    } catch (winrt::hresult_error const& ex) {
      std::cerr << "[just_audio_windows] Broadcast event error: " << winrt::to_string(ex.message()) << std::endl;
    }

    try {
      broadcastDataEvent();
    } catch (winrt::hresult_error const& ex) {
      std::cerr << "[just_audio_windows] Broadcast data error: " << winrt::to_string(ex.message()) << std::endl;
    }
  }

  void AudioPlayer::broadcastPlaybackEvent() {
    if(disposed_) return;
    auto session = mediaPlayer.PlaybackSession();

    auto eventData = flutter::EncodableMap();

    auto duration = TO_MICROSECONDS(session.NaturalDuration());
    auto position = TO_MICROSECONDS(session.Position());

    auto now = std::chrono::system_clock::now();

    double bufferingProgress = 0.0;
    try {
      bufferingProgress = session.BufferingProgress();
      if (!std::isfinite(bufferingProgress)) bufferingProgress = 0.0;
      bufferingProgress = std::clamp(bufferingProgress, 0.0, 1.0);
    } catch (const winrt::hresult_error& ex) {
      std::cerr << "[just_audio_windows] Error accessing BufferingProgress: "
                << winrt::to_string(ex.message()) << std::endl;
    }
    auto bufferedPosition = (std::max)(
      static_cast<int64_t>(position),
      static_cast<int64_t>(duration * bufferingProgress));
    if (duration > 0) bufferedPosition = (std::min)(bufferedPosition, duration);

    eventData[flutter::EncodableValue("processingState")] = flutter::EncodableValue(processingState(session.PlaybackState()));
    eventData[flutter::EncodableValue("updatePosition")] = flutter::EncodableValue(position); //int
    eventData[flutter::EncodableValue("updateTime")] = flutter::EncodableValue(TO_MILLISECONDS(now.time_since_epoch())); //int
    eventData[flutter::EncodableValue("bufferedPosition")] = flutter::EncodableValue(bufferedPosition); //int
    eventData[flutter::EncodableValue("duration")] = flutter::EncodableValue(duration); //int

    if (mediaPlaybackList.Items().Size() > 0) {
      int64_t currentIndex = mediaPlaybackList.CurrentItemIndex();
      if (currentIndex != 4294967295) { // UINT32_MAX - 1
        eventData[flutter::EncodableValue("currentIndex")] = flutter::EncodableValue(currentIndex); //int
      }
    } else {
      eventData[flutter::EncodableValue("currentIndex")] = flutter::EncodableValue(0); //int
    }

    event_sink_->Success(eventData);
  }

  int AudioPlayer::processingState(Playback::MediaPlaybackState state) {
    if(disposed_) return 0;
    auto session = mediaPlayer.PlaybackSession();

    if (state == Playback::MediaPlaybackState::None) {
      return 0; //idle
    } else if (state == Playback::MediaPlaybackState::Opening) {
      return 1; //loading
    } else if (state == Playback::MediaPlaybackState::Buffering) {
      return 2;//buffering
    } else if (session.Position().count() == session.NaturalDuration().count()) {
      return 4; //completed
    }
    return 3; //ready
  }

  void AudioPlayer::broadcastDataEvent() {
    if(disposed_) return;
    auto session = mediaPlayer.PlaybackSession();
    auto eventData = flutter::EncodableMap();

    auto isPlaying = session.PlaybackState() == Playback::MediaPlaybackState::Playing;

    eventData[flutter::EncodableValue("playing")] = flutter::EncodableValue(isPlaying);
    eventData[flutter::EncodableValue("volume")] = flutter::EncodableValue(mediaPlayer.Volume());
    eventData[flutter::EncodableValue("speed")] = flutter::EncodableValue(session.PlaybackRate());
    eventData[flutter::EncodableValue("loopMode")] = flutter::EncodableValue(getLoopMode());
    eventData[flutter::EncodableValue("shuffleMode")] = flutter::EncodableValue(getShuffleMode());

    data_sink_->Success(eventData);
  }

  int AudioPlayer::getLoopMode() {
    if (mediaPlayer.IsLoopingEnabled()) {
      // one
      return 1;
    } else if (mediaPlaybackList.AutoRepeatEnabled()) {
      // all
      return 2;
    } else {
      // pff
      return 0;
    }
  }

  int AudioPlayer::getShuffleMode() {
    // TODO(bdlukaa): playlists
    return 0;
  }

  flutter::EncodableMap AudioPlayer::collectIcyMetadata() {
    auto icyData = flutter::EncodableMap();

    // TODO: Icy Metadata
    // mediaPlayer.PlaybackMediaMarkers();

    return icyData;
  }

  /// Transforms a num into positive, if negative
  int negativeToPositive(int num) {
    if (num < 0) { return num * (-1); }
    return num;
  }

  void AudioPlayer::seekToItem(uint32_t index) {
    if (index >= mediaPlaybackList.Items().Size()) {
      return;
    }

    try {
      mediaPlaybackList.MoveTo(index);
    } catch (winrt::hresult_error const& ex) {
      std::cerr << "[just_audio_windows] Failed to seek to item: " << winrt::to_string(ex.message()) << std::endl;
    }

    broadcastState();
  }

  void AudioPlayer::seekToPosition(int64_t microseconds) {
    if(disposed_) return;
    mediaPlayer.Position(TimeSpan(std::chrono::microseconds(microseconds)));

    broadcastState();
  }

  void AudioPlayer::setShuffleOrder(const flutter::EncodableMap& source) {
    const std::string* type = std::get_if<std::string>(ValueOrNull(source, "type"));
    // const std::string* id = std::get_if<std::string>(ValueOrNull(source, "id"));

    if (type->compare("concatenating") == 0) {
      const auto* shuffleOrder = std::get_if<flutter::EncodableList>(ValueOrNull(source, "shuffleOrder"));

      // A copy of mediaPlaybackList.Items()
      std::vector<Playback::MediaPlaybackItem> itemsCopy {};
      for (auto item : mediaPlaybackList.Items()) {
        itemsCopy.push_back(item);
      }

      // then we apply the suffling to itemsCopy
      for (int i = 0; i < ((int) shuffleOrder->size()); i++) {
        auto item = itemsCopy.at(i);

        auto insertAt = (*shuffleOrder).at(i).LongValue();

        // delete the item at i
        itemsCopy.erase(itemsCopy.begin() + i);
        itemsCopy.insert(itemsCopy.begin() + insertAt, item);
      }

      // and finnaly provide it to the player list
      mediaPlaybackList.SetShuffledItems(itemsCopy);

      itemsCopy.clear();
      itemsCopy.shrink_to_fit();

      const auto* children = std::get_if<flutter::EncodableList>(ValueOrNull(source, "children"));
      for (auto child : *children) {
        setShuffleOrder(std::get<flutter::EncodableMap>(child));
      }
    } else if (type->compare("looping") == 0) {
      const flutter::EncodableMap* child = std::get_if<flutter::EncodableMap>(ValueOrNull(source, "child"));
      setShuffleOrder(*child);
    } else {
      // can not shuffle a single-audio media source
    }
  }

};
