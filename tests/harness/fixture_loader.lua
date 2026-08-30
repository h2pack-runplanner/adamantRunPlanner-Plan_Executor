-- Test-only loader for the current producer fixture. Runtime code never uses it.
local json = require("mods/json")
local loader = {}
loader.fixturePath = "test/fixtures/execution-plan/f-opening.execution.json"

function loader.raw()
    local file = assert(io.open(loader.fixturePath, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end

function loader.decode()
    local value, errorMessage = json.decode(loader.raw())
    assert(value, errorMessage)
    return value
end

return loader
