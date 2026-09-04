local CFG_FILE = "/hud_cfg.lua"

local CFG = {

    X_OFF       = 0,
    Y_OFF       = 0,
    Z_OFF       = 0,

    BLOCK_W     = 6,
    BLOCK_H     = 3,
    FACING      = "south",

    YAW         = 0,
    PITCH       = 0,
    OPACITY     = 100,
    BG_OPACITY  = 0,

    RES_MULT    = 2,
    REFRESH_HZ  = 20,

    COL_FG      = { 235, 238, 240 },
    COL_ACCENT  = {  90, 220, 130 },
    COL_DIM     = { 120, 130, 140 },
    COL_WARN    = { 235,  70,  70 },

    RELAY_THR     = "",
    RELAY_HB      = "",
    RELAY_THR_FWD = "",
    RELAY_THR_REV = "",
    RELAY_GEAR    = "",

    TARGET_FUEL    = "",

    COLOR_MODE     = "WHITE",
    SIZE_MULT      = 1.15,

    VIEW           = "INDICATOR",
}

local function saveCfg()
    local f = fs.open(CFG_FILE, "w")
    if f then f.write(textutils.serialize(CFG)); f.close() end
end
local function loadCfg()
    if not fs.exists(CFG_FILE) then return end
    local f = fs.open(CFG_FILE, "r")
    if not f then return end
    local raw = f.readAll(); f.close()
    local ok, t = pcall(textutils.unserialize, raw)
    if not ok or type(t) ~= "table" then return end
    for k, v in pairs(t) do
        if CFG[k] ~= nil then CFG[k] = v end
    end
end
loadCfg()

local RELAY_KEYS = {"RELAY_THR", "RELAY_HB", "RELAY_THR_FWD",
                    "RELAY_THR_REV", "RELAY_GEAR"}

local function relaysConfigured()
    for _, k in ipairs(RELAY_KEYS) do
        if CFG[k] == nil or CFG[k] == "" then return false end
    end
    return true
end

local function relaysOK()
    for _, k in ipairs(RELAY_KEYS) do
        if CFG[k] == "" then return false end
        if not peripheral.wrap(CFG[k]) then return false end
    end
    return true
end

local function wizard()
    term.clear(); term.setCursorPos(1, 1)
    print("-- HUD REDSTONE WIZARD --")
    print("")
    print("Five redstone_relay peripherals, all on 'front' face:")
    print("  THR     -- 0..15 analog throttle level")
    print("  HB      -- on/off handbrake state")
    print("  THR_FWD -- on/off forward-thrust flag")
    print("  THR_REV -- on/off reverse-thrust flag")
    print("  GEAR    -- on/off landing gear deployed")
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

    local function ask(label, def)
        io.write(string.format("  %-22s [%s]: ", label, def))
        local inp = read(nil, nil, function(t)
            local r = {}
            for _, s in ipairs(sugg) do
                if s:sub(1,#t) == t then r[#r+1] = s:sub(#t+1) end
            end
            return r
        end)
        return (inp == nil or inp == "") and def or inp
    end

    local thrName    = ask("Relay THR     (0..15)", "redstone_relay_0")
    local hbName     = ask("Relay HB      (on/off)", "redstone_relay_1")
    local thrFwdName = ask("Relay THR_FWD (on/off)", "redstone_relay_2")
    local thrRevName = ask("Relay THR_REV (on/off)", "redstone_relay_3")
    local gearName   = ask("Relay GEAR    (on/off)", "redstone_relay_4")
    print("")
    print("Optional CC:C Bridge Target Block for fuel readings.")
    print("Multiple Display Links can write to it; the HUD averages")
    print("all numeric lines.  Leave blank to skip.")
    local fuelTarget = ask("Target FUEL   (avg of all tanks)", CFG.TARGET_FUEL or "")
    print("")

    print("Checking peripherals...")
    local ok = true
    local checks = {
        {"THR",     thrName},
        {"HB",      hbName},
        {"THR_FWD", thrFwdName},
        {"THR_REV", thrRevName},
        {"GEAR",    gearName},
    }
    for _, pair in ipairs(checks) do
        local lbl, name = pair[1], pair[2]
        local found = peripheral.wrap(name) ~= nil
        print(string.format("  %-8s (%s) %s", lbl, name,
              found and "OK" or "NOT FOUND"))
        if not found then ok = false end
    end
    if fuelTarget ~= "" then
        local found = peripheral.wrap(fuelTarget) ~= nil
        print(string.format("  %-8s (%s) %s", "FUEL", fuelTarget,
              found and "OK" or "NOT FOUND -- fuel column will be blank"))
    end
    if not ok then
        print("WARNING: some relays missing -- saving anyway.")
        print("         Affected readouts will show 0 / OFF / no arrow")
        print("         until the peripherals come back.")
    end

    CFG.RELAY_THR     = thrName
    CFG.RELAY_HB      = hbName
    CFG.RELAY_THR_FWD = thrFwdName
    CFG.RELAY_THR_REV = thrRevName
    CFG.RELAY_GEAR    = gearName
    CFG.TARGET_FUEL   = fuelTarget
    saveCfg()
    print("")
    print("Saved to " .. CFG_FILE .. ".  Booting HUD...")
    sleep(0.6)
end

if not relaysConfigured() then
    wizard()
elseif not relaysOK() then
    local missing = {}
    for _, k in ipairs(RELAY_KEYS) do
        if not peripheral.wrap(CFG[k]) then
            missing[#missing + 1] = CFG[k]
        end
    end
    print("HUD: loaded saved peripherals from " .. CFG_FILE)
    print("HUD: not responding right now: "
          .. table.concat(missing, ", "))
    print("HUD: those readouts show 0 / OFF until they return.")
    print("HUD: type 'wizard' to reconfigure.")
else
    print("HUD: loaded saved peripherals from " .. CFG_FILE)
end

local gpu = peripheral.find("directgpu")
if not gpu then
    error("HUD: no directgpu peripheral found on this computer.")
end
if not sublevel then
    error("HUD: sublevel API not present.\n"
       .. "       Place this computer ON the Sable contraption.")
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function rotateByConj(qx, qy, qz, qw, vx, vy, vz)
    local cx, cy, cz, cw = -qx, -qy, -qz, qw
    local tx =  cw*vx + cy*vz - cz*vy
    local ty =  cw*vy + cz*vx - cx*vz
    local tz =  cw*vz + cx*vy - cy*vx
    local tw = -cx*vx - cy*vy - cz*vz
    local rx = tw*qx + tx*qw + ty*qz - tz*qy
    local ry = tw*qy - tx*qz + ty*qw + tz*qx
    local rz = tw*qz + tx*qy - ty*qx + tz*qw
    return rx, ry, rz
end

local function quatComponents(q)
    if type(q) ~= "table" and type(q) ~= "userdata" then return nil end
    local ok, x, y, z, w = pcall(function()
        if type(q.v) == "table" and q.a then
            return q.v.x, q.v.y, q.v.z, q.a
        end
        return q.x, q.y, q.z, q.w
    end)
    if ok and type(x) == "number" and type(y) == "number"
         and type(z) == "number" and type(w) == "number" then
        return x, y, z, w
    end
    return nil
end

local function lerpC(a, b, t)
    t = math.max(0, math.min(1, t))
    return {
        math.floor(a[1] + (b[1] - a[1]) * t),
        math.floor(a[2] + (b[2] - a[2]) * t),
        math.floor(a[3] + (b[3] - a[3]) * t),
    }
end

local function quatToEuler(qx, qy, qz, qw)
    local sinr = 2*(qw*qx + qy*qz)
    local cosr = 1 - 2*(qx*qx + qy*qy)
    local roll = math.atan(sinr, cosr)
    local sinp = 2*(qw*qy - qz*qx)
    local pitch
    if math.abs(sinp) >= 1 then
        pitch = (sinp >= 0) and (math.pi/2) or -(math.pi/2)
    else
        pitch = math.asin(sinp)
    end
    local siny = 2*(qw*qz + qx*qy)
    local cosy = 1 - 2*(qy*qy + qz*qz)
    local yaw  = math.atan(siny, cosy)
    return roll, pitch, yaw
end

local function pollSable()
    local d = {}
    local ok, pose = pcall(sublevel.getLogicalPose)
    if not ok or type(pose) ~= "table" then return nil end
    local p = pose.position
    if not p then return nil end
    d.x, d.y, d.z = p.x or 0, p.y or 0, p.z or 0

    local q = pose.orientation
    d.pitch, d.roll, d.yaw = 0, 0, 0
    local qx, qy, qz, qw
    if q then
        local okE, pitchRad, yawRad, rollRad = pcall(function()
            return q:toEuler()
        end)
        if okE and type(pitchRad) == "number" then
            d.pitch = math.deg(pitchRad)
            d.yaw   = math.deg(yawRad or 0)
            d.roll  = math.deg(rollRad or 0)
        end
        qx, qy, qz, qw = quatComponents(q)
    end

    local okv, vel = pcall(sublevel.getLinearVelocity)
    if okv and vel then
        local wx, wy, wz = vel.x or 0, vel.y or 0, vel.z or 0
        d.vy    = wy
        d.speed = math.sqrt(wx * wx + wy * wy + wz * wz)
        if qx then
            local bx, by, bz = rotateByConj(qx, qy, qz, qw, wx, wy, wz)
            d.fwd, d.strafe, d.climb = bz, bx, by
        else
            local yawR = math.rad(d.yaw)
            local cyw, syw = math.cos(yawR), math.sin(yawR)
            d.fwd    = -syw * wx + cyw * wz
            d.strafe =  cyw * wx + syw * wz
            d.climb  =  wy
        end
    else
        d.fwd, d.strafe, d.vy, d.climb, d.speed = 0, 0, 0, 0, 0
    end
    return d
end

local HUD = {
    id      = nil,
    pixelW  = 0,
    pixelH  = 0,
    res     = 2,
}

local REF_RES = 2

local function dims()
    if not HUD.id then return 320, 240, (CFG.RES_MULT or REF_RES) end
    local ok, info = pcall(function() return gpu.getDisplayInfo(HUD.id) end)
    if not ok or type(info) ~= "table" then
        return 320, 240, (CFG.RES_MULT or REF_RES)
    end
    return (info.pixelWidth or 320), (info.pixelHeight or 240),
           (info.resolutionMultiplier or CFG.RES_MULT or REF_RES)
end

local function resComp()
    return math.max(1, (HUD.res or CFG.RES_MULT or REF_RES) / REF_RES)
end

local function hudDestroy()
    if not HUD.id then return end
    for _, name in ipairs({
        "destroyDisplay", "destroy", "removeDisplay", "deleteDisplay",
        "closeDisplay", "unbindDisplay", "releaseDisplay",
    }) do
        if type(gpu[name]) == "function" then
            pcall(gpu[name], HUD.id)
            HUD.id = nil
            return
        end
    end

    pcall(gpu.clear,         HUD.id, 0, 0, 0)
    pcall(gpu.setOpacity,    HUD.id, 0)
    pcall(gpu.updateDisplay, HUD.id)
    HUD.id = nil
end

local function hudCreate()
    if HUD.id then return true end

    print(string.format(
        "HUD: createDisplay offset=(%d,%d,%d) facing=%s size=%dx%d res=%d",
        CFG.X_OFF, CFG.Y_OFF, CFG.Z_OFF, CFG.FACING,
        CFG.BLOCK_W, CFG.BLOCK_H, CFG.RES_MULT))

    local ok, idOrErr = pcall(gpu.createDisplay,
        CFG.X_OFF, CFG.Y_OFF, CFG.Z_OFF,
        CFG.FACING, CFG.BLOCK_W, CFG.BLOCK_H,
        CFG.RES_MULT, true)
    if not ok or type(idOrErr) ~= "number" then
        print("HUD create FAILED: " .. tostring(idOrErr))
        return false
    end

    HUD.id = idOrErr
    HUD.pixelW, HUD.pixelH, HUD.res = dims()
    print(string.format("HUD: display id=%s, canvas %dx%d px, res=%s",
        tostring(HUD.id), HUD.pixelW, HUD.pixelH, tostring(HUD.res)))

    pcall(gpu.setRotation,          HUD.id, CFG.PITCH, CFG.YAW)
    pcall(gpu.setOpacity,           HUD.id, CFG.OPACITY)
    pcall(gpu.setBackgroundOpacity, HUD.id, CFG.BG_OPACITY)
    return true
end

local LAST = {
    yaw      = nil,
    pitch    = nil,
    opacity  = nil,
    bg       = nil,
    px       = nil, py = nil, pz = nil,
}

local function hudApplyLive()
    if not HUD.id then return end

    if LAST.yaw ~= CFG.YAW or LAST.pitch ~= CFG.PITCH then
        pcall(gpu.setRotation, HUD.id, CFG.PITCH, CFG.YAW)
        LAST.yaw, LAST.pitch = CFG.YAW, CFG.PITCH
    end
    if LAST.opacity ~= CFG.OPACITY then
        pcall(gpu.setOpacity, HUD.id, CFG.OPACITY)
        LAST.opacity = CFG.OPACITY
    end
    if LAST.bg ~= CFG.BG_OPACITY then
        pcall(gpu.setBackgroundOpacity, HUD.id, CFG.BG_OPACITY)
        LAST.bg = CFG.BG_OPACITY
    end

end

local CK  = {   0,   0,   0 }
local CW  = { 235, 238, 240 }
local CG  = {  90, 220, 130 }
local CGD = {  40,  90,  60 }
local CR  = { 235,  70,  70 }
local CGY = { 120, 130, 140 }

local function grect(x, y, w, h, c)
    if w < 1 or h < 1 then return end
    pcall(gpu.fillRect, HUD.id, math.floor(x), math.floor(y),
          math.floor(w), math.floor(h), c[1], c[2], c[3])
end

local function gtext(s, x, y, c, size, style)
    pcall(gpu.drawText, HUD.id, s, math.floor(x), math.floor(y),
          c[1], c[2], c[3], "Arial", size or 10, style or "plain")
end

local HAS_DRAWLINE = (type(gpu.drawLine) == "function")

local function gline(x0, y0, x1, y1, c, thick)
    thick = thick or 1
    x0 = math.floor(x0 + 0.5); y0 = math.floor(y0 + 0.5)
    x1 = math.floor(x1 + 0.5); y1 = math.floor(y1 + 0.5)
    if thick <= 1 and HAS_DRAWLINE then
        local ok = pcall(gpu.drawLine, HUD.id,
                         x0, y0, x1, y1, c[1], c[2], c[3])
        if ok then return end
        HAS_DRAWLINE = false
        print("HUD: gpu.drawLine unavailable, using software lines.")
    end
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
        pcall(gpu.fillRect, HUD.id, x0 - ox, y0 - oy, dw, dh,
              c[1], c[2], c[3])
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end
end

local function gborder(x, y, w, h, c)
    grect(x,         y,         w, 1, c)
    grect(x,         y + h - 1, w, 1, c)
    grect(x,         y,         1, h, c)
    grect(x + w - 1, y,         1, h, c)
end

local HAS_ROUNDRECT = (type(gpu.drawRoundedRect) == "function")

local function grrect(x, y, w, h, rad, c, filled)
    if w < 1 or h < 1 then return end
    x = math.floor(x); y = math.floor(y)
    w = math.floor(w); h = math.floor(h)
    rad = math.floor(math.min(rad, w / 2, h / 2))
    if rad >= 1 and HAS_ROUNDRECT then
        local ok = pcall(gpu.drawRoundedRect, HUD.id, x, y, w, h, rad,
                         c[1], c[2], c[3], filled and true or false)
        if ok then return end
        HAS_ROUNDRECT = false
    end
    if filled then grect(x, y, w, h, c) else gborder(x, y, w, h, c) end
end

local function gcommit()
    if HUD.id then pcall(gpu.updateDisplay, HUD.id) end
end

local COLOR_MODES = {
    WHITE = {
        fg   = { 235, 238, 240 },
        dim  = { 120, 130, 140 },
        acc  = {  90, 220, 130 },
        warn = { 235,  70,  70 },
        cau  = { 240, 180,  50 },
    },
    GREEN = {
        fg   = {  95, 240, 145 },
        dim  = {  48, 122,  78 },
        acc  = { 175, 255, 205 },
        warn = { 255, 120,  85 },
        cau  = { 225, 245, 115 },
    },
}

local function scheme()
    return COLOR_MODES[CFG.COLOR_MODE] or COLOR_MODES.WHITE
end

local function tickRank(v)
    local a = math.abs(v)
    if a % 10 == 0 then return 1.0     end
    if a %  5 == 0 then return 0.5     end
    if a %  2 == 0 then return 1 / 3   end
    return 0.25
end

local function tickVisible(v, pxPerStep)
    local a = math.abs(v)
    if a % 10 == 0 then return true end
    if a %  5 == 0 then return pxPerStep * 5 >= 3 end
    if a %  2 == 0 then return pxPerStep * 2 >= 3 end
    return pxPerStep >= 3
end

local UI = {
    hoverX        = -1,
    hoverY        = -1,
    scrollTargets = {},
    clickTargets  = {},
    pendingApply  = false,
    dirty         = true,
    page          = 1,
    viewBtnSeen   = os.clock(),
}

local FADE_AFTER = 3.0
local FADE_OVER  = 1.0

local function inRect(px, py, rx, ry, rw, rh)
    return px >= rx and px < rx + rw and py >= ry and py < ry + rh
end
local function uiAddScroll(x, y, w, h, fn)
    UI.scrollTargets[#UI.scrollTargets + 1] = { x=x, y=y, w=w, h=h, fn=fn }
end
local function uiAddClick(x, y, w, h, fn)
    UI.clickTargets[#UI.clickTargets + 1] = { x=x, y=y, w=w, h=h, fn=fn }
end

local LADDER_MAX  = 180
local BANK_RANGE  = 60
local BANK_LABELS = { -60, -30, 0, 30, 60 }

local C_SKY = { 14, 26, 20 }
local C_GND = {  6,  8,  7 }

local SPAWN_Y = nil
local function maybeAnchorSpawn(d)
    if SPAWN_Y == nil and d and d.y then SPAWN_Y = d.y end
end
local function zeroAlt(d)
    if d and d.y then SPAWN_Y = d.y end
end

local function paintIndicator(d)
    if not HUD.id then return end

    local SCH = scheme()
    local CW  = SCH.fg
    local CG  = SCH.acc
    local CGY = SCH.dim
    local CR  = SCH.warn
    local CAU = SCH.cau
    pcall(gpu.clear, HUD.id, 0, 0, 0)
    if not d then
        gtext("waiting for sub-level...", 10, 10, CGY, 10, "plain")
        return
    end

    local PW = HUD.pixelW
    local PH = HUD.pixelH

    local rc = resComp()
    local sm = CFG.SIZE_MULT or 1
    local sc = math.min(1.4, math.max(0.75, (PW / rc) / 320)) * rc * sm
    local px = rc * sm
    local tapeW = math.floor(math.max(36 * px,
                             math.min(56 * px, PW * 0.10 * sm)))
    tapeW = math.min(tapeW, math.floor(PW * 0.22))
    local tapeX = PW - tapeW

    local compH = math.floor(12 * sc)
    local bandH = math.floor(22 * sc)
    local hzX0  = 0
    local hzY0  = compH
    local hzW   = tapeX
    local hzH   = PH - compH - bandH
    local cx    = hzW * 0.5
    local cy    = hzY0 + hzH * 0.5

    local ppd    = hzH / 60.0
    local rollA  = math.rad(d.roll or 0)
    local rollCA = math.cos(rollA)
    local rollSA = math.sin(rollA)
    local function proj(u, v)
        return cx + u * rollCA - v * rollSA,
               cy + u * rollSA + v * rollCA
    end

    do
        local compY = 0
        local yawW = d.yaw or 0
        local function compassDeg()
            local h = (yawW % 360 + 360) % 360
            return h
        end
        local h = compassDeg()
        local scaleC = hzW / 90.0
        local function pointX(degAt)
            local diff = (degAt - h + 540) % 360 - 180
            return cx + diff * scaleC
        end
        local CARDINALS = { {0,"N"}, {90,"E"}, {180,"S"}, {270,"W"} }
        local cFont = math.floor(9 * sc)
        local tickH = math.floor(4 * sc)
        for _, c in ipairs(CARDINALS) do
            local x = pointX(c[1])
            if x >= 4 and x <= hzW - 4 then

                grect(x, compY, 1, tickH, CW)
                gtext(c[2], x - 3, compY + tickH + 1, CW, cFont, "bold")
            end
        end
        local minorH = math.floor(2 * sc)
        for tick = 0, 360, 15 do
            if tick % 90 ~= 0 then
                local x = pointX(tick)
                if x >= 2 and x <= hzW - 2 then
                    grect(x, compY, 1, minorH, CGY)
                end
            end
        end

        grect(cx, compY, 1, math.floor(6 * sc), CG)
        gtext(string.format("%03d", math.floor(h + 0.5) % 360),
              cx + 3, compY + tickH + 1, CG, cFont, "bold")
    end

    if d.gear then

        local amber = CAU
        local W       = math.max(28, math.floor(36 * sc))
        local H       = math.max(18, math.floor(22 * sc))
        local inset   = math.floor(6 * sc)
        local x0      = inset

        local y0      = math.max(0, inset - 4)
        local cx_g    = x0 + math.floor(W / 2)

        local whH = math.max(8, math.floor(H * 0.42 + 0.5))
        local whW = math.max(4, math.floor(W * 0.20 + 0.5))
        local wheelLeftX  = x0 + math.floor(W * 0.14)
        local wheelRightX = x0 + math.floor(W * 0.86) - whW + 1
        local wheelY      = y0 + H - whH

        local function wheel(wx)
            local fullH = whH - 2
            grect(wx + 1, wheelY,             whW - 2, 1,     amber)
            grect(wx,     wheelY + 1,         whW,     fullH, amber)
            grect(wx + 1, wheelY + 1 + fullH, whW - 2, 1,     amber)
        end
        wheel(wheelLeftX)
        wheel(wheelRightX)

        local axleY  = wheelY + math.floor(whH * 0.45)
        local axleH  = math.max(1, math.floor(2 * sc))
        local axleX0 = wheelLeftX + whW
        local axleX1 = wheelRightX
        grect(axleX0, axleY, axleX1 - axleX0, axleH, amber)

        local strutW   = math.max(1, math.floor(2 * sc))
        local strutTop = y0 + math.floor(H * 0.42)

        local diffW    = math.max(3, math.floor(4 * sc))
        local diffH    = math.max(2, math.floor(3 * sc))
        local diffX    = cx_g - math.floor(diffW / 2)
        local diffY    = axleY - math.floor(diffH / 2)
        local strutBot = diffY
        grect(cx_g - math.floor(strutW / 2), strutTop,
              strutW, strutBot - strutTop, amber)

        grect(diffX, diffY, diffW, diffH, amber)

        local topW = math.max(8, math.floor((wheelRightX + whW - wheelLeftX) * 0.45))
        local topH = math.max(1, math.floor(1.5 * sc))
        local topX = cx_g - math.floor(topW / 2)
        local topY = strutTop - topH
        grect(topX, topY, topW, topH, amber)

        local gFont = math.max(7, math.floor(8 * sc))
        local lblY  = y0 + H + math.floor(2 * sc)
        gtext("GEAR", x0 + math.floor(W * 0.10), lblY, amber, gFont, "bold")
    end

    local ladFont = math.floor(8 * sc)
    do
        local ladFull = 30 * sc
        local visSpan = (hzH * 0.5) / ppd + 4
        local pit     = d.pitch or 0
        local dLo = math.max(-LADDER_MAX, math.ceil(pit - visSpan))
        local dHi = math.min( LADDER_MAX, math.floor(pit + visSpan))
        for deg = dLo, dHi do
            if tickVisible(deg, ppd) then
                local v = -(deg - pit) * ppd
                local mx, my = proj(0, v)
                if my >= hzY0 + 2 and my <= hzY0 + hzH - 2
                   and mx >= hzX0 and mx <= hzX0 + hzW then
                    local rank   = tickRank(deg)
                    local isZero = (deg == 0)
                    local half = ladFull * (isZero and 1.4 or rank)
                    local lx, ly = proj(-half, v)
                    local rx, ry = proj( half, v)
                    gline(lx, ly, rx, ry,
                          isZero and CG or ((rank >= 1) and CW or CGY), 1)
                    if isZero then
                        gline(lx, ly + 1, rx, ry + 1, CG, 1)
                    end
                    if rank >= 1 then
                        local lbl = tostring(math.abs(deg))
                        local lcol = isZero and CG or CW
                        gtext(lbl, rx + 3, ry - 4, lcol, ladFont, "plain")
                        gtext(lbl, lx - math.floor(12 * sc), ly - 4,
                              lcol, ladFont, "plain")
                    end
                end
            end
        end
    end

    do
        local halfLen = hzW * 0.5
        local gap     = math.max(6, math.floor(10 * sc))
        local ax, ay = proj(-halfLen, 0)
        local bx, by = proj(-gap, 0)
        local ex, ey = proj(gap, 0)
        local fx, fy = proj(halfLen, 0)
        gline(ax, ay,     bx, by,     CW, 1)
        gline(ax, ay + 1, bx, by + 1, CW, 1)
        gline(ex, ey,     fx, fy,     CW, 1)
        gline(ex, ey + 1, fx, fy + 1, CW, 1)
    end

    do
        local bankR    = math.min(hzW * 0.45, hzH * 0.36)
        local pxPerDeg = bankR * math.pi / 180
        local majL     = math.max(4, math.floor(8 * sc))
        local aFont    = math.max(7, math.floor(8 * sc))
        local acw      = math.max(3, math.floor(aFont * 0.6 + 0.5))
        for deg = -BANK_RANGE, BANK_RANGE do
            if tickVisible(deg, pxPerDeg) then
                local rank = tickRank(deg)
                local L    = math.max(2, math.floor(majL * rank))
                local a    = math.rad(-90 + deg)
                local ca2, sa2 = math.cos(a), math.sin(a)
                gline(cx + bankR * ca2,       cy + bankR * sa2,
                      cx + (bankR + L) * ca2, cy + (bankR + L) * sa2,
                      (rank >= 1) and CW or CGY, 1)
            end
        end
        for _, deg in ipairs(BANK_LABELS) do
            local a   = math.rad(-90 + deg)
            local rr  = bankR + majL + math.floor(3 * sc)
            local lbl = tostring(math.abs(deg))
            gtext(lbl,
                  math.floor(cx + rr * math.cos(a) - (#lbl * acw) / 2),
                  math.floor(cy + rr * math.sin(a) - aFont / 2),
                  CGY, aFont, "plain")
        end
        local rollC = math.max(-BANK_RANGE,
                      math.min(BANK_RANGE, d.roll or 0))
        local pa    = math.rad(-90 + rollC)
        local pca, psa = math.cos(pa), math.sin(pa)
        local psz   = math.max(3, math.floor(5 * sc))
        local bR    = bankR - psz * 1.7
        local perX, perY = -psa * psz * 0.75, pca * psz * 0.75
        local tipX, tipY = cx + bankR * pca, cy + bankR * psa
        local p1x, p1y = cx + bR * pca + perX, cy + bR * psa + perY
        local p2x, p2y = cx + bR * pca - perX, cy + bR * psa - perY
        gline(tipX, tipY, p1x, p1y, CG, 2)
        gline(tipX, tipY, p2x, p2y, CG, 2)
        gline(p1x,  p1y,  p2x, p2y, CG, 2)
    end

    do
        local rcx, rcy = math.floor(cx), math.floor(cy)
        local sz = math.max(4, math.floor(5 * sc))

        grect(rcx - sz - 2, rcy, sz, 1, CW)
        grect(rcx + 3,      rcy, sz, 1, CW)
        grect(rcx, rcy - sz, 1, sz * 2 + 1, CW)

        local ay = rcy - sz - 4
        grect(rcx,     ay,     1, 1, CW)
        grect(rcx - 1, ay + 1, 3, 1, CW)
        grect(rcx - 2, ay + 2, 5, 1, CW)
    end

    do
        local eFont = math.max(8, math.floor(9 * sc))
        local ecw   = math.max(4, math.floor(eFont * 0.6 + 0.5))
        local pad   = math.max(3, math.floor(4 * sc))
        local pTxt  = string.format("%+.0f", d.pitch or 0)
        local rTxt  = string.format("%+.0f", d.roll  or 0)
        local boxW  = math.max(#pTxt, #rTxt) * ecw + ecw * 2 + pad * 3
        local boxH  = eFont + pad
        local bx    = hzX0 + math.max(2, math.floor(3 * sc))
        local pY    = math.floor(cy - boxH - math.floor(2 * sc))
        local rY    = math.floor(cy + math.floor(2 * sc))
        local ty    = math.floor(pad / 2)

        local function readout(y, tag, txt)
            gborder(bx, y, boxW, boxH, CGY)
            gtext(tag, bx + pad, y + ty, CGY, eFont, "plain")
            gtext(txt, bx + boxW - #txt * ecw - pad, y + ty,
                  CW, eFont, "bold")
        end
        readout(pY, "P", pTxt)
        readout(rY, "R", rTxt)
    end

    do
        local tx = tapeX
        local tH = hzH

        local centreY = hzY0 + tH * 0.5
        local pxPerM  = tH / 60.0
        local alt     = d.y or 0
        local function altToY(a)
            return centreY - (a - alt) * pxPerM
        end
        local rightEdge = tx + tapeW - 1

        local tFont   = math.max(7, math.floor(8 * sc))
        local majL    = math.floor(10 * sc)
        local visM    = (tH * 0.5) / pxPerM + 2
        local aLo     = math.floor(alt - visM)
        local aHi     = math.ceil(alt + visM)
        for a = aLo, aHi do
            if tickVisible(a, pxPerM) then
                local yy = altToY(a)
                if yy >= hzY0 + 2 and yy <= PH - 2 then
                    local rank = tickRank(a)
                    local L    = math.max(2, math.floor(majL * rank))
                    grect(rightEdge - L, yy, L, 1,
                          (rank >= 1) and CW or CGY)
                    if rank >= 1 then
                        gtext(tostring(a), tx + 2, yy - 4,
                              CGY, tFont, "plain")
                    end
                end
            end
        end

        if SPAWN_Y then
            local sy = altToY(SPAWN_Y)
            if sy >= hzY0 + 1 and sy <= PH then
                gline(rightEdge - 2,    sy,     rightEdge - 10, sy - 5, CG, 1)
                gline(rightEdge - 2,    sy,     rightEdge - 10, sy + 5, CG, 1)
                gline(rightEdge - 10,   sy - 5, rightEdge - 10, sy + 5, CG, 1)
                gtext("H", rightEdge - 18, sy - 4, CG, math.max(7, tFont), "plain")
            end
        end

        local vsiMax  = 10.0
        local vc      = math.max(-vsiMax, math.min(vsiMax, d.vy or 0))
        local vRows   = math.abs(vc) / vsiMax * (tH * 0.40)
        local vColW   = math.max(2, math.floor(2 * sc))
        local vColX   = rightEdge - majL - vColW - 2
        if vc >= 0 then
            grect(vColX, centreY - vRows, vColW, vRows, CG)
        else
            grect(vColX, centreY,         vColW, vRows, CGY)
        end
        grect(vColX - 1, centreY, vColW + 2, 1, CW)
    end

    if d.fuel then
        local v     = d.fuel
        local amber = CAU
        local col
        if     v >= 50 then col = CG
        elseif v >= 20 then col = amber
        else                col = CR end

        local pxAspect = (CFG.BLOCK_H * PW) / (CFG.BLOCK_W * PH)

        local areaScale = math.min(1.0,
            math.sqrt((CFG.BLOCK_W * CFG.BLOCK_H) / 6))

        local ryCap = 52 * px
        local ryMin = 18 * px
        local ryPad = 24 * px

        local baseRy      = math.floor(44 * sc * areaScale)
        local labFontBase = math.max(6 * px,
                            math.floor(8 * sc * areaScale))

        local maxRyByHeight = math.max(ryMin,
            math.floor(hzH * 0.5 - labFontBase - ryPad))
        local Ry = math.min(ryCap, math.max(ryMin, baseRy), maxRyByHeight)

        local labFont
        if Ry < math.min(ryCap, baseRy) then
            labFont = math.max(6 * px, math.floor(Ry * 0.21))
            maxRyByHeight = math.max(ryMin,
                math.floor(hzH * 0.5 - labFont - ryPad))
            Ry = math.min(ryCap, math.max(ryMin, baseRy), maxRyByHeight)
        else
            labFont = labFontBase
        end
        labFont = math.floor(labFont)
        Ry      = math.floor(Ry)

        local Rx = math.floor(Ry * pxAspect)
        local cw = math.max(3, math.floor(labFont * 0.6 + 0.5))

        local tickHalfMajY = math.max(3, math.floor(Ry * 0.11))
        local tickHalfMajX = math.max(3, math.floor(tickHalfMajY * pxAspect))
        local tickHalfMinY = math.max(2, math.floor(tickHalfMajY * 0.55))
        local tickHalfMinX = math.max(2, math.floor(tickHalfMinY * pxAspect))

        local labOffX  = math.max(14 * px, math.floor(cw + 8 * px))
        local labOffY  = math.max(14 * px, math.floor(labFont * 1.0))

        local sidePad   = tickHalfMajX + labOffX + math.floor(cw / 2) + 2
        local topPad    = tickHalfMajY + labOffY + math.floor(labFont / 2) + 2
        local bottomPad = math.floor(labFont / 2) + 3
        local fuelH     = Ry + topPad + bottomPad
        local by        = PH - bandH + 2
        local y0        = by - 4 - fuelH
        local x0        = math.max(3, math.floor(4 * sc))
        local cx_g      = x0 + sidePad + Rx
        local cy_g      = y0 + topPad  + Ry

        do
            local SEG = 40
            local pX, pY
            for i = 0, SEG do
                local a  = math.pi - (i / SEG) * math.pi
                local ax = cx_g + Rx * math.cos(a)
                local ay = cy_g - Ry * math.sin(a)
                if pX then gline(pX, pY, ax, ay, CW, 1) end
                pX, pY = ax, ay
            end
        end

        do
            local warnCol = CR
            local clearY  = 2
            local angleStart = math.pi
                - math.asin(math.min(0.5, clearY / Ry))
            local angleEnd   = math.pi * 7 / 8
            local SEG = 28
            local pX, pY
            for i = 0, SEG do
                local t  = i / SEG
                local a  = angleStart - t * (angleStart - angleEnd)
                local ax = cx_g + Rx * math.cos(a)
                local ay = cy_g - Ry * math.sin(a)
                if pX then gline(pX, pY, ax, ay, warnCol, 5) end
                pX, pY = ax, ay
            end
        end

        local STEPS        = 16
        local MAJOR_EVERY  = 4
        local MAJOR_LABELS = { "E", "1/4", "1/2", "3/4", "F" }
        local labRx        = Rx + tickHalfMajX + labOffX
        local labRy        = Ry + tickHalfMajY + labOffY
        for i = 0, STEPS do
            local a       = math.pi - (i / STEPS) * math.pi
            local ca, sa  = math.cos(a), math.sin(a)
            local isMajor = (i % MAJOR_EVERY == 0)
            local thx     = isMajor and tickHalfMajX or tickHalfMinX
            local thy     = isMajor and tickHalfMajY or tickHalfMinY
            gline(cx_g + (Rx + thx) * ca, cy_g - (Ry + thy) * sa,
                  cx_g + (Rx - thx) * ca, cy_g - (Ry - thy) * sa,
                  CW, isMajor and 2 or 1)
            if isMajor then
                local lbl = MAJOR_LABELS[(i / MAJOR_EVERY) + 1]
                local lx  = math.floor(cx_g + labRx * ca - (#lbl * cw) / 2)
                local ly  = math.floor(cy_g - labRy * sa - labFont / 2)
                gtext(lbl, lx, ly, CW, labFont, "plain")
            end
        end

        local fLbl = "FUEL"
        local fuelTopY = math.min(
            math.floor(cy_g - Ry * 0.65),
            cy_g - labFont * 2 - 3)
        gtext(fLbl,
              math.floor(cx_g - (#fLbl * cw) / 2),
              fuelTopY,
              CW, labFont, "bold")
        local vStr = string.format("%d%%", math.floor(v + 0.5))
        local pctTopY = math.max(
            math.floor(cy_g - Ry * 0.38),
            fuelTopY + labFont + 2)
        gtext(vStr,
              math.floor(cx_g - (#vStr * cw) / 2),
              pctTopY,
              col, labFont, "bold")

        local k  = math.max(0, math.min(100, v)) / 100
        local na = math.pi - k * math.pi
        gline(cx_g, cy_g,
              cx_g + 0.85 * Rx * math.cos(na),
              cy_g - 0.85 * Ry * math.sin(na),
              col, 3)

        local pRy = math.max(3, math.floor(3 * sc))
        local pRx = math.max(3, math.floor(pRy * pxAspect))
        grect(cx_g - pRx, cy_g - pRy, pRx * 2 + 1, pRy * 2 + 1, col)
    end

    do
        local by = PH - bandH + 2

        grect(0, by - 2, hzW, 1, CGY)
        local bFont = math.max(8, math.floor(9 * sc))
        local row2  = math.floor(10 * sc)

        local c1 = 6
        local c2 = math.floor(hzW * 0.25) + 6
        local c3 = math.floor(hzW * 0.50) + 6
        local c4 = math.floor(hzW * 0.75) + 6

        gtext(string.format("P %+6.2f", d.pitch),
              c1, by, CW, bFont, "bold")
        gtext(string.format("R %+6.2f", d.roll),
              c1, by + row2, CW, bFont, "bold")

        gtext(string.format("FWD %+.1f", d.fwd or 0),
              c2, by, CW, bFont, "plain")
        gtext(string.format("STR %+.1f", d.strafe or 0),
              c2, by + row2, CW, bFont, "plain")

        gtext(string.format("ALT: %.1f", d.y or 0),
              c3, by, CW, bFont, "bold")
        gtext(string.format("VS %+.1f", d.vy or 0),
              c3, by + row2, CW, bFont, "plain")

        local thr   = d.thr or 0
        local thrK  = math.max(0, math.min(1, thr / 15.0))
        local thrCol = lerpC(CW, CR, thrK)
        local thrLabel = string.format("THR: %d", thr)
        gtext(thrLabel, c4, by, thrCol, bFont, "bold")

        do
            local cw = math.floor(bFont * 0.6 + 0.5)
            local ax = c4 + #thrLabel * cw + 4
            local sz = math.max(3, math.floor(bFont * 0.55 + 0.5))
            local ay = by + math.floor((bFont - sz) / 2)
            if d.thrFwd and not d.thrRev then

                for row = 0, sz - 1 do
                    local w = (row * 2) + 1
                    if w > sz * 2 - 1 then w = sz * 2 - 1 end
                    grect(ax + sz - 1 - math.floor(w/2),
                          ay + row, w, 1, CG)
                end
            elseif d.thrRev and not d.thrFwd then

                for row = 0, sz - 1 do
                    local w = ((sz - 1 - row) * 2) + 1
                    if w > sz * 2 - 1 then w = sz * 2 - 1 end
                    grect(ax + sz - 1 - math.floor(w/2),
                          ay + row, w, 1, CR)
                end
            end
        end

        local hb = d.hb and true or false
        gtext("HB: " .. (hb and "ON" or "OFF"),
              c4, by + row2, hb and CR or CG, bFont, "bold")
    end
end

local function uiScale()
    local rc = resComp()
    local h  = (HUD.pixelH or 162) / rc
    return math.max(0.6, h / 162) * rc * (CFG.SIZE_MULT or 1)
end
local function S(v) return math.floor(v * uiScale() + 0.5) end
local FONT_STEPS = { 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48 }

local function snapFont(px, down)
    if down then
        local best = FONT_STEPS[1]
        for _, t in ipairs(FONT_STEPS) do
            if t <= px then best = t end
        end
        return best
    end
    local best, bestErr = FONT_STEPS[1], math.huge
    for _, t in ipairs(FONT_STEPS) do
        local err = math.abs(t - px)
        if err < bestErr then best, bestErr = t, err end
    end
    return best
end

local function ST(v)
    return snapFont(v * uiScale())
end

local CFG_BG     = {  14,  17,  24 }
local CFG_PANEL  = {  24,  29,  40 }
local CFG_ROW    = {  31,  37,  50 }
local CFG_HOVER  = {  38,  58,  88 }
local CFG_LINE   = {  46,  54,  70 }
local CFG_ACCENT = {  90, 190, 255 }
local CFG_WARN   = { 245, 165,  70 }
local CFG_OK     = { 120, 225, 145 }
local CFG_TXT    = { 232, 236, 242 }
local CFG_DIM    = { 132, 142, 158 }

local function setVal(key, v) CFG[key] = v; UI.dirty = true end
local function bumpVal(key, delta, lo, hi, decimals)
    local v = (CFG[key] or 0) + delta
    if lo then v = math.max(lo, v) end
    if hi then v = math.min(hi, v) end
    if decimals then
        local m = 10 ^ decimals
        v = math.floor(v * m + 0.5) / m
    end
    setVal(key, v)
end

local function applyHud()
    hudDestroy()

    os.sleep(0.05)
    hudCreate()
    UI.pendingApply = false
    UI.dirty = true
end

local ROW_H = 14

local function settingRow(x, y, w, h, label, value, ts,
                          onScroll, needsApply, valCol, clickable, alt)
    local hovered = inRect(UI.hoverX, UI.hoverY, x, y, w, h)
    local rad     = math.max(2, math.floor(h * 0.24))
    if hovered then
        grrect(x, y, w, h, rad, CFG_HOVER, true)
        grect(x, y + 1, math.max(2, math.floor(h * 0.10)), h - 2, CFG_ACCENT)
    elseif alt then
        grrect(x, y, w, h, rad, CFG_ROW, true)
    end

    local charW = math.max(1, math.floor(ts * 0.6))
    local ipad  = math.max(3, math.floor(charW * 0.8))
    local ty    = y + math.floor((h - ts) / 2)
    local dot   = (needsApply and UI.pendingApply)
                  and math.max(2, math.floor(ts * 0.22)) or 0
    local chev  = hovered and charW or 0

    local vw   = #value * charW
    local rEnd = x + w - ipad - (dot > 0 and (dot + ipad) or 0)
    local room = w - ipad * 2 - vw - chev * 2 - charW - dot
    local maxL = math.max(1, math.floor(room / charW))
    if #label > maxL then label = label:sub(1, maxL) end

    gtext(label, x + ipad, ty, CFG_TXT, ts, "plain")
    local vx = rEnd - vw - chev
    gtext(value, vx, ty, valCol or CFG_ACCENT, ts, "bold")
    if hovered then
        gtext("<", vx - charW, ty, CFG_DIM, ts, "plain")
        gtext(">", rEnd - chev + math.floor(charW * 0.2), ty,
              CFG_DIM, ts, "plain")
    end
    if dot > 0 then
        grect(x + w - ipad - dot, y + math.floor((h - dot) / 2),
              dot, dot, CFG_WARN)
    end
    if onScroll then
        uiAddScroll(x, y, w, h, onScroll)
        if clickable then
            uiAddClick(x, y, w, h, function() onScroll(1) end)
        end
    end
end

local function button(x, y, w, h, label, edgeColor, onClick, active, tsOver)
    local hovered = inRect(UI.hoverX, UI.hoverY, x, y, w, h)
    local rad  = math.max(2, math.floor(h * 0.28))
    local fill = hovered and CFG_HOVER or CFG_PANEL
    if active then
        fill = { edgeColor[1] / 3, edgeColor[2] / 3, edgeColor[3] / 3 }
    end
    grrect(x, y, w, h, rad, fill, true)
    grrect(x, y, w, h, rad, edgeColor, false)
    local ts = tsOver or ST(10)
    local charW = math.floor(ts * 0.6)
    local tw = #label * charW
    gtext(label, x + math.floor((w - tw)/2), y + math.floor((h - ts)/2),
          edgeColor, ts, "bold")
    if onClick then uiAddClick(x, y, w, h, onClick) end
end

local COLOR_PALETTE = {
    { 235, 238, 240 },
    {  90, 220, 130 },
    {  90, 200, 235 },
    { 235, 220,  90 },
    { 240, 160,  70 },
    { 240, 100, 100 },
    { 200, 120, 235 },
    { 120, 130, 140 },
}
local function colorEq(a, b)
    return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end
local function cycleColor(key)
    local cur = CFG[key]
    local idx = 1
    for i, c in ipairs(COLOR_PALETTE) do
        if colorEq(cur, c) then idx = i; break end
    end
    setVal(key, COLOR_PALETTE[(idx % #COLOR_PALETTE) + 1])
end

local function colorSwatch(x, y, w, label, key)
    local hovered = inRect(UI.hoverX, UI.hoverY, x, y, w, ROW_H)
    if hovered then grect(x, y, w, ROW_H, CFG_HOVER) end
    local ts = ST(10)
    gtext(label, x + S(5), y + S(3), CFG_TXT, ts, "plain")
    local sw = S(18)
    local sx = x + w - sw - S(6)
    grect(sx, y + S(2), sw, ROW_H - S(4), CFG[key] or { 0, 0, 0 })
    gborder(sx, y + S(2), sw, ROW_H - S(4), CFG_DIM)
    uiAddClick(x, y, w, ROW_H, function() cycleColor(key) end)
end

local SETTINGS_ITEMS = {
    { l = "X OFF", s = "X",
      v = function() return string.format("%+d", CFG.X_OFF) end,
      f = function(dir) bumpVal("X_OFF", -dir, -32, 32, 0) end },
    { l = "Y OFF", s = "Y",
      v = function() return string.format("%+d", CFG.Y_OFF) end,
      f = function(dir) bumpVal("Y_OFF", -dir, -32, 32, 0) end },
    { l = "Z OFF", s = "Z",
      v = function() return string.format("%+d", CFG.Z_OFF) end,
      f = function(dir) bumpVal("Z_OFF", -dir, -32, 32, 0) end },
    { l = "YAW", s = "YAW",
      v = function() return tostring(CFG.YAW) end,
      f = function(dir)
              local y = (CFG.YAW - dir * 90) % 360
              if y < 0 then y = y + 360 end
              setVal("YAW", y)
          end },
    { l = "OPACITY", s = "OPC",
      v = function() return CFG.OPACITY .. "%" end,
      f = function(dir) bumpVal("OPACITY", -dir * 5, 0, 100, 0) end },
    { l = "BG OPAC", s = "BG",
      v = function() return CFG.BG_OPACITY .. "%" end,
      f = function(dir) bumpVal("BG_OPACITY", -dir * 5, 0, 100, 0) end },
    { l = "WIDTH", s = "W", apply = true,
      v = function() return tostring(CFG.BLOCK_W or 6) end,
      f = function(dir)
              bumpVal("BLOCK_W", -dir, 1, 16, 0)
              UI.pendingApply = true
          end },
    { l = "HEIGHT", s = "H", apply = true,
      v = function() return tostring(CFG.BLOCK_H or 3) end,
      f = function(dir)
              bumpVal("BLOCK_H", -dir, 1, 16, 0)
              UI.pendingApply = true
          end },
    { l = "RES MULT", s = "RES", apply = true,
      v = function() return tostring(CFG.RES_MULT) end,
      f = function(dir)
              bumpVal("RES_MULT", -dir, 1, 4, 0)
              UI.pendingApply = true
          end },
    { l = "SIZE", s = "SZ",
      v = function()
              return math.floor((CFG.SIZE_MULT or 1) * 100 + 0.5) .. "%"
          end,
      f = function(dir) bumpVal("SIZE_MULT", -dir * 0.05, 0.6, 2.0, 2) end },
    { l = "COLOR", s = "COL", click = true,
      v = function() return CFG.COLOR_MODE end,
      c = function() return scheme().fg end,
      f = function()
              setVal("COLOR_MODE",
                     (CFG.COLOR_MODE == "GREEN") and "WHITE" or "GREEN")
          end },
}

local SETTINGS_GROUPS = {
    { name = "HOLOGRAM", from = 1,  to = 6  },
    { name = "DISPLAY",  from = 7,  to = 11 },
}

local function viewBtnRect()
    local W = HUD.pixelW or 320
    local H = HUD.pixelH or 240
    local f = snapFont(math.max(6, math.min(ST(6),
                       math.floor(H * 0.032))), true)
    local cwv = math.max(1, math.floor(f * 0.6))
    local w   = 3 * cwv + math.max(4, math.floor(f * 0.7))
    local h   = f + math.max(3, math.floor(f * 0.5))
    local m   = math.max(2, math.floor(f * 0.4))
    return W - w - m, m, w, h, f
end

local function paintSettings()
    if not HUD.id then return end
    UI.scrollTargets = {}
    UI.clickTargets  = {}

    local W, H = HUD.pixelW, HUD.pixelH
    grect(0, 0, W, H, CFG_BG)

    local pad  = math.max(2, math.floor(math.min(W, H) * 0.012))
    local cols = (W >= H * 1.5) and 2 or 1

    local vbx, _, _, vbh = viewBtnRect()
    local btnF = snapFont(math.max(6, math.min(ST(7),
                          math.floor(H * 0.036))), true)
    local bcw  = math.max(1, math.floor(btnF * 0.6))
    local bh   = btnF + math.max(3, math.floor(btnF * 0.7))
    local hdrF = snapFont(math.max(6, math.min(ST(9),
                          math.floor(H * 0.05))), true)
    local hcw  = math.max(1, math.floor(hdrF * 0.6))
    local hdrH = math.max(vbh, bh, hdrF) + pad * 2

    local availH = H - hdrH - pad * 2
    local colW   = math.floor((W - pad * (cols + 1)) / cols)

    local function buildFlow(heads)
        local f = {}
        if cols == 2 then
            for _, g in ipairs(SETTINGS_GROUPS) do
                local col = {}
                if heads then col[#col + 1] = { head = g.name } end
                for i = g.from, g.to do
                    col[#col + 1] = { it = SETTINGS_ITEMS[i] }
                end
                f[#f + 1] = col
            end
        else
            local col = {}
            for _, g in ipairs(SETTINGS_GROUPS) do
                if heads then col[#col + 1] = { head = g.name } end
                for i = g.from, g.to do
                    col[#col + 1] = { it = SETTINGS_ITEMS[i] }
                end
            end
            f[1] = col
        end
        return f
    end

    local function fitFont(flow)
        local maxLen, maxChars = 1, 1
        for _, col in ipairs(flow) do
            if #col > maxLen then maxLen = #col end
            for _, e in ipairs(col) do
                local c
                if e.head then
                    c = #e.head + 2
                else
                    local lbl = (cols == 1) and e.it.l or e.it.s
                    c = #lbl + #e.it.v() + 4
                end
                if c > maxChars then maxChars = c end
            end
        end
        local tsH = math.floor(availH / maxLen) - 1 - pad
        local tsW = math.floor((colW - pad * 4) / (maxChars * 0.6))
        return snapFont(math.max(6,
               math.min(ST(10), tsH, tsW)), true), maxLen
    end

    local flow = buildFlow(true)
    local ts, maxLen = fitFont(flow)
    if ts < 10 then
        flow = buildFlow(false)
        ts, maxLen = fitFont(flow)
    end

    local rowH = ts + pad
    ROW_H = rowH

    local perCol = math.max(1, math.floor(availH / (rowH + 1)))
    local pages  = math.max(1, math.ceil(maxLen / perCol))
    if UI.page > pages then UI.page = pages end
    if UI.page < 1    then UI.page = 1     end

    grect(0, 0, W, hdrH, CFG_PANEL)
    grect(0, hdrH - 1, W, 1, CFG_ACCENT)

    local bSave  = 4 * bcw + pad * 2
    local bApply = 6 * bcw + pad * 2
    local by     = math.floor((hdrH - bh) / 2)
    local bx     = vbx - pad - bSave
    button(bx, by, bSave, bh, "SAVE", CFG_OK,
           function() saveCfg(); UI.dirty = true end, false, btnF)
    bx = bx - pad - bApply
    button(bx, by, bApply, bh,
           UI.pendingApply and "APPLY*" or "APPLY",
           UI.pendingApply and CFG_WARN or CFG_DIM,
           applyHud, UI.pendingApply, btnF)

    local hty = math.floor((hdrH - hdrF) / 2)
    if pages > 1 then
        local ptxt = UI.page .. "/" .. pages
        local aw   = #ptxt * bcw + pad * 2
        button(pad, by, aw, bh, ptxt, CFG_ACCENT, function()
            UI.page  = (UI.page % pages) + 1
            UI.dirty = true
        end, false, btnF)
    elseif bx - pad * 2 >= 8 * hcw then
        gtext("SETTINGS", pad, hty, CFG_TXT, hdrF, "bold")
    end

    local first  = (UI.page - 1) * perCol + 1
    local rowTop = hdrH + pad
    local shown  = math.min(perCol, maxLen - first + 1)
    if shown < 1 then shown = 1 end
    local panelH = shown * (rowH + 1) + pad

    for c, col in ipairs(flow) do
        local x = pad + (c - 1) * (colW + pad)
        grrect(x, rowTop, colW, panelH,
               math.max(2, math.floor(rowH * 0.3)), CFG_PANEL, true)
        local y = rowTop + math.floor(pad / 2)
        local ix, iw = x + 2, colW - 4
        for i = first, math.min(#col, first + perCol - 1) do
            local e = col[i]
            if e.head then
                local hf = snapFont(math.max(6,
                           math.floor(ts * 0.85)), true)
                local hw = #e.head * math.max(1, math.floor(hf * 0.6))
                gtext(e.head, ix + 4, y + math.floor((rowH - hf) / 2),
                      CFG_ACCENT, hf, "bold")
                local ly = y + math.floor(rowH / 2)
                grect(ix + 8 + hw, ly, iw - 12 - hw, 1, CFG_LINE)
            else
                local it  = e.it
                local lbl = (cols == 1) and it.l or it.s
                settingRow(ix, y, iw, rowH, lbl, it.v(), ts,
                           it.f, it.apply,
                           it.c and it.c() or nil, it.click,
                           (i % 2) == 0)
            end
            y = y + rowH + 1
        end
    end

    local restH = availH - panelH
    if pages == 1 and restH >= ts + pad * 2 then
        local hf   = snapFont(math.max(6, ts - 2), true)
        local hfw  = math.max(1, math.floor(hf * 0.6))
        local hint = "scroll a row to tune, click to toggle"
        if #hint * hfw > W - pad * 2 then hint = "scroll to tune" end
        if #hint * hfw <= W - pad * 2 then
            gtext(hint, pad * 2, rowTop + panelH + pad,
                  CFG_DIM, hf, "plain")
        end
    end
end

local function viewBtnAlpha(x, y, w, h)
    if CFG.VIEW ~= "INDICATOR" then return 1 end
    local m = math.max(4, math.floor(h * 0.9))
    if inRect(UI.hoverX, UI.hoverY,
              x - m, y - m, w + m * 2, h + m * 2) then
        UI.viewBtnSeen = os.clock()
        return 1
    end
    local age = os.clock() - (UI.viewBtnSeen or 0)
    if age <= FADE_AFTER then return 1 end
    if age >= FADE_AFTER + FADE_OVER then return 0 end
    return 1 - (age - FADE_AFTER) / FADE_OVER
end

local function drawViewButton()
    if not HUD.id then return end

    local x, y, w, h, ts = viewBtnRect()
    uiAddClick(x, y, w, h, function()
        if CFG.VIEW == "INDICATOR" then CFG.VIEW = "SETTINGS"
        else CFG.VIEW = "INDICATOR" end
        UI.page  = 1
        UI.dirty = true
    end)

    local a = viewBtnAlpha(x, y, w, h)
    if a <= 0.02 then return end

    local label   = (CFG.VIEW == "INDICATOR") and "SET" or "IND"
    local hovered = inRect(UI.hoverX, UI.hoverY, x, y, w, h)
    local base    = hovered and CFG_HOVER or { 20, 30, 50 }
    local bgc     = lerpC(CK, base, a)
    local edge    = lerpC(CK, CFG_ACCENT, a)
    local rad     = math.max(2, math.floor(h * 0.3))
    grrect(x, y, w, h, rad, bgc, true)
    grrect(x, y, w, h, rad, edge, false)
    local charW = math.floor(ts * 0.6)
    local tw = #label * charW
    gtext(label, x + math.floor((w - tw) / 2),
          y + math.floor((h - ts) / 2), edge, ts, "bold")
end

local function consumeEvents()
    if not HUD.id then return false end
    local anyChange = false
    while gpu.hasEvents(HUD.id) do
        local e = gpu.pollEvent(HUD.id)
        if type(e) == "table" then
            local t = e.type
            if type(e.x) == "number" and type(e.y) == "number" then
                UI.hoverX = e.x
                UI.hoverY = e.y
                anyChange = true
            end
            if t == "mouse_click" then
                local cx, cy = e.x or 0, e.y or 0

                for i = #UI.clickTargets, 1, -1 do
                    local tgt = UI.clickTargets[i]
                    if inRect(cx, cy, tgt.x, tgt.y, tgt.w, tgt.h) then
                        tgt.fn()
                        anyChange = true
                        break
                    end
                end
            elseif t and t:find("scroll") then
                local d = e.button or e.direction or e.dir or e.delta
                       or e.dy or e.wheel
                if type(d) == "number" and d ~= 0 then
                    local dir = (d > 0) and 1 or -1
                    for _, tgt in ipairs(UI.scrollTargets) do
                        if inRect(UI.hoverX, UI.hoverY,
                                  tgt.x, tgt.y, tgt.w, tgt.h) then
                            tgt.fn(dir)
                            anyChange = true
                            break
                        end
                    end
                end
            end
        end
    end
    return anyChange
end

local DATA = { cur = nil }

local FUEL_DIAG = {
    lines  = nil,
    cache  = nil,
    raw    = nil,
    sized  = false,
}

local FUEL_RESET = false

pollSableCache = function() return DATA.cur end

local function pollLoop()
    local announced = false

    local targetSized    = false
    local lastTargetName = ""

    local lineCache = {}
    while true do
        local d = pollSable()
        if d then
            if not announced then
                announced = true
                print(string.format(
                    "HUD: first sublevel poll OK -- pos=(%.1f, %.1f, %.1f)",
                    d.x, d.y, d.z))
            end
            maybeAnchorSpawn(d)

            local thr, hb = 0, false
            local thrFwd, thrRev = false, false
            local gear = false
            if CFG.RELAY_THR ~= "" then
                local ok, v = pcall(peripheral.call,
                    CFG.RELAY_THR, "getAnalogInput", "front")
                if ok and type(v) == "number" then thr = v end
            end
            if CFG.RELAY_HB ~= "" then
                local ok, v = pcall(peripheral.call,
                    CFG.RELAY_HB, "getInput", "front")
                if ok then hb = (v == true) end
            end
            if CFG.RELAY_THR_FWD ~= "" then
                local ok, v = pcall(peripheral.call,
                    CFG.RELAY_THR_FWD, "getInput", "front")
                if ok then thrFwd = (v == true) end
            end
            if CFG.RELAY_THR_REV ~= "" then
                local ok, v = pcall(peripheral.call,
                    CFG.RELAY_THR_REV, "getInput", "front")
                if ok then thrRev = (v == true) end
            end
            if CFG.RELAY_GEAR ~= "" then
                local ok, v = pcall(peripheral.call,
                    CFG.RELAY_GEAR, "getInput", "front")
                if ok then gear = (v == true) end
            end

            local fuelRaw = nil
            if FUEL_RESET then

                FUEL_RESET     = false
                lineCache      = {}
                FUEL_DIAG.lines = nil
                FUEL_DIAG.cache = nil
                FUEL_DIAG.raw   = nil
            end
            if CFG.TARGET_FUEL ~= "" then
                if CFG.TARGET_FUEL ~= lastTargetName then
                    lastTargetName = CFG.TARGET_FUEL
                    targetSized    = false
                    lineCache      = {}
                end
                if not targetSized then
                    local ok = pcall(peripheral.call,
                        CFG.TARGET_FUEL, "resize", 16, 16)
                    if ok then targetSized = true end
                end
                if targetSized then
                    local ok, lines = pcall(peripheral.call,
                        CFG.TARGET_FUEL, "dump")
                    if ok and type(lines) == "table" then
                        FUEL_DIAG.lines = lines
                        local now = os.clock()

                        for i, line in ipairs(lines) do
                            if type(line) == "string" then
                                local num = tonumber(
                                    line:match("(%-?%d+%.?%d*)"))
                                if num then
                                    lineCache[i] =
                                        { val = num, t = now }
                                end
                            end
                        end

                        local sum, n = 0, 0
                        for _, e in pairs(lineCache) do
                            sum = sum + e.val
                            n   = n + 1
                        end
                        if n > 0 then fuelRaw = sum / n end
                    end
                end
                FUEL_DIAG.sized = targetSized
                FUEL_DIAG.cache = lineCache
                FUEL_DIAG.raw   = fuelRaw
            else

                lineCache       = {}
                FUEL_DIAG.lines = nil
                FUEL_DIAG.cache = nil
                FUEL_DIAG.raw   = nil
                FUEL_DIAG.sized = false
            end

            d.thr    = thr
            d.hb     = hb
            d.thrFwd = thrFwd
            d.thrRev = thrRev
            d.gear   = gear
            d.fuel   = fuelRaw
            DATA.cur = d
        end

        sleep(0.05)
    end
end

local function renderLoop()

    local EV = "hud_render"
    os.queueEvent(EV)
    local lastPaint = os.clock()

    while true do
        os.pullEvent(EV)

        local now = os.clock()
        local minDt = 1 / math.max(10, math.min(20, CFG.REFRESH_HZ or 20))

        if not HUD.id then
            if hudCreate() then UI.dirty = true end
        end

        if HUD.id and (now - lastPaint) >= minDt then
            hudApplyLive()
            consumeEvents()
            UI.scrollTargets = {}
            UI.clickTargets  = {}
            if CFG.VIEW == "SETTINGS" then
                paintSettings()
            else
                paintIndicator(DATA.cur)
            end
            drawViewButton()
            pcall(gpu.updateDisplay, HUD.id)
            lastPaint = now
        end

        os.queueEvent(EV)
    end
end

local function printHelp()
    print("-- HUD COMMANDS --")
    print("  view ind | view settings  switch display mode")
    print("  res <n>       1 .. 3      resolution multiplier (then 'apply')")
    print("  hz <n>        refresh rate")
    print("  x <n> | y <n> | z <n>     hologram offset (live)")
    print("  yaw <n>       rotation in degrees (live)")
    print("  opac <n>      0..100  content opacity")
    print("  bg <n>        0..100  background opacity")
    print("  zero          set current alt as AGL zero")
    print("  size <n>      element size, percent (e.g. 115)")
    print("  color white | color green  HUD element color mode")
    print("  wizard        re-run the peripheral setup")
    print("  target <name>            CC:C Bridge Target Block for fuel")
    print("  target clear             disable fuel column")
    print("  fuel                     diagnostic: raw lines + cache + avg")
    print("  fuel reset               clear the per-line cache")
    print("  apply         rebuild hologram with new size")
    print("  save          persist to " .. CFG_FILE)
    print("  reset         delete config")
    print("  status        print current settings")
    print("  help | h      this list")
end

local function cmdLoop()

    sleep(0.5)
    print("Type 'help' for HUD commands.")
    while true do
        write("> ")
        local line = read()
        if not line or line == "" then

        else
            local words = {}
            for w in line:gmatch("%S+") do words[#words + 1] = w end
            local one = words[1] and words[1]:lower()
            local two = words[2] and words[2]:lower()
            local n   = tonumber(words[2])

            if one == "help" or one == "h" then
                printHelp()
            elseif one == "view" then
                if two == "ind" or two == "indicator" then
                    setVal("VIEW", "INDICATOR")
                    print("view = INDICATOR")
                elseif two == "set" or two == "settings" then
                    setVal("VIEW", "SETTINGS")
                    print("view = SETTINGS")
                else
                    print("view ind | view settings")
                end
            elseif one == "res" and n then
                CFG.RES_MULT = math.max(1, math.min(4, math.floor(n)))
                UI.pendingApply = true; UI.dirty = true
                print("RES_MULT = " .. CFG.RES_MULT .. "  (run 'apply' to rebuild)")
            elseif one == "hz" and n then
                CFG.REFRESH_HZ = math.max(10, math.min(20, math.floor(n)))
                print("REFRESH_HZ = " .. CFG.REFRESH_HZ)
            elseif one == "x" and n then
                CFG.X_OFF = n; UI.dirty = true
                print("X_OFF = " .. CFG.X_OFF)
            elseif one == "y" and n then
                CFG.Y_OFF = n; UI.dirty = true
                print("Y_OFF = " .. CFG.Y_OFF)
            elseif one == "z" and n then
                CFG.Z_OFF = n; UI.dirty = true
                print("Z_OFF = " .. CFG.Z_OFF)
            elseif one == "yaw" and n then
                CFG.YAW = n % 360; UI.dirty = true
                print("YAW = " .. CFG.YAW)
            elseif one == "opac" and n then
                CFG.OPACITY = math.max(0, math.min(100, math.floor(n)))
                UI.dirty = true
                print("OPACITY = " .. CFG.OPACITY)
            elseif one == "bg" and n then
                CFG.BG_OPACITY = math.max(0, math.min(100, math.floor(n)))
                UI.dirty = true
                print("BG_OPACITY = " .. CFG.BG_OPACITY)
            elseif one == "zero" then
                zeroAlt(DATA.cur)
                print("AGL zero set to current altitude")
            elseif one == "size" and n then
                local m = (n > 10) and (n / 100) or n
                CFG.SIZE_MULT = math.max(0.6, math.min(2.0,
                    math.floor(m * 100 + 0.5) / 100))
                UI.dirty = true
                saveCfg()
                print(string.format("SIZE_MULT = %d %%",
                    math.floor(CFG.SIZE_MULT * 100 + 0.5)))
            elseif one == "color" or one == "colour" then
                if two == "white" or two == "green" then
                    setVal("COLOR_MODE", two:upper())
                    saveCfg()
                    print("COLOR_MODE = " .. CFG.COLOR_MODE)
                elseif two == nil then
                    setVal("COLOR_MODE",
                           (CFG.COLOR_MODE == "GREEN") and "WHITE" or "GREEN")
                    saveCfg()
                    print("COLOR_MODE = " .. CFG.COLOR_MODE)
                else
                    print("color white | color green   (now: "
                          .. tostring(CFG.COLOR_MODE) .. ")")
                end
            elseif one == "wizard" then
                wizard()
                UI.dirty = true
            elseif one == "target" then

                if two == nil then
                    print("TARGET_FUEL = "
                          .. (CFG.TARGET_FUEL == "" and "(unset)"
                              or CFG.TARGET_FUEL))
                elseif two == "clear" or two == "''" or two == '""' then
                    CFG.TARGET_FUEL = ""
                    print("TARGET_FUEL cleared -- fuel column disabled")
                else
                    local raw = words[2]
                    CFG.TARGET_FUEL = raw
                    local found = peripheral.wrap(raw) ~= nil
                    print(string.format(
                        "TARGET_FUEL = %s  (%s)",
                        raw, found and "OK" or "NOT FOUND"))
                end
            elseif one == "fuel" then

                if two == "reset" then
                    FUEL_RESET = true
                    print("Fuel cache reset requested -- "
                          .. "will clear on next poll.")
                elseif CFG.TARGET_FUEL == "" then
                    print("TARGET_FUEL not set -- use 'target <name>' first.")
                else
                    print("TARGET_FUEL = " .. CFG.TARGET_FUEL
                          .. (FUEL_DIAG.sized and ""
                              or "  (resize pending)"))
                    local lines = FUEL_DIAG.lines
                    if type(lines) == "table" then
                        print("Raw lines:")
                        for i, line in ipairs(lines) do
                            local trimmed = (line or ""):gsub("%s+$", "")
                            if trimmed ~= "" then
                                print(string.format(
                                    "  [%2d] %q", i, trimmed))
                            end
                        end
                    else
                        print("Raw lines: (no successful dump yet)")
                    end
                    local cache = FUEL_DIAG.cache
                    if type(cache) == "table" then
                        print("Cache:")
                        local now = os.clock()
                        local any = false
                        local ks = {}
                        for k in pairs(cache) do ks[#ks+1] = k end
                        table.sort(ks)
                        for _, k in ipairs(ks) do
                            local e = cache[k]
                            print(string.format(
                                "  [%2d] %6.1f%%   (age %.2fs)",
                                k, e.val, now - e.t))
                            any = true
                        end
                        if not any then print("  (empty)") end
                    end
                    print(string.format("avg = %s",
                        FUEL_DIAG.raw
                            and string.format("%.2f%%", FUEL_DIAG.raw)
                            or  "nil"))
                end
            elseif one == "apply" then
                applyHud()
                local w, h = dims()
                print(string.format("Hologram rebuilt: %dx%d px, RES=%d",
                    w, h, CFG.RES_MULT))
            elseif one == "save" then
                saveCfg()
                print("Saved to " .. CFG_FILE)
            elseif one == "reset" then
                if fs.exists(CFG_FILE) then fs.delete(CFG_FILE) end
                print("Config deleted -- restart the program to apply defaults.")
            elseif one == "status" then
                local w, h = dims()
                print(string.format(
                    "VIEW=%s  off=(%.2f,%.2f,%.2f)  yaw=%d  canvas=%dx%d  res=%d",
                    CFG.VIEW, CFG.X_OFF, CFG.Y_OFF, CFG.Z_OFF,
                    CFG.YAW, w, h, CFG.RES_MULT))
                print(string.format(
                    "opac=%d  bg=%d  hz=%d  color=%s",
                    CFG.OPACITY, CFG.BG_OPACITY, CFG.REFRESH_HZ,
                    tostring(CFG.COLOR_MODE)))
                print(string.format(
                    "ui scale x%.2f (locked to RES %d)  size=%d%%",
                    resComp(), REF_RES,
                    math.floor((CFG.SIZE_MULT or 1) * 100 + 0.5)))
                print("fuel target = "
                      .. (CFG.TARGET_FUEL == "" and "(unset)"
                          or CFG.TARGET_FUEL))
            else
                print("unknown command -- type 'help'")
            end
        end
    end
end

print("HUD: starting...")
print("HUD: VIEW=" .. CFG.VIEW)
print("HUD: tap top-right button on the hologram to switch views.")

local ok, err = pcall(function()
    parallel.waitForAny(pollLoop, renderLoop, cmdLoop)
end)

hudDestroy()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("HUD stopped.")
if not ok and err ~= "Terminated" then
    print("Error: " .. tostring(err))
end
