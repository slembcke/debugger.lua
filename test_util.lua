-- Hack to disable color support
local getenv = os.getenv
os.getenv = function(sym) return (sym == "TERM") and "dumb" or getenv(sym) end

local dbg = require("debugger");
local dbg_read = dbg.read
local dbg_write = dbg.write

-- The global Lua versions will be overwritten in some tests.
local lua_assert = assert
local lua_error = error

local LOG_IO = false

function string.strip(str) return str:match("^%s*(.-)%s*$") end

local module = {}

-- Debugger command line string to run next.
local command_string
local function cmd(str) command_string = str end

dbg.read = function(prompt)
	lua_assert(command_string, "Command not set!")
	
	local str = command_string
	command_string = nil
	
	if LOG_IO then print(prompt..str) end
	return str
end

local function sanity_write(str)
	print "ERROR: dbg.write caled unexpectedly?!"
	if LOG_IO then print(str) end
end

local function expect(str, cmd)
	local str2 = coroutine.yield():strip()
	if LOG_IO then print(str2) end
	if str ~= str2 then
		print("FAILURE")
		print("expected: "..str)
		print("got     : "..str2)
	end
end

local function expect_match(pattern, cmd)
	local str = coroutine.yield():strip()
	if LOG_IO then print(str2) end
	if not str:match(pattern) then
		print("FAILURE (match)")
		print("expected: "..pattern)
		print("got     : "..str)
	end
end

-- Used for setting up new tests.
local function show()
	print("expect \""..coroutine.yield():strip().."\"")
end

local function ignore()
	local str = coroutine.yield():strip()
	if LOG_IO then print(str) end
end

function module.repl(test_body)
	dbg.read = dbg_read
	dbg.write = dbg_write
	test_body()
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
	expect "test.lua:8 in 'func1'"; cmd "s"
	expect "test.lua:12 in 'func2'"; cmd "s"
	expect "test.lua:13 in 'func2'"; cmd "s"
	expect "test.lua:17 in 'func3'"; cmd "s"
	expect "test.lua:4 in 'do_nothing'"; cmd "s"
	expect "test.lua:18 in 'func3'"; cmd "s"
	expect "test.lua:22 in 'test_body'"; cmd "c"
	print "STEP TESTS COMPLETE"
end

function module.next()
	expect "test.lua:8 in 'func1'"; cmd "n"
	expect "test.lua:12 in 'func2'"; cmd "n"
	expect "test.lua:13 in 'func2'"; cmd "n"
	expect "test.lua:17 in 'func3'"; cmd "n"
	expect "test.lua:18 in 'func3'"; cmd "n"
	expect "test.lua:26 in 'test_body'"; cmd "c"
	print "NEXT TESTS COMPLETE"
end

function module.finish()
	expect "test.lua:8 in 'func1'"; cmd "f"
	expect "test.lua:12 in 'func2'"; cmd "f"
	expect "test.lua:17 in 'func3'"; cmd "f"
	expect "test.lua:30 in 'test_body'"; cmd "c"
	print "FINISH TESTS COMPLETE"
end

function module.continue()
	expect "test.lua:8 in 'func1'"; cmd "c"
	expect "test.lua:8 in 'func1'"; cmd "c"
	expect "test.lua:8 in 'func1'"; cmd "c"
	print "CONTINUE TESTS COMPLETE"
end

function module.trace()
	ignore(); -- Stack frame info that will be in the trace anyway.
	
	cmd "t"
	expect "Inspecting frame: 0 - (test.lua:8 in 'func1')"
	expect "stack traceback:"
	expect_match "0\ttest%.lua:8: in %a+ 'func1'"
	expect_match "1\ttest%.lua:11: in %a+ 'func2'"
	expect_match "2\ttest%.lua:16: in %a+ 'func3'"
	expect_match "3\ttest%.lua:39: in %a+ 'test_body'"
	expect_match "4\t./test_util%.lua:%d+: in function '.*run_test'"
	expect "5\ttest.lua:38: in main chunk"
	expect_match "6\t%[C%]:.*"
	cmd "c"
end

return module
