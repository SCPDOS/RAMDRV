#!/bin/sh

buffer:
	nasm ramdrv.asm -o ./bin/RAMDRV.SYS -f bin -l ./lst/ramdrv.lst -O0v
