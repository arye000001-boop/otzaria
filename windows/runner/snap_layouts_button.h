#ifndef RUNNER_SNAP_LAYOUTS_BUTTON_H_
#define RUNNER_SNAP_LAYOUTS_BUTTON_H_

#include <flutter/binary_messenger.h>

// Snap Layouts של Windows 11 לכפתור ההגדלה ש-Flutter מצייר (#4021).
// Dart דורך את הכפתור בריחוף; עד שהסמן יוצא, Windows מקבל ממנו HTMAXBUTTON.
namespace snap_layouts {

void Initialize(flutter::BinaryMessenger* messenger);
void Shutdown();

}  // namespace snap_layouts

#endif  // RUNNER_SNAP_LAYOUTS_BUTTON_H_
