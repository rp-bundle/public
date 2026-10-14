---rpf_inventory's HUD on a Gmod client: a small box in the corner staff
---chose, with the player's money, job and rank, and what other addons put
---on it, drawn every frame from the server's last answer. Shipped as
---`lua/rpf_inventory/hud.lua`.
rpf_inventory = rpf_inventory or {}

---The server's last answer, or nil while there is nothing to show.
---@type table?
local shown = nil

---Takes the server's answer for the next frames.
---@param hud table? The HUD, or nil to hide it.
function rpf_inventory.draw_hud(hud)
  shown = hud
end

---The lines of the HUD, each `{ label, value, fill }`, `fill` being how full
---a bar is, from 0 to 1, for a value with a `max`.
---@param hud table The HUD.
---@return { label: string, value: string, fill: number? }[] lines The lines.
local function lines_of(hud)
  local out = {}
  for _, account in ipairs(hud.money or {}) do
    out[#out + 1] = { label = account.account, value = string.Comma(account.balance) }
  end
  local job = hud.job
  if job then
    local where = job.employer and (job.name .. ", " .. job.employer) or job.name
    out[#out + 1] = { label = job.on_duty and "On duty" or "Job", value = tostring(where) }
    out[#out + 1] = { label = "Rank", value = tostring(job.rank) }
  end
  for _, extra in ipairs(hud.extras or {}) do
    local fill = extra.max and math.Clamp(extra.value / extra.max, 0, 1) or nil
    local value = extra.max and (math.Round(extra.value) .. " / " .. extra.max) or tostring(extra.value)
    out[#out + 1] = { label = extra.label, value = value, fill = fill }
  end
  return out
end

---Draws the HUD in its corner.
local function paint()
  if not shown then
    return
  end
  local lines = lines_of(shown)
  if #lines == 0 then
    return
  end
  local line_h, width, pad = 18, 200, 8
  local height = pad * 2
  for _, line in ipairs(lines) do
    height = height + line_h + (line.fill and 6 or 0)
  end
  local corner = shown.corner or "bottom_right"
  local x = corner:find("left", 1, true) and 20 or (ScrW() - width - 20)
  local y = corner:find("top", 1, true) and 20 or (ScrH() - height - 20)
  draw.RoundedBox(6, x, y, width, height, Color(16, 18, 24, 220))
  local at = y + pad
  for _, line in ipairs(lines) do
    draw.SimpleText(line.label, "DermaDefault", x + pad, at, Color(154, 160, 174))
    draw.SimpleText(line.value, "DermaDefault", x + width - pad, at, Color(232, 234, 240), TEXT_ALIGN_RIGHT)
    at = at + line_h
    if line.fill then
      draw.RoundedBox(2, x + pad, at - 2, width - pad * 2, 4, Color(255, 255, 255, 16))
      draw.RoundedBox(2, x + pad, at - 2, (width - pad * 2) * line.fill, 4, Color(106, 168, 255))
      at = at + 6
    end
  end
end

hook.Add("HUDPaint", "rpf_inventory", paint)
