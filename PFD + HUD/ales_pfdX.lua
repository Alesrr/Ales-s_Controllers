-- =================================================== --
-- PFD for X-Layout Copters / Made by;
-- =================================================== --
--                     ,--,                            
--                  ,---.'|                            
--     ,---,        |   | :        ,---,.   .--.--.    
--    '  .' \       :   : |      ,'  .' |  /  /    '.  
--   /  ;    '.     |   ' :    ,---.'   | |  :  /`. /  
--  :  :       \    ;   ; '    |   |   .' ;  |  |--`   
--  :  |   /\   \   '   | |__  :   :  |-, |  :  ;_     
--  |  :  ' ;.   :  |   | :.'| :   |  ;/|  \  \    `.  
--  |  |  ;/  \   \ '   :    ; |   :   .'   `----.   \ 
--  '  :  | \  \ ,' |   |  ./  |   |  |-,   __ \  \  | 
--  |  |  '  '--'   ;   : ;    '   :  ;/|  /  /`--'  / 
--  |  :  :         |   ,/     |   |    \ '--'.     /  
--  |  | ,'         '---'      |   :   .'   `--'---'   
--  `--''                      |   | ,'                
--                             `----'                  
-- =================================================== --
                                             
local P_KP = 0.8
local P_KI = 0.15
local P_KD = 2.5
local R_KP = 0.8
local R_KI = 0.15
local R_KD = 2.5

local A_KP        = 2.0
local A_KI        = 0.08
local A_KD_VEL    = 2.5
local A_FALLBACK  = 62.0
local TARGET_ALT  = 64

local MOTOR_MIN    =   0
local MOTOR_MAX    = 256
local I_MIN, I_MAX = -40,  40
local O_MIN, O_MAX = -80,  80

local K_ALPHA   = 0.05
local K_MIN_RPM = 20

local DISTURBANCE_DEG = 5.0
local INTEGRAL_BLEED  = 0.3

local ATT_BASE = 80

local LOOP_RATE    = 0.05
local ALT_STEP     = 10
local RS_HOLD_TIME = 0.01

local CFG_FILE = "/pfd_cfg.lua"

local MODE         = "ATT"
local SUB          = "GRAPH"
local TIER         = "STD"
local UI_MODE      = "stab_graph"
local GAINS_RANGE  = 18
local UI_DIRTY     = true

local RES_SCALE = 2

local gpu           = nil
local displayId     = nil
local DISPLAY_ID_FILE = "pfd_display.id"

local currentCfg

local FRAME = {
    cur = nil, prev = nil,
    t_cur = 0, t_prev = 0,
    seq = 0,
    seen = -1,
}

local SAT = {
    glmHigh  = 0,
    glmLow   = 0,
    pitchOut = 0,
    rollOut  = 0,
    iPClamp  = 0,
    iRClamp  = 0,
    iAClamp  = 0,
}

local RENDER_HZ = 60

local SPID = {}
SPID.__index = SPID

function SPID.new(kp, ki, kd)
    return setmetatable({
        sp = 0, kp = kp, ki = ki, kd = kd,
        integral = 0, prevErr = 0,
    }, SPID)
end

function SPID:step(measured, dt)
    if dt <= 0 then return 0 end
    local err     = self.sp - measured
    self.integral = math.max(I_MIN, math.min(I_MAX, self.integral + err * dt))
    local deriv   = (err - self.prevErr) / dt
    self.prevErr  = err
    return math.max(O_MIN, math.min(O_MAX,
           self.kp * err + self.ki * self.integral + self.kd * deriv))
end

function SPID:reset()            self.integral = 0; self.prevErr = 0 end
function SPID:setGains(kp,ki,kd) self.kp=kp; self.ki=ki; self.kd=kd  end

local APID = {}
APID.__index = APID

function APID.new(kp, ki)
    return setmetatable({
        sp = TARGET_ALT, kp = kp, ki = ki,
        integral = 0, prevErr = 0,
    }, APID)
end

function APID:step(measured, dt)
    if dt <= 0 then return 0 end
    local err = self.sp - measured

    local newI = math.max(I_MIN, math.min(I_MAX, self.integral + err * dt))
    local newOut = self.kp * err + self.ki * newI
    local pushingIntoMax = ((newOut >= O_MAX) or self.satHi) and (err > 0)
    local pushingIntoMin = ((newOut <= O_MIN) or self.satLo) and (err < 0)
    if not (pushingIntoMax or pushingIntoMin) then
        self.integral = newI
    end

    return math.max(O_MIN, math.min(O_MAX,
           self.kp * err + self.ki * self.integral))
end

function APID:setSaturated(hi, lo)
    self.satHi = hi and true or false
    self.satLo = lo and true or false
end

function APID:reset()          self.integral = 0; self.prevErr = 0 end
function APID:setSP(sp)        self.sp = sp                          end
function APID:setGains(kp,ki)  self.kp = kp; self.ki = ki            end

local function saveConfig(cfg)
    local f = fs.open(CFG_FILE, "w")
    if f then f.write(textutils.serialize(cfg)); f.close() end
end

local function loadConfig()
    if not fs.exists(CFG_FILE) then return nil end
    local f = fs.open(CFG_FILE, "r")
    if not f then return nil end
    local d = f.readAll(); f.close()
    return textutils.unserialize(d)
end

local function wizard()
    term.clear(); term.setCursorPos(1, 1)

    local saved = loadConfig()
    if saved then

        local function shortPeri(name)
            if not name then return "(none)" end
            local stripped = name
                :gsub("^Create_RotationSpeedController_", "RSC#")
                :gsub("^redstone_relay_", "relay#")
            if #stripped > 28 then
                stripped = "..." .. stripped:sub(-25)
            end
            return stripped
        end
        local function line(label, value)
            print(string.format("  %-7s %s", label, tostring(value)))
        end
        local function linePair(lLbl, lVal, rLbl, rVal)

            if rLbl then
                print(string.format("  %-4s%-16s  %-4s%s",
                    lLbl, tostring(lVal), rLbl, tostring(rVal)))
            else
                print(string.format("  %-4s%s", lLbl, tostring(lVal)))
            end
        end

        print("-- Saved config --")
        print(" Motors")
        linePair("GLM", shortPeri(saved.GLM), nil, nil)
        linePair("FL",  shortPeri(saved.FL),  "FR", shortPeri(saved.FR))
        linePair("BL",  shortPeri(saved.BL),  "BR", shortPeri(saved.BR))
        print(" Redstone")
        linePair("UP",  shortPeri(saved.RELAY_UP),
                 "DN",  shortPeri(saved.RELAY_DOWN))
        print(" Tune")
        line("BASE", string.format("%d rpm", saved.ATT_BASE or ATT_BASE))

        local pKP = saved.P_KP or saved.S_KP or P_KP
        local pKI = saved.P_KI or saved.S_KI or P_KI
        local pKD = saved.P_KD or saved.S_KD or P_KD
        local rKP = saved.R_KP or saved.S_KP or R_KP
        local rKI = saved.R_KI or saved.S_KI or R_KI
        local rKD = saved.R_KD or saved.S_KD or R_KD
        line("pitch", string.format("kP=%.3f kI=%.3f kD=%.3f", pKP, pKI, pKD))
        line("roll",  string.format("kP=%.3f kI=%.3f kD=%.3f", rKP, rKI, rKD))
        line("alt",   string.format("kP=%.3f kI=%.3f kD=%.3f",
            saved.A_KP or A_KP, saved.A_KI or A_KI, saved.A_KD_VEL or A_KD_VEL))
        line("",      string.format("ff=%.2f", saved.A_FALLBACK or A_FALLBACK))
        print(" Advanced")
        line("BLD",  string.format("%.2f", saved.INTEGRAL_BLEED  or INTEGRAL_BLEED))
        line("DIS",  string.format("%.1f deg", saved.DISTURBANCE_DEG or DISTURBANCE_DEG))
        line("KA",   string.format("%.3f", saved.K_ALPHA         or K_ALPHA))
        line("RSH",  string.format("%.2f s", saved.RS_HOLD_TIME   or RS_HOLD_TIME))
        line("STEP", string.format("%d m",  saved.ALT_STEP        or ALT_STEP))
        print("")

        local periKeys = {"GLM", "FL", "FR", "BL", "BR",
                          "RELAY_UP", "RELAY_DOWN"}
        local allOK = true
        local missing = nil
        for _, k in ipairs(periKeys) do
            local n = saved[k]
            if not n or n == "" or not peripheral.wrap(n) then
                allOK = false
                missing = k
                break
            end
        end

        if allOK then
            print("All saved peripherals present -- loading config.")

            P_KP = saved.P_KP or saved.S_KP or P_KP
            P_KI = saved.P_KI or saved.S_KI or P_KI
            P_KD = saved.P_KD or saved.S_KD or P_KD

            R_KP = saved.R_KP or saved.S_KP or R_KP
            R_KI = saved.R_KI or saved.S_KI or R_KI
            R_KD = saved.R_KD or saved.S_KD or R_KD
            if saved.A_KP      then A_KP      = saved.A_KP      end
            if saved.A_KI      then A_KI      = saved.A_KI      end
            if saved.A_KD_VEL  then A_KD_VEL  = saved.A_KD_VEL  end
            if saved.A_FALLBACK then A_FALLBACK = saved.A_FALLBACK end
            if saved.ATT_BASE  then ATT_BASE  = saved.ATT_BASE  end

            if saved.INTEGRAL_BLEED  then INTEGRAL_BLEED  = saved.INTEGRAL_BLEED  end
            if saved.DISTURBANCE_DEG then DISTURBANCE_DEG = saved.DISTURBANCE_DEG end
            if saved.K_ALPHA         then K_ALPHA         = saved.K_ALPHA         end
            if saved.RS_HOLD_TIME    then RS_HOLD_TIME    = saved.RS_HOLD_TIME    end
            if saved.ALT_STEP        then ALT_STEP        = saved.ALT_STEP        end
            sleep(0.4)
            return saved
        else
            print("Peripheral '" .. tostring(missing) .. "' (" ..
                  tostring(saved[missing]) ..
                  ") not present -- redoing wizard from scratch.")
            print("")
            sleep(0.8)
        end
    end

    term.clear(); term.setCursorPos(1, 1)
    print("-- FUSED FLIGHT CONTROLLER SETUP --")
    print("")
    print("Available peripherals:")

    local names = peripheral.getNames()
    local sugg  = {}
    for _, n in ipairs(names) do
        print(string.format("  %-32s (%s)", n, peripheral.getType(n)))
        sugg[#sugg+1] = n
    end
    for _, s in ipairs({"top","bottom","left","right","front","back"}) do
        sugg[#sugg+1] = s
    end
    print("")
    print("This airframe has a dedicated lift motor (GLM) plus 4")
    print("corner rotors used ONLY for attitude trim.")
    print("Name the GLM, then each rotor at its X-quad corner.")
    print("")

    local function ask(label, def)
        io.write(string.format("  %-24s [%s]: ", label, def))
        local inp = read(nil, nil, function(t)
            local r = {}
            for _, s in ipairs(sugg) do
                if s:sub(1,#t) == t then r[#r+1] = s:sub(#t+1) end
            end
            return r
        end)
        return (inp == nil or inp == "") and def or inp
    end

    local glm = ask("GLM lift motor", "RSC Main")
    local fl  = ask("Attitude FL",    "RSC 1")
    local fr  = ask("Attitude FR",    "RSC 2")
    local bl  = ask("Attitude BL",    "RSC 3")
    local br  = ask("Attitude BR",    "RSC 4")
    print("")
    print("Altitude trim runs through two redstone_relay peripherals,")
    print("one for UP and one for DOWN.  Each relay's 'front' face is")
    print("polled for input; pulse to step target altitude by "
          .. ALT_STEP .. " m.")
    print("")
    local relayUp   = ask("Relay UP   (peripheral)", "redstone_relay_0")
    local relayDown = ask("Relay DOWN (peripheral)", "redstone_relay_1")
    print("")

    print("Checking peripherals...")
    local ok = true

    for lbl, name in pairs({GLM=glm, FL=fl, FR=fr, BL=bl, BR=br,
                            ["UP"]=relayUp, ["DN"]=relayDown}) do
        local found = peripheral.wrap(name) ~= nil
        print(string.format("  %-4s (%s) %s", lbl, name,
              found and "OK" or "NOT FOUND"))
        if not found then ok = false end
    end
    local gpuFound = peripheral.find("directgpu") ~= nil
    print("  CC:DirectGPU " .. (gpuFound and "OK" or "NOT FOUND"))
    if not gpuFound then
        print("  WARNING: no DirectGPU -- the UI cannot render.")
    end
    if not ok then print("WARNING: some motors missing.") end

    print("")
    io.write("Save config? [Y/n]: ")
    local sv  = read()
    local cfg = {
        GLM=glm, FL=fl, FR=fr, BL=bl, BR=br,
        RELAY_UP=relayUp, RELAY_DOWN=relayDown,
        ATT_BASE=ATT_BASE,
        P_KP=P_KP, P_KI=P_KI, P_KD=P_KD,
        R_KP=R_KP, R_KI=R_KI, R_KD=R_KD,
        A_KP=A_KP, A_KI=A_KI, A_KD_VEL=A_KD_VEL, A_FALLBACK=A_FALLBACK,

        INTEGRAL_BLEED=INTEGRAL_BLEED, DISTURBANCE_DEG=DISTURBANCE_DEG,
        K_ALPHA=K_ALPHA, RS_HOLD_TIME=RS_HOLD_TIME,
        ALT_STEP=ALT_STEP,
    }
    if sv == "" or sv:lower() == "y" then
        saveConfig(cfg); print("Saved to " .. CFG_FILE)
    end
    return cfg
end

local function gpuSaveId(id)
    local f = fs.open(DISPLAY_ID_FILE, "w")
    if f then f.write(tostring(id)); f.close() end
end

local function gpuLoadId()
    if not fs.exists(DISPLAY_ID_FILE) then return nil end
    local f = fs.open(DISPLAY_ID_FILE, "r")
    if not f then return nil end
    local s = f.readAll(); f.close()
    return tonumber(s)
end

local function gpuEnsure()
    if displayId then return true end
    if not gpu    then return false end

    local ok_l, displays = pcall(function() return gpu.listDisplays() end)
    if ok_l and type(displays) == "table" and #displays > 0 then
        local saved = gpuLoadId()
        if saved then
            for _, dd in ipairs(displays) do
                if tonumber(dd) == saved then displayId = saved break end
            end
        end
        if not displayId then
            displayId = tonumber(displays[1])
            gpuSaveId(displayId)
        end
        sleep(0.1)
        pcall(function() gpu.clear(displayId, 0, 0, 0); gpu.updateDisplay(displayId) end)
        return true
    end

    print("DirectGPU: creating display at scale " .. RES_SCALE .. "...")
    sleep(0.5)

    local ok_d, did = pcall(function()
        return gpu.autoDetectAndCreateDisplay(RES_SCALE)
    end)
    if not ok_d or not did then
        print("DirectGPU: scaled create failed (" .. tostring(did)
              .. "); retrying at default scale...")
        ok_d, did = pcall(function()
            return gpu.autoDetectAndCreateDisplay()
        end)
    end
    if not ok_d or not did then
        print("DirectGPU: creation failed: " .. tostring(did))
        return false
    end
    displayId = did
    gpuSaveId(did)
    sleep(0.3)
    pcall(function() gpu.clear(did, 0, 0, 0);    gpu.updateDisplay(did) end)
    sleep(0.2)
    pcall(function() gpu.clear(did, 0, 0, 0);    gpu.updateDisplay(did) end)
    return true
end

local function gpuRelease()
    if not gpu or not displayId then return end
    local id = displayId
    displayId = nil
    if fs.exists(DISPLAY_ID_FILE) then fs.delete(DISPLAY_ID_FILE) end
    pcall(function() gpu.clear(id, 0, 0, 0); gpu.updateDisplay(id) end)
    pcall(function() gpu.removeDisplay(id) end)
end

local CK = { 0,   0,   0   }
local CW = { 235, 238, 240 }
local CG = { 90,  220, 130 }
local CGD= { 40,  90,  60  }
local CR = { 235, 70,  70  }
local CGY= { 120, 130, 140 }
local CB = { 90,  150, 240 }

local function dims()
    local ok, info = pcall(function() return gpu.getDisplayInfo(displayId) end)
    if not ok or type(info) ~= "table" then return 320, 240 end
    return (info.pixelWidth or 320), (info.pixelHeight or 240)
end

local function gline(x0, y0, x1, y1, c, thick)
    thick = thick or 1
    x0 = math.floor(x0 + 0.5); y0 = math.floor(y0 + 0.5)
    x1 = math.floor(x1 + 0.5); y1 = math.floor(y1 + 0.5)
    local dx =  math.abs(x1 - x0)
    local dy = -math.abs(y1 - y0)
    local sx = (x0 < x1) and 1 or -1
    local sy = (y0 < y1) and 1 or -1
    local err = dx + dy

    local steep = (-dy) > dx
    local dw = steep and thick or 1
    local dh = steep and 1 or thick
    local ox = math.floor(dw / 2)
    local oy = math.floor(dh / 2)
    while true do
        gpu.fillRect(displayId, x0 - ox, y0 - oy, dw, dh, c[1], c[2], c[3])
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end
end

local function grect(x, y, w, h, c)
    if w < 1 or h < 1 then return end
    gpu.fillRect(displayId, math.floor(x), math.floor(y),
                 math.floor(w), math.floor(h), c[1], c[2], c[3])
end

local UI_TEXT_SCALE = 1
local function refreshUiTextScale()
    local PW = select(1, dims())
    UI_TEXT_SCALE = math.min(2.0, math.max(1.0, PW / 640))
end

local function gtextRaw(s, x, y, c, size, style)
    gpu.drawText(displayId, s, math.floor(x), math.floor(y),
                 c[1], c[2], c[3], "Arial", size or 10, style or "plain")
end

local function gtext(s, x, y, c, size, style)
    local sz = math.floor((size or 10) * UI_TEXT_SCALE + 0.5)
    gpu.drawText(displayId, s, math.floor(x), math.floor(y),
                 c[1], c[2], c[3], "Arial", sz, style or "plain")
end

local function gflush() end

local function gcommit()
    gpu.updateDisplay(displayId)
end

local MODE_ORDER = { "ATT", "ALT" }
local SUB_OTHER  = { GRAPH = "GAINS", GAINS = "GRAPH" }

local function uiModeFromMS()
    if MODE == "ATT" and SUB == "GRAPH"    then return "stab_graph" end
    if MODE == "ATT" and SUB == "GAINS"    then return "stab_gains" end
    if MODE == "ALT" and SUB == "GRAPH"    then return "alt_graph"  end
    if MODE == "ALT" and SUB == "GAINS"    then return "alt_gains"  end
    return "stab_graph"
end

local function applyMode()
    UI_MODE  = uiModeFromMS()
    UI_DIRTY = true
end

local function cycleMode()
    local idx = 1
    for i, m in ipairs(MODE_ORDER) do
        if m == MODE then idx = i; break end
    end
    MODE = MODE_ORDER[(idx % #MODE_ORDER) + 1]
    applyMode()
end

local function toggleSub()
    SUB = SUB_OTHER[SUB] or "GRAPH"
    applyMode()
end

local TIER_OTHER = { STD = "ADV", ADV = "STD" }
local function toggleTier()
    TIER = TIER_OTHER[TIER] or "STD"
    UI_DIRTY = true
end

local UI = {
    hoverX = -1, hoverY = -1,
    scrollTargets = {},
}

local function resetScrollTargets()
    UI.scrollTargets = {}
end

local function addScrollTarget(x, y, w, h, onScroll)
    UI.scrollTargets[#UI.scrollTargets + 1] = {
        x = x, y = y, w = w, h = h, onScroll = onScroll
    }
end

local function inRect(x, y, rx, ry, rw, rh)
    return x >= rx and x < rx + rw and y >= ry and y < ry + rh
end

local function dispatchScroll(dir)
    local hx, hy = UI.hoverX, UI.hoverY
    if hx < 0 or hy < 0 then return end
    for _, t in ipairs(UI.scrollTargets) do
        if inRect(hx, hy, t.x, t.y, t.w, t.h) then
            t.onScroll(dir)
            return
        end
    end
end

local function consumeGpuEvents(onClick)
    if not gpu or not displayId then return end
    while gpu.hasEvents(displayId) do
        local e = gpu.pollEvent(displayId)
        if type(e) == "table" then
            local t = e.type

            if type(e.x) == "number" and type(e.y) == "number" then
                UI.hoverX = e.x
                UI.hoverY = e.y
            end

            if t == "mouse_click" then
                if onClick then onClick(e.x or 0, e.y or 0, e.button or 1) end
            elseif t and t:find("scroll") then

                if not _gpuScrollSeen then
                    _gpuScrollSeen = true
                    local parts = {}
                    for k, v in pairs(e) do
                        parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
                    end
                    pcall(function()
                        term.setCursorPos(1, 18); term.clearLine()
                        print("[gpu scroll #1: " .. table.concat(parts, " ") .. "]")
                    end)
                end

                local d = e.button
                       or e.direction or e.dir   or e.delta
                       or e.dy        or e.wheel or e.scrollDir
                       or e.scrollDirection      or e.amount
                       or e.scrollY   or e.deltaY
                if type(d) ~= "number" then
                    for k, v in pairs(e) do
                        if type(v) == "number"
                           and k ~= "x" and k ~= "y"
                           and k ~= "timestamp"
                           and v ~= 0 and math.abs(v) <= 10 then
                            d = v
                            break
                        end
                    end
                end
                if type(d) == "number" and d ~= 0 then

                    dispatchScroll(d > 0 and 1 or -1)
                end
            end
        end
    end
end

local CTRL = {}

local GAIN_STEP = 0.01
local INT_STEP  = 1

local function applyDelta(value, dir, step, lo, hi)
    local v = value + (-dir) * step
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

local function bumpPitchKP(dir)
    P_KP = applyDelta(P_KP, dir, GAIN_STEP, 0, nil)
    if CTRL.pitchPID then CTRL.pitchPID:setGains(P_KP, P_KI, P_KD) end
end
local function bumpPitchKI(dir)
    P_KI = applyDelta(P_KI, dir, GAIN_STEP, 0, nil)
    if CTRL.pitchPID then CTRL.pitchPID:setGains(P_KP, P_KI, P_KD) end
end
local function bumpPitchKD(dir)
    P_KD = applyDelta(P_KD, dir, GAIN_STEP, 0, nil)
    if CTRL.pitchPID then CTRL.pitchPID:setGains(P_KP, P_KI, P_KD) end
end
local function bumpRollKP(dir)
    R_KP = applyDelta(R_KP, dir, GAIN_STEP, 0, nil)
    if CTRL.rollPID then CTRL.rollPID:setGains(R_KP, R_KI, R_KD) end
end
local function bumpRollKI(dir)
    R_KI = applyDelta(R_KI, dir, GAIN_STEP, 0, nil)
    if CTRL.rollPID then CTRL.rollPID:setGains(R_KP, R_KI, R_KD) end
end
local function bumpRollKD(dir)
    R_KD = applyDelta(R_KD, dir, GAIN_STEP, 0, nil)
    if CTRL.rollPID then CTRL.rollPID:setGains(R_KP, R_KI, R_KD) end
end
local function bumpStabBase(dir)
    ATT_BASE = math.floor(applyDelta(ATT_BASE, dir, INT_STEP, 0, MOTOR_MAX))
end

local BLEED_STEP    = 0.05
local DIST_STEP     = 1.0
local KALPHA_STEP   = 0.01
local RSHOLD_STEP   = 0.01
local ALTSTEP_STEP  = 1

local function bumpIntBleed(dir)
    INTEGRAL_BLEED = applyDelta(INTEGRAL_BLEED, dir, BLEED_STEP, 0, 1)
end
local function bumpDisturbance(dir)
    DISTURBANCE_DEG = applyDelta(DISTURBANCE_DEG, dir, DIST_STEP, 0, 45)
end
local function bumpKAlpha(dir)
    K_ALPHA = applyDelta(K_ALPHA, dir, KALPHA_STEP, 0, 1)
end
local function bumpRsHold(dir)
    RS_HOLD_TIME = applyDelta(RS_HOLD_TIME, dir, RSHOLD_STEP, 0, 5)
end
local function bumpAltStep(dir)
    ALT_STEP = math.floor(applyDelta(ALT_STEP, dir, ALTSTEP_STEP, 1, 100))
end

local function bumpAltKP(dir)
    A_KP = applyDelta(A_KP, dir, GAIN_STEP, 0, nil)
    if CTRL.altPID then CTRL.altPID:setGains(A_KP, A_KI) end
end
local function bumpAltKI(dir)
    A_KI = applyDelta(A_KI, dir, GAIN_STEP, 0, nil)
    if CTRL.altPID then CTRL.altPID:setGains(A_KP, A_KI) end
end
local function bumpAltKD(dir)
    A_KD_VEL = applyDelta(A_KD_VEL, dir, GAIN_STEP, 0, nil)
end
local function bumpAltFF(dir)
    A_FALLBACK = applyDelta(A_FALLBACK, dir, INT_STEP, 0, MOTOR_MAX)
end

local BTN_W_BASE       = 64
local BTN_H_BASE       = 18
local BTN_PAD_BASE     = 6
local BTN_PAD_TOP_BASE = 3
local BTN_GAP_BASE     = 6
local BTN_FONT_BASE    = 10

local BTN_W       = BTN_W_BASE
local BTN_H       = BTN_H_BASE
local BTN_PAD     = BTN_PAD_BASE
local BTN_PAD_TOP = BTN_PAD_TOP_BASE
local BTN_GAP     = BTN_GAP_BASE
local BTN_FONT    = BTN_FONT_BASE
local BTN_STRIP_H = BTN_H + BTN_PAD_TOP + BTN_PAD

local function refreshButtonScale()
    BTN_W       = math.floor(BTN_W_BASE       * UI_TEXT_SCALE + 0.5)
    BTN_H       = math.floor(BTN_H_BASE       * UI_TEXT_SCALE + 0.5)
    BTN_PAD     = math.floor(BTN_PAD_BASE     * UI_TEXT_SCALE + 0.5)
    BTN_PAD_TOP = math.floor(BTN_PAD_TOP_BASE * UI_TEXT_SCALE + 0.5)
    BTN_GAP     = math.floor(BTN_GAP_BASE     * UI_TEXT_SCALE + 0.5)
    BTN_FONT    = math.floor(BTN_FONT_BASE    * UI_TEXT_SCALE + 0.5)
    BTN_STRIP_H = BTN_H + BTN_PAD_TOP + BTN_PAD
end

local MODE_LABEL = { ATT = "ATTITUDE", ALT = "ALTITUDE" }

local function mainBtnRect()
    local _, PH = dims()
    return BTN_PAD, PH - BTN_PAD - BTN_H, BTN_W, BTN_H
end
local function subBtnRect()
    local _, PH = dims()
    return BTN_PAD + BTN_W + BTN_GAP, PH - BTN_PAD - BTN_H, BTN_W, BTN_H
end
local function tierBtnRect()
    local _, PH = dims()
    return BTN_PAD + (BTN_W + BTN_GAP) * 2, PH - BTN_PAD - BTN_H, BTN_W, BTN_H
end

local function handleButtonClick(x, y)
    local mx, my, mw, mh = mainBtnRect()
    if inRect(x, y, mx, my, mw, mh) then cycleMode(); return true end
    local sx, sy, sw, sh = subBtnRect()
    if inRect(x, y, sx, sy, sw, sh) then toggleSub(); return true end
    local tx, ty, tw, th = tierBtnRect()
    if inRect(x, y, tx, ty, tw, th) then toggleTier(); return true end
    return false
end

local C_BTN_HOVER = { 30, 35, 45 }

local function drawOneButton(x, y, w, h, label, edgeColor, hovered)
    grect(x, y, w, h, hovered and C_BTN_HOVER or CK)
    grect(x,         y,         w, 1, edgeColor)
    grect(x,         y + h - 1, w, 1, edgeColor)
    grect(x,         y,         1, h, edgeColor)
    grect(x + w - 1, y,         1, h, edgeColor)

    local charW = math.floor(BTN_FONT * 0.6 + 0.5)
    local tw = #label * charW
    local ty = y + math.floor((h - BTN_FONT) / 2)
    gtextRaw(label, x + math.floor((w - tw) / 2), ty,
             edgeColor, BTN_FONT, "bold")
end

local function drawButtons()
    local hx, hy = UI.hoverX, UI.hoverY

    local mx, my, mw, mh = mainBtnRect()
    local mc
    if     MODE == "ATT" then mc = CG
    elseif MODE == "ALT" then mc = CB
    else                      mc = CW end
    drawOneButton(mx, my, mw, mh, MODE_LABEL[MODE] or MODE,
                  mc, inRect(hx, hy, mx, my, mw, mh))

    local sx, sy, sw, sh = subBtnRect()
    local sc = (SUB == "GAINS") and CG or CW
    drawOneButton(sx, sy, sw, sh, SUB, sc,
                  inRect(hx, hy, sx, sy, sw, sh))

    local tx, ty, tw, th = tierBtnRect()
    local tc = (TIER == "ADV") and CR or CW
    drawOneButton(tx, ty, tw, th, TIER, tc,
                  inRect(hx, hy, tx, ty, tw, th))
end

local Graph = {}
Graph.__index = Graph

function Graph.new(title, series, opts)
    opts = opts or {}
    return setmetatable({
        title   = title,
        series  = series,
        cap     = opts.cap or 80,

        data    = {},
        head    = 0,
        count   = 0,
        fixed_hi = opts.fixed_hi,
        fixed_lo = opts.fixed_lo,
        unit    = opts.unit or "",
        danger  = opts.danger,
    }, Graph)
end

Graph.SUBSTEPS = 1

function Graph:push(values)
    local prev
    if self.count > 0 then
        prev = self.data[self.head]
    end
    local steps = Graph.SUBSTEPS
    if not prev then steps = 1 end
    for s = 1, steps do
        local col
        if steps == 1 then
            col = values
        else

            local t = s / steps
            col = {}
            for k, v in pairs(values) do
                local pv = prev[k]
                if type(v) == "number" and type(pv) == "number" then
                    col[k] = pv + (v - pv) * t
                else
                    col[k] = v
                end
            end
        end
        self.head = (self.head % self.cap) + 1
        self.data[self.head] = col
        if self.count < self.cap then self.count = self.count + 1 end
    end
end

function Graph:clear()
    self.data = {}; self.head = 0; self.count = 0
end

function Graph:_at(i)
    local start = (self.count < self.cap) and 1 or (self.head % self.cap) + 1
    local idx = ((start - 1 + (i - 1)) % self.cap) + 1
    return self.data[idx]
end

function Graph:_window()
    local hi, lo = self.fixed_hi, self.fixed_lo
    if not hi or not lo then
        hi, lo = -1e9, 1e9
        for i = 1, self.count do
            local col = self:_at(i)
            if col then
                for _, s in ipairs(self.series) do
                    local v = col[s.key or s.name]
                    if v then
                        if v > hi then hi = v end
                        if v < lo then lo = v end
                    end
                end
            end
        end
        if hi <= lo then hi = lo + 1 end
        local pad = (hi - lo) * 0.12
        hi = hi + pad; lo = lo - pad

        local span = hi - lo
        local q    = span / 20
        hi = math.ceil(hi / q) * q
        lo = math.floor(lo / q) * q
    end
    return hi, lo
end

function Graph:_geom(px, py, pw, ph)

    local GUTTER   = math.floor(34 * UI_TEXT_SCALE + 0.5)
    local TITLE_GAP = math.floor(22 * UI_TEXT_SCALE + 0.5)
    local BOT_GAP   = math.floor( 6 * UI_TEXT_SCALE + 0.5)
    return {
        GUTTER = GUTTER,
        plotX  = px + GUTTER,
        plotY  = py + TITLE_GAP,
        plotW  = pw - GUTTER - 6,
        plotH  = ph - TITLE_GAP - BOT_GAP,
    }
end

function Graph:renderChrome(px, py, pw, ph)
    grect(px, py, pw, ph, CK)
    grect(px, py, pw, 1, CW)
    grect(px, py, 1, ph, CW)
    grect(px, py + ph - 1, pw, 1, CGD)
    grect(px + pw - 1, py, 1, ph, CGD)

    local titleY = py + math.floor(5 * UI_TEXT_SCALE + 0.5)
    gtext(self.title, px + 8, titleY, CW, 11, "bold")

    local swSize = math.max(9, math.floor(9 * UI_TEXT_SCALE + 0.5))
    local lgFont = 9
    local lgCharW = math.floor(lgFont * UI_TEXT_SCALE * 0.6 + 0.5)
    local lx = px + pw - 10
    for i = #self.series, 1, -1 do
        local s   = self.series[i]
        local txt = s.name
        lx = lx - (#txt * lgCharW) - swSize - math.floor(8 * UI_TEXT_SCALE)
        grect(lx, titleY + 1, swSize, swSize, s.color)
        grect(lx, titleY + 1, swSize, 1, CW)
        gtext(txt, lx + swSize + 4, titleY, CW, lgFont, "plain")
    end

    local underY = py + math.floor(18 * UI_TEXT_SCALE + 0.5)
    grect(px + 1, underY, pw - 2, 1, CGD)

    local g  = self:_geom(px, py, pw, ph)
    if g.plotW < 8 or g.plotH < 8 then return end
    local hi, lo = self:_window()
    self._chrome = { px=px, py=py, pw=pw, ph=ph, hi=hi, lo=lo }

    grect(px + 1, g.plotY, g.GUTTER - 1, g.plotH, CK)
    grect(g.plotX - 1, g.plotY, 1, g.plotH, CGD)

    for gi = 0, 4 do
        local frac = gi / 4
        local val  = hi - (hi - lo) * frac
        local gy   = g.plotY + frac * (g.plotH - 1)
        gy = math.max(g.plotY, math.min(g.plotY + g.plotH - 1, gy))
        grect(g.plotX, gy, g.plotW, 1, CGD)
        grect(g.plotX - 4, gy, 4, 1, CGY)
        local lbl = string.format("%.1f", val)
        gtext(lbl, g.plotX - 7 - (#lbl * 5), gy - 4, CGY, 8, "plain")
    end
end

function Graph:renderTrace(px, py, pw, ph, scrollFrac)
    scrollFrac = scrollFrac or 0
    local g = self:_geom(px, py, pw, ph)
    if g.plotW < 8 or g.plotH < 8 then return true end

    local hi, lo = self:_window()
    local ch = self._chrome
    if not ch or ch.hi ~= hi or ch.lo ~= lo
       or ch.px ~= px or ch.py ~= py or ch.pw ~= pw or ch.ph ~= ph then

        return false
    end

    grect(g.plotX, g.plotY, g.plotW, g.plotH, CK)

    for gi = 0, 4 do
        local frac = gi / 4
        local gy   = g.plotY + frac * (g.plotH - 1)
        gy = math.max(g.plotY, math.min(g.plotY + g.plotH - 1, gy))
        grect(g.plotX, gy, g.plotW, 1, CGD)
    end

    local function yOf(v)
        local f = (hi - v) / (hi - lo)
        if f < 0 then f = 0 elseif f > 1 then f = 1 end
        return g.plotY + f * (g.plotH - 1)
    end

    if lo < 0 and hi > 0 then
        local zy = yOf(0)
        for xx = g.plotX, g.plotX + g.plotW - 1, 7 do
            grect(xx, zy, 4, 1, CW)
        end
    end

    if self.count >= 2 then
        local n = self.count

        local colW = (g.plotW - 1) / (n - 1)
        local xL   = g.plotX
        local xR   = g.plotX + g.plotW - 1
        local flags = {}
        for _, s in ipairs(self.series) do
            local key = s.key or s.name
            local prevX, prevY, prevClipped
            local lastX, lastY, lastV
            local penY, penV

            for i = 1, n do
                local col = self:_at(i)
                local v   = col and col[key]
                if v ~= nil then
                    local xx = g.plotX + (i - 1) * colW - scrollFrac * colW
                    local yy = yOf(v)
                    local c  = s.color
                    if self.danger and math.abs(v) > self.danger then
                        c = CR
                    end

                    if prevX and not (xx < xL and prevX < xL)
                              and not (xx > xR and prevX > xR) then
                        local ax, ay, bx, by = prevX, prevY, xx, yy
                        if ax < xL then ax = xL end
                        if bx < xL then bx = xL end
                        if ax > xR then ax = xR end
                        if bx > xR then bx = xR end
                        gline(ax, ay, bx, by, c, 2)
                    end

                    penY, penV = prevY, nil
                    prevX, prevY = xx, yy
                    if xx <= xR + 0.5 then
                        lastX, lastY, lastV = math.min(xx, xR), yy, v
                    end
                end
            end
            if lastX then
                local c = s.color
                if self.danger and lastV and math.abs(lastV) > self.danger then
                    c = CR
                end

                local flagY = lastY
                if penY then

                    flagY = lastY + (penY - lastY) * scrollFrac
                end

                grect(lastX - 2, flagY - 2, 5, 5, c)
                grect(lastX - 1, flagY - 1, 3, 3, CW)
                local txt  = string.format("%.1f", lastV or 0)

                local flagFont  = 8
                local flagCharW = math.max(5,
                    math.floor(flagFont * UI_TEXT_SCALE * 0.6 + 0.5))
                local flagPadX  = math.floor(8 * UI_TEXT_SCALE + 0.5)
                flags[#flags + 1] = {
                    yIdeal = flagY,
                    color  = c,
                    text   = txt,
                    w      = #txt * flagCharW + flagPadX,
                    dotY   = flagY,
                }
            end
        end

        local flagFont = 8
        local FH   = math.max(11, math.floor((flagFont + 3) * UI_TEXT_SCALE + 0.5))
        local GAP  = 1
        local top  = g.plotY
        local bot  = g.plotY + g.plotH - FH
        table.sort(flags, function(a, b) return a.yIdeal < b.yIdeal end)
        local nF = #flags
        for i = 1, nF do
            local f = flags[i]
            f.y = math.max(top, math.min(bot, f.yIdeal - math.floor(FH/2)))
            if i > 1 then
                local prev = flags[i - 1]
                if f.y < prev.y + FH + GAP then
                    f.y = prev.y + FH + GAP
                end
            end
        end

        if nF > 0 and flags[nF].y > bot then
            flags[nF].y = bot
            for i = nF - 1, 1, -1 do
                local below = flags[i + 1]
                if flags[i].y + FH + GAP > below.y then
                    flags[i].y = below.y - FH - GAP
                end
                if flags[i].y < top then flags[i].y = top end
            end
        end

        for _, f in ipairs(flags) do
            local fw = f.w
            local fx = g.plotX + g.plotW - fw - 1
            local fy = f.y
            local cy = fy + math.floor(FH / 2)

            if math.abs(cy - f.dotY) > 2 then
                gline(fx, cy, fx - 6, f.dotY, f.color, 1)
            end
            grect(fx, fy, fw, FH, CK)
            grect(fx, fy, fw, 1, f.color)
            grect(fx, fy + FH - 1, fw, 1, f.color)
            grect(fx, fy, 1, FH, f.color)

            local txtY = fy + math.floor((FH - flagFont * UI_TEXT_SCALE) / 2 + 0.5)
            gtext(f.text, fx + 4, txtY, f.color, flagFont, "plain")
        end
    end
    return true
end

function Graph:render(px, py, pw, ph)
    self:renderChrome(px, py, pw, ph)
    self:renderTrace(px, py, pw, ph)
end

local G_stab_flux = Graph.new("STAB - Motor Flux", {
    { name = "FL", color = { 90, 220, 130 } },
    { name = "FR", color = { 235, 220, 90 } },
    { name = "BL", color = { 90, 200, 235 } },
    { name = "BR", color = { 240, 160, 70 } },
})
local G_stab_err = Graph.new("STAB - Attitude Error (deg)", {
    { name = "pitch", color = CG },
    { name = "roll",  color = CW },
}, { fixed_hi = 30, fixed_lo = -30, danger = 25 })

local G_stab_gain_pitch = Graph.new("STAB - Pitch Gain Contributions (RPM)", {
    { name = "kP", color = CG },
    { name = "kI", color = CR },
    { name = "kD", color = CB },
})
local G_stab_gain_roll  = Graph.new("STAB - Roll Gain Contributions (RPM)", {
    { name = "kP", color = CG },
    { name = "kI", color = CR },
    { name = "kD", color = CB },
})

local G_alt_flux = Graph.new("ALT - GLM Lift RPM", {
    { name = "GLM", key = "rpm", color = CG },
})
local G_alt_trk = Graph.new("ALT - Altitude Tracking (m)", {
    { name = "alt",    color = CG },
    { name = "target", color = CW },
})
local G_alt_gain = Graph.new("ALT - Gain Contributions (RPM)", {
    { name = "kP", color = CG },
    { name = "kI", color = CR },
    { name = "kD", color = CB },
})

local SIDE_W_FRAC = 0.26
local function drawSidePanel(d, gainsKind)
    local PW, PH = dims()
    local pw = math.max(150, math.floor(PW * SIDE_W_FRAC))
    local x0 = PW - pw

    grect(x0 - 1, 0, 1, PH, CW)
    grect(x0, 0, pw, PH, CK)

    resetScrollTargets()

    local fs   = 11

    local lhScale = 1 + (UI_TEXT_SCALE - 1) * 0.6
    local lh   = math.max(12, math.floor(fs * 1.12 * lhScale + 0.5))
    local row  = 0
    local pad  = math.floor(3 * lhScale + 0.5)
    local panelBottom = PH - (BTN_PAD + BTN_H + BTN_PAD)
    local function ln(t, c)
        local y = pad + row * lh
        row = row + 1
        if y > panelBottom - lh then return end
        gtext(t, x0 + 6, y, c or CW, fs, "plain")
    end

    local function scrollLn(t, c, onScroll)
        local y = pad + row * lh
        row = row + 1
        if y > panelBottom - lh then return end
        local rx, ry, rw, rh = x0 + 1, y - 2, pw - 2, lh
        if onScroll and inRect(UI.hoverX, UI.hoverY, rx, ry, rw, rh) then
            grect(rx, ry, rw, rh, { 18, 50, 80 })
            grect(rx, ry, 2,  rh, { 80, 180, 255 })
        end
        gtext(t, x0 + 6, y, c or CW, fs, "plain")
        if onScroll then
            addScrollTarget(rx, ry, rw, rh, onScroll)
        end
    end
    local function div()
        local y = pad + row * lh + math.floor(lh/2) - 1
        row = row + 1
        if y > panelBottom - 2 then return end
        grect(x0 + 4, y, pw - 8, 1, CG)
    end
    local barW = pw - math.floor(56 * UI_TEXT_SCALE + 0.5)
    local function bar(lbl, rpm, col, lo, hi)
        local y = pad + row * lh
        row = row + 1
        if y > panelBottom - lh then return end
        lo = lo or MOTOR_MIN; hi = hi or MOTOR_MAX
        local pct  = (rpm - lo) / (hi - lo)
        if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
        local bars = math.floor(pct * barW + 0.5)

        local labelX = x0 + math.floor(6  * UI_TEXT_SCALE + 0.5)
        local barX   = x0 + math.floor(34 * UI_TEXT_SCALE + 0.5)
        local barH   = math.max(3, math.floor((fs - 3) * UI_TEXT_SCALE + 0.5))
        local barY   = y + math.floor((lh - barH) / 2)
        gtext(lbl, labelX, y, CW, fs, "plain")
        grect(barX,        barY, bars,        barH, col)
        grect(barX + bars, barY, barW - bars, barH, CGD)
    end

    local attActive = (MODE == "ATT")
    local altActive = (MODE == "ALT")

    local function blockStab()
        ln(" ATTITUDE", CG)
        div()
        local pLvl = math.abs(d.pitch) < 1.0
        local rLvl = math.abs(d.roll)  < 1.0
        ln(string.format(" P %+7.2f deg", d.pitch), pLvl and CG or CW)
        ln(string.format(" R %+7.2f deg", d.roll),  rLvl and CG or CW)
        div()
        ln(string.format(" wP %+5.3f r/s", d.angX))
        ln(string.format(" wR %+5.3f r/s", d.angZ))
        div()

        local kpCol = (gainsKind == "stab") and CG or nil
        local kiCol = (gainsKind == "stab") and CR or nil
        local kdCol = (gainsKind == "stab") and CB or nil

        local function gainRow(lbl, p, pCol, pOn, r, rCol, rOn)
            local y = pad + row * lh
            row = row + 1
            if y > panelBottom - lh then return end
            local halfW = math.floor((pw - 6) / 2)
            local cells = {
                { x = x0 + 2,              v = p, c = pCol, on = pOn, lbl = "p" .. lbl },
                { x = x0 + 4 + halfW,      v = r, c = rCol, on = rOn, lbl = "r" .. lbl },
            }
            for _, cell in ipairs(cells) do
                if cell.on and inRect(UI.hoverX, UI.hoverY,
                                      cell.x, y - 2, halfW, lh) then
                    grect(cell.x, y - 2, halfW, lh, { 18, 50, 80 })
                    grect(cell.x, y - 2, 2,     lh, { 80, 180, 255 })
                end
                gtext(string.format("%s %5.3f", cell.lbl, cell.v),
                      cell.x + 3, y, cell.c or CW, fs, "plain")
                if cell.on then
                    addScrollTarget(cell.x, y - 2, halfW, lh, cell.on)
                end
            end

            grect(x0 + 3 + halfW, y - 1, 1, lh - 2, { 60, 60, 80 })
        end

        if attActive then
            gainRow("P", P_KP, kpCol, bumpPitchKP, R_KP, kpCol, bumpRollKP)
            gainRow("I", P_KI, kiCol, bumpPitchKI, R_KI, kiCol, bumpRollKI)
            gainRow("D", P_KD, kdCol, bumpPitchKD, R_KD, kdCol, bumpRollKD)
            scrollLn(string.format(" BASE %5d", ATT_BASE), nil, bumpStabBase)
        else

            ln(string.format(" pP %5.3f  rP %5.3f", P_KP, R_KP), kpCol)
            ln(string.format(" pI %5.3f  rI %5.3f", P_KI, R_KI), kiCol)
            ln(string.format(" pD %5.3f  rD %5.3f", P_KD, R_KD), kdCol)
            ln(string.format(" BASE %5d", ATT_BASE))
        end

        local function iCol(v)
            local a = math.abs(v or 0)
            if a > 25 then return CR end
            if a > 10 then return CGY end
            return CG
        end
        ln(string.format(" iP %+6.2f  iR %+6.2f", d.iP or 0, d.iR or 0),
           iCol(math.max(math.abs(d.iP or 0), math.abs(d.iR or 0))))
        div()
        local function motorBar(lbl, rpm, col)
            local useCol = (UI_MODE == "stab_graph") and col or CW
            bar(lbl, rpm, useCol)
        end
        motorBar("FL", d.fl, { 90,220,130 })
        motorBar("FR", d.fr, { 235,220,90 })
        motorBar("BL", d.bl, { 90,200,235 })
        motorBar("BR", d.br, { 240,160,70 })
        div()
    end

    local function blockStabADV()
        ln(" ATT - ADV", CR)
        div()
        local function advRow(lLbl, lFmt, lVal, lOn, rLbl, rFmt, rVal, rOn)
            local y = pad + row * lh
            row = row + 1
            if y > panelBottom - lh then return end
            local halfW = math.floor((pw - 6) / 2)
            local cells = {
                { x = x0 + 2,         lbl = lLbl, fmt = lFmt, v = lVal, on = lOn },
                { x = x0 + 4 + halfW, lbl = rLbl, fmt = rFmt, v = rVal, on = rOn },
            }
            for _, cell in ipairs(cells) do
                if cell.on and inRect(UI.hoverX, UI.hoverY,
                                      cell.x, y - 2, halfW, lh) then
                    grect(cell.x, y - 2, halfW, lh, { 18, 50, 80 })
                    grect(cell.x, y - 2, 2,     lh, { 80, 180, 255 })
                end
                gtext(string.format(cell.fmt, cell.lbl, cell.v),
                      cell.x + 3, y, CW, fs, "plain")
                if cell.on then
                    addScrollTarget(cell.x, y - 2, halfW, lh, cell.on)
                end
            end
            grect(x0 + 3 + halfW, y - 1, 1, lh - 2, { 60, 60, 80 })
        end
        ln(" TUNABLES", CGY)
        advRow("BLD", "%s %4.2f", INTEGRAL_BLEED,
               attActive and bumpIntBleed     or nil,
               "DIS", "%s %4.1f", DISTURBANCE_DEG,
               attActive and bumpDisturbance  or nil)
        advRow("KA",  "%s %5.3f", K_ALPHA,
               attActive and bumpKAlpha       or nil,
               "RSH", "%s %4.2f", RS_HOLD_TIME,
               attActive and bumpRsHold       or nil)
        div()
        ln(" PID OUTPUT", CGY)
        ln(string.format(" pOut %+6.2f", d.pitchOut or 0))
        ln(string.format(" rOut %+6.2f", d.rollOut  or 0))
        div()
        ln(" INTEGRAL", CGY)
        local function iLine(lbl, v)
            local headroom = math.min(math.abs((I_MAX or 40) - v),
                                      math.abs(v - (I_MIN or -40)))
            local col = CG
            if headroom < 5  then col = CR
            elseif headroom < 15 then col = CGY end
            ln(string.format(" %s %+6.2f (-%4.1f)", lbl, v or 0, headroom), col)
        end
        iLine("iP", d.iP or 0)
        iLine("iR", d.iR or 0)
        div()
        ln(" SATURATION (ticks)", CGY)
        ln(string.format(" pOut  %6d", d.satPitch or 0),
           (d.satPitch or 0) > 50 and CR or CW)
        ln(string.format(" rOut  %6d", d.satRoll  or 0),
           (d.satRoll  or 0) > 50 and CR or CW)
        ln(string.format(" iP clmp %4d  iR clmp %4d",
                          d.satIP or 0, d.satIR or 0),
           ((d.satIP or 0) + (d.satIR or 0)) > 50 and CR or CW)
    end

    local function blockAlt()
        ln(" ALTITUDE", CG)
        div()
        local err   = d.targetAlt - d.alt
        local onTgt = math.abs(err) < 1.5
        ln(string.format(" TGT %6.1f m",  d.targetAlt), CG)
        ln(string.format(" ALT %6.1f m",  d.alt),  onTgt and CG or CW)
        ln(string.format(" ERR %+6.1f m", err),
           math.abs(err) < 0.5 and CG or CW)
        div()
        ln(string.format(" VEL %+6.2f/s", d.velY),
           math.abs(d.velY) < 0.5 and CG or CW)
        div()

        local kpCol = (gainsKind == "alt") and CG or nil
        local kiCol = (gainsKind == "alt") and CR or nil
        local kdCol = (gainsKind == "alt") and CB or nil
        if altActive then
            scrollLn(string.format(" kP  %6.3f", A_KP),     kpCol, bumpAltKP)
            scrollLn(string.format(" kI  %6.3f", A_KI),     kiCol, bumpAltKI)
            scrollLn(string.format(" kD  %6.3f", A_KD_VEL), kdCol, bumpAltKD)
            scrollLn(string.format(" ff  %6.2f", A_FALLBACK), nil,  bumpAltFF)
        else
            ln(string.format(" kP  %6.3f", A_KP),     kpCol)
            ln(string.format(" kI  %6.3f", A_KI),     kiCol)
            ln(string.format(" kD  %6.3f", A_KD_VEL), kdCol)
            ln(string.format(" ff  %6.2f", A_FALLBACK))
        end

        local function altICol(v)
            local a = math.abs(v or 0)
            if a > 25 then return CR  end
            if a > 10 then return CGY end
            return CG
        end
        ln(string.format(" altI %+6.2f", d.altI or 0), altICol(d.altI))
        div()

        ln(string.format(" FF  %+6.1f",  d.ff))
        ln(string.format(" PID %+6.1f",  d.pidCorr))
        ln(string.format(" VD  %+6.1f",  -d.velDamp))
        ln(string.format(" RPM %6.0f",   d.rpm), CG)

        local glmRpm = d.glm or d.rpm or 0
        local glmCol = (glmRpm >= MOTOR_MAX - 1) and CR or CG
        bar("GLM", glmRpm, glmCol)
        div()
        if d.k then ln(string.format(" K  %.5f", d.k), CGY)
        else        ln(" K  warmup...",            CGY) end
        ln(string.format(" M  %.1f kg", d.mass),     CGY)
        ln(string.format(" Pa %.4f",    d.pressure), CGY)
    end

    local function blockAltADV()
        ln(" ALT - ADV", CR)
        div()
        ln(" TUNABLES", CGY)
        if altActive then
            scrollLn(string.format(" STEP %3d m", ALT_STEP), CW, bumpAltStep)

            scrollLn(string.format(" KA   %5.3f", K_ALPHA), CW, bumpKAlpha)
        else
            ln(string.format(" STEP %3d m", ALT_STEP), CW)
            ln(string.format(" KA   %5.3f", K_ALPHA), CW)
        end
        div()
        ln(" CONTROL EFFORT", CGY)
        ln(string.format(" FF  %+6.1f",  d.ff or 0))
        ln(string.format(" PID %+6.1f",  d.pidCorr or 0))
        ln(string.format(" VD  %+6.1f",  -(d.velDamp or 0)))
        ln(string.format(" sum %+6.1f -> %d rpm",
            (d.ff or 0) + (d.pidCorr or 0) - (d.velDamp or 0),
            d.glm or 0))
        div()
        ln(" INTEGRAL", CGY)
        local v = d.altI or 0
        local headroom = math.min(math.abs((I_MAX or 40) - v),
                                  math.abs(v - (I_MIN or -40)))
        local col = CG
        if headroom < 5  then col = CR
        elseif headroom < 15 then col = CGY end
        ln(string.format(" altI %+6.2f (-%4.1f)", v, headroom), col)
        div()
        ln(" LIFT EST", CGY)
        local kNow  = d.k     or 0
        local kPrev = d.kPrev or kNow
        local kDelta = kNow - kPrev
        if d.k then
            ln(string.format(" K   %.5f",  kNow), CGY)
            ln(string.format(" K-1 %.5f",  kPrev), CGY)
            ln(string.format(" dK  %+.5f", kDelta),
               math.abs(kDelta) > 1e-3 and CR or CG)
        else
            ln(" K  warmup...", CGY)
        end
        div()
        ln(" SATURATION (ticks)", CGY)
        ln(string.format(" GLM hi %5d", d.satGlmHi or 0),
           (d.satGlmHi or 0) > 50 and CR or CW)
        ln(string.format(" GLM lo %5d", d.satGlmLo or 0),
           (d.satGlmLo or 0) > 0  and CGY or CW)
        ln(string.format(" altI clamp %4d", d.satIA or 0),
           (d.satIA or 0) > 50 and CR or CW)
    end

    local stabFn, altFn
    if TIER == "ADV" then
        stabFn, altFn = blockStabADV, blockAltADV
    else
        stabFn, altFn = blockStab, blockAlt
    end

    if altActive then
        altFn()
    elseif attActive then
        stabFn()
    else

        stabFn(); altFn()
    end

    return x0 - 1
end

local PANEL_PAD = 6
local PANEL_GAP = 10

local function paintGraph(G, x, y, w, h, full, scrollFrac)
    if full then
        G:renderChrome(x, y, w, h)
        G:renderTrace(x, y, w, h, scrollFrac)
    else
        local okChrome = G:renderTrace(x, y, w, h, scrollFrac)
        if not okChrome then
            G:renderChrome(x, y, w, h)
            G:renderTrace(x, y, w, h, scrollFrac)
        end
    end
end

local function stackGeom()
    local PW, PH = dims()

    local areaH  = PH - PANEL_PAD * 2 - BTN_STRIP_H
    local half   = math.floor((areaH - PANEL_GAP) / 2)
    return PW, PH, areaH, half
end

local function drawStabGraph(d, full, sf)
    local PW, PH, areaH, half = stackGeom()
    local gx = drawSidePanel(d, nil)
    local areaX, areaW, areaY = PANEL_PAD, gx - PANEL_PAD * 2, PANEL_PAD
    paintGraph(G_stab_flux, areaX, areaY, areaW, half, full, sf)
    paintGraph(G_stab_err,  areaX, areaY + half + PANEL_GAP,
               areaW, areaH - half - PANEL_GAP, full, sf)
end

local function drawStabGains(d, full, sf)

    G_stab_gain_pitch.fixed_hi =  GAINS_RANGE
    G_stab_gain_pitch.fixed_lo = -GAINS_RANGE
    G_stab_gain_roll.fixed_hi  =  GAINS_RANGE
    G_stab_gain_roll.fixed_lo  = -GAINS_RANGE
    local PW, PH, areaH, half = stackGeom()
    local gx = drawSidePanel(d, "stab")
    local areaX, areaW, areaY = PANEL_PAD, gx - PANEL_PAD * 2, PANEL_PAD
    paintGraph(G_stab_gain_pitch, areaX, areaY, areaW, half, full, sf)
    paintGraph(G_stab_gain_roll,  areaX, areaY + half + PANEL_GAP,
               areaW, areaH - half - PANEL_GAP, full, sf)
end

local function drawAltGraph(d, full, sf)
    local PW, PH, areaH, half = stackGeom()
    local gx = drawSidePanel(d, nil)
    local areaX, areaW, areaY = PANEL_PAD, gx - PANEL_PAD * 2, PANEL_PAD
    paintGraph(G_alt_flux, areaX, areaY, areaW, half, full, sf)
    paintGraph(G_alt_trk,  areaX, areaY + half + PANEL_GAP,
               areaW, areaH - half - PANEL_GAP, full, sf)
end

local function drawAltGains(d, full, sf)
    local PW, PH = dims()
    G_alt_gain.fixed_hi =  GAINS_RANGE
    G_alt_gain.fixed_lo = -GAINS_RANGE
    local gx = drawSidePanel(d, "alt")
    paintGraph(G_alt_gain, PANEL_PAD, PANEL_PAD,
               gx - PANEL_PAD * 2,
               PH - PANEL_PAD * 2 - BTN_STRIP_H, full, sf)
end

local function ingestFrame(d)
    G_stab_flux:push({ FL=d.fl, FR=d.fr, BL=d.bl, BR=d.br })
    G_stab_err:push({ pitch=d.pitch, roll=d.roll })

    G_stab_gain_pitch:push({
        kP = P_KP * (-d.pitch),
        kI = P_KI * d.iP,
        kD = -(P_KD * d.angX),
    })
    G_stab_gain_roll:push({
        kP = R_KP * (-d.roll),
        kI = R_KI * d.iR,
        kD = -(R_KD * d.angZ),
    })
    G_alt_flux:push({ rpm = d.rpm })
    G_alt_trk:push({ alt = d.alt, target = d.targetAlt })
    G_alt_gain:push({
        kP = A_KP * (d.targetAlt - d.alt),
        kI = A_KI * d.altI,
        kD = -d.velDamp,
    })
end

local function renderFrame(d, sf)
    if not gpu then return end
    if not displayId then
        if not gpuEnsure() then return end
    end
    if not d then return end

    refreshUiTextScale()
    refreshButtonScale()

    consumeGpuEvents(function(cx, cy, button)
        if button == 1 then handleButtonClick(cx, cy) end
    end)

    local full = UI_DIRTY

    if full then
        local PW, PH = dims()
        grect(0, 0, PW, PH, CK)
    end

    if     UI_MODE == "stab_graph" then
        drawStabGraph(d, full, sf)
    elseif UI_MODE == "stab_gains" then
        drawStabGains(d, full, sf)
    elseif UI_MODE == "alt_graph" then
        drawAltGraph(d, full, sf)
    elseif UI_MODE == "alt_gains" then
        drawAltGains(d, full, sf)
    end

    drawButtons()

    UI_DIRTY = false
    gcommit()
end

local function getPitchRoll(q)
    local pitchRad, _, rollRad = q:toEuler()
    return math.deg(pitchRad), math.deg(rollRad)
end

local k_est = nil

local function getFeedforward(pressure, mass, gravity)
    if not pressure or pressure == 0 then return 0 end
    local ff
    if k_est then ff = (mass * gravity) / (k_est * pressure)
    else          ff = A_FALLBACK / pressure
    end

    if ff > MOTOR_MAX then ff = MOTOR_MAX end
    if ff < MOTOR_MIN then ff = MOTOR_MIN end
    return ff
end

local function updateK(mass, gravity, vertAccel, avgRPM, pressure)
    if avgRPM < K_MIN_RPM            then return end
    if not pressure or pressure == 0 then return end
    local lift = mass * (gravity + vertAccel)
    if lift <= 0                     then return end
    local kNew = lift / (avgRPM * pressure)
    k_est = k_est and (k_est * (1 - K_ALPHA) + kNew * K_ALPHA) or kNew
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function roundI(v)
    if v >= 0 then return math.floor(v + 0.5) end
    return -math.floor(-v + 0.5)
end

local M = {}

local function wrapMotors(cfg)
    local function w(name, lbl)
        local p = peripheral.wrap(name)
        if not p then error(lbl .. " not found: " .. name) end
        return p
    end
    M.GLM = w(cfg.GLM, "GLM")
    M.FL  = w(cfg.FL, "FL"); M.FR = w(cfg.FR, "FR")
    M.BL  = w(cfg.BL, "BL"); M.BR = w(cfg.BR, "BR")
end

local function setMotors(coll, pitchOut, rollOut)

    local glm = roundI(clamp(coll, MOTOR_MIN, MOTOR_MAX))
    local fl  = roundI(clamp(ATT_BASE + pitchOut - rollOut, MOTOR_MIN, MOTOR_MAX))
    local fr  = roundI(clamp(ATT_BASE + pitchOut + rollOut, MOTOR_MIN, MOTOR_MAX))
    local bl  = roundI(clamp(ATT_BASE - pitchOut - rollOut, MOTOR_MIN, MOTOR_MAX))
    local br  = roundI(clamp(ATT_BASE - pitchOut + rollOut, MOTOR_MIN, MOTOR_MAX))
    M.GLM.setTargetSpeed(glm)
    M.FL.setTargetSpeed(fl); M.FR.setTargetSpeed(fr)
    M.BL.setTargetSpeed(bl); M.BR.setTargetSpeed(br)
    return glm, fl, fr, bl, br
end

local function stopMotors()
    for _, m in pairs(M) do pcall(function() m.setTargetSpeed(0) end) end
end

local pitchPID, rollPID, altPID

local function makeControlStep()
    local lastTime = os.clock()
    local prevVelY = 0
    local lastColl = 0

    return function()
        local now = os.clock()
        local dt  = math.max(now - lastTime, 0.001)
        lastTime  = now

        local pose    = sublevel.getLogicalPose()
        local pos     = pose.position
        local angVel  = sublevel.getAngularVelocity()
        local linVel  = sublevel.getLinearVelocity()
        local mass    = sublevel.getMass()
        local pitch, roll = getPitchRoll(pose.orientation)

        local pressure = aero.getAirPressure(pos)
        local gravVec  = aero.getGravity()
        local gravity  = math.abs(gravVec.y)

        local velY      = linVel.y
        local vertAccel = (velY - prevVelY) / dt
        prevVelY        = velY

        updateK(mass, gravity, vertAccel, lastColl, pressure)
        local ff      = getFeedforward(pressure, mass, gravity)

        local satHi = (lastColl or 0) >= MOTOR_MAX - 1e-6
        local satLo = (lastColl or 0) <= MOTOR_MIN + 1e-6
        altPID:setSaturated(satHi, satLo)
        local pidCorr = altPID:step(pos.y, dt)
        local velDamp = A_KD_VEL * velY
        local coll    = clamp(ff + pidCorr - velDamp, MOTOR_MIN, MOTOR_MAX)
        lastColl      = coll

        if math.abs(roll)  > DISTURBANCE_DEG then
            rollPID.integral  = rollPID.integral  * INTEGRAL_BLEED
        end
        if math.abs(pitch) > DISTURBANCE_DEG then
            pitchPID.integral = pitchPID.integral * INTEGRAL_BLEED
        end
        local pitchOutRaw = pitchPID:step(pitch, dt) - P_KD * angVel.x
        local rollOutRaw  = rollPID:step(roll,   dt) - R_KD * angVel.z
        local pitchOut = clamp(pitchOutRaw, O_MIN, O_MAX)
        local rollOut  = clamp(rollOutRaw,  O_MIN, O_MAX)

        if pitchOutRaw ~= pitchOut then SAT.pitchOut = SAT.pitchOut + 1 end
        if rollOutRaw  ~= rollOut  then SAT.rollOut  = SAT.rollOut  + 1 end
        if pitchPID.integral >= I_MAX - 1e-6
        or pitchPID.integral <= I_MIN + 1e-6 then SAT.iPClamp = SAT.iPClamp + 1 end
        if rollPID.integral  >= I_MAX - 1e-6
        or rollPID.integral  <= I_MIN + 1e-6 then SAT.iRClamp = SAT.iRClamp + 1 end
        if altPID.integral   >= I_MAX - 1e-6
        or altPID.integral   <= I_MIN + 1e-6 then SAT.iAClamp = SAT.iAClamp + 1 end
        if coll >= MOTOR_MAX - 1e-6 then SAT.glmHigh = SAT.glmHigh + 1 end
        if coll <= MOTOR_MIN + 1e-6 then SAT.glmLow  = SAT.glmLow  + 1 end

        local glm, fl, fr, bl, br = setMotors(coll, pitchOut, rollOut)

        local kPrev = (FRAME.cur and FRAME.cur.k) or k_est
        FRAME.prev = FRAME.cur
        FRAME.cur  = {
            pitch = pitch, roll = roll,
            angX  = angVel.x, angZ = angVel.z,
            glm = glm, fl = fl, fr = fr, bl = bl, br = br,
            iP = pitchPID.integral, iR = rollPID.integral,
            alt = pos.y, targetAlt = TARGET_ALT, velY = velY,
            rpm = coll, ff = ff, pidCorr = pidCorr, velDamp = velDamp,
            altI = altPID.integral, k = k_est, kPrev = kPrev,
            mass = mass, pressure = pressure,

            pitchOut = pitchOut, rollOut = rollOut,
            satPitch = SAT.pitchOut, satRoll  = SAT.rollOut,
            satIP    = SAT.iPClamp, satIR    = SAT.iRClamp,
            satIA    = SAT.iAClamp,
            satGlmHi = SAT.glmHigh, satGlmLo = SAT.glmLow,
        }
        FRAME.t_prev = FRAME.t_cur
        FRAME.t_cur  = os.clock()
        FRAME.seq    = FRAME.seq + 1
    end
end

local RELAY_SIDE = "front"

local function redstoneLoop()
    local cfg = currentCfg or {}
    local upName   = cfg.RELAY_UP
    local downName = cfg.RELAY_DOWN

    local function describe(label, name)
        if not name then
            print("RS: " .. label .. " relay unset -- no altitude trim that way")
            return nil
        end
        local p = peripheral.wrap(name)
        if not p then
            print("RS: " .. label .. " relay '" .. name
                  .. "' not present -- check wiring")
            return nil
        end
        return p
    end

    describe("UP",   upName)
    describe("DOWN", downName)

    local riseTime = { up = nil, down = nil }

    local function step(dir, label)
        if dir > 0 then
            TARGET_ALT = TARGET_ALT + ALT_STEP
        else
            TARGET_ALT = TARGET_ALT - ALT_STEP
        end
        altPID:setSP(TARGET_ALT); altPID:reset()
        term.setCursorPos(1, 16); term.clearLine()
        print("RS: " .. label .. " -> alt " .. TARGET_ALT .. " m")
    end

    while true do
        os.pullEvent("redstone")
        local now = os.clock()

        local relayUp = upName and peripheral.wrap(upName) or nil
        if relayUp then
            local rUp = relayUp.getInput(RELAY_SIDE)
            if rUp and not riseTime.up then
                riseTime.up = now
            elseif not rUp and riseTime.up then
                if (now - riseTime.up) >= RS_HOLD_TIME then
                    step(1, "+" .. ALT_STEP .. "m")
                end
                riseTime.up = nil
            end
        end

        local relayDown = downName and peripheral.wrap(downName) or nil
        if relayDown then
            local rDown = relayDown.getInput(RELAY_SIDE)
            if rDown and not riseTime.down then
                riseTime.down = now
            elseif not rDown and riseTime.down then
                if (now - riseTime.down) >= RS_HOLD_TIME then
                    step(-1, "-" .. ALT_STEP .. "m")
                end
                riseTime.down = nil
            end
        end
    end
end

local function printHelp()
    print("-- VIEWS --")
    print("  stab graph   motor flux + attitude error")
    print("  stab gains   per-axis kP/kI/kD contribution")
    print("  alt graph    collective RPM + alt tracking")
    print("  alt gains    kP/kI/kD contribution (altitude)")
    print("-- TUNE (attitude, per axis) --")
    print("  pitch kp|ki|kd <n>")
    print("  roll  kp|ki|kd <n>")
    print("  stab  kp|ki|kd <n>  set BOTH pitch and roll")
    print("  stab base <n>       attitude rotor idle rpm (now " .. ATT_BASE .. ")")
    print("-- TUNE (altitude) --")
    print("  alt  kp|ki|kd <n>   |   alt ff <n>")
    print("  alt  set <n>        command target altitude")
    print("  gr <n>              graph half-range (now " .. GAINS_RANGE .. ")")
    print("-- SYSTEM --")
    print("  save | reset | help")
    print("  [RS] UP relay  -> +" .. ALT_STEP .. "m")
    print("  [RS] DOWN relay -> -" .. ALT_STEP .. "m")
end

local function setView(m, label)

    if     m == "stab_graph" then MODE, SUB = "ATT", "GRAPH"
    elseif m == "stab_gains" then MODE, SUB = "ATT", "GAINS"
    elseif m == "alt_graph"  then MODE, SUB = "ALT", "GRAPH"
    elseif m == "alt_gains"  then MODE, SUB = "ALT", "GAINS"
    end
    UI_MODE = m
    UI_DIRTY = true
    if displayId then pcall(function() gpu.clear(displayId, 0,0,0); gpu.updateDisplay(displayId) end) end
    print("View: " .. label)
end

local function inputLoop()
    while true do
        io.write("> ")
        local line = read()
        if line then

            local g, s, num = line:match("^(%a+)%s+(%a+)%s*(%-?%d*%.?%d*)")
            local one, oneNum = line:match("^(%a+)%s*(%-?%d*%.?%d*)")
            g = g and g:lower(); s = s and s:lower()
            one = one and one:lower()
            local n = tonumber(num)
            local n1 = tonumber(oneNum)

            if g == "stab" and s == "graph" then
                setView("stab_graph", "stabiliser graph")
            elseif g == "stab" and s == "gains" then
                setView("stab_gains", "stabiliser gains")
            elseif g == "alt" and s == "graph" then
                setView("alt_graph", "altitude graph")
            elseif g == "alt" and s == "gains" then
                setView("alt_gains", "altitude gains")

            elseif g == "pitch" and s == "kp" and n then
                P_KP = n; pitchPID:setGains(P_KP, P_KI, P_KD)
                print("pitch kP = " .. string.format("%.3f", P_KP))
            elseif g == "pitch" and s == "ki" and n then
                P_KI = n; pitchPID:setGains(P_KP, P_KI, P_KD)
                print("pitch kI = " .. string.format("%.3f", P_KI))
            elseif g == "pitch" and s == "kd" and n then
                P_KD = n; pitchPID:setGains(P_KP, P_KI, P_KD)
                print("pitch kD = " .. string.format("%.3f", P_KD))

            elseif g == "roll" and s == "kp" and n then
                R_KP = n; rollPID:setGains(R_KP, R_KI, R_KD)
                print("roll kP = " .. string.format("%.3f", R_KP))
            elseif g == "roll" and s == "ki" and n then
                R_KI = n; rollPID:setGains(R_KP, R_KI, R_KD)
                print("roll kI = " .. string.format("%.3f", R_KI))
            elseif g == "roll" and s == "kd" and n then
                R_KD = n; rollPID:setGains(R_KP, R_KI, R_KD)
                print("roll kD = " .. string.format("%.3f", R_KD))

            elseif g == "stab" and s == "kp" and n then
                P_KP, R_KP = n, n
                pitchPID:setGains(P_KP, P_KI, P_KD)
                rollPID:setGains(R_KP, R_KI, R_KD)
                print("stab (pitch+roll) kP = " .. string.format("%.3f", n))
            elseif g == "stab" and s == "ki" and n then
                P_KI, R_KI = n, n
                pitchPID:setGains(P_KP, P_KI, P_KD)
                rollPID:setGains(R_KP, R_KI, R_KD)
                print("stab (pitch+roll) kI = " .. string.format("%.3f", n))
            elseif g == "stab" and s == "kd" and n then
                P_KD, R_KD = n, n
                pitchPID:setGains(P_KP, P_KI, P_KD)
                rollPID:setGains(R_KP, R_KI, R_KD)
                print("stab (pitch+roll) kD = " .. string.format("%.3f", n))

            elseif g == "stab" and s == "base" and n then
                ATT_BASE = math.max(0, math.floor(n))
                print("attitude rotor base = " .. ATT_BASE .. " rpm")

            elseif g == "alt" and s == "kp" and n then
                A_KP = n; altPID:setGains(A_KP,A_KI)
                print("alt kP = " .. string.format("%.3f", A_KP))
            elseif g == "alt" and s == "ki" and n then
                A_KI = n; altPID:setGains(A_KP,A_KI)
                print("alt kI = " .. string.format("%.3f", A_KI))
            elseif g == "alt" and s == "kd" and n then
                A_KD_VEL = n
                print("alt kD (vel damp) = " .. string.format("%.3f", A_KD_VEL))
            elseif g == "alt" and s == "ff" and n then
                A_FALLBACK = n
                print("alt ff = " .. string.format("%.2f", A_FALLBACK))
            elseif g == "alt" and s == "set" and n then
                TARGET_ALT = n; altPID:setSP(n); altPID:reset()
                print("target altitude = " .. string.format("%.1f", n) .. " m")

            elseif one == "gr" and n1 then
                GAINS_RANGE = math.max(1, math.floor(n1))
                UI_DIRTY = true
                print("graph half-range = +-" .. GAINS_RANGE)
            elseif one == "save" then
                currentCfg.P_KP=P_KP; currentCfg.P_KI=P_KI; currentCfg.P_KD=P_KD
                currentCfg.R_KP=R_KP; currentCfg.R_KI=R_KI; currentCfg.R_KD=R_KD

                currentCfg.S_KP=nil; currentCfg.S_KI=nil; currentCfg.S_KD=nil
                currentCfg.A_KP=A_KP; currentCfg.A_KI=A_KI
                currentCfg.A_KD_VEL=A_KD_VEL; currentCfg.A_FALLBACK=A_FALLBACK
                currentCfg.ATT_BASE=ATT_BASE

                currentCfg.INTEGRAL_BLEED  = INTEGRAL_BLEED
                currentCfg.DISTURBANCE_DEG = DISTURBANCE_DEG
                currentCfg.K_ALPHA         = K_ALPHA
                currentCfg.RS_HOLD_TIME    = RS_HOLD_TIME
                currentCfg.ALT_STEP        = ALT_STEP

                currentCfg.STATE_iP        = pitchPID.integral
                currentCfg.STATE_iR        = rollPID.integral
                currentCfg.STATE_iA        = altPID.integral
                currentCfg.STATE_k         = k_est
                currentCfg.STATE_targetAlt = TARGET_ALT

                saveConfig(currentCfg)
                print("All gains saved to " .. CFG_FILE)
                print(string.format(
                    "  state: iP=%.3f iR=%.3f iA=%.3f k=%s tgt=%.1fm",
                    pitchPID.integral, rollPID.integral, altPID.integral,
                    k_est and string.format("%.6f", k_est) or "nil",
                    TARGET_ALT))
            elseif one == "reset" then
                pitchPID:reset(); rollPID:reset(); altPID:reset()
                print("All integrators reset.")
            elseif one == "help" or one == "h" then
                printHelp()
            else
                print("Unknown. Type help.")
            end
        end
    end
end

local cfg = wizard()
currentCfg = cfg
print("")
print("Wrapping motors...")
wrapMotors(cfg)
stopMotors()

gpu = peripheral.find("directgpu")
if not gpu then
    error("CC:DirectGPU not found. The fused UI requires a DirectGPU block.")
end
print("CC:DirectGPU peripheral found. Display created on first draw.")

pitchPID = SPID.new(P_KP, P_KI, P_KD)
rollPID  = SPID.new(R_KP, R_KI, R_KD)

print("Reading initial state...")
sleep(0.3)
local initPose = sublevel.getLogicalPose()
TARGET_ALT = math.floor(initPose.position.y)
local p0, r0 = getPitchRoll(initPose.orientation)
print(string.format("  Pitch %+.2f  Roll %+.2f  Alt %d m", p0, r0, TARGET_ALT))

altPID = APID.new(A_KP, A_KI)
altPID:setSP(TARGET_ALT)

if cfg then
    if cfg.STATE_targetAlt then
        TARGET_ALT = cfg.STATE_targetAlt
        altPID:setSP(TARGET_ALT)
    end
    if cfg.STATE_iP then pitchPID.integral = cfg.STATE_iP end
    if cfg.STATE_iR then rollPID.integral  = cfg.STATE_iR end
    if cfg.STATE_iA then altPID.integral   = cfg.STATE_iA end
    if cfg.STATE_k  then k_est             = cfg.STATE_k  end
    if cfg.STATE_iP or cfg.STATE_iR or cfg.STATE_iA or cfg.STATE_k then
        print(string.format(
            "Restored state: iP=%.3f iR=%.3f iA=%.3f k=%s tgt=%.1fm",
            pitchPID.integral, rollPID.integral, altPID.integral,
            k_est and string.format("%.6f", k_est) or "nil",
            TARGET_ALT))
    end
end

CTRL.pitchPID = pitchPID
CTRL.rollPID  = rollPID
CTRL.altPID   = altPID

print("Type 'help' for commands. 'save' to persist gains.")
print("Starting in 2s... Ctrl+T to stop.")
sleep(2)

local controlStep = makeControlStep()

term.clear(); term.setCursorPos(1, 1)
print("FUSED FLIGHT CONTROLLER running. Ctrl+T to stop.")
printHelp()
print("")

local function renderLoop()
    local EV = "fg_render"
    os.queueEvent(EV)
    local minDt = 1 / RENDER_HZ
    local lastPaint = os.clock()

    while true do
        os.pullEvent(EV)

        local now = os.clock()
        if now - lastPaint >= minDt then

            if FRAME.seq ~= FRAME.seen and FRAME.cur then
                ingestFrame(FRAME.cur)
                FRAME.seen = FRAME.seq
            end

            local sf = 0
            if FRAME.t_cur > 0 then
                local period = FRAME.t_cur - FRAME.t_prev
                if period <= 0 then period = LOOP_RATE end
                sf = (now - FRAME.t_cur) / period
                if sf < 0 then sf = 0 elseif sf > 1 then sf = 1 end
            end

            renderFrame(FRAME.cur, sf)
            lastPaint = now
        end

        os.queueEvent(EV)
    end
end

local function scrollLoop()
    while true do
        local _, dir = os.pullEvent("mouse_scroll")
        dispatchScroll(dir)
    end
end

local ok, err = pcall(function()
    parallel.waitForAny(
        function()
            while true do
                local ok2, e2 = pcall(controlStep)
                if not ok2 then
                    term.setCursorPos(1, 14); term.clearLine()
                    print("WARN: " .. tostring(e2))
                end
                sleep(LOOP_RATE)
            end
        end,
        renderLoop,
        inputLoop,
        redstoneLoop,
        scrollLoop
    )
end)

stopMotors()
gpuRelease()
term.clear(); term.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then
    printError("Crashed: " .. tostring(err))
else
    print("Stopped. Motors zeroed.")
end
