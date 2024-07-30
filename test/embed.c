// SPDX-License-Identifier: MIT
// Copyright (c) 2024 Scott Lembcke and Howling Moon Software

#include <stdio.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#define DEBUGGER_LUA_DEFINE
#include "debugger_lua.h"

int main(int argc, char **argv){
	lua_State *lua = luaL_newstate();
	luaL_openlibs(lua);
	
	dbg_setup_default(lua);
	
	luaL_loadstring(lua,
		"local num = 1\n"
		"local str = 'one'\n"
		"local res = num + str\n"
	);
	
	if(dbg_pcall(lua, 0, 0, 0)){
		fprintf(stderr, "Lua Error: %s\n", lua_tostring(lua, -1));
	}
}
