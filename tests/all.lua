package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tests/?/init.lua;./?.lua;./?/init.lua;" .. package.path

require("tests/test_protocol")
require("tests/test_inbox")

local lu = require("luaunit")
os.exit(lu.LuaUnit.run())
