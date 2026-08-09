-- Fixed active-slot filesystem adapter. It never enumerates, creates, or
-- selects files: the desktop publisher and this reader agree on one filename.
-- It is deliberately unaware of transport compression and project semantics.

local inbox = {}
inbox.MAX_BYTES = 1048576
inbox.ACTIVE_SLOT = "active.runplanner.json"

local function fail(code, message)
    return nil, code, message
end

local function slotPath(root, pathApi)
    if type(pathApi) ~= "table" or type(pathApi.combine) ~= "function" then
        error("Plan Executor requires rom.path.combine", 3)
    end
    return pathApi.combine(root, inbox.ACTIVE_SLOT)
end

local function missingFile(openError)
    local message = string.lower(tostring(openError or ""))
    return message:find("no such file", 1, true) ~= nil
        or message:find("cannot find", 1, true) ~= nil
        or message:find("not found", 1, true) ~= nil
end

local function readBinary(root, pathApi)
    local path = slotPath(root, pathApi)
    local file, openError = io.open(path, "rb")
    if not file then
        if missingFile(openError) then
            return fail("not-published", "active published bundle is not present")
        end
        return fail("file-open-failed", tostring(openError or "could not open active published bundle"))
    end
    local content = file:read(inbox.MAX_BYTES + 1)
    file:close()
    if content == nil then
        return fail("file-read-failed", "could not read selected plan")
    end
    if #content > inbox.MAX_BYTES then
        return fail("bundle-too-large", "bundle exceeds the 1,048,576-byte limit")
    end
    return content
end

local function copyStatus(state)
    local status = {}
    for key, value in pairs(state.status) do status[key] = value end
    return status
end

function inbox.create(root, decode, pathApi)
    if type(root) ~= "string" or root == "" then
        error("inbox root must be a non-empty path", 2)
    end
    if type(decode) ~= "function" then
        error("inbox decoder must be a function", 2)
    end
    local state = {
        root = root,
        plan = nil,
        status = {
            slot = "unknown",
            load = "idle",
            protocol = "unknown",
            catalog = "unknown",
            routeAvailability = "unknown",
            fingerprint = nil,
            error = nil,
        },
    }

    local api = {}

    function api.root()
        return root
    end

    function api.load()
        state.plan = nil
        state.status.slot = "unknown"
        state.status.load = "loading"
        state.status.protocol = "unknown"
        state.status.catalog = "unknown"
        state.status.routeAvailability = "unknown"
        state.status.fingerprint = nil
        state.status.error = nil
        local raw, readCode, readMessage = readBinary(root, pathApi)
        if not raw then
            state.status.load = "error"
            state.status.slot = readCode == "not-published" and "not-published" or "error"
            state.status.error = { code = readCode, message = readMessage }
            return false, readCode
        end
        state.status.slot = "present"
        local decoded, decodeError = decode(raw)
        if not decoded then
            state.status.load = "error"
            state.status.protocol = "error"
            local code = tostring(decodeError or "malformed-json")
            if code:match("^malformed%-json") then
                code = "malformed-json"
            end
            state.status.error = { code = code, message = decodeError }
            return false, state.status.error.code
        end
        state.plan = decoded
        state.status.load = "ready"
        state.status.protocol = decoded.kind == "project-only" and "project-only" or "ready"
        state.status.catalog = decoded.catalogVersion or "not-present"
        state.status.routeAvailability = #decoded.routeKeys == 0 and "none" or table.concat(decoded.routeKeys, ",")
        state.status.fingerprint = decoded.fingerprint
        return true, decoded
    end

    function api.plan()
        return state.plan
    end

    function api.status()
        return copyStatus(state)
    end

    return api
end

inbox.readBinary = readBinary
inbox.slotPath = slotPath

return inbox
