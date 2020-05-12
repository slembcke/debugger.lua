-- Probably not terribly useful.
-- Experimenting with debugger.lua to make a standalone repl.

dbg = require 'debugger'
dbg.auto_where = 3
dbg.auto_eval = true

COLOR_BLUE = string.char(27) .. "[94m"
COLOR_RESET = string.char(27) .. "[0m"

while true do
	local line = dbg.read(COLOR_BLUE.."interact> "..COLOR_RESET)
	if line == nil then dbg.exit(1); return true end
	
	local source = "interact.lua REPL"
	local chunk = load("dbg.pp("..line..")", source, "t", _G) or load(line, source, "t", _G)
	if chunk then
		chunk()
	else
		dbg.writeln("Could not compile: %s", line)
	end
end
