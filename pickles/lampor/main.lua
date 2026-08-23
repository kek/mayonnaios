-- lampor: talk Tuya local protocol 3.3 to wifi lamps, no cloud, no hub.
--
-- The device list (names, ids, ips and local keys) is not in this file:
-- local keys are secrets. Inject them once after install:
--
--   curl -X POST http://nerves.local/api/pickles/lampor/call/set_devices \
--     -d '[[{"name":"Bumling","id":"...","ip":"192.168.100.123","key":"16charlocalkey.."}, ...]]'
--
-- They land in mayo.storage and survive restarts and reinstalls.
--
-- Protocol 3.3 frames every command as
--   000055aa | seq | cmd | len | payload | crc32 | 0000aa55
-- with the JSON payload AES-128-ECB encrypted under the device's local key
-- (CONTROL additionally prefixed by "3.3" + 12 zero bytes). The sandbox has
-- no crypto, so the AES and CRC32 live here in Lua; `selftest` proves them
-- against the FIPS-197 and CRC32 known answers.

local bxor, band, rshift, lshift = bit32.bxor, bit32.band, bit32.rshift, bit32.lshift

-- -- bytes ---------------------------------------------------------------

local function be32(n)
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256)
end

local function rd32(s, i)
  local a, b, c, d = string.byte(s, i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function bytes_to_str(t)
  local cs = {}
  for i = 1, #t do cs[i] = string.char(t[i]) end
  return table.concat(cs)
end

-- -- crc32 (IEEE, reflected) ---------------------------------------------

local crc_table = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if band(c, 1) == 1 then c = bxor(rshift(c, 1), 0xEDB88320) else c = rshift(c, 1) end
  end
  crc_table[i] = c
end

local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = bxor(rshift(c, 8), crc_table[band(bxor(c, string.byte(s, i)), 0xFF)])
  end
  return bxor(c, 0xFFFFFFFF)
end

-- -- AES-128-ECB ----------------------------------------------------------

local sbox = {
  0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
  0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
  0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
  0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
  0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
  0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
  0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
  0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
  0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
  0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
  0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
  0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
  0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
  0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
  0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
  0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
}

local inv_sbox = {}
for i = 1, 256 do inv_sbox[sbox[i] + 1] = i - 1 end

local mul2, mul3, mul9, mul11, mul13, mul14 = {}, {}, {}, {}, {}, {}
for i = 0, 255 do
  local x2 = band(lshift(i, 1), 0xFF)
  if i >= 128 then x2 = bxor(x2, 0x1B) end
  mul2[i + 1] = x2
end
for i = 0, 255 do
  local x2 = mul2[i + 1]
  local x4 = mul2[x2 + 1]
  local x8 = mul2[x4 + 1]
  mul3[i + 1] = bxor(x2, i)
  mul9[i + 1] = bxor(x8, i)
  mul11[i + 1] = bxor(bxor(x8, x2), i)
  mul13[i + 1] = bxor(bxor(x8, x4), i)
  mul14[i + 1] = bxor(bxor(x8, x4), x2)
end

local rcon = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36 }

local function expand_key(key)
  local rk = { string.byte(key, 1, 16) }
  for i = 4, 43 do
    local t1, t2, t3, t4 = rk[i * 4 - 3], rk[i * 4 - 2], rk[i * 4 - 1], rk[i * 4]
    if i % 4 == 0 then
      t1, t2, t3, t4 = sbox[t2 + 1], sbox[t3 + 1], sbox[t4 + 1], sbox[t1 + 1]
      t1 = bxor(t1, rcon[i / 4])
    end
    local j = i * 4
    rk[j + 1] = bxor(rk[j - 15], t1)
    rk[j + 2] = bxor(rk[j - 14], t2)
    rk[j + 3] = bxor(rk[j - 13], t3)
    rk[j + 4] = bxor(rk[j - 12], t4)
  end
  return rk
end

-- State is flat and column-major like the spec's input order: byte i sits at
-- row i % 4, column (i - i % 4) / 4, which is what the shift-row index math
-- below assumes.
local function encrypt_block(b, rk)
  local s = {}
  for i = 1, 16 do s[i] = bxor(b[i], rk[i]) end
  for round = 1, 9 do
    local t = {}
    for i = 0, 15 do
      local r = i % 4
      local c = (i - r) / 4
      t[i + 1] = sbox[s[r + 4 * ((c + r) % 4) + 1] + 1]
    end
    local base = round * 16
    for c = 0, 3 do
      local i0 = c * 4 + 1
      local a0, a1, a2, a3 = t[i0], t[i0 + 1], t[i0 + 2], t[i0 + 3]
      s[i0]     = bxor(bxor(mul2[a0 + 1], mul3[a1 + 1]), bxor(bxor(a2, a3), rk[base + i0]))
      s[i0 + 1] = bxor(bxor(a0, mul2[a1 + 1]), bxor(bxor(mul3[a2 + 1], a3), rk[base + i0 + 1]))
      s[i0 + 2] = bxor(bxor(a0, a1), bxor(bxor(mul2[a2 + 1], mul3[a3 + 1]), rk[base + i0 + 2]))
      s[i0 + 3] = bxor(bxor(mul3[a0 + 1], a1), bxor(bxor(a2, mul2[a3 + 1]), rk[base + i0 + 3]))
    end
  end
  local out = {}
  for i = 0, 15 do
    local r = i % 4
    local c = (i - r) / 4
    out[i + 1] = bxor(sbox[s[r + 4 * ((c + r) % 4) + 1] + 1], rk[160 + i + 1])
  end
  return out
end

local function decrypt_block(b, rk)
  local s = {}
  for i = 1, 16 do s[i] = bxor(b[i], rk[160 + i]) end
  for round = 9, 1, -1 do
    local t = {}
    for i = 0, 15 do
      local r = i % 4
      local c = (i - r) / 4
      t[i + 1] = inv_sbox[s[r + 4 * ((c - r) % 4) + 1] + 1]
    end
    local base = round * 16
    for i = 1, 16 do t[i] = bxor(t[i], rk[base + i]) end
    for c = 0, 3 do
      local i0 = c * 4 + 1
      local a0, a1, a2, a3 = t[i0], t[i0 + 1], t[i0 + 2], t[i0 + 3]
      s[i0]     = bxor(bxor(mul14[a0 + 1], mul11[a1 + 1]), bxor(mul13[a2 + 1], mul9[a3 + 1]))
      s[i0 + 1] = bxor(bxor(mul9[a0 + 1], mul14[a1 + 1]), bxor(mul11[a2 + 1], mul13[a3 + 1]))
      s[i0 + 2] = bxor(bxor(mul13[a0 + 1], mul9[a1 + 1]), bxor(mul14[a2 + 1], mul11[a3 + 1]))
      s[i0 + 3] = bxor(bxor(mul11[a0 + 1], mul13[a1 + 1]), bxor(mul9[a2 + 1], mul14[a3 + 1]))
    end
  end
  local out = {}
  for i = 0, 15 do
    local r = i % 4
    local c = (i - r) / 4
    out[i + 1] = bxor(inv_sbox[s[r + 4 * ((c - r) % 4) + 1] + 1], rk[i + 1])
  end
  return out
end

local key_cache = {}
local function round_keys(key)
  if not key_cache[key] then key_cache[key] = expand_key(key) end
  return key_cache[key]
end

local function aes_encrypt(key, plain)
  local rk = round_keys(key)
  local pad = 16 - (#plain % 16)
  plain = plain .. string.rep(string.char(pad), pad)
  local out = {}
  for i = 1, #plain, 16 do
    out[#out + 1] = bytes_to_str(encrypt_block({ string.byte(plain, i, i + 15) }, rk))
  end
  return table.concat(out)
end

local function aes_decrypt(key, cipher)
  if #cipher == 0 or #cipher % 16 ~= 0 then return nil end
  local rk = round_keys(key)
  local out = {}
  for i = 1, #cipher, 16 do
    out[#out + 1] = bytes_to_str(decrypt_block({ string.byte(cipher, i, i + 15) }, rk))
  end
  local plain = table.concat(out)
  local pad = string.byte(plain, #plain)
  if not pad or pad < 1 or pad > 16 or pad > #plain then return nil end
  return string.sub(plain, 1, #plain - pad)
end

-- -- tuya 3.3 -------------------------------------------------------------

local CONTROL, DP_QUERY = 7, 10
local seqno = 0

local function ts()
  return string.format("%d", math.floor(mayo.now_ms() / 1000))
end

local function tuya_exchange(dev, cmd, body)
  seqno = seqno + 1
  local enc = aes_encrypt(dev.key, body)
  local payload = enc
  if cmd == CONTROL then
    payload = "3.3" .. string.rep(string.char(0), 12) .. enc
  end
  local head = string.char(0, 0, 0x55, 0xAA) .. be32(seqno) .. be32(cmd) .. be32(#payload + 8)
  local frame = head .. payload .. be32(crc32(head .. payload)) .. string.char(0, 0, 0xAA, 0x55)
  local reply, err = mayo.lan.tcp(dev.ip, 6668, frame, 700)
  if not reply then
    -- These lamps accept one TCP connection at a time and are slow to take
    -- a new one right after a close; back-to-back commands need one retry.
    mayo.sleep(600)
    reply, err = mayo.lan.tcp(dev.ip, 6668, frame, 700)
  end
  return reply, err
end

local function parse_frames(buf)
  local frames = {}
  local i = 1
  while i + 19 <= #buf do
    if rd32(buf, i) == 0x000055AA then
      local len = rd32(buf, i + 12)
      if len < 12 or i + 15 + len > #buf then break end
      frames[#frames + 1] = {
        cmd = rd32(buf, i + 8),
        rc = rd32(buf, i + 16),
        data = string.sub(buf, i + 20, i + 15 + len - 8),
      }
      i = i + 16 + len
    else
      i = i + 1
    end
  end
  return frames
end

-- Data may carry the "3.3" + 12 zero bytes prefix (pushes do, query replies
-- do not); either way what remains is AES under the device key.
local function decode_data(dev, data)
  if string.sub(data, 1, 3) == "3.3" then data = string.sub(data, 16) end
  local plain = aes_decrypt(dev.key, data)
  if not plain then return nil end
  return mayo.json.decode(plain)
end

local function query_dps(dev)
  local body = mayo.json.encode({ gwId = dev.id, devId = dev.id, uid = dev.id, t = ts() })
  local reply, err = tuya_exchange(dev, DP_QUERY, body)
  if not reply then return nil, err end
  for _, f in ipairs(parse_frames(reply)) do
    local obj = decode_data(dev, f.data)
    if obj and obj.dps then return obj.dps end
  end
  return nil, "no dps in reply"
end

local function send_dps(dev, dps)
  local body = mayo.json.encode({ devId = dev.id, gwId = dev.id, uid = dev.id, t = ts(), dps = dps })
  local reply, err = tuya_exchange(dev, CONTROL, body)
  if not reply then return nil, err end
  local frames = parse_frames(reply)
  if #frames == 0 then return nil, "no ack" end
  for _, f in ipairs(frames) do
    if f.cmd == CONTROL and f.rc ~= 0 then return nil, "device refused, rc " .. f.rc end
  end
  return true
end

-- -- device registry ------------------------------------------------------

-- Runtime caches; the durable list lives in storage under "devices".
lamp_on = {}     -- name -> true/false, last known
lamp_bright = {} -- name -> 10..1000, last known
switch_dp = {}   -- name -> "20" or "1", learned from a query

local function devices()
  return mayo.storage.get("devices") or {}
end

local function find_dev(name)
  if type(name) ~= "string" or name == "" then return nil, "which lamp?" end
  local want = string.lower(name)
  for _, d in ipairs(devices()) do
    if string.lower(d.name) == want then return d end
  end
  for _, d in ipairs(devices()) do
    if string.sub(string.lower(d.name), 1, #want) == want then return d end
  end
  return nil, "no lamp called " .. name
end

local function learn(dev, dps)
  if dps["20"] ~= nil then
    switch_dp[dev.name] = "20"
    lamp_on[dev.name] = dps["20"]
  elseif dps["1"] ~= nil then
    switch_dp[dev.name] = "1"
    lamp_on[dev.name] = dps["1"]
  end
  if type(dps["22"]) == "number" then lamp_bright[dev.name] = dps["22"] end
end

local function set_power(dev, on)
  local dp = switch_dp[dev.name]
  if not dp then
    local dps = query_dps(dev)
    if dps then learn(dev, dps) end
    dp = switch_dp[dev.name] or "20"
  end
  local ok, err = send_dps(dev, { [dp] = on })
  if not ok then return nil, err end
  lamp_on[dev.name] = on
  return true
end

-- -- actions --------------------------------------------------------------

-- One argument: the device list itself, [{name, id, ip, key}, ...].
function set_devices(list)
  if type(list) ~= "table" then return nil, "expected a list of devices" end
  local clean = {}
  for _, d in ipairs(list) do
    if type(d) ~= "table" or type(d.name) ~= "string" or type(d.id) ~= "string"
      or type(d.ip) ~= "string" or type(d.key) ~= "string" or #d.key ~= 16 then
      return nil, "each device needs name, id, ip and a 16-byte key"
    end
    clean[#clean + 1] = { name = d.name, id = d.id, ip = d.ip, key = d.key }
  end
  local ok, err = mayo.storage.set("devices", clean)
  if not ok then return nil, err end
  lamp_on, lamp_bright, switch_dp = {}, {}, {}
  mayo.log("device list set: " .. #clean .. " lamps")
  return #clean
end

function list()
  local out = {}
  for _, d in ipairs(devices()) do
    out[#out + 1] = { name = d.name, ip = d.ip, on = lamp_on[d.name] }
  end
  return out
end

function status(name)
  local dev, err = find_dev(name)
  if not dev then return nil, err end
  local dps, qerr = query_dps(dev)
  if not dps then return nil, qerr end
  learn(dev, dps)
  return dps
end

function on(name)
  local dev, err = find_dev(name)
  if not dev then return nil, err end
  return set_power(dev, true)
end

function off(name)
  local dev, err = find_dev(name)
  if not dev then return nil, err end
  return set_power(dev, false)
end

function toggle(name)
  local dev, err = find_dev(name)
  if not dev then return nil, err end
  local cur = lamp_on[dev.name]
  if cur == nil then
    local dps, qerr = query_dps(dev)
    if not dps then return nil, qerr end
    learn(dev, dps)
    cur = lamp_on[dev.name]
    if cur == nil then return nil, "lamp reports no switch dp" end
  end
  local ok, serr = set_power(dev, not cur)
  if not ok then return nil, serr end
  return not cur
end

-- 10..1000, the v2 brightness scale.
function brightness(name, value)
  local dev, err = find_dev(name)
  if not dev then return nil, err end
  if type(value) ~= "number" then return nil, "brightness needs a number 10..1000" end
  value = math.floor(math.max(10, math.min(1000, value)))
  local ok, serr = send_dps(dev, { ["22"] = value })
  if not ok then return nil, serr end
  lamp_bright[dev.name] = value
  return value
end

local function set_all(on_)
  local ok, failed = 0, {}
  for _, d in ipairs(devices()) do
    if set_power(d, on_) then ok = ok + 1 else failed[#failed + 1] = d.name end
  end
  return { ok = ok, failed = failed }
end

function all_on() return set_all(true) end
function all_off() return set_all(false) end

function refresh_all()
  local seen = 0
  for _, d in ipairs(devices()) do
    local dps = query_dps(d)
    if dps then
      learn(d, dps)
      seen = seen + 1
    else
      lamp_on[d.name] = nil
    end
  end
  mayo.ui.redraw()
  return seen
end

function selftest()
  local key = bytes_to_str({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 })
  local pt = { 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
               0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff }
  local want = { 0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
                 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a }
  local got = encrypt_block(pt, round_keys(key))
  for i = 1, 16 do
    if got[i] ~= want[i] then return nil, "AES known answer failed at byte " .. i end
  end
  local back = decrypt_block(got, round_keys(key))
  for i = 1, 16 do
    if back[i] ~= pt[i] then return nil, "AES decrypt mismatch at byte " .. i end
  end
  local msg = "the quick brown fox jumps over the lazy dog"
  if aes_decrypt(key, aes_encrypt(key, msg)) ~= msg then return nil, "padding roundtrip failed" end
  if crc32("123456789") ~= 0xCBF43926 then return nil, "CRC32 known answer failed" end
  return "aes + crc32 ok"
end

-- -- lifecycle ------------------------------------------------------------

refresh_at = 0

function on_start()
  mayo.log("lampor up, " .. #devices() .. " lamps configured")
  -- Warm the state one lamp at a time; a full sweep in one call would sit
  -- on the runner for seconds and make the buttons feel dead.
  mayo.timer.every(15000, "refresh_next")
  mayo.timer.once(1000, "refresh_next")
end

function refresh_next()
  local devs = devices()
  if #devs == 0 then return end
  refresh_at = (refresh_at % #devs) + 1
  local d = devs[refresh_at]
  local dps = query_dps(d)
  if dps then learn(d, dps) else lamp_on[d.name] = nil end
end

-- -- the face -------------------------------------------------------------

sel = 1
notice = nil

local function selected_dev()
  local devs = devices()
  if #devs == 0 then return nil end
  if sel > #devs then sel = #devs end
  return devs[sel]
end

local function nudge_brightness(dev, delta)
  local cur = lamp_bright[dev.name]
  if not cur then
    local dps = query_dps(dev)
    if dps then learn(dev, dps) end
    cur = lamp_bright[dev.name]
  end
  if not cur then
    notice = dev.name .. " has no brightness dp"
    return
  end
  local value = math.floor(math.max(10, math.min(1000, cur + delta)))
  if send_dps(dev, { ["22"] = value }) then
    lamp_bright[dev.name] = value
    notice = dev.name .. " brightness " .. value
  else
    notice = dev.name .. " did not answer"
  end
end

function on_button(button, pressed)
  if not pressed then return end
  local devs = devices()
  if #devs == 0 then return end
  if button == "up" then
    sel = (sel - 2) % #devs + 1
  elseif button == "down" then
    sel = sel % #devs + 1
  elseif button == "a" then
    local dev = selected_dev()
    local result, err = toggle(dev.name)
    if err then
      notice = dev.name .. ": " .. err
    else
      notice = dev.name .. (result and " on" or " off")
    end
  elseif button == "y" then
    local r = set_all(true)
    notice = "all on: " .. r.ok .. " ok, " .. #r.failed .. " silent"
  elseif button == "x" then
    local r = set_all(false)
    notice = "all off: " .. r.ok .. " ok, " .. #r.failed .. " silent"
  elseif button == "left" then
    nudge_brightness(selected_dev(), -150)
  elseif button == "right" then
    nudge_brightness(selected_dev(), 150)
  elseif button == "r1" then
    refresh_all()
    notice = "refreshed"
  end
end

function on_draw()
  local ops = {
    { kind = "rect", x = 0, y = 0, w = mayo.ui.width, h = mayo.ui.height, color = "black" },
    { kind = "text", x = 30, y = 44, text = "lampor", size = 32, color = "gold" },
    { kind = "line", x1 = 30, y1 = 58, x2 = 610, y2 = 58, color = "dark_gray" },
  }
  local devs = devices()
  if #devs == 0 then
    ops[#ops + 1] = { kind = "text", x = 30, y = 120, text = "no lamps configured", size = 24, color = "gray" }
    ops[#ops + 1] = { kind = "text", x = 30, y = 160, text = "POST /call/set_devices with the device list", size = 16, color = "dark_gray" }
    return ops
  end
  if sel > #devs then sel = #devs end
  -- Window of 12 rows around the cursor, for lists longer than the panel.
  local first = math.max(1, math.min(sel - 5, #devs - 11))
  local y = 92
  for i = first, math.min(#devs, first + 11) do
    local d = devs[i]
    local state = lamp_on[d.name]
    local state_text, state_color
    if state == true then
      state_text, state_color = "ON", "green"
    elseif state == false then
      state_text, state_color = "off", "gray"
    else
      state_text, state_color = "?", "dark_gray"
    end
    if i == sel then
      ops[#ops + 1] = { kind = "rect", x = 22, y = y - 20, w = 596, h = 27, color = "navy", fill = true }
    end
    ops[#ops + 1] = { kind = "text", x = 34, y = y, text = d.name, size = 20,
                      color = i == sel and "white" or "light_gray" }
    ops[#ops + 1] = { kind = "text", x = 470, y = y, text = state_text, size = 20, color = state_color }
    local b = lamp_bright[d.name]
    if b and state == true then
      ops[#ops + 1] = { kind = "text", x = 540, y = y, text = math.floor(b / 10) .. "%", size = 16, color = "teal" }
    end
    y = y + 28
  end
  if notice then
    ops[#ops + 1] = { kind = "text", x = 30, y = 442, text = notice, size = 16, color = "yellow" }
  end
  ops[#ops + 1] = { kind = "text", x = 30, y = 468,
                    text = "A toggle   Y all on   X all off   <> dim   R1 refresh", size = 16, color = "gray" }
  return ops
end
