test:
	- lua-5.1 test.lua
	- lua5.1 test.lua
	- lua5.2 test.lua
	- lua5.3 test.lua
	- lua5.4 test.lua
	- luajit test.lua
	- lua test.lua

debugger_lua.h: ../make_c_header.lua ../debugger.lua
	lua $^ $@

CFLAGS = -I ../embed
LDFLAGS = -llua

clean:
	- rm embed *.o debugger_lua.h
	
embed.o: debugger_lua.h
embed: embed.o

test-embed: embed
	printf "w\nt\nc\n" | ./embed
