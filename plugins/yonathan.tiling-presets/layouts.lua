-- Custom Hyprland layouts for the Tiling Presets plugin. Loaded by bin/tiling-preset (live, through
-- hyprctl eval) and by the per-workspace files it saves, so it is safe to load more than once.
--
-- tp_tiles: rows (or columns) of the sizes a preset lists, e.g. 25 / 50 / 25 from top to bottom.
-- Windows fill the tiles in the order they were opened. With fewer windows than tiles the tiles
-- that are used share the whole area in the same proportions; with more, the extra windows share
-- the last tile, side by side (one above the other for columns).
--
-- The sizes are per workspace: TilingPresets.set("21", { axis = "y", tiles = { 25, 50, 25 } }),
-- or live with the layout message "set y 25,50,25" ("x" lays the tiles out side by side).
if _G.TilingPresets then
  return _G.TilingPresets
end

local M = { state = {} }
_G.TilingPresets = M

local DEFAULT_TILES = { 25, 50, 25 }

function M.set(workspace, opts)
  local key = tostring(workspace)
  M.state[key] = M.state[key] or {}
  for name, value in pairs(opts) do
    M.state[key][name] = value
  end
end

local function workspace_key(ctx)
  for _, target in ipairs(ctx.targets) do
    local window = target.window
    if window and window.workspace then
      return tostring(window.workspace.id)
    end
  end
end

hl.layout.register("tp_tiles", {
  recalculate = function(ctx)
    local count = #ctx.targets
    if count == 0 then
      return
    end

    local key = workspace_key(ctx)
    local state = (key and M.state[key]) or {}
    local sizes = state.tiles or DEFAULT_TILES
    local vertical = (state.axis or "y") == "y"
    local area = ctx.area

    local used = math.min(count, #sizes)
    local total = 0
    for i = 1, used do
      total = total + sizes[i]
    end

    local span = vertical and area.h or area.w
    local at = vertical and area.y or area.x

    for i = 1, used do
      local length = span * sizes[i] / total
      local box = vertical and { x = area.x, y = at, w = area.w, h = length }
        or { x = at, y = area.y, w = length, h = area.h }

      if i < used then
        ctx.targets[i]:place(box)
      else
        -- the last tile in use takes every window that has no tile of its own
        local rest = count - i + 1
        for j = 0, rest - 1 do
          ctx.targets[i + j]:place(vertical
            and { x = box.x + box.w * j / rest, y = box.y, w = box.w / rest, h = box.h }
            or { x = box.x, y = box.y + box.h * j / rest, w = box.w, h = box.h / rest })
        end
      end

      at = at + length
    end
  end,

  layout_msg = function(ctx, msg)
    local axis, list = msg:match("^set%s+([xy])%s+([%d,%.]+)")
    local key = workspace_key(ctx)

    if axis and key then
      local tiles = {}
      for number in list:gmatch("[^,]+") do
        table.insert(tiles, tonumber(number) or 0)
      end
      if #tiles > 0 then
        M.set(key, { axis = axis, tiles = tiles })
        return true
      end
    end

    return "tp_tiles: expected  set <x|y> <size,size,...>"
  end,
})

return M
