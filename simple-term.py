import sys
import os
import threading
import readline

out_name, in_name = "/tmp/debugger.lua.in", "/tmp/debugger.lua.out"
os.system(f"mkfifo {in_name} {out_name}")

out_pipe = open(out_name, "w")
in_pipe = open(in_name, "r")

def read_loop():
	while True:
		str = in_pipe.read(1)
		if(len(str) == 0):
			print("noinput")
			sys.exit()
		
		sys.stdout.write(str)
		sys.stdout.flush()
		
threading.Thread(target=read_loop).start()

while True:
	str = sys.stdin.readline()
	out_pipe.write(str + "\n")
	out_pipe.flush()
