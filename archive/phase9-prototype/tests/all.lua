package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tests/?/init.lua;./?.lua;./?/init.lua;" .. package.path

require("tests/test_protocol")
require("tests/test_inbox")
require("tests/test_session")
require("tests/test_managed_lifecycle")
require("tests/test_ui")

local lu = require("luaunit")
os.exit(lu.LuaUnit.run())
