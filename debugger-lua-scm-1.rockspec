package = "debugger-lua"
version = "scm-1"

source = {
   url = "https://github.com/slembcke/debugger.lua"
}

description = {
   summary = "A simple, highly embedabble CLI debugger for Lua 5.x, and LuaJIT 2.0.",
   detailed = [[
      A simple, highly embedabble CLI debugger for Lua 5.x, and LuaJIT 2.0.
      
      Features:
      * Simple installation as either a single .lua file (< 500 LoC) OR a single .c/.h file pair.
      * Drop in xpcall() and lua_pcall() replacements that drop into the REPL for an error.
      * Optional colored output and GNU readline (LuaJIT) support.
      * Extendable I/O that defaults to stdin/stdout.
      * Simple assert style breakpoints.
      * REPL with step, next, finish, print/eval, up/down, backtrace and list locals commands.
      * Pretty printed output for tables.
      * Speed! Debug hooks are only set when stepping and do not otherwise affect performance.
   ]],
}

build = {
   type = "builtin",
   modules = {
      debugger = "debugger.lua"
   }
}
