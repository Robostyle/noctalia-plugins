--!nonstrict
-- monitor-input-switch bar widget: renders the snapshot the service publishes.
--
-- Clicks are declared in plugin.toml [widget.actions], so they can be remapped
-- from the bar's gesture settings:
--   left  -> plugin robostyle/monitor-input-switch:service all quick
--   right -> panel-toggle robostyle/monitor-input-switch:menu

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

  local text = ""
  if mode == "target" and target ~= nil then
    text = `→ {target.label}`
  elseif mode == "current" and current ~= nil then
    text = current.label
  end

  local role = "on_surface"
  if snapshot.error ~= nil then
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

  local rows = {
    { key = tr("tooltip.monitor"), value = monitorText(snapshot.monitor) },
    { key = tr("tooltip.last_sent"), value = if current ~= nil then current.label else tr("status.unknown") },
    {
      key = tr("tooltip.left_click"),
      value = if target ~= nil then tr("tooltip.switch_to", { name = target.label }) else tr("errors.no_quick_target"),
    },
    { key = tr("tooltip.right_click"), value = tr("tooltip.all_inputs") },
  }
  if snapshot.error ~= nil then
    table.insert(rows, 1, { key = tr("tooltip.error"), value = snapshot.error })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch(common.STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

-- Settings are re-read on every render; no polling needed otherwise.
function update()
  noctalia.setUpdateInterval(60000)
  render()
end

render()
