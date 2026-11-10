--!nonstrict
-- monitor-input-switch menu: the input list that opens under the bar button.
--
--   noctalia msg panel-toggle robostyle/monitor-input-switch:menu
--
-- One row per configured input. The last input this machine sent is
-- highlighted; the quick-switch target carries a bolt. Picking a row asks the
-- service to switch and closes the menu.

local common = require("./common.luau")

local snapshot = nil

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function inputRow(input)
  local active = snapshot.current == input.id
  local isQuick = snapshot.quick == input.id
  return ui.row({ key = "row-" .. input.id, gap = 4, align = "center" }, {
    ui.button({
      key = "in-" .. input.id .. (if active then "-on" else ""),
      glyph = input.glyph,
      text = input.label,
      variant = if active then "primary" else "ghost",
      contentAlign = "start",
      enabled = not snapshot.busy,
      flexGrow = 1,
      onClick = function()
        common.request("switch", input.id)
        panel.close()
      end,
    }),
    ui.glyph({
      key = "quick-" .. input.id,
      name = "bolt",
      size = 14,
      color = "on_surface_variant",
      opacity = if isQuick then 1 else 0,
    }),
  })
end

local function footer()
  local mon = snapshot.monitor
  local text
  local color = "on_surface_variant"
  if snapshot.error ~= nil then
    text = snapshot.error
    color = "error"
  elseif mon == nil then
    text = tr("status.no_monitor")
  else
    local parts = {}
    if mon.connector ~= nil then
      table.insert(parts, mon.connector)
    end
    table.insert(parts, `i2c-{mon.bus}`)
    text = table.concat(parts, " · ")
    if not mon.live then
      text = text .. " " .. tr("status.last_known")
    end
  end
  return ui.row({ key = "footer", gap = 6, align = "center" }, {
    ui.label({ text = text, fontSize = 11, color = color, maxLines = 3, flexGrow = 1 }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.settings"),
      onClick = function()
        panel.close()
        noctalia.openSettings()
      end,
    }),
  })
end

local function render()
  local children = {}
  if type(snapshot) ~= "table" then
    table.insert(children, ui.label({ text = tr("status.starting"), color = "on_surface_variant" }))
  elseif #snapshot.inputs == 0 then
    table.insert(children, ui.label({ text = tr("errors.no_inputs"), color = "error", maxLines = 3 }))
    table.insert(children, footer())
  else
    local rows = {}
    for _, input in ipairs(snapshot.inputs) do
      table.insert(rows, inputRow(input))
    end
    table.insert(children, ui.scroll({ key = "inputs", flexGrow = 1, gap = 4 }, rows))
    table.insert(children, ui.separator({}))
    table.insert(children, footer())
  end
  panel.render(ui.column({ flexGrow = 1, gap = 4, align = "stretch" }, children))
end

noctalia.state.watch(common.STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function onOpen(_context)
  snapshot = noctalia.state.get(common.STATE_KEY)
  render()
end
