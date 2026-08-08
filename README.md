# adi2-mac-controller

Control an RME ADI-2 DAC's Line-out volume with your Mac's keyboard media keys (volume up/down/mute), by talking to the DAC directly over MIDI SysEx instead of macOS's own system volume. macOS's system volume is left untouched — the media keys are captured and consumed before the OS handles them.

## How it works

- `init.lua` is a [Hammerspoon](https://www.hammerspoon.org/) config that intercepts the `SOUND_UP`/`SOUND_DOWN`/`MUTE` system-defined key events and, on each press, sends a MIDI SysEx message to the DAC via [`sendmidi`](https://github.com/gbevin/SendMIDI).
- The SysEx format is RME's documented MIDI protocol (see `MIDITable_ADI-2_230930.ods` from RME, or the [ADI-2 Remote MIDI protocol download](https://rme-audio.de/downloads/adi2remote_e.pdf)). Volume is Line-out channel address `3`, parameter index `12`, sent as an absolute value in 0.1 dB units.
- Because the DAC didn't reliably echo its state back over MIDI when queried (tested against real hardware — writes work, reads don't), the current volume/mute state is tracked locally (via `hs.settings`, backed by macOS preferences) rather than queried from the device on every launch. If you turn the physical knob while Hammerspoon isn't running, state can drift until the next key press.

## Setup

This repo *is* the Hammerspoon config — `~/.hammerspoon/init.lua` is a symlink into it, so editing files here takes effect immediately (just reload Hammerspoon).

1. **Install Hammerspoon** (captures the global media keys):
   ```
   brew install --cask hammerspoon
   ```
   Launch it once, then grant it **Accessibility** access when prompted (System Settings → Privacy & Security → Accessibility).

2. **Install `sendmidi`/`receivemidi`.** Building from source via Homebrew (`gbevin/tools/sendmidi`) requires a full Xcode install. To avoid that, grab the prebuilt macOS binaries from the GitHub releases and extract the executable directly from the `.pkg` payload instead of running the installer (no `sudo` needed). Check the [SendMIDI](https://github.com/gbevin/SendMIDI/releases) / [ReceiveMIDI](https://github.com/gbevin/ReceiveMIDI/releases) releases pages for the current version and substitute it below (this was tested with sendmidi 1.4.3 / receivemidi 1.6.1):
   ```
   cd /tmp
   curl -sL -o sendmidi.zip https://github.com/gbevin/SendMIDI/releases/download/1.4.3/sendmidi-macOS-1.4.3.zip
   curl -sL -o receivemidi.zip https://github.com/gbevin/ReceiveMIDI/releases/download/1.6.1/receivemidi-macOS-1.6.1.zip
   unzip -o sendmidi.zip -d sendmidi_extract
   unzip -o receivemidi.zip -d receivemidi_extract
   pkgutil --expand sendmidi_extract/*.pkg sendmidi_pkg_expanded
   pkgutil --expand receivemidi_extract/*.pkg receivemidi_pkg_expanded
   mkdir -p sendmidi_payload receivemidi_payload
   tar -xzf sendmidi_pkg_expanded/Payload -C sendmidi_payload
   tar -xzf receivemidi_pkg_expanded/Payload -C receivemidi_payload
   chmod +x sendmidi_payload/sendmidi receivemidi_payload/receivemidi
   cp sendmidi_payload/sendmidi receivemidi_payload/receivemidi /opt/homebrew/bin/
   xattr -d com.apple.quarantine /opt/homebrew/bin/sendmidi /opt/homebrew/bin/receivemidi 2>/dev/null
   ```

3. **Enable MIDI on the DAC.** On the ADI-2 DAC's own Setup menu, make sure MIDI is turned on. Confirm it shows up:
   ```
   sendmidi list
   ```
   You should see something like `ADI-2 DAC (12345678) Port 1`. If not, check the Setup menu and that the DAC is connected via USB.

4. **Symlink this repo's `init.lua` into Hammerspoon's config location:**
   ```
   rm -f ~/.hammerspoon/init.lua
   ln -s "$(pwd)/init.lua" ~/.hammerspoon/init.lua
   ```

5. **Reload Hammerspoon** (relaunch the app, or from its console run `hs.reload()`), and grant it **Input Monitoring** access too, if macOS prompts for it separately from Accessibility.

## Syncing changes

Because `~/.hammerspoon/init.lua` is a symlink into this repo, there's nothing to sync — edit `init.lua` here, then reload Hammerspoon (quit and relaunch the app, or `hs.reload()` from its console) to pick up changes.

If the symlink ever gets clobbered (e.g. by reinstalling Hammerspoon), recreate it:
```
rm -f ~/.hammerspoon/init.lua
ln -s "$(pwd)/init.lua" ~/.hammerspoon/init.lua
```

## Configuration

Edit the constants near the top of `init.lua`:

- `adi2.lineAddress` — which output to control (`3` = Line, `6` = Phones 1/2, `9` = Phones 3/4)
- `adi2.stepDb` — volume step per key press, in dB
- `adi2.minDb` / `adi2.maxDb` — clamp range (device limits: -114.5 to +6.0 dB)

## Debugging

`init.lua` logs to `~/.hammerspoon/adi2.log` (key events, MIDI port discovery, sync attempts). Tail it while testing:
```
tail -f ~/.hammerspoon/adi2.log
```
