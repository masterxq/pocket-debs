# System-wide back navigation for Plasma Mobile

The patches for `kwin`, `plasma-mobile` and `kf6-kirigami` in this repository add a system-wide "back" to Plasma
Mobile: the navigation bar shows a back arrow in place of the close button while the active window reports that
back has an effect in it, and tapping the arrow makes that window go back one step. This page describes the problem,
how the parts work together, what happens without them, and where the work could go upstream. It is meant to become
a KDE tracking issue later; nothing of it has been submitted yet.

## Problem

The navigation bar of Plasma Mobile has three buttons: task switcher, home, and a close button that closes the
active window (`xdg_toplevel.close`). There is no back button. Applications draw their own back control in the
window content, usually at the top left, which is the hardest place to reach on a phone held in one hand. Phone
users expect one back control at the bottom of the screen, as on Android.

Back cannot be emulated by the shell. Sending Escape or Alt+Left to the window is guessing: some applications
close a dialog on Escape but do not go back a page, some go back in their history on Alt+Left but ignore Escape,
and none of them tell whether the key would do anything at all. The shell could not know when to show a back
button and when to keep the close button.

## Design

Applications tell the compositor, per window, whether back currently has an effect; the shell reads this state
for the active window and asks the compositor to send back to exactly that window. Two Wayland protocols carry
this, both versioned and both written for this purpose:

- `kde_back_navigation_v1` (file `kde-back-navigation-v1.xml`), used by applications: an object per
  `xdg_toplevel` with a state (`unavailable`, `available`) the application sets at any time, and an event
  `back`.
- `kde_back_navigation_shell_v1` (file `kde-back-navigation-shell-v1.xml`), used by the shell: for a window it
  manages through `org_kde_plasma_window_management` it gets an object that reports the state of that window and
  has a request `back`. Passing the `org_kde_plasma_window` object restricts the protocol to clients that may
  manage windows.

The rules (when the state must be available, what the event means, dialogs and transient windows, popups,
races, lifetime, versioning) are defined only in the descriptions of the two XML files, see the KWin patch
[`kwin/patches/0004-wayland-add-back-navigation-protocols.patch`](../kwin/patches/0004-wayland-add-back-navigation-protocols.patch).
The shell protocol is a separate file so that applications do not need the Plasma window management protocol to
use the application protocol.

## Parts

| Project | Package here | What it does |
|---|---|---|
| KWin | `kwin` | offers both globals, keeps the state per window (`Window::isBackAvailable()`, also passed to `PlasmaWindowInterface`), forwards a back request of the shell to the window only while the state is available and the window can take input (not while a modal dialog blocks it or the session is locked); integration test `testBackNavigation` |
| Plasma Mobile | `plasma-mobile` | `WindowUtil` tracks the state of every window (`activeWindowCanGoBack`, `goBackInActiveWindow()`); the navigation bar shows `go-previous-symbolic` instead of the close button while the active window can go back, and tapping it sends back to that window. The button still hides the on-screen keyboard first when it is shown |
| Kirigami | `kf6-kirigami` | the application side: an attached type `BackNavigation` lets items report that back has an effect for them and handle it; a dispatcher per window combines them with the open popups of the window (the topmost one is closed as on Escape) and talks to the compositor. `PageRow` (layers, then pages), the submenus of `GlobalDrawer`, drawers and dialogs take part, so applications built from these components need no code of their own |

The XML files are copied into each project until they have an upstream home, because the packages are built
against the build dependencies of the Debian suite, whose `plasma-wayland-protocols` does not contain them.

## Without support

Everything that does not implement the protocols behaves as before:

| Situation | Result |
|---|---|
| application without the protocol (GTK, Firefox, XWayland, older Kirigami) | state stays unavailable, the navigation bar shows the close button |
| application with the protocol, nothing to go back to | state unavailable, close button |
| compositor without the protocols (other compositors, KWin without the patch) | the application finds no global and works as before; Plasma Mobile finds no shell global and shows the close button |
| Plasma desktop | KWin offers the globals, but no shell uses them; applications behave as before |
| application with the state available but not responding | tapping the arrow has no effect; home and the task switcher stay usable, the window can be closed from the task switcher |

While an application shows the back arrow, the close button is not shown for it; it is closed from the task
switcher.

## Outlook

- **wayland-protocols.** The application side is not specific to KDE. A general protocol in wayland-protocols
  (for example an `xdg_toplevel` extension in staging) would let GTK/libadwaita (`AdwNavigationView`), Qt Quick
  Controls (`StackView`), browsers (history) and other toolkits take part on every compositor. The KDE protocol
  is a first version to learn from; its rules are written so that they could carry over.
- **Plasma Wayland protocols.** Until then the application protocol belongs in `plasma-wayland-protocols`. The shell
  side could instead become a state flag and a request of `org_kde_plasma_window` in a new version of the Plasma
  window management protocol (with KWayland and libtaskmanager following).
- **Other back controls.** KWin could route a hardware Back key or an edge gesture (gesture navigation of Plasma
  Mobile) to the same mechanism.
- **Predictive back.** A later version could announce back before it happens (start, progress, cancel) for
  animated previews as on Android.
