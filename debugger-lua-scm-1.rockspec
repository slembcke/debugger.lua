package = "debugger-lua"
version = "scm-1"

source = {
   url = "https://github.com/slembcke/debugger.lua"
}

description = {
   summary = "A simple, embedabble CLI debugger for Lua 5.1, Lua 5.2 and LuaJIT 2.0.",
   detailed = [[
      A simple, embedabble CLI debugger for Lua 5.1, Lua 5.2 and
      LuaJIT 2.0. Licensed under the very permissable MIT license.

      Have you ever been working on an embedded Lua project and found
      yourself in need of a debugger? The lua-users wiki lists a
      number of them. While clidebugger was closest to what I wanted,
      I ran into several compatibility issues. The rest of them are
      very large libraries that require you to integrate socket
      libraries or other native libraries and such into your
      program. I just wanted something simple that would work through
      stdin/out. I also decided that it sounded fun to try and make my
      own.
   ]],
}

build = {
   type = "builtin",
   modules = {
      debugger = "debugger.lua"
   }
}
