--!nonstrict
-- Shared between the entries: state keys and the request channel.
--
-- Entries do not share Lua memory. The service publishes one snapshot table
-- under STATE_KEY; the panel and the tile ask it to switch by writing a request
-- under REQUEST_KEY. The nonce is monotonic across writers (each seeds from the
-- last request in the shared state), so the service never replays a stale
-- request after a hot reload.

local M = {}

M.STATE_KEY = "monitor_input_state"
M.REQUEST_KEY = "monitor_input_request"

-- action: "quick" (the configured quick-switch target) or "switch" (needs id).
function M.request(action: string, id: string?)
  local prev = noctalia.state.get(M.REQUEST_KEY)
  local nonce = (if type(prev) == "table" then tonumber(prev.nonce) or 0 else 0) + 1
  noctalia.state.set(M.REQUEST_KEY, { nonce = nonce, action = action, id = id })
end

-- The input entry for id in a published snapshot, or nil.
function M.find(snapshot, id: string?)
  if type(snapshot) ~= "table" or type(snapshot.inputs) ~= "table" or id == nil then
    return nil
  end
  for _, input in ipairs(snapshot.inputs) do
    if input.id == id then
      return input
    end
  end
  return nil
end

return M
