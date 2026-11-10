--!nonstrict
-- monitor-input-switch bar widget: renders the snapshot the service publishes.
--
-- Clicks are handled in onClick and onRightClick below rather than bound in
-- [widget.actions], so both do nothing while the monitor is disconnected.

local common = require("./common.luau")

local snapshot = noctalia.state.get(common.STATE_KEY)

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function monitorText(mon): string
  if mon == nil then
    return tr("status.no_monitor")
  end
  local parts = {}
  if mon.vendor ~= nil then
    table.insert(parts, mon.vendor)
  end
  if mon.connector ~= nil then
    table.insert(parts, mon.connector)
  end
  table.insert(parts, `/dev/i2c-{mon.bus}`)
  local text = table.concat(parts, " · ")
  if not mon.live then
    text = text .. " " .. tr("status.last_known")
  end
  return text
end

local function render()
  local glyph = noctalia.getConfig("glyph") or "device-desktop"
  local mode = noctalia.getConfig("label_mode") or "target"

  if type(snapshot) ~= "table" then
    barWidget.setGlyph(glyph)
    barWidget.setText("")
    barWidget.clearTooltip()
    return
  end

  local target = common.find(snapshot, snapshot.quick)
  local current = common.find(snapshot, snapshot.current)
  local offline = common.disconnected(snapshot)

  -- No label while disconnected: there is nothing to switch.
  local text = ""
  if offline then
    text = ""
  elseif mode == "target" and target ~= nil then
    text = `→ {target.label}`
  elseif mode == "current" and current ~= nil then
    text = current.label
  end

  local role = "on_surface"
  if snapshot.error ~= nil or offline then
    glyph = "plug-x"
    role = "error"
  elseif snapshot.busy then
    glyph = "arrows-exchange"
    role = "primary"
  end

  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(role)
  barWidget.setColor(role)
  barWidget.setText(text)

  -- Errors are not repeated here: the notification already showed them, and
  -- the red icon marks the state.
  local rows = {
    { key = tr("tooltip.monitor"), value = monitorText(snapshot.monitor) },
  }
  if not offline then
    table.insert(rows, {
      key = tr("tooltip.left_click"),
      value = if target ~= nil then tr("tooltip.switch_to", { name = target.label }) else tr("errors.no_quick_target"),
    })
    table.insert(rows, { key = tr("tooltip.right_click"), value = tr("tooltip.all_inputs") })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch(common.STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

-- Left click switches to the quick-switch target and right click opens the
-- input menu, but neither does anything while the monitor is gone: there is
-- nothing to switch. Not bound in [widget.actions], because a binding there
-- would always run and skip this check. Hotkeys go to the service directly
-- and still work, which is the way back after switching away.
function onClick()
  if not common.disconnected(snapshot) then
    common.request("quick")
  end
end

function onRightClick()
  if not common.disconnected(snapshot) then
    noctalia.togglePanel("robostyle/monitor-input-switch:menu")
  end
end

-- Settings are re-read on every render; no polling needed otherwise.
function update()
  noctalia.setUpdateInterval(60000)
  render()
end

render()
