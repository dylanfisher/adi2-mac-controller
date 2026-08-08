-- RME ADI-2 DAC Line-out volume control via Mac media keys.
--
-- Media keys (F10/F11/F12) are intercepted and consumed here, so macOS's own
-- system volume never changes -- only the DAC's own analog Line-out gain does.
--
-- Protocol: RME's documented MIDI SysEx format (MIDITable_ADI-2_230930.ods).
-- Header: 00 20 0D <DeviceID> <CommandID>. DeviceID 0x71 = ADI-2 DAC.
-- CommandID 0x02 = send parameter to device, 0x03 0x09 = request all settings.
-- Each parameter is a 3-byte container:
--   byte1: bits6..3 = channel address, bits2..0 = upper 3 bits of param index
--   byte2: bits6..5 = lower 2 bits of param index, bit4 = value bit11 (sign),
--          bits3..0 = value bits10..7
--   byte3: bits6..0 = value bits6..0
-- Line-out channel address = 3. Volume = param index 12, range -114.5..6.0 dB,
-- transmitted in 0.1dB integer units. Mute = param index 15 (0/1).
-- This encoding was verified against RME's own worked example (Phones34,
-- addr 9, idx 12, value -100 -> 4B 1F 1C) and against a live capture from
-- the actual DAC (addr 3, idx 12 decoded back to -49.0 dB as 1B 1C 16).

hs.autoLaunch(true)

local adi2 = {}

local LOG_PATH = os.getenv("HOME") .. "/.hammerspoon/adi2.log"
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
end
adi2.log = log

adi2.sendmidi = "/opt/homebrew/bin/sendmidi"
adi2.receivemidi = "/opt/homebrew/bin/receivemidi"
adi2.lineAddress = 3
adi2.volumeIndex = 12
adi2.muteIndex = 15
adi2.stepDb = 1.0
adi2.minDb = -114.5
adi2.maxDb = 6.0

adi2.defaultVolumeDb = -50.0

adi2.state = {
    volumeDb = nil,
    muted = false,
    port = nil,
}

-- The device doesn't reliably echo its settings dump back over MIDI on
-- request (confirmed by testing against real hardware: writes work, but
-- reads via "request all settings" don't reliably come back), so rather
-- than depend on a live query at every launch, the last known volume is
-- persisted locally (via hs.settings, backed by macOS preferences) and
-- restored on startup. This can drift from the DAC's actual volume if the
-- front-panel knob is turned while Hammerspoon isn't running.
function adi2.loadPersistedState()
    local savedDb = hs.settings.get("adi2.volumeDb")
    adi2.state.volumeDb = savedDb or adi2.defaultVolumeDb
    adi2.state.muted = hs.settings.get("adi2.muted") or false
end

function adi2.savePersistedState()
    hs.settings.set("adi2.volumeDb", adi2.state.volumeDb)
    hs.settings.set("adi2.muted", adi2.state.muted)
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

-- Finds the live ADI-2 DAC MIDI port name (it includes a serial number suffix
-- that can change device to device, so this can't be hardcoded).
function adi2.findPort()
    local out = hs.execute(adi2.sendmidi .. " list")
    if not out then return nil end
    for line in out:gmatch("[^\r\n]+") do
        if line:match("ADI%-2 DAC") then
            return trim(line)
        end
    end
    return nil
end

function adi2.encodeParam(address, index, value)
    local idx5 = index & 0x1F
    local upper3 = (idx5 >> 2) & 0x7
    local lower2 = idx5 & 0x3
    local byte1 = ((address & 0xF) << 3) | upper3

    local value12 = value & 0xFFF
    local signBit = (value12 >> 11) & 0x1
    local bits10_7 = (value12 >> 7) & 0xF
    local bits6_0 = value12 & 0x7F
    local byte2 = (lower2 << 5) | (signBit << 4) | bits10_7
    local byte3 = bits6_0

    return string.format("%02X", byte1), string.format("%02X", byte2), string.format("%02X", byte3)
end

function adi2.sendParam(address, index, value)
    if not adi2.state.port then
        hs.alert.show("ADI-2 DAC not found (sendmidi list)")
        return
    end
    local b1, b2, b3 = adi2.encodeParam(address, index, value)
    local args = {
        "dev", adi2.state.port,
        "syx", "hex", "00", "20", "0D", "71", "02", b1, b2, b3,
    }
    hs.task.new(adi2.sendmidi, nil, args):start()
end

function adi2.sendVolume(db)
    local raw = math.floor(db * 10 + 0.5)
    adi2.sendParam(adi2.lineAddress, adi2.volumeIndex, raw)
end

function adi2.sendMute(isMuted)
    adi2.sendParam(adi2.lineAddress, adi2.muteIndex, isMuted and 1 or 0)
end

-- Decodes a 3-byte param container (as hex strings) and returns
-- address, index, value -- or nil if these aren't a valid triplet.
local function decodeParam(b1, b2, b3)
    local n1, n2, n3 = tonumber(b1, 16), tonumber(b2, 16), tonumber(b3, 16)
    if not (n1 and n2 and n3) then return nil end
    local address = (n1 >> 3) & 0xF
    local upper3 = n1 & 0x7
    local lower2 = (n2 >> 5) & 0x3
    local index = (upper3 << 2) | lower2
    local signBit = (n2 >> 4) & 0x1
    local bits10_7 = n2 & 0xF
    local bits6_0 = n3 & 0x7F
    local value12 = (signBit << 11) | (bits10_7 << 7) | bits6_0
    if signBit == 1 then value12 = value12 - 4096 end
    return address, index, value12
end

local function parseVolumeAndMuteFromCapture(capture)
    local hexBytes = {}
    for b in capture:gmatch("%x%x") do
        table.insert(hexBytes, b)
    end

    -- receivemidi's "syx hex" output includes the leading "00 20 0D 71 01"
    -- SysEx header bytes interleaved with real triplets; decodeParam() on
    -- those header bytes just yields addresses/indexes that never match
    -- our targets, so a plain triplet scan across the whole byte stream
    -- is sufficient without explicitly stripping headers.
    local volumeDb, muted = nil, nil
    local i = 1
    while i + 2 <= #hexBytes do
        local address, index, value = decodeParam(hexBytes[i], hexBytes[i + 1], hexBytes[i + 2])
        if address == adi2.lineAddress and index == adi2.volumeIndex then
            volumeDb = value / 10.0
        elseif address == adi2.lineAddress and index == adi2.muteIndex then
            muted = (value == 1)
        end
        i = i + 3
    end
    return volumeDb, muted
end

-- Best-effort: requests all settings and listens briefly for a reply. In
-- testing, the device didn't reliably answer this request after the first
-- MIDI session following power-on, so this opportunistically corrects our
-- persisted state if a reply does arrive, but nothing else depends on it.
function adi2.syncFromDevice()
    if not adi2.state.port then return end

    local buffer = {}
    local captureTask = hs.task.new(
        adi2.receivemidi,
        nil,
        function(task, stdOut, stdErr)
            if stdOut then table.insert(buffer, stdOut) end
            return true
        end,
        { "dev", adi2.state.port, "syx", "hex" }
    )
    captureTask:start()

    hs.task.new(adi2.sendmidi, nil,
        { "dev", adi2.state.port, "syx", "hex", "00", "20", "0D", "71", "03", "09" }
    ):start()

    hs.timer.doAfter(0.8, function()
        captureTask:terminate()
        local volumeDb, muted = parseVolumeAndMuteFromCapture(table.concat(buffer))
        if volumeDb then
            adi2.state.volumeDb = volumeDb
            if muted ~= nil then adi2.state.muted = muted end
            adi2.savePersistedState()
            log(string.format("live sync succeeded: volumeDb=%.1f muted=%s", volumeDb, tostring(adi2.state.muted)))
        else
            log("live sync got no reply, keeping persisted volumeDb=" .. tostring(adi2.state.volumeDb))
        end
    end)
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Small custom on-screen HUD (top-right, like the native volume indicator)
-- instead of hs.alert's large centered banner.
local HUD_WIDTH = 190
local HUD_HEIGHT = 54
local HUD_MARGIN = 14
local hud = nil
local hudHideTimer = nil

local function ensureHud()
    if hud then return hud end
    local screen = hs.screen.mainScreen():frame()
    local x = screen.x + screen.w - HUD_WIDTH - HUD_MARGIN
    local y = screen.y + HUD_MARGIN
    hud = hs.canvas.new({ x = x, y = y, w = HUD_WIDTH, h = HUD_HEIGHT })
    hud:level(hs.canvas.windowLevels.overlay)
    hud:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    hud:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.82 },
        roundedRectRadii = { xRadius = 14, yRadius = 14 },
    })
    hud:appendElements({
        id = "label",
        type = "text",
        text = "",
        textColor = { white = 1, alpha = 1 },
        textSize = 13,
        textFont = ".AppleSystemUIFont",
        frame = { x = 14, y = 8, w = HUD_WIDTH - 28, h = 18 },
    })
    hud:appendElements({
        id = "track",
        type = "rectangle",
        action = "fill",
        fillColor = { white = 1, alpha = 0.25 },
        roundedRectRadii = { xRadius = 2.5, yRadius = 2.5 },
        frame = { x = 14, y = 34, w = HUD_WIDTH - 28, h = 5 },
    })
    hud:appendElements({
        id = "fill",
        type = "rectangle",
        action = "fill",
        fillColor = { white = 1, alpha = 0.95 },
        roundedRectRadii = { xRadius = 2.5, yRadius = 2.5 },
        frame = { x = 14, y = 34, w = 0, h = 5 },
    })
    return hud
end

-- fraction is 0..1 (nil hides the level bar entirely, e.g. for mute)
local function showHud(label, fraction)
    local c = ensureHud()
    c["label"].text = label
    local trackWidth = HUD_WIDTH - 28
    local barWidth = fraction and (trackWidth * clamp(fraction, 0, 1)) or 0
    c["fill"].frame = { x = 14, y = 34, w = barWidth, h = 5 }
    c["track"].fillColor = { white = 1, alpha = fraction and 0.25 or 0.12 }
    c:show()
    if hudHideTimer then hudHideTimer:stop() end
    hudHideTimer = hs.timer.doAfter(1.1, function() c:hide() end)
end

local function volumeFraction(db)
    return (db - adi2.minDb) / (adi2.maxDb - adi2.minDb)
end

function adi2.volumeUp()
    adi2.state.volumeDb = clamp(adi2.state.volumeDb + adi2.stepDb, adi2.minDb, adi2.maxDb)
    adi2.sendVolume(adi2.state.volumeDb)
    adi2.savePersistedState()
    showHud(string.format("ADI-2 Line  %.1f dB", adi2.state.volumeDb), volumeFraction(adi2.state.volumeDb))
end

function adi2.volumeDown()
    adi2.state.volumeDb = clamp(adi2.state.volumeDb - adi2.stepDb, adi2.minDb, adi2.maxDb)
    adi2.sendVolume(adi2.state.volumeDb)
    adi2.savePersistedState()
    showHud(string.format("ADI-2 Line  %.1f dB", adi2.state.volumeDb), volumeFraction(adi2.state.volumeDb))
end

function adi2.toggleMute()
    adi2.state.muted = not adi2.state.muted
    adi2.sendMute(adi2.state.muted)
    adi2.savePersistedState()
    if adi2.state.muted then
        showHud("ADI-2 Line  Muted", nil)
    else
        showHud(string.format("ADI-2 Line  %.1f dB", adi2.state.volumeDb), volumeFraction(adi2.state.volumeDb))
    end
end

function adi2.start()
    log("start(): looking for ADI-2 DAC port")
    adi2.state.port = adi2.findPort()
    if not adi2.state.port then
        hs.alert.show("ADI-2 DAC MIDI port not found")
        log("start(): port not found")
        return
    end
    log("start(): found port " .. adi2.state.port)
    adi2.loadPersistedState()
    log(string.format("start(): loaded persisted volumeDb=%.1f muted=%s", adi2.state.volumeDb, tostring(adi2.state.muted)))
    showHud(string.format("ADI-2 ready  %.1f dB", adi2.state.volumeDb), volumeFraction(adi2.state.volumeDb))
    adi2.syncFromDevice()

    adi2.eventtap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(event)
        local nsEvent = event:systemKey()
        if not nsEvent or not nsEvent.down then return false end
        if nsEvent.key == "SOUND_UP" then
            adi2.volumeUp()
            return true
        elseif nsEvent.key == "SOUND_DOWN" then
            adi2.volumeDown()
            return true
        elseif nsEvent.key == "MUTE" then
            adi2.toggleMute()
            return true
        end
        return false
    end)
    local tapStarted = adi2.eventtap:start()
    log("eventtap start() returned: " .. tostring(tapStarted) .. ", isEnabled: " .. tostring(adi2.eventtap:isEnabled()))
    if not hs.accessibilityState() then
        log("WARNING: Accessibility permission not granted, eventtap will not receive events")
    end
end

adi2.start()

_G.adi2 = adi2
