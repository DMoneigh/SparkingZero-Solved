local protocol = {}
local keys = {
    protocol = true, session = true, sequence = true, heartbeat = true, armed = true,
    health = true, ki = true, sparking = true, fps = true, skill = true,
    frame_rate = true, side = true
}

function protocol.parse(text, now)
    if #text > 4096 then return nil, "Control request is too large." end
    local fields = {}
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^([a-z_]+)=([^\r\n]*)$")
        if not key or not keys[key] or fields[key] ~= nil then
            return nil, "Invalid or duplicate control field."
        end
        fields[key] = value
    end
    for key in pairs(keys) do
        if fields[key] == nil then return nil, "Incomplete control request: " .. key end
    end
    if fields.protocol ~= "1" then return nil, "Unsupported control protocol." end
    if not fields.session:match("^[a-f0-9]+$") or #fields.session ~= 32 then
        return nil, "Invalid control-panel session."
    end
    for _, key in ipairs({"sequence", "heartbeat", "frame_rate", "side"}) do
        if not fields[key]:match("^%d+$") then return nil, "Invalid number: " .. key end
        fields[key] = tonumber(fields[key])
        if not fields[key] or fields[key] > 9007199254740991 then return nil, "Number out of range: " .. key end
    end
    if now - fields.heartbeat > 3 or fields.heartbeat - now > 1 then
        return nil, "Control-panel heartbeat expired. Controls released."
    end
    if fields.side ~= 0 and fields.side ~= 1 then return nil, "Invalid player side." end
    if fields.frame_rate ~= 0 and (fields.frame_rate < 30 or fields.frame_rate > 240) then
        return nil, "Frame cap must be 0 (uncapped) or 30-240."
    end
    for _, key in ipairs({"armed", "health", "ki", "sparking", "fps", "skill"}) do
        if fields[key] ~= "0" and fields[key] ~= "1" then return nil, "Invalid toggle: " .. key end
        fields[key] = fields[key] == "1"
    end
    return fields
end

function protocol.read_request(path, now)
    local file, err, code = io.open(path, "r")
    if not file then
        if code == 2 then return nil, "Waiting for the native control panel." end
        return nil, "Cannot read control request: " .. tostring(err)
    end
    local text, read_error = file:read(4097)
    local closed, close_error = file:close()
    if not closed then return nil, "Cannot close control request: " .. tostring(close_error) end
    if not text then return nil, "Empty or unreadable control request: " .. tostring(read_error or "empty file") end
    return protocol.parse(text, now)
end

function protocol.write(path, values)
    local file, err = io.open(path, "w")
    if not file then return nil, err end
    local lines = {}
    for key, value in pairs(values) do
        lines[#lines + 1] = key .. "=" .. tostring(value):gsub("[\r\n]", " ")
    end
    table.sort(lines)
    local written, write_error = file:write(table.concat(lines, "\n") .. "\ncomplete=1\n")
    local closed, close_error = file:close()
    if not written then return nil, write_error end
    if not closed then return nil, close_error end
    return true
end

return protocol
