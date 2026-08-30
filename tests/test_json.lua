local lu = require("luaunit")
local json = require("mods/json")

TestJson = {}

function TestJson.testDecodesTaggedObjectsArraysAndScalars()
    local value = assert(json.decode('{"a":[true,null,{"n":2}],"s":"ok"}'))
    lu.assertTrue(json.isObject(value))
    lu.assertTrue(json.isArray(value.a))
    lu.assertTrue(value.a[1])
    lu.assertTrue(json.isNull(value.a[2]))
    lu.assertEquals(value.a[3].n, 2)
end

function TestJson.testRejectsDuplicateKeysTrailingDataAndBadEscape()
    lu.assertNil(json.decode('{"a":1,"a":2}'))
    lu.assertNil(json.decode('{"a":1} trailing'))
    lu.assertNil(json.decode('{"a":"\\q"}'))
end

function TestJson.testRejectsNonJsonNumberForms()
    for _, value in ipairs({ "01", "-01", "1.", ".1", "1e", "1e+", "+1" }) do
        lu.assertNil(json.decode(value))
    end
end

return TestJson
