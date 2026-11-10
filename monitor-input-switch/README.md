# Monitor Input Switcher

Switch your monitor's input source over DDC/CI from the bar or a hotkey. Made
for one monitor shared by two machines, such as a workstation on DisplayPort
and a laptop on USB-C: each machine sends the monitor to the other with one
click.

Written for LG monitors, which need LG's own command (tested on the LG
45GX950A). Other monitors work with the standard MCCS protocol setting.

## Plugin

| Field | Value |
| --- | --- |
| ID | `robostyle/monitor-input-switch` |
| Entries | Bar widget: `button`; panel: `menu`; service: `service`; shortcut: `quick` |

## Requirements

- `i2ctransfer` on `PATH`, from the `i2c-tools` package (Arch: `i2c-tools`,
  Debian/Ubuntu: `i2c-tools`, Fedora: `i2c-tools`).
- `sh` and `od` (coreutils), used to scan `/sys/class/drm` for the monitor.
- The `i2c-dev` kernel module, so `/dev/i2c-N` devices exist.
- Read/write access to the monitor's `/dev/i2c-N` as your user, through a udev
  rule.
- A direct cable. DDC/CI over USB-C works when the laptop is plugged straight
  into the monitor; docks and MST hubs often do not pass it through.
- DDC/CI enabled in the monitor's on-screen menu (on by default on most LGs).

ddcutil is not needed.

### One-time setup

Load `i2c-dev` now and at every boot:

```bash
echo i2c-dev | sudo tee /etc/modules-load.d/i2c-dev.conf
sudo modprobe i2c-dev
```

Give the logged-in user access to i2c buses that belong to a graphics card:

```bash
echo 'SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x03*", TAG+="uaccess"' \
  | sudo tee /etc/udev/rules.d/60-monitor-input-switch.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=i2c-dev
```

`getfacl /dev/i2c-N` should now list your user with `rw-`. No group and no
re-login are needed. If ddcutil is installed, its own
`/usr/lib/udev/rules.d/60-ddcutil-i2c.rules` already contains this rule.

The `ATTRS{class}=="0x03*"` match is deliberate: it only opens buses on the
GPU. Rules that open every `/dev/i2c-*` also expose the motherboard's SMBus,
where RAM configuration chips and RGB controllers live, and a stray write there
can damage them.

Some systems briefly deny `uaccess` devices after resume from sleep. If you
see permission errors after waking up, use a group instead:

```bash
sudo groupadd --system i2c
sudo usermod -aG i2c "$USER"
echo 'SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x03*", GROUP="i2c", MODE="0660"' \
  | sudo tee /etc/udev/rules.d/60-monitor-input-switch.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=i2c-dev
```

Log out and in again for the group to apply.

## Usage

Add the `button` widget from the bar's Add-widget picker.

- **Left click** switches to the **Quick-switch target**. Set this to the
  *other* machine's input: `0xD1` (USB-C) on the workstation, `0xD0` (DisplayPort) on the laptop. You
  only ever see the bar of the machine on screen, so one click always means
  "go to the other machine".
- **Right click** opens the input menu. Pick an input to switch to it. The last
  input this machine sent is highlighted and the quick-switch target is marked
  with a bolt.
- **Middle click** opens the widget's settings.

When the monitor is not connected (cable out, or it shows another input), the
icon turns red and the label goes away. Left and right click then do nothing,
and the tooltip shows the monitor as Disconnected. The service rescans whenever the
set of outputs changes, so this shows right away, without a click. Hotkeys
still work while disconnected; they are the way back after switching away.

The clicks are handled by the widget itself, not bound as bar gestures, so
they can be ignored while disconnected. Do not bind left or right click for
this widget in the bar's gesture settings: a binding always runs.

Open the menu from a keyboard or script:

```sh
noctalia msg panel-toggle robostyle/monitor-input-switch:menu
```

Add the `quick` tile from Settings → Control Center shortcuts for a
one-press quick switch.

### Hotkeys

The service accepts IPC events. Bind them in your compositor:

```sh
noctalia msg plugin robostyle/monitor-input-switch:service all quick          # to the quick-switch target
noctalia msg plugin robostyle/monitor-input-switch:service all switch 0xD1    # to an input by code
noctalia msg plugin robostyle/monitor-input-switch:service all switch usbc    # to an input by name, any case
noctalia msg plugin robostyle/monitor-input-switch:service all switch 2       # to the second input in the menu (sorted by code)
noctalia msg plugin robostyle/monitor-input-switch:service all detect         # rescan for the monitor
```

`switch` takes an input's code (`0xD1`), its name in any case, or its position
in the menu, which is sorted by code. Quote names with spaces
(`switch "PS5 Pro"`). A code keeps working when you rename the input.

A hotkey is the way back when this machine's only monitor shows another
input, since its bar is then off screen.

Niri (`~/.config/niri/config.kdl`, inside `binds { }`):

```kdl
Mod+Shift+M { spawn "noctalia" "msg" "plugin" "robostyle/monitor-input-switch:service" "all" "quick"; }
Mod+Shift+1 { spawn "noctalia" "msg" "plugin" "robostyle/monitor-input-switch:service" "all" "switch" "dp"; }
Mod+Shift+2 { spawn "noctalia" "msg" "plugin" "robostyle/monitor-input-switch:service" "all" "switch" "usbc"; }
```

Hyprland (`~/.config/hypr/hyprland.conf`):

```ini
bind = SUPER SHIFT, M, exec, noctalia msg plugin robostyle/monitor-input-switch:service all quick
bind = SUPER SHIFT, 1, exec, noctalia msg plugin robostyle/monitor-input-switch:service all switch dp
bind = SUPER SHIFT, 2, exec, noctalia msg plugin robostyle/monitor-input-switch:service all switch usbc
```

Umbriel (`[keybinds]` in your Umbriel config):

```toml
"Mod+Shift+M" = "spawn:noctalia msg plugin robostyle/monitor-input-switch:service all quick"
"Mod+Shift+1" = "spawn:noctalia msg plugin robostyle/monitor-input-switch:service all switch dp"
"Mod+Shift+2" = "spawn:noctalia msg plugin robostyle/monitor-input-switch:service all switch usbc"
```

Sway (`~/.config/sway/config`):

```text
bindsym $mod+Shift+m exec noctalia msg plugin robostyle/monitor-input-switch:service all quick
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `inputs` | `string_map` | *(empty: `0xD0 = dp`, `0xD1 = usbc`, `0x90 = hdmi1`, `0x91 = hdmi2`)* | Input code → name. The menu is sorted by code. |
| `quick_target` | `string` | `0xD1` | Code, name or menu position of the input for left click, the tile and the `quick` IPC event. |
| `protocol` | `select` | `lg` | `lg`: host address 0x50, VCP 0xF4. `mccs`: standard Input Select, VCP 0x60 (advanced). |
| `vendor` | `string` | `GSM` | EDID manufacturer id used to find the monitor; `GSM` is LG (advanced). |
| `connector` | `string` | *(empty)* | Only use the monitor on this connector, e.g. `DP-1` (advanced). |
| `bus` | `int` | `-1` | Fixed `/dev/i2c-N` number; `-1` detects automatically (advanced). |

Widget settings:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `label_mode` | `select` | `target` | Text next to the icon: `→ <quick-switch target>`, the last sent input, or nothing. |
| `glyph` | `glyph` | `device-desktop` | Bar icon. |

Each **Inputs** entry maps the code the monitor expects for an input to the
name shown in the menu and the bar. While **Inputs** is empty the plugin uses
the LG inputs `0xD0 = dp`, `0xD1 = usbc`, `0x90 = hdmi1` and `0x91 = hdmi2`.
The first entry you add replaces all four, so add every input you use:

```text
0x90 = PS5
0xD0 = Workstation
0xD1 = Macbook
```

The code is the key: hex (`0xD0`) or decimal, fixed once added. To fix a wrong
code, remove the entry and add it again. The name is the value and can be
changed any time; two inputs may share a name, and an empty name shows the
code. The menu is sorted by code. A key that is not a code, or the same code
written twice (`0xD0` and `208`), is skipped and logged. Use codes for the
**Quick-switch target** and in hotkeys if you rename inputs often.

The setting starts empty, rather than showing the four LG inputs, because
Noctalia's key/value editor drops the other default rows on the first edit.
Entries you add yourself are saved and edited normally.

For a non-LG monitor, set **Protocol** to standard MCCS and enter the
monitor's own codes. Common MCCS values are `0x0F` DisplayPort 1, `0x10`
DisplayPort 2, `0x11` HDMI 1 and `0x12` HDMI 2; `ddcutil capabilities` lists
the ones your monitor accepts.

## How it works

The service scans `/sys/class/drm/card*-*`. For each connected connector it
reads the EDID manufacturer id (bytes 8–9) and finds the connector's i2c bus:
the DP AUX channel (`i2c-N` child) or the HDMI `ddc` link. The first match for
**EDID vendor id** (and **Connector**, if set) is used. While it is connected,
the monitor name, serial number and connector are shown in the widget's
tooltip as **Monitor**, **Serial** and **Output**.

It then writes one DDC/CI VCP-set packet to address `0x37`:

```text
i2ctransfer -y <bus> w7@0x37 <source> 0x84 0x03 <vcp> <hi> <lo> <checksum>
```

with source `0x50` and VCP `0xF4` for LG, or `0x51` and `0x60` for MCCS. The
checksum is the XOR of `0x6E` and all preceding bytes.

Once the monitor shows another input it often disappears from this machine.
The last bus that worked, with the monitor's connector, name and serial, is
saved in the plugin's data directory, so switching back still works and the
tooltip still names the monitor, also after the shell restarts.

Most monitors, LG included, do not report the active input reliably, so the
plugin never reads it back. The highlighted input in the menu and the "Last sent
input" label are what this machine last sent.

- **Processes spawned:** `sh` (the sysfs scan) and `i2ctransfer`, only when
  switching or rescanning.
- **Files written:** `monitor.json` in the plugin data directory.

## Troubleshooting

- **No permission to open the i2c device:** the udev rule is missing or not
  applied. Check `getfacl /dev/i2c-N`.
- **The i2c device does not exist:** `i2c-dev` is not loaded. Run
  `sudo modprobe i2c-dev`.
- **No monitor found:** run
  `od -An -tx1 -j8 -N2 /sys/class/drm/card*-DP-1/edid`. LG prints `1e 6d`.
  Otherwise set **EDID vendor id**, **Connector** or **i2c bus override**.
- **The write succeeds but nothing happens:** check that DDC/CI is enabled in
  the monitor's menu and try the other **Protocol**.
