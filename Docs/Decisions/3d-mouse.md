# 3D mouse navigation

A 3D mouse, such as a 3Dconnexion SpaceMouse, moves the viewport camera. The
plan does not cover 3D mice; the owner asked for them on 2026-11-24 and chose
to support both the 3Dconnexion driver and direct HID input.

## Two device paths

When 3Dconnexion's driver (3DxWare) is installed, it takes the device for
itself, so reading the device directly returns nothing. Scadretto therefore
picks one path when input starts:

- **Driver.** If `/Library/Frameworks/3DconnexionClient.framework` exists,
  Scadretto loads it at run time and registers as a client. It neither links
  nor ships the framework. It registers with the driver's manual signature,
  so the driver delivers input only while Scadretto asks for it: Scadretto
  activates the client when it becomes the active application and deactivates
  it when it resigns. In take-over mode the client receives all six axes and
  every button, and the driver runs none of its own button assignments
  meanwhile.
- **Direct HID.** Otherwise Scadretto matches HID multi-axis controllers
  (Generic Desktop page, usage 0x08). It discovers them without opening them,
  so a Mac without a 3D mouse never sees a permission request. While
  Scadretto is active it opens each one exclusively, because macOS otherwise
  moves the pointer with the cap. It closes them when Scadretto resigns active
  so other programs can use them. Opening may need the Input Monitoring
  permission; macOS asks once, and Settings explains a refusal or a device
  another program holds.

If the framework is present but fails to load, Scadretto reports that
instead of falling back, since the driver would still hold the device.

### Declarations, not the SDK

Scadretto declares the six client functions it calls and reads the four
fields it uses from the driver's 48-byte device state record by offset:
target client at 2, command at 4, axes at 30 and the 32-bit buttons at 44.
The driver sends every record to all its clients, so Scadretto ignores records
for another client, such as a second running Scadretto. It includes no
3Dconnexion header. The installed headers carry a notice that reserves use,
copying, modification and distribution to 3Dconnexion's permission. The owner
chose this path knowing that, and confirms the licensing before a release.

### Library validation

Under the hardened runtime, which every Scadretto build uses, the app may
load only libraries signed by Apple or by its own team. The 3Dconnexion
framework is signed by 3Dconnexion, so the app carries one entitlement,
`com.apple.security.cs.disable-library-validation`
(`App/Scadretto.entitlements`); `Scripts/package-macos` signs the app with it
in both modes. The worker keeps no entitlements, so its own library
validation is unchanged. Packaging fails unless the app carries exactly this
entitlement and the worker none. A separate helper process could have kept validation
in the app, but the driver delivers input to the client of the active
application, and a helper is never that application.

Observed on this Mac: a Debug build signed with Apple Development and the
hardened runtime registered with the driver. The same app re-signed without
the entitlement failed in `dlopen` with a code signature error and reported
"could not load its client library" in Settings.

## Motion

Devices report x to the right, y toward the user and z down, with rotations
right-handed about those axes. View axes put x right, y up and z toward the
viewer, so a reading `(x, y, z, rx, ry, rz)` becomes translation
`(x, -z, y)` and rotation `(rx, -rz, ry)`. The model follows the cap, the
usual object mode: push right and it moves right, pull toward you and it comes
closer, twist and it turns the same way. Readings within 4% of rest count as
rest and the rest rescales, so a cap that does not quite center cannot drift.

Direct HID readings are normalized by each axis's logical range and clamped
to ±1. Driver readings are normalized by 350, the devices' usual full scale.
They are allowed up to ±4, because the driver applies the user's 3DxWare
speed settings first.

At full deflection and speed 1 the model turns at 2 radians a second, pans one
visible view height a second, and zooms by a factor of e^1.2 a second about the
orbit center. Settings scales all three from 0.25× to 4×. The viewport
advances the camera once per display frame while motion is not zero. It
limits each step to 0.1 s so a stalled frame cannot jump the view. Like
scrolling, it leaves the camera alone during a handle drag.

## Buttons

3Dconnexion numbers buttons the same way in driver messages and in its
devices' HID reports. Two-button devices report Menu and Fit.

| Button | Action |
|---|---|
| Menu (1) | Diagonal view, then Frame Model |
| Fit (2) | Frame Model |
| Top, Left, Right, Front, Bottom, Back (3–8) | The standard view |

Other buttons do nothing.

## Routing and lifetime

Motion goes to the viewport of the frontmost document window, including while
the Settings window is in front. A held cap keeps reporting the same reading,
so the motion moves to a document window that becomes main and leaves one
that closes. Motion returns to zero when Scadretto resigns active, when input
is switched off, and when a device goes away. Settings shows whether input is
on, its speed and its status. The driver's device query names a device even
when none is connected, so the driver path reports a device only when the
driver says one arrived or left.

## Verification

Automated, run on every `Scripts/verify`:

- `ScadrettoInputTests`: axis mapping, dead zone, normalization, driver
  record decoding, button edges, activation rules, and resolving the client
  functions from an installed framework (skipped without 3DxWare).
- `ViewportNavigationTests`: direction, rate and bounds of each kind of
  motion, and an orthonormal camera after 5,000 steps.
- UI test `testThreeDMouseMovesTheFrontViewport`: a simulated device (hidden
  default `ScadrettoSimulated3DMouse`) turns the plate in the real
  application, keeps turning it behind Settings, and stops when input is
  switched off. Its first run found that the motion stayed with the untitled
  window a newly opened document replaced.

On a Mac16,9 with macOS 27.0.1 and 3DxWare 10.8.14: the driver extension
enabled, Scadretto registered as a driver client, and Settings read "Using
the 3Dconnexion driver." No 3D mouse was connected and none could be
simulated: a virtual HID device needs an entitlement only Apple grants.

### Real-device checklist

Not yet run. With the mounting plate open, at speed 1:

1. With 3DxWare installed, Settings reads "Using the 3Dconnexion driver."
   Plugging the device in changes it to "A 3D mouse is connected…".
2. Push the cap right: the model moves right. Lift it: the model moves up.
   Pull it toward you: the model comes closer.
3. Twist the cap counterclockwise seen from above: the model turns
   counterclockwise. Tilt its top toward you: the model's top tips toward
   you. Roll it to the left: the model rolls counterclockwise on screen.
4. Full deflection feels fast but controllable. If the driver path is several
   times faster or slower than the HID path, its 350 full scale needs
   adjusting.
5. Fit frames the model; Menu returns to the diagonal view. On larger
   devices the view buttons select their views.
6. During a diameter handle drag the cap does not move the view, and the drag
   commits one undo entry.
7. Switch to another application: the device works there as the driver
   configures it. Switch back: it moves Scadretto's view again.
8. Without 3DxWare: the first use asks for Input Monitoring. After allowing
   it and reopening Scadretto, Settings names the device. Steps 2–7 behave
   the same, and the pointer stays still while Scadretto is active.
9. Turning input off in Settings stops the device from moving the view.
