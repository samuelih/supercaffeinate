# supercaffeinate

Keeps a Mac fully awake until you turn it off, or for a set time: no system
sleep, no display sleep, no screensaver, no auto-lock, and closing the lid does
not put the machine to sleep. Controlled from the terminal or from a small menu bar app.

## Menu bar app

<p align="center"><img src="docs/menubar-icon.png" width="106" alt="SuperCaffeinate coffee cup icon in the macOS menu bar"></p>
<p align="center"><em>The status item: a filled cup while awake, an outline cup while off.</em></p>

<p align="center"><img src="docs/menubar-menu.png" width="323" alt="SuperCaffeinate menu open, showing Awake since 09:57, the lid state, Turn Off and Quit"></p>
<p align="center"><em>The open menu while on: how long it has been awake, what the lid is doing, and the switch.</em></p>

<p align="center"><img src="menubar/icon/AppIcon-1024.png" width="160" alt="SuperCaffeinate app icon"></p>

## What it does

`supercaffeinate on`:

- holds `caffeinate` assertions for idle, disk, system and display sleep
- sets the screensaver idle time to 0 (the previous value is saved and restored)
- runs `pmset -a disablesleep 1`, so closing the lid or choosing Sleep from the
  Apple menu does nothing
- starts a small watcher that follows the lid once a second

`supercaffeinate off` undoes all of it and restores normal sleep and lock
behavior. Each switch posts a notification. While the menu bar app is running
it posts them with its own icon, so allow SuperCaffeinate in System Settings >
Notifications (and in any Focus mode allow list); when the app is not running
the script falls back to `osascript`, which shows up as Script Editor.

`supercaffeinate on 8h` does the same with an auto-off timer: when the time is
up the watcher runs the normal off path (the notification says "OFF (timer
expired)") and the usual sleep and lock behavior comes back.

`supercaffeinate on claude` stays awake while Claude Code sessions are working.
Every 30 seconds the watcher counts `claude` processes and looks for a
transcript under `~/.claude/projects` written in the last 15 minutes (Claude
Code appends to it on every turn and tool call). Once no session is left, or
none has written for the grace period, it turns off ("OFF (Claude idle for
15m)"). `on claude 30m` changes the grace. The first check waits one grace
period, so a fresh start is never judged on stale transcripts.

`supercaffeinate check` prints health as `key=value` lines: whether the
passwordless `pmset` rule is installed, whether `screenblank` is present,
whether `pmset disablesleep` is still set while off (for example after a
reboot), whether the lid watcher is alive, and how many Claude sessions are
running. The menu bar app reads it when the menu opens. `status` prints the
same problems as warnings.

### Lid handling

The display is never allowed to sleep, so the "require password after the
display turns off" lock never fires. What happens when the lid closes depends
on what is plugged in:

- **Built-in display only:** the screen is blacked out by `screenblank`, a tiny
  helper that sets every display's gamma to zero. The panel is still on as far
  as macOS is concerned, so nothing locks and everything keeps running.
  Opening the lid kills the helper and the picture comes straight back.
- **External display connected:** no blackout. The Mac keeps running in
  clamshell mode and the external screen stays on. Unplugging the external
  display while the lid is closed applies the blackout.

## Menu bar app

`SuperCaffeinate.app` puts a coffee cup in the menu bar: filled when on,
outline when off, a warning triangle if the state is stale or the lid watcher
died. Click it to see how long the Mac has been held awake (or how long is
left on a timer, and until when) and to turn it on or off. Turn On stays on
indefinitely; Turn On For opens a submenu with 30 minutes, 1, 2, 4 and 8
hours, Until 7:00 AM, and Custom... (a number of hours, 0.5 is fine); Turn On
While Claude Runs is the `on claude` mode and shows how many sessions are
running.

The menu also reports problems instead of hiding them: a missing `pmset`
sudoers rule ("Setup needed", with a Run Setup in Terminal... item), sleep
still disabled from an earlier session while off (with Restore Normal Sleep),
a dead watcher (with Repair, which turns off and back on with the same mode
and remaining time), and the last failure or warning the script printed. Each
of those is also posted as a notification.

The app polls the state file every 2 seconds, so changes made from a terminal or a
hotkey show up right away. It is launched at login by a LaunchAgent. See
[menubar/README.md](menubar/README.md) for details.

## Install

    git clone https://github.com/partypancake8/supercaffeinate.git
    cd supercaffeinate
    ./install.sh
    supercaffeinate-setup

`install.sh` copies the scripts to `~/bin`, compiles `screenblank` from
`screenblank/main.swift` into `~/bin/screenblank` (no binary is shipped in
this repo), builds the menu bar app into `~/Applications`, renders the
LaunchAgent with your home directory and loads it. It is safe to re-run.

`supercaffeinate-setup` only needs to run once. It installs
`/etc/sudoers.d/supercaffeinate`, a NOPASSWD rule for your user limited to
`pmset -a disablesleep 1` and `pmset -a disablesleep 0`, so the toggle works
from a hotkey or the menu bar with no password prompt. It asks for your admin
password once.

Make sure `~/bin` is on your `PATH`.

## Usage

    supercaffeinate on [DURATION | claude [GRACE]]
    supercaffeinate off
    supercaffeinate toggle [DURATION | claude [GRACE]]
    supercaffeinate status
    supercaffeinate check

DURATION is optional. Leave it out (or pass `0`, `inf`, `infinite` or
`forever`) to stay awake until `off`. Otherwise it is hours, minutes and
seconds such as `8h`, `90m`, `2h30m` or `45s`, or a bare number of minutes
(`45`). When the timer runs out supercaffeinate turns itself off. `status`
shows the time left, e.g. `auto-off in 7h 42m (at 19:35)`. `claude` instead
of a duration stays awake while Claude Code sessions are active, with an
optional GRACE (default `15m`, minimum `1m`) before an idle session counts as
done.

`toggle` is safe to fire from a hotkey with no terminal: a lock prevents rapid
presses from stacking. To bind it to a key, point Karabiner-Elements,
Hammerspoon or a Shortcut at `supercaffeinate toggle`.

## Requirements

- macOS 13 or later, Apple Silicon or Intel
- `swiftc` from the Xcode Command Line Tools (`xcode-select --install`)
- Python 3 with Pillow, only if you want to regenerate the app icon

## Caveats

- While on, sleep is disabled system-wide. A laptop in a bag with the lid
  closed will keep running and draining the battery until you turn it off.
- State lives in `/tmp`, so a reboot resets everything to normal. If a reboot
  happens while it is on, `pmset disablesleep` may still be set; run
  `supercaffeinate off` once to clear it.
- The lid blackout only changes gamma. The backlight stays on at whatever
  brightness it was.

## Uninstall

    supercaffeinate off
    launchctl bootout gui/$(id -u)/com.sawyer.supercaffeinate-menubar
    rm ~/Library/LaunchAgents/com.sawyer.supercaffeinate-menubar.plist
    rm -rf ~/Applications/SuperCaffeinate.app
    rm ~/bin/supercaffeinate ~/bin/supercaffeinate-setup ~/bin/screenblank
    sudo rm /etc/sudoers.d/supercaffeinate
