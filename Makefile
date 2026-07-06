CC = gcc
CFLAGS = -O2 -fPIC -shared -m64 -Wl,-rpath,'$ORIGIN/./lib/lua'
LUA_DIR = ./include/lua5.4
LUA_LIB = ./lib/lua
LUA_CFLAGS = -I$(LUA_DIR)
LUA_LIBS = -L./lib/lua -llua-5.4

all: cprofiler.so

cprofiler.so: cprofiler.o
	$(CC) cprofiler.o -o cprofiler.so $(CFLAGS) $(LUA_LIBS)

cprofiler.o:
	$(CC) -c cprofiler.c $(CFLAGS) $(LUA_CFLAGS)

clean:
	rm -f *.o *.so