--!nonstrict
-- monitor-input-switch service: owns the i2c bus.
--
-- Finds the monitor through sysfs (EDID vendor id -> DRM connector -> i2c
-- bus), writes the DDC/CI input-select command with i2ctransfer, and publishes
-- a snapshot that the widget, panel and control-center tile render.
--
-- IPC (bind these in your compositor, see README.md):
--   noctalia msg plugin robostyle/monitor-input-switch:service all quick
--   noctalia msg plugin robostyle/monitor-input-switch:service all switch <input>
--   noctalia msg plugin robostyle/monitor-input-switch:service all detect

local common = require("./common.luau")

-- ── DDC/CI ───────────────────────────────────────────────────────────────────
-- A VCP write to the display at 7-bit address 0x37:
--   <source> 0x84 0x03 <vcp> <value hi> <value lo> <checksum>
-- 0x84 is 0x80 | payload length (opcode, vcp, hi, lo). The checksum is the XOR
-- of the destination address byte (0x6E = 0x37 << 1) and every byte before it.
local DDC_ADDR = "0x37"
local DDC_DEST = 0x6E
local PROTOCOLS = {
  -- LG: host address 0x50 instead of the standard 0x51, and LG's vendor VCP
  -- 0xF4. ddcutil setvcp cannot send this, hence the raw i2c write.
  lg = { source = 0x50, vcp = 0xF4 },
  -- Standard MCCS Input Select.
  mccs = { source = 0x51, vcp = 0x60 },
}

local DEFAULT_LABELS = { dp = "DisplayPort", usbc = "USB-C", hdmi1 = "HDMI 1", hdmi2 = "HDMI 2" }
local DEFAULT_GLYPHS = { dp = "device-desktop", usbc = "usb", hdmi1 = "device-tv", hdmi2 = "device-tv" }
local FALLBACK_GLYPH = "device-desktop"

-- One line per DRM connector: "<connector> <edid bytes 8-9 as hex | -> <i2c bus | ->".
-- DP connectors expose their AUX channel as an i2c-N child; HDMI/DVI connectors
-- link theirs as ddc/. A connector reported as disconnected yields "-" for the
-- EDID, so it never matches; the bus number is still printed.
local SCAN = [[
for c in /sys/class/drm/card*-*; do
  [ -d "$c" ] || continue
  n=${c##*/}; n=${n#*-}
  v=-
  if [ "$(cat "$c/status" 2>/dev/null)" = connected ]; then
    v=$(od -An -tx1 -j8 -N2 "$c/edid" 2>/dev/null | tr -d ' \n')
    [ -n "$v" ] || v=-
  fi
  b=-
  for d in "$c"/i2c-* "$c"/ddc/i2c-dev/i2c-*; do
    [ -e "$d" ] && { b=${d##*/i2c-}; break; }
  done
  echo "$n $v $b"
done
]]

-- ── State ────────────────────────────────────────────────────────────────────

local inputs = {} -- { { id, label, glyph, code } } in the configured order
local quick: string? = nil -- quick-switch target id, nil when misconfigured
local current: string? = nil -- last input this machine sent; LGs cannot be read back reliably
local busy = false
local pending: string? = nil -- newest request that arrived while busy
local lastError: string? = nil
local monitor = nil -- { connector, vendor, bus, live }; live = seen in the last scan
local hasTool = noctalia.commandExists("i2ctransfer")

local switchTo -- forward declaration

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function trim(s)
  return noctalia.string.trim(s)
end

local function cfgString(key: string, fallback: string): string
  local value = noctalia.getConfig(key)
  if type(value) == "string" then
    return trim(value)
  end
  return fallback
end

local function fail(message: string)
  lastError = message
  noctalia.notifyError(tr("title"), message)
end

-- ── Persistence ──────────────────────────────────────────────────────────────
-- Once the monitor shows another input it may drop off this machine: status
-- turns disconnected and the EDID disappears, so the scan cannot find it. The
-- last good connector/bus is kept on disk so switching back still works, also
-- after a restart of the shell.

local cachePath = nil
do
  local dir = noctalia.pluginDataDir()
  if dir ~= nil then
    cachePath = dir .. "/monitor.json"
  end
end

local function loadCache()
  if cachePath == nil or not noctalia.fileExists(cachePath) then
    return
  end
  local text = noctalia.readFile(cachePath)
  local data = text and noctalia.json.decode(text)
  if type(data) == "table" and type(data.bus) == "number" then
    monitor = { connector = data.connector, vendor = data.vendor, bus = data.bus, live = false }
  end
end

local function saveCache()
  if cachePath == nil or monitor == nil then
    return
  end
  local text = noctalia.json.encode({ connector = monitor.connector, vendor = monitor.vendor, bus = monitor.bus })
  if text ~= nil then
    local ok, err = noctalia.writeFile(cachePath, text)
    if not ok then
      noctalia.log(`could not write {cachePath}: {err}`)
    end
  end
end

-- ── Configuration ────────────────────────────────────────────────────────────

-- "0xD0", "0XD0" or "208" -> 208. 16 bit, so MCCS values with a high byte fit.
local function parseCode(value): number?
  if type(value) ~= "string" then
    return nil
  end
  local s = trim(value)
  local n = nil
  if s:match("^0[xX]%x+$") then
    n = tonumber(s:sub(3), 16)
  elseif s:match("^%d+$") then
    n = tonumber(s)
  end
  if n == nil or n < 0 or n > 0xFFFF then
    return nil
  end
  return n
end

local function readConfig()
  local list = noctalia.getConfig("inputs")
  local codes = noctalia.getConfig("codes")
  local labels = noctalia.getConfig("labels")
  if type(codes) ~= "table" then
    codes = {}
  end
  if type(labels) ~= "table" then
    labels = {}
  end

  inputs = {}
  local seen = {}
  if type(list) == "table" then
    for _, raw in ipairs(list) do
      local id = trim(tostring(raw)):lower()
      if id ~= "" and not seen[id] then
        seen[id] = true
        local code = parseCode(codes[id] or codes[raw])
        if code == nil then
          noctalia.log(`input '{id}' has no valid entry in the codes setting; skipped`)
        else
          local label = labels[id] or labels[raw]
          if type(label) ~= "string" or trim(label) == "" then
            label = DEFAULT_LABELS[id] or id
          end
          table.insert(inputs, {
            id = id,
            label = trim(label),
            glyph = DEFAULT_GLYPHS[id] or FALLBACK_GLYPH,
            code = code,
          })
        end
      end
    end
  end

  local target = cfgString("quick_target", ""):lower()
  quick = nil
  for _, input in ipairs(inputs) do
    if input.id == target then
      quick = target
    end
  end
  if quick == nil and target ~= "" then
    noctalia.log(`quick_target '{target}' is not one of the configured inputs`)
  end
end

local function findInput(id: string?)
  for _, input in ipairs(inputs) do
    if input.id == id then
      return input
    end
  end
  return nil
end

-- ── Publishing ───────────────────────────────────────────────────────────────

local function publish()
  local mon = nil
  if monitor ~= nil then
    mon = { connector = monitor.connector, vendor = monitor.vendor, bus = monitor.bus, live = monitor.live }
  end
  noctalia.state.set(common.STATE_KEY, {
    inputs = inputs,
    quick = quick,
    current = current,
    busy = busy,
    error = lastError,
    monitor = mon,
  })
end

-- ── Detection ────────────────────────────────────────────────────────────────

-- EDID bytes 8-9: big-endian, three 5-bit letters, 1 = 'A'. LG is "GSM" (0x1E6D).
local function decodeVendor(hex: string): string?
  if not hex:match("^%x%x%x%x$") then
    return nil
  end
  local v = tonumber(hex, 16)
  local letters = {}
  for _, shift in ipairs({ 10, 5, 0 }) do
    local c = bit32.band(bit32.rshift(v, shift), 0x1F)
    if c < 1 or c > 26 then
      return nil
    end
    table.insert(letters, string.char(64 + c))
  end
  return table.concat(letters)
end

-- Calls onDone(monitor) with the detected monitor, the last known one when the
-- scan finds nothing, or nil. Scanning sysfs takes a few milliseconds, so it
-- runs before every switch: bus numbers can change across reboots and hotplug.
local function detect(onDone)
  local override = noctalia.getConfig("bus")
  if type(override) == "number" and override >= 0 then
    monitor = { connector = nil, vendor = nil, bus = math.floor(override), live = true }
    onDone(monitor)
    return
  end

  local wantVendor = cfgString("vendor", "GSM"):upper()
  local wantConnector = cfgString("connector", "")

  local started = noctalia.runAsync(SCAN, function(res)
    local found = nil
    if res.exitCode == 0 then
      for line in res.stdout:gmatch("[^\n]+") do
        local connector, hex, bus = line:match("^(%S+)%s+(%S+)%s+(%S+)$")
        if connector ~= nil and tonumber(bus) ~= nil then
          local vendor = decodeVendor(hex)
          if vendor == wantVendor and (wantConnector == "" or connector == wantConnector) then
            found = { connector = connector, vendor = vendor, bus = tonumber(bus), live = true }
            break
          end
        end
      end
    else
      noctalia.log(`sysfs scan failed ({res.exitCode}): {res.stderr}`)
    end

    if found ~= nil then
      local changed = monitor == nil or monitor.bus ~= found.bus or monitor.connector ~= found.connector
      monitor = found
      if changed then
        saveCache()
      end
    elseif monitor ~= nil then
      monitor.live = false
    end
    onDone(monitor)
  end, 5000)

  if not started then
    onDone(monitor)
  end
end

-- ── Switching ────────────────────────────────────────────────────────────────

local function describeWriteError(stderr: string?): string
  local s = stderr or ""
  if s:find("Permission denied", 1, true) then
    return tr("errors.permission")
  end
  if s:find("No such file", 1, true) then
    return tr("errors.no_device")
  end
  return tr("errors.write_failed", { detail = s:match("[^\n]+") or "?" })
end

local function finish()
  busy = false
  publish()
  if pending ~= nil then
    local id = pending
    pending = nil
    switchTo(id)
  end
end

local function buildCommand(bus: number, code: number): { string }
  local protocol = PROTOCOLS[cfgString("protocol", "lg")] or PROTOCOLS.lg
  local bytes = {
    protocol.source,
    0x84,
    0x03,
    protocol.vcp,
    bit32.rshift(code, 8),
    bit32.band(code, 0xFF),
  }
  local checksum = DDC_DEST
  for _, b in ipairs(bytes) do
    checksum = bit32.bxor(checksum, b)
  end
  table.insert(bytes, checksum)

  local argv = { "i2ctransfer", "-y", tostring(bus), `w{#bytes}@{DDC_ADDR}` }
  for _, b in ipairs(bytes) do
    table.insert(argv, string.format("0x%02X", b))
  end
  return argv
end

switchTo = function(id: string)
  local input = findInput(id)
  if input == nil then
    noctalia.notifyError(tr("title"), tr("errors.unknown_input", { id = id }))
    return
  end
  if busy then
    pending = id
    return
  end
  if not hasTool then
    hasTool = noctalia.commandExists("i2ctransfer")
    if not hasTool then
      fail(tr("errors.no_i2ctransfer"))
      publish()
      return
    end
  end

  busy = true
  lastError = nil
  publish()

  detect(function(mon)
    if mon == nil then
      fail(tr("errors.no_monitor", { vendor = cfgString("vendor", "GSM") }))
      finish()
      return
    end
    if not noctalia.fileExists(`/dev/i2c-{mon.bus}`) then
      fail(tr("errors.no_device"))
      finish()
      return
    end

    local argv = buildCommand(mon.bus, input.code)
    noctalia.log(table.concat(argv, " "))
    local started = noctalia.runAsync(argv, function(res)
      if res.timedOut then
        fail(tr("errors.timeout"))
      elseif res.exitCode ~= 0 then
        fail(describeWriteError(res.stderr))
      else
        current = id
        lastError = nil
      end
      finish()
    end, 3000)
    if not started then
      fail(tr("errors.spawn"))
      finish()
    end
  end)
end

local function switchQuick()
  if quick == nil then
    noctalia.notifyError(tr("title"), tr("errors.no_quick_target"))
    return
  end
  switchTo(quick)
end

-- ── Requests from the panel and the tile ─────────────────────────────────────

local handledNonce = 0
do
  local req = noctalia.state.get(common.REQUEST_KEY)
  if type(req) == "table" and type(req.nonce) == "number" then
    handledNonce = req.nonce
  end
end

noctalia.state.watch(common.REQUEST_KEY, function(req)
  if type(req) ~= "table" or type(req.nonce) ~= "number" or req.nonce <= handledNonce then
    return
  end
  handledNonce = req.nonce
  if req.action == "quick" then
    switchQuick()
  elseif req.action == "switch" and type(req.id) == "string" then
    switchTo(req.id)
  end
end)

-- ── Host callbacks ───────────────────────────────────────────────────────────

function onIpc(event, payload)
  if event == "quick" then
    switchQuick()
  elseif event == "switch" then
    local id = if type(payload) == "string" then trim(payload):lower() else ""
    switchTo(id)
  elseif event == "detect" then
    detect(function(_mon)
      publish()
    end)
  else
    noctalia.log(`unknown IPC event '{event}'`)
  end
end

-- Plugging or unplugging the monitor (or switching its input away) changes the
-- output set, so rescan right away to turn the widget red or back without a
-- click. The kernel may update the connector status a moment after the
-- compositor reacts, so scan once more a second later; only the newest change
-- schedules that second scan. A running switch does its own scan.
local outputsGen = 0

local function rescan()
  if busy then
    return
  end
  detect(function(_mon)
    publish()
  end)
end

function onOutputsChanged()
  outputsGen += 1
  local gen = outputsGen
  rescan()
  noctalia.runAsync({ "sleep", "1" }, function(_res)
    if gen == outputsGen then
      rescan()
    end
  end)
end

function onConfigChanged()
  readConfig()
  publish()
  detect(function(_mon)
    publish()
  end)
end

-- On disable/uninstall/shutdown nothing republishes, so do not leave the other
-- entries showing "switching" forever. A hot reload republishes on load.
function onExit(_signal, reason)
  if reason ~= "reload" and busy then
    busy = false
    publish()
  end
end

-- ── Startup ──────────────────────────────────────────────────────────────────

readConfig()
loadCache()
if not hasTool then
  lastError = tr("errors.no_i2ctransfer")
end
publish()
detect(function(_mon)
  publish()
end)
