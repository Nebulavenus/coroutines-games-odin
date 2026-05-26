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

Game_State :: struct {
	score: int,
}

print_score_callback :: proc(data: rawptr) -> bool {
	state := (^Game_State)(data)
	fmt.printf("Coroutine run! Current Score: %d\n", state.score)
	return true
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

	// Init coroutines
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	state := Game_State { score = 42 }

	// Sequence coroutine: Print -> wait 1.5s -> print -> wait 3.0s -> print
	my_coroutine := new_sequence_node([]^Node {
		new_callback_node(print_score_callback, &state),
		new_wait_node(1.5),
		new_callback_node(print_score_callback, &state),
		new_wait_node(3.0),
		new_callback_node(print_score_callback, &state),
	})
	enqueue_node(&exec, my_coroutine)

	// Game loop
	should_quit := false
	last_time := sdl.GetTicksNS()
	for !should_quit {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if event.type == .QUIT do should_quit = true
			if event.type == .KEY_DOWN {
				if event.key.key == sdl.K_ESCAPE do should_quit = true
			}
		}

		// frame delta
		now := sdl.GetTicksNS()
		dt_ns := now - last_time
		last_time = now
		dt := f32(dt_ns) / 1_000_000_000.0 // to seconds

		// update coroutines
		executor_step(&exec, dt)

		state.score += 1

		sdl.Delay(1)
	}
}
