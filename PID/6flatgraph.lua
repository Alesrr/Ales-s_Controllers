-- ================================================================
--  6flatgraph.lua  --  Flat Stabilization Controller
--  Keeps the craft level at 0 pitch and 0 roll.
--
--  USAGE:
--    1. Copy to computer root as 6flatgraph.lua  ->  run: 6flatgraph
--    2. Setup wizard lists peripherals and saves config
--    3. While running:
--         kp/ki/kd/base <n>  tune gains
--         save / reset
--         indicator          attitude indicator view
--         graph              RPM flux + pitch/roll error (telem)
--         gains              kP/kI/kD contribution plot (telem)
--         gr <n>             set gains Y-axis half-range RPM (now 15)
--    4. Ctrl+T to stop
--
--  QUICK TUNING
--  ---------------------------------------------------------------
--  Barely reacts to tilt        -> raise kP
--  Oscillates side to side      -> lower kP  OR  raise kD
--  Overshoots and bounces       -> raise kD
--  High-frequency jitter        -> lower kD
--  Settles slightly off-level   -> raise kI  (add slowly)
--  Slow growing oscillation     -> lower kI
-- ================================================================


-- ================================================================
--  §1  DEFAULTS  (overwritten by saved config if present)
-- ================================================================

local KP       = 0.8
local KI       = 0.15
local KD       = 2.5
local BASE_RPM = 60

local MOTOR_MIN    =   0
local MOTOR_MAX    = 256
local I_MIN, I_MAX = -40,  40
local O_MIN, O_MAX = -80,  80

local DISTURBANCE_DEG = 5.0
local INTEGRAL_BLEED  = 0.3
local LOOP_RATE       = 0.05

local CFG_FILE = "/6flatgraph_cfg.lua"

-- ================================================================
--  GAINS GRAPH  (telem multiLine — https://telem.cyberbit.dev/)
--
--  One telem backplane per axis (pitch top, roll bottom).
--  Each backplane emits 6 metrics per cycle:
--    kP  = KP  * error       -> lime   (proportional contribution)
--    kI  = KI  * integral    -> red    (integral contribution)
--    kD  = -(KD * angVel)    -> blue   (rate-damping contribution)
--    ref = 0                 -> white  (reference: zero correction)
--    scale_hi = +GAINS_RANGE -> black  (invisible Y-axis upper bound)
--    scale_lo = -GAINS_RANGE -> black  (invisible Y-axis lower bound)
--
--  Because the Y-axis auto-scales to min/max of the buffer, the
--  black anchors pin the range symmetrically around zero, so the
--  white ref=0 line always sits exactly in the middle.
--  When all three coloured lines converge on the white line,
--  the system is stable.
--
--  GAINS_RANGE: increase with "gr <n>" if lines clip at edges.
--  Rebuilds the backplanes immediately so scale resets at once.
-- ================================================================

local UI_MODE    = "indicator"   -- "indicator" | "graph" | "gains"
local GAINS_RANGE = 15           -- RPM: Y-axis = -GAINS_RANGE to +GAINS_RANGE

-- Live gain-term values written each control tick, read by telem inputs
local TG = { kp_p=0, ki_p=0, kd_p=0, kp_r=0, ki_r=0, kd_r=0 }

-- Telem handles for gains mode (populated in entry point if telem loads)
local telem_lib      = nil
local gainsBP_pitch  = nil
local gainsBP_roll   = nil
local gainsWin_pitch = nil
local gainsWin_roll  = nil

-- Layout values shared between setupGainsBackplanes and drawGainsGraph.
-- Computed once from mW/mH so both functions use identical geometry.
local G = { graphW=0, g1H=0, sepRow=0, g2top=0 }

-- Telem live-feed state for graph mode (RPM + attitude)
local TS = { fl=0, fr=0, bl=0, br=0, pitch=0, roll=0 }

-- Telem backplanes for graph mode (RPM Flux + Pitch/Roll error graphs)
local graphBP1, graphBP2, graphBP3

-- Distinct motor colours used in graph mode and data panel bars.
local COL_FL = colors.lime    -- green
local COL_FR = colors.yellow  -- yellow
local COL_BL = colors.cyan    -- cyan
local COL_BR = colors.orange  -- orange

-- Module-level monitor handle (assigned in entry point)
local mon = nil


-- ================================================================
--  §2  EMBEDDED PID
-- ================================================================

local PID = {}
PID.__index = PID

function PID.new(kp, ki, kd)
    return setmetatable({
        sp=0, kp=kp, ki=ki, kd=kd,
        integral=0, prevErr=0,
    }, PID)
end

function PID:step(measured, dt)
    if dt <= 0 then return 0 end
    local err     = self.sp - measured
    self.integral = math.max(I_MIN, math.min(I_MAX, self.integral + err * dt))
    local deriv   = (err - self.prevErr) / dt
    self.prevErr  = err
    return math.max(O_MIN, math.min(O_MAX,
           self.kp * err + self.ki * self.integral + self.kd * deriv))
end

function PID:reset()             self.integral = 0; self.prevErr = 0        end
function PID:setGains(kp,ki,kd)  self.kp=kp; self.ki=ki; self.kd=kd        end


-- ================================================================
--  §3  CONFIG / WIZARD
--  The config file stores BOTH peripheral names AND gain values.
--  Use the  save  terminal command to persist gains mid-flight.
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

-- Build the current config table (peripherals + live gains)
local currentCfg   -- set after wizard, used by save command

local function wizard()
    term.clear(); term.setCursorPos(1, 1)

    local saved = loadConfig()
    if saved then
        print("-- Saved config --")
        print("  BR: " .. saved.FL)
        print("  BL: " .. saved.FR)
        print("  FR: " .. saved.BL)
        print("  FL: " .. saved.BR)
        print("  Monitor: " .. saved.monitor)
        print(string.format("  Gains: kP=%.3f  kI=%.3f  kD=%.3f  base=%d",
            saved.KP or KP, saved.KI or KI, saved.KD or KD, saved.BASE_RPM or BASE_RPM))
        io.write("Use this? [y/n]: ")
        local a = read()
        if a == "" or a:lower() == "y" then
            -- Apply saved gains
            if saved.KP       then KP       = saved.KP       end
            if saved.KI       then KI       = saved.KI       end
            if saved.KD       then KD       = saved.KD       end
            if saved.BASE_RPM then BASE_RPM = saved.BASE_RPM end
            return saved
        end
    end

    term.clear(); term.setCursorPos(1, 1)
    print("-- ALES'S FLATSTAB SETUP --")
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

    local fl  = ask("Motor BL (front-left)",  "RSC 1")
    local fr  = ask("Motor BR (front-right)", "RSC 2")
    local bl  = ask("Motor FL (back-left)",   "RSC 3")
    local br  = ask("Motor FR (back-right)",  "RSC 4")
    local mon = ask("Monitor side/name",      "Rectangular display")
    print("")

    print("Checking peripherals...")
    local ok = true
    for lbl, name in pairs({FL=fl, FR=fr, BL=bl, BR=br}) do
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
        KP=KP, KI=KI, KD=KD, BASE_RPM=BASE_RPM,
    }
    if sv=="" or sv:lower()=="y" then
        saveConfig(cfg); print("Saved to " .. CFG_FILE)
    end
    return cfg
end


-- ================================================================
--  §4  ATTITUDE INDICATOR  (black & white + green horizon)
--
--  Colour palette (blit hex codes, all single-byte ASCII):
--    "0" = white    "5" = lime (green)    "f" = black
--    "7" = gray
--
--  Sky  = white ("0")
--  Ground = black ("f")
--  Horizon = lime ("5")   <-- only coloured element
--  Bank strip = black bg, white ticks, lime pointer
--  Aircraft symbol = lime ("5")
--  Pitch ladder = black text on white sky / white text on black ground
-- ================================================================

local C_SKY  = "0"   -- white  (sky fill)
local C_GND  = "f"   -- black  (ground fill)
local C_HOR  = "5"   -- lime   (horizon line -- the green line)
local C_REF  = "5"   -- lime   (aircraft symbol)
local C_BANK = "f"   -- black  (bank arc strip background)

-- ---- Buffer --------------------------------------------------

local function newBuf(w, h)
    local b = {}
    for y = 1, h do
        b[y] = {}
        for x = 1, w do b[y][x] = {" ", "f", C_SKY} end
    end
    return b
end

local function bset(b, x, y, ch, fg, bg)
    if b[y] and b[y][x] and #ch == 1 then
        b[y][x] = {ch, fg, bg}
    end
end

local function bget(b, x, y)
    if b[y] and b[y][x] then return b[y][x] end
    return {" ", "f", C_SKY}
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

-- ---- Sky / ground fill (solid B&W, no gradient) --------------

local function fillSkyGround(b, w, h, pitch, roll)
    local cx      = (w + 1) * 0.5
    local cy      = (h + 1) * 0.5
    local ppd     = h / 60.0
    local pitchPx = pitch * ppd
    local tanR    = math.tan(math.rad(roll))
    for y = 1, h do
        local row = b[y]
        for x = 1, w do
            local horizY = cy - pitchPx + (x - cx) * tanR
            if y < horizY then
                -- Sky: white bg, black text for pitch marks
                row[x] = {" ", "f", C_SKY}
            else
                -- Ground: black bg, white text
                row[x] = {" ", "0", C_GND}
            end
        end
    end
end

-- ---- Horizon line (lime, 2 chars thick) ----------------------

local function drawHorizon(b, w, h, pitch, roll)
    local cx      = (w + 1) * 0.5
    local cy      = (h + 1) * 0.5
    local ppd     = h / 60.0
    local pitchPx = pitch * ppd
    local tanR    = math.tan(math.rad(roll))
    local prevIY  = nil

    for x = 1, w do
        local horizY = cy - pitchPx + (x - cx) * tanR
        local iy     = math.floor(horizY + 0.5)

        if prevIY and math.abs(iy - prevIY) > 1 then
            local step = iy > prevIY and 1 or -1
            for py = prevIY + step, iy - step, step do
                bset(b, x-1, py,   " ", "0", C_HOR)
                bset(b, x-1, py+1, " ", "0", C_HOR)
            end
        end

        bset(b, x, iy,   " ", "0", C_HOR)
        bset(b, x, iy+1, " ", "0", C_HOR)
        prevIY = iy
    end
end

-- ---- Pitch ladder --------------------------------------------

local LADDER = {-30, -20, -10, 10, 20, 30}
local MKLEN  = 4

local function drawLadder(b, w, h, pitch, roll)
    local cx   = (w + 1) * 0.5
    local cy   = (h + 1) * 0.5
    local ppd  = h / 60.0
    local tanR = math.tan(math.rad(roll))

    for _, deg in ipairs(LADDER) do
        local markCY = cy - (deg - pitch) * ppd
        if markCY >= 2 and markCY <= h - 1 then
            local inSky = (deg > 0)
            -- Black marks on white sky, white marks on black ground
            local mfg   = inSky and "f" or "0"
            local cyi   = math.floor(markCY + 0.5)

            for xi = math.floor(cx - MKLEN), math.floor(cx + MKLEN) do
                local iy = math.floor(markCY + (xi - cx) * tanR + 0.5)
                if xi >= 1 and xi <= w and iy >= 1 and iy <= h then
                    local c  = bget(b, xi, iy)
                    local ch = (math.abs(xi - cx) < 1) and "." or "-"
                    bset(b, xi, iy, ch, mfg, c[3])
                end
            end

            -- Degree label right of mark
            local lbl = " " .. tostring(math.abs(deg))
            local rx  = math.floor(cx + MKLEN + 2)
            for i = 1, #lbl do
                local xi = rx + i - 1
                if xi >= 1 and xi <= w and cyi >= 1 and cyi <= h then
                    local c = bget(b, xi, cyi)
                    bset(b, xi, cyi, lbl:sub(i,i), mfg, c[3])
                end
            end
        end
    end
end

-- ---- Bank arc indicator (top 3 rows) -------------------------
--  Black strip. White tick marks. Lime pointer and centre mark.
--  Labels at -60, -30, 0, +30, +60.

local BANK_MAJOR = {-60, -30, 0, 30, 60}
local BANK_MINOR = {-50, -40, -20, -10, 10, 20, 40, 50}

local function drawBankArc(b, w, roll)
    local cx    = (w + 1) * 0.5
    local scale = w / 180.0

    -- Fill rows 1-3 with black
    for y = 1, 3 do
        for x = 1, w do bset(b, x, y, " ", "0", C_BANK) end
    end

    -- Row 1: degree labels (white text on black)
    for _, deg in ipairs(BANK_MAJOR) do
        local x   = math.floor(cx + deg * scale + 0.5)
        local lbl = (deg == 0) and "0" or tostring(math.abs(deg))
        local lx  = x - math.floor(#lbl * 0.5)
        for i = 1, #lbl do
            local xi = lx + i - 1
            if xi >= 1 and xi <= w then
                bset(b, xi, 1, lbl:sub(i,i), "0", C_BANK)
            end
        end
    end

    -- Row 2: ticks (| major, ' minor, all white)
    for _, deg in ipairs(BANK_MAJOR) do
        local x = math.floor(cx + deg * scale + 0.5)
        if x >= 1 and x <= w then bset(b, x, 2, "|", "0", C_BANK) end
    end
    for _, deg in ipairs(BANK_MINOR) do
        local x = math.floor(cx + deg * scale + 0.5)
        if x >= 1 and x <= w then bset(b, x, 2, "'", "7", C_BANK) end
    end

    -- Row 3: lime pointer (v) and white centre mark (^)
    local px = math.max(1, math.min(w, math.floor(cx + roll * scale + 0.5)))
    bset(b, px, 3, "v", "5", C_BANK)
    bset(b, math.floor(cx + 0.5), 3, "^", "0", C_BANK)
end

-- ---- Aircraft reference symbol (lime, centre of AI) ----------

local function drawRef(b, w, h)
    local cx = math.floor((w + 1) * 0.5)
    local cy = math.floor((h + 1) * 0.5)

    local function over(x, y, ch)
        local c = bget(b, x, y)
        bset(b, x, y, ch, C_REF, c[3])
    end

    over(cx-4, cy, "-"); over(cx-3, cy, "-"); over(cx-2, cy, "-")
    over(cx-1, cy, "<")
    over(cx,   cy, "+")
    over(cx+1, cy, ">")
    over(cx+2, cy, "-"); over(cx+3, cy, "-"); over(cx+4, cy, "-")
    over(cx,   cy-1, "|")
end

-- ---- Data panel (right of separator) ------------------------

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
        -- Lime dividers -- the "middle lines" in green
        ln(string.rep("-", pw), colors.lime)
    end

    ln(" FLATSTAB",  colors.lime)
    div()

    -- Attitude (lime when level, white when correcting)
    local pLvl = math.abs(d.pitch) < 1.0
    local rLvl = math.abs(d.roll)  < 1.0
    ln(string.format(" P %+6.1f deg", d.pitch), pLvl and colors.lime or colors.white)
    ln(string.format(" R %+6.1f deg", d.roll),  rLvl and colors.lime or colors.white)
    div()

    -- Angular rates
    ln(string.format(" wP %+5.3f r/s", d.angX))
    ln(string.format(" wR %+5.3f r/s", d.angZ))
    div()

    -- Gain labels: coloured in gains mode (lime/red/blue = kP/kI/kD).
    -- White in all other modes so the panel stays neutral.
    if UI_MODE == "gains" then
        ln(string.format(" kP  %6.3f", KP),       colors.lime)
        ln(string.format(" kI  %6.3f", KI),       colors.red)
        ln(string.format(" kD  %6.3f", KD),       colors.blue)
    else
        ln(string.format(" kP  %6.3f", KP))
        ln(string.format(" kI  %6.3f", KI))
        ln(string.format(" kD  %6.3f", KD))
    end
    ln(string.format(" RPM %6d",   BASE_RPM))
    div()

    -- Motor bars: coloured only in graph mode.
    -- In indicator and gains modes the bars are plain white so they
    -- do not distract from the attitude indicator or gains graph.
    local barW = math.max(1, pw - 4)
    local function motorBar(lbl, rpm, col)
        local pct    = (rpm - MOTOR_MIN) / (MOTOR_MAX - MOTOR_MIN)
        local bars   = math.max(0, math.min(barW, math.floor(pct * barW + 0.5)))
        local useCol = (UI_MODE == "graph") and col or colors.white
        ln(lbl .. string.rep("|", bars) .. string.rep(".", barW - bars), useCol)
    end
    motorBar("FL ", d.fl, COL_FL)
    motorBar("FR ", d.fr, COL_FR)
    motorBar("BL ", d.bl, COL_BL)
    motorBar("BR ", d.br, COL_BR)
    div()

    -- Integral accumulation
    ln(string.format(" iP %+5.2f", d.iP))
    ln(string.format(" iR %+5.2f", d.iR))
    div()

    -- Status
    if pLvl and rLvl then
        ln(" LEVEL",      colors.lime)
    else
        ln(" CORRECTING", colors.white)
    end
end

-- ---- Graph draw (telem) -------------------------------------
-- ATTITUDE_RANGE: half-span of Y-axis for pitch and roll graphs.
-- Invisible black anchors at +/- this value keep 0 deg always centred.
local ATTITUDE_RANGE = 30   -- degrees shown above and below zero

local function drawGraph(mon, mW, mH, d, pw)
    TS.fl    = d.fl;   TS.fr    = d.fr
    TS.bl    = d.bl;   TS.br    = d.br
    TS.pitch = d.pitch; TS.roll = d.roll

    if graphBP1 then graphBP1:cycle() end
    if graphBP2 then graphBP2:cycle() end
    if graphBP3 then graphBP3:cycle() end

    -- Layout: 3 equal graph bands with 2 separator rows
    local graphW    = mW - 1 - pw
    local totalH    = mH - 2   -- 2 rows reserved for separators
    local g1H       = math.floor(totalH / 3)
    local g2H       = math.floor(totalH / 3)
    local sep1Row   = g1H + 1
    local sep2Row   = g1H + 1 + g2H + 1

    -- Draw the two separator rows (lime dashes)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lime)
    mon.setCursorPos(1, sep1Row); mon.write(string.rep("-", graphW))
    mon.setCursorPos(1, sep2Row); mon.write(string.rep("-", graphW))

    -- Graph labels: top-right of each sub-window, white on black
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    local lbl1 = "RPM Flux"
    local lbl2 = "Pitch Err."
    local lbl3 = "Roll Err."
    mon.setCursorPos(graphW - #lbl1 + 1, 1);          mon.write(lbl1)
    mon.setCursorPos(graphW - #lbl2 + 1, sep1Row + 1); mon.write(lbl2)
    mon.setCursorPos(graphW - #lbl3 + 1, sep2Row + 1); mon.write(lbl3)
end

-- ---- Gains backplane factory ---------------------------------
-- Creates/replaces the two gains backplanes using the cached layout G.
-- Called at startup and whenever GAINS_RANGE is changed with "gr <n>".

local function setupGainsBackplanes()
    if not telem_lib or G.graphW == 0 then return end
    local t = telem_lib

    gainsBP_pitch = t.backplane()
        :addInput('pitch', t.input.custom(function()
            return {
                kP       = TG.kp_p,
                kI       = TG.ki_p,
                kD       = TG.kd_p,
                ref      = 0,              -- white reference: zero correction
                scale_hi =  GAINS_RANGE,   -- black anchor: sets Y-axis upper bound
                scale_lo = -GAINS_RANGE,   -- black anchor: sets Y-axis lower bound
            }
        end))
        :addOutput('pplot', t.output.plotter.multiLine(gainsWin_pitch, {
            { name = 'kP',       color = colors.lime  },
            { name = 'kI',       color = colors.red   },
            { name = 'kD',       color = colors.blue  },
            { name = 'ref',      color = colors.white },
            { name = 'scale_hi', color = colors.black },
            { name = 'scale_lo', color = colors.black },
        }, colors.black, colors.white, G.graphW))

    gainsBP_roll = t.backplane()
        :addInput('roll', t.input.custom(function()
            return {
                kP       = TG.kp_r,
                kI       = TG.ki_r,
                kD       = TG.kd_r,
                ref      = 0,
                scale_hi =  GAINS_RANGE,
                scale_lo = -GAINS_RANGE,
            }
        end))
        :addOutput('rplot', t.output.plotter.multiLine(gainsWin_roll, {
            { name = 'kP',       color = colors.lime  },
            { name = 'kI',       color = colors.red   },
            { name = 'kD',       color = colors.blue  },
            { name = 'ref',      color = colors.white },
            { name = 'scale_hi', color = colors.black },
            { name = 'scale_lo', color = colors.black },
        }, colors.black, colors.white, G.graphW))
end

-- ---- Gains graph draw (telem) --------------------------------
-- Cycles both gains backplanes (which repaint their sub-windows),
-- then draws the lime separator and per-graph labels/legends.

local function drawGainsGraph(d)
    -- Compute and store the per-term contributions
    TG.kp_p = KP * (-d.pitch)       -- proportional: KP * error
    TG.ki_p = KI * d.iP             -- integral:     KI * integral
    TG.kd_p = -(KD * d.angX)        -- rate-damp:    -(KD * angVel)
    TG.kp_r = KP * (-d.roll)
    TG.ki_r = KI * d.iR
    TG.kd_r = -(KD * d.angZ)

    if gainsBP_pitch then gainsBP_pitch:cycle() end
    if gainsBP_roll  then gainsBP_roll:cycle()  end

    -- Lime separator between the two sub-windows
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lime)
    mon.setCursorPos(1, G.sepRow)
    mon.write(string.rep("-", G.graphW))

    -- Pitch graph: title on row 1, colour legend on row 2
    mon.setBackgroundColor(colors.black)
    local t1 = "Pitch Gains"
    mon.setTextColor(colors.white)
    mon.setCursorPos(G.graphW - #t1 + 1, 1)
    mon.write(t1)
    if G.g1H >= 2 then
        local lx = G.graphW - 8
        mon.setCursorPos(lx, 2)
        mon.setTextColor(colors.lime);  mon.write("kP ")
        mon.setTextColor(colors.red);   mon.write("kI ")
        mon.setTextColor(colors.blue);  mon.write("kD")
    end

    -- Roll graph: title on first row of section, legend on second
    local t2 = "Roll Gains"
    mon.setTextColor(colors.white)
    mon.setCursorPos(G.graphW - #t2 + 1, G.g2top)
    mon.write(t2)
    if (G.sepRow + 2) <= G.sepRow + (G.sepRow - 1) then  -- at least 2 rows in bottom
        local lx = G.graphW - 8
        mon.setCursorPos(lx, G.g2top + 1)
        mon.setTextColor(colors.lime);  mon.write("kP ")
        mon.setTextColor(colors.red);   mon.write("kI ")
        mon.setTextColor(colors.blue);  mon.write("kD")
    end
end

-- ---- Master draw call ----------------------------------------

local function drawAll(mon, mW, mH, d)
    local pw  = math.min(14, math.floor(mW * 0.27))
    local aiW = mW - 1 - pw
    local aiH = mH

    if UI_MODE == "gains" then
        drawGainsGraph(d)
    elseif UI_MODE == "graph" then
        drawGraph(mon, mW, mH, d, pw)
    else
        local buf = newBuf(aiW, aiH)
        fillSkyGround(buf, aiW, aiH, d.pitch, d.roll)
        drawHorizon  (buf, aiW, aiH, d.pitch, d.roll)
        drawLadder   (buf, aiW, aiH, d.pitch, d.roll)
        drawBankArc  (buf, aiW,      d.roll)
        drawRef      (buf, aiW, aiH)
        flushBuf     (buf, mon, 1, 1)
    end

    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lime)
    for y = 1, aiH do
        mon.setCursorPos(aiW + 1, y)
        mon.write("|")
    end

    drawDataPanel(mon, aiW + 2, 1, pw, aiH, d)
end


-- ================================================================
--  §5  QUATERNION
-- ================================================================
--
--  q:toEuler() -> pitchRad, yawRad, rollRad  (Minecraft Y-up)
--  If the wrong axis tilts on screen: swap the return values below.

local function getPitchRoll(q)
    local pitchRad, _, rollRad = q:toEuler()
    return math.deg(pitchRad), math.deg(rollRad)
end


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

local function clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end

local function setMotors(fl, fr, bl, br)
    M.FL.setTargetSpeed(clamp(fl, MOTOR_MIN, MOTOR_MAX))
    M.FR.setTargetSpeed(clamp(fr, MOTOR_MIN, MOTOR_MAX))
    M.BL.setTargetSpeed(clamp(bl, MOTOR_MIN, MOTOR_MAX))
    M.BR.setTargetSpeed(clamp(br, MOTOR_MIN, MOTOR_MAX))
end

local function stopMotors()
    for _, m in pairs(M) do pcall(function() m.setTargetSpeed(0) end) end
end


-- ================================================================
--  §7  CONTROL LOOP
-- ================================================================

local pitchPID, rollPID

local function makeControlStep(mon, mW, mH)
    local lastTime = os.clock()

    return function()
        local now = os.clock()
        local dt  = math.max(now - lastTime, 0.001)
        lastTime  = now

        local pose   = sublevel.getLogicalPose()
        local angVel = sublevel.getAngularVelocity()
        local pitch, roll = getPitchRoll(pose.orientation)

        if math.abs(roll)  > DISTURBANCE_DEG then
            rollPID.integral  = rollPID.integral  * INTEGRAL_BLEED
        end
        if math.abs(pitch) > DISTURBANCE_DEG then
            pitchPID.integral = pitchPID.integral * INTEGRAL_BLEED
        end

        local pitchOut = pitchPID:step(pitch, dt) - KD * angVel.x
        local rollOut  = rollPID:step(roll,   dt) - KD * angVel.z

        pitchOut = clamp(pitchOut, O_MIN, O_MAX)
        rollOut  = clamp(rollOut,  O_MIN, O_MAX)

        local fl = BASE_RPM + pitchOut + rollOut
        local fr = BASE_RPM + pitchOut - rollOut
        local bl = BASE_RPM - pitchOut + rollOut
        local br = BASE_RPM - pitchOut - rollOut

        setMotors(fl, fr, bl, br)

        drawAll(mon, mW, mH, {
            pitch=pitch, roll=roll,
            angX=angVel.x, angZ=angVel.z,
            fl=fl, fr=fr, bl=bl, br=br,
            iP=pitchPID.integral, iR=rollPID.integral,
        })
    end
end


-- ================================================================
--  §8  INPUT LOOP  (live gain editing + save)
-- ================================================================

local function printHelp()
    print("  kp/ki/kd <n>: tune gains")
    print("  base <n>    : hover RPM")
    print("  save        : persist gains to disk")
    print("  reset       : clear integrals")
    print("  indicator   : attitude indicator view")
    print("  graph       : RPM flux + pitch/roll error (telem)")
    print("  gains       : kP/kI/kD contribution graph (telem)")
    print("  gr <n>      : set gains Y-axis half-range RPM (now: " .. GAINS_RANGE .. ")")
    print("  help        : show this list")
end

local function inputLoop()
    while true do
        io.write("> ")
        local line = read()
        if line then
            local cmd, val = line:match("^(%a+)%s*(%-?%d*%.?%d*)")
            cmd = cmd and cmd:lower() or ""
            local n = tonumber(val)

            if cmd == "kp" and n then
                KP = n
                pitchPID:setGains(KP, KI, KD)
                rollPID:setGains(KP, KI, KD)
                print("kP = " .. string.format("%.3f", KP))
            elseif cmd == "ki" and n then
                KI = n
                pitchPID:setGains(KP, KI, KD)
                rollPID:setGains(KP, KI, KD)
                print("kI = " .. string.format("%.3f", KI))
            elseif cmd == "kd" and n then
                KD = n
                pitchPID:setGains(KP, KI, KD)
                rollPID:setGains(KP, KI, KD)
                print("kD = " .. string.format("%.3f", KD))
            elseif cmd == "base" and n then
                BASE_RPM = math.floor(n)
                print("BASE_RPM = " .. BASE_RPM)
            elseif cmd == "save" then
                -- Merge current gains into the stored config
                currentCfg.KP       = KP
                currentCfg.KI       = KI
                currentCfg.KD       = KD
                currentCfg.BASE_RPM = BASE_RPM
                saveConfig(currentCfg)
                print("Gains saved to " .. CFG_FILE)
            elseif cmd == "reset" then
                pitchPID:reset(); rollPID:reset()
                print("Integrals reset to 0.")
            elseif cmd == "indicator" then
                UI_MODE = "indicator"
                mon.clear()
                print("View: attitude indicator")
            elseif cmd == "graph" then
                UI_MODE = "graph"
                mon.clear()
                print("View: telem graph")
            elseif cmd == "gains" then
                UI_MODE = "gains"
                mon.clear()
                print("View: gains (+-" .. GAINS_RANGE .. " RPM range)")
            elseif cmd == "gr" and n then
                GAINS_RANGE = math.max(1, math.floor(n))
                setupGainsBackplanes()   -- rebuild with new scale immediately
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
if mW < 22 or mH < 10 then
    error("Monitor too small -- need 22 wide x 10 tall at scale 0.5.")
end

-- ---- Telem graph setup ----------------------------------------
-- Three sub-windows stacked in the left (AI) region.
-- g1: Motor RPM (distinct colours per rotor)
-- g2: Pitch error (0 always centred)
-- g3: Roll error  (0 always centred)
-- Requires telem: wget run https://pinestore.cc/d/14
do
    local ok, telem = pcall(require, 'telem')
    if ok and telem then
        telem_lib = telem   -- save for setupGainsBackplanes

        local pw      = math.min(14, math.floor(mW * 0.27))
        local graphW  = mW - 1 - pw
        local totalH  = mH - 2        -- 2 separator rows
        local g1H     = math.floor(totalH / 3)
        local g2H     = math.floor(totalH / 3)
        local g3H     = totalH - g1H - g2H
        local g2top   = g1H + 2
        local g3top   = g1H + 1 + g2H + 2

        local win1 = window.create(mon, 1, 1,      graphW, g1H)
        local win2 = window.create(mon, 1, g2top,  graphW, g2H)
        local win3 = window.create(mon, 1, g3top,  graphW, g3H)

        graphBP1 = telem.backplane()
            :addInput('motors', telem.input.custom(function()
                return {
                    fl        = TS.fl,
                    fr        = TS.fr,
                    bl        = TS.bl,
                    br        = TS.br,
                    reference = BASE_RPM,
                }
            end))
            :addOutput('plot1', telem.output.plotter.multiLine(win1, {
                { name = 'fl',        color = COL_FL       },
                { name = 'fr',        color = COL_FR       },
                { name = 'bl',        color = COL_BL       },
                { name = 'br',        color = COL_BR       },
                { name = 'reference', color = colors.white },
            }, colors.black, colors.white, graphW))

        graphBP2 = telem.backplane()
            :addInput('pitch_err', telem.input.custom(function()
                return {
                    pitch      = TS.pitch,
                    anchor_hi  =  30,
                    anchor_lo  = -30,
                }
            end))
            :addOutput('plot2', telem.output.plotter.multiLine(win2, {
                { name = 'pitch',     color = colors.lime  },
                { name = 'anchor_hi', color = colors.black },
                { name = 'anchor_lo', color = colors.black },
            }, colors.black, colors.white, graphW))

        graphBP3 = telem.backplane()
            :addInput('roll_err', telem.input.custom(function()
                return {
                    roll       = TS.roll,
                    anchor_hi  =  30,
                    anchor_lo  = -30,
                }
            end))
            :addOutput('plot3', telem.output.plotter.multiLine(win3, {
                { name = 'roll',      color = colors.lime  },
                { name = 'anchor_hi', color = colors.black },
                { name = 'anchor_lo', color = colors.black },
            }, colors.black, colors.white, graphW))

        print("Graph engine ready (3 plots).")

        -- ---- Gains mode setup ----------------------------------
        -- Two windows equal-height, separated by one row.
        -- Layout stored in G so drawGainsGraph uses identical geometry.
        G.graphW = graphW
        G.g1H    = math.floor((mH - 1) / 2)
        G.sepRow = G.g1H + 1
        G.g2top  = G.g1H + 2

        local gH2 = mH - G.g1H - 1
        gainsWin_pitch = window.create(mon, 1, 1,      G.graphW, G.g1H)
        gainsWin_roll  = window.create(mon, 1, G.g2top, G.graphW, gH2)

        setupGainsBackplanes()
        print("Gains engine ready (telem, +-" .. GAINS_RANGE .. " RPM).")
    else
        print("Telem not found -- graph/gains modes unavailable.")
        print("Install: wget run https://pinestore.cc/d/14")
    end
end

pitchPID = PID.new(KP, KI, KD)
rollPID  = PID.new(KP, KI, KD)

print("Reading initial orientation...")
sleep(0.3)
local p0, r0 = getPitchRoll(sublevel.getLogicalPose().orientation)
print(string.format("  Pitch: %+.2f   Roll: %+.2f", p0, r0))
print("  Tilt nose down -- pitch value should change.")
print("  If axes are swapped: edit getPitchRoll() return order (section 5).")
print("")
print("Type 'help' for commands. 'save' to persist gains.")
print("Starting in 2s... Ctrl+T to stop.")
sleep(2)

local controlStep = makeControlStep(mon, mW, mH)

term.clear(); term.setCursorPos(1, 1)
print("FLATSTAB running. Ctrl+T to stop.")
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
        inputLoop
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
