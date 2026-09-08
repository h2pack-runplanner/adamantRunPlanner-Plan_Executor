-- The module inbox owns transport for the six fixed published plan slots. It
-- reads one bounded file only when the session explicitly asks for a new-run
-- plan or an inspection.

local inbox = {}
inbox.MAX_BYTES = 1048576
inbox.SLOT_COUNT = 6
inbox.SLOT_FILES = {
    "slot-1.runplanner.json",
    "slot-2.runplanner.json",
    "slot-3.runplanner.json",
    "slot-4.runplanner.json",
    "slot-5.runplanner.json",
    "slot-6.runplanner.json",
}

local function normalizeSlot(slot)
    if type(slot) ~= "number" or slot ~= math.floor(slot)
        or slot < 1 or slot > inbox.SLOT_COUNT then
        return nil
    end
    return slot
end

function inbox.slotFileName(slot)
    local normalized = normalizeSlot(slot)
    return normalized and inbox.SLOT_FILES[normalized] or nil
end

local function slotPath(root, pathApi, slot)
    if type(root) ~= "string" or root == "" then error("inbox root must be non-empty", 3) end
    if type(pathApi) ~= "table" or type(pathApi.combine) ~= "function" then
        error("inbox requires rom.path.combine", 3)
    end
    local fileName = inbox.slotFileName(slot)
    if fileName == nil then return nil, "invalid-slot", "plan slot must be an integer from 1 through 6" end
    return pathApi.combine(root, fileName)
end

local function missing(message)
    local text = string.lower(tostring(message or ""))
    return text:find("no such file", 1, true) ~= nil
        or text:find("cannot find", 1, true) ~= nil
        or text:find("not found", 1, true) ~= nil
end

function inbox.readBinary(root, pathApi, slot)
    local path, slotError, slotMessage = slotPath(root, pathApi, slot)
    if path == nil then return nil, slotError, slotMessage end
    local file, openError = io.open(path, "rb")
    if not file then
        if missing(openError) then
            return nil, "not-published", "published plan slot " .. tostring(slot) .. " is not present"
        end
        return nil, "file-open-failed", tostring(openError or "could not open published plan slot")
    end
    local content = file:read(inbox.MAX_BYTES + 1)
    file:close()
    if content == nil then return nil, "file-read-failed", "could not read published plan slot" end
    if #content > inbox.MAX_BYTES then
        return nil, "plan-too-large", "plan exceeds the 1,048,576-byte limit"
    end
    return content
end

function inbox.create(root, decode, pathApi)
    if type(decode) ~= "function" then error("inbox decoder must be a function", 2) end
    local state = {
        plan = nil,
        selectedSlot = 1,
        status = {
            slot = 1,
            file = "not-inspected",
            inspection = "not-inspected",
            load = "idle",
            protocol = "unknown",
            catalog = "unknown",
            fingerprint = nil,
            error = nil,
        },
    }
    local api = {}
    local function resetStatus()
        state.status.slot = state.selectedSlot
        state.status.file = "not-inspected"
        state.status.inspection = "not-inspected"
        state.status.load = "idle"
        state.status.protocol = "unknown"
        state.status.catalog = "unknown"
        state.status.fingerprint = nil
        state.status.error = nil
    end

    function api.activeSlot() return state.selectedSlot end
    function api.select(slot)
        local normalized = normalizeSlot(slot)
        if normalized == nil then
            return false, "invalid-slot"
        end
        if normalized ~= state.selectedSlot then
            state.selectedSlot = normalized
            state.plan = nil
            resetStatus()
        end
        return true, normalized
    end
    function api.plan() return state.plan end
    function api.status()
        local copy = {}
        for key, value in pairs(state.status) do copy[key] = value end
        return copy
    end
    function api.load(slot)
        if slot ~= nil then
            local selected, selectError = api.select(slot)
            if not selected then
                state.plan = nil
                state.status.slot = slot
                state.status.file = "error"
                state.status.inspection, state.status.load = "failed", "error"
                state.status.error = { code = selectError, message = "plan slot must be an integer from 1 through 6" }
                return false, selectError
            end
        end
        state.plan = nil
        state.status.slot, state.status.file = state.selectedSlot, "reading"
        state.status.inspection, state.status.load = "reading", "loading"
        state.status.protocol = "unknown"
        state.status.catalog, state.status.fingerprint, state.status.error = "unknown", nil, nil
        local raw, code, message = inbox.readBinary(root, pathApi, state.selectedSlot)
        if raw == nil then
            state.status.file = code == "not-published" and "not-published" or "error"
            state.status.inspection, state.status.load = "failed", "error"
            state.status.error = { code = code, message = message }
            return false, code
        end
        local decoded, decodeError = decode(raw)
        if decoded == nil then
            state.status.inspection, state.status.load, state.status.protocol = "failed", "error", "error"
            state.status.file = "present"
            state.status.error = { code = "malformed-plan", message = decodeError }
            return false, "malformed-plan"
        end
        state.plan = decoded
        state.status.file, state.status.inspection, state.status.load = "present", "inspected", "ready"
        state.status.protocol, state.status.catalog = decoded.protocolVersion, decoded.catalogVersion
        state.status.fingerprint = decoded.planFingerprint
        return true, decoded
    end
    return api
end

return inbox
