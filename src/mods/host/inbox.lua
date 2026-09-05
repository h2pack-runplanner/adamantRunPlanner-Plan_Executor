-- The module inbox is one fixed slot. It reads a bounded file only when the
-- session explicitly asks for a new-run plan or an inspection.

local inbox = {}
inbox.ACTIVE_SLOT = "active.runplanner.json"
inbox.MAX_BYTES = 1048576

local function slotPath(root, pathApi)
    if type(root) ~= "string" or root == "" then error("inbox root must be non-empty", 3) end
    if type(pathApi) ~= "table" or type(pathApi.combine) ~= "function" then
        error("inbox requires rom.path.combine", 3)
    end
    return pathApi.combine(root, inbox.ACTIVE_SLOT)
end

local function missing(message)
    local text = string.lower(tostring(message or ""))
    return text:find("no such file", 1, true) ~= nil
        or text:find("cannot find", 1, true) ~= nil
        or text:find("not found", 1, true) ~= nil
end

function inbox.readBinary(root, pathApi)
    local path = slotPath(root, pathApi)
    local file, openError = io.open(path, "rb")
    if not file then
        if missing(openError) then return nil, "not-published", "active published plan is not present" end
        return nil, "file-open-failed", tostring(openError or "could not open active published plan")
    end
    local content = file:read(inbox.MAX_BYTES + 1)
    file:close()
    if content == nil then return nil, "file-read-failed", "could not read active published plan" end
    if #content > inbox.MAX_BYTES then
        return nil, "plan-too-large", "plan exceeds the 1,048,576-byte limit"
    end
    return content
end

function inbox.create(root, decode, pathApi)
    if type(decode) ~= "function" then error("inbox decoder must be a function", 2) end
    local state = {
        plan = nil,
        status = {
            slot = "unknown",
            inspection = "not-inspected",
            load = "idle",
            protocol = "unknown",
            catalog = "unknown",
            fingerprint = nil,
            error = nil,
        },
    }
    local api = {}
    function api.activeSlot() return inbox.ACTIVE_SLOT end
    function api.plan() return state.plan end
    function api.status()
        local copy = {}
        for key, value in pairs(state.status) do copy[key] = value end
        return copy
    end
    function api.load()
        state.plan = nil
        state.status.slot, state.status.inspection, state.status.load = "unknown", "reading", "loading"
        state.status.protocol = "unknown"
        state.status.catalog, state.status.fingerprint, state.status.error = "unknown", nil, nil
        local raw, code, message = inbox.readBinary(root, pathApi)
        if raw == nil then
            state.status.slot = code == "not-published" and "not-published" or "error"
            state.status.inspection, state.status.load = "failed", "error"
            state.status.error = { code = code, message = message }
            return false, code
        end
        local decoded, decodeError = decode(raw)
        if decoded == nil then
            state.status.inspection, state.status.load, state.status.protocol = "failed", "error", "error"
            state.status.slot = "present"
            state.status.error = { code = "malformed-plan", message = decodeError }
            return false, "malformed-plan"
        end
        state.plan = decoded
        state.status.slot, state.status.inspection, state.status.load = "present", "inspected", "ready"
        state.status.protocol, state.status.catalog = decoded.protocolVersion, decoded.catalogVersion
        state.status.fingerprint = decoded.planFingerprint
        return true, decoded
    end
    return api
end

return inbox
