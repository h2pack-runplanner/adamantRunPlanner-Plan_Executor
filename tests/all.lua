package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tests/?/init.lua;./?.lua;./?/init.lua;" .. package.path

require("tests/test_json")
require("tests/test_protocol")
require("tests/test_inbox")
require("tests/test_chaos")
require("tests/test_session")
require("tests/test_logic")

local lu = require("luaunit")
os.exit(lu.LuaUnit.run())
