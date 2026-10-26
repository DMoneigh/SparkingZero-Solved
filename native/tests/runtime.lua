-- No game, loader or DLL is executed. These fakes exercise the Lua adapter contract.
local original_dofile = dofile
local protocol = original_dofile("DezsMinion/Scripts/protocol.lua")
local tests = 0
local function equal(actual, expected, label)
    tests = tests + 1
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function request(overrides)
    local values = {
        protocol = "1", session = string.rep("a", 32), sequence = "1", heartbeat = tostring(os.time()),
        armed = "1", health = "1", ki = "1", skill = "1", sparking = "1", fps = "1",
        side = "0", frame_rate = "120"
    }
    for key, value in pairs(overrides or {}) do values[key] = tostring(value) end
    local lines = {}
    for key, value in pairs(values) do lines[#lines + 1] = key .. "=" .. value end
    return table.concat(lines, "\n")
end
local parsed = assert(protocol.parse(request(), os.time()))
equal(parsed.armed, true, "armed parsed")
equal(parsed.frame_rate, 120, "FPS parsed")
equal(protocol.parse(request({health = "true"}), os.time()), nil, "invalid boolean rejected")
equal(protocol.parse(request({side = "2"}), os.time()), nil, "invalid side rejected")
equal(protocol.parse(request({frame_rate = "241"}), os.time()), nil, "invalid cap rejected")
equal(protocol.parse(request({heartbeat = tostring(os.time() - 4)}), os.time()), nil, "stale request rejected")
equal(protocol.parse(request({heartbeat = tostring(os.time() + 2)}), os.time()), nil, "future request rejected")
equal(protocol.parse(request({sequence = "1e10"}), os.time()), nil, "exponential sequence rejected")
equal(protocol.parse(request() .. "\nhealth=0", os.time()), nil, "duplicate rejected")
equal(protocol.parse(request() .. "\nexecute=anything", os.time()), nil, "unknown command rejected")
equal(protocol.parse(string.rep("a", 4097), os.time()), nil, "oversized request rejected")
equal(protocol.parse(request({session = "../../escape"}), os.time()), nil, "invalid session rejected")
equal(assert(protocol.parse(request({frame_rate = "0"}), os.time())).frame_rate, 0, "uncapped accepted")
local original_open = io.open
local output = ""
io.open = function()
    return {
        write = function(self, text) output = text; return self end,
        close = function() return true end
    }
end
equal(protocol.write("unused", {protocol = 1, message = "first\nsecond"}), true, "status write succeeds")
equal(output:match("complete=1\n$") ~= nil, true, "status completion marker")
equal(output:match("message=first second") ~= nil, true, "status cannot inject new lines")
io.open = function() return nil, "access denied", 13 end
local write_ok, write_error = protocol.write("unused", {protocol = 1})
equal(write_ok, nil, "status access error is not swallowed")
equal(write_error, "access denied", "status access error reported")
local read_ok, read_error = protocol.read_request("unused", os.time())
equal(read_ok, nil, "request access error blocks controls")
equal(read_error:match("access denied") ~= nil, true, "request access error reported")
io.open = original_open

local function object(fields)
    fields = fields or {}
    fields.IsValid = function(self) return self.valid ~= false end
    return fields
end
local function fixture()
    local f = {writes = 0, online = false, networked = false, controllers = {}, missing = nil, callbacks = 0}
    f.world = object({NetDriver = object({valid = false})})
    f.instance = object({
        IsA = function() return true end,
        GetOnlineBattleFlg = function() return f.online end,
        GetOnlineBattleObserver = function() return false end,
        IsOnlineBattleMatching = function() return f.matching or false end,
        IsOnlineBattleMatched = function() return false end,
        IsBattleMenuStandByTraining = function() return f.standby or false end
    })
    f.settings = object({
        cap = 60,
        GetFrameRateLimit = function(self) return self.cap end,
        SetFrameRateLimit = function(self, value) self.cap = value end,
        ApplyNonResolutionSettings = function() f.fps_applies = (f.fps_applies or 0) + 1 end
    })
    function f.newPawn(address, side)
        return object({
            hp = 40, ki = 20, skill = 1, stop = false, sparking = false,
            GetAddress = function() return address end,
            GetPlayerSide = function() return side end,
            IsA = function() return true end,
            GetWorld = function() return f.world end,
            GetFullName = function() return "Fake local fighter" end,
            GetMaxHPGaugeValue = function() return 40000 end,
            GetMaxSPGaugeValue = function() return 50000 end,
            GetMaxBlastStockCount = function() return 5 end,
            GetHPGaugeValue = function(self) return self.hp end,
            GetSPGaugeValue = function(self) return self.ki end,
            GetBlastStockCount = function(self) return self.skill end,
            SetHPGaugeValue = function(self, value) self.hp = value; f.writes = f.writes + 1 end,
            SetSPGaugeValue = function(self, value) self.ki = value; f.writes = f.writes + 1 end,
            SetBlastStockCount = function(self, value) self.skill = value; f.writes = f.writes + 1 end,
            IsSparkingTimeConsumeStop = function(self) return self.stop end,
            SetSparkingTimeConsumeStop = function(self, value) self.stop = value end,
            SetSparkingGaugeMax = function(self) self.gauge = 50000 end,
            IsSparkingModeState = function(self) return self.sparking end,
            DebugToSparkingMode = function(self) self.sparking = true end
        })
    end
    f.pawn = f.newPawn(100, 0)
    f.controller = object({Pawn = f.pawn, IsLocalController = function() return true end})
    f.controllers = {f.controller}
    f.request = assert(protocol.parse(request(), os.time()))
    dofile = function(path)
        assert(path:match("protocol.lua$"), "Only the protocol module is loaded")
        return {
            read_request = function() return f.request, f.reason end,
            write = function(_, fields) f.status = fields; return true end
        }
    end
    StaticFindObject = function(path)
        if path == f.missing then return object({valid = false}) end
        if path == "/Script/Engine.Default__GameplayStatics" then
            return object({GetGameInstance = function() return f.instance end})
        end
        if path == "/Script/Engine.Default__GameUserSettings" then
            return object({GetGameUserSettings = function() return f.settings end})
        end
        return object()
    end
    FindAllOf = function(name)
        equal(name, "BP_BattlePlayerController_C", "controller selector")
        return f.controllers
    end
    EngineTickAvailable = true
    LoopInGameThreadWithDelay = function(interval, callback)
        equal(interval, 16, "game-thread interval")
        f.tick = callback
    end
    original_dofile("DezsMinion/Scripts/main.lua")
    dofile = original_dofile
    return f
end

local f = fixture()
f.tick()
equal(f.status.state, "active", "active handshake")
equal(f.pawn.hp, 40000, "character max health")
equal(f.pawn.ki, 50000, "character max Ki")
equal(f.pawn.skill, 5, "character max skills, not hardcoded six")
equal(f.pawn.stop, true, "sparking timer frozen")
equal(f.pawn.sparking, true, "sparking entry requested")
equal(f.settings.cap, 120, "actual settings cap")
f.request.armed = false
f.tick()
equal(f.status.state, "disarmed", "disarm acknowledged")
equal(f.pawn.stop, false, "sparking flag restored")
equal(f.settings.cap, 60, "FPS restored")
equal(f.pawn.hp, 40000, "resources not rewound")

for _, guard in ipairs({"online", "matching", "standby", "networked"}) do
    f = fixture()
    if guard == "networked" then f.world.NetDriver.valid = true else f[guard] = true end
    f.tick()
    equal(f.status.state, "blocked", guard .. " blocked")
    equal(f.writes, 0, guard .. " no writes")
end

f = fixture()
f.controllers = {}
f.tick()
equal(f.status.state, "waiting", "no fighter")
equal(f.writes, 0, "no fighter no writes")
f = fixture()
f.controllers[2] = object({Pawn = f.newPawn(200, 0), IsLocalController = function() return true end})
f.tick()
equal(f.status.state, "waiting", "ambiguous fighters")
equal(f.writes, 0, "ambiguous fighters no writes")
f = fixture()
f.request.side = 1
f.tick()
equal(f.writes, 0, "wrong player side no writes")

f = fixture()
f.tick()
local old = f.pawn
f.controller.Pawn = f.newPawn(200, 0)
f.tick()
equal(old.stop, false, "old fighter flag restored on switch")
equal(f.controller.Pawn.hp, 40000, "new fighter replenished")
f.request = nil
f.reason = "Expired"
f.tick()
equal(f.controller.Pawn.stop, false, "heartbeat loss restores flag")
equal(f.settings.cap, 60, "heartbeat loss restores frame cap")
equal(f.status.state, "idle", "heartbeat loss acknowledged")

f = fixture()
f.missing = "/Script/SS.SSCharacter:SetHPGaugeValue"
f.tick()
equal(f.status.state, "error", "missing API reported")
equal(f.writes, 0, "missing API fails closed")
f.missing = nil
f.tick()
equal(f.writes, 0, "fault remains latched")

f = fixture()
f.pawn.GetMaxSPGaugeValue = function() return -1 end
f.tick()
equal(f.status.state, "error", "invalid max reported")
equal(f.writes, 0, "limits validated before writes")

f = fixture()
f.tick()
f.pawn.SetHPGaugeValue = function() error("injected adapter failure") end
f.tick()
equal(f.status.state, "error", "runtime failure reported")
equal(f.pawn.stop, false, "failure restores timer")
equal(f.settings.cap, 60, "failure restores FPS")

print("Passed " .. tests .. " Lua protocol and mocked-runtime assertions. No live gameplay was exercised.")
