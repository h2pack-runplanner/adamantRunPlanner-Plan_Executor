package.path = "./?.lua;./?/init.lua;" .. package.path

local lu = require("luaunit")
os.exit(lu.LuaUnit.run())
