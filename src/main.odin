package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import sdl "vendor:sdl3"
import img "vendor:stb/image"

// --- Windows High Performance GPU Hint ---
@(export, link_name = "NvOptimusEnablement")
NvOptimusEnablement: c.ulong = 1
@(export, link_name = "AmdPowerXpressRequestingHighPerformance")
AmdPowerXpressRequestingHighPerformance: i32 = 1

W_WIDTH, W_HEIGHT :: 640, 480

Globals :: struct {
	window:   ^sdl.Window,
}

globals: Globals

sdl_assert :: proc(ok: bool, loc := #caller_location) {
	if !ok do log.panicf("SDL Error at line %v: {}", loc, sdl.GetError())
}

main :: proc() {
	context.logger = log.create_console_logger()

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		for _, leak in track.allocation_map {
			fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
		}
		mem.tracking_allocator_clear(&track)
	}

	// Init SDL
	sdl_assert(sdl.Init({.VIDEO}))
	defer sdl.Quit()

	globals.window = sdl.CreateWindow("Game", W_WIDTH, W_HEIGHT, {})
	sdl_assert(globals.window != nil)
	defer sdl.DestroyWindow(globals.window)

	should_quit := false
	for !should_quit {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if event.type == .QUIT do should_quit = true
			if event.type == .KEY_DOWN {
				if event.key.key == sdl.K_ESCAPE do should_quit = true
			}
		}

		sdl.Delay(1)
	}
}
