-- ================================================================
--  5altgraph.lua  --  Altitude Hold Controller
--
--  USAGE:
--    1. Copy to computer root as 5altgraph.lua  ->  run: 5altgraph
--    2. Setup wizard  |  alt/kp/ki/kd/ff/save/reset
--       indicator : altimeter tape
--       graph     : RPM flux + altitude tracking (telem)
--       gains     : kP/kI/kD contribution graph (telem)
--       gr <n>    : set gains Y-axis half-range RPM (now 20)
--    3. Ctrl+T to stop
--
--  QUICK TUNING
--  ---------------------------------------------------------------
--  Sinks or climbs at target     -> adjust ff
--  Slow to reach altitude        -> raise kP
--  Overshoots and bounces        -> raise kD
--  Oscillates up and down        -> lower kP  OR  raise kD
--  Settles a few blocks off      -> raise kI  (add slowly)
--  Slow growing oscillation      -> lower kI
-- ================================================================


-- ================================================================
--  §1  DEFAULTS  (overwritten by saved config if present)
-- ================================================================

local TARGET_ALT = 64

local KP        = 2.0
local KI        = 0.08
local KD_VEL    = 2.5
local FALLBACK_C = 62.0

local MOTOR_MIN    =   0
local MOTOR_MAX    = 256
local I_MIN, I_MAX = -40,  40
local O_MIN, O_MAX = -80,  80

local K_ALPHA   = 0.05
local K_MIN_RPM = 20

local LOOP_RATE = 0.05
local CFG_FILE  = "/5altgraph_cfg.lua"

-- Altitude step applied by a sustained redstone pulse on left/right sides
local ALT_STEP      = 10     -- blocks per valid pulse
local RS_HOLD_TIME  = 0.01   -- seconds the signal must be held to count

-- ================================================================
--  GAINS GRAPH  (telem multiLine)
--
--  Single window, full height.  One backplane with 6 metrics:
--    kP  = KP * altError          -> lime
--    kI  = KI * integral          -> red
--    kD  = -(KD_VEL * velY)       -> blue  (vel-damp contribution)
--    ref = 0                      -> white (reference: zero correction)
--    scale_hi = +GAINS_RANGE      -> black (invisible Y-axis upper bound)
--    scale_lo = -GAINS_RANGE      -> black (invisible Y-axis lower bound)
-- ================================================================

local UI_MODE     = "indicator"
local GAINS_RANGE = 20

local TA = { kp_a=0, ki_a=0, kd_a=0 }

local telem_lib  = nil
local gainsBP    = nil
local gainsWin   = nil
local gains_gW   = 0   -- gains graph width (cached from entry point)

local function setupGainsBackplane()
    if not telem_lib or not gainsWin then return end
    local t = telem_lib
    gainsBP = t.backplane()
        :addInput('pid', t.input.custom(function()
            return {
                kP       = TA.kp_a,
                kI       = TA.ki_a,
                kD       = TA.kd_a,
                ref      = 0,
                scale_hi =  GAINS_RANGE,
                scale_lo = -GAINS_RANGE,
            }
        end))
        :addOutput('gplot', t.output.plotter.multiLine(gainsWin, {
            { name = 'kP',       color = colors.lime  },
            { name = 'kI',       color = colors.red   },
            { name = 'kD',       color = colors.blue  },
            { name = 'ref',      color = colors.white },
            { name = 'scale_hi', color = colors.black },
            { name = 'scale_lo', color = colors.black },
        }, colors.black, colors.white, gains_gW))
end

local TS  = { rpm=0, alt=0, targetAlt=64 }
local mon = nil

local graphBP1, graphBP2   -- telem backplanes for graph mode

local ALT_CENTRE_RANGE = 30

local function drawGraph(mon, mW, mH, d, pw)
    TS.rpm       = d.rpm
    TS.alt       = d.alt
    TS.targetAlt = d.targetAlt

    if graphBP1 then graphBP1:cycle() end
    if graphBP2 then graphBP2:cycle() end

    local graphW = mW - 1 - pw
    local g1H    = math.floor((mH - 1) / 2)
    local sepRow = g1H + 1
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lime)
    mon.setCursorPos(1, sepRow)
    mon.write(string.rep("-", graphW))

    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    local lbl1 = "RPM Flux"
    local lbl2 = "Alt. Hold"
    mon.setCursorPos(graphW - #lbl1 + 1, 1);          mon.write(lbl1)
    mon.setCursorPos(graphW - #lbl2 + 1, sepRow + 1); mon.write(lbl2)
end


-- ================================================================
--  §2  EMBEDDED PID
-- ================================================================

local PID = {}
PID.__index = PID

function PID.new(kp, ki)
    return setmetatable({
        sp=TARGET_ALT, kp=kp, ki=ki,
        integral=0, prevErr=0,
    }, PID)
end

function PID:step(measured, dt)
    if dt <= 0 then return 0 end
    local err     = self.sp - measured
    self.integral = math.max(I_MIN, math.min(I_MAX, self.integral + err * dt))
    return math.max(O_MIN, math.min(O_MAX,
           self.kp * err + self.ki * self.integral))
end

function PID:reset()           self.integral = 0; self.prevErr = 0     end
function PID:setSP(sp)         self.sp = sp                             end
function PID:setGains(kp, ki)  self.kp=kp; self.ki=ki                  end


-- ================================================================
--  §3  CONFIG / WIZARD
--  Gains (KP, KI, KD_VEL, FALLBACK_C) are stored alongside
--  peripheral names in the same config file.
--  Use the  save  command to persist gains changed mid-flight.
-- ================================================================

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

local currentCfg

local function wizard()
    term.clear(); term.setCursorPos(1, 1)

    local saved = loadConfig()
    if saved then
        print("-- Saved config --")
        print("  GLM: " .. saved.FL)
        print("  Monitor: " .. saved.monitor)
        print(string.format("  Gains: kP=%.3f  kI=%.3f  kD=%.3f  ff=%.2f",
            saved.KP or KP, saved.KI or KI,
            saved.KD_VEL or KD_VEL, saved.FALLBACK_C or FALLBACK_C))
        io.write("Use this? [Y/n]: ")
        local a = read()
        if a == "" or a:lower() == "y" then
            if saved.KP         then KP         = saved.KP         end
            if saved.KI         then KI         = saved.KI         end
            if saved.KD_VEL     then KD_VEL     = saved.KD_VEL     end
            if saved.FALLBACK_C then FALLBACK_C = saved.FALLBACK_C end
            return saved
        end
    end

    term.clear(); term.setCursorPos(1, 1)
    print("-- ALES'S ALTSTAB SETUP --")
    print("")
    print("Available peripherals:")

    local names = peripheral.getNames()
    local sugg  = {}
    for _, n in ipairs(names) do
        print(string.format("  %-36s (%s)", n, peripheral.getType(n)))
        sugg[#sugg+1] = n
    end
    for _, s in ipairs({"top","bottom","left","right","front","back"}) do
        sugg[#sugg+1] = s
    end
    print("")

    local function ask(label, def)
        io.write(string.format("  %-22s [%s]: ", label, def))
        local inp = read(nil, nil, function(t)
            local r = {}
            for _, s in ipairs(sugg) do
                if s:sub(1,#t)==t then r[#r+1]=s:sub(#t+1) end
            end
            return r
        end)
        return (inp==nil or inp=="") and def or inp
    end

    local fl  = ask("General Lift Motor/s",  "RSC Main")
    local fr  = fl
    local bl  = fl
    local br  = fl
    local mon = ask("Monitor side/name",      "Rectangular Display")
    print("")

    print("Checking peripherals...")
    local ok = true
    for lbl, name in pairs({GLM=fl}) do
        local found = peripheral.wrap(name) ~= nil
        print(string.format("  %s (%s) %s", lbl, name, found and "OK" or "NOT FOUND"))
        if not found then ok=false end
    end
    local mFound = peripheral.wrap(mon) ~= nil
    print("  Monitor (" .. mon .. ") " .. (mFound and "OK" or "NOT FOUND"))
    if not mFound then ok=false end
    if not ok then print("WARNING: some peripherals missing.") end

    print("")
    io.write("Save config? [y/n]: ")
    local sv  = read()
    local cfg = {
        FL=fl, FR=fr, BL=bl, BR=br, monitor=mon,
        KP=KP, KI=KI, KD_VEL=KD_VEL, FALLBACK_C=FALLBACK_C,
    }
    if sv=="" or sv:lower()=="y" then
        saveConfig(cfg); print("Saved to " .. CFG_FILE)
    end
    return cfg
end


-- ================================================================
--  §4  ALTIMETER DISPLAY  (black & white + green accents)
--
--  Colour palette (blit hex, all single-byte ASCII):
--    "0" = white    "5" = lime (green)    "f" = black    "7" = gray
--
--  Above current altitude  = white bg  ("0")
--  Below current altitude  = black bg  ("f")
--  Current altitude row    = lime bg   ("5")  <-- green line
--  Target marker           = lime bg   ("5")
--  VSI bar                 = lime when climbing, gray when sinking
--  All text                = white on black, black on white/lime
-- ================================================================

local C_ABOVE   = "0"   -- white  (sky region of tape)
local C_BELOW   = "f"   -- black  (ground region of tape)
local C_CUR_BG  = "5"   -- lime   (current altitude highlight)
local C_CUR_FG  = "f"   -- black  (text on lime)
local C_TGT_BG  = "5"   -- lime   (target marker)
local C_TGT_FG  = "f"   -- black
local C_TICK    = "f"   -- black  (ticks on white region)
local C_TICK2   = "0"   -- white  (ticks on black region)
local C_NUM     = "7"   -- gray   (altitude numbers)
local C_VSI_UP  = "5"   -- lime   (climbing)
local C_VSI_DN  = "7"   -- gray   (sinking)

local SCALE = 2   -- blocks per character row on the tape

-- ---- Buffer helpers ------------------------------------------

local function newBuf(w, h)
    local b = {}
    for y = 1, h do
        b[y] = {}
        for x = 1, w do b[y][x] = {" ", "f", C_ABOVE} end
    end
    return b
end

local function bset(b, x, y, ch, fg, bg)
    if b[y] and b[y][x] and #ch == 1 then
        b[y][x] = {ch, fg, bg}
    end
end

local function flushBuf(b, mon, ox, oy)
    local cs, fs, bs = {}, {}, {}
    for y = 1, #b do
        local row = b[y]
        local n   = #row
        for x = 1, n do
            cs[x] = row[x][1]
            fs[x] = row[x][2]
            bs[x] = row[x][3]
        end
        mon.setCursorPos(ox, oy + y - 1)
        mon.blit(
            table.concat(cs, "", 1, n),
            table.concat(fs, "", 1, n),
            table.concat(bs, "", 1, n)
        )
    end
end

-- ---- Tape ---------------------------------------------------

local function altToRow(alt, currentAlt, centreRow)
    return centreRow - math.floor((alt - currentAlt) / SCALE + 0.5)
end

local function drawTape(buf, w, h, currentAlt, targetAlt, velY)
    local centreRow = math.floor(h * 0.5)

    -- Background: white above centre (sky), black below (ground)
    for y = 1, h do
        local bg = (y <= centreRow) and C_ABOVE or C_BELOW
        local row = buf[y]
        for x = 1, w do row[x] = {" ", "f", bg} end
    end

    -- Ticks and altitude numbers
    local visRange = math.floor(h * SCALE * 0.5) + SCALE * 2
    local startAlt = math.floor((currentAlt - visRange) / 5) * 5
    local endAlt   = currentAlt + visRange

    for alt = startAlt, endAlt, 5 do
        local row  = altToRow(alt, currentAlt, centreRow)
        if row >= 1 and row <= h then
            local above  = (row <= centreRow)
            local bg     = above and C_ABOVE or C_BELOW
            local tickFg = above and C_TICK   or C_TICK2
            local is10   = (alt % 10 == 0)

            if is10 then
                -- Number right-aligned, leaving room for tick
                local lbl  = tostring(alt)
                local maxW = w - 5
                if #lbl > maxW then lbl = lbl:sub(#lbl - maxW + 1) end
                local startX = w - 1 - #lbl
                for i = 1, #lbl do
                    local xi = startX + i - 1
                    if xi >= 1 and xi <= w then
                        bset(buf, xi, row, lbl:sub(i,i), C_NUM, bg)
                    end
                end
                -- Major tick
                bset(buf, 4, row, "|", tickFg, bg)
            else
                -- Minor tick
                bset(buf, 4, row, "'", tickFg, bg)
            end
        end
    end

    -- Target marker: lime band labelled "T<altitude>"
    local tgtRow = altToRow(targetAlt, currentAlt, centreRow)
    if tgtRow >= 1 and tgtRow <= h then
        local tgtLbl = "T" .. tostring(math.floor(targetAlt)) .. ">"
        if #tgtLbl > w - 1 then tgtLbl = tgtLbl:sub(1, w - 1) end
        for i = 1, #tgtLbl do
            bset(buf, i, tgtRow, tgtLbl:sub(i,i), C_TGT_FG, C_TGT_BG)
        end
    end

    -- Current altitude highlight: 3-row lime band at centre
    for dy = -1, 1 do
        local y = centreRow + dy
        if y >= 1 and y <= h then
            local row = buf[y]
            for x = 1, w do
                row[x] = {row[x][1], C_CUR_FG, C_CUR_BG}
            end
        end
    end

    -- Current altitude readout centred in the highlight
    local curLbl = string.format("%.1f", currentAlt)
    local full   = ">> " .. curLbl .. " <<"
    if #full > w then full = curLbl:sub(1, w) end
    local lx = math.floor((w - #full) * 0.5) + 1
    for i = 1, #full do
        local xi = lx + i - 1
        if xi >= 1 and xi <= w then
            bset(buf, xi, centreRow, full:sub(i,i), C_CUR_FG, C_CUR_BG)
        end
    end

    -- VSI bar: columns 1-2, grows from centre up (climb) or down (sink)
    local vsiMax  = 10.0
    local vsiCap  = math.max(-vsiMax, math.min(vsiMax, velY))
    local vsiRows = math.floor(math.abs(vsiCap) / vsiMax * (h * 0.4) + 0.5)
    local vsiCol  = (vsiCap >= 0) and C_VSI_UP or C_VSI_DN

    -- Clear VSI columns first
    for y = 1, h do
        local bg = (y <= centreRow) and C_ABOVE or C_BELOW
        bset(buf, 1, y, " ", "0", bg)
        bset(buf, 2, y, " ", "0", bg)
        bset(buf, 3, y, " ", "0", bg)
    end

    if vsiCap >= 0 then
        for r = 0, vsiRows - 1 do
            local y = centreRow - r
            if y >= 1 then
                bset(buf, 1, y, " ", "0", vsiCol)
                bset(buf, 2, y, " ", "0", vsiCol)
            end
        end
    else
        for r = 0, vsiRows - 1 do
            local y = centreRow + r
            if y <= h then
                bset(buf, 1, y, " ", "0", vsiCol)
                bset(buf, 2, y, " ", "0", vsiCol)
            end
        end
    end

    -- VSI centre tick on the lime highlight row
    bset(buf, 1, centreRow, "-", C_CUR_FG, C_CUR_BG)
    bset(buf, 2, centreRow, "-", C_CUR_FG, C_CUR_BG)
    bset(buf, 3, centreRow, "-", C_CUR_FG, C_CUR_BG)
end

-- ---- Data panel ---------------------------------------------

local function drawDataPanel(mon, x0, y0, pw, ph, d)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)

    local row = 0
    local function ln(t, col)
        row = row + 1
        if row > ph then return end
        mon.setCursorPos(x0, y0 + row - 1)
        if col then mon.setTextColor(col) end
        t = (t or ""):sub(1, pw)
        mon.write(t .. string.rep(" ", math.max(0, pw - #t)))
        mon.setTextColor(colors.white)
    end
    local function div()
        -- Lime divider lines -- the "middle lines" in green
        ln(string.rep("-", pw), colors.lime)
    end

    ln(" ALTSTAB",  colors.lime)
    div()

    -- Altitude
    local err   = d.targetAlt - d.alt
    local onTgt = math.abs(err) < 1.5
    ln(string.format(" TGT %6.1f m",  d.targetAlt), colors.lime)
    ln(string.format(" ALT %6.1f m",  d.alt),
       onTgt and colors.lime or colors.white)
    ln(string.format(" ERR %+6.1f m", err),
       math.abs(err) < 0.5 and colors.lime or colors.white)
    div()

    -- Vertical velocity
    ln(string.format(" VEL %+6.2f/s", d.velY),
       math.abs(d.velY) < 0.5 and colors.lime or colors.white)
    div()

    -- RPM breakdown
    ln(string.format(" FF  %+6.1f",  d.ff))
    ln(string.format(" PID %+6.1f",  d.pidCorr))
    ln(string.format(" VD  %+6.1f",  -d.velDamp))
    div()
    ln(string.format(" RPM %6.0f",   d.rpm), colors.lime)
    div()

    -- Live gains: coloured only in gains mode (kP=lime, kI=red, kD=blue)
    if UI_MODE == "gains" then
        ln(string.format(" kP  %6.3f", KP),       colors.lime)
        ln(string.format(" kI  %6.3f", KI),       colors.red)
        ln(string.format(" kD  %6.3f", KD_VEL),   colors.blue)
    else
        ln(string.format(" kP  %6.3f", KP))
        ln(string.format(" kI  %6.3f", KI))
        ln(string.format(" kD  %6.3f", KD_VEL))
    end
    ln(string.format(" ff  %6.2f", FALLBACK_C))
    div()

    -- Physics / K estimator
    if d.k then
        ln(string.format(" K  %.5f", d.k), colors.gray)
    else
        ln(" K  warmup...",              colors.gray)
    end
    ln(string.format(" M  %.1f kg", d.mass),    colors.gray)
    ln(string.format(" Pa %.4f",    d.pressure),colors.gray)
    div()

    -- Integral
    ln(string.format(" I  %+5.2f", d.integral))
    div()

    -- Status
    if onTgt and math.abs(d.velY) < 0.3 then
        ln(" HOLDING",  colors.lime)
    elseif err > 0 then
        ln(" CLIMBING", colors.white)
    else
        ln(" DESCEND",  colors.white)
    end
end

-- ---- Gains graph draw (telem) -------------------------------------

local function drawGainsGraph(mon, mW, mH, d, pw)
    TA.kp_a = KP     * (TARGET_ALT - d.alt)   -- proportional contribution
    TA.ki_a = KI     * d.integral              -- integral contribution
    TA.kd_a = -d.velDamp                       -- vel-damp contribution

    if gainsBP then gainsBP:cycle() end

    -- Title and colour legend drawn after cycle() so they overlay the chart
    local graphW = mW - 1 - pw
    mon.setBackgroundColor(colors.black)
    local t1 = "PID Gains"
    mon.setTextColor(colors.white)
    mon.setCursorPos(graphW - #t1 + 1, 1)
    mon.write(t1)
    if mH >= 2 then
        local lx = graphW - 8
        mon.setCursorPos(lx, 2)
        mon.setTextColor(colors.lime);  mon.write("kP ")
        mon.setTextColor(colors.red);   mon.write("kI ")
        mon.setTextColor(colors.blue);  mon.write("kD")
    end
end

-- ---- Master draw -------------------------------------------

local function drawAll(mon, mW, mH, d)
    local pw    = math.min(14, math.floor(mW * 0.27))
    local tapeW = mW - 1 - pw
    local tapeH = mH

    if UI_MODE == "gains" then
        drawGainsGraph(mon, mW, mH, d, pw)
    elseif UI_MODE == "graph" then
        drawGraph(mon, mW, mH, d, pw)
    else
        local buf = newBuf(tapeW, tapeH)
        drawTape(buf, tapeW, tapeH, d.alt, d.targetAlt, d.velY)
        flushBuf(buf, mon, 1, 1)
    end

    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lime)
    for y = 1, tapeH do
        mon.setCursorPos(tapeW + 1, y)
        mon.write("|")
    end

    drawDataPanel(mon, tapeW + 2, 1, pw, tapeH, d)
end


-- ================================================================
--  §5  PHYSICS HELPERS
-- ================================================================

local k = nil

local function getFeedforward(pressure, mass, gravity)
    if not pressure or pressure == 0 then return 0 end
    if k then return (mass * gravity) / (k * pressure)
    else      return FALLBACK_C / pressure
    end
end

local function updateK(mass, gravity, vertAccel, avgRPM, pressure)
    if avgRPM < K_MIN_RPM              then return end
    if not pressure or pressure == 0   then return end
    local lift = mass * (gravity + vertAccel)
    if lift <= 0                        then return end
    local kNew = lift / (avgRPM * pressure)
    k = k and (k*(1-K_ALPHA) + kNew*K_ALPHA) or kNew
end

local function clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end


-- ================================================================
--  §6  MOTORS
-- ================================================================

local M = {}

local function wrapMotors(cfg)
    local function w(name, lbl)
        local p = peripheral.wrap(name)
        if not p then error(lbl .. " not found: " .. name) end
        return p
    end
    M.FL = w(cfg.FL,"FL"); M.FR = w(cfg.FR,"FR")
    M.BL = w(cfg.BL,"BL"); M.BR = w(cfg.BR,"BR")
end

local function setMotors(rpm)
    local r = clamp(rpm, MOTOR_MIN, MOTOR_MAX)
    M.FL.setTargetSpeed(r); M.FR.setTargetSpeed(r)
    M.BL.setTargetSpeed(r); M.BR.setTargetSpeed(r)
end

local function stopMotors()
    for _, m in pairs(M) do pcall(function() m.setTargetSpeed(0) end) end
end


-- ================================================================
--  §7  CONTROL LOOP
-- ================================================================

local altPID

local function makeControlStep(mon, mW, mH)
    local lastTime = os.clock()
    local prevVelY = 0
    local lastRPM  = 0

    return function()
        local now = os.clock()
        local dt  = math.max(now - lastTime, 0.001)
        lastTime  = now

        local pose    = sublevel.getLogicalPose()
        local pos     = pose.position
        local linVel  = sublevel.getLinearVelocity()
        local mass    = sublevel.getMass()

        local pressure = aero.getAirPressure(pos)
        local gravVec  = aero.getGravity()
        local gravity  = math.abs(gravVec.y)

        local velY      = linVel.y
        local vertAccel = (velY - prevVelY) / dt
        prevVelY        = velY

        updateK(mass, gravity, vertAccel, lastRPM, pressure)

        local ff      = getFeedforward(pressure, mass, gravity)
        local pidCorr = altPID:step(pos.y, dt)
        local velDamp = KD_VEL * velY
        local rpm     = clamp(ff + pidCorr - velDamp, MOTOR_MIN, MOTOR_MAX)
        lastRPM       = rpm
        setMotors(rpm)

        drawAll(mon, mW, mH, {
            alt=pos.y, targetAlt=TARGET_ALT,
            velY=velY, ff=ff, pidCorr=pidCorr, velDamp=velDamp,
            rpm=rpm, integral=altPID.integral,
            k=k, mass=mass, gravity=gravity, pressure=pressure,
        })
    end
end


-- ================================================================
--  §8  INPUT LOOP
-- ================================================================

-- ================================================================
--  REDSTONE ALTITUDE CONTROL
--
--  RIGHT side of the computer  →  target altitude + ALT_STEP
--  LEFT  side of the computer  →  target altitude - ALT_STEP
--
--  The signal must be held HIGH for at least RS_HOLD_TIME seconds
--  before the change fires.  This prevents brief noise or glitches
--  from accidentally moving the target.
--
--  The craft does not need to reach the new altitude before
--  another pulse is accepted — each falling edge is evaluated
--  independently, so you can stack several pulses quickly.
-- ================================================================

local function redstoneLoop()
    -- Track the time each side went HIGH (nil = currently LOW)
    local riseTime = { right = nil, left = nil }

    while true do
        os.pullEvent("redstone")   -- blocks until any redstone changes

        local now = os.clock()

        -- Check RIGHT side (altitude up)
        local rRight = redstone.getInput("right")
        if rRight and not riseTime.right then
            -- Rising edge on right
            riseTime.right = now
        elseif not rRight and riseTime.right then
            -- Falling edge on right — was it held long enough?
            if (now - riseTime.right) >= RS_HOLD_TIME then
                TARGET_ALT = TARGET_ALT + ALT_STEP
                altPID:setSP(TARGET_ALT)
                altPID:reset()
                term.setCursorPos(1, 16); term.clearLine()
                print("RS: alt + " .. ALT_STEP .. " -> " .. TARGET_ALT .. " m")
            end
            riseTime.right = nil
        end

        -- Check LEFT side (altitude down)
        local rLeft = redstone.getInput("left")
        if rLeft and not riseTime.left then
            -- Rising edge on left
            riseTime.left = now
        elseif not rLeft and riseTime.left then
            -- Falling edge on left — was it held long enough?
            if (now - riseTime.left) >= RS_HOLD_TIME then
                TARGET_ALT = TARGET_ALT - ALT_STEP
                altPID:setSP(TARGET_ALT)
                altPID:reset()
                term.setCursorPos(1, 16); term.clearLine()
                print("RS: alt - " .. ALT_STEP .. " -> " .. TARGET_ALT .. " m")
            end
            riseTime.left = nil
        end
    end
end

local function printHelp()
    print("  alt <n>  : set target altitude")
    print("  kp/ki/kd/ff <n>: tune gains")
    print("  save / reset")
    print("  indicator: altimeter tape view")
    print("  graph    : RPM flux + altitude tracking (telem)")
    print("  gains    : kP/kI/kD contribution graph (telem)")
    print("  gr <n>   : set gains Y-axis half-range RPM (now: " .. GAINS_RANGE .. ")")
    print("  help     : show this list")
    print("  [Redstone] RIGHT side held " .. RS_HOLD_TIME .. "s -> alt +" .. ALT_STEP)
    print("  [Redstone] LEFT  side held " .. RS_HOLD_TIME .. "s -> alt -" .. ALT_STEP)
end

local function inputLoop()
    while true do
        io.write("> ")
        local line = read()
        if line then
            local cmd, val = line:match("^(%a+)%s*(%-?%d*%.?%d*)")
            cmd = cmd and cmd:lower() or ""
            local n = tonumber(val)

            if cmd == "alt" and n then
                TARGET_ALT = n; altPID:setSP(n); altPID:reset()
                print("Target altitude = " .. string.format("%.1f", n) .. " m")
            elseif cmd == "kp" and n then
                KP = n; altPID:setGains(KP, KI)
                print("kP = " .. string.format("%.3f", KP))
            elseif cmd == "ki" and n then
                KI = n; altPID:setGains(KP, KI)
                print("kI = " .. string.format("%.3f", KI))
            elseif cmd == "kd" and n then
                KD_VEL = n
                print("kD (velocity damp) = " .. string.format("%.3f", KD_VEL))
            elseif cmd == "ff" and n then
                FALLBACK_C = n
                print("FALLBACK_C = " .. string.format("%.2f", FALLBACK_C))
            elseif cmd == "save" then
                currentCfg.KP         = KP
                currentCfg.KI         = KI
                currentCfg.KD_VEL     = KD_VEL
                currentCfg.FALLBACK_C = FALLBACK_C
                saveConfig(currentCfg)
                print("Gains saved to " .. CFG_FILE)
            elseif cmd == "reset" then
                altPID:reset(); print("Integral reset to 0.")
            elseif cmd == "indicator" then
                UI_MODE = "indicator"
                mon.clear()
                print("View: altimeter tape")
            elseif cmd == "graph" then
                UI_MODE = "graph"
                mon.clear()
                print("View: telem graph")
            elseif cmd == "gains" then
                UI_MODE = "gains"
                mon.clear()
                print("View: gains (+-" .. GAINS_RANGE .. " RPM)")
            elseif cmd == "gr" and n then
                GAINS_RANGE = math.max(1, math.floor(n))
                setupGainsBackplane()   -- rebuild with new scale immediately
                print("Gains range: +-" .. GAINS_RANGE .. " RPM")
            elseif cmd == "help" or cmd == "h" then
                printHelp()
            else
                print("Unknown command. Type help.")
            end
        end
    end
end


-- ================================================================
--  §9  ENTRY POINT
-- ================================================================

local cfg = wizard()
currentCfg = cfg
print("")
print("Wrapping motors...")
wrapMotors(cfg)
stopMotors()

mon = peripheral.wrap(cfg.monitor)
if not mon           then error("Monitor not found: " .. cfg.monitor) end
if not mon.isColor() then error("Advanced Monitor (colour) required.") end
mon.setTextScale(0.5)

local mW, mH = mon.getSize()
print(string.format("Monitor: %d x %d chars", mW, mH))
if mW < 20 or mH < 10 then
    error("Monitor too small -- need 20 wide x 10 tall at scale 0.5.")
end

-- ---- Telem graph setup ----------------------------------------
do
    local ok, telem = pcall(require, 'telem')
    if ok and telem then
        telem_lib = telem

        local pw      = math.min(14, math.floor(mW * 0.27))
        local graphW  = mW - 1 - pw
        local g1H     = math.floor((mH - 1) / 2)
        local g2top   = g1H + 2
        local g2H     = mH - g1H - 1

        -- win1: top half — collective motor RPM
        local win1 = window.create(mon, 1, 1, graphW, g1H)
        -- win2: bottom half — altitude vs target (reference line)
        local win2 = window.create(mon, 1, g2top, graphW, g2H)

        graphBP1 = telem.backplane()
            :addInput('motors', telem.input.custom(function()
                return { rpm = TS.rpm }
            end))
            :addOutput('plot1', telem.output.plotter.multiLine(win1, {
                { name = 'rpm', color = colors.lime },
            }, colors.black, colors.white, graphW))

        graphBP2 = telem.backplane()
            :addInput('altitude', telem.input.custom(function()
                return {
                    altitude  = TS.alt,
                    target    = TS.targetAlt,
                    anchor_hi = TS.targetAlt + 30,
                    anchor_lo = TS.targetAlt - 30,
                }
            end))
            :addOutput('plot2', telem.output.plotter.multiLine(win2, {
                { name = 'altitude',  color = colors.lime  },
                { name = 'target',    color = colors.white },
                { name = 'anchor_hi', color = colors.black },
                { name = 'anchor_lo', color = colors.black },
            }, colors.black, colors.white, graphW))

        print("Graph engine ready.")

        -- Gains mode: full-height single window
        gains_gW = graphW
        gainsWin = window.create(mon, 1, 1, gains_gW, mH)
        setupGainsBackplane()
        print("Gains engine ready (telem, +-" .. GAINS_RANGE .. " RPM).")
    else
        print("Telem not found -- graph/gains modes unavailable.")
        print("Install: wget run https://pinestore.cc/d/14")
    end
end

-- Seed target to current altitude so craft holds on startup
print("Reading initial altitude...")
sleep(0.3)
local initPose = sublevel.getLogicalPose()
TARGET_ALT     = math.floor(initPose.position.y)
print(string.format("Initial target altitude: %d m", TARGET_ALT))

altPID = PID.new(KP, KI)
altPID:setSP(TARGET_ALT)

print("Type 'help' for commands. 'save' to persist gains.")
print("Starting in 2s... Ctrl+T to stop.")
sleep(2)

local controlStep = makeControlStep(mon, mW, mH)

term.clear(); term.setCursorPos(1, 1)
print("ALTSTAB running. Ctrl+T to stop.")
printHelp()
print("")

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
        inputLoop,
        redstoneLoop
    )
end)

stopMotors()
mon.clear()
term.clear(); term.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then
    printError("Crashed: " .. tostring(err))
else
    print("Stopped. Motors zeroed.")
end
