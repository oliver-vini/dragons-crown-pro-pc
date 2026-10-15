// "Hold Shift while starting brings the launcher back." On Linux the X server is asked for its keyboard state; Wayland
// has no global key state (--launcher does the same there).
#pragma once

namespace dcp {

bool ShiftHeldAtStart();

} // namespace dcp
