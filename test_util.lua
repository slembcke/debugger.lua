-- Hack to disable color support
local getenv = os.getenv
os.getenv = function(sym) return (sym == "TERM") and "dumb" or getenv(sym) end

local dbg = require("debugger");
local dbg_read = dbg.read
local dbg_write = dbg.write

function string.strip(str) return str:match("^%s*(.-)%s*$") end

local module = {}

-- Debugger command line string to run next.
local command_string
local function cmd(str) command_string = str end

dbg.read = function()
	local str = command_string
	-- command_string = nil
	return str
end

local function sanity_write(str)
	print "ERROR: dbg.write caled unexpectedly?!"
	print(str)
end

local function expect(str)
	local str2 = coroutine.yield():strip()
	if str ~= str2 then
		print("FAILURE")
		print("expected: "..str)
		print("got     : "..str2)
	end
end

-- Used for setting up new tests.
local function show()
	print("expect \""..coroutine.yield():strip().."\"")
end

local function skip()
	coroutine.yield()
end

function module.run_test(test, test_body)
	local coro = coroutine.create(test)
	coroutine.resume(coro)
	
	dbg.write = function(str) coroutine.resume(coro, str) end
	test_body()
	dbg.write = sanity_write
	
	if coroutine.status(coro) ~= "dead" then
		print("FAILURE: test coroutine not complete")
	end
end

function module.step()
	cmd "s"; expect "test.lua:8 in 'func1'"
	cmd "s"; expect "test.lua:12 in 'func2'"
	cmd "s"; expect "test.lua:13 in 'func2'"
	cmd "s"; expect "test.lua:17 in 'func3'"
	cmd "s"; expect "test.lua:4 in 'do_nothing'"
	cmd "s"; expect "test.lua:18 in 'func3'"
	cmd "s"; expect "test.lua:22 in 'test_body'"
	print("STEP TESTS COMPLETE")
	cmd "c"
end

function module.next()
	cmd "n"; expect "test.lua:8 in 'func1'"
	cmd "n"; expect "test.lua:12 in 'func2'"
	cmd "n"; expect "test.lua:13 in 'func2'"
	cmd "n"; expect "test.lua:17 in 'func3'"
	cmd "n"; expect "test.lua:18 in 'func3'"
	cmd "n"; expect "test.lua:26 in 'test_body'"
	print("NEXT TESTS COMPLETE")
	cmd "c"
end

function module.finish()
	cmd "f"; expect "test.lua:8 in 'func1'"
	cmd "f"; expect "test.lua:12 in 'func2'"
	cmd "f"; expect "test.lua:17 in 'func3'"
	cmd "f"; expect "test.lua:30 in 'test_body'"
	print("FINISH TESTS COMPLETE")
	cmd "c"
end

return module
