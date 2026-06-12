local BASE = "https://raw.githubusercontent.com/AkumaHalls/AWTech/main/awtech_lua"
local CACHE = "./awtech_lua"

local function load(name)
    local filename = name .. ".lua"
    local url = BASE .. "/awtech_" .. filename
    local cachePath = CACHE .. "/awtech_" .. filename
    local src

    -- try remote
    local ok, body = pcall(http.Get, url)
    if ok and type(body) == "string" and #body > 50 then
        src = body
        print("[awtech] " .. name .. " downloaded from " .. url)
        -- save cache
        pcall(function()
            local f = file.Open(cachePath, "w")
            if f then f:Write(body); f:Close() end
        end)
    else
        -- fallback to cached
        print("[awtech] download failed, trying cache: " .. cachePath)
        pcall(function()
            local f = file.Open(cachePath, "r")
            if f then src = f:Read(); f:Close() end
        end)
    end

    if type(src) ~= "string" or #src <= 50 then
        print("[awtech] FATAL: cannot load " .. name)
        return nil
    end
    local chunk, err = loadstring(src, "=" .. name)
    if not chunk then print("[awtech] " .. name .. " compile error: " .. tostring(err)); return nil end
    local ok, mod = pcall(chunk)
    if not ok then print("[awtech] " .. name .. " run error: " .. tostring(mod)); return nil end
    print("[awtech] " .. name .. " loaded successfully")
    return mod
end

local M = load("guilib")
if type(M) ~= "table" then return end

local C = load("changer")
if type(C) ~= "table" then return end

local ffi = rawget(_G, "ffi")
local floor = math.floor

local VM = {}
local EV = { installed = false }
local HS = {}

local weaponLb, skinLb, skinWd
local sWear, sSeed, cbAuto
local modelLb, modelWd, modelPaths
local cbVm, vmX, vmY, vmZ
local hsOn, hsCmb, hsCmbWd, hsVol
local ksOn, ksCmb, ksCmbWd, ksVol
local SND_NAMES, SND_PATHS

local lastModelSel = -1
local curPaints    = { 0 }
local lastSel      = -1
local lastSig      = nil
local lastAutoDef  = nil
local lastAuto     = false

local function item()     return C.items[weaponLb:Get()] end
local function paint()    return curPaints[skinLb:Get()] or 0 end
local function settings() return sWear:Get(), floor(sSeed:Get() + 0.5) end

local function applySelected()
    local it = item(); if not it then return end
    local w, s = settings()
    C.apply(it, paint(), w, s)
end

local function sig()
    local it = item(); if not it then return "none" end
    local w, s = settings()
    return it.def.."|"..paint().."|"..floor(w * 100000).."|"..s
end

local function autoFollow()
    if not cbAuto:Get() then lastAutoDef = nil; return end
    local def = C.activeDef(); if not def then return end
    if not C.defToItem[def] and C.isKnife(def) and C.knifeDef() then def = C.knifeDef() end
    if def == lastAutoDef then return end
    local idx = C.defToItem[def]; if not idx then return end
    lastAutoDef = def
    weaponLb:Set(idx)
end

local function autoApply()
    local s = sig()
    if s == lastSig then return end
    lastSig = s
    applySelected()
end

local function syncSkins()
    local sel = weaponLb:Get()
    if sel == lastSel then return end
    lastSel = sel
    local it = C.items[sel]; if not it then return end
    local names, paints = C.skinList(it.def)
    curPaints     = paints
    skinWd.items  = names
    skinWd.value  = 1
    skinWd.scroll = 0
    local c = C.getCfg(it.def)
    if c then
        sWear:Set(c.wear); sSeed:Set(c.seed)
        for i = 2, #paints do
            if paints[i] == c.paint then skinWd.value = i; break end
        end
    end
    lastSig = sig()
end

local function persistOpts()
    local v = cbAuto:Get()
    if v ~= lastAuto then lastAuto = v; C.setOpt("autoFollow", v) end
end

local function syncModel()
    if not modelLb then return end
    local sel = modelLb:Get()
    if sel == lastModelSel then return end
    lastModelSel = sel
    C.setLocalModel(modelPaths and modelPaths[sel] or nil)
end

local SIG = {
    vm        = "E8 ?? ?? ?? ?? 48 8B CB E8 ?? ?? ?? ?? 84 C0 74 11 F3 0F 10 45 B0",
    ev_mgr    = "48 8D 47 40 48 C1 E2 04 48 03 D0 74 0D 48 8B 0D",
    ev_getint = "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 30 48 8B 01 41 8B F0",
}

-- ===== CS2 UPDATE SURVIVAL: signature health monitor =====
local SIG_MONITOR = {
    interval = 10,
    timer    = 0,
    healthy  = { vm = false, ev_mgr = false, ev_getint = false },
    resolved = false,
}

local function checkSigs()
    for name, pattern in pairs(SIG) do
        local a = mem.FindPattern("client.dll", pattern)
        SIG_MONITOR.healthy[name] = (a ~= nil and a ~= 0)
    end
    SIG_MONITOR.resolved = true
    local allOk = true
    for _, v in pairs(SIG_MONITOR.healthy) do if not v then allOk = false; break end end
    return allOk
end

local function sigTick()
    SIG_MONITOR.timer = SIG_MONITOR.timer + (M.now() - (SIG_MONITOR._last or M.now()))
    SIG_MONITOR._last = M.now()
    if SIG_MONITOR.timer >= SIG_MONITOR.interval then
        SIG_MONITOR.timer = 0
        local ok = checkSigs()
        if not ok then
            local failed = {}
            for name, healthy in pairs(SIG_MONITOR.healthy) do
                if not healthy then failed[#failed+1] = name end
            end
            print("[awtech] SIG MONITOR: stale signatures detected: " .. table.concat(failed, ", ") .. " -- re-resolve next round")
        end
    end
end

local function r_ptr(a) return tonumber(ffi.cast("uint64_t*", a)[0]) end
local function valid(p) return p ~= nil and p > 0x10000 and p < 0x7FFFFFFFFFFF end

do
    local page, match, origRel, ok = nil, nil, nil, false

    local function r_i32(a) return ffi.cast("int32_t*",  a)[0] end
    local function w_u8 (a, v) ffi.cast("uint8_t*", a)[0] = v end
    local function w_i32(a, v) ffi.cast("int32_t*", a)[0] = v end
    local function w_f32(a, v) ffi.cast("float*",   a)[0] = v end

    local function le64(v)
        local t = {}
        for _ = 1, 8 do t[#t + 1] = v % 256; v = math.floor(v / 256) end
        return t
    end

    local function alloc_near(target, size)
        local gran = 0x10000
        local base = target - (target % gran)
        for i = 1, 0x8000 do
            local lo, hi = base - i * gran, base + i * gran
            if lo > 0x10000 then
                local p = ffi.C.VirtualAlloc(ffi.cast("void*", lo), size, 0x3000, 0x40)
                if p ~= nil then return p end
            end
            local p2 = ffi.C.VirtualAlloc(ffi.cast("void*", hi), size, 0x3000, 0x40)
            if p2 ~= nil then return p2 end
        end
        return nil
    end

    local function install()
        if type(ffi) ~= "table" then print("[awtech] VM: no ffi"); return false end
        pcall(function() ffi.cdef [[
            void* VirtualAlloc(void*, size_t, uint32_t, uint32_t);
            int   VirtualProtect(void*, size_t, uint32_t, uint32_t*);
            void* GetCurrentProcess(void);
            int   FlushInstructionCache(void*, void*, size_t);
        ]] end)

        local a = mem.FindPattern("client.dll", SIG.vm)
        if not a or a == 0 then print("[awtech] VM: sig not found"); return false end
        match = a
        local orig = a + 5 + r_i32(a + 1)

        local p = alloc_near(orig, 0x1000)
        if p == nil then print("[awtech] VM: alloc failed"); return false end
        page = tonumber(ffi.cast("uintptr_t", p))
        local code = page + 16

        local b = { 0x53, 0x56, 0x48,0x83,0xEC,0x28, 0x48,0x89,0xD6, 0x48,0xB8 }
        for _, v in ipairs(le64(orig)) do b[#b + 1] = v end
        for _, v in ipairs({ 0xFF,0xD0, 0x48,0xBB }) do b[#b + 1] = v end
        for _, v in ipairs(le64(page)) do b[#b + 1] = v end
        for _, v in ipairs({
            0x8B,0x0B, 0x85,0xC9, 0x74,0x2B,
            0xF3,0x0F,0x10,0x4B,0x04, 0xF3,0x0F,0x58,0x0E, 0xF3,0x0F,0x11,0x0E,
            0xF3,0x0F,0x10,0x4B,0x08, 0xF3,0x0F,0x58,0x4E,0x04, 0xF3,0x0F,0x11,0x4E,0x04,
            0xF3,0x0F,0x10,0x4B,0x0C, 0xF3,0x0F,0x58,0x4E,0x08, 0xF3,0x0F,0x11,0x4E,0x08,
            0x48,0x83,0xC4,0x28, 0x5E, 0x5B, 0xC3,
        }) do b[#b + 1] = v end
        for i = 0, #b - 1 do w_u8(code + i, b[i + 1]) end
        w_i32(page, 0); w_f32(page + 4, 0); w_f32(page + 8, 0); w_f32(page + 12, 0)

        local rel = code - (match + 5)
        if rel < -2147483648 or rel > 2147483647 then print("[awtech] VM: rel32 overflow"); return false end
        origRel = r_i32(match + 1)
        local old = ffi.new("uint32_t[1]")
        ffi.C.VirtualProtect(ffi.cast("void*", match), 5, 0x40, old)
        w_i32(match + 1, rel)
        ffi.C.VirtualProtect(ffi.cast("void*", match), 5, old[0], old)
        pcall(function() ffi.C.FlushInstructionCache(ffi.C.GetCurrentProcess(), ffi.cast("void*", match), 5) end)
        print("[awtech] VM: installed")
        return true
    end

    pcall(function() ok = install() end)

    function VM.set(on, x, y, z)
        if not ok or not page then return end
        w_i32(page, on and 1 or 0)
        w_f32(page + 4, x or 0)
        w_f32(page + 8, y or 0)
        w_f32(page + 12, z or 0)
    end

    function VM.uninstall()
        if not (ok and match and origRel) then return end
        pcall(function()
            local old = ffi.new("uint32_t[1]")
            ffi.C.VirtualProtect(ffi.cast("void*", match), 5, 0x40, old)
            w_i32(match + 1, origRel)
            ffi.C.VirtualProtect(ffi.cast("void*", match), 5, old[0], old)
        end)
    end
end
pcall(function() callbacks.Register("Unload", function() pcall(VM.uninstall) end) end)

local lastVm = nil
local function syncVm()
    local on = cbVm:Get()
    local x, y, z = vmX:Get(), vmY:Get(), vmZ:Get()
    VM.set(on, x, y, z)
    local s = (on and "1" or "0") .. ":" .. x .. ":" .. y .. ":" .. z
    if s ~= lastVm then
        lastVm = s
        C.setOpt("vm_on", on)
        C.setOpt("vm_x", x); C.setOpt("vm_y", y); C.setOpt("vm_z", z)
    end
end

do
    local DLL = "client.dll"

    local I_ADD, I_REMOVE = 3, 5
    local LISTEN_FLAG = 2

    local registry = {}
    local queue    = {}
    local keep     = { names = {} }
    local getNameFn, getIntFn

    local function onFire(_self, ev)
        if ev == nil then return end
        pcall(function()
            local evn = tonumber(ffi.cast("uint64_t", ev))
            if not valid(evn) then return end
            if not getNameFn then
                getNameFn = ffi.cast("const char* (*)(void*)", r_ptr(r_ptr(evn) + 8))
            end
            local np = getNameFn(ev); if np == nil then return end
            local name = ffi.string(np)
            local subs = registry[name]; if not subs then return end
            for i = 1, #subs do
                local sub  = subs[i]
                local f    = sub.fields
                local data = { name = name }
                for j = 1, #f do data[f[j]] = getIntFn(ev, sub.fc[f[j]], -1) end
                queue[#queue + 1] = { sub.handler, data }
            end
        end)
    end

    local function inMod(base, a) return a and a >= base + 0x1000 and a < base + 0x4000000 end

    function EV.install()
        if EV.installed then return true end
        if type(ffi) ~= "table" then return false end
        local base = mem.GetModuleBase(DLL); if not base then return false end
        local mp = mem.FindPattern(DLL, SIG.ev_mgr)
        if not mp or mp == 0 then print("[awtech] event hook: mgr sig not found"); return false end
        local mgrPtr = mp + 20 + ffi.cast("int32_t*", mp + 16)[0]
        local mgr = r_ptr(mgrPtr);          if not valid(mgr) then return false end
        local vt  = r_ptr(mgr);             if not valid(vt)  then return false end
        local addAddr = r_ptr(vt + I_ADD * 8)
        local remAddr = r_ptr(vt + I_REMOVE * 8)
        if not (inMod(base, addAddr) and inMod(base, remAddr)) then
            print("[awtech] event hook: vtable resolve failed (bad offsets?) -- aborted"); return false
        end
        EV._mgr = ffi.cast("void*", mgr)
        EV._add = ffi.cast("char (*)(void*, void*, const char*, char)", addAddr)
        EV._rem = ffi.cast("void (*)(void*, void*)",                    remAddr)
        local gi = mem.FindPattern(DLL, SIG.ev_getint)
        if not gi or gi == 0 then print("[awtech] event hook: getint sig not found"); return false end
        getIntFn = ffi.cast("int (*)(void*, const char*, int)", gi)

        local cb0    = ffi.cast("void* (*)(void*)", function(s) return s end)
        local cbFire = ffi.cast("void (*)(void*, void*)", onFire)
        local cbDbg  = ffi.cast("int (*)(void*)", function() return 42 end)
        local lvt = ffi.new("void*[3]")
        lvt[0] = ffi.cast("void*", cb0); lvt[1] = ffi.cast("void*", cbFire); lvt[2] = ffi.cast("void*", cbDbg)
        local obj = ffi.new("void*[1]"); obj[0] = ffi.cast("void*", lvt)
        keep.cb0, keep.cbFire, keep.cbDbg, keep.lvt, keep.obj = cb0, cbFire, cbDbg, lvt, obj
        EV._listener = ffi.cast("void*", obj)
        EV.installed = true
        for _, cs in pairs(keep.names) do pcall(function() EV._add(EV._mgr, EV._listener, cs, LISTEN_FLAG) end) end
        print("[awtech] event hook installed")
        return true
    end

    function EV.on(name, fields, handler)
        fields = fields or {}
        if not keep.names[name] then keep.names[name] = ffi.new("char[?]", #name + 1, name) end
        local fc = {}
        for i = 1, #fields do fc[fields[i]] = ffi.new("char[?]", #fields[i] + 1, fields[i]) end
        registry[name] = registry[name] or {}
        registry[name][#registry[name] + 1] = { fields = fields, fc = fc, handler = handler }
        if EV.installed and #registry[name] == 1 then
            pcall(function() EV._add(EV._mgr, EV._listener, keep.names[name], LISTEN_FLAG) end)
        end
    end

    function EV.drain()
        local n = #queue; if n == 0 then return end
        local q = queue; queue = {}
        for i = 1, n do pcall(q[i][1], q[i][2]) end
    end

    function EV.uninstall()
        if EV.installed and EV._rem then pcall(function() EV._rem(EV._mgr, EV._listener) end) end
        EV.installed = false
    end
end
pcall(function() callbacks.Register("Unload", function() pcall(EV.uninstall) end) end)

do
    local f = ffi
    local FFF, FNF, FCL, GCD, WINEXEC
    local soundDir = ".\\csgo\\sounds"
    if type(f) == "table" then
        pcall(function() f.cdef [[ void* GetModuleHandleA(const char*); void* GetProcAddress(void*, const char*); ]] end)
        pcall(function() f.cdef [[ typedef struct { uint32_t attr; uint8_t pad[40]; char nm[260]; char alt[14]; } AWSNDFD; ]] end)
        local function P(nm, t)
            local h = f.C.GetModuleHandleA("kernel32.dll"); if h == nil then return nil end
            local p = f.C.GetProcAddress(h, nm); return (p ~= nil) and f.cast(t, p) or nil
        end
        FFF = P("FindFirstFileA",       "void*(*)(const char*, void*)")
        FNF = P("FindNextFileA",        "int(*)(void*, void*)")
        FCL = P("FindClose",            "int(*)(void*)")
        GCD = P("GetCurrentDirectoryA", "uint32_t(*)(uint32_t, char*)")
        WINEXEC = P("WinExec",          "uint32_t(*)(const char*, uint32_t)")
        pcall(function()
            if GCD then
                local eb = f.new("char[?]", 1024)
                local cwd = f.string(eb, GCD(1024, eb))
                soundDir = cwd:gsub("[\\/]bin[\\/]win64.*$", "\\csgo\\sounds")
            end
        end)
    end
    HS.openSoundDir = function()
        if WINEXEC then pcall(function() WINEXEC('explorer.exe "' .. soundDir .. '"', 5) end) end
    end

    local function scanSounds()
        local names = {}
        pcall(function()
            if not (f and FFF and FNF and FCL) then return end
            local INVALID = f.cast("void*", f.cast("intptr_t", -1))
            local fd = f.new("AWSNDFD")
            local h = FFF(soundDir .. "\\*.vsnd_c", fd)
            if h ~= INVALID then
                repeat
                    local nm = f.string(fd.nm)
                    if nm:sub(-7):lower() == ".vsnd_c" then names[#names + 1] = nm:sub(1, #nm - 7) end
                until FNF(h, fd) == 0
                FCL(h)
            end
        end)
        table.sort(names)
        local paths = {}
        for i = 1, #names do paths[i] = names[i] end
        if #names == 0 then names[1] = "[ put .vsnd_c in csgo\\sounds ]" end
        return names, paths
    end
    HS.scan = scanSounds
    SND_NAMES, SND_PATHS = scanSounds()

    local function resolve(cmb)
        return tostring(SND_PATHS[cmb:Get()] or "")
    end

    local function play(path, vol)
        if path == "" then return end
        vol = (tonumber(vol) or 100) / 100
        if vol <= 0 then return end
        pcall(function() client.SetConVar("snd_toolvolume", vol, true) end)
        pcall(function() client.Command("play sounds\\" .. path, true) end)
    end

    function HS.playHit()  play(resolve(hsCmb), hsVol:Get()) end
    function HS.playKill() play(resolve(ksCmb), ksVol:Get()) end

    local bit_ = rawget(_G, "bit")
    local DLL  = "client.dll"
    local off  = {}
    pcall(function()
        local j = http.Get("https://raw.githubusercontent.com/a2x/cs2-dumper/main/output/offsets.json")
        local function pull(name) local v = j and j:match('"' .. name .. '"%s*:%s*(%-?%d+)'); return v and tonumber(v) or nil end
        off.dwEntityList            = pull("dwEntityList")
        off.dwLocalPlayerController = pull("dwLocalPlayerController")
    end)
    pcall(function()
        local j = http.Get("https://raw.githubusercontent.com/a2x/cs2-dumper/main/output/client_dll.json")
        off.m_iszPlayerName = j and tonumber(j:match('"m_iszPlayerName"%s*:%s*(%d+)')) or nil
        off.m_iPing         = j and tonumber(j:match('"m_iPing"%s*:%s*(%d+)')) or nil
    end)

    local band, rshift = (bit_ or {}).band, (bit_ or {}).rshift
    local function slot(elist, idx)
        if not valid(elist) then return nil end
        local chunk = r_ptr(elist + 8 * rshift(idx, 9) + 16); if not valid(chunk) then return nil end
        local e = r_ptr(chunk + 112 * band(idx, 0x1FF))
        if valid(e) and valid(r_ptr(e)) then return e end
        return nil
    end

    local function nameOf(elist, plyslot)
        if not (off.m_iszPlayerName and type(ffi) == "table") then return nil end
        local c = slot(elist, (plyslot or -1) + 1)
        if not valid(c) then return nil end
        local s
        pcall(function() s = ffi.string(ffi.cast("const char*", c + off.m_iszPlayerName)) end)
        if s and #s > 0 and #s < 64 then return s end
        return nil
    end

    local function localCtrlList()
        if not (type(ffi) == "table" and band and off.dwLocalPlayerController and off.dwEntityList) then return nil, nil end
        local base = mem.GetModuleBase(DLL); if not base then return nil, nil end
        local lctrl = r_ptr(base + off.dwLocalPlayerController)
        local elist = r_ptr(base + off.dwEntityList)
        if valid(lctrl) and valid(elist) then return lctrl, elist end
        return nil, nil
    end

    function HS.localInfo()
        local lctrl = localCtrlList()
        if not valid(lctrl) then return nil, nil end
        local nick, ping
        if off.m_iszPlayerName then
            pcall(function()
                local s = ffi.string(ffi.cast("const char*", lctrl + off.m_iszPlayerName))
                if s and #s > 0 and #s < 64 then nick = s end
            end)
        end
        if off.m_iPing then
            pcall(function()
                local p = ffi.cast("int32_t*", lctrl + off.m_iPing)[0]
                if p and p >= 0 and p < 10000 then ping = p end
            end)
        end
        return nick, ping
    end

    function HS.nameBySlot(s)
        local _, elist = localCtrlList()
        if not valid(elist) then return nil end
        return nameOf(elist, s)
    end

    local function evHurt(d)
        if (d.dmg_health or 0) <= 0 then return end
        if type(ffi) == "table" and band and off.dwLocalPlayerController and off.dwEntityList then
            local base = mem.GetModuleBase(DLL)
            if base then
                local lctrl = r_ptr(base + off.dwLocalPlayerController)
                local elist = r_ptr(base + off.dwEntityList)
                if valid(lctrl) and valid(elist) then
                    if slot(elist, (d.attacker or -1) + 1) ~= lctrl then return end
                    if d.userid == d.attacker then return end
                end
            end
        end
        if (d.health or 1) <= 0 then
            if ksOn:Get() then HS.playKill() end
        elseif hsOn:Get() then HS.playHit() end
    end

    function HS.tick()
        if EV.installed then return end
        if EV.install() then EV.on("player_hurt", { "attacker", "userid", "health", "dmg_health" }, evHurt) end
    end

    local lastHs = nil
    function HS.sync()
        local s = table.concat({ hsOn:Get() and 1 or 0, hsCmb:Get(), hsVol:Get(),
                                 ksOn:Get() and 1 or 0, ksCmb:Get(), ksVol:Get() }, ":")
        if s == lastHs then return end
        lastHs = s
        C.setOpt("hs_on2", hsOn:Get()); C.setOpt("hs_snd2", hsCmb:Get()); C.setOpt("hs_vol2", hsVol:Get())
        C.setOpt("ks_on2", ksOn:Get()); C.setOpt("ks_snd2", ksCmb:Get()); C.setOpt("ks_vol2", ksVol:Get())
    end
end

local RG = { ok = false, ids = {}, names = {}, allow = {}, add = 200, enabled = false, installed = false }
do
    local f = ffi
    local CITY = {
        ams = "Amsterdam", atl = "Atlanta", bom = "Mumbai", maa = "Chennai",
        can = "Guangzhou", sha = "Shanghai", tyo = "Tokyo", hkg = "Hong Kong",
        seo = "Seoul", sgp = "Singapore", syd = "Sydney", dxb = "Dubai",
        fra = "Frankfurt", lhr = "London", lux = "Luxembourg", par = "Paris",
        mad = "Madrid", sto = "Stockholm", vie = "Vienna", waw = "Warsaw",
        hel = "Helsinki", iad = "Washington", ord = "Chicago", lax = "Los Angeles",
        sea = "Seattle", dfw = "Dallas", okc = "Oklahoma", gru = "Sao Paulo",
        sao = "Sao Paulo", scl = "Santiago", lim = "Lima", bog = "Bogota",
        eat = "Moscow", sto2 = "Stockholm", jhb = "Johannesburg", pwj = "Tianjin",
        pwg = "Guangzhou", pwz = "Chengdu", tsn = "Tianjin", cpt = "Cape Town",
    }

    local function decode(id)
        local code = ""
        for sh = 24, 0, -8 do
            local c = floor(id / 2 ^ sh) % 256
            if c >= 32 and c < 127 then code = code .. string.char(c) end
        end
        return (code:gsub("%s", ""))
    end

    function RG.label(id)
        local code = decode(id)
        local city = CITY[code:lower()]
        if city then return city .. " (" .. code .. ")" end
        return code ~= "" and code or ("#" .. id)
    end

    if type(f) == "table" then
        local IDX_COUNT, IDX_LIST = 10, 11
        local TARGETS = {
            { rva = 0x13F050, steal = 17 },
            { rva = 0x13EBB0, steal = 15, call = 10 },
        }

        local DLL  = "steamnetworkingsockets.dll"
        local ACCS = { "SteamNetworkingUtils_LibV4", "SteamNetworkingUtils_LibV3", "SteamNetworkingUtils_LibV2" }

        local hmod = f.C.GetModuleHandleA(DLL)
        local base = hmod ~= nil and tonumber(f.cast("uintptr_t", hmod)) or nil

        local utils, vtbl, getCount, getList
        if hmod ~= nil then
            local acc
            for _, nm in ipairs(ACCS) do
                local p = f.C.GetProcAddress(hmod, nm)
                if p ~= nil then acc = p; break end
            end
            if acc ~= nil then
                local ok2, u = pcall(function() return f.cast("void*(*)(void)", acc)() end)
                if ok2 and u ~= nil then utils = u end
            end
            if utils ~= nil then
                vtbl = f.cast("void***", utils)[0]
                if vtbl ~= nil then
                    getCount = f.cast("int(*)(void*)", vtbl[IDX_COUNT])
                    getList  = f.cast("int(*)(void*, uint32_t*, int)", vtbl[IDX_LIST])
                end
            end
        end

        local hooks, keeps = {}, {}

        local function hookFunc(rva, steal, callOff)
            local T  = base + rva
            local b0 = f.cast("uint8_t*", T)
            local p  = alloc_near(T, 64); if p == nil then return nil end
            local TR = tonumber(f.cast("uintptr_t", p))

            local saved = {}
            for i = 0, steal - 1 do saved[i] = b0[i]; w_u8(TR + i, b0[i]) end

            if callOff then
                local relOrig    = r_i32(T + callOff + 1)
                local callTarget = (T + callOff + 5) + relOrig
                local newRel     = callTarget - (TR + callOff + 5)
                if newRel < -2147483648 or newRel > 2147483647 then return nil end
                w_i32(TR + callOff + 1, newRel)
            end

            w_u8(TR + steal, 0xFF); w_u8(TR + steal + 1, 0x25); w_i32(TR + steal + 2, 0)
            le64(TR + steal + 6, T + steal)

            local orig = f.cast("int(*)(void*, uint32_t, uint32_t*)", f.cast("void*", TR))
            local cb = f.cast("int(*)(void*, uint32_t, uint32_t*)", function(self, popid, via)
                local r = orig(self, popid, via)
                if RG.enabled and r >= 0 and next(RG.allow) ~= nil then
                    if RG.allow[tonumber(popid)] then
                        if RG.minimize then return 1 end
                    else
                        return r + RG.add
                    end
                end
                return r
            end)
            keeps[#keeps + 1] = cb

            local old = f.new("uint32_t[1]")
            if f.C.VirtualProtect(f.cast("void*", T), steal, 0x40, old) == 0 then return nil end
            w_u8(T, 0xFF); w_u8(T + 1, 0x25); w_i32(T + 2, 0); le64(T + 6, tonumber(f.cast("uintptr_t", cb)))
            for i = 14, steal - 1 do w_u8(T + i, 0x90) end
            f.C.VirtualProtect(f.cast("void*", T), steal, old[0], old)
            pcall(function() f.C.FlushInstructionCache(f.C.GetCurrentProcess(), f.cast("void*", T), steal) end)

            hooks[#hooks + 1] = { T = T, saved = saved, steal = steal }
            return orig
        end

        local function install()
            if not base then return false end
            local any = false
            for _, t in ipairs(TARGETS) do
                local o = nil
                pcall(function() o = hookFunc(t.rva, t.steal, t.call) end)
                if o then
                    any = true
                    if not RG.ping then RG.ping = o end
                end
            end
            RG.installed = any
            return any
        end

        function RG.uninstall()
            for _, h in ipairs(hooks) do
                pcall(function()
                    local old = f.new("uint32_t[1]")
                    f.C.VirtualProtect(f.cast("void*", h.T), h.steal, 0x40, old)
                    for i = 0, h.steal - 1 do w_u8(h.T + i, h.saved[i]) end
                    f.C.VirtualProtect(f.cast("void*", h.T), h.steal, old[0], old)
                    f.C.FlushInstructionCache(f.C.GetCurrentProcess(), f.cast("void*", h.T), h.steal)
                end)
            end
            RG.installed = false
        end

        local function pingOf(id)
            if not RG.ping then return nil end
            local r
            pcall(function()
                local via = f.new("uint32_t[1]")
                r = RG.ping(nil, id, via)
            end)
            if r and r >= 0 and r < 100000 then return r end
            return nil
        end

        local function enumerate()
            if utils == nil or not getCount or not getList then return end
            local n = getCount(utils)
            if n <= 0 then return end
            if n > 256 then n = 256 end
            local buf = f.new("uint32_t[?]", n)
            local got = getList(utils, buf, n)
            if got < 0 then return end
            if got > n then got = n end
            local all, hasPing = {}, {}
            for i = 0, got - 1 do
                local id    = tonumber(buf[i])
                local known = CITY[decode(id):lower()] ~= nil
                local ping  = pingOf(id)
                local nm    = RG.label(id) .. (ping and ("  " .. ping .. "ms") or "")
                local e = { id = id, name = nm, known = known, ping = ping }
                all[#all + 1] = e
                if ping ~= nil and ping <= 250 then hasPing[#hasPing + 1] = e end
            end
            local use = (#hasPing > 0) and hasPing or all
            table.sort(use, function(a, b)
                if (a.ping ~= nil) ~= (b.ping ~= nil) then return a.ping ~= nil end
                if a.ping and b.ping and a.ping ~= b.ping then return a.ping < b.ping end
                if a.known ~= b.known then return a.known end
                return a.name < b.name
            end)
            local ids, names = {}, {}
            for _, e in ipairs(use) do ids[#ids + 1] = e.id; names[#names + 1] = e.name end
            if #ids > 0 then RG.ids = ids; RG.names = names end
        end
        RG.enumerate = enumerate

        local okI = false
        pcall(function() okI = install() end)
        if utils ~= nil and vtbl ~= nil then pcall(enumerate) end
        RG.ok = okI
        if okI then print("[awtech] region: hooked " .. #hooks .. " fns (" .. #RG.ids .. " pops)")
        else        print("[awtech] region: hook failed") end
    end

    if #RG.names == 0 then RG.names = { "[ join a server, then Refresh ]" } end
end
pcall(function() callbacks.Register("Unload", function() pcall(RG.uninstall) end) end)

local NC = { ok = false, installed = false, enabled = false }
do
    local f = ffi
    local DLL  = "engine2.dll"
    local SIG_SETINFO = "40 55 41 57 48 8D 6C 24 ?? 48 81 EC ?? ?? ?? ?? 45 33 FF"
    local STEAL = 16
    local NAME_OFF, KEY_OFF, VAL_OFF = 0x440, 0x8, 0x10

    local T, orig, keepCb

    function NC.setName(s)
        s = tostring(s or "")
        if #s == 0 then NC._buf = nil; return end
        NC._buf = f.new("char[?]", #s + 1, s)
    end

    local function onSetInfo(rcx, a2)
        if NC.enabled and NC._buf ~= nil and a2 ~= nil then
            pcall(function()
                local a2n = tonumber(f.cast("uintptr_t", a2))
                if a2n and a2n >= 0x1000 then
                    local arg_list = r_ptr(a2n + NAME_OFF)
                    if arg_list and arg_list >= 0x1000 then
                        local key = r_ptr(arg_list + KEY_OFF)
                        if valid(key) then
                            local ks = f.string(f.cast("const char*", key))
                            if ks:lower() == "name" then
                                f.cast("const char**", arg_list + VAL_OFF)[0] = f.cast("const char*", NC._buf)
                            end
                        end
                    end
                end
            end)
        end
        return orig(rcx, a2)
    end

    local function install()
        if type(f) ~= "table" then print("[awtech] namechanger: no ffi"); return false end
        local a = mem.FindPattern(DLL, SIG_SETINFO)
        if not a or a == 0 then print("[awtech] namechanger: sig not found"); return false end
        T = a
        local b0 = f.cast("uint8_t*", T)
        local p = alloc_near(T, 64); if p == nil then print("[awtech] namechanger: alloc failed"); return false end
        local TR = tonumber(f.cast("uintptr_t", p))

        local saved = {}
        for i = 0, STEAL - 1 do saved[i] = b0[i]; w_u8(TR + i, b0[i]) end
        w_u8(TR + STEAL, 0xFF); w_u8(TR + STEAL + 1, 0x25); w_i32(TR + STEAL + 2, 0)
        le64(TR + STEAL + 6, T + STEAL)

        orig = f.cast("char (*)(void*, void*)", f.cast("void*", TR))
        keepCb = f.cast("char (*)(void*, void*)", onSetInfo)

        local old = f.new("uint32_t[1]")
        if f.C.VirtualProtect(f.cast("void*", T), STEAL, 0x40, old) == 0 then
            print("[awtech] namechanger: protect failed"); return false
        end
        w_u8(T, 0xFF); w_u8(T + 1, 0x25); w_i32(T + 2, 0)
        le64(T + 6, tonumber(f.cast("uintptr_t", keepCb)))
        for i = 14, STEAL - 1 do w_u8(T + i, 0x90) end
        f.C.VirtualProtect(f.cast("void*", T), STEAL, old[0], old)
        pcall(function() f.C.FlushInstructionCache(f.C.GetCurrentProcess(), f.cast("void*", T), STEAL) end)

        NC._saved = saved
        NC.installed = true
        return true
    end

    function NC.uninstall()
        if not (NC.installed and T and NC._saved) then return end
        pcall(function()
            local old = f.new("uint32_t[1]")
            f.C.VirtualProtect(f.cast("void*", T), STEAL, 0x40, old)
            for i = 0, STEAL - 1 do w_u8(T + i, NC._saved[i]) end
            f.C.VirtualProtect(f.cast("void*", T), STEAL, old[0], old)
            f.C.FlushInstructionCache(f.C.GetCurrentProcess(), f.cast("void*", T), STEAL)
        end)
        NC.installed = false
    end

    local CVAR_RVA, RESOLVE_RVA = 0x685698, 0x3FC080
    local VT_FIND, FLAGS_OFF    = 0x58, 0x30
    local F_USERINFO, F_PROTECTED = 0x200, 0x2
    local bit_ = rawget(_G, "bit")

    function NC.fixFlags()
        if type(f) ~= "table" or not bit_ then return false end
        if NC._flags then
            local p = f.cast("uint32_t*", NC._flags)
            p[0] = bit_.band(bit_.bor(p[0], F_USERINFO), bit_.bnot(F_PROTECTED))
            return true
        end
        local base = mem.GetModuleBase(DLL); if not base then return false end
        local cvar = r_ptr(base + CVAR_RVA);  if not valid(cvar) then return false end
        local vt   = r_ptr(cvar);             if not valid(vt)   then return false end
        local findAddr = r_ptr(vt + VT_FIND); if not valid(findAddr) then return false end
        local findfn  = f.cast("uint64_t (*)(void*, void*, const char*, int)", findAddr)
        local resolve = f.cast("void* (*)(void*, uint32_t, int16_t)", base + RESOLVE_RVA)
        local nameC   = f.new("char[5]", "name")
        local outbuf  = f.new("uint8_t[64]")
        local res     = f.new("uint64_t[4]")
        local done = false
        pcall(function()
            local ref = tonumber(findfn(f.cast("void*", cvar), outbuf, nameC, 1))
            if not ref or ref < 0x10000 then return end
            local handle = f.cast("uint32_t*", ref)[0]
            resolve(res, handle, -1)
            local obj = tonumber(res[1])
            if not valid(obj) then return end
            NC._flags = obj + FLAGS_OFF
            local p = f.cast("uint32_t*", NC._flags)
            p[0] = bit_.band(bit_.bor(p[0], F_USERINFO), bit_.bnot(F_PROTECTED))
            done = true
        end)
        return done
    end

    function NC.steamName()
        if type(f) ~= "table" then return nil end
        if NC._steam then return NC._steam end
        local h = f.C.GetModuleHandleA("steam_api64.dll"); if h == nil then return nil end
        local getName = f.C.GetProcAddress(h, "SteamAPI_ISteamFriends_GetPersonaName")
        if getName == nil then return nil end
        local accFn
        for _, v in ipairs({ "SteamAPI_SteamFriends_v017", "SteamAPI_SteamFriends_v018",
                             "SteamAPI_SteamFriends_v019", "SteamAPI_SteamFriends_v016",
                             "SteamAPI_SteamFriends_v020" }) do
            local p = f.C.GetProcAddress(h, v)
            if p ~= nil then accFn = p; break end
        end
        if accFn == nil then return nil end
        local res
        pcall(function()
            local iface = f.cast("void* (*)(void)", accFn)()
            if iface == nil then return end
            local s = f.cast("const char* (*)(void*)", getName)(iface)
            if s ~= nil then
                local str = f.string(s)
                if #str > 0 and #str < 64 then res = str end
            end
        end)
        if res then NC._steam = res end
        return res
    end

    function NC.origName()
        return NC.steamName() or NC._captured
    end

    local okI = false
    pcall(function() okI = install() end)
    NC.ok = okI
    if okI then print("[awtech] namechanger: hooked SetInfo @ " .. string.format("%X", T))
    else        print("[awtech] namechanger: install failed") end
end
pcall(function() callbacks.Register("Unload", function() pcall(NC.uninstall) end) end)

local VR = { q = {} }
do
    local G, R, W, P = string.char(4), string.char(2), string.char(1), string.char(14)
    local function pfx() return "[" .. P .. "awtech" .. W .. "] " end

    local function startMsg(initiator, target)
        return pfx() .. initiator .. " started a vote to kick " .. target,
               initiator .. " wants to kick " .. target
    end
    local function castMsg(name, yes)
        local yn = yes and (G .. "yes" .. W) or (R .. "no" .. W)
        return pfx() .. name .. " voted " .. yn,
               name .. " voted " .. (yes and "yes" or "no")
    end

    local function push(chat, note, kind) VR.q[#VR.q + 1] = { chat = chat, note = note, kind = kind } end

    local function pname(slot)
        if not slot or slot < 0 then return "player" end
        local n = HS.nameBySlot(slot)
        if type(n) == "string" and #n > 0 and #n < 64 then return n end
        return "player"
    end

    function VR.flush()
        local total = #VR.q; if total == 0 then return end
        local q = VR.q; VR.q = {}
        local mode = (VR._mode and VR._mode()) or 3
        for i = 1, total do
            local it = q[i]
            if mode == 2 or mode == 3 then pcall(function() M:Notify(it.note, it.kind) end) end
        end
    end

    function VR.test()
        local c, d = castMsg("player", true);  push(c, d, "success")
        local e, g = castMsg("player", false); push(e, g, "error")
    end

    function VR.onEvent(ev)
        if not (VR._on and VR._on()) then return end
        local name
        pcall(function() name = ev:GetName() end)
        if name == "vote_cast" then
            local opt
            pcall(function() opt = ev:GetInt("vote_option") end)
            if opt == nil or opt < 0 then return end
            local voter
            pcall(function() voter = ev:GetInt("userid") end)
            local yes = (opt == 0)
            local c, n = castMsg(pname(voter), yes)
            push(c, n, yes and "success" or "error")
        elseif name == "vote_started" or name == "vote_begin" then
            local initiator
            pcall(function() initiator = ev:GetInt("entityid") end)
            if not initiator or initiator <= 0 then pcall(function() initiator = ev:GetInt("userid") end) end
            local tid
            pcall(function()
                local disp = ev:GetString("disp_str")
                if type(disp) == "string" then
                    local m = disp:match(":(%d+):")
                    if m then tid = tonumber(m) end
                end
            end)
            local c, n = startMsg(pname(initiator), tid and pname(tid) or "player")
            push(c, n, "info")
        end
    end

    function VR.init()
        for _, e in ipairs({ "vote_started", "vote_begin", "vote_cast" }) do
            pcall(function() client.AllowListener(e) end)
        end
        callbacks.Register("FireGameEvent", "AwTech_VR", function(ev)
            pcall(VR.onEvent, ev)
        end)
        print("[awtech] vote revealer: events registered")
    end
end

local ncClock = (function()
    for _, fn in ipairs({ function() return globals.RealTime() end,
                          function() return globals.CurTime() end,
                          function() return os.clock() end }) do
        local ok, v = pcall(fn)
        if ok and type(v) == "number" then return fn end
    end
    return function() return 0 end
end)()

local NC_LEET = {
    a = { "@", "4" }, b = { "6", "8" }, c = { "<" },
    e = { "3" },      f = { "ph" },     g = { "9", "6" }, h = { "#" },
    i = { "1", "!" },     l = { "1" },
    m = { "|\\/|" },  n = { "|\\|" },   o = { "0" },
    r = { "|2" },     s = { "$" }, t = { "7" },
    v = { "\\/" },    z = { "2" },
}

local function ncGlitch(target)
    local function corrupt()
        local chars = {}
        for i = 1, #target do
            local c = target:sub(i, i)
            local alt = NC_LEET[c:lower()]
            if i > 1 and i < #target and alt and math.random() < 0.4 then
                c = alt[math.random(#alt)]
            end
            chars[i] = c
        end
        return table.concat(chars)
    end
    local seq = {}
    local function burst(n)
        for _ = 1, n do seq[#seq + 1] = { t = corrupt(), ms = 55 } end
    end
    burst(6)
    seq[#seq + 1] = { t = target, ms = 2000 }
    burst(6)
    seq[#seq + 1] = { t = target, ms = 2000 }
    return seq
end

local NC_FEM = {
    { t = "",          ms = 550 },
    { t = "$F",         ms = 55 },  { t = "$f",         ms = 85 },
    { t = "$f3",        ms = 55 },  { t = "$fe",        ms = 85 },
    { t = "$fe|\\/|",   ms = 55 },  { t = "$fem",       ms = 85 },
    { t = "$fem6",      ms = 55 },  { t = "$femb",      ms = 85 },
    { t = "$femb0",     ms = 55 },  { t = "$fembo",     ms = 85 },
    { t = "$femboY",    ms = 55 },  { t = "$femboy",    ms = 85 },
    { t = "$femboyT",   ms = 55 },  { t = "$femboyt",   ms = 85 },
    { t = "$femboyt@",  ms = 55 },  { t = "$femboyta",  ms = 85 },
    { t = "$femboytaP", ms = 55 },  { t = "$femboytap", ms = 90 },
    { t = "$femboytap",  ms = 70 }, { t = "$femboytap$", ms = 2000 },
    { t = "$femboytap",  ms = 70 }, { t = "$femboytap",   ms = 70 },
    { t = "$femboyta",  ms = 60 },  { t = "$femboyt",   ms = 60 },
    { t = "$femboy",    ms = 60 },  { t = "$fembo",     ms = 60 },
    { t = "$femb",      ms = 60 },  { t = "$fe",        ms = 60 },
    { t = "$f",         ms = 60 },
}

local NC_AIM = {
    { t = "",            ms = 450 },
    { t = "[A]",           ms = 120 },  { t = "[AI]",          ms = 120 },
    { t = "[AIM]",         ms = 120 },  { t = "[AIMW]",        ms = 120 },
    { t = "[AIMWA]",       ms = 120 },  { t = "[AIMWAR]",      ms = 120 },
    { t = "[AIMWARE]",     ms = 110 }, { t = "[AIMWARE.]",    ms = 120 },
    { t = "[AIMWARE.N]",   ms = 90 },  { t = "[AIMWARE.NE]",  ms = 120 },
    { t = "[AIMWARE.NET]", ms = 2000 },
    { t = "[AIMWARE.NE]",  ms = 120 },  { t = "[AIMWARE.N]",   ms = 120 },
    { t = "[AIMWARE.]",    ms = 120 },  { t = "[AIMWARE]",     ms = 120 },
    { t = "[AIMWAR]",      ms = 120 },  { t = "[AIMWA]",       ms = 120 },
    { t = "[AIMW]",        ms = 120 },  { t = "[AIM]",         ms = 120 },
    { t = "[AI]",          ms = 120 },  { t = "[A]",           ms = 120 },
}

local NC_FEM_G = ncGlitch("$femboytap$")
local NC_AIM_G = ncGlitch("[AIMWARE.NET]")

local function ncParse(str, defMs)
    local frames = {}
    for tok in (str .. ","):gmatch("([^,]*),") do
        if tok ~= "" then
            local t, ms = tok:match("^(.-):(%d+)$")
            if t then frames[#frames + 1] = { t = t, ms = tonumber(ms) }
            else      frames[#frames + 1] = { t = tok, ms = defMs } end
        end
    end
    return frames
end

local function ncFrameAt(seq, t, factor)
    factor = factor or 1
    local n = #seq; if n == 0 then return "" end
    local total = 0
    for i = 1, n do total = total + seq[i].ms * factor end
    if total <= 0 then return seq[1].t end
    local ms  = (t * 1000) % total
    local acc = 0
    for i = 1, n do
        acc = acc + seq[i].ms * factor
        if ms < acc then return seq[i].t end
    end
    return seq[n].t
end

local function ncValue(t)
    local src = ncSrc and ncSrc:Get() or 1
    local glitch = ncStyle and ncStyle:Get() == 2
    local s
    if src == 2 then
        s = ncFrameAt(glitch and NC_FEM_G or NC_FEM, t, (ncSpeed:Get() or 400) / 400)
    elseif src == 3 then
        s = ncFrameAt(glitch and NC_AIM_G or NC_AIM, t, (ncSpeed:Get() or 400) / 400)
    elseif src == 4 then
        s = ncFrameAt(ncParse(ncText:Get(), floor(ncSpeed:Get() or 400)), t, 1)
    else
        s = ncText:Get()
    end
    s = s or ""
    if ncMode and ncMode:Get() == 2 then
        local rn = NC.origName()
        if rn and rn ~= "" then s = (s == "") and rn or (s .. " " .. rn) end
    end
    return s
end

local function ncApply(val, raw)
    if not val or val == "" then return end
    pcall(NC.fixFlags)
    NC.setName(val)
    if raw then
        pcall(function() client.Command("setinfo name x", true) end)
    else
        pcall(function() client.Command('setinfo name "' .. val:gsub('"', '') .. '"', true) end)
    end
end

local tab = M:Tab("Skins")

tab:Row()
weaponLb = tab:Section("Weapons"):Listbox("", C.names, "fill", 1)

tab:Col()
local sSec = tab:Section("Skins")
skinLb = sSec:Listbox("", { "[ select a weapon ]" }, "fill", 1)
skinWd = sSec.ws[#sSec.ws]

tab:Col()
local setSec = tab:Section("Settings")
sWear  = setSec:Slider("Wear / Float", 0.0001, 0.0, 1.0, 0.001, "%.3f")
sSeed  = setSec:Slider("Seed", 0, 0, 1000, 1)
cbAuto = setSec:Checkbox("Auto select weapon", false)

local actSec = tab:Section("Actions")
actSec:Button("Remove",    function() C.remove(item()) end)
actSec:Button("Reset All", function() C.resetAll() end)
actSec:Button("Randomize All", function()
    math.randomseed(os and os.time and os.time() or tonumber(tostring({}):sub(8)))
    local kItems, gItems, wItems = {}, {}, {}
    for i = 1, #C.items do
        local it = C.items[i]
        if it.kind == "knife" then kItems[#kItems+1] = it
        elseif it.kind == "glove" and it.def ~= 0 then gItems[#gItems+1] = it
        elseif it.kind == "weapon" then wItems[#wItems+1] = it end
    end
    for i = 1, #wItems do
        local it = wItems[i]
        local _, paints = C.skinList(it.def)
        if #paints > 1 then C.apply(it, paints[math.random(2, #paints)], math.random() * 0.7, math.random(0, 1000)) end
    end
    if #kItems > 0 then
        local it = kItems[math.random(1, #kItems)]
        local _, paints = C.skinList(it.def)
        if #paints > 1 then C.apply(it, paints[math.random(2, #paints)], math.random() * 0.7, math.random(0, 1000)) end
    end
    if #gItems > 0 then
        local it = gItems[math.random(1, #gItems)]
        local _, paints = C.skinList(it.def)
        if #paints > 1 then C.apply(it, paints[math.random(2, #paints)], math.random() * 0.7, math.random(0, 1000)) end
    end
    C.forceUpdate(); lastSel = -2; lastModelSel = -2
    print("[awtech] All skins randomized!")
end)

local cfgSec = tab:Section("Config")
cfgSec:Button("Save config", function()
    C.setOpt("_saved", 1)
    print("[awtech] Config saved to awtech_config.txt")
end)
cfgSec:Button("Reload config", function()
    if C.loadConfig() then lastSel = -2; lastModelSel = -2; print("[awtech] Config reloaded") else print("[awtech] No saved config found") end
end)
cfgSec:Button("Reset config", function() C.clearConfig() end)

local vtab = M:Tab("Visuals")

local submodels = vtab:Sub("Models")
submodels:Row()
local vSec = submodels:Section("List")
local mNames
mNames, modelPaths = C.modelList()
modelLb = vSec:Listbox("", mNames, "fill", 1)
modelWd = vSec.ws[#vSec.ws]
submodels:Col()
local vSsec = submodels:Section("Settings")
vSsec:Button("Refresh models", function()
    local cur = C.getLocalModel()
    local n, p = C.refreshModels()
    modelPaths     = p
    modelWd.items  = n
    modelWd.value  = 1
    modelWd.scroll = 0
    if cur then
        for i = 2, #p do if p[i] == cur then modelWd.value = i; break end end
    end
    lastModelSel = modelWd.value
end)

local sublocal = vtab:Sub("Local")
sublocal:Row()
local localSection = sublocal:Section("Local player")
cbVm = localSection:Checkbox("Viewmodel override", false)
vmX  = localSection:Slider("Offset X", 0, -30, 30, 0.1, "%.1f")
vmY  = localSection:Slider("Offset Y", 0, -30, 30, 0.1, "%.1f")
vmZ  = localSection:Slider("Offset Z", 0, -30, 30, 0.1, "%.1f")

local stab = M:Tab("Sounds")
stab:Row()
local hsSec = stab:Section("Hit sound")
hsOn    = hsSec:Checkbox("Enabled", true)
hsCmb   = hsSec:Combo("Sound", SND_NAMES, 1)
hsCmbWd = hsSec.ws[#hsSec.ws]
hsVol   = hsSec:Slider("Volume", 100, 0, 100, 1, "%.0f")

stab:Col()
local ksSec = stab:Section("Kill sound")
ksOn    = ksSec:Checkbox("Enabled", false)
ksCmb   = ksSec:Combo("Sound", SND_NAMES, 1)
ksCmbWd = ksSec.ws[#ksSec.ws]
ksVol   = ksSec:Slider("Volume", 100, 0, 100, 1, "%.0f")

stab:Col()
local tSec = stab:Section("Preview")
tSec:Button("Play hit",  function() HS.playHit() end)
tSec:Button("Play kill", function() HS.playKill() end)
tSec:Button("Rescan", function()
    local n, p = HS.scan()
    SND_PATHS = p
    hsCmbWd.options = n; hsCmbWd.value = 1
    ksCmbWd.options = n; ksCmbWd.value = 1
end)
tSec:Button("Open folder", function() HS.openSoundDir() end)

local ntab = M:Tab("Misc")
ntab:Row()
local rgSec = ntab:Section("Matchmaking region")
rgOn    = rgSec:Checkbox("Enabled", false)
rgCmb   = rgSec:MultiCombo("Allowed regions", RG.names, {})
rgCmbWd = rgSec.ws[#rgSec.ws]
rgPen   = rgSec:Slider("Ping penalty", 200, 50, 250, 1, "%.0f")
rgMin   = rgSec:Checkbox("Minimize selected ping", true)
rgSec:Button("Refresh regions", function()
    if not RG.enumerate then return end
    local selIds = {}
    local sel = rgCmb:Get()
    for i, id in ipairs(RG.ids) do if sel[i] then selIds[id] = true end end
    RG.enumerate()
    local nv = {}
    for i, id in ipairs(RG.ids) do if selIds[id] then nv[i] = true end end
    rgCmbWd.options = RG.names
    rgCmbWd.value   = nv
end)

ntab:Col()
local ncSec = ntab:Section("Name changer")
ncOn     = ncSec:Checkbox("Enabled", false)
ncMode   = ncSec:Combo("Mode", { "Full name", "Clantag" }, 1)
ncSrc    = ncSec:Combo("Source", { "Static", "Femboytap", "Aimware", "Custom" }, 1)
ncStyle  = ncSec:Combo("Style", { "Typing", "Glitch" }, 1)
ncText   = ncSec:Input("Text / frames", "", "name / a:80,ai:80,aim:200")
ncSpeed  = ncSec:Slider("Frame ms", 400, 100, 1000, 10, "%.0f")
ncSec:Button("Apply once", function() ncApply(ncValue(ncClock()), false) end)

ntab:Col()
local vrSec = ntab:Section("Vote revealer")
vrOn   = vrSec:Checkbox("Enabled", false)
vrMode = vrSec:Combo("Mode", { "Chat", "Notification", "Both" }, 3)
vrSec:Button("Test", function() VR.test() end)

VR._on   = function() return vrOn:Get() end
VR._mode = function() return vrMode:Get() end

local lastRg
local function rgSync()
    if not RG.ok then return end
    RG.enabled  = rgOn:Get()
    RG.add      = rgPen:Get()
    RG.minimize = rgMin:Get()
    local sel = rgCmb:Get()
    local allow = {}
    for i, id in ipairs(RG.ids) do if sel[i] then allow[id] = true end end
    RG.allow = allow
    local key = table.concat({ RG.enabled and 1 or 0, RG.add, RG.minimize and 1 or 0, #RG.allow })
    if key == lastRg then return end
    lastRg = key
    C.setOpt("rg_on", RG.enabled); C.setOpt("rg_add", RG.add); C.setOpt("rg_min", RG.minimize)
    for i, id in ipairs(RG.ids) do C.setOpt("rg_" .. id, sel[i] and true or false) end
end

local lastNc
local function ncSync()
    if not NC.ok then return end
    NC.enabled = ncOn:Get()
    local key = table.concat({ ncOn:Get(), ncMode:Get(), ncSrc:Get(), ncStyle:Get(), ncText:Get(), ncSpeed:Get() }, ":")
    if key ~= lastNc then
        lastNc = key
        C.setOpt("nc_on", ncOn:Get()); C.setOpt("nc_mode", ncMode:Get()); C.setOpt("nc_src", ncSrc:Get())
        C.setOpt("nc_style", ncStyle:Get()); C.setOpt("nc_text", ncText:Get()); C.setOpt("nc_speed", ncSpeed:Get())
    end
    if NC.enabled then
        ncApply(ncValue(ncClock()), false)
    end
end

local hltab = M:Tab("Hitlogs")
hltab:Row()
local hlSet = hltab:Section("Hitlog")
local hlOn  = hlSet:Checkbox("Enabled", true)
local hlY   = hlSet:Slider("Offset Y", 120, -400, 400, 1, "%.0f")
local hlX   = hlSet:Slider("Offset X", 0, -600, 600, 1, "%.0f")

hltab:Col()
local hlTest = hltab:Section("Test")
hlTest:Button("Miss", function() M:Hitlog("miss") end)
hlTest:Button("Hit",  function() M:Hitlog("hit",  math.random(8, 60)) end)
hlTest:Button("Hurt", function() M:Hitlog("hurt", math.random(8, 60)) end)
hlTest:Button("Kill", function() M:Hitlog("kill") end)

hltab:Col()
local hlCol = hltab:Section("Colors")
local cMiss = hlCol:ColorPicker("Miss", { 235, 90, 90 })
local cHit  = hlCol:ColorPicker("Hit",  { 139, 124, 246 })
local cHurt = hlCol:ColorPicker("Hurt", { 245, 170, 70 })
local cKill = hlCol:ColorPicker("Kill", { 80, 200, 120 })

local function hlSync()
    M:HitlogSet({
        enabled = hlOn:Get(),
        x_off   = hlX:Get(),
        y_off   = hlY:Get(),
        colors  = { miss = cMiss:Get(), hit = cHit:Get(), hurt = cHurt:Get(), kill = cKill:Get() },
    })
end

if C.loadConfig() then lastSel = -2 end
cbAuto:Set(C.getOpt("autoFollow") and true or false)
lastAuto = cbAuto:Get()

cbVm:Set(C.getOpt("vm_on") and true or false)
vmX:Set(tonumber(C.getOpt("vm_x")) or 0)
vmY:Set(tonumber(C.getOpt("vm_y")) or 0)
vmZ:Set(tonumber(C.getOpt("vm_z")) or 0)

do
    local cur = C.getLocalModel()
    if cur and modelPaths then
        for i = 2, #modelPaths do
            if modelPaths[i] == cur then modelLb:Set(i); break end
        end
    end
    lastModelSel = modelLb:Get()
end

local function getBool(k, d)
    local v = C.getOpt(k); if v == nil then return d end
    return v and true or false
end
hsOn:Set(getBool("hs_on2", true))
ksOn:Set(getBool("ks_on2", false))
local function setCmb(cmb, k)
    local i = tonumber(C.getOpt(k))
    if i and i >= 1 and i <= #SND_NAMES then cmb:Set(i) end
end
setCmb(hsCmb, "hs_snd2")
setCmb(ksCmb, "ks_snd2")
hsVol:Set(tonumber(C.getOpt("hs_vol2")) or 100)
ksVol:Set(tonumber(C.getOpt("ks_vol2")) or 100)

if RG.ok then
    rgOn:Set(getBool("rg_on", false))
    rgPen:Set(tonumber(C.getOpt("rg_add")) or 200)
    rgMin:Set(getBool("rg_min", true))
    local sel = {}
    for i, id in ipairs(RG.ids) do
        local v = C.getOpt("rg_" .. id)
        if v == nil then v = false end
        sel[i] = v
    end
    rgCmb:Set(sel)
end

if NC.ok then
    ncOn:Set(getBool("nc_on", false))
    ncMode:Set(tonumber(C.getOpt("nc_mode")) or 1)
    ncSrc:Set(tonumber(C.getOpt("nc_src")) or 1)
    ncStyle:Set(tonumber(C.getOpt("nc_style")) or 1)
    local savedText = C.getOpt("nc_text")
    if savedText then ncText:Set(savedText) end
    ncSpeed:Set(tonumber(C.getOpt("nc_speed")) or 400)
end

pcall(VR.init)

M:OnFrame(function()
    pcall(autoFollow)
    pcall(syncSkins)
    pcall(autoApply)
    pcall(persistOpts)
    pcall(syncModel)
    pcall(syncVm)
    pcall(EV.drain)
    pcall(HS.tick)
    pcall(HS.sync)
    pcall(hlSync)
    pcall(rgSync)
    pcall(ncSync)
    pcall(VR.flush)
end)

checkSigs()
print("[awtech] Sig health: " .. (SIG_MONITOR.resolved and "checked" or "pending"))

-- periodic signature health monitor in OnFrame
M:OnFrame(function()
    pcall(sigTick)
end)

M:Build({ w = 720, h = 500 })
