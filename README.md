# StreamCamBar

Tiny macOS menu bar app for Logitech StreamCam UVC controls — no Logitech Tune/G Hub needed.

Talks to the camera directly over USB (UVC class requests via IOKit).

## Controls
- Exposure: auto toggle, shutter (log scale), gain, brightness
- White balance: auto toggle, temperature
- Focus: auto toggle, manual focus, zoom
- Image: contrast, saturation, sharpness, backlight comp, anti-flicker
- Reset to defaults / re-apply

## Profiles
Save the current settings as a named profile (e.g. "Daytime", "Evening – lamp on") and switch
from the menu at the top of the panel. Tweak a profile's settings and hit **Update** to save them back.
Give a profile an auto-switch time and it's applied automatically when that time passes — also on
launch/wake if you missed it. Picking a profile by hand sticks until the next scheduled time.

Settings you change are saved and (optionally) re-applied when the camera is plugged in,
when the Mac wakes, and when an app starts using the camera.

## Build
```sh
./build.sh           # -> build/StreamCamBar.app
./build.sh install   # copy to ~/Applications and launch
```
Needs Xcode command line tools, macOS 13+. Other UVC cameras: change `targetVendorID` /
`targetProductID` in `CameraModel.swift`.
