CC ?= cc
.PHONY: check
check: hello
	./hello | tee result.txt
hello: hello.c
	$(CC) -O2 -o hello hello.c
