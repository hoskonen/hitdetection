-- Ensure global table exists
HitDetection = HitDetection or {}

-- Bootstrap: load the main logic
Script.ReloadScript("Scripts/HitDetection/HitDetection.lua")

-- Load CombatProbe
Script.ReloadScript("Scripts/CombatProbe/CombatProbe.lua")

-- Register gameplay start (primary path)
if UIAction and UIAction.RegisterEventSystemListener then
    System.LogAlways("[CombatProbe] init: registering OnGameplayStarted")
    UIAction.RegisterEventSystemListener(CombatProbe, "System", "OnGameplayStarted", "OnGameplayStarted")

    -- OPTIONAL: system event firehose for debugging timing (toggle in config)
    if CombatProbe.config.debugSysEvents then
        System.LogAlways("[CombatProbe] init: registering System event firehose")
        UIAction.RegisterEventSystemListener(CombatProbe, "System", "", "OnAnySystemEvent")
    end

    -- Also register HitDetection
    UIAction.RegisterEventSystemListener(HitDetection, "System", "OnGameplayStarted", "OnGameplayStarted")
else
    System.LogAlways("[CombatProbe] init: UIAction not available at init time")
end

-- Fallback: timer-start in case we missed the event due to load order
Script.SetTimer(2000, function()
    if CombatProbe and CombatProbe.Start and not CombatProbe._active then
        System.LogAlways("[CombatProbe] init: fallback timer → Start()")
        CombatProbe.Start()
    end
end)
