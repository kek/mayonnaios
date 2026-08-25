-- weather: the sky at a place you name.
--
-- Ask for a place by name and it stays on the panel:
--
--   curl -X POST http://nerves.local/api/pickles/weather/call/show -d '["Kiruna"]'
--
-- Open-Meteo does the geocoding and the forecasting, both without an API
-- key, so there is no secret to keep here. Places live in storage, so the
-- panel comes back to the same sky after a reboot.

-- ---------------------------------------------------------------- state --

places = {}        -- [{name, label, region, lat, lon}], mirrored in storage
idx = 1            -- which place the panel is showing
wx = {}            -- idx -> decoded forecast, plus fetched_at / error
loading = false    -- a fetch is queued; the panel says so

local DEFAULT = {
  name = "Stockholm",
  label = "Stockholm",
  region = "Stockholm County, Sweden",
  lat = 59.3294,
  lon = 18.0687
}

local REFRESH_MS = 15 * 60 * 1000
local STALE_MS = 10 * 60 * 1000

-- ---------------------------------------------------------------- utils --

-- Byte by byte, and by number rather than by character class: this Lua's
-- %w matches the first byte of a UTF-8 "o with diaeresis" but not the
-- second, so a pattern-based encoder leaks a raw 0xC3 into the URL and
-- Malmo -- the real spelling of it -- never reaches the geocoder.
local function urlencode(s)
  s = tostring(s or "")
  local out = {}
  for i = 1, #s do
    local b = string.byte(s, i)
    if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
       or b == 45 or b == 46 or b == 95 or b == 126 then
      out[#out + 1] = string.char(b)
    else
      out[#out + 1] = string.format("%%%02X", b)
    end
  end
  return table.concat(out)
end

local function round(n)
  if type(n) ~= "number" then return nil end
  return math.floor(n + 0.5)
end

-- Temperatures print as whole degrees; a missing reading prints as a dash
-- rather than as the word "nil".
local function deg(n)
  local r = round(n)
  if not r then return "--" end
  return r .. "\194\176" -- U+00B0, spelled in bytes for the sandbox's Lua

end

-- Zeller, because os.date is not in the sandbox and the API hands back
-- plain ISO dates.
local DAYS = {"Sat", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri"}

local function weekday(iso)
  local y, m, d = string.match(tostring(iso or ""), "^(%d+)-(%d+)-(%d+)")
  if not y then return "?" end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m < 3 then
    m = m + 12
    y = y - 1
  end
  local k, j = y % 100, math.floor(y / 100)
  local h = (d + math.floor((13 * (m + 1)) / 5) + k + math.floor(k / 4)
             + math.floor(j / 4) + 5 * j) % 7
  return DAYS[h + 1] or "?"
end

-- WMO weather codes: the word for the sky, and the family of picture to
-- draw for it.
local CODES = {
  [0] = {"Clear sky", "sun"},
  [1] = {"Mainly clear", "sun"},
  [2] = {"Partly cloudy", "partly"},
  [3] = {"Overcast", "cloud"},
  [45] = {"Fog", "fog"},
  [48] = {"Rime fog", "fog"},
  [51] = {"Light drizzle", "drizzle"},
  [53] = {"Drizzle", "drizzle"},
  [55] = {"Dense drizzle", "drizzle"},
  [56] = {"Freezing drizzle", "drizzle"},
  [57] = {"Freezing drizzle", "drizzle"},
  [61] = {"Light rain", "rain"},
  [63] = {"Rain", "rain"},
  [65] = {"Heavy rain", "rain"},
  [66] = {"Freezing rain", "rain"},
  [67] = {"Freezing rain", "rain"},
  [71] = {"Light snow", "snow"},
  [73] = {"Snow", "snow"},
  [75] = {"Heavy snow", "snow"},
  [77] = {"Snow grains", "snow"},
  [80] = {"Light showers", "rain"},
  [81] = {"Showers", "rain"},
  [82] = {"Violent showers", "rain"},
  [85] = {"Snow showers", "snow"},
  [86] = {"Heavy snow showers", "snow"},
  [95] = {"Thunderstorm", "storm"},
  [96] = {"Thunderstorm, hail", "storm"},
  [99] = {"Thunderstorm, hail", "storm"}
}

local function describe(code)
  local e = CODES[code or -1]
  if e then return e[1], e[2] end
  return "Unknown sky", "cloud"
end

-- --------------------------------------------------------------- places --

local function save_places()
  mayo.storage.set("places", mayo.json.encode(places))
  mayo.storage.set("idx", idx)
end

local function load_places()
  local raw = mayo.storage.get("places")
  if type(raw) == "string" then
    local t = mayo.json.decode(raw)
    if type(t) == "table" and t[1] then places = t end
  end
  if not places[1] then places = {DEFAULT} end
  idx = tonumber(mayo.storage.get("idx")) or 1
  if idx < 1 or idx > #places then idx = 1 end
end

local function find_place(query)
  local want = string.lower(tostring(query or ""))
  for i, p in ipairs(places) do
    if string.lower(p.name) == want or string.lower(p.label) == want then
      return i, p
    end
  end
  return nil
end

local function geocode(query)
  if type(query) ~= "string" or query == "" then
    return nil, "give me a place name"
  end

  local url = "https://geocoding-api.open-meteo.com/v1/search?count=1"
    .. "&language=en&format=json&name=" .. urlencode(query)

  local body, status = mayo.http.get(url)
  if not body then return nil, "geocoding unreachable: " .. tostring(status) end
  if status ~= 200 then return nil, "geocoding answered " .. tostring(status) end

  local data = mayo.json.decode(body)
  if type(data) ~= "table" then return nil, "geocoding sent something odd" end

  local r = data.results and data.results[1]
  if not r or not r.latitude then
    return nil, "nowhere called '" .. query .. "'"
  end

  local region = r.admin1 or ""
  if r.country then
    region = (region ~= "" and (region .. ", ") or "") .. r.country
  end

  return {
    name = r.name,
    label = r.name,
    region = region,
    lat = r.latitude,
    lon = r.longitude
  }
end

-- -------------------------------------------------------------- fetching --

local function fetch(place)
  local url = "https://api.open-meteo.com/v1/forecast"
    .. "?latitude=" .. string.format("%.4f", place.lat)
    .. "&longitude=" .. string.format("%.4f", place.lon)
    .. "&current=temperature_2m,apparent_temperature,relative_humidity_2m"
    .. ",weather_code,wind_speed_10m,is_day"
    .. "&daily=weather_code,temperature_2m_max,temperature_2m_min"
    .. "&wind_speed_unit=ms&timezone=auto&forecast_days=4"

  local body, status = mayo.http.get(url)
  if not body then return nil, "forecast unreachable: " .. tostring(status) end
  if status ~= 200 then return nil, "forecast answered " .. tostring(status) end

  local data = mayo.json.decode(body)
  if type(data) ~= "table" or type(data.current) ~= "table" then
    return nil, "forecast sent something odd"
  end

  data.fetched_at = mayo.now_ms()
  return data
end

-- Refresh one slot, keeping the last good reading on the panel if the
-- network has gone away: a stale temperature beats a blank screen.
local function refresh(i)
  local place = places[i]
  if not place then return nil, "no place at " .. tostring(i) end

  local data, err = fetch(place)
  if not data then
    local held = wx[i]
    if held then
      held.error = err
    else
      wx[i] = {error = err}
    end
    mayo.log("weather: " .. place.label .. ": " .. err)
    return nil, err
  end

  data.error = nil
  wx[i] = data
  return data
end

local function stale(i)
  local d = wx[i]
  if not d or not d.fetched_at then return true end
  return (mayo.now_ms() - d.fetched_at) > STALE_MS
end

-- A button press should not sit through a ten-second HTTP timeout, so it
-- flips the panel to "loading" and lets a timer do the waiting. One at a
-- time: a mashed A button would otherwise spend the sixteen timers the
-- sandbox allows, and mayo.timer.once answers true either way, so hitting
-- that ceiling would strand the panel on "asking..." with no way to know.
local function queue_refresh()
  if loading then return end
  loading = true
  mayo.timer.once(250, "refresh_now")
end

-- --------------------------------------------------------- the summary --

local function summarise(i)
  local place, d = places[i], wx[i]
  if not place then return nil, "no place at " .. tostring(i) end
  if not d or not d.current then
    return {place = place and place.label, error = d and d.error or "no reading yet"}
  end

  local c = d.current
  local text = describe(c.weather_code)
  local out = {
    place = place.label,
    region = place.region,
    latitude = place.lat,
    longitude = place.lon,
    conditions = text,
    temperature_c = c.temperature_2m,
    feels_like_c = c.apparent_temperature,
    humidity_pct = c.relative_humidity_2m,
    wind_ms = c.wind_speed_10m,
    observed_at = c.time,
    timezone = d.timezone,
    error = d.error,
    forecast = {}
  }

  local daily = d.daily
  if type(daily) == "table" and type(daily.time) == "table" then
    for n = 1, #daily.time do
      out.forecast[n] = {
        date = daily.time[n],
        day = weekday(daily.time[n]),
        conditions = (describe(daily.weather_code and daily.weather_code[n])),
        high_c = daily.temperature_2m_max and daily.temperature_2m_max[n],
        low_c = daily.temperature_2m_min and daily.temperature_2m_min[n]
      }
    end
  end

  return out
end

-- ---------------------------------------------------------------- life --

function on_start()
  load_places()
  mayo.log("weather: showing " .. places[idx].label
           .. " (" .. #places .. " place(s) saved)")
  mayo.timer.every(REFRESH_MS, "tick")
  queue_refresh()
end

function tick()
  refresh(idx)
end

-- Also an action: POST .../call/refresh_now
function refresh_now()
  loading = false
  local data, err = refresh(idx)
  mayo.ui.redraw()
  if not data then return nil, err end
  return summarise(idx)
end

-- ------------------------------------------------------------- actions --

-- Put a place on the panel, adding it to the list if it is new.
-- curl -X POST .../call/show -d '["Kiruna"]'
function show(query)
  if query == nil then
    return summarise(idx)
  end

  local found = find_place(query)
  if found then
    idx = found
  else
    local place, err = geocode(query)
    if not place then return nil, err end
    table.insert(places, place)
    idx = #places
  end

  save_places()
  local data, err = refresh(idx)
  mayo.ui.redraw()
  if not data then return nil, err end
  return summarise(idx)
end

-- The reading for a place, without disturbing what the panel is showing.
-- curl -X POST .../call/weather -d '["Reykjavik"]'
function weather(query)
  if query == nil then return summarise(idx) end

  local found = find_place(query)
  if found then
    if stale(found) then refresh(found) end
    return summarise(found)
  end

  local place, err = geocode(query)
  if not place then return nil, err end

  local data
  data, err = fetch(place)
  if not data then return nil, err end

  -- Borrow a slot so summarise/1 can do the shaping, then hand it back.
  local slot = #places + 1
  places[slot], wx[slot] = place, data
  local out = summarise(slot)
  places[slot], wx[slot] = nil, nil
  return out
end

-- curl -X POST .../call/forget -d '["Kiruna"]'
function forget(query)
  local found = find_place(query)
  if not found then return nil, "not on the list: " .. tostring(query) end
  if #places == 1 then return nil, "that is the only place left" end

  table.remove(places, found)
  wx = {}
  if idx > #places then idx = #places end
  save_places()
  queue_refresh()
  return list()
end

-- curl -X POST .../call/list
function list()
  local out = {}
  for i, p in ipairs(places) do
    out[i] = {
      place = p.label,
      region = p.region,
      showing = (i == idx),
      temperature_c = wx[i] and wx[i].current and wx[i].current.temperature_2m
    }
  end
  return out
end

-- ------------------------------------------------------------- the face --

function on_button(button, pressed)
  if not pressed then return end

  if button == "right" or button == "r1" then
    idx = (idx % #places) + 1
    save_places()
    if stale(idx) then queue_refresh() end
  elseif button == "left" or button == "l1" then
    idx = ((idx - 2) % #places) + 1
    save_places()
    if stale(idx) then queue_refresh() end
  elseif button == "a" or button == "x" then
    queue_refresh()
  end
end

-- The pictures: circles, lines and a rectangle are the whole vocabulary,
-- so a cloud is three circles sitting on a slab.
local function sun(ops, cx, cy, s, color)
  ops[#ops + 1] = {kind = "circle", x = cx, y = cy, r = 20 * s,
                   color = color, fill = true}
  for n = 0, 7 do
    local a = n * math.pi / 4
    ops[#ops + 1] = {
      kind = "line",
      x1 = cx + math.floor(math.cos(a) * 27 * s),
      y1 = cy + math.floor(math.sin(a) * 27 * s),
      x2 = cx + math.floor(math.cos(a) * 36 * s),
      y2 = cy + math.floor(math.sin(a) * 36 * s),
      color = color,
      width = math.max(1, math.floor(3 * s))
    }
  end
end

local function cloud(ops, cx, cy, s, color)
  ops[#ops + 1] = {kind = "circle", x = cx - 15 * s, y = cy + 3 * s,
                   r = 13 * s, color = color, fill = true}
  ops[#ops + 1] = {kind = "circle", x = cx + 2 * s, y = cy - 8 * s,
                   r = 18 * s, color = color, fill = true}
  ops[#ops + 1] = {kind = "circle", x = cx + 19 * s, y = cy + 3 * s,
                   r = 13 * s, color = color, fill = true}
  ops[#ops + 1] = {kind = "rect", x = cx - 15 * s, y = cy + 2 * s,
                   w = 34 * s, h = 15 * s, color = color, fill = true}
end

local function streaks(ops, cx, cy, s, color, dx)
  for n = -1, 1 do
    local x = cx + n * 14 * s
    ops[#ops + 1] = {kind = "line", x1 = x, y1 = cy + 22 * s,
                     x2 = x - dx * s, y2 = cy + 36 * s,
                     color = color, width = math.max(1, math.floor(3 * s))}
  end
end

local function icon(ops, family, cx, cy, s, is_day)
  local sun_color = (is_day == false) and "light_gray" or "gold"

  if family == "sun" then
    sun(ops, cx, cy, s, sun_color)
  elseif family == "partly" then
    sun(ops, cx + 10 * s, cy - 12 * s, s * 0.7, sun_color)
    cloud(ops, cx, cy + 6 * s, s, "light_gray")
  elseif family == "cloud" then
    cloud(ops, cx, cy, s, "gray")
  elseif family == "fog" then
    cloud(ops, cx, cy - 6 * s, s, "gray")
    for n = 0, 2 do
      ops[#ops + 1] = {kind = "line", x1 = cx - 24 * s, y1 = cy + (16 + n * 9) * s,
                       x2 = cx + 24 * s, y2 = cy + (16 + n * 9) * s,
                       color = "light_gray", width = math.max(1, math.floor(3 * s))}
    end
  elseif family == "drizzle" then
    cloud(ops, cx, cy - 6 * s, s, "gray")
    streaks(ops, cx, cy - 6 * s, s, "cyan", 3)
  elseif family == "rain" then
    cloud(ops, cx, cy - 6 * s, s, "gray")
    streaks(ops, cx, cy - 6 * s, s, "blue", 6)
  elseif family == "snow" then
    cloud(ops, cx, cy - 6 * s, s, "light_gray")
    for n = -1, 1 do
      ops[#ops + 1] = {kind = "circle", x = cx + n * 14 * s, y = cy + 24 * s,
                       r = math.max(2, 4 * s), color = "white", fill = true}
    end
  elseif family == "storm" then
    cloud(ops, cx, cy - 6 * s, s, "dark_gray")
    ops[#ops + 1] = {kind = "line", x1 = cx + 6 * s, y1 = cy + 16 * s,
                     x2 = cx - 6 * s, y2 = cy + 28 * s,
                     color = "yellow", width = math.max(2, math.floor(4 * s))}
    ops[#ops + 1] = {kind = "line", x1 = cx - 6 * s, y1 = cy + 28 * s,
                     x2 = cx + 8 * s, y2 = cy + 40 * s,
                     color = "yellow", width = math.max(2, math.floor(4 * s))}
  end
end

local function ago(ms)
  local mins = math.floor((mayo.now_ms() - ms) / 60000)
  if mins < 1 then return "just now" end
  if mins == 1 then return "1 min ago" end
  if mins < 90 then return mins .. " min ago" end
  return math.floor(mins / 60) .. " h ago"
end

function on_draw()
  local ops = {
    {kind = "rect", x = 0, y = 0, w = mayo.ui.width, h = mayo.ui.height,
     color = "navy", fill = true}
  }

  local place, d = places[idx], wx[idx]

  ops[#ops + 1] = {kind = "text", x = 24, y = 46,
                   text = place and place.label or "no place",
                   size = 34, color = "gold"}
  if place and place.region and place.region ~= "" then
    ops[#ops + 1] = {kind = "text", x = 24, y = 72, text = place.region,
                     size = 16, color = "light_gray"}
  end
  if #places > 1 then
    ops[#ops + 1] = {kind = "text", x = 560, y = 46,
                     text = idx .. "/" .. #places, size = 20, color = "light_gray"}
  end
  ops[#ops + 1] = {kind = "line", x1 = 24, y1 = 88, x2 = 616, y2 = 88,
                   color = "gray", width = 2}

  local c = d and d.current

  if c then
    local text, family = describe(c.weather_code)
    icon(ops, family, 96, 172, 1.0, c.is_day ~= 0)

    ops[#ops + 1] = {kind = "text", x = 180, y = 196, text = deg(c.temperature_2m),
                     size = 68, color = "white"}
    ops[#ops + 1] = {kind = "text", x = 180, y = 232, text = text,
                     size = 24, color = "cyan"}
    ops[#ops + 1] = {kind = "text", x = 180, y = 262,
                     text = "feels like " .. deg(c.apparent_temperature),
                     size = 17, color = "light_gray"}
    ops[#ops + 1] = {kind = "text", x = 180, y = 286,
                     text = "wind " .. (round(c.wind_speed_10m) or "--") .. " m/s"
                            .. "   humidity " .. (round(c.relative_humidity_2m) or "--") .. "%",
                     size = 17, color = "light_gray"}
  else
    ops[#ops + 1] = {kind = "text", x = 24, y = 190,
                     text = loading and "asking the sky..." or "no reading yet",
                     size = 30, color = "light_gray"}
    if d and d.error then
      ops[#ops + 1] = {kind = "text", x = 24, y = 226, text = d.error,
                       size = 18, color = "orange"}
    end
  end

  -- The four-day strip.
  local daily = d and d.daily
  if type(daily) == "table" and type(daily.time) == "table" then
    ops[#ops + 1] = {kind = "line", x1 = 24, y1 = 318, x2 = 616, y2 = 318,
                     color = "gray", width = 2}

    for n = 1, math.min(4, #daily.time) do
      local x = 24 + (n - 1) * 148
      local _, family = describe(daily.weather_code and daily.weather_code[n])

      ops[#ops + 1] = {kind = "text", x = x + 4, y = 346,
                       text = (n == 1) and "Today" or weekday(daily.time[n]),
                       size = 20, color = "gold"}
      icon(ops, family, x + 30, 396, 0.45, true)
      ops[#ops + 1] = {kind = "text", x = x + 68, y = 388,
                       text = deg(daily.temperature_2m_max
                                  and daily.temperature_2m_max[n]),
                       size = 24, color = "white"}
      ops[#ops + 1] = {kind = "text", x = x + 68, y = 414,
                       text = deg(daily.temperature_2m_min
                                  and daily.temperature_2m_min[n]),
                       size = 18, color = "light_gray"}
    end
  end

  local foot = "A refresh"
  if #places > 1 then foot = foot .. "   L/R place" end
  if loading then
    foot = foot .. "   asking..."
  elseif d and d.error then
    foot = foot .. "   " .. d.error
  elseif d and d.fetched_at then
    foot = foot .. "   updated " .. ago(d.fetched_at)
  end
  ops[#ops + 1] = {kind = "text", x = 24, y = 466, text = foot,
                   size = 15, color = "gray"}

  return ops
end
