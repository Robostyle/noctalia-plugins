--!nonstrict
-- monitor-input-switch Control Center tile: one press sends the quick-switch target.
-- Add it from Settings -> Control Center shortcuts.

local common = require("./common.luau")

local snapshot = noctalia.state.get(common.STATE_KEY)

local function render()
  local target = common.find(snapshot, if type(snapshot) == "table" then snapshot.quick else nil)
  if target ~= nil then
    shortcut.setLabel(noctalia.tr("tooltip.switch_to", { name = target.label }))
  else
    shortcut.setLabel(noctalia.tr("title"))
  end
  shortcut.setIcon("arrows-exchange")
  shortcut.setActive(type(snapshot) == "table" and snapshot.busy == true)
  shortcut.setEnabled(target ~= nil and not (type(snapshot) == "table" and snapshot.busy == true))
end

noctalia.state.watch(common.STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function onClick()
  common.request("quick")
end

render()
