local ffi  = ffi
local band, rshift, bxor, lshift = bit.band, bit.rshift, bit.bxor, bit.lshift
local floor = math.floor

local off = {}

local DUMPER = "https://raw.githubusercontent.com/a2x/cs2-dumper/main/output/"
local OFFSETS = {
    "dwLocalPlayerPawn", "dwLocalPlayerController", "dwEntityList",
    "dwNetworkGameClient", "dwNetworkGameClient_signOnState",
}

local FIELDS = {
    m_pWeaponServices      = "m_pWeaponServices",
    m_hMyWeapons           = "m_hMyWeapons",
    m_hActiveWeapon        = "m_hActiveWeapon",
    m_AttributeManager     = { "m_AttributeManager", "C_EconEntity" },
    m_Item                 = "m_Item",
    m_pGameSceneNode       = "m_pGameSceneNode",
    m_modelState           = { "m_modelState", "CSkeletonInstance" },
    m_hModel               = { "m_hModel", "CModelState" },
    m_nSubclassID          = "m_nSubclassID",
    m_iTeamNum             = "m_iTeamNum",
    m_iHealth              = "m_iHealth",
    m_lifeState            = "m_lifeState",
    m_hOwnerEntity         = "m_hOwnerEntity",
    m_hPlayerPawn          = "m_hPlayerPawn",
    m_steamID              = "m_steamID",
    m_iItemDefinitionIndex = "m_iItemDefinitionIndex",
    m_bRestoreCustomMat    = "m_bRestoreCustomMaterialAfterPrecache",
    m_iEntityQuality       = "m_iEntityQuality",
    m_iItemIDLow           = "m_iItemIDLow",
    m_iItemIDHigh          = "m_iItemIDHigh",
    m_iAccountID           = "m_iAccountID",
    m_OriginalOwnerXuidLow = { "m_OriginalOwnerXuidLow", "C_EconEntity" },
    m_bInitialized         = "m_bInitialized",
    m_bDisallowSOC         = "m_bDisallowSOC",
    m_AttributeList        = "m_AttributeList",
    m_Attributes           = "m_Attributes",
    m_nFallbackPaintKit    = { "m_nFallbackPaintKit", "C_EconEntity" },
    m_nFallbackSeed        = { "m_nFallbackSeed", "C_EconEntity" },
    m_flFallbackWear       = { "m_flFallbackWear", "C_EconEntity" },
    m_nFallbackStatTrak    = { "m_nFallbackStatTrak", "C_EconEntity" },
    m_EconGloves           = { "m_EconGloves", "C_CSPlayerPawn" },
    m_bNeedToReApplyGloves = { "m_bNeedToReApplyGloves", "C_CSPlayerPawn" },
    m_hViewModel           = { "m_hViewModel", "C_CSPlayerPawn" },
}

local function pull_offset(j, name, after)
    local init = 1
    if after then local p = j:find('"' .. after .. '"%s*:%s*{'); if p then init = p end end
    local v = j:match('"' .. name .. '"%s*:%s*(%d+)', init)
    return v and tonumber(v) or nil
end
pcall(function()
    local j = http.Get(DUMPER .. "offsets.json")
    if type(j) ~= "string" then return end
    for _, k in ipairs(OFFSETS) do local v = pull_offset(j, k); if v then off[k] = v end end
end)
pcall(function()
    local j = http.Get(DUMPER .. "client_dll.json")
    if type(j) ~= "string" then return end
    for key, spec in pairs(FIELDS) do
        local name, after = spec, nil
        if type(spec) == "table" then name, after = spec[1], spec[2] end
        local v = pull_offset(j, name, after)
        if v then off[key] = v end
    end
end)
off.m_szWorldModel = 48
off.m_modelState = off.m_modelState or 336
off.m_hModel     = off.m_hModel     or 160
if not off.dwLocalPlayerPawn or not off.m_hMyWeapons then
    print("[awtech-changer] WARNING: offsets not pulled from dumper (network?) -- changer inactive")
end

local function r_u8 (a) return ffi.cast("uint8_t*",  a)[0] end
local function r_u16(a) return ffi.cast("uint16_t*", a)[0] end
local function r_i32(a) return ffi.cast("int32_t*",  a)[0] end
local function r_u32(a) return ffi.cast("uint32_t*", a)[0] end
local function r_u64(a) return ffi.cast("uint64_t*", a)[0] end
local function r_ptr(a) return tonumber(ffi.cast("uint64_t*", a)[0]) end
local function w_u8 (a,v) ffi.cast("uint8_t*",  a)[0]=v end
local function w_u16(a,v) ffi.cast("uint16_t*", a)[0]=v end
local function w_i32(a,v) ffi.cast("int32_t*",  a)[0]=v end
local function w_u32(a,v) ffi.cast("uint32_t*", a)[0]=v end
local function w_u64(a,v) ffi.cast("uint64_t*", a)[0]=v end
local function w_f32(a,v) ffi.cast("float*",    a)[0]=v end
local function valid(p) return p ~= nil and p > 0x10000 and p < 0x7FFFFFFFFFFF end
local function read_cstr(a, max)
    if not valid(a) then return "" end
    local t = {}
    for i = 0, (max or 160) - 1 do
        local c = r_u8(a + i); if c == 0 then break end
        t[#t+1] = string.char(c)
    end
    return table.concat(t)
end

local function tou32(x) x = x % 0x100000000; if x < 0 then x = x + 0x100000000 end; return x end
local function mul32(a, b)
    a = a % 0x100000000; b = b % 0x100000000
    local ah, al = floor(a/0x10000), a%0x10000
    local bh = floor(b/0x10000)
    return (al*(b%0x10000) + ((al*bh + ah*(b%0x10000)) % 0x10000)*0x10000) % 0x100000000
end
local MM = 0x5bd1e995
local function murmur2(str, seed)
    local len = #str
    local h = tou32(bxor(seed, len))
    local i, rem = 1, len
    while rem >= 4 do
        local b0,b1,b2,b3 = str:byte(i, i+3)
        local k = b0 + b1*256 + b2*65536 + b3*16777216
        k = mul32(k, MM); k = tou32(bxor(k, rshift(k, 24))); k = mul32(k, MM)
        h = mul32(h, MM); h = tou32(bxor(h, k))
        i = i + 4; rem = rem - 4
    end
    if rem >= 3 then h = tou32(bxor(h, lshift(str:byte(i+2), 16))) end
    if rem >= 2 then h = tou32(bxor(h, lshift(str:byte(i+1), 8))) end
    if rem >= 1 then h = tou32(bxor(h, str:byte(i))); h = mul32(h, MM) end
    h = tou32(bxor(h, rshift(h, 13))); h = mul32(h, MM); h = tou32(bxor(h, rshift(h, 15)))
    return h
end
local function subclass_hash(def) return murmur2(tostring(def):lower(), 0x31415926) end

local DLL = "client.dll"
local sig = {
    set_model       = "40 53 48 83 EC ?? 48 8B D9 4C 8B C2 48 8B 0D ?? ?? ?? ?? 48 8D 54 24 40",
    update_subclass = "4C 8B DC 53 48 81 EC ?? ?? ?? ?? 48 8B 41",
    set_mesh_mask   = "48 89 5C 24 ?? 48 89 74 24 ?? 57 48 83 EC ?? 48 8D 99 ?? ?? ?? ?? 48 8B 71",
    regen_skins     = "48 83 EC ?? E8 ?? ?? ?? ?? 48 85 C0 0F 84 ?? ?? ?? ?? 48 8B 10",
}
local SBG_SIG = "E8 ?? ?? ?? ?? EB 0C 48 8B CF"

local SIG_FALLBACKS = {
    set_model = {
        "40 53 48 83 EC ?? 48 8B D9 4C 8B C2 48 8B 0D ?? ?? ?? ?? 48 8D 54 24 40",
        "48 89 5C 24 ?? 48 89 6C 24 ?? 48 89 74 24 ?? 57 48 83 EC ?? 48 8B D9 4C 8B C2 48 8B 0D",
    },
    update_subclass = {
        "4C 8B DC 53 48 81 EC ?? ?? ?? ?? 48 8B 41",
        "48 89 5C 24 ?? 48 89 74 24 ?? 57 48 83 EC ?? 48 8B 41",
    },
    set_mesh_mask = {
        "48 89 5C 24 ?? 48 89 74 24 ?? 57 48 83 EC ?? 48 8D 99 ?? ?? ?? ?? 48 8B 71",
        "40 53 48 83 EC ?? 48 8B D9 48 8B 0D",
    },
    regen_skins = {
        "48 83 EC ?? E8 ?? ?? ?? ?? 48 85 C0 0F 84 ?? ?? ?? ?? 48 8B 10",
        "E8 ?? ?? ?? ?? 48 85 C0 0F 84 ?? ?? ?? ?? 48 8B 10",
    },
}

local fn, fnptr = {}, {}
local function resolve()
    for name, pattern in pairs(sig) do
        if not fn[name] then
            local a = mem.FindPattern(DLL, pattern)
            if not a or a == 0 then
                local fallbacks = SIG_FALLBACKS[name]
                if fallbacks then
                    for _, alt in ipairs(fallbacks) do
                        a = mem.FindPattern(DLL, alt)
                        if a and a ~= 0 then break end
                    end
                end
            end
            if a and a ~= 0 then fn[name] = a end
        end
    end
    if not fn.set_body_group then
        local a = mem.FindPattern(DLL, SBG_SIG)
        if a and a ~= 0 then fn.set_body_group = a + 5 + r_i32(a + 1) end
    end
    if fn.set_model       and not fnptr.set_model       then fnptr.set_model       = ffi.cast("void(*)(void*, const char*)", fn.set_model) end
    if fn.update_subclass and not fnptr.update_subclass then fnptr.update_subclass = ffi.cast("void(*)(void*)",              fn.update_subclass) end
    if fn.set_mesh_mask   and not fnptr.set_mesh_mask   then fnptr.set_mesh_mask   = ffi.cast("void(*)(void*, uint64_t)",    fn.set_mesh_mask) end
    if fn.regen_skins     and not fnptr.regen_skins     then fnptr.regen_skins     = ffi.cast("void(*)(void)",               fn.regen_skins) end
    if fn.set_body_group  and not fnptr.set_body_group  then fnptr.set_body_group  = ffi.cast("void(*)(void*, const char*, unsigned int)", fn.set_body_group) end
end

local function resolve_sig(name, pattern)
    local a = mem.FindPattern(DLL, pattern)
    if a and a ~= 0 then return a end
    local fallbacks = SIG_FALLBACKS[name]
    if fallbacks then
        for _, alt in ipairs(fallbacks) do
            a = mem.FindPattern(DLL, alt)
            if a and a ~= 0 then return a end
        end
    end
    return nil
end

local function vfunc(this, index)
    if not valid(this) then return nil end
    local vt = r_ptr(this); if not valid(vt) then return nil end
    local f = r_ptr(vt + index*8); if not valid(f) then return nil end
    return f
end
local function vcall_void(this, index)
    local f = vfunc(this, index); if not f then return end
    ffi.cast("void(*)(void*)", f)(ffi.cast("void*", this))
end
local function vcall_void_bool(this, index, b)
    local f = vfunc(this, index); if not f then return end
    ffi.cast("void(*)(void*, int)", f)(ffi.cast("void*", this), b and 1 or 0)
end

local KNIVES = {
    { name = "Default (no swap)", def = nil },
    { name = "Bayonet",        def = 500 }, { name = "Classic Knife",  def = 503 },
    { name = "Flip Knife",     def = 505 }, { name = "Gut Knife",      def = 506 },
    { name = "Karambit",       def = 507 }, { name = "M9 Bayonet",     def = 508 },
    { name = "Huntsman",       def = 509 }, { name = "Falchion",       def = 512 },
    { name = "Bowie Knife",    def = 514 }, { name = "Butterfly",      def = 515 },
    { name = "Shadow Daggers", def = 516 }, { name = "Paracord Knife", def = 517 },
    { name = "Survival Knife", def = 518 }, { name = "Ursus Knife",    def = 519 },
    { name = "Navaja Knife",   def = 520 }, { name = "Nomad Knife",    def = 521 },
    { name = "Stiletto",       def = 522 }, { name = "Talon Knife",    def = 523 },
    { name = "Skeleton Knife", def = 525 }, { name = "Kukri Knife",    def = 526 },
}
local WEAPONS = {
    { name = "AK-47",        def = 7  }, { name = "M4A4",         def = 16 },
    { name = "M4A1-S",       def = 60 }, { name = "AWP",          def = 9  },
    { name = "SSG 08",       def = 40 }, { name = "SCAR-20",      def = 38 },
    { name = "G3SG1",        def = 11 }, { name = "SG 553",       def = 39 },
    { name = "AUG",          def = 8  }, { name = "FAMAS",        def = 10 },
    { name = "Galil AR",     def = 13 }, { name = "Desert Eagle", def = 1  },
    { name = "R8 Revolver",  def = 64 }, { name = "Dual Berettas",def = 2  },
    { name = "Five-SeveN",   def = 3  }, { name = "Glock-18",     def = 4  },
    { name = "Tec-9",        def = 30 }, { name = "P2000",        def = 32 },
    { name = "P250",         def = 36 }, { name = "USP-S",        def = 61 },
    { name = "CZ75-Auto",    def = 63 }, { name = "MAC-10",       def = 17 },
    { name = "P90",          def = 19 }, { name = "PP-Bizon",     def = 26 },
    { name = "MP5-SD",       def = 23 }, { name = "MP7",          def = 33 },
    { name = "MP9",          def = 34 }, { name = "UMP-45",       def = 24 },
    { name = "M249",         def = 14 }, { name = "Negev",        def = 28 },
    { name = "XM1014",       def = 25 }, { name = "MAG-7",        def = 27 },
    { name = "Nova",         def = 35 }, { name = "Sawed-Off",    def = 29 },
}
local GLOVES = {
    { name = "Default (off)",      def = 0    },
    { name = "Bloodhound Gloves",  def = 5027 }, { name = "Sport Gloves",      def = 5030 },
    { name = "Driver Gloves",      def = 5031 }, { name = "Hand Wraps",        def = 5032 },
    { name = "Moto Gloves",        def = 5033 }, { name = "Specialist Gloves", def = 5034 },
    { name = "Hydra Gloves",       def = 5035 }, { name = "Broken Fang Gloves",def = 4725 },
}
local function is_knife(def) return def == 42 or def == 59 or (def >= 500 and def <= 526) end

local SKINS = {
  [1]={{"Blaze",37},{"Blue Ply",945},{"Bronze Deco",425},{"Calligraffiti",114},{"Cobalt Disruption",231},{"Code Red",711},{"Conspiracy",351},{"Corinthian",509},{"Crimson Web",232},{"Directive",603},{"Emerald JГ¶rmungandr",757},{"Fennec Fox",764},{"Firebreathing",1430},{"Golden Koi",185},{"Hand Cannon",328},{"Heat Treated",1054},{"Heirloom",273},{"Hypnotic",61},{"Kumicho Dragon",527},{"Light Rail",841},{"Mecha Industries",805},{"Meteorite",296},{"Midnight Storm",468},{"Mint Fan",1257},{"Mudder",90},{"Mulberry",1318},{"Naga",397},{"Night",40},{"Night Heist",1006},{"Ocean Drive",1090},{"Oxide Blaze",645},{"Pilot",347},{"Printstream",962},{"Serpent Strike",1189},{"Sputnik",1056},{"Starcade",938},{"Sunset Storm еЈ±",469},{"Sunset Storm ејђ",470},{"The Bronze",992},{"The Daily Deagle",1360},{"Tilted",138},{"Trigger Discipline",1050},{"Urban DDPAT",17},{"Urban Rubble",237}},
  [2]={{"Angel Eyes",1347},{"Anodized Navy",28},{"Balance",895},{"Black Limba",190},{"BorDeux",1335},{"Briar",330},{"Cartel",528},{"Cobalt Quartz",249},{"Cobra Strike",658},{"Colony",47},{"Contractor",46},{"Demolition",153},{"Dezastre",978},{"Drift Wood",824},{"Dualing Dragons",491},{"Duelist",447},{"Elite 1.6",903},{"Emerald",453},{"Flora Carnivora",1156},{"Heist",1005},{"Hemoglobin",220},{"Hideout",1169},{"Hydro Strike",112},{"Marina",261},{"Melondrama",1126},{"Moon in Libra",450},{"Oil Change",1086},{"Panther",276},{"Polished Malachite",1290},{"Pyre",860},{"Retribution",307},{"Rose Nacre",1263},{"Royal Consorts",625},{"Shred",710},{"Silver Pour",1373},{"Stained",43},{"Sweet Little Angels",139},{"Switch Board",998},{"Tread",1091},{"Twin Turbo",747},{"Urban Shock",396},{"Ventilators",544}},
  [3]={{"Angry Mob",837},{"Anodized Gunmetal",210},{"Autumn Thicket",1336},{"Berries And Cherries",1002},{"Boost Protocol",1093},{"Buddy",906},{"Candy Apple",3},{"Capillary",646},{"Case Hardened",44},{"Contractor",46},{"Coolant",784},{"Copper Galaxy",274},{"Crimson Blossom",729},{"Dark Polymer",1429},{"Fairy Tale",979},{"Fall Hazard",1082},{"Flame Test",693},{"Forest Night",78},{"Fowl Play",352},{"Fraise Crane",1380},{"Heat Treated",831},{"Hot Shot",377},{"Hybrid",1168},{"Hyper Beast",660},{"Jungle",151},{"Kami",265},{"Midnight Paintover",1062},{"Monkey Business",427},{"Neon Kimono",464},{"Nightshade",223},{"Nitro",254},{"Orange Peel",141},{"Retrobution",510},{"Scrawl",1128},{"Scumbria",605},{"Silver Quartz",252},{"Sky Blue",1262},{"Triumvirate",530},{"Urban Hazard",387},{"Violent Daimyo",585},{"Withered Vine",932}},
  [4]={{"AXIA",832},{"Block-18",1167},{"Blue Fissure",278},{"Brass",159},{"Bullet Queen",957},{"Bunsen Burner",479},{"Candy Apple",3},{"Catacombs",399},{"Clear Polymer",1039},{"Coral Bloom",1312},{"Death Rattle",293},{"Dragon Tattoo",48},{"Fade",38},{"Franklin",1016},{"Fully Tuned",1421},{"Gamma Doppler",1119},{"Gamma Doppler",1120},{"Gamma Doppler",1121},{"Gamma Doppler",1122},{"Gamma Doppler",1123},{"Glockingbird",1282},{"Gold Toof",129},{"Green Line",1200},{"Grinder",381},{"Groundwater",2},{"High Beam",799},{"Ironwork",623},{"Mirror Mosaic",1348},{"Moonrise",694},{"Neo-Noir",988},{"Night",40},{"Nuclear Garden",789},{"Ocean Topo",1265},{"Off World",680},{"Oxide Blaze",808},{"Pink DDPAT",84},{"Ramese's Reach",1240},{"Reactor",367},{"Red Tire",1079},{"Royal Legion",532},{"Sacrifice",918},{"Sand Dune",208},{"Shinobu",1208},{"Snack Attack",1100},{"Steel Disruption",230},{"Synth Leaf",732},{"Teal Graf",152},{"Trace Lock",1357},{"Twilight Galaxy",437},{"Umbral Rabbit",1227},{"Vogue",963},{"Warhawk",713},{"Wasteland Rebel",586},{"Water Elemental",353},{"Weasel",607},{"Winterized",1158},{"Wraiths",495}},
  [7]={{"Aphrodite",1397},{"Aquamarine Revenge",474},{"Asiimov",801},{"B the Monster",142},{"Baroque Purple",745},{"Black Laminate",172},{"Bloodsport",639},{"Blue Laminate",226},{"Breakthrough",1358},{"Cartel",394},{"Case Hardened",44},{"Crane Flight",1425},{"Crossfade",912},{"Elite Build",422},{"Emerald Pinstripe",300},{"Fire Serpent",180},{"First Class",341},{"Frontside Misty",490},{"Fuel Injector",524},{"Gold Arabesque",921},{"Green Laminate",1070},{"Head Shot",1221},{"Hydroponic",456},{"Ice Coaled",1143},{"Inheritance",1171},{"Jaguar",316},{"Jet Set",340},{"Jungle Spray",122},{"Leet Museo",1087},{"Legion of Anubis",959},{"Midnight Laminate",1218},{"Neon Revolution",600},{"Neon Rider",707},{"Nightwish",1141},{"Nouveau Rouge",1309},{"Olive Polycam",1179},{"Orbit Mk01",656},{"Panthera onca",1018},{"Phantom Disruptor",941},{"Point Disarray",506},{"Predator",170},{"Rat Rod",885},{"Red Laminate",14},{"Redline",282},{"Safari Mesh",72},{"Safety Net",795},{"Searing Rage",1207},{"Slate",1035},{"Steel Delta",1238},{"The Empress",675},{"The Oligarch",1352},{"The Outsiders",113},{"Uncharted",836},{"VariCamo Grey",1288},{"Vulcan",302},{"Wasteland Rebel",380},{"Wild Lotus",724},{"Wintergreen",1283},{"X-Ray",1004}},
  [8]={{"Akihabara Accept",455},{"Amber Fade",246},{"Amber Slipstream",708},{"Anodized Navy",197},{"Arctic Wolf",886},{"Aristocrat",583},{"Bengal Tiger",9},{"Carved Jade",1033},{"Chameleon",280},{"Colony",47},{"Commando Company",1308},{"Condemned",110},{"Contractor",46},{"Copperhead",10},{"Creep",1362},{"Daedalus",444},{"Death by Puppy",913},{"Eye of Zapems",134},{"Flame JГ¶rmungandr",758},{"Fleet Flock",541},{"Hot Rod",33},{"Lil' Pig",173},{"Luxe Trim",121},{"Midnight Lily",727},{"Momentum",845},{"Navy Murano",740},{"Plague",1088},{"Radiation Hazard",375},{"Random Access",779},{"Ricochet",507},{"Sand Storm",823},{"Snake Pit",1249},{"Spalted Wood",927},{"Steel Sentinel",1198},{"Storm",100},{"Stymphalian",690},{"Surveillance",995},{"Sweeper",794},{"Syd Mead",601},{"Tom Cat",942},{"Torque",305},{"Trigger Discipline",1339},{"Triqua",674},{"Wings",73}},
  [9]={{"Acheron",788},{"Arsenic Spill",1324},{"Asiimov",279},{"Atheris",838},{"Black Nile",1239},{"BOOM",174},{"Capillary",943},{"Chromatic Aberration",1144},{"Chrome Cannon",1170},{"CMYK",163},{"Containment Breach",887},{"Corticera",181},{"Crakow!",137},{"Desert Hydra",819},{"Dragon Lore",344},{"Duality",1222},{"Electric Hive",227},{"Elite Build",525},{"Exoskeleton",975},{"Exothermic",1378},{"Fade",1026},{"Fever Dream",640},{"Graphite",212},{"Green Energy",1280},{"Gungnir",756},{"Hyper Beast",475},{"Ice Coaled",1346},{"Lightning Strike",51},{"LongDog",1213},{"Man-o'-war",395},{"Medusa",446},{"Mortis",691},{"Neo-Noir",803},{"Oni Taiji",662},{"PAW",718},{"Phobos",584},{"Pink DDPAT",84},{"Pit Viper",251},{"POP AWP",1058},{"Printstream",1206},{"Queen's Gambit",1422},{"Redline",259},{"Safari Mesh",72},{"Silk Tiger",1029},{"Snake Camo",30},{"Sun in Leo",451},{"The End",1356},{"The Prince",736},{"Wildfire",917},{"Worm God",424}},
  [10]={{"2A2F",1202},{"Afterimage",154},{"Bad Trip",1184},{"Byproduct",1393},{"CaliCamo",240},{"Colony",47},{"Commemoration",919},{"Contrast Spray",22},{"Crypsis",835},{"Cyanospatter",92},{"Dark Water",60},{"Decommissioned",904},{"Djinn",429},{"Doomkitty",178},{"Eye of Athena",723},{"Faulty Wiring",1066},{"Grey Ghost",1321},{"Half Sleeve",461},{"Halftone Wash",882},{"Hexane",218},{"Macabre",659},{"Mecha Industries",626},{"Meltdown",1053},{"Meow 36",1146},{"Neural Net",477},{"Night Borre",863},{"Palm",1302},{"Prime Conspiracy",999},{"Pulse",260},{"Rapid Eye Movement",1127},{"Roll Cage",604},{"Sergeant",288},{"Spitfire",194},{"Styx",371},{"Sundown",869},{"Survivor Z",492},{"Teardown",244},{"Valence",529},{"Vendetta",1365},{"Waters of Nephthys",1241},{"Yeti Camo",1219},{"ZX Spectron",1092}},
  [11]={{"Ancient Ritual",1034},{"Arctic Camo",6},{"Azure Zebra",229},{"Black Sand",891},{"Chronos",438},{"Contractor",46},{"Demeter",195},{"Desert Storm",8},{"Digital Mesh",980},{"Dream Glade",1129},{"Flux",493},{"Green Apple",294},{"Green Cell",1305},{"High Seas",712},{"Hunter",677},{"Jungle Dashed",147},{"Keeping Tabs",1095},{"Murky",382},{"New Roots",930},{"Orange Crash",545},{"Orange Kimono",465},{"Polar Camo",74},{"Red Jasper",1328},{"Safari Mesh",72},{"Scavenger",806},{"Stinger",628},{"The Executioner",511},{"VariCamo",235},{"Ventilator",606},{"Violet Murano",739}},
  [13]={{"Acid Dart",1296},{"Akoben",842},{"Amber Fade",246},{"Aqua Terrace",460},{"Black Sand",629},{"Blue Titanium",216},{"CAUTION!",1071},{"Cerberus",379},{"Chatterbox",398},{"Chromatic Aberration",1038},{"Cold Fusion",790},{"Connexion",972},{"Control",1185},{"Crimson Tsunami",647},{"Destroyer",1147},{"Dusk Ruins",1032},{"Eco",428},{"Firefight",546},{"Galigator",1434},{"Green Apple",294},{"Grey Smoke",1275},{"Hunting Blind",241},{"Kami",308},{"Metallic Squeezer",239},{"NV",939},{"O-Ranger",1314},{"Orange DDPAT",83},{"Phoenix Blacklight",1013},{"Rainbow Spoon",1178},{"Robin's Egg",1264},{"Rocket Pop",478},{"Sage Spray",119},{"Sandstorm",264},{"Shattered",192},{"Signal",807},{"Sky Mandala",1383},{"Stone Cold",494},{"Sugar Rush",661},{"Tornado",101},{"Tuxedo",297},{"Urban Rubble",237},{"Vandal",981},{"VariCamo",235},{"Winter Forest",76}},
  [14]={{"Aztec",902},{"Blizzard Marbleized",75},{"Bock Blocks",1435},{"Contrast Spray",22},{"Deep Relief",983},{"Downtown",1148},{"Emerald Poison Dart",648},{"Gator Mesh",243},{"Humidor",827},{"Hypnosis",120},{"Impact Drill",472},{"Jungle",151},{"Jungle DDPAT",202},{"Magma",266},{"Midnight Palm",933},{"Nebula Crusader",496},{"O.S.I.P.R.",1042},{"Predator",170},{"Sage Camo",1298},{"Shipping Forecast",452},{"Sleet",1370},{"Spectre",547},{"Spectrogram",875},{"Submerged",1242},{"System Lock",401},{"Warbird",900}},
  [16]={{"Aeolian Dark",1364},{"Asiimov",255},{"Bullet Rain",155},{"Buzz Kill",632},{"Choppa",1210},{"Converter",793},{"Cyber Security",985},{"Dark Blossom",730},{"Daybreak",471},{"Desert Storm",8},{"Desert-Strike",336},{"Desolate Space",588},{"Etch Lord",1165},{"Evil Daimyo",480},{"Eye of Horus",1255},{"Faded Zebra",176},{"Full Throttle",1353},{"Global Offensive",993},{"Griffin",384},{"Hellfire",664},{"Hellish",1209},{"Howl",309},{"In Living Color",1041},{"Jungle Tiger",16},{"Magnesium",811},{"Mainframe",780},{"Modern Hunter",164},{"Naval Shred Camo",1266},{"Neo-Noir",695},{"Poly Mag",1149},{"Polysoup",874},{"Poseidon",449},{"Radiation Hazard",167},{"Red DDPAT",926},{"Royal Paladin",512},{"Sheet Lightning",1281},{"Spider Lily",1097},{"Steel Work",1313},{"Temukau",1228},{"The Battlestar",533},{"The Coalition",1063},{"The Emperor",844},{"Tooth Fairy",971},{"Tornado",101},{"Turbine",118},{"Urban DDPAT",17},{"X-Ray",215},{"Zirka",187},{"Zubastick",1432},{"йѕЌзЋ‹ (Dragon King)",400}},
  [17]={{"Acid Hex",1295},{"Allure",965},{"Aloha",665},{"Amber Fade",246},{"Bronzer",1334},{"Button Masher",1045},{"Calf Skin",748},{"Candy Apple",3},{"Carnivore",589},{"Case Hardened",44},{"Cat Fight",1349},{"Classic Crate",908},{"Commuter",343},{"Copper Borre",761},{"Curse",310},{"Derailment",1204},{"Disco Tech",947},{"Echoing Sands",1244},{"Ensnared",1131},{"Fade",38},{"Gold Brick",1025},{"Graven",188},{"Heat",284},{"Hot Snakes",1009},{"Indigo",333},{"Lapis Gator",534},{"Last Dive",651},{"Light Box",1164},{"Malachite",402},{"Monkeyflage",1150},{"Neon Rider",433},{"Nuclear Garden",372},{"Oceanic",682},{"Palm",157},{"Pipe Down",812},{"Pipsqueak",140},{"Poplar Thicket",1285},{"Propaganda",1067},{"Rangeen",498},{"Red Filigree",742},{"SaibДЃ Oni",126},{"Sakkaku",1229},{"Sienna Damask",826},{"Silver",32},{"Snow Splash",1367},{"Stalker",898},{"Storm Camo",1269},{"Strats",1075},{"Surfwood",871},{"Tatter",337},{"Tornado",101},{"Toybox",1098},{"Ultraviolet",98},{"Urban DDPAT",17},{"Whitefish",840}},
  [19]={{"Aeolian Light",1361},{"Ancient Earth",1020},{"Ash Wood",234},{"Asiimov",359},{"Astral JГ¶rmungandr",759},{"Attack Vector",936},{"Baroque Red",744},{"Blind Spot",228},{"Blue Tac",1277},{"Chopper",593},{"Cocoa Rampage",977},{"Cold Blooded",67},{"Death by Kitty",156},{"Death Grip",669},{"Deathgaze",1419},{"Desert DDPAT",925},{"Desert Halftone",1332},{"Desert Warfare",311},{"Elite Build",486},{"Emerald Dragon",182},{"Facility Negative",776},{"Fallout Warning",169},{"Freight",969},{"Glacier Mesh",111},{"Grim",611},{"Leather",342},{"Module",335},{"Mustard Gas",1291},{"Neoqueen",1233},{"Nostalgia",911},{"Off World",849},{"Randy Rush",127},{"Reef Grief",1256},{"Run and Hide",1000},{"Sand Spray",124},{"ScaraB Rush",1250},{"Schematic",1074},{"Scorched",175},{"Shallow Grave",636},{"Shapewood",516},{"Storm",100},{"Straight Dimes",1199},{"Sunset Lily",726},{"Teardown",244},{"Tiger Pit",1015},{"Traction",717},{"Trigon",283},{"Vent Rush",1154},{"Verdant Growth",828},{"Virus",20},{"Wash me",133},{"Wave Breaker",1190}},
  [23]={{"Acid Wash",888},{"Agent",915},{"Autumn Twilly",1061},{"Bamboo Garden",872},{"Co-Processor",781},{"Condition Zero",986},{"Desert Strike",949},{"Dirt Drop",753},{"Focus",1344},{"Gauss",846},{"Gold Leaf",1294},{"Kitbash",974},{"Lab Rats",800},{"Lime Hex",1274},{"Liquidation",1231},{"Necro Jr.",1137},{"Neon Squeezer",161},{"Nitro",798},{"Oxide Oasis",923},{"Phosphor",810},{"Picnic",1385},{"Savannah Halftone",768},{"Snow Splash",1366},{"Statics",1180}},
  [24]={{"Arctic Wolf",704},{"Blaze",37},{"Bone Pile",193},{"Briefing",615},{"Caramel",93},{"Carbon Fiber",70},{"Continuum",1351},{"Corporal",281},{"Crime Scene",1003},{"Crimson Foil",412},{"Day Lily",725},{"Delusion",392},{"Exposure",688},{"Facility Dark",778},{"Fade",879},{"Fallout Warning",169},{"Fragment",1426},{"Full Stop",250},{"Gold Bismuth",990},{"Grand Prix",436},{"Green Swirl",1303},{"Gunsmoke",15},{"Houndstooth",1008},{"Indigo",333},{"K.O. Factory",1194},{"Labyrinth",362},{"Late Night Transit",1203},{"Mechanism",1085},{"Metal Flowers",672},{"Minotaur's Labyrinth",441},{"Momentum",802},{"Moonrise",851},{"Motorized",1175},{"Mudder",90},{"Neo-Noir",131},{"Oscillator",1049},{"Plastique",916},{"Primal Saber",556},{"Riot",488},{"Roadblock",1157},{"Scaffold",652},{"Scorched",175},{"Urban DDPAT",17},{"Warm Blooded",1387},{"Wild Child",1236}},
  [25]={{"Ancient Lore",1021},{"Banana Leaf",731},{"Black Tie",557},{"Blaze Orange",166},{"Blue Spruce",96},{"Blue Steel",42},{"Blue Tire",1078},{"Bone Machine",370},{"CaliCamo",240},{"Canvas Cloud",1333},{"Charter",994},{"Copperflage",1287},{"Elegant Vines",821},{"Entombed",970},{"Fallout Warning",169},{"Frost Borre",760},{"Grassland",95},{"Gum Wall Camo",1267},{"Halftone Shift",834},{"Heaven Guard",314},{"Hieroglyph",1254},{"Incinegator",850},{"Irezumi",1174},{"Jungle",205},{"Mockingbird",1182},{"Monster Melt",146},{"Oxide Blaze",706},{"Quicksilver",407},{"Red Leather",348},{"Red Python",320},{"Run Run Run",1201},{"Scumbria",505},{"Seasons",654},{"Slipstream",616},{"Solitude",1215},{"Teclu Burner",521},{"Tranquility",393},{"Urban Perforated",135},{"VariCamo Blue",238},{"Watchdog",1103},{"XoooM",1381},{"XOXO",1046},{"Ziggy",689},{"Zombie Offensive",1135}},
  [26]={{"Anolis",829},{"Antique",306},{"Bamboo Print",457},{"Bizoom",1374},{"Blue Streak",13},{"Brass",159},{"Breaker Box",1083},{"Candy Apple",3},{"Carbon Fiber",70},{"Chemical Green",376},{"Cobalt Halftone",267},{"Cold Cell",770},{"Death Rattle",293},{"Embargo",884},{"Facility Sketch",775},{"Forest Leaves",25},{"Fuel Rod",508},{"Harvester",594},{"High Roller",676},{"Irradiated Alert",171},{"Judgement of Anubis",542},{"Jungle Slipstream",641},{"Lumen",1099},{"Modern Hunter",164},{"Night Ops",236},{"Night Riot",692},{"Osiris",349},{"Photic Zone",526},{"RMX",1418},{"Runic",973},{"Rust Coat",203},{"Sand Dashed",148},{"Seabird",873},{"Space Cat",1125},{"Thermal Currents",1392},{"Urban Dashed",149},{"Water Sigil",224},{"Wood Block Camo",1325}},
  [27]={{"BI83 Spectrum",1089},{"Bulldozer",39},{"Carbon Fiber",70},{"Chainmail",327},{"Cinquedea",737},{"Cobalt Core",499},{"Copper Coated",1245},{"Copper Oxide",1306},{"Core Breach",787},{"Counter Terrace",462},{"Firestarter",385},{"Foresight",1132},{"Hard Water",666},{"Hazard",198},{"Heat",431},{"Heaven Guard",291},{"Insomnia",1220},{"Irradiated Alert",171},{"Justice",948},{"MAGnitude",1355},{"Memento",177},{"Metallic DDPAT",34},{"Monster Call",961},{"Navy Sheen",822},{"Petroglyph",608},{"Popdog",909},{"Praetorian",535},{"Prism Terrace",1072},{"Resupply",1188},{"Rust Coat",754},{"Sand Dune",99},{"Seabird",473},{"Silver",32},{"Sonar",633},{"Storm",100},{"SWAG-7",703},{"Wildwood",773}},
  [28]={{"Anodized Navy",28},{"Army Sheen",298},{"Boroque Sand",920},{"Bratatat",317},{"Bulkhead",783},{"CaliCamo",240},{"Dazzle",610},{"Desert-Strike",355},{"dev_texture",1043},{"Drop Me",1152},{"Infrastructure",1080},{"Lionfish",698},{"Loudmouth",483},{"Man-o'-war",432},{"MjГ¶lnir",763},{"Nuclear Waste",369},{"Palm",201},{"Phoenix Stencil",1012},{"Power Loader",514},{"Prototype",950},{"Raw Ceramic",1300},{"Sour Grapes",1260},{"Terrain",285},{"Ultralight",958},{"Wall Bang",144}},
  [29]={{"Amber Fade",246},{"Analog Input",1160},{"Apocalypto",953},{"Bamboo Shadow",458},{"Black Sand",814},{"Brake Light",797},{"Clay Ambush",1014},{"Copper",41},{"Crimson Batik",1391},{"Devourer",720},{"First Class",345},{"Forest DDPAT",5},{"Fubar",552},{"Full Stop",250},{"Fusion",1427},{"Highwayman",390},{"Irradiated Alert",171},{"Jungle Thicket",870},{"Kissв™ҐLove",1155},{"Limelight",596},{"Morris",673},{"Mosaico",204},{"Orange DDPAT",83},{"Origami",434},{"Parched",880},{"Runoff",1272},{"Rust Coat",323},{"Sage Spray",119},{"Serenity",405},{"Snake Camo",30},{"Spirit Board",1140},{"The Kraken",256},{"Wasteland Princess",638},{"Yorick",517},{"Zander",655}},
  [30]={{"Army Mesh",242},{"Avalanche",520},{"Bamboo Forest",459},{"Bamboozle",839},{"Banana Leaf",1384},{"Blast From the Past",1024},{"Blue Blast",1279},{"Blue Titanium",216},{"Brass",159},{"Brother",964},{"Citric Acid",1322},{"Cracked Opal",684},{"Cut Out",671},{"Decimator",889},{"Flash Out",905},{"Fubar",816},{"Fuel Injector",614},{"Garter-9",1286},{"Groundwater",2},{"Hades",439},{"Ice Cap",599},{"Isaac",303},{"Jambiya",539},{"Mummy's Rot",1252},{"Nuclear Threat",179},{"Orange Murano",738},{"Ossified",36},{"Phoenix Chalk",1010},{"Raw Ceramic",1299},{"Re-Entry",555},{"Rebel",1235},{"Red Quartz",248},{"Remote Control",791},{"Rust Leaf",733},{"Safety Net",795},{"Sandstorm",289},{"Slag",1159},{"Snek-9",722},{"Terrace",463},{"Tiger Stencil",766},{"Titanium Bit",272},{"Tornado",206},{"Toxic",374},{"Urban DDPAT",17},{"VariCamo",235},{"Whiteout",1214}},
  [31]={{"Charged Up",1205},{"Dragon Snore",292},{"Earth Mandala",1382},{"Electric Blue",1268},{"Olympus",1172},{"Swamp DDPAT",1297},{"Tosai",1183}},
  [32]={{"Acid Etched",951},{"Amber Fade",246},{"Chainmail",327},{"Coach Class",346},{"Coral Halftone",878},{"Corticera",184},{"Dispatch",997},{"Fire Elemental",389},{"Gnarled",960},{"Granite Marbleized",21},{"Grassland",95},{"Grassland Leaves",104},{"Grip Tape",1359},{"Handgun",485},{"Imperial",515},{"Imperial Dragon",591},{"Ivory",357},{"Lifted Spirits",1138},{"Marsh",1292},{"Obsidian",894},{"Ocean Foam",211},{"Oceanic",550},{"Panther Camo",1019},{"Pathfinder",443},{"Pulse",338},{"Red FragCam",275},{"Red Wing",1342},{"Royal Baroque",1259},{"Scorpion",71},{"Silver",32},{"Space Race",1055},{"Sure Grip",1181},{"Turf",635},{"Urban Hazard",700},{"Wicked Sick",1224},{"Woodsman",667}},
  [33]={{"Abyssal Apparition",1133},{"Akoben",649},{"Amberline",1436},{"Anodized Navy",28},{"Armor Core",423},{"Army Recon",245},{"Asterion",442},{"Astrolabe",940},{"Bloodsport",696},{"Cirrus",627},{"Coral Paisley",1386},{"Fade",752},{"Forest DDPAT",5},{"Full Stop",250},{"Groundwater",209},{"Guerrilla",1096},{"Gunsmoke",15},{"Impire",536},{"Just Smile",1163},{"Mischief",847},{"Motherboard",782},{"Nemesis",481},{"Neon Ply",893},{"Ocean Foam",213},{"Olive Plaid",365},{"Orange Peel",141},{"Powercore",719},{"Prey",935},{"Scorched",175},{"Short Ochre",1326},{"Skulls",11},{"Smoking Kills",1354},{"Special Delivery",500},{"Sunbaked",1246},{"Tall Grass",1023},{"Teal Blossom",728},{"Urban Hazard",354},{"Vault Heist",1007},{"Whiteout",102}},
  [34]={{"Airlock",609},{"Arctic Tri-Tone",331},{"Army Sheen",298},{"Bee-Tron",1388},{"Bioleak",549},{"Black Sand",697},{"Broken Record",1341},{"Buff Blue",1278},{"Bulldozer",39},{"Capillary",715},{"Cobalt Paisley",1258},{"Dark Age",329},{"Dart",386},{"Deadly Poison",403},{"Dizzy",1375},{"Dry Season",199},{"Featherweight",1225},{"Food Chain",1037},{"Goo",679},{"Green Plaid",366},{"Hot Rod",33},{"Hydra",910},{"Hypnotic",61},{"Latte Rush",1211},{"Modest Threat",804},{"Mount Fuji",1094},{"Multi-Terrain",1330},{"Music Box",820},{"Nexus",1193},{"Old Roots",931},{"Orange Peel",141},{"Pandora's Box",448},{"Pine",1301},{"Rose Iron",262},{"Ruby Poison Dart",482},{"Sand Dashed",148},{"Sand Scale",630},{"Setting Sun",368},{"Shredded",1310},{"Slide",755},{"Stained Glass",867},{"Starlight Protector",1134},{"Storm",100},{"Urban Sovereign",1423},{"Wild Lily",734}},
  [35]={{"Antique",286},{"Army Sheen",298},{"Baroque Orange",746},{"Blaze Orange",166},{"Bloomstick",62},{"Caged Steel",299},{"Candy Apple",3},{"Clear Polymer",987},{"Currents",1368},{"Dark Sigil",1162},{"Exo",590},{"Forest Leaves",25},{"Ghost Camo",225},{"Gila",634},{"Graphite",214},{"Green Apple",294},{"Hyper Beast",537},{"Interlock",1077},{"Koi",356},{"Mandrel",785},{"Marsh Grass",1331},{"Modern Hunter",164},{"Moon in Libra",450},{"Ocular",1350},{"Plume",890},{"Polar Mesh",107},{"Predator",170},{"Quick Sand",929},{"Rain Station",1337},{"Ranger",484},{"Red Quartz",248},{"Rising Skull",263},{"Rising Sun",1192},{"Rust Coat",323},{"Sand Dune",99},{"Sobek's Bite",1247},{"Tempest",191},{"Toy Soldier",716},{"Turquoise Pour",1261},{"Walnut",158},{"Wild Six",699},{"Windblown",1051},{"Wood Fired",809},{"Wurst HГ¶lle",145},{"Yorkshire",324}},
  [36]={{"Apep's Curse",1248},{"Asiimov",551},{"Bengal Tiger",1030},{"Black & Tan",928},{"Bone Mask",27},{"Boreal Forest",77},{"Bullfrog",1345},{"Cartel",388},{"Cassette",968},{"Constructivist",1212},{"Contaminant",982},{"Contamination",373},{"Copper Oxide",1307},{"Crimson Kimono",466},{"Cyber Shell",1044},{"Dark Filigree",741},{"Digital Architect",1081},{"Drought",825},{"Epicenter",130},{"Exchanger",786},{"Facets",207},{"Facility Draft",777},{"Forest Night",78},{"Franklin",295},{"Gunsmoke",15},{"Hive",219},{"Inferno",907},{"Iron Clad",592},{"Kintsugi",1420},{"Mehndi",258},{"Metallic DDPAT",34},{"Mint Kimono",467},{"Modern Hunter",164},{"Muertos",404},{"Nevermore",813},{"Nuclear Threat",168},{"Plum Netting",1273},{"Re.built",1230},{"Red Rock",668},{"Red Tide",1315},{"Ripple",650},{"Sand Dune",99},{"Sedimentary",1317},{"See Ya Later",678},{"Sleet",1369},{"Small Game",774},{"Splash",162},{"Steel Disruption",230},{"Supernova",358},{"Undertow",271},{"Valence",426},{"Verdigris",848},{"Vino Primo",749},{"Visions",1153},{"Whiteout",102},{"Wingshot",501},{"X-Ray",125}},
  [38]={{"Army Sheen",298},{"Assault",914},{"Bloodsport",597},{"Blueprint",642},{"Brass",159},{"Caged",1343},{"Carbon Fiber",70},{"Cardiac",391},{"Contractor",46},{"Crimson Web",232},{"Cyrex",312},{"Emerald",196},{"Enforcer",954},{"Fragments",1226},{"Green Marine",502},{"Grotto",406},{"Jungle Slipstream",685},{"Magna Carta",1028},{"Outbreak",518},{"Palm",157},{"Poultrygeist",1139},{"Powercore",612},{"Sand Mesh",116},{"Short Ochre",1327},{"Splash Jam",165},{"Stone Mosaico",865},{"Storm",100},{"Torn",896},{"Trail Blazer",117},{"Wild Berry",883},{"Zinc",1371}},
  [39]={{"Aerial",598},{"Aloha",702},{"Anodized Navy",28},{"Army Sheen",298},{"Atlas",553},{"Barricade",861},{"Basket Halftone",1320},{"Berry Gel Coat",901},{"Bleached",934},{"Bulldozer",39},{"Candy Apple",864},{"Colony IV",897},{"Cyberforce",1234},{"Cyrex",487},{"Damascus Steel",247},{"Danger Close",815},{"Darkwing",955},{"Desert Blossom",765},{"Dragon Tech",1151},{"Fallout Warning",378},{"Gator Mesh",243},{"Hazard Pay",1084},{"Heavy Metal",1048},{"Hypnotic",61},{"Integrale",750},{"Lush Ruins",1022},{"Night Camo",1270},{"Ol' Rusty",966},{"Phantom",686},{"Pulse",287},{"Safari Print",1394},{"Tiger Moth",519},{"Tornado",101},{"Traveler",363},{"Triarch",613},{"Ultraviolet",98},{"Wave Spray",186},{"Waves Perforated",136}},
  [40]={{"Abyss",361},{"Acid Fade",253},{"Azure Glyph",1251},{"Big Iron",503},{"Blood in the Water",222},{"Bloodshot",899},{"Blue Spruce",96},{"Blush Pour",1316},{"Calligrafaux",1379},{"Carbon Fiber",70},{"Dark Water",60},{"Death Strike",1052},{"Death's Head",670},{"Detour",319},{"Dezastre",1161},{"Dragonfire",624},{"Fever Dream",956},{"Ghost Crusader",554},{"Green Ceramic",1304},{"Grey Smoke",1271},{"Halftone Whorl",877},{"Hand Brake",751},{"Jungle Dashed",147},{"Lichen Dashed",26},{"Mainframe 001",967},{"Mayan Dreams",200},{"Memorial",1187},{"Necropos",538},{"Orange Filigree",743},{"Parallax",989},{"Prey",935},{"Rapid Transit",128},{"Red Stone",762},{"Sand Dune",99},{"Sans Comic",1372},{"Sea Calico",868},{"Slashed",304},{"Spring Twilly",1060},{"Threat Detected",996},{"Tiger Tear",1289},{"Tropical Storm",233},{"Turbo Peek",1101},{"Zeno",513}},
  [60]={{"Atomic Alloy",301},{"Basilisk",383},{"Black Lotus",1166},{"Blood Tiger",217},{"Blue Phosphor",1017},{"Boreal Forest",77},{"Briefing",663},{"Bright Water",189},{"Chantico's Fire",548},{"Control Panel",792},{"Cyrex",360},{"Dark Water",60},{"Decimator",644},{"Electrum",1433},{"Emphorosaur-S",1223},{"Fade",1177},{"Fizzy POP",1059},{"Flashback",631},{"Glitched Paint",1311},{"Golden Coil",497},{"Guardian",257},{"Hot Rod",445},{"Hyper Beast",430},{"Icarus Fell",440},{"Imminent Danger",1073},{"Knight",326},{"Leaded Glass",681},{"Liquidation",1340},{"Master Piece",321},{"Mecha Industries",587},{"Moss Quartz",862},{"Mud-Spec",1243},{"Night Terror",1130},{"Nightmare",714},{"Nitro",254},{"Party Animal",1376},{"Player Two",946},{"Printstream",984},{"Rose Hex",1319},{"Solitude",1338},{"Stratosphere",1216},{"Vaporwave",106},{"VariCamo",235},{"Wash me plz",160},{"Welcome to the Jungle",1001}},
  [61]={{"27",115},{"Alpine Camo",830},{"Ancient Visions",1031},{"Black Lotus",1102},{"Bleeding Edge",1323},{"Blood Tiger",217},{"Blueprint",657},{"Business Class",364},{"Caiman",339},{"Check Engine",796},{"Cortex",705},{"Cyrex",637},{"Dark Water",60},{"Desert Tactical",1253},{"Flashback",817},{"Forest Leaves",25},{"Guardian",290},{"Jawbreaker",1173},{"Kill Confirmed",504},{"Lead Conduit",540},{"Monster Mashup",991},{"Neo-Noir",653},{"Night Ops",236},{"Orange Anolis",922},{"Orion",313},{"Overgrowth",183},{"Para Green",454},{"Pathfinder",443},{"PC-GRN",1186},{"Printstream",1142},{"Purple DDPAT",818},{"Road Rash",318},{"Royal Blue",332},{"Royal Guard",1217},{"Serum",221},{"Silent Shot",1431},{"Sleeping Potion",1377},{"Stainless",277},{"Target Acquired",1027},{"The Traitor",1040},{"Ticket to Hell",1136},{"Torque",489},{"Tropical Breeze",1284},{"Whiteout",1065}},
  [63]={{"Army Sheen",298},{"Chalice",325},{"Circaetus",1036},{"Copper Fiber",1195},{"Crimson Web",12},{"Distressed",944},{"Eco",709},{"Emerald",453},{"Emerald Quartz",859},{"Framework",1076},{"Green Plaid",366},{"Hexane",218},{"Honey Paisley",1390},{"Imprint",602},{"Indigo",333},{"Jungle Dashed",147},{"Midnight Palm",933},{"Nitro",322},{"Pink Pearl",1329},{"Poison Dart",315},{"Pole Position",435},{"Polymer",622},{"Red Astor",543},{"Silver",32},{"Slalom",937},{"Syndicate",1064},{"Tacticat",687},{"The Fuschia Is Now",269},{"Tigris",350},{"Tread Plate",268},{"Tuxedo",297},{"Twist",334},{"Vendetta",976},{"Victoria",270},{"Xiangliu",643},{"Yellow Jacket",476}},
  [64]={{"Amber Fade",523},{"Banana Cannon",1232},{"Blaze",37},{"Bone Forged",952},{"Bone Mask",27},{"Canal Spray",866},{"Cobalt Grip",1276},{"Crazy 8",1145},{"Crimson Web",12},{"Dark Chamber",1363},{"Desert Brush",924},{"Fade",522},{"Grip",701},{"Inlay",1237},{"Junk Yard",1047},{"Leafhopper",1293},{"Llama Cannon",683},{"Mauve Aside",1389},{"Memento",892},{"Night",40},{"Nitro",798},{"Phoenix Marker",1011},{"Reboot",595},{"Skull Crusher",843},{"Survivalist",721},{"Tango",123}},
  [500]={{"Autotronic",573},{"Black Laminate",563},{"Blue Steel",42},{"Boreal Forest",77},{"Bright Water",578},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",410},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Freehand",580},{"Gamma Doppler",568},{"Gamma Doppler",569},{"Gamma Doppler",570},{"Gamma Doppler",571},{"Gamma Doppler",572},{"Lore",558},{"Marble Fade",413},{"Night",40},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [503]={{"Blue Steel",42},{"Boreal Forest",77},{"Case Hardened",44},{"Crimson Web",12},{"Fade",38},{"Forest DDPAT",5},{"Night Stripe",735},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Urban Masked",143}},
  [505]={{"Autotronic",574},{"Black Laminate",564},{"Blue Steel",42},{"Boreal Forest",77},{"Bright Water",578},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",410},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Freehand",580},{"Gamma Doppler",568},{"Gamma Doppler",569},{"Gamma Doppler",570},{"Gamma Doppler",571},{"Gamma Doppler",572},{"Lore",559},{"Marble Fade",413},{"Night",40},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [506]={{"Autotronic",575},{"Black Laminate",565},{"Blue Steel",42},{"Boreal Forest",77},{"Bright Water",578},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",410},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Freehand",580},{"Gamma Doppler",568},{"Gamma Doppler",569},{"Gamma Doppler",570},{"Gamma Doppler",571},{"Gamma Doppler",572},{"Lore",560},{"Marble Fade",413},{"Night",40},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [507]={{"Autotronic",576},{"Black Laminate",566},{"Blue Steel",42},{"Boreal Forest",77},{"Bright Water",578},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",410},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Freehand",582},{"Gamma Doppler",568},{"Gamma Doppler",569},{"Gamma Doppler",570},{"Gamma Doppler",571},{"Gamma Doppler",572},{"Lore",561},{"Marble Fade",413},{"Night",40},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [508]={{"Autotronic",577},{"Black Laminate",567},{"Blue Steel",42},{"Boreal Forest",77},{"Bright Water",579},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",411},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Freehand",581},{"Gamma Doppler",568},{"Gamma Doppler",569},{"Gamma Doppler",570},{"Gamma Doppler",571},{"Gamma Doppler",572},{"Lore",562},{"Marble Fade",413},{"Night",40},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [509]={{"Autotronic",1117},{"Black Laminate",1112},{"Blue Steel",42},{"Boreal Forest",77},{"Bright Water",579},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",411},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Freehand",581},{"Gamma Doppler",568},{"Gamma Doppler",569},{"Gamma Doppler",570},{"Gamma Doppler",571},{"Gamma Doppler",572},{"Lore",1107},{"Marble Fade",413},{"Night",40},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",620},{"Urban Masked",143}},
  [512]={{"Autotronic",1116},{"Black Laminate",1111},{"Blue Steel",42},{"Boreal Forest",77},{"Bright Water",579},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",411},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Freehand",581},{"Gamma Doppler",568},{"Gamma Doppler",569},{"Gamma Doppler",570},{"Gamma Doppler",571},{"Gamma Doppler",572},{"Lore",1106},{"Marble Fade",413},{"Night",40},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",621},{"Urban Masked",143}},
  [514]={{"Autotronic",1114},{"Black Laminate",1109},{"Blue Steel",42},{"Boreal Forest",77},{"Bright Water",579},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",411},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Freehand",581},{"Gamma Doppler",568},{"Gamma Doppler",569},{"Gamma Doppler",570},{"Gamma Doppler",571},{"Gamma Doppler",572},{"Lore",1104},{"Marble Fade",413},{"Night",40},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [515]={{"Autotronic",1115},{"Black Laminate",1110},{"Blue Steel",42},{"Boreal Forest",77},{"Bright Water",579},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",411},{"Doppler",617},{"Doppler",418},{"Doppler",618},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",619},{"Fade",38},{"Forest DDPAT",5},{"Freehand",581},{"Gamma Doppler",568},{"Gamma Doppler",569},{"Gamma Doppler",570},{"Gamma Doppler",571},{"Gamma Doppler",572},{"Lore",1105},{"Marble Fade",413},{"Night",40},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [516]={{"Autotronic",1118},{"Black Laminate",1113},{"Blue Steel",42},{"Boreal Forest",77},{"Bright Water",579},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",411},{"Doppler",617},{"Doppler",418},{"Doppler",618},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",619},{"Fade",38},{"Forest DDPAT",5},{"Freehand",581},{"Gamma Doppler",568},{"Gamma Doppler",569},{"Gamma Doppler",570},{"Gamma Doppler",571},{"Gamma Doppler",572},{"Lore",1108},{"Marble Fade",413},{"Night",40},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [517]={{"Blue Steel",42},{"Boreal Forest",77},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",410},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Marble Fade",413},{"Night Stripe",735},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",621},{"Urban Masked",143}},
  [518]={{"Blue Steel",42},{"Boreal Forest",77},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",410},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Marble Fade",413},{"Night Stripe",735},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [519]={{"Blue Steel",42},{"Boreal Forest",77},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",857},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Marble Fade",413},{"Night Stripe",735},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [520]={{"Blue Steel",42},{"Boreal Forest",77},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",857},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Marble Fade",413},{"Night Stripe",735},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [521]={{"Blue Steel",42},{"Boreal Forest",77},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",410},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Marble Fade",413},{"Night Stripe",735},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [522]={{"Blue Steel",42},{"Boreal Forest",77},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",857},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Marble Fade",413},{"Night Stripe",735},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [523]={{"Blue Steel",42},{"Boreal Forest",77},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",858},{"Doppler",417},{"Doppler",852},{"Doppler",853},{"Doppler",854},{"Doppler",855},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Marble Fade",856},{"Night Stripe",735},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [525]={{"Blue Steel",42},{"Boreal Forest",77},{"Case Hardened",44},{"Crimson Web",12},{"Damascus Steel",410},{"Doppler",417},{"Doppler",418},{"Doppler",419},{"Doppler",420},{"Doppler",421},{"Doppler",415},{"Doppler",416},{"Fade",38},{"Forest DDPAT",5},{"Marble Fade",413},{"Night Stripe",735},{"Rust Coat",414},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Tiger Tooth",409},{"Ultraviolet",98},{"Urban Masked",143}},
  [526]={{"Blue Steel",42},{"Boreal Forest",77},{"Case Hardened",44},{"Crimson Web",12},{"Fade",38},{"Forest DDPAT",5},{"Night Stripe",735},{"Safari Mesh",72},{"Scorched",175},{"Slaughter",59},{"Stained",43},{"Urban Masked",143}},
  [4725]={{"Jade",10085},{"Needle Point",10087},{"Unhinged",10088},{"Yellow-banded",10086}},
  [5027]={{"Bronzed",10008},{"Charred",10006},{"Guerrilla",10039},{"Snakebite",10007}},
  [5030]={{"Amphibious",10045},{"Arid",10019},{"Big Game",10074},{"Blaze",1407},{"Bronze Morph",10046},{"Creme Pinstripe",1408},{"Frosty",1406},{"Hedge Maze",10038},{"Nocts",10076},{"Occult",1417},{"Omega",10047},{"Pandora's Box",10037},{"Red Racer",1409},{"Scarlet Shamagh",10075},{"Slingshot",10073},{"Superconductor",10018},{"Ultra Violent",1410},{"Vice",10048},{"Violet Beadwork",1405}},
  [5031]={{"Black Tie",10072},{"Brocade Crane",1399},{"Brocade Flowers",1400},{"Convoy",10015},{"Crimson Weave",10016},{"Diamondback",10040},{"Dragon Fists",1401},{"Garden",1402},{"Hand Sweaters",1439},{"Imperial Plaid",10042},{"King Snake",10041},{"Lunar Weave",10013},{"Overtake",10043},{"Plum Quill",1412},{"Queen Jaguar",10071},{"Racing Green",10044},{"Rezan the Red",10069},{"Seigaiha",1404},{"Snow Leopard",10070},{"Wave Chaser",1398}},
  [5032]={{"Arboreal",10056},{"Badlands",10036},{"CAUTION!",10084},{"Cobalt Skulls",10053},{"Constrictor",10083},{"Desert Shamagh",10081},{"Duct Tape",10055},{"Giraffe",10082},{"Leather",10009},{"Overprint",10054},{"Slaughter",10021},{"Spruce DDPAT",10010}},
  [5033]={{"3rd Commando Company",10080},{"Blood Pressure",10079},{"Boom!",10027},{"Cool Mint",10028},{"Eclipse",10024},{"Finish Line",10077},{"Polygon",10052},{"POW!",10049},{"Smoke Out",10078},{"Spearmint",10026},{"Transport",10051},{"Turtle",10050}},
  [5034]={{"Big Swell",1437},{"Blackbook",1414},{"Buckshot",10062},{"Chocolate Chesterfield",1415},{"Cloud Chaser",1440},{"Crimson Kimono",10033},{"Crimson Web",10061},{"Emerald Web",10034},{"Fade",10063},{"Field Agent",10068},{"Forest DDPAT",10030},{"Foundation",10035},{"Lime Polycam",1413},{"Lt. Commander",10066},{"Marble Fade",10065},{"Mogul",10064},{"Pillow Punchers",1438},{"Sunburst",1416},{"Tiger Strike",10067}},
  [5035]={{"Case Hardened",10060},{"Emerald",10057},{"Mangrove",10058},{"Rattler",10059}},
}

local function skin_list_for(def)
    local names  = { "[ None ]" }
    local paints = { 0 }
    local src = def and SKINS[def]
    if src then
        for i = 1, #src do
            names[i+1]  = src[i][1]
            paints[i+1] = src[i][2]
        end
    end
    return names, paints
end

local ITEMS = {}
local function add_item(name, def, kind) ITEMS[#ITEMS+1] = { name = name, def = def, kind = kind } end

for i = 1, #KNIVES do
    local k = KNIVES[i]
    if k.def then add_item("[Knife] " .. k.name, k.def, "knife") end
end
for i = 1, #WEAPONS do
    add_item(WEAPONS[i].name, WEAPONS[i].def, "weapon")
end
for i = 1, #GLOVES do
    local g = GLOVES[i]
    add_item(g.def == 0 and "[Glove] Default (off)" or "[Glove] " .. g.name, g.def, "glove")
end

local itemNames = {}; for i = 1, #ITEMS do itemNames[i] = ITEMS[i].name end

local DEF_TO_ITEM = {}
for i = 1, #ITEMS do
    if ITEMS[i].kind ~= "glove" then DEF_TO_ITEM[ITEMS[i].def] = i end
end

local state = {
    cfg          = {},
    opts         = {},
    knifeDef     = nil,
    gloveDef     = nil,
    applied      = {},
    pendingReset = {},
    resetKnife   = false,
    resetGlove   = false,
    lastGloveTeam    = 0,
    localModel       = nil,
    appliedLocalModel= nil,
}

local Config = {}

local g_activeDef = nil

local function item_ptr(wpn) return wpn + off.m_AttributeManager + off.m_Item end

local function safe_wear(wear)
    if not wear or wear <= 0 then return 0.0001 end
    return wear
end

local function write_fallback(wpn, paint, wear, seed, stat, statval)
    w_i32(wpn + off.m_nFallbackPaintKit, paint)
    w_f32(wpn + off.m_flFallbackWear, safe_wear(wear))
    w_i32(wpn + off.m_nFallbackSeed, seed)
    w_i32(wpn + off.m_nFallbackStatTrak, stat and (statval or 0) or -1)
end

local function mark_item_custom(item)
    w_u32(item + off.m_iItemIDHigh, 0xFFFFFFFF)
    w_u32(item + off.m_iItemIDLow, 0xFFFFFFFF)
    w_u8 (item + off.m_bInitialized, 1)
    w_u8 (item + off.m_bDisallowSOC, 0)
    w_u8 (item + off.m_bRestoreCustomMat, 1)
end

local function refresh_econ(wpn)
    vcall_void_bool(wpn, 10, true)
    vcall_void_bool(wpn, 110, true)
end

local function apply_knife_model(wpn)
    if fnptr.set_model then
        local vdata = r_ptr(wpn + off.m_nSubclassID + 8)
        if valid(vdata) then
            local s = read_cstr(vdata + off.m_szWorldModel, 160)
            if s:find("models/") and s:find("%.vmdl") then fnptr.set_model(ffi.cast("void*", wpn), s) end
        end
    end
    if fnptr.set_mesh_mask then
        local node = r_ptr(wpn + off.m_pGameSceneNode)
        if valid(node) then fnptr.set_mesh_mask(ffi.cast("void*", node), 2) end
    end
end

local function set_knife_subclass(wpn, def_target, quality)
    local item = item_ptr(wpn)
    w_u16(item + off.m_iItemDefinitionIndex, def_target)
    w_i32(item + off.m_iEntityQuality, quality)
    w_u32(wpn + off.m_nSubclassID, subclass_hash(def_target))
    if fnptr.update_subclass then fnptr.update_subclass(ffi.cast("void*", wpn)) end
    apply_knife_model(wpn)
    return item
end

local function process_knife(wpn, def_target, paint, wear, seed, stat, statval)
    local item = set_knife_subclass(wpn, def_target, 3)
    mark_item_custom(item)
    write_fallback(wpn, paint, wear, seed, stat, statval)
    refresh_econ(wpn)
    vcall_void(wpn, 195)
end

local function apply_weapon_model(wpn)
    if fnptr.set_mesh_mask then
        local node = r_ptr(wpn + off.m_pGameSceneNode)
        if valid(node) then fnptr.set_mesh_mask(ffi.cast("void*", node), 2) end
    end
end

local function process_weapon(wpn, paint, wear, seed, stat, statval)
    mark_item_custom(item_ptr(wpn))
    write_fallback(wpn, paint, wear, seed, stat, statval)
    apply_weapon_model(wpn)
    if fnptr.update_subclass then fnptr.update_subclass(ffi.cast("void*", wpn)) end
    refresh_econ(wpn)
    vcall_void(wpn, 195)
end

local function restore_weapon(wpn)
    write_fallback(wpn, 0, 0.0001, 0, false)
    refresh_econ(wpn)
end

local function restore_knife(wpn, pawn)
    local def_target = (r_u8(pawn + off.m_iTeamNum) == 2) and 59 or 42
    set_knife_subclass(wpn, def_target, 0)
    write_fallback(wpn, 0, 0.0001, 0, false)
    refresh_econ(wpn)
    vcall_void(wpn, 195)
end

local ATTR_STRUCT = 72

local game_alloc, game_free
local function resolve_mem()
    if game_alloc then return true end
    pcall(function() ffi.cdef[[ void* GetModuleHandleA(const char*); ]] end)
    pcall(function() ffi.cdef[[ void* GetProcAddress(void*, const char*); ]] end)
    local tier0
    pcall(function() tier0 = ffi.C.GetModuleHandleA("tier0.dll") end)
    if not tier0 then return false end
    local pa, pf
    pcall(function() pa = ffi.C.GetProcAddress(tier0, "MemAlloc_AllocFunc") end)
    pcall(function() pf = ffi.C.GetProcAddress(tier0, "MemAlloc_FreeFunc") end)
    if not pa or not pf then return false end
    pcall(function()
        game_alloc = ffi.cast("void*(*)(size_t)", pa)
        game_free  = ffi.cast("void(*)(void*)", pf)
    end)
    return game_alloc ~= nil and game_free ~= nil
end

local function glove_attr_remove(item)
    local addr = item + off.m_AttributeList + off.m_Attributes
    local size = r_ptr(addr)
    local ptr  = r_ptr(addr + 8)
    w_u64(addr, 0); w_u64(addr + 8, 0)
    if game_free and size ~= 0 and valid(ptr) then
        pcall(function() game_free(ffi.cast("void*", ptr)) end)
    end
end

local function glove_attr_set(item, paint, seed, wear)
    glove_attr_remove(item)
    if paint <= 0 then return end
    if not resolve_mem() then return end
    wear = safe_wear(wear)
    local raw  = game_alloc(ATTR_STRUCT * 3)
    local bptr = tonumber(ffi.cast("uintptr_t", raw))
    if not bptr or bptr == 0 then return end
    for i = 0, (ATTR_STRUCT * 3) / 8 - 1 do w_u64(bptr + i * 8, 0) end
    local function mk(i, def, val)
        local b = bptr + i * ATTR_STRUCT
        w_u16(b + 0x30, def); w_f32(b + 0x34, val); w_f32(b + 0x38, val)
    end
    mk(0, 6, paint)
    mk(1, 7, seed)
    mk(2, 8, wear)
    local addr = item + off.m_AttributeList + off.m_Attributes
    w_u64(addr, 3)
    w_u64(addr + 8, bptr)
end

local function local_account_id(base)
    local ctrl = r_ptr(base + off.dwLocalPlayerController)
    if not valid(ctrl) then return 0 end
    local sid = r_u64(ctrl + off.m_steamID)
    return tonumber(sid % 0x100000000)
end

local glove_key, glove_apply = nil, 0
local function apply_gloves(base, pawn, gdef, paint, wear, seed)
    local g    = pawn + off.m_EconGloves
    local cur  = r_u16(g + off.m_iItemDefinitionIndex)
    local init = r_u8 (g + off.m_bInitialized)
    local key  = gdef.."|"..paint.."|"..floor(wear*100000).."|"..seed

    if key ~= glove_key then glove_key = key; glove_apply = 6 end
    local engine_reset = (cur ~= gdef) or (init == 0)
    if engine_reset and glove_apply <= 0 then glove_apply = 2 end

    if glove_apply > 0 then
        local acc = local_account_id(base)
        w_u8 (g + off.m_bInitialized, 0)
        w_u16(g + off.m_iItemDefinitionIndex, gdef)
        w_i32(g + off.m_iEntityQuality, 3)
        w_u32(g + off.m_iItemIDHigh, 0xFFFFFFFF)
        w_u32(g + off.m_iItemIDLow,  0xFFFFFFFF)
        w_u32(g + off.m_iAccountID, acc)
        w_u32(g + off.m_OriginalOwnerXuidLow, acc)
        glove_attr_set(g, paint, seed, wear)
        w_u8 (g + off.m_bDisallowSOC, 0)
        w_u8 (g + off.m_bRestoreCustomMat, 1)
        w_u8 (g + off.m_bInitialized, 1)
        w_u8 (pawn + off.m_bNeedToReApplyGloves, 1)
        if fnptr.set_body_group then
            pcall(function() fnptr.set_body_group(ffi.cast("void*", pawn), "first_or_third_person", 2) end)
        end
        glove_apply = glove_apply - 1
    end
end

local function reset_gloves(pawn)
    local g = pawn + off.m_EconGloves
    w_u8 (g + off.m_bInitialized, 0)
    w_u16(g + off.m_iItemDefinitionIndex, 0)
    glove_attr_remove(g)
    w_u8 (pawn + off.m_bNeedToReApplyGloves, 1)
    glove_key, glove_apply = nil, 0
    if fnptr.set_body_group then
        pcall(function() fnptr.set_body_group(ffi.cast("void*", pawn), "first_or_third_person", 2) end)
    end
end

local function handle_to_entity(elist, hnd)
    if not valid(elist) or hnd == 0 or hnd == 0xFFFFFFFF then return nil end
    local idx   = band(hnd, 0x7FFF)
    local chunk = r_ptr(elist + 8 * rshift(idx, 9) + 16); if not valid(chunk) then return nil end
    local e     = r_ptr(chunk + 112 * band(idx, 0x1FF))
    if valid(e) and valid(r_ptr(e)) then return e end
    return nil
end

local function pawn_alive(pawn)
    local ls = r_u8 (pawn + off.m_lifeState)
    local hp = r_i32(pawn + off.m_iHealth)
    return ls == 0 and hp > 0 and hp < 100000
end

local function in_game()
    local cl, so = off.dwNetworkGameClient, off.dwNetworkGameClient_signOnState
    if not cl or not so then return true end
    local eng = mem.GetModuleBase("engine2.dll"); if not eng then return true end
    local client = r_ptr(eng + cl); if not valid(client) then return false end
    return r_i32(client + so) == 6
end

local function get_live_local()
    local ok, lp = pcall(entities.GetLocalPlayer)
    if not ok or not lp then return nil end
    local alive = false
    pcall(function() alive = lp:IsAlive() end)
    return alive and lp or nil
end

local model_ffi_done = false
local function model_ffi()
    if model_ffi_done then return end
    model_ffi_done = true
    pcall(function() ffi.cdef[[
        typedef struct {
            uint32_t dwFileAttributes;
            uint32_t ftCreationLo, ftCreationHi;
            uint32_t ftAccessLo,   ftAccessHi;
            uint32_t ftWriteLo,    ftWriteHi;
            uint32_t nFileSizeHigh, nFileSizeLow;
            uint32_t dwReserved0,  dwReserved1;
            char     cFileName[260];
            char     cAlternateFileName[14];
        } AW_FIND_DATA;
        void*    FindFirstFileA(const char*, AW_FIND_DATA*);
        int      FindNextFileA(void*, AW_FIND_DATA*);
        int      FindClose(void*);
        uint32_t GetCurrentDirectoryA(uint32_t, char*);
        typedef struct {
            int32_t  m_nLength;
            uint32_t m_nAllocatedSize;
            union { char* p; char s[8]; } u;
        } AW_CBufStr;
    ]] end)
    pcall(function() ffi.cdef[[ void* GetModuleHandleA(const char*); ]] end)
    pcall(function() ffi.cdef[[ void* GetProcAddress(void*, const char*); ]] end)
end

local function find_invalid() return ffi.cast("void*", ffi.cast("intptr_t", -1)) end

local function models_root()
    model_ffi()
    local buf = ffi.new("char[?]", 1024)
    local n = ffi.C.GetCurrentDirectoryA(1024, buf)
    local cwd = ffi.string(buf, n)
    local root, count = cwd:gsub("[\\/]bin[\\/]win64.*$", "\\csgo")
    if count == 0 then return nil end
    return root
end

local SCAN_DIRS = { "characters", "agents", "models" }

local function scan_into(dir, names, paths)
    local fd = ffi.new("AW_FIND_DATA")
    local h = ffi.C.FindFirstFileA(dir .. "\\*", fd)
    if h == find_invalid() then return end
    repeat
        local nm = ffi.string(fd.cFileName)
        if nm ~= "." and nm ~= ".." then
            local full = dir .. "\\" .. nm
            if band(fd.dwFileAttributes, 0x10) ~= 0 then
                scan_into(full, names, paths)
            elseif nm:sub(-7) == ".vmdl_c" then
                local stem = nm:sub(1, #nm - 7)
                if not stem:lower():match("_arms?$") then
                    local p = full:lower():find("\\csgo\\", 1, true)
                    if p then
                        local rel = full:sub(p + 6):gsub("\\", "/")
                        rel = rel:sub(1, #rel - 2)
                        names[#names + 1] = stem
                        paths[#paths + 1] = rel
                    end
                end
            end
        end
    until ffi.C.FindNextFileA(h, fd) == 0
    ffi.C.FindClose(h)
end

local g_modelNames, g_modelPaths
local function scan_models()
    if g_modelNames then return g_modelNames, g_modelPaths end
    local names, paths = { "[ OFF ]" }, { "" }
    pcall(function()
        local root = models_root()
        if root then
            for _, sub in ipairs(SCAN_DIRS) do scan_into(root .. "\\" .. sub, names, paths) end
        end
    end)
    g_modelNames, g_modelPaths = names, paths
    return names, paths
end
local function rescan_models()
    g_modelNames, g_modelPaths = nil, nil
    return scan_models()
end

local g_IRS = nil
local PRECACHE_SIG = "40 53 55 57 48 81 EC 80 00 00 00 48 8B 01 49 8B E8 48 8B FA"
local function resolve_model_fns()
    if fnptr.precache and g_IRS and fnptr.cbuf_insert then return true end
    model_ffi()
    if not fn.precache then
        local a = mem.FindPattern("resourcesystem.dll", PRECACHE_SIG)
        if a and a ~= 0 then fn.precache = a end
    end
    if fn.precache and not fnptr.precache then
        fnptr.precache = ffi.cast("void*(*)(void*, void*, const char*)", fn.precache)
    end
    if not g_IRS then
        pcall(function()
            local rs = ffi.C.GetModuleHandleA("resourcesystem.dll")
            local ci = rs and ffi.C.GetProcAddress(rs, "CreateInterface")
            if ci then
                local CI = ffi.cast("void*(*)(const char*, int*)", ci)
                local irs = CI("ResourceSystem013", nil)
                if irs ~= nil then g_IRS = irs end
            end
        end)
    end
    if not fnptr.cbuf_insert then
        pcall(function()
            local t0 = ffi.C.GetModuleHandleA("tier0.dll")
            local ins = t0 and ffi.C.GetProcAddress(t0, "?Insert@CBufferString@@QEAAPEBDHPEBDH_N@Z")
            if ins then fnptr.cbuf_insert = ffi.cast("const char*(*)(void*, int, const char*, int, int)", ins) end
        end)
    end
    return fnptr.precache ~= nil and g_IRS ~= nil and fnptr.cbuf_insert ~= nil
end

local function precache_model(path)
    if path == nil or path == "" then return end
    if not resolve_model_fns() then return end
    local cb = ffi.new("AW_CBufStr")
    cb.m_nLength = 0
    cb.m_nAllocatedSize = 0xC0000008
    cb.u.p = nil
    pcall(function() fnptr.cbuf_insert(cb, 0, path, -1, 0) end)
    pcall(function() fnptr.precache(g_IRS, cb, "") end)
end

local function apply_local_model(pawn, lp)
    if not fnptr.set_model then return end

    if state.origModelPawn ~= pawn then
        state.origModelPawn     = pawn
        state.appliedLocalModel = nil
        state.overrideActive    = false
        state.origModelName     = nil
        if lp then pcall(function()
            local nm = lp:GetModelName()
            if type(nm) == "string" and nm:find("%.vmdl") then state.origModelName = nm end
        end) end
    end
    local path = state.localModel
    if path and path ~= "" then
        if state.appliedLocalModel == path then return end
        precache_model(path)
        pcall(function() fnptr.set_model(ffi.cast("void*", pawn), path) end)
        state.appliedLocalModel = path
        state.overrideActive    = true
    else
        if state.appliedLocalModel == "OFF" then return end
        if state.overrideActive and state.origModelName then
            precache_model(state.origModelName)
            pcall(function() fnptr.set_model(ffi.cast("void*", pawn), state.origModelName) end)
            state.overrideActive = false
        end
        state.appliedLocalModel = "OFF"
    end
end

local function run()
    local lp = get_live_local()
    if not lp or not in_game() then
        if next(state.applied) then state.applied = {} end
        return
    end

    local base = mem.GetModuleBase(DLL); if not base then return end
    local pawn = r_ptr(base + off.dwLocalPlayerPawn); if not valid(pawn) then return end
    if not valid(r_ptr(pawn + off.m_pGameSceneNode)) then return end

    if not pawn_alive(pawn) then
        if next(state.applied) then state.applied = {} end
        return
    end

    local ctrl = r_ptr(base + off.dwLocalPlayerController); if not valid(ctrl) then return end
    local myHandle = r_u32(ctrl + off.m_hPlayerPawn)
    if myHandle == 0 or myHandle == 0xFFFFFFFF then return end

    local elist = r_ptr(base + off.dwEntityList); if not valid(elist) then return end

    if handle_to_entity(elist, myHandle) ~= pawn then
        if next(state.applied) then state.applied = {} end
        return
    end

    local applied = state.applied

    apply_local_model(pawn, lp)

    local myTeam = r_u8(pawn + off.m_iTeamNum)
    if state.lastGloveTeam ~= myTeam then
        state.lastGloveTeam = myTeam
        glove_key = nil
    end

    if state.resetGlove then
        reset_gloves(pawn); state.resetGlove = false
    elseif state.gloveDef then
        local c = state.cfg[state.gloveDef]
        if c then apply_gloves(base, pawn, state.gloveDef, c.paint, c.wear, c.seed) end
    end

    local ws   = r_ptr(pawn + off.m_pWeaponServices); if not valid(ws) then return end
    local count= r_i32(ws + off.m_hMyWeapons)
    local arr  = r_ptr(ws + off.m_hMyWeapons + 8)
    if count<=0 or count>64 or not valid(arr) then return end

    local kdef = state.knifeDef
    local kc   = kdef and state.cfg[kdef]

    local did = false
    for i = 0, count - 1 do
        local wpn = handle_to_entity(elist, r_u32(arr + i*4))
        if wpn then
            if r_u32(wpn + off.m_hOwnerEntity) == myHandle then
                do
                    local def = r_u16(item_ptr(wpn) + off.m_iItemDefinitionIndex)
                    if is_knife(def) then
                        if state.resetKnife and not (kdef and kc) then
                            restore_knife(wpn, pawn); applied[wpn] = nil; state.resetKnife = false; did = true
                        elseif kdef and kc then
                            local s = "k|"..kdef.."|"..kc.paint.."|"..kc.wear.."|"..kc.seed.."|"..tostring(kc.stat).."|"..tostring(kc.statval or 0)
                            if applied[wpn] ~= s then
                                process_knife(wpn, kdef, kc.paint, kc.wear, kc.seed, kc.stat, kc.statval); applied[wpn]=s; did=true
                            end
                        end
                    else
                        if state.pendingReset[def] then
                            restore_weapon(wpn); applied[wpn] = nil; state.pendingReset[def] = nil; did = true
                        else
                            local c = state.cfg[def]
                            if c then
                                if c.paint > 0 then
                                    local s = "w|"..c.paint.."|"..c.wear.."|"..c.seed.."|"..tostring(c.stat).."|"..tostring(c.statval or 0)
                                    if applied[wpn] ~= s then
                                        process_weapon(wpn, c.paint, c.wear, c.seed, c.stat, c.statval); applied[wpn]=s; did=true
                                    end
                                else
                                    local s = "w|none"
                                    if applied[wpn] ~= s then
                                        restore_weapon(wpn); applied[wpn]=s; did=true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- sync viewmodel (first-person hand model)
    if off.m_hViewModel then
        local vmHnd = r_u32(pawn + off.m_hViewModel)
        if vmHnd ~= 0 and vmHnd ~= 0xFFFFFFFF then
            local vmEntity = handle_to_entity(elist, vmHnd)
            if vmEntity then
                local activeHnd = r_u32(ws + off.m_hActiveWeapon)
                if activeHnd ~= 0 and activeHnd ~= 0xFFFFFFFF then
                    local activeWpn = handle_to_entity(elist, activeHnd)
                    if activeWpn then
                        local def = r_u16(item_ptr(activeWpn) + off.m_iItemDefinitionIndex)
                        local c = state.cfg[def]
                        if c and c.paint > 0 then
                            w_i32(vmEntity + off.m_nFallbackPaintKit, c.paint)
                            w_f32(vmEntity + off.m_flFallbackWear, safe_wear(c.wear))
                            w_i32(vmEntity + off.m_nFallbackSeed, c.seed)
                            w_i32(vmEntity + off.m_nFallbackStatTrak, c.stat and (c.statval or 0) or -1)
                            if fnptr.set_mesh_mask then
                                local node = r_ptr(vmEntity + off.m_pGameSceneNode)
                                if valid(node) then fnptr.set_mesh_mask(ffi.cast("void*", node), 2) end
                            end
                        end
                    end
                end
            end
        end
    end
    if did and fnptr.regen_skins then fnptr.regen_skins() end
end

local function active_weapon_def()
    if not get_live_local() then return nil end
    local base = mem.GetModuleBase(DLL); if not base then return nil end
    local pawn = r_ptr(base + off.dwLocalPlayerPawn); if not valid(pawn) then return nil end
    local ws   = r_ptr(pawn + off.m_pWeaponServices); if not valid(ws) then return nil end
    local elist = r_ptr(base + off.dwEntityList)
    local wpn  = handle_to_entity(elist, r_u32(ws + off.m_hActiveWeapon)); if not wpn then return nil end
    return r_u16(item_ptr(wpn) + off.m_iItemDefinitionIndex)
end

local CFG_FILE = "awtech_config.txt"

local function file_write(path, data)
    local ok = false
    pcall(function()
        local f = file.Open(path, "w")
        if f then f:Write(data); f:Close(); ok = true end
    end)
    return ok
end

local function file_read(path)
    local data
    pcall(function()
        local f = file.Open(path, "r")
        if f then data = f:Read(); f:Close() end
    end)
    return data
end

local function serialize()
    local lines = { "AWCFG1",
                    "K " .. tostring(state.knifeDef or 0),
                    "G " .. tostring(state.gloveDef or 0) }
    for def, c in pairs(state.cfg) do
        lines[#lines + 1] = string.format("E %d %d %.6f %d %d %s %d",
            def, c.paint or 0, c.wear or 0.0001, c.seed or 0, c.stat and 1 or 0, c.kind or "weapon", c.statval or 0)
    end
    for k, v in pairs(state.opts) do
        local tv = type(v)
        local tag = (tv == "boolean") and "b" or (tv == "number") and "n" or "s"
        local sv  = (tv == "boolean") and (v and "1" or "0") or tostring(v)
        lines[#lines + 1] = string.format("O %s %s %s", k, tag, sv)
    end
    if state.localModel and state.localModel ~= "" then
        lines[#lines + 1] = "L " .. state.localModel
    end
    return table.concat(lines, "\n")
end

local function parse(str)
    if type(str) ~= "string" or not str:find("AWCFG1", 1, true) then return nil end
    local newCfg, kdef, gdef, opts, lmodel = {}, nil, nil, {}, nil
    for line in str:gmatch("[^\r\n]+") do
        local t = line:sub(1, 1)
        if t == "K" then
            local v = tonumber(line:match("^K%s+(%-?%d+)")); if v and v ~= 0 then kdef = v end
        elseif t == "G" then
            local v = tonumber(line:match("^G%s+(%-?%d+)")); if v and v ~= 0 then gdef = v end
        elseif t == "E" then
            local d, p, w, s, st, kind, sv =
                line:match("^E%s+(%-?%d+)%s+(%-?%d+)%s+([%d%.eE%+%-]+)%s+(%-?%d+)%s+(%d)%s+(%a+)%s*(%d*)")
            d, p, w, s = tonumber(d), tonumber(p), tonumber(w), tonumber(s)
            if d then
                newCfg[d] = { paint = p or 0, wear = w or 0.0001, seed = s or 0,
                              stat = (st == "1"), kind = kind or "weapon", statval = tonumber(sv) or 0 }
            end
        elseif t == "O" then
            local k, tag, v = line:match("^O%s+(%S+)%s+(%a)%s+(.*)$")
            if k then
                if     tag == "b" then opts[k] = (v == "1")
                elseif tag == "n" then opts[k] = tonumber(v) or 0
                else                   opts[k] = v end
            end
        elseif t == "L" then
            local v = line:match("^L%s+(.+)$")
            if v and v ~= "" then lmodel = v end
        end
    end
    return newCfg, kdef, gdef, opts, lmodel
end

function applyTable(newCfg, kdef, gdef, opts, lmodel)
    for def, c in pairs(state.cfg) do
        if c.kind == "weapon" and not newCfg[def] then state.pendingReset[def] = true end
    end
    if state.knifeDef and state.knifeDef ~= kdef then state.resetKnife = true end
    if state.gloveDef and state.gloveDef ~= gdef then state.resetGlove = true end
    state.cfg      = newCfg
    state.knifeDef = kdef
    state.gloveDef = gdef
    state.opts     = opts or {}
    state.localModel = lmodel
    state.appliedLocalModel = nil
    state.applied  = {}
end

local function save() return file_write(CFG_FILE, serialize()) end

local function load()
    local newCfg, kdef, gdef, opts, lmodel = parse(file_read(CFG_FILE))
    if not newCfg then return false end
    applyTable(newCfg, kdef, gdef, opts, lmodel)
    return true
end

local function commit()
    state.applied = {}
    save()
end

local C = {}
C.items     = ITEMS
C.names     = itemNames
C.defToItem = DEF_TO_ITEM

function C.skinList(def) return skin_list_for(def) end
function C.isKnife(def)  return is_knife(def) end
function C.activeDef()   return g_activeDef end
function C.knifeDef()    return state.knifeDef end
function C.getCfg(def)   return state.cfg[def] end

function C.apply(item, paint, wear, seed, stat, statval)
    if not item then return "nothing selected" end
    if item.kind == "glove" and item.def == 0 then
        state.cfg[0]     = nil
        state.gloveDef   = nil
        state.resetGlove = true
        commit()
        return "gloves: default"
    end
    state.cfg[item.def] = { paint = paint, wear = wear, seed = seed, stat = stat, statval = statval, kind = item.kind }
    if     item.kind == "knife" then state.knifeDef = item.def
    elseif item.kind == "glove" then state.gloveDef = item.def end
    commit()
    return string.format("applied: %s (paint %d)", item.name, paint)
end

function C.remove(item)
    if not item then return "nothing selected" end
    state.cfg[item.def] = nil
    if item.kind == "knife" then
        if state.knifeDef == item.def then state.knifeDef = nil end
        state.resetKnife = true
    elseif item.kind == "glove" then
        if state.gloveDef == item.def then state.gloveDef = nil end
        state.resetGlove = true
    else
        state.pendingReset[item.def] = true
    end
    commit()
    return "removed: " .. item.name
end

function C.resetAll()
    for def, c in pairs(state.cfg) do
        if c.kind == "weapon" then state.pendingReset[def] = true end
    end
    state.cfg        = {}
    state.knifeDef   = nil
    state.gloveDef   = nil
    state.resetKnife = true
    state.resetGlove = true
    commit()
    return "reset all"
end

function C.forceUpdate()
    state.applied = {}
    return "force update queued"
end

function C.clearConfig()
    C.resetAll()
    pcall(function() file.Delete(CFG_FILE) end)
    return "config cleared"
end

function C.loadConfig() return load() end
function C.getOpt(k)     return state.opts[k] end
function C.setOpt(k, v)  state.opts[k] = v; save() end

function C.modelList()     return scan_models() end
function C.refreshModels() return rescan_models() end
function C.getLocalModel() return state.localModel end
function C.setLocalModel(path)
    if path == nil or path == "" then state.localModel = nil
    else state.localModel = path end
    state.appliedLocalModel = nil
    save()
    return state.localModel
end

callbacks.Register("CreateMove", function()
    local okd, d = pcall(active_weapon_def); g_activeDef = okd and d or nil
    local ok, err = pcall(run)
    if not ok then print("[awtech-changer] error: " .. tostring(err)) end
end)

resolve()
pcall(resolve_model_fns)
local n = 0; for _ in pairs(SKINS) do n = n + 1 end
print(string.format("[awtech-changer] ready: %d weapons, set_model=%s", n, fn.set_model and "ok" or "NIL"))
local ok_root, root_str = pcall(models_root)
print(string.format("[awtech-changer] precache: fn=%s irs=%s cbuf=%s root=%s",
    fnptr.precache and "ok" or "NIL", g_IRS and "ok" or "NIL",
    fnptr.cbuf_insert and "ok" or "NIL", tostring(ok_root and root_str or "ERR")))

return C
