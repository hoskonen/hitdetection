-- CombatProbe — clean minimal scanner for combat + nearby NPC health deltas
CombatProbe                        = CombatProbe or {}

-- ---------- Config ----------
CombatProbe.config                 = {
    enabled        = true,
    pollEveryMs    = 150,  -- fast edge poll
    sampleEveryMs  = 500,  -- slow probe while in combat
    scanRadius     = 8.0,  -- meters
    maxPrint       = 4,    -- lines per sample
    logHeartbeat   = true, -- “… in combat (heartbeat)”
    dumpEntityOnce = true, -- one-time basic dump per entity
}

CombatProbe.config.dumpFactionOnce = true -- show faction/superfaction/archetype once per enemy
CombatProbe.config.dumpDerivedOnce = true -- show STR/AGI/CHA once per enemy

-- ---------- State ----------
CombatProbe._active                = false
CombatProbe._inCombat              = false
CombatProbe._player                = nil
CombatProbe._lastSampleMs          = 0
CombatProbe._lastEnemyHP           = {} -- [entityId] -> last hp
CombatProbe._dumpedEntities        = {} -- [entityId] -> true
CombatProbe._lastPlayerHealth      = nil
CombatProbe._lastPlayerStamina     = nil
CombatProbe._fallbackMs            = 0
CombatProbe._hpGetterById          = CombatProbe._hpGetterById or {} -- [entityId] -> function(e) -> number|nil
CombatProbe._playerMetaDumped      = false
CombatProbe._lastPrimaryId         = nil

-- ---------- Utils ----------
local function Log(s) System.LogAlways("[CombatProbe] " .. tostring(s)) end

local function Try(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function Round(x, p)
    local m = 10 ^ (p or 1)
    return math.floor((x or 0) * m + 0.5) / m
end

local function NowMs()
    local t = Try(function() return Script and Script.GetTime and Script.GetTime() end)
    if type(t) == "number" then return math.floor(t * 1000) end
    CombatProbe._fallbackMs = CombatProbe._fallbackMs + (CombatProbe.config.pollEveryMs or 150)
    return CombatProbe._fallbackMs
end

local function ResolveHpGetter(e)
    -- A: soul:GetHealth()
    if e.soul and type(e.soul.GetHealth) == "function" then
        return function(ent)
            local ok, v = pcall(ent.soul.GetHealth, ent.soul); return ok and v or nil
        end
    end
    -- B: soul:GetState("health")
    if e.soul and type(e.soul.GetState) == "function" then
        return function(ent)
            local ok, v = pcall(ent.soul.GetState, ent.soul, "health"); return ok and v or nil
        end
    end
    -- C: actor:GetHealth()
    if e.actor and type(e.actor.GetHealth) == "function" then
        return function(ent)
            local ok, v = pcall(ent.actor.GetHealth, ent.actor); return ok and v or nil
        end
    end
    -- D: entity:GetHealth() (rare)
    if type(e.GetHealth) == "function" then
        return function(ent)
            local ok, v = pcall(ent.GetHealth, ent); return ok and v or nil
        end
    end
    return nil
end

local function GetEnemyHp(e)
    local id = e.id or tostring(e)
    local getter = CombatProbe._hpGetterById[id]
    if getter == nil then
        getter = ResolveHpGetter(e)
        CombatProbe._hpGetterById[id] = getter or false -- cache failure too
    end
    return getter and getter(e) or nil
end

local function DumpEntityOnce(e)
    if not CombatProbe.config.dumpEntityOnce then return end
    local id = e.id or tostring(e)
    if CombatProbe._dumpedEntities[id] then return end
    CombatProbe._dumpedEntities[id] = true

    local name                      = (e.GetName and Try(e.GetName, e)) or "?"
    local class                     = e.class or (e.GetClass and Try(e.GetClass, e)) or "?"
    local hp                        = GetEnemyHp(e)

    Log(("dump: id=%s name=%s class=%s AI=%s soul=%s hp=%s")
        :format(tostring(id), tostring(name), tostring(class),
            e.AI and "yes" or "no", e.soul and "yes" or "no",
            hp and Round(hp, 1) or "?"))

    -- Faction / Superfaction / Archetype (once)
    if CombatProbe.config.dumpFactionOnce and e.soul then
        local factionId    = Try(e.soul.GetFactionID, e.soul)
        local superCurrent = Try(e.soul.GetSuperfaction, e.soul, "Current")
        local superOrig    = Try(e.soul.GetSuperfaction, e.soul, "Original")
        local archetype    = Try(e.soul.GetArchetype, e.soul)
        local archName     = (type(archetype) == "table" and (archetype.name or archetype.class or archetype.id)) or
            tostring(archetype)
        Log(("meta: faction=%s super(Current)=%s super(Original)=%s archetype=%s")
            :format(tostring(factionId), tostring(superCurrent), tostring(superOrig), tostring(archName)))
    end

    -- Derived stats (once)
    if CombatProbe.config.dumpDerivedOnce and e.soul and type(e.soul.GetDerivedStat) == "function" then
        local ctx, used = {}, {}
        local str = select(2, pcall(e.soul.GetDerivedStat, e.soul, "str", ctx, used))
        local agi = select(2, pcall(e.soul.GetDerivedStat, e.soul, "agi", ctx, used))
        local cha = select(2, pcall(e.soul.GetDerivedStat, e.soul, "cha", ctx, used))
        Log(("derived: STR=%s AGI=%s CHA=%s")
            :format(str and Round(str, 2) or "?", agi and Round(agi, 2) or "?", cha and Round(cha, 2) or "?"))
    end
end


-- Resolve/get player once, refresh if handle invalid
function CombatProbe.GetPlayer()
    local p = CombatProbe._player
    if p and System.GetEntity and System.GetEntity(p.id) then return p end
    if Game and Game.GetPlayer then
        p = Try(Game.GetPlayer, Game)
    end
    if not p then
        p = System.GetEntityByName and (System.GetEntityByName("Henry") or System.GetEntityByName("dude")) or nil
    end
    CombatProbe._player = p
    return p
end

-- Heuristics
local function GetPlayerPos(p) return (p and p.GetWorldPos) and Try(p.GetWorldPos, p) or nil end
local function GetEntitiesNear(pos, r)
    return (pos and System.GetEntitiesInSphere) and
        (Try(System.GetEntitiesInSphere, pos, r) or {}) or {}
end
local function Dist(a, b)
    if System.GetDistance then return Try(System.GetDistance, a, b) end
    if a and b and a.x and b.x then
        local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    return nil
end
local function IsHostile(e, player) return (e and e ~= player and (e.AI or e.soul)) or false end

local function DumpEntityOnce(e)
    if not CombatProbe.config.dumpEntityOnce then return end
    local id = e.id or tostring(e)
    if CombatProbe._dumpedEntities[id] then return end
    CombatProbe._dumpedEntities[id] = true
    local name                      = (e.GetName and Try(e.GetName, e)) or "?"
    local class                     = e.class or (e.GetClass and Try(e.GetClass, e)) or "?"
    local hp                        = e.soul and Try(function() return e.soul:GetHealth() end) or nil
    Log(("dump: id=%s name=%s class=%s AI=%s soul=%s hp=%s")
        :format(tostring(id), tostring(name), tostring(class), e.AI and "yes" or "no", e.soul and "yes" or "no",
            hp and Round(hp, 1) or "?"))
end

-- Ray from camera forward to pick what's under the crosshair
local function PickByCrosshair(player, maxDist)
    if not (System.RayWorldIntersection and System.GetViewCameraPos and System.GetViewCameraDir) then return nil end
    local camPos = Try(System.GetViewCameraPos)
    local camDir = Try(System.GetViewCameraDir)
    if not (camPos and camDir) then return nil end
    local to = { x = camPos.x + camDir.x * maxDist, y = camPos.y + camDir.y * maxDist, z = camPos.z + camDir.z * maxDist }
    -- ent_all / rwi_colltype_any style flags vary by build; pass nil -> engine default
    local ok, hits = pcall(System.RayWorldIntersection, camPos,
        { x = to.x - camPos.x, y = to.y - camPos.y, z = to.z - camPos.z }, nil, nil, nil, nil)
    if not ok or not hits or not hits[1] then return nil end
    local h = hits[1]
    -- CRITICAL: some builds return entityId or entity; support both
    local e = h.entity or (h.entityId and System.GetEntity and System.GetEntity(h.entityId)) or nil
    return e
end

-- Compute a score for “good target”: in front, near center, close distance, sticky to last pick
local function ScoreCandidate(player, ppos, e, lastPrimaryId)
    if not (e and e.GetWorldPos) then return -1e9 end
    local epos = Try(e.GetWorldPos, e)
    if not epos then return -1e9 end

    -- Distance
    local d = Dist(ppos, epos) or 999

    -- Facing (use camera forward)
    local camDir = Try(System.GetViewCameraDir) or { x = 0, y = 1, z = 0 }
    local v = { x = epos.x - ppos.x, y = epos.y - ppos.y, z = epos.z - ppos.z }
    local vl = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) + 1e-6
    local dot = (v.x * camDir.x + v.y * camDir.y + v.z * camDir.z) / vl -- [-1..1], 1=straight ahead

    -- Project to screen for center bias if available
    local centerBias = 0
    if System.ProjectToScreen then
        local sOk, sx, sy = pcall(function()
            local sx, sy, _ = System.ProjectToScreen(epos)
            return sx, sy
        end)
        if sOk and sx and sy then
            local dx = (sx - 50.0) / 50.0 -- 0..100 → -1..1
            local dy = (sy - 50.0) / 50.0
            local dist2 = dx * dx + dy * dy
            centerBias = -dist2 -- nearer center → less penalty
        end
    end

    -- Dead gets huge penalty (hp==0)
    local hp = GetEnemyHp(e)
    local deadPenalty = (hp == 0) and -1000 or 0

    -- Sticky bonus if same as previous primary
    local sticky = ((e.id or e) == lastPrimaryId) and 0.5 or 0

    -- Combine: larger is better
    -- weights: facing more important than distance; center helps; dead is bad
    local score = (dot * 2.0) + (centerBias * 0.75) + (sticky) - (d * 0.15) + deadPenalty
    return score
end

local function PickPrimary(player, hostiles)
    local ppos = GetPlayerPos(player)
    if not ppos or #hostiles == 0 then return nil end

    -- 1) Crosshair pick wins if it’s one of our hostiles
    local underCross = PickByCrosshair(player, 6.0)
    if underCross then
        for _, e in ipairs(hostiles) do
            if e == underCross then return e end
        end
    end

    -- 2) Score-based pick
    local best, bestScore = nil, -1e9
    for _, e in ipairs(hostiles) do
        local s = ScoreCandidate(player, ppos, e, CombatProbe._lastPrimaryId)
        if s > bestScore then
            best, bestScore = e, s
        end
    end
    return best
end


-- UH-style combat predicate (danger -> combat -> actor)
local function IsInCombat(soul, player)
    if soul and soul.IsInCombatDanger then
        local v = Try(soul.IsInCombatDanger, soul)
        if v == 1 or v == true then return true end
    end
    if soul and soul.IsInCombat then
        local v = Try(soul.IsInCombat, soul)
        if v == 1 or v == true then return true end
    end
    local actor = player and player.actor
    if actor and actor.IsInCombat then
        local v = Try(actor.IsInCombat, actor)
        if v == 1 or v == true then return true end
    end
    return false
end

-- ---------- Core check ----------
function CombatProbe.Check()
    local player = CombatProbe.GetPlayer()
    if not (player and player.soul) then return end

    local inCombat = IsInCombat(player.soul, player)

    if inCombat and not CombatProbe._inCombat then
        CombatProbe._playerMetaDumped  = false -- reset at combat start
        CombatProbe._inCombat          = true
        CombatProbe._lastPlayerHealth  = Try(function() return player.soul:GetHealth() end)
        CombatProbe._lastPlayerStamina = Try(function()
            return (player.soul.GetStamina and player.soul:GetStamina()) or
                (player.soul.GetExhaust and player.soul:GetExhaust())
        end)
        Log(("⚔️ Entered combat (hp=%s st=%s)"):format(
            CombatProbe._lastPlayerHealth and Round(CombatProbe._lastPlayerHealth, 1) or "?",
            CombatProbe._lastPlayerStamina and Round(CombatProbe._lastPlayerStamina, 1) or "?"))

        if not CombatProbe._playerMetaDumped and player and player.soul then
            CombatProbe._playerMetaDumped = true
            local pf                      = Try(player.soul.GetFactionID, player.soul)
            local pa                      = Try(player.soul.GetArchetype, player.soul)
            local archName                = (type(pa) == "table" and (pa.name or pa.class or pa.id)) or tostring(pa)
            -- Try both short and long derived keys; some builds differ
            local ctx, used               = {}, {}
            local pstr                    = player.soul.GetDerivedStat and
                (select(2, pcall(player.soul.GetDerivedStat, player.soul, "str", ctx, used)) or select(2, pcall(player.soul.GetDerivedStat, player.soul, "strength", ctx, used)))
            local pagi                    = player.soul.GetDerivedStat and
                (select(2, pcall(player.soul.GetDerivedStat, player.soul, "agi", ctx, used)) or select(2, pcall(player.soul.GetDerivedStat, player.soul, "agility", ctx, used)))
            Log(("player: faction=%s archetype=%s STR=%s AGI=%s")
                :format(tostring(pf), tostring(archName),
                    pstr and Round(pstr, 2) or "?", pagi and Round(pagi, 2) or "?"))
        end
    elseif (not inCombat) and CombatProbe._inCombat then
        CombatProbe._inCombat = false
        CombatProbe._lastEnemyHP = {}
        Log("🕊️ Left combat")
        CombatProbe._playerMetaDumped = false
    elseif inCombat and CombatProbe.config.logHeartbeat then
        Log("… in combat (heartbeat)")
    end

    -- Optional: player meta once on entry
    if player.soul then
        local pf = Try(player.soul.GetFactionID, player.soul)
        local pa = Try(player.soul.GetArchetype, player.soul)
        local archName = (type(pa) == "table" and (pa.name or pa.class or pa.id)) or tostring(pa)
        local ctx, used = {}, {}
        local pstr = player.soul.GetDerivedStat and
            select(2, pcall(player.soul.GetDerivedStat, player.soul, "str", ctx, used)) or nil
        local pagi = player.soul.GetDerivedStat and
            select(2, pcall(player.soul.GetDerivedStat, player.soul, "agi", ctx, used)) or nil
        Log(("player: faction=%s archetype=%s STR=%s AGI=%s")
            :format(tostring(pf), tostring(archName),
                pstr and Round(pstr, 2) or "?", pagi and Round(pagi, 2) or "?"))
    end


    if not CombatProbe._inCombat then return end

    -- Rate-limited sampling
    local now = NowMs()
    local period = CombatProbe.config.sampleEveryMs or 500
    if CombatProbe._lastSampleMs == 0 then CombatProbe._lastSampleMs = now - period end
    if now - CombatProbe._lastSampleMs < period then return end
    CombatProbe._lastSampleMs = now

    local ok, err = pcall(CombatProbe.Sample)
    if not ok then Log("[ERR] Sample(): " .. tostring(err)) end
end

-- ---------- Probe scan ----------
function CombatProbe.Sample()
    local player = CombatProbe.GetPlayer()
    if not player then
        Log("sample: no player"); return
    end
    local ppos = GetPlayerPos(player)
    if not ppos then
        Log("sample: no player pos"); return
    end

    local near = GetEntitiesNear(ppos, CombatProbe.config.scanRadius)
    local hostiles = {}
    for _, e in ipairs(near) do
        if IsHostile(e, player) then hostiles[#hostiles + 1] = e end
    end
    if #hostiles == 0 then
        Log("sample: no hostiles in radius"); return
    end

    local primary = PickPrimary(player, hostiles)
    if primary then CombatProbe._lastPrimaryId = primary.id or primary end

    local printed = 0
    for _, e in ipairs(hostiles) do
        if printed >= CombatProbe.config.maxPrint then break end
        local id   = e.id or tostring(e)
        local name = (e.GetName and Try(e.GetName, e)) or "?"
        local epos = (e.GetWorldPos and Try(e.GetWorldPos, e)) or nil
        local dist = (epos and Dist(ppos, epos)) or nil
        local hp   = GetEnemyHp(e)
        local last = CombatProbe._lastEnemyHP[id]
        local dhp  = (hp ~= nil and last ~= nil) and Round(hp - last, 1) or 0
        if hp ~= nil then CombatProbe._lastEnemyHP[id] = hp end

        local mark = (e == primary) and "★ " or "  "
        Log(("%srow: 👺[%s] d=%s hp=%s Δhp=%+s")
            :format(mark, tostring(name), dist and Round(dist, 2) or "?", hp ~= nil and Round(hp, 1) or "?", dhp))

        DumpEntityOnce(e)
        printed = printed + 1
    end

    -- Optional: show only the primary row per sample. Flip this on if you want less noise.
    -- if primary then
    --   hostiles = { primary } ; printed = 0
    --   -- (repeat the same row log for 'primary' only)
    -- end
end

-- ---------- Poller / lifecycle ----------
function CombatProbe._Tick()
    local ok, err = pcall(CombatProbe.Check)
    if not ok then Log("[ERR] _Tick/Check: " .. tostring(err)) end
    Script.SetTimerForFunction(CombatProbe.config.pollEveryMs, "CombatProbe._Tick")
end

_G["CombatProbe._Tick"] = CombatProbe._Tick

function CombatProbe.Start()
    if CombatProbe._active or not CombatProbe.config.enabled then return end
    CombatProbe._active = true
    Log(("start: poll=%dms sample=%dms radius=%.1fm"):format(
        CombatProbe.config.pollEveryMs, CombatProbe.config.sampleEveryMs, CombatProbe.config.scanRadius))
    Script.SetTimerForFunction(CombatProbe.config.pollEveryMs, "CombatProbe._Tick")
end

function CombatProbe.Stop()
    if not CombatProbe._active then return end
    CombatProbe._active = false
    Log("stop")
end

function CombatProbe.OnGameplayStarted()
    Log("OnGameplayStarted → Start()")
    CombatProbe.Start()
end
