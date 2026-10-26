-- Reflected game APIs, not memory offsets. See native/INSTRUCTIONS.txt for sources.
local source = debug.getinfo(1, "S").source:sub(2)
local script_dir = assert(source:match("^(.*[\\/])"), "Cannot determine mod directory")
local bridge = script_dir .. "..\\Bridge\\"
local protocol = dofile(script_dir .. "protocol.lua")
local runtime = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local fault, last_status, last_report = nil, "", 0
local sparking_owner, sparking_original = nil, nil
local fps_owner, fps_original = nil, nil
local last_session, last_sequence = "", -1
local last_sparking = false

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function status(kind, message, request, values)
    local now = os.time()
    local signature = kind .. message .. (request and request.session or "")
    if signature == last_status and now == last_report then return end
    last_status, last_report = signature, now
    local fields = {
        protocol = 1, runtime = runtime, heartbeat = now, state = kind,
        message = message, session = request and request.session or "",
        sequence = request and request.sequence or -1
    }
    for key, value in pairs(values or {}) do fields[key] = value end
    local ok, err = protocol.write(bridge .. "status.txt", fields)
    if not ok then error("Cannot publish runtime status: " .. tostring(err)) end
end

local function restore_sparking()
    if valid(sparking_owner) then
        sparking_owner:SetSparkingTimeConsumeStop(sparking_original)
    end
    sparking_owner, sparking_original = nil, nil
    last_sparking = false
end

local function restore_fps()
    if valid(fps_owner) then
        fps_owner:SetFrameRateLimit(fps_original)
        fps_owner:ApplyNonResolutionSettings()
    end
    fps_owner, fps_original = nil, nil
end

local function restore()
    restore_sparking()
    restore_fps()
end

local function require_function(path)
    if not valid(StaticFindObject(path)) then
        error("Unsupported game build: missing reflected function " .. path)
    end
end

local function check_apis()
    for _, name in ipairs({
        "GetPlayerSide", "GetMaxHPGaugeValue", "SetHPGaugeValue", "GetHPGaugeValue",
        "GetMaxSPGaugeValue", "SetSPGaugeValue", "GetSPGaugeValue",
        "GetMaxBlastStockCount", "SetBlastStockCount", "GetBlastStockCount",
        "IsSparkingModeState", "IsSparkingTimeConsumeStop", "SetSparkingTimeConsumeStop",
        "SetSparkingGaugeMax", "DebugToSparkingMode"
    }) do
        require_function("/Script/SS.SSCharacter:" .. name)
    end
    for _, name in ipairs({
        "GetOnlineBattleFlg", "GetOnlineBattleObserver", "IsOnlineBattleMatching",
        "IsOnlineBattleMatched", "IsBattleMenuStandByTraining"
    }) do
        require_function("/Script/SS.SSGameInstance:" .. name)
    end
    require_function("/Script/Engine.Controller:IsLocalController")
    require_function("/Script/Engine.GameplayStatics:GetGameInstance")
    for _, name in ipairs({"GetGameUserSettings", "GetFrameRateLimit", "SetFrameRateLimit", "ApplyNonResolutionSettings"}) do
        require_function("/Script/Engine.GameUserSettings:" .. name)
    end
end

local function find_player(side)
    local selected
    for _, controller in ipairs(FindAllOf("BP_BattlePlayerController_C") or {}) do
        if valid(controller) and controller:IsLocalController() then
            local pawn = controller.Pawn
            if valid(pawn) and pawn:IsA("/Script/SS.SSCharacter") and pawn:GetPlayerSide() == side then
                if selected and selected:GetAddress() ~= pawn:GetAddress() then
                    return nil, "Multiple local fighters match this side. Controls are suspended."
                end
                selected = pawn
            end
        end
    end
    return selected, "Waiting for the selected local fighter. Enter an offline battle."
end

local function offline(pawn)
    local world = pawn:GetWorld()
    if not valid(world) then return false, "Waiting for a valid battle world." end
    if valid(world.NetDriver) then return false, "Networked world detected. Controls are blocked." end
    local library = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not valid(library) then error("GameplayStatics is unavailable") end
    local instance = library:GetGameInstance(pawn)
    if not valid(instance) or not instance:IsA("/Script/SS.SSGameInstance") then
        return false, "Cannot verify the game instance. Controls are blocked."
    end
    if instance:GetOnlineBattleFlg() or instance:GetOnlineBattleObserver()
        or instance:IsOnlineBattleMatching() or instance:IsOnlineBattleMatched()
        or instance:IsBattleMenuStandByTraining() then
        return false, "Online battle, matchmaking or standby training detected. Controls are blocked."
    end
    return true
end

local function positive(value, label)
    if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
        error("Invalid " .. label .. " reported by this game build")
    end
    return value
end

local apis_checked = false
local function tick()
    local request, reason = protocol.read_request(bridge .. "request.txt", os.time())
    if not request then
        restore()
        status("idle", reason)
        return
    end
    if not request.armed then
        restore()
        status("disarmed", "Connected. Enable controls only in an offline battle.", request)
        return
    end
    if not apis_checked then
        check_apis()
        apis_checked = true
    end
    local pawn, waiting = find_player(request.side)
    if not pawn then
        restore()
        status("waiting", waiting, request)
        return
    end
    local allowed, blocked = offline(pawn)
    if not allowed then
        restore()
        status("blocked", blocked, request)
        return
    end
    if last_session ~= request.session then
        restore()
        last_session, last_sequence = request.session, -1
    end
    if sparking_owner and (not valid(sparking_owner) or sparking_owner:GetAddress() ~= pawn:GetAddress()) then
        restore_sparking()
    end

    -- Read and validate all requested limits before applying any gameplay writes.
    local hp = request.health and positive(pawn:GetMaxHPGaugeValue(), "max health") or nil
    local ki = request.ki and positive(pawn:GetMaxSPGaugeValue(), "max Ki") or nil
    local skill = request.skill and positive(pawn:GetMaxBlastStockCount(), "max skill count") or nil
    if skill and skill % 1 ~= 0 then error("Game returned a non-integer skill limit") end
    if hp then pawn:SetHPGaugeValue(hp) end
    if ki then pawn:SetSPGaugeValue(ki) end
    if skill then pawn:SetBlastStockCount(skill) end

    if request.sparking then
        if not sparking_owner then
            sparking_owner = pawn
            sparking_original = pawn:IsSparkingTimeConsumeStop()
        end
        pawn:SetSparkingTimeConsumeStop(true)
        pawn:SetSparkingGaugeMax()
        if not last_sparking and not pawn:IsSparkingModeState() then
            pawn:DebugToSparkingMode()
        end
        last_sparking = true
    else
        restore_sparking()
    end
    if request.fps then
        if not valid(fps_owner) then
            local settings_class = StaticFindObject("/Script/Engine.Default__GameUserSettings")
            if not valid(settings_class) then error("GameUserSettings class is unavailable") end
            fps_owner = settings_class:GetGameUserSettings()
            if not valid(fps_owner) then error("GameUserSettings instance is unavailable") end
            fps_original = fps_owner:GetFrameRateLimit()
            last_sequence = -1
        end
        if last_sequence ~= request.sequence then
            fps_owner:SetFrameRateLimit(request.frame_rate)
            fps_owner:ApplyNonResolutionSettings()
        end
    else
        restore_fps()
    end
    last_sequence = request.sequence
    status("active", "Controls applied to the selected offline fighter.", request, {
        player = pawn:GetFullName(), health = pawn:GetHPGaugeValue(),
        ki = pawn:GetSPGaugeValue(), skill = pawn:GetBlastStockCount(),
        sparking = pawn:IsSparkingModeState() and 1 or 0,
        fps = request.fps and request.frame_rate or "original"
    })
end

local function service()
    if fault then return end
    local ok, err = xpcall(tick, debug.traceback)
    if not ok then
        -- Latch failures instead of retrying unsafe writes each frame.
        fault = tostring(err)
        print("[DezsMinion] DISABLED: " .. fault .. "\n")
        for name, cleanup in pairs({sparking = restore_sparking, fps = restore_fps}) do
            local restored, cleanup_error = pcall(cleanup)
            if not restored then
                fault = fault .. " | Restore " .. name .. " failed: " .. tostring(cleanup_error)
                print("[DezsMinion] " .. tostring(cleanup_error) .. "\n")
            end
        end
        local written, write_error = protocol.write(bridge .. "status.txt", {
            protocol = 1, runtime = runtime, heartbeat = os.time(), state = "error", message = fault
        })
        if not written then print("[DezsMinion] Status write failed: " .. tostring(write_error) .. "\n") end
    end
end

assert(type(LoopInGameThreadWithDelay) == "function",
    "DezsMinion requires the documented UE4SS experimental loader with LoopInGameThreadWithDelay")
assert(EngineTickAvailable == true or ProcessEventAvailable == true,
    "No game-thread scheduler is available. Controls were not started.")
print("[DezsMinion] Loaded. Waiting for the native control panel; all controls start disarmed.\n")
LoopInGameThreadWithDelay(16, service)
