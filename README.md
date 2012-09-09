debugger.lua
=

A simple, embedabble CLI debugger for Lua 5.1, Lua 5.2 and LuaJIT 2.0.

Have you ever been working on an embedded Lua project and found yourself in need of a debugger? The lua-users wiki lists a [number of them](http://lua-users.org/wiki/DebuggingLuaCode). While clidebugger was closest to what I wanted, I ran into several compatibility issues. The rest of them are very large libraries that require you to integrate socket libraries or other native libraries and such into your program. I just wanted something simple that would work through stdin/out. I also decided that it sounded fun to try and make my own.

Features
-

- Simple to "install". Simply copy debugger.lua into your project then load it using <code>local dbg = require()</code>.
- Conditional assert-style breakpoints.
- Easy to set it up to break on <code>assert()</code> or <code>error()</code>
- <code>dbg.call()</code> works similar to <code>xpcall()</code> but starts the debugger when an error occurs.
- Works with Lua 5.2, Lua 5.1, LuaJIT 2.0 and probably other versions that I didn't bother to test.
- The regular assortment of commands you'd expect from a debugger: continue, step, next, finish, print/eval expression, move up/down the stack, backtrace, print locals, inline help.
- Evaluate expressions and call functions interactively in the debugger. Inspect locals, upvalues and globals. Even works with varargs <code>...</code> (Lua 5.2 only).
- Pretty printed output so you get <code>{1 = 3, "a" = 5}</code> instead of <code>table: 0x10010cfa0</code>
- Speed. The debugger hooks are only set when running the step/next/finish commands and shouldn't otherwise affect your program's performance.
