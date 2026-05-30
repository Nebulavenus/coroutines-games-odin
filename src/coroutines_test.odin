#+build windows
package main

import "core:fmt"
import "core:testing"
import hm "core:container/handle_map"

Test_Context :: struct {
	action_count:  int,
	was_completed: bool,
	was_failed:    bool,
	cleanup_val:   Status,
}

reset_context :: proc(ctx: ^Test_Context) {
	ctx.action_count = 0
	ctx.was_completed = false
	ctx.was_failed = false
	ctx.cleanup_val = .None
}

increment_action :: proc(ctx: ^Test_Context) -> bool {
	ctx.action_count += 1
	return true
}

fail_action :: proc(ctx: ^Test_Context) -> bool {
	ctx.was_failed = true
	return false
}

complete_action :: proc(ctx: ^Test_Context) -> bool {
	ctx.was_completed = true
	return true
}

@(test)
test_wait_and_callback_sequence :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Seq: incr -> wait 0.1s -> completed
	node := seq(run(increment_action, &ctx), wait(0.10), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.action_count, 1)
	testing.expect_value(t, ctx.was_completed, false)

	executor_step(&exec, 0.05)
	testing.expect_value(t, ctx.was_completed, false)

	executor_step(&exec, 0.06)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_selector_fallback :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Select: Try to Fail -> Then Fallback to Complete
	node := select(run(fail_action, &ctx), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0)

	testing.expect_value(t, ctx.was_failed, true) // First branch ran and failed
	testing.expect_value(t, ctx.was_completed, true) // Second branch successfully executed
}

@(test)
test_parallel_race :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Race: Fast wait vs Slow wait
	// If fast wait wins, slow wait is aborted and the complete action triggers
	node := seq(race(wait(0.05), wait(1.00)), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	// 0.02s elapsed. No winner yet.
	executor_step(&exec, 0.02)
	testing.expect_value(t, ctx.was_completed, false)

	// Total 0.06s elapsed. 0.05s timer completed, winning the race.
	executor_step(&exec, 0.04)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_parallel_sync :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Sync: Wait 0.05s AND Wait 0.20s
	node := seq(sync(wait(0.05), wait(0.20)), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	// Step past the first timer limit (0.05s)
	executor_step(&exec, 0.10)
	testing.expect_value(t, ctx.was_completed, false) // Still waiting for the second timer (0.20s)

	// Step past the second timer limit
	executor_step(&exec, 0.15)
	testing.expect_value(t, ctx.was_completed, true) // Both are done, sync finishes
}

@(test)
test_loop_termination_on_failure :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Loop that increments action count, then fails on the third iteration
	looping_counter_action :: proc(c: ^Test_Context) -> bool {
		c.action_count += 1
		return c.action_count < 3 // Return false (fail) on the 3rd step to terminate loop
	}

	node := loop(run(looping_counter_action, &ctx))
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0) // Frame 1: count = 1, returns true (running)
	testing.expect_value(t, ctx.action_count, 1)

	executor_step(&exec, 0.0) // Frame 2: count = 2, returns true (running)
	testing.expect_value(t, ctx.action_count, 2)

	executor_step(&exec, 0.0) // Frame 3: count = 3, returns false (fails, breaking loop)
	testing.expect_value(t, ctx.action_count, 3)

	// Step once more to verify execution has stopped
	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.action_count, 3) // Count should remain 3
}

@(test)
test_scope_cleanup :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	cleanup_callback :: proc(c: ^Test_Context, status: Status) {
		c.cleanup_val = status
	}

	// Scope wraps a wait node. When wait completes, cleanup runs with .Completed
	node := scope(wait(0.10), cleanup_callback, &ctx)
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.05)
	testing.expect_value(t, ctx.cleanup_val, Status.None) // Not finished yet

	executor_step(&exec, 0.06)
	testing.expect_value(t, ctx.cleanup_val, Status.Completed) // Cleanup executed successfully
}

@(test)
test_scope_cleanup_on_abort :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	cleanup_callback :: proc(c: ^Test_Context, status: Status) {
		c.cleanup_val = status
	}

	node := scope(wait(1.00), cleanup_callback, &ctx)
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.05)

	// Force abort the active node tree midway
	abort_node(&exec, node)
	testing.expect_value(t, ctx.cleanup_val, Status.Aborted) // Cleanup should run with Aborted state
}

@(test)
test_tween_interpolation :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	val: f32 = 0.0
	node := tween(0.0, 10.0, 1.0, &val)
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0)
	testing.expect(t, val == 0.0, "Expected initial value to be 0.0")

	executor_step(&exec, 0.5)
	testing.expect(t, val == 5.0, "Expected value to interpolate to 5.0")

	executor_step(&exec, 0.5)
	testing.expect(t, val == 10.0, "Expected final value to interpolate to 10.0")
}

@(test)
test_wait_until :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	condition_met := false
	check_condition :: proc(data: ^bool) -> bool {
		return data^
	}

	node := seq(wait_until(check_condition, &condition_met), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_completed, false)

	condition_met = true
	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_catch_node :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Catch a failure, turning it into a success for the sequence
	node := seq(catch(run(fail_action, &ctx)), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_failed, true)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_logical_decorators :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Decorate a failure action with NOT, converting it to Success
	node := seq(not(run(fail_action, &ctx)), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_failed, true) // Failure action was executed
	testing.expect_value(t, ctx.was_completed, true) // NOT intercepted failure, allowing sequence to complete
}

@(test)
test_nested_aborts :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

    ctx: Test_Context
	reset_context(&ctx)

	cleanup_callback :: proc(c: ^Test_Context, status: Status) {
		c.cleanup_val = status
	}

	// Seq [ Scope [ Wait ] ]
	// Aborting Seq should abort Scope, which should abort Wait and run cleanup.
	inner_wait := wait(10.0)
	scoped := scope(inner_wait, cleanup_callback, &ctx)
	root_seq := seq(scoped)

	enqueue_node(&exec, root_seq, {})
	executor_step(&exec, 0.1)

	testing.expect_value(t, ctx.cleanup_val, Status.None)

	abort_node(&exec, root_seq)
	testing.expect_value(t, ctx.cleanup_val, Status.Aborted)
}

@(test)
test_wait_until_with_zero_dt :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	condition := false
	check_cond :: proc(data: ^bool) -> bool {
		return data^
	}

	node := seq(wait_until(check_cond, &condition), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	// Step with zero dt (paused simulation)
	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_completed, false)

	condition = true
	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_wait_frames :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	node := seq(wait_frames(3), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0) // Frame 1
	testing.expect_value(t, ctx.was_completed, false)

	executor_step(&exec, 0.0) // Frame 2
	testing.expect_value(t, ctx.was_completed, false)

	executor_step(&exec, 0.0) // Frame 3
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_capture_return :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	res: bool
	node := capture_return(run(proc() -> bool {return false}), &res)
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0)
	testing.expect_value(t, res, false)

	res = false
	node2 := capture_return(run(proc() -> bool {return true}), &res)
	enqueue_node(&exec, node2, {})

	executor_step(&exec, 0.0)
	testing.expect_value(t, res, true)
}

@(test)
test_optional_sequence :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Optional sequence should NOT stop on failure
	node := optional_seq(
		run(increment_action, &ctx),
		run(proc() -> bool {return false}), 	// Fail
		run(increment_action, &ctx),
	)
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.action_count, 2)
}

@(test)
test_semaphore_scope :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	sem: Semaphore
	semaphore_init(&sem, 1)
	defer semaphore_destroy(&sem)

	ctx1, ctx2: Test_Context
	reset_context(&ctx1)
	reset_context(&ctx2)

	// Two nodes trying to enter a semaphore with max_active=1
	node1 := semaphore_scope(&sem, seq(wait(0.1), run(complete_action, &ctx1)))
	node2 := semaphore_scope(&sem, run(complete_action, &ctx2))

	enqueue_node(&exec, node1, {})
	enqueue_node(&exec, node2, {})

	executor_step(&exec, 0.0)
	// node1 acquired, node2 is queued
	testing.expect_value(t, sem.current_active, 1)
	testing.expect_value(t, ctx1.was_completed, false)
	testing.expect_value(t, ctx2.was_completed, false)

	executor_step(&exec, 0.11)
	// node1 completed and released semaphore, node2 acquired and completed immediately
	testing.expect_value(t, ctx1.was_completed, true)
	testing.expect_value(t, ctx2.was_completed, true)
}

@(test)
test_managed_node :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	// Allocate a payload
	payload := new(int)
	payload^ = 42

	// Wrap in a managed node
	node := managed(wait(1.0), payload)
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.1)

	// Abort the node. The Managed_Node's destroy should free the payload.
	abort_node(&exec, node)
}

@(test)
test_fork :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Seq [ Fork [ Seq [ Wait, Incr ] ], Complete ]
	// Parent branch finishes instantly after Fork. Detached branch runs in background.
	node := seq(
		fork(seq(wait(0.1), run(increment_action, &ctx))),
		run(complete_action, &ctx),
	)
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_completed, true) // Parent branch done
	testing.expect_value(t, ctx.action_count, 0)     // Detached branch still waiting

	executor_step(&exec, 0.11)
	testing.expect_value(t, ctx.action_count, 1)     // Detached branch finished
}

@(test)
test_wait_forever :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Race: 0.1s wait vs Forever. 0.1s should always win.
	node := seq(race(wait(0.1), wait_forever()), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.05)
	testing.expect_value(t, ctx.was_completed, false)

	executor_step(&exec, 0.1)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_weak_guard :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	alive := true
	is_valid :: proc(data: ^bool) -> bool { return data^ }

	// Weak wraps an action. If 'alive' becomes false, Weak should abort child and fail.
	node := seq(weak(wait(1.0), is_valid, &alive), run(complete_action, &ctx))
	enqueue_node(&exec, node, {})

	executor_step(&exec, 0.1)
	testing.expect_value(t, ctx.was_completed, false)

	alive = false
	executor_step(&exec, 0.1)
	// Sequence should have failed because Weak failed, so complete_action never runs.
	testing.expect_value(t, ctx.was_completed, false)
}

@(test)
test_suspended_status_behavior :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	context.user_ptr = &exec
	defer executor_destroy(&exec)

	// Sequence [ Wait(0.1) ]
	// Sequence should be .Suspended while Wait is .Running
	wait_h := wait(0.1)
	seq_h := seq(wait_h)
	enqueue_node(&exec, seq_h, {})

	executor_step(&exec, 0.0)

	// Check pool status
	s_node, _ := hm.get(&exec.pool, seq_h)
	w_node, _ := hm.get(&exec.pool, wait_h)
	
	testing.expect_value(t, s_node.status, Status.Suspended)
	testing.expect_value(t, w_node.status, Status.Running)

	// Check active queues
	// seq_h should NOT be in active_nodes (it's suspended)
	// wait_h SHOULD be in active_nodes
	
	found_seq := false
	found_wait := false
	for h in exec.active_nodes {
		if h == seq_h do found_seq = true
		if h == wait_h do found_wait = true
	}
	
	testing.expect_value(t, found_seq, false)
	testing.expect_value(t, found_wait, true)

	// Step to finish Wait
	executor_step(&exec, 0.11)
	
	// Now Sequence should be Completed and freed (since it's root)
	_, ok := hm.get(&exec.pool, seq_h)
	testing.expect_value(t, ok, false)
}
