-- Minimal polling demo (no config). Starts immediately on game load.
-- Uses Unworthy Hands–style resolver + HS_RIGHT / HS_LEFT slots.
-- Logs on state changes and exposes simple hooks you can edit.

HitDetection             = HitDetection or {}

-- === Tweak for your friend ===
local TARGET_WEAPON_NAME = "short_sword" -- case-insensitive substring match on item *name*
local POLL_INTERVAL_MS   = 3000          -- 3 seconds

-- Prefer engine constants if present; fall back to common slot names
local SLOT_RIGHT         = rawget(_G, "HS_RIGHT") or "RightWeapon"
local SLOT_LEFT          = rawget(_G, "HS_LEFT") or "LeftWeapon"
local SLOT_RIGHT_LABEL   = rawget(_G, "HS_RIGHT") and "HS_RIGHT" or "RightWeapon"
local SLOT_LEFT_LABEL    = rawget(_G, "HS_LEFT") and "HS_LEFT" or "LeftWeapon"

-- Internal state (used to avoid log spam)
HitDetection._active     = false
HitDetection._lastMatch  = nil  -- boolean | nil
HitDetection._lastName   = nil
HitDetection._lastSlot   = nil

-- ===== Logging & safety =====================================================

local function Log(msg) System.LogAlways("[HitDetection] " .. tostring(msg)) end

local function SafeCall(fn, ...)
    if type(fn) == "function" then
        local ok, err = pcall(fn, ...)
        if not ok then Log("Hook error: " .. tostring(err)) end
    end
end

-- ===== Player / item helpers ===============================================

local function GetPlayer()
    return System.GetEntityByName("Henry") or System.GetEntityByName("dude")
end

-- UH-style resolver: player.human:GetItemInHand(slot) → ItemManager.GetItem(id)
local function _getItemInfo(player, slot)
    if not player or not player.human or not player.human.GetItemInHand then return nil end

    local okId, id = pcall(function() return player.human:GetItemInHand(slot) end)
    if not okId or not id then return nil end

    local okItem, item = pcall(function() return ItemManager.GetItem(id) end)
    if not okItem or not item then return nil end

    local class  = item.class and tostring(item.class) or nil
    local name   = (class and ItemManager.GetItemName and ItemManager.GetItemName(item.class)) or nil
    local iid    = item.id and tostring(item.id) or nil
    local health = item.health or 0
    local amount = item.amount or 1

    return {
        id     = id,
        item   = item,
        class  = class,
        name   = name,
        iid    = iid,
        health = health,
        amount = amount,
    }
end

-- Prefer right hand; fall back to left
local function GetHeldItemInfo(player)
    local infoR = _getItemInfo(player, SLOT_RIGHT)
    if infoR then return infoR, SLOT_RIGHT_LABEL end

    local infoL = _getItemInfo(player, SLOT_LEFT)
    if infoL then return infoL, SLOT_LEFT_LABEL end

    return nil, nil
end

-- ===== Hooks your friend can edit ==========================================

function HitDetection.OnMatch(info, slotLabel)
    -- Runs once when we transition into MATCH ✅ (name contains TARGET_WEAPON_NAME)
    -- Example:
    -- System.LogAlways("[HitDetection] >>> MATCH action here for " .. (info.name or "?"))
end

function HitDetection.OnNoMatch(info, slotLabel)
    -- Runs once when we transition into NO MATCH ❌ (while still holding an item)
end

function HitDetection.OnHeldNone()
    -- Runs once when hands become empty / unresolved
end

-- ===== Core check ===========================================================

function HitDetection.Check()
    local player = GetPlayer()
    if not player then
        if HitDetection._lastMatch ~= false then
            Log("No player found")
            HitDetection._lastMatch = false
            HitDetection._lastName  = nil
            HitDetection._lastSlot  = nil
        end
        return
    end

    local info, slotLabel = GetHeldItemInfo(player)
    local heldName = info and info.name or nil

    if not heldName then
        if HitDetection._lastMatch ~= false then
            Log("No item in hands (or could not resolve)")
            SafeCall(HitDetection.OnHeldNone)
            HitDetection._lastMatch = false
            HitDetection._lastName  = nil
            HitDetection._lastSlot  = nil
        end
        return
    end

    -- Hardcoded substring match on name (case-insensitive)
    local t = string.lower(TARGET_WEAPON_NAME or "")
    local isMatch = (t ~= "") and (string.find(string.lower(heldName), t, 1, true) ~= nil)

    -- Log only on state change or when slot/name changed
    if HitDetection._lastMatch ~= isMatch
        or HitDetection._lastName ~= heldName
        or HitDetection._lastSlot ~= slotLabel then
        Log(string.format("holding '%s' (class=%s, slot=%s) → %s",
            heldName, info.class or "?", slotLabel or "?",
            isMatch and "MATCH ✅" or "NO MATCH ❌"))

        if isMatch then
            SafeCall(HitDetection.OnMatch, info, slotLabel)
        else
            SafeCall(HitDetection.OnNoMatch, info, slotLabel)
        end

        HitDetection._lastMatch = isMatch
        HitDetection._lastName  = heldName
        HitDetection._lastSlot  = slotLabel
    end
end

-- ===== Poller ==============================================================

function HitDetection.PollingTick()
    if not HitDetection._active then return end
    HitDetection.Check()
    Script.SetTimerForFunction(POLL_INTERVAL_MS, "HitDetection.PollingTick")
end

_G["HitDetection.PollingTick"] = HitDetection.PollingTick

function HitDetection.Start()
    if HitDetection._active then
        Log("Polling already active")
        return
    end
    HitDetection._active = true
    Log(string.format("Started polling every %.1fs for target '%s' (slots: %s/%s)",
        POLL_INTERVAL_MS / 1000, TARGET_WEAPON_NAME, SLOT_RIGHT_LABEL, SLOT_LEFT_LABEL))
    Script.SetTimerForFunction(POLL_INTERVAL_MS, "HitDetection.PollingTick")
end

function HitDetection.Stop()
    if not HitDetection._active then
        Log("Polling already stopped")
        return
    end
    HitDetection._active = false
    Log("Stopped polling")
end

-- Convenience: change the match target at runtime (optional)
function HitDetection.SetTarget(name)
    TARGET_WEAPON_NAME = tostring(name or "")
    Log("Target changed to '" .. TARGET_WEAPON_NAME .. "'")
    HitDetection._lastMatch = nil -- force a log next tick
end

-- ===== Game lifecycle =======================================================

function HitDetection.OnGameplayStarted(actionName, eventName, argTable)
    Log("OnGameplayStarted → initializing")
    HitDetection.Start()
end
