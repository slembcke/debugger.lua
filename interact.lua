dbg = require 'debugger'
dbg.auto_where = 3
dbg.auto_eval = true

while true do
	local line = dbg.read("interact> ")
	if line == nil then dbg.exit(1); return true end
	
	local source = "interact.lua REPL"
	local chunk = load(line, source, "t", _G) or load("dbg.pp("..line..")", source, "t", _G)
	if chunk then
		chunk()
	else
		dbg.writeln("Could not compile: %s", line)
	end
end
