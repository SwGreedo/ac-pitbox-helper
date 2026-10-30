-- Pitbox Helper  -  pit, tyre and fuel overlay for Assetto Corsa (Custom Shaders Patch Lua app)
--
--   * Pit limiter / pit lane / in-box status and speed against the pit limit
--   * Per tyre: wear remaining %, inner/middle/outer temperature, pressure, laps on the set
--   * Temperature colouring per tread zone: blue cold, white in window, amber warm, red hot
--   * Fuel: burn per lap (measured over your last laps), laps of fuel left, fuel to add
--   * Warning strip: hot / cold tyres, worn tyres, hot brakes, low fuel -> "BOX THIS LAP"

local settings = ac.storage({
  tempUnit = 'C',        -- 'C' or 'F'
  speedUnit = 'MPH',     -- 'KMH' or 'MPH'
  pressUnit = 'PSI',     -- 'PSI' or 'BAR'
  optTemp = 0,           -- tyre optimum °C, 0 = read from the car (fallback 85)
  window = 12,           -- ± °C counted as "in the window"
  wearWarn = 30,         -- % remaining that triggers a warning
  brakeWarn = 750,       -- °C brake disc warning (if the car reports it)
  raceLaps = 0,          -- laps to fuel for, 0 = work it out from the session
  margin = 1.0,          -- extra laps of fuel
})

local WHEEL = { [0] = 'FL', 'FR', 'RL', 'RR' }

-- ---------------------------------------------------------------- helpers
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function safe(f, ...) local ok, r = pcall(f, ...); if ok then return r end end
local function field(obj, ...)
  for _, k in ipairs({ ... }) do
    local ok, v = pcall(function() return obj[k] end)
    if ok and v ~= nil then return v end
  end
end

local function tempStr(c)
  if not c then return '--' end
  if settings.tempUnit == 'F' then return string.format('%.0fF', c * 9 / 5 + 32) end
  return string.format('%.0fC', c)
end
local function speedVal(kmh) return settings.speedUnit == 'MPH' and kmh * 0.621371 or kmh end
local function pressStr(psi)
  if not psi or psi <= 0 then return '--' end
  if settings.pressUnit == 'BAR' then return string.format('%.2f', psi * 0.0689476) end
  return string.format('%.1f', psi)
end

-- ---------------------------------------------------------------- state
local fuel = { lapStart = nil, burns = {}, lastLap = nil, avgLap = nil, lapTimes = {} }
local tyres = { laps = 0, lastWear = nil }
local warnings = {}
local view = {}       -- numbers prepared in update(), drawn in windowMain()

local function avg(list)
  if #list == 0 then return nil end
  local s = 0
  for _, v in ipairs(list) do s = s + v end
  return s / #list
end
local function push(list, v, n) list[#list + 1] = v; while #list > n do table.remove(list, 1) end end

-- ---------------------------------------------------------------- update
function script.update(dt)
  local car = ac.getCar(0)
  if not car then return end
  local sim = ac.getSim()

  local lapCount = car.lapCount or 0
  local f = car.fuel or 0

  -- lap boundary: measure burn and tyre laps
  if fuel.lastLap == nil then
    fuel.lastLap, fuel.lapStart = lapCount, f
  elseif lapCount ~= fuel.lastLap then
    if lapCount == fuel.lastLap + 1 then
      local used = (fuel.lapStart or f) - f
      local lt = car.previousLapTimeMs or 0
      if used > 0.05 and not fuel.refuelled then push(fuel.burns, used, 5) end
      if lt > 10000 then push(fuel.lapTimes, lt, 5) end
      tyres.laps = tyres.laps + 1
    end
    fuel.lastLap, fuel.lapStart, fuel.refuelled = lapCount, f, false
  end
  if fuel.lastFuel and f > fuel.lastFuel + 0.2 then fuel.refuelled = true; fuel.lapStart = f end
  fuel.lastFuel = f

  -- tyres
  local opt = settings.optTemp > 0 and settings.optTemp or nil
  local wheels = {}
  local wearSum = 0
  for i = 0, 3 do
    local w = car.wheels and car.wheels[i]
    local d = { name = WHEEL[i] }
    if w then
      local wear = field(w, 'tyreWear')
      d.wear = wear and clamp((1 - wear) * 100, 0, 100) or nil
      d.ti = field(w, 'tyreInsideTemperature')
      d.tm = field(w, 'tyreMiddleTemperature')
      d.to = field(w, 'tyreOutsideTemperature')
      d.core = field(w, 'tyreCoreTemperature')
      d.press = field(w, 'tyrePressure')
      d.brake = field(w, 'discTemperature', 'brakeTemperature')
      d.opt = opt or field(w, 'tyreOptimumTemperature') or 85
      if d.opt <= 0 then d.opt = 85 end
      wearSum = wearSum + (wear or 0)
    end
    wheels[i] = d
  end
  -- new set fitted: average wear drops
  if tyres.lastWear and wearSum < tyres.lastWear - 0.08 then tyres.laps = 0 end
  tyres.lastWear = wearSum
  view.wheels = wheels

  -- fuel numbers
  local burn = avg(fuel.burns) or field(car, 'fuelPerLap')
  if burn and burn <= 0 then burn = nil end
  local lapsOfFuel = burn and f / burn or nil

  local lapsLeft
  local lapFrac = clamp(car.splinePosition or 0, 0, 1)
  if settings.raceLaps > 0 then
    lapsLeft = settings.raceLaps - lapCount - lapFrac
  else
    local sess = safe(function() return ac.getSession(sim.currentSessionIndex) end)
    local total = sess and field(sess, 'laps')
    if total and total > 0 then
      lapsLeft = total - lapCount - lapFrac
    else
      local left = sim and field(sim, 'sessionTimeLeft')
      local lapMs = avg(fuel.lapTimes) or ((car.bestLapTimeMs or 0) > 0 and car.bestLapTimeMs) or nil
      if left and left > 0 and lapMs then lapsLeft = math.ceil(left / lapMs) + 1 - lapFrac end
    end
  end
  if lapsLeft and lapsLeft < 0 then lapsLeft = 0 end

  local toAdd
  if burn and lapsLeft then
    toAdd = math.max(0, (lapsLeft + settings.margin) * burn - f)
    local cap = (car.maxFuel or 0) - f
    if cap > 0 then toAdd = math.min(toAdd, cap) end
  end
  view.fuel, view.burn, view.lapsOfFuel, view.lapsLeft, view.toAdd = f, burn, lapsOfFuel, lapsLeft, toAdd

  -- pit status
  view.limiter = field(car, 'pitLimiterEnabled', 'manualPitsSpeedLimiterEnabled', 'speedLimiterInAction') and true or false
  view.inBox = field(car, 'isInPit') and true or false
  view.inLane = field(car, 'isInPitlane') and true or false
  view.speed = car.speedKmh or 0
  view.limit = (sim and field(sim, 'pitsSpeedLimit')) or 80
  view.tyreLaps = tyres.laps

  -- warnings (most serious first)
  warnings = {}
  local boxNow = false
  for i = 0, 3 do
    local d = wheels[i]
    if d.ti then
      local hottest = math.max(d.ti, d.tm or d.ti, d.to or d.ti)
      local coolest = math.min(d.ti, d.tm or d.ti, d.to or d.ti)
      if hottest > d.opt + settings.window * 2 then
        warnings[#warnings + 1] = { 3, d.name .. ' OVERHEATING  ' .. tempStr(hottest) }
      elseif hottest > d.opt + settings.window then
        warnings[#warnings + 1] = { 2, d.name .. ' HOT  ' .. tempStr(hottest) }
      elseif coolest < d.opt - settings.window * 2 and view.speed > 30 then
        warnings[#warnings + 1] = { 1, d.name .. ' COLD  ' .. tempStr(coolest) }
      end
      -- camber/pressure hint: big spread across the tread
      if d.to and math.abs(d.ti - d.to) > 20 then
        warnings[#warnings + 1] = { 1, d.name .. ' TEMP SPREAD ' .. string.format('%.0f', math.abs(d.ti - d.to)) .. '°C' }
      end
    end
    if d.wear and d.wear < settings.wearWarn then
      warnings[#warnings + 1] = { d.wear < settings.wearWarn / 2 and 3 or 2, d.name .. ' WORN  ' .. string.format('%.0f%%', d.wear) }
      if d.wear < settings.wearWarn / 2 then boxNow = true end
    end
    if d.brake and d.brake > settings.brakeWarn then
      warnings[#warnings + 1] = { 2, d.name .. ' BRAKE HOT  ' .. tempStr(d.brake) }
    end
  end
  if lapsOfFuel and lapsLeft and lapsOfFuel < lapsLeft then
    if lapsOfFuel < 1.3 then
      boxNow = true
      warnings[#warnings + 1] = { 3, string.format('FUEL  %.1f LAPS LEFT', lapsOfFuel) }
    elseif lapsOfFuel < 3 then
      warnings[#warnings + 1] = { 2, string.format('FUEL  %.1f LAPS LEFT', lapsOfFuel) }
    end
  end
  table.sort(warnings, function(a, b) return a[1] > b[1] end)
  view.boxNow = boxNow and not view.inLane
end

-- ---------------------------------------------------------------- drawing
local C = {
  panel  = rgbm(0.10, 0.105, 0.115, 0.93),
  stripe = rgbm(1, 1, 1, 0.03),
  cell   = rgbm(0.06, 0.065, 0.075, 1),
  edge   = rgbm(1, 1, 1, 0.10),
  green  = rgbm(0.05, 0.70, 0.18, 1),
  green2 = rgbm(0.25, 0.85, 0.35, 1),
  blue   = rgbm(0.10, 0.60, 1.00, 1),
  blue2  = rgbm(0.45, 0.78, 1.00, 1),
  amber  = rgbm(1.00, 0.62, 0.10, 1),
  red    = rgbm(0.92, 0.12, 0.12, 1),
  red2   = rgbm(1.00, 0.40, 0.40, 1),
  grey   = rgbm(0.28, 0.29, 0.31, 1),
  grey2  = rgbm(0.42, 0.43, 0.45, 1),
  white  = rgbm(0.97, 0.97, 0.97, 1),
  dim    = rgbm(0.55, 0.56, 0.58, 1),
  cold   = rgbm(0.35, 0.65, 1.00, 1),
  black  = rgbm(0.02, 0.02, 0.025, 1),
}

local function text(str, size, x, y, col, align)
  local w = ui.measureDWriteText(str, size).x
  if align == 'right' then x = x - w elseif align == 'center' then x = x - w / 2 end
  ui.dwriteDrawText(str, size, vec2(x, y), col)
end

local function box(x1, y1, x2, y2, fill, border, r, b)
  ui.drawRectFilled(vec2(x1, y1), vec2(x2, y2), border, r)
  ui.drawRectFilled(vec2(x1 + b, y1 + b), vec2(x2 - b, y2 - b), fill, math.max(0, r - b))
end

local function carbonRect(x1, y1, x2, y2, spacing, col, thick)
  local kk = x1 - y2
  while kk < x2 - y1 do
    local xa, xb = math.max(x1, y1 + kk), math.min(x2, y2 + kk)
    if xb > xa then ui.drawLine(vec2(xa, xa - kk), vec2(xb, xb - kk), col, thick) end
    kk = kk + spacing
  end
end

local function zoneColour(t, opt)
  if not t then return C.grey2 end
  if t < opt - settings.window * 2 then return C.cold end
  if t < opt - settings.window then return C.blue2 end
  if t <= opt + settings.window then return C.white end
  if t <= opt + settings.window * 2 then return C.amber end
  return C.red
end

local function wearColour(w)
  if not w then return C.dim end
  if w < settings.wearWarn / 2 then return C.red2 end
  if w < settings.wearWarn then return C.amber end
  return C.white
end

-- one tyre block; left = true for left-hand tyres (outside edge on the left)
local function drawTyre(d, cx, y, s, left)
  local function S(v) return v * s end
  -- wear % above the tyre
  text(d.wear and string.format('%.0f%%', d.wear) or '--%', S(22), cx, y, wearColour(d.wear), 'center')

  -- the tyre: three tread zones, outer zone on the outside edge
  local tw, th = S(50), S(84)
  local x1, y1 = cx - tw / 2, y + S(30)
  local zones
  if left then zones = { d.to, d.tm, d.ti } else zones = { d.ti, d.tm, d.to } end
  local zw = tw / 3
  ui.drawRectFilled(vec2(x1 - S(3), y1 - S(3)), vec2(x1 + tw + S(3), y1 + th + S(3)), C.black, S(15))
  ui.drawRectFilled(vec2(x1, y1), vec2(x1 + zw + S(6), y1 + th), zoneColour(zones[1], d.opt), S(12))
  ui.drawRectFilled(vec2(x1 + 2 * zw - S(6), y1), vec2(x1 + tw, y1 + th), zoneColour(zones[3], d.opt), S(12))
  ui.drawRectFilled(vec2(x1 + zw, y1), vec2(x1 + 2 * zw, y1 + th), zoneColour(zones[2], d.opt), 0)
  ui.drawLine(vec2(x1 + zw, y1), vec2(x1 + zw, y1 + th), C.black, S(3))
  ui.drawLine(vec2(x1 + 2 * zw, y1), vec2(x1 + 2 * zw, y1 + th), C.black, S(3))

  -- outside edge: laps on this set and pressure
  local sx, al = x1 + tw + S(12), nil
  if left then sx, al = x1 - S(12), 'right' end
  text(tostring(view.tyreLaps or 0) .. 'L', S(16), sx, y1 + S(14), C.dim, al)
  text(pressStr(d.press), S(16), sx, y1 + S(42), C.dim, al)
  text(settings.pressUnit, S(10), sx, y1 + S(61), C.dim, al)

  -- zone temps below, same order as the stripes, then core
  local ty = y1 + th + S(8)
  for z = 1, 3 do
    text(tempStr(zones[z]), S(14), cx + (z - 2) * S(41), ty, zoneColour(zones[z], d.opt), 'center')
  end
  text('CORE ' .. tempStr(d.core), S(11), cx, ty + S(19), zoneColour(d.core, d.opt), 'center')
end

local BASE_W, BASE_H = 340, 660

function script.windowMain(dt)
  local size = ui.windowSize()
  local s = math.min(size.x / BASE_W, size.y / BASE_H)
  local function S(v) return v * s end
  local W = BASE_W * s
  local t = os.clock()

  ui.pushDWriteFont('Segoe UI;Weight=Bold')

  ui.drawRectFilled(vec2(0, 0), vec2(W, S(BASE_H)), C.panel, S(10))
  carbonRect(S(4), S(4), W - S(4), S(BASE_H - 4), S(5), C.stripe, S(1.3))

  -- 1. limiter banner
  local m = S(10)
  if view.limiter then
    box(m, S(10), W - m, S(64), C.green, C.green2, S(3), S(3))
    text('PIT LIMITER ON', S(27), W / 2, S(19), C.white, 'center')
  elseif view.inLane then
    local flash = math.floor(t * 4) % 2 == 0
    box(m, S(10), W - m, S(64), flash and C.red or rgbm(0.5, 0.06, 0.06, 1), C.red2, S(3), S(3))
    text('LIMITER OFF', S(27), W / 2, S(19), C.white, 'center')
  else
    box(m, S(10), W - m, S(64), C.grey, C.grey2, S(3), S(3))
    text('PIT LIMITER OFF', S(27), W / 2, S(19), C.dim, 'center')
  end

  -- 2. status bar
  local status, scol, sborder = 'ON TRACK', C.cell, C.edge
  if view.inBox then status, scol, sborder = 'IN BOX', C.blue, C.blue2
  elseif view.inLane then status, scol, sborder = 'PIT LANE', rgbm(0.75, 0.45, 0.05, 1), C.amber
  elseif view.boxNow then
    status = 'BOX THIS LAP'
    scol = (math.floor(t * 3) % 2 == 0) and C.red or rgbm(0.5, 0.06, 0.06, 1)
    sborder = C.red2
  end
  box(m, S(70), W - m, S(104), scol, sborder, S(2), S(2.5))
  text(status, S(19), W / 2, S(75), C.white, 'center')

  -- 3. speed vs pit limit
  local half = W / 2
  box(m, S(108), half - S(1), S(142), C.cell, C.edge, S(2), S(1.5))
  box(half + S(1), S(108), W - m, S(142), C.cell, C.edge, S(2), S(1.5))
  local spd, spdCol
  if view.inLane or view.inBox then
    local over = speedVal(view.speed - view.limit)
    spd = string.format('%+.1f', over)
    spdCol = over > 0.5 and C.red2 or C.white
  else
    spd = string.format('%.0f', speedVal(view.speed or 0))
    spdCol = C.white
  end
  text(spd, S(19), half / 2 + m / 2, S(113), spdCol, 'center')
  text(settings.speedUnit, S(19), half + (W - m - half) / 2, S(113), C.white, 'center')

  -- 4. tyres
  local wh = view.wheels or {}
  local lx, rx = S(92), W - S(92)
  if wh[0] then
    drawTyre(wh[0], lx, S(150), s, true)
    drawTyre(wh[1], rx, S(150), s, false)
    drawTyre(wh[2], lx, S(314), s, true)
    drawTyre(wh[3], rx, S(314), s, false)
  end

  -- 5. fuel
  local fy = S(486)
  box(m, fy, W - m, fy + S(86), C.cell, C.edge, S(3), S(1.5))
  local cols = {
    { 'FUEL', view.fuel and string.format('%.1f L', view.fuel) or '--' },
    { 'BURN / LAP', view.burn and string.format('%.2f L', view.burn) or '--' },
    { 'LAPS OF FUEL', view.lapsOfFuel and string.format('%.1f', view.lapsOfFuel) or '--' },
    { 'ADD AT STOP', view.toAdd and string.format('+%.1f L', view.toAdd) or '--' },
  }
  for i, c in ipairs(cols) do
    local col = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    local cx = m + (W - 2 * m) * (col * 0.5 + 0.25)
    local cy = fy + S(6) + row * S(40)
    text(c[1], S(11), cx, cy, C.dim, 'center')
    local vc = C.white
    if i == 3 and view.lapsOfFuel and view.lapsLeft and view.lapsOfFuel < view.lapsLeft then
      vc = view.lapsOfFuel < 1.3 and C.red2 or C.amber
    end
    if i == 4 and view.toAdd and view.toAdd > 0 then vc = C.green2 end
    text(c[2], S(20), cx, cy + S(12), vc, 'center')
  end
  if view.lapsLeft then
    text(string.format('%.1f laps to go', view.lapsLeft), S(10), W - m - S(6), fy + S(87), C.dim, 'right')
  end

  -- 6. warnings
  local wy = S(588)
  if #warnings == 0 then
    text('ALL GOOD', S(14), W / 2, wy + S(20), C.dim, 'center')
  else
    for i = 1, math.min(3, #warnings) do
      local w = warnings[i]
      local wc = w[1] == 3 and C.red2 or (w[1] == 2 and C.amber or C.blue2)
      text(w[2], S(15), W / 2, wy + (i - 1) * S(21), wc, 'center')
    end
  end

  ui.popDWriteFont()
end

-- ---------------------------------------------------------------- settings
local function cycle(label, key, options)
  if ui.button(label .. ': ' .. tostring(settings[key]) .. '##' .. key) then
    local idx = 1
    for i, o in ipairs(options) do if o == settings[key] then idx = i end end
    settings[key] = options[(idx % #options) + 1]
  end
end

function script.windowSettings(dt)
  cycle('Temperature', 'tempUnit', { 'C', 'F' })
  ui.sameLine()
  cycle('Speed', 'speedUnit', { 'KMH', 'MPH' })
  ui.sameLine()
  cycle('Pressure', 'pressUnit', { 'PSI', 'BAR' })
  ui.separator()
  local v, c
  v, c = ui.slider('##opt', settings.optTemp, 0, 120, settings.optTemp > 0 and 'Tyre optimum: %.0f °C' or 'Tyre optimum: from car')
  if c then settings.optTemp = math.floor(v + 0.5) end
  v, c = ui.slider('##win', settings.window, 4, 25, 'Temp window: ±%.0f °C')
  if c then settings.window = v end
  v, c = ui.slider('##wear', settings.wearWarn, 5, 60, 'Wear warning below %.0f%%')
  if c then settings.wearWarn = v end
  v, c = ui.slider('##brake', settings.brakeWarn, 300, 1100, 'Brake warning above %.0f °C')
  if c then settings.brakeWarn = v end
  ui.separator()
  v, c = ui.slider('##laps', settings.raceLaps, 0, 200, settings.raceLaps > 0 and 'Fuel for %.0f laps' or 'Race length: from session')
  if c then settings.raceLaps = math.floor(v + 0.5) end
  v, c = ui.slider('##margin', settings.margin, 0, 3, 'Fuel margin: %.1f laps')
  if c then settings.margin = v end
  if ui.button('Reset fuel burn and tyre laps') then
    fuel.burns, fuel.lapTimes = {}, {}
    tyres.laps = 0
  end
end

-- exposed for testing only
script._debug = function() return view, warnings, fuel end
