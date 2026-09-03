package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tests/?/init.lua;./?.lua;./?/init.lua;" .. package.path

require("tests/test_json")
require("tests/test_inbox")
require("tests/test_chaos")
require("tests/test_room_sessions_v10")
require("tests/test_protocol_v12")
require("tests/test_runtime_session")
require("tests/test_native_checkpoints_v10")
require("tests/test_native_adapters")
require("tests/test_loadout_v11")
require("tests/test_hook_composition_v10")

local lu = require("luaunit")
os.exit(lu.LuaUnit.run())
