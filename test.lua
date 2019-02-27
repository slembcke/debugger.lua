local tests = require("test_util")
local dbg = require("debugger")

local function do_nothing() end

local function func1()
	dbg()
end

local function func2()
	func1()
	local _ = nil -- padding
end

local function func3()
	func2()
	do_nothing()
end

tests.run_test(tests.step, function()
	func3()
end)

tests.run_test(tests.next, function()
	func3()
end)

tests.run_test(tests.finish, function()
	func3()
end)

print("TESTS COMPLETE")
