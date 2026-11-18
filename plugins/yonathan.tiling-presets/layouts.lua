-- Custom Hyprland layouts for the Tiling Presets plugin. Loaded by bin/tiling-preset (live, through
-- hyprctl eval) and by the per-workspace files it saves, so it is safe to load more than once.
--
-- tp_middle: the main window is a band across the middle of the workspace, and the other windows
-- are shared between a band above it and a band below it, side by side. It is the sideways
-- counterpart of Hyprland's "center" master layout, made for portrait monitors, where the center
-- layout would put the other windows left and right of a narrow main window.
--
-- The size of the main band is per workspace: TilingPresets.set("21", { ratio = 0.4 }), or live
-- with the layout message "ratio 0.4".
if _G.TilingPresets then
  return _G.TilingPresets
end

local M = { state = {} }
_G.TilingPresets = M

local function clamp(x, lo, hi)
  return math.max(lo, math.min(hi, x))
end

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

local function side_by_side(targets, band)
  for i, target in ipairs(targets) do
    target:place({
      x = band.x + band.w * (i - 1) / #targets,
      y = band.y,
      w = band.w / #targets,
      h = band.h,
    })
  end
end

hl.layout.register("tp_middle", {
  recalculate = function(ctx)
    local count = #ctx.targets
    if count == 0 then
      return
    end

    local area = ctx.area
    if count == 1 then
      ctx.targets[1]:place(area)
      return
    end

    local key = workspace_key(ctx)
    local ratio = clamp((key and M.state[key] and M.state[key].ratio) or 0.5, 0.1, 0.9)

    -- The first window is the main one. The next goes above it, the one after below, and so on.
    local above, below = {}, {}
    for i = 2, count do
      table.insert(i % 2 == 0 and above or below, ctx.targets[i])
    end

    -- With nothing below, the main window takes the lower part and the others sit above it.
    local main_h = area.h * ratio
    local band_h = (area.h - main_h) / 2
    if #below == 0 then
      band_h = area.h - main_h
      side_by_side(above, { x = area.x, y = area.y, w = area.w, h = band_h })
      ctx.targets[1]:place({ x = area.x, y = area.y + band_h, w = area.w, h = main_h })
      return
    end

    side_by_side(above, { x = area.x, y = area.y, w = area.w, h = band_h })
    ctx.targets[1]:place({ x = area.x, y = area.y + band_h, w = area.w, h = main_h })
    side_by_side(below, { x = area.x, y = area.y + band_h + main_h, w = area.w, h = band_h })
  end,

  layout_msg = function(ctx, msg)
    local command, arg = msg:match("^(%S+)%s*(.*)$")
    local key = workspace_key(ctx)

    if command == "ratio" and key then
      M.set(key, { ratio = clamp(tonumber(arg) or 0.5, 0.1, 0.9) })
      return true
    end

    return "tp_middle: expected ratio <0.1..0.9>"
  end,
})

return M
