#include "snap_layouts_button.h"

#include <windows.h>

#include <commctrl.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <cmath>
#include <cwchar>
#include <memory>
#include <optional>

namespace snap_layouts {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr UINT_PTR kViewSubclassId = 0x5A11;
constexpr UINT_PTR kRootSubclassId = 0x5A12;

// התשובות של `arm`, כפי ש-Dart קורא אותן.
constexpr int kArmUnsupported = -1;
constexpr int kArmRejected = 0;
constexpr int kArmAccepted = 1;

struct ArmedButton {
  int64_t token = 0;
  HWND root = nullptr;
  HWND view = nullptr;
  // פיקסלים פיזיים באזור-הלקוח של [view].
  RECT rect{};
  bool hovered = false;
  bool pressed = false;
};

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
std::optional<ArmedButton> g_armed;

bool IsWindows11OrGreater() {
#pragma warning(push)
#pragma warning(disable : 4996)
  const DWORD version = ::GetVersion();
#pragma warning(pop)
  const DWORD build = version < 0x80000000 ? HIWORD(version) : 0;
  return build >= 22000;
}

bool HasClass(HWND hwnd, const wchar_t* expected) {
  wchar_t name[32] = {};
  return ::GetClassNameW(hwnd, name, ARRAYSIZE(name)) > 0 &&
         wcscmp(name, expected) == 0;
}

void Notify(const char* method, const ArmedButton& button, bool armed) {
  if (!g_channel) return;
  EncodableMap args;
  args[EncodableValue("token")] = EncodableValue(button.token);
  args[EncodableValue("armed")] = EncodableValue(armed);
  args[EncodableValue("hovered")] = EncodableValue(button.hovered);
  args[EncodableValue("pressed")] = EncodableValue(button.pressed);
  g_channel->InvokeMethod(method, std::make_unique<EncodableValue>(args));
}

void Disarm(bool notify) {
  if (!g_armed) return;
  ArmedButton button = *g_armed;
  g_armed.reset();
  button.hovered = false;
  button.pressed = false;
  if (notify) Notify("state", button, false);
}

void SetVisualState(bool hovered, bool pressed) {
  if (!g_armed) return;
  if (g_armed->hovered == hovered && g_armed->pressed == pressed) return;
  g_armed->hovered = hovered;
  g_armed->pressed = pressed;
  Notify("state", *g_armed, true);
}

// הנקודה בקואורדינטות מסך, כמו בכל הודעת WM_NC*.
bool OverArmedButton(LPARAM screen_point) {
  if (!g_armed) return false;
  POINT pt{GET_X_LPARAM(screen_point), GET_Y_LPARAM(screen_point)};
  return ::ScreenToClient(g_armed->view, &pt) &&
         ::PtInRect(&g_armed->rect, pt);
}

LRESULT CALLBACK ViewProc(HWND hwnd, UINT message, WPARAM wparam,
                          LPARAM lparam, UINT_PTR, DWORD_PTR) {
  switch (message) {
    case WM_NCHITTEST:
      if (g_armed && g_armed->view == hwnd) {
        // מעביר את בדיקת הפגיעה לחלון העליון, שעונה HTMAXBUTTON.
        if (OverArmedButton(lparam)) return HTTRANSPARENT;
        Disarm(true);
      }
      break;
    case WM_NCDESTROY:
      if (g_armed && g_armed->view == hwnd) Disarm(false);
      ::RemoveWindowSubclass(hwnd, ViewProc, kViewSubclassId);
      break;
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK RootProc(HWND hwnd, UINT message, WPARAM wparam,
                          LPARAM lparam, UINT_PTR, DWORD_PTR) {
  const bool armed_here = g_armed && g_armed->root == hwnd;
  const bool on_button = armed_here && LOWORD(wparam) == HTMAXBUTTON;
  switch (message) {
    case WM_NCHITTEST:
      if (armed_here && OverArmedButton(lparam)) return HTMAXBUTTON;
      break;
    case WM_NCMOUSEMOVE:
      if (on_button) {
        TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE | TME_NONCLIENT, hwnd,
                              0};
        ::TrackMouseEvent(&track);
        SetVisualState(true, g_armed->pressed);
      } else if (armed_here) {
        Disarm(true);
      }
      // גם DefWindowProc מקבל את התזוזה: הריחוף שלו על HTMAXBUTTON פותח את התפריט.
      break;
    case WM_NCMOUSELEAVE:
      if (armed_here) Disarm(true);
      break;
    // DefWindowProc היה מריץ את לולאת כפתור הכותרת הקלאסי ומצייר מעל Flutter.
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK:
      if (on_button) {
        SetVisualState(true, true);
        return 0;
      }
      break;
    case WM_NCLBUTTONUP:
      if (on_button) {
        const bool was_pressed = g_armed->pressed;
        const ArmedButton button = *g_armed;
        // הקליק מזיז בדרך כלל את הכפתור; Dart דורך אותו מחדש בריחוף הבא.
        Disarm(true);
        if (was_pressed) Notify("click", button, false);
        return 0;
      }
      break;
    case WM_NCRBUTTONDOWN:
    case WM_NCRBUTTONUP:
    case WM_NCRBUTTONDBLCLK:
    case WM_NCMBUTTONDOWN:
    case WM_NCMBUTTONUP:
    case WM_NCMBUTTONDBLCLK:
    case WM_NCXBUTTONDOWN:
    case WM_NCXBUTTONUP:
    case WM_NCXBUTTONDBLCLK:
      if (on_button) return 0;
      break;
    case WM_NCDESTROY:
      if (armed_here) Disarm(false);
      ::RemoveWindowSubclass(hwnd, RootProc, kRootSubclassId);
      break;
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}

std::optional<double> NumberArg(const EncodableMap& args, const char* key) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return std::nullopt;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
  if (const auto* l = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*l);
  }
  return std::nullopt;
}

int Arm(const EncodableMap& args) {
  if (!IsWindows11OrGreater()) return kArmUnsupported;
  const auto token = NumberArg(args, "token");
  const auto left = NumberArg(args, "left");
  const auto top = NumberArg(args, "top");
  const auto right = NumberArg(args, "right");
  const auto bottom = NumberArg(args, "bottom");
  if (!token || !left || !top || !right || !bottom) return kArmRejected;

  // רק התצוגה שתחת הסמן: זה החלון שבו Flutter מצא עכשיו את הכפתור.
  POINT cursor{};
  if (!::GetCursorPos(&cursor)) return kArmRejected;
  const HWND view = ::WindowFromPoint(cursor);
  if (!view || !HasClass(view, L"FLUTTERVIEW") ||
      ::GetWindowThreadProcessId(view, nullptr) != ::GetCurrentThreadId()) {
    return kArmRejected;
  }
  const HWND root = ::GetAncestor(view, GA_ROOT);
  if (!root || root == view ||
      (::GetWindowLongPtrW(root, GWL_STYLE) & WS_MAXIMIZEBOX) == 0) {
    return kArmRejected;
  }

  const RECT rect{static_cast<LONG>(std::floor(*left)),
                  static_cast<LONG>(std::floor(*top)),
                  static_cast<LONG>(std::ceil(*right)),
                  static_cast<LONG>(std::ceil(*bottom))};
  POINT local = cursor;
  if (!::ScreenToClient(view, &local) || !::PtInRect(&rect, local)) {
    return kArmRejected;
  }

  const auto token_value = static_cast<int64_t>(*token);
  if (g_armed && g_armed->token == token_value && g_armed->view == view) {
    g_armed->rect = rect;
    return kArmAccepted;
  }
  Disarm(true);
  if (!::SetWindowSubclass(view, ViewProc, kViewSubclassId, 0) ||
      !::SetWindowSubclass(root, RootProc, kRootSubclassId, 0)) {
    return kArmRejected;
  }
  ArmedButton button;
  button.token = token_value;
  button.root = root;
  button.view = view;
  button.rect = rect;
  g_armed = button;
  return kArmAccepted;
}

}  // namespace

void Initialize(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "otzaria/snap_layouts",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto* args = std::get_if<EncodableMap>(call.arguments());
        if (call.method_name() == "arm") {
          result->Success(EncodableValue(args ? Arm(*args) : kArmRejected));
          return;
        }
        if (call.method_name() == "disarm") {
          const auto token = args ? NumberArg(*args, "token") : std::nullopt;
          if (token && g_armed &&
              g_armed->token == static_cast<int64_t>(*token)) {
            Disarm(false);
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
}

void Shutdown() {
  Disarm(false);
  g_channel.reset();
}

}  // namespace snap_layouts
