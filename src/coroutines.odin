package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import hm "core:container/handle_map"

Status :: enum {
	None,
	Completed,
	Failed,
	Running,
	Suspended,
	Aborted,
}

Eval :: struct($T: typeid) {
	val:  T,
	ptr: ^T,
}

eval_get :: #force_inline proc "contextless" (e: Eval($T)) -> T {
	return e.ptr != nil ? e.ptr^ : e.val
}

Handle :: hm.Handle32

Node :: struct {
	handle:       Handle,
	parent:       Handle,
	first_child:  Handle,
	next_sibling: Handle,
	status:       Status,
	name:         string,
	user_name:    string,
	start_time:   f64,
	show_age:     bool,
	data:         Node_Data,
}

Ease_Proc :: proc(t: f32) -> f32

ease_linear :: proc(t: f32) -> f32 {
	return t
}

ease_in_out_cubic :: proc(t: f32) -> f32 {
	if t < 0.5 {
		return 4.0 * t * t * t
	}
	return 1.0 - math.pow(f32(-2.0 * t + 2.0), 3.0) / 2.0
}

ease_in_out_elastic :: proc(t: f32) -> f32 {
	c5: f32 = (2.0 * math.PI) / 4.5
	if t == 0.0 do return 0.0
	if t == 1.0 do return 1.0

	if t < 0.5 {
		return -(math.pow(f32(2.0), 20.0 * t - 10.0) * math.sin((20.0 * t - 11.125) * c5)) / 2.0
	}
	return (math.pow(f32(2.0), -20.0 * t + 10.0) * math.sin((20.0 * t - 11.125) * c5)) / 2.0 + 1.0
}

Tween_Node :: struct {
	start:    Eval(f32),
	target:   Eval(f32),
	duration: Eval(f32),
	elapsed:  f32,
    output:	  ^f32,
    ease: 	  Ease_Proc,
	// cached
	resolved_start:    f32,
	resolved_target:   f32,
	resolved_duration: f32,
}

Wait_Node :: struct {
	duration: Eval(f32),
	elapsed:  f32,
}

Sequence_Node :: struct {
	current_child: Handle,
}

Select_Node :: struct {
	current_child: Handle,
}

Callback_Node :: struct {
	callback_ptr: rawptr,
	payload:      rawptr,
	thunk:        proc(cb: rawptr, p: rawptr) -> bool,
}

Loop_Node :: struct {
	last_step: int,
}

Race_Node :: struct {}

Sync_Node :: struct {
	closed_count: int,
	end_status:   Status,
}

Condition_Node :: struct {
	condition_ptr: rawptr,
	payload:       rawptr,
	thunk:         proc(cb: rawptr, p: rawptr) -> bool,
}

Scope_Node :: struct {
	on_exit_ptr: rawptr,
	payload:     rawptr,
	thunk:       proc(cb: rawptr, p: rawptr, status: Status),
}

Not_Node :: struct {}

Managed_Node :: struct {
	payload:    rawptr,
	allocator:  mem.Allocator,
}

Catch_Node :: struct {
	output: ^bool,
}

Wait_Frames_Node :: struct {
	target_frames:  Eval(int),
	elapsed_frames: int,
	// cached
	resolved_target: int,
}

Capture_Return_Node :: struct {
	output: ^bool,
}

Optional_Sequence_Node :: struct {
	current_child: Handle,
}

Semaphore_Handler_Node :: struct {
	sem:      ^Semaphore,
	acquired: bool,
}

Fork_Node :: struct {}

Wait_Forever_Node :: struct {}

Weak_Node :: struct {
	is_valid_ptr: rawptr,
	payload:      rawptr,
	thunk:        proc(cb: rawptr, p: rawptr) -> bool,
}

Node_Data :: union {
	Wait_Node,
	Sequence_Node,
	Select_Node,
	Callback_Node,
	Loop_Node,
	Race_Node,
	Sync_Node,
	Tween_Node,
	Condition_Node,
	Scope_Node,
	Not_Node,
	Managed_Node,
	Catch_Node,
	Wait_Frames_Node,
	Capture_Return_Node,
	Optional_Sequence_Node,
	Semaphore_Handler_Node,
	Fork_Node,
	Wait_Forever_Node,
	Weak_Node,
}

Fading_Node :: struct {
	name:       string,
	user_name:  string,
	info:       string, // cloned only for fading
	status:     Status,
	end_time:   f64,
	depth:      int,
}

Diagnostics_DB :: struct {
	enabled:      bool,
	fading_nodes: [dynamic]Fading_Node,
	allocator:    mem.Allocator,
}

diagnostics_db_init :: proc(db: ^Diagnostics_DB, allocator := context.allocator) {
	db.allocator = allocator
	db.enabled = true
	db.fading_nodes = make([dynamic]Fading_Node, 0, 128, allocator)
}

diagnostics_db_destroy :: proc(db: ^Diagnostics_DB) {
	for &f in db.fading_nodes {
		if len(f.info) > 0 do delete(f.info, db.allocator)
	}
	delete(db.fading_nodes)
}

Executor :: struct {
	pool:              hm.Dynamic_Handle_Map(Node, Handle),
	active_nodes:      [dynamic]Handle,
	next_active_nodes: [dynamic]Handle,
	step_count:        int,
	total_time:        f64,
	allocator:         mem.Allocator,
	debugger:          ^Diagnostics_DB,
}

executor_init :: proc(exec: ^Executor, allocator := context.allocator) {
	exec.allocator = allocator
	hm.dynamic_init(&exec.pool, allocator)
	exec.active_nodes = make([dynamic]Handle, allocator)
	exec.next_active_nodes = make([dynamic]Handle, allocator)
	exec.step_count = 0
	exec.total_time = 0
	exec.debugger = nil
}

executor_destroy :: proc(exec: ^Executor) {
	roots := make([dynamic]Handle, context.temp_allocator)
	it := hm.iterator_make(&exec.pool)
	for node, h in hm.iterate(&it) {
		if node.parent.idx == 0 {
			append(&roots, h)
		}
	}
	for h in roots {
		node_free(exec, h)
	}

	delete(exec.active_nodes)
	delete(exec.next_active_nodes)
	hm.dynamic_destroy(&exec.pool)
}

node_free :: proc(exec: ^Executor, h: Handle, depth: int = 0) {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return

	diagnostics_notify_destroyed(exec, node, depth)

	// Recursively free children
	curr := node.first_child
	for curr.idx != 0 {
		c_node, c_ok := hm.get(&exec.pool, curr)
		if c_ok {
			next := c_node.next_sibling
			node_free(exec, curr, depth + 1)
			curr = next
		} else {
			break
		}
	}

	// Special variant cleanup
	#partial switch &v in node.data {
	case Managed_Node:
		if v.payload != nil {
			free(v.payload, v.allocator)
		}
	case Scope_Node:
		if v.thunk != nil {
			v.thunk(v.on_exit_ptr, v.payload, .Aborted)
		}
	case Semaphore_Handler_Node:
		if v.acquired {
			semaphore_release(exec, v.sem)
			v.acquired = false
		} else {
			for i := 0; i < len(v.sem.queued); i += 1 {
				if v.sem.queued[i] == h {
					unordered_remove(&v.sem.queued, i)
					break
				}
			}
		}
	case:
		// No special cleanup
	}

	hm.remove(&exec.pool, h)
}

enqueue_node :: proc(exec: ^Executor, h: Handle, parent: Handle = {}) {
	if h.idx == 0 do return
	node, ok := hm.get(&exec.pool, h)
	if !ok do return
	node.parent = parent
	node.status = .None
	append(&exec.active_nodes, h)
}

executor_step :: proc(exec: ^Executor, dt: f32) {
	exec.total_time += f64(dt)

	i := 0
	for i < len(exec.active_nodes) {
		h := exec.active_nodes[i]
		i += 1

		if h.idx == 0 do continue

		node, ok := hm.get(&exec.pool, h)
		if !ok do continue

		if node.status == .Aborted {
			if node.parent.idx == 0 {
				node_free(exec, h)
			}
			continue
		}

		if node.status == .None {
			node.status = node_start(exec, h)

			if node.status == .Completed || node.status == .Failed {
				process_node_end(exec, h, node.status)
				continue
			}
		}

		if node.status == .Running {
			node.status = node_update(exec, h, dt)

			if node.status == .Completed || node.status == .Failed {
				process_node_end(exec, h, node.status)
				continue
			}

			if node.status == .Running {
				append(&exec.next_active_nodes, h)
			}
		}
	}

	// O(1) Double-Buffered Swap
	exec.active_nodes, exec.next_active_nodes = exec.next_active_nodes, exec.active_nodes
	clear(&exec.next_active_nodes)
	exec.step_count += 1
}

process_node_end :: proc(exec: ^Executor, h: Handle, status: Status) {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return

	node_end(exec, h, status)
	node.status = status

	if node.parent.idx != 0 {
		parent_status := node_on_child_stopped(exec, node.parent, h, status)
		p_node, p_ok := hm.get(&exec.pool, node.parent)
		if p_ok {
			old_parent_status := p_node.status
			p_node.status = parent_status
			if parent_status == .Completed || parent_status == .Failed {
				process_node_end(exec, node.parent, parent_status)
			} else if parent_status == .Running && old_parent_status == .Suspended {
				append(&exec.active_nodes, node.parent)
			}
		}
	} else {
		node_free(exec, h)
	}
}

abort_node :: proc(exec: ^Executor, h: Handle) {
	if h.idx == 0 do return
	node, ok := hm.get(&exec.pool, h)
	if !ok do return

	node_end(exec, h, .Aborted)
	node.status = .Aborted
}

node_start :: proc(exec: ^Executor, h: Handle) -> Status {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return .Failed

	switch &v in node.data {
	case Wait_Node:
		v.elapsed = 0
		dur := eval_get(v.duration)
		return dur <= 0 ? .Completed : .Running
	case Sequence_Node:
		if node.first_child.idx == 0 do return .Completed
		v.current_child = node.first_child
		enqueue_node(exec, v.current_child, h)
		return .Suspended
	case Select_Node:
		if node.first_child.idx == 0 do return .Completed
		v.current_child = node.first_child
		enqueue_node(exec, v.current_child, h)
		return .Suspended
	case Callback_Node:
		if v.thunk != nil {
			return v.thunk(v.callback_ptr, v.payload) ? .Completed : .Failed
		}
		return .Failed
	case Loop_Node:
		v.last_step = -1
		return .Running
	case Race_Node:
		if node.first_child.idx == 0 do return .Completed
		curr := node.first_child
		for curr.idx != 0 {
			enqueue_node(exec, curr, h)
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return .Suspended
	case Sync_Node:
		if node.first_child.idx == 0 do return .Completed
		v.closed_count = 0
		v.end_status = .Completed
		curr := node.first_child
		for curr.idx != 0 {
			enqueue_node(exec, curr, h)
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return .Suspended
	case Tween_Node:
		v.elapsed = 0
		v.resolved_start = eval_get(v.start)
		v.resolved_target = eval_get(v.target)
		v.resolved_duration = eval_get(v.duration)

		v.output^ = v.resolved_start
		return v.resolved_duration <= 0 ? .Completed : .Running
	case Condition_Node:
		return .Running
	case Scope_Node:
		enqueue_node(exec, node.first_child, h)
		return .Suspended
	case Not_Node:
		enqueue_node(exec, node.first_child, h)
		return .Suspended
	case Managed_Node:
		enqueue_node(exec, node.first_child, h)
		return .Suspended
	case Catch_Node:
		enqueue_node(exec, node.first_child, h)
		return .Suspended
	case Wait_Frames_Node:
		v.elapsed_frames = 0
		v.resolved_target = eval_get(v.target_frames)
		return v.resolved_target <= 0 ? .Completed : .Running
	case Capture_Return_Node:
		enqueue_node(exec, node.first_child, h)
		return .Suspended
	case Optional_Sequence_Node:
		if node.first_child.idx == 0 do return .Completed
		v.current_child = node.first_child
		enqueue_node(exec, v.current_child, h)
		return .Suspended
	case Semaphore_Handler_Node:
		if v.sem.current_active < v.sem.max_active {
			v.sem.current_active += 1
			v.acquired = true
			enqueue_node(exec, node.first_child, h)
			return .Suspended
		}
		append(&v.sem.queued, h)
		return .Suspended
	case Fork_Node:
		enqueue_node(exec, node.first_child, {})
		node.first_child = {}
		return .Completed
	case Wait_Forever_Node:
		return .Suspended
	case Weak_Node:
		if v.thunk != nil && !v.thunk(v.is_valid_ptr, v.payload) do return .Failed
		enqueue_node(exec, node.first_child, h)
		return .Running
	}
	return .Completed
}

node_update :: proc(exec: ^Executor, h: Handle, dt: f32) -> Status {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return .Failed

	#partial switch &v in node.data {
	case Wait_Node:
		v.elapsed += dt
		dur := eval_get(v.duration)
		return v.elapsed >= dur ? .Completed : .Running
	case Tween_Node:
		v.elapsed += dt
		alpha := clamp(v.elapsed / v.resolved_duration, 0.0, 1.0)
		e_alpha := v.ease != nil ? v.ease(alpha) : alpha
		v.output^ = v.resolved_start + (v.resolved_target - v.resolved_start) * e_alpha
		return v.elapsed >= v.resolved_duration ? .Completed : .Running
	case Condition_Node:
		if v.thunk != nil {
			return v.thunk(v.condition_ptr, v.payload) ? .Completed : .Running
		}
		return .Failed
	case Loop_Node:
		if exec.step_count != v.last_step {
			v.last_step = exec.step_count
			c_node, c_ok := hm.get(&exec.pool, node.first_child)
			if c_ok && c_node.status != .Running && c_node.status != .Suspended {
				enqueue_node(exec, node.first_child, h)
			}
		}
		return .Running
	case Wait_Frames_Node:
		v.elapsed_frames += 1
		return v.elapsed_frames >= v.resolved_target ? .Completed : .Running
	case Weak_Node:
		if v.thunk != nil && !v.thunk(v.is_valid_ptr, v.payload) {
			abort_node(exec, node.first_child)
			return .Failed
		}
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if !c_ok do return .Failed
		if c_node.status == .Completed do return .Completed
		if c_node.status == .Failed do return .Failed
		return .Running
	case:
		return node.status
	}
	return node.status
}

node_end :: proc(exec: ^Executor, h: Handle, status: Status) {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return

	#partial switch &v in node.data {
	case Sequence_Node:
		if status == .Aborted && v.current_child.idx != 0 {
			abort_node(exec, v.current_child)
		}
	case Select_Node:
		if status == .Aborted && v.current_child.idx != 0 {
			abort_node(exec, v.current_child)
		}
	case Optional_Sequence_Node:
		if status == .Aborted && v.current_child.idx != 0 {
			abort_node(exec, v.current_child)
		}
	case Loop_Node:
		if status == .Aborted {
			c_node, c_ok := hm.get(&exec.pool, node.first_child)
			if c_ok && (c_node.status == .None || c_node.status == .Running || c_node.status == .Suspended) {
				abort_node(exec, node.first_child)
			}
		}
	case Race_Node:
		if status == .Aborted {
			curr := node.first_child
			for curr.idx != 0 {
				child, c_ok := hm.get(&exec.pool, curr)
				if !c_ok do break
				if child.status == .None || child.status == .Running || child.status == .Suspended {
					abort_node(exec, curr)
				}
				curr = child.next_sibling
			}
		}
	case Sync_Node:
		if status == .Aborted {
			curr := node.first_child
			for curr.idx != 0 {
				child, c_ok := hm.get(&exec.pool, curr)
				if !c_ok do break
				if child.status == .None || child.status == .Running || child.status == .Suspended {
					abort_node(exec, curr)
				}
				curr = child.next_sibling
			}
		}
	case Scope_Node:
		if v.thunk != nil {
			v.thunk(v.on_exit_ptr, v.payload, status)
			v.thunk = nil
		}
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case Not_Node:
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case Managed_Node:
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case Catch_Node:
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case Capture_Return_Node:
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case Weak_Node:
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case:
		// No special handling
	}
}

node_on_child_stopped :: proc(exec: ^Executor, parent: Handle, child: Handle, status: Status) -> Status {
	p, ok := hm.get(&exec.pool, parent)
	if !ok do return .Failed

	#partial switch &v in p.data {
	case Sequence_Node:
		if status == .Failed do return .Failed
		c_node, c_ok := hm.get(&exec.pool, child)
		if !c_ok do return .Failed
		v.current_child = c_node.next_sibling
		if v.current_child.idx == 0 do return .Completed
		enqueue_node(exec, v.current_child, parent)
		return .Suspended
	case Select_Node:
		if status == .Completed do return .Completed
		c_node, c_ok := hm.get(&exec.pool, child)
		if !c_ok do return .Failed
		v.current_child = c_node.next_sibling
		if v.current_child.idx == 0 do return .Failed
		enqueue_node(exec, v.current_child, parent)
		return .Suspended
	case Optional_Sequence_Node:
		c_node, c_ok := hm.get(&exec.pool, child)
		if !c_ok do return .Failed
		v.current_child = c_node.next_sibling
		if v.current_child.idx == 0 do return .Completed
		enqueue_node(exec, v.current_child, parent)
		return .Suspended
	case Loop_Node:
		return status == .Failed ? .Completed : .Running
	case Race_Node:
		curr := p.first_child
		for curr.idx != 0 {
			if curr != child {
				other, o_ok := hm.get(&exec.pool, curr)
				if o_ok && (other.status == .None || other.status == .Running || other.status == .Suspended) {
					abort_node(exec, curr)
				}
			}
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return status
	case Sync_Node:
		if status == .Failed do v.end_status = .Failed
		v.closed_count += 1

		total_children := 0
		curr := p.first_child
		for curr.idx != 0 {
			total_children += 1
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}

		if v.closed_count == total_children do return v.end_status
		return .Suspended
	case Scope_Node:
		return status
	case Not_Node:
		if status == .Completed do return .Failed
		if status == .Failed do return .Completed
		return status
	case Managed_Node:
		return status
	case Catch_Node:
		if v.output != nil do v.output^ = (status == .Completed)
		return .Completed
	case Capture_Return_Node:
		v.output^ = (status == .Completed)
		return .Completed
	case Semaphore_Handler_Node:
		if v.acquired {
			semaphore_release(exec, v.sem)
			v.acquired = false
		}
		return status
	case Weak_Node:
		return status
	case:
		return .Failed
	}
	return .Failed
}

Semaphore :: struct {
	max_active:     int,
	current_active: int,
	queued:         [dynamic]Handle,
}

semaphore_init :: proc(sem: ^Semaphore, max_active: int, allocator := context.allocator) {
	sem.max_active = max_active
	sem.current_active = 0
	sem.queued = make([dynamic]Handle, allocator)
}

semaphore_destroy :: proc(sem: ^Semaphore) {
	delete(sem.queued)
}

semaphore_release :: proc(exec: ^Executor, sem: ^Semaphore) {
	if len(sem.queued) > 0 {
		h := sem.queued[0]
		ordered_remove(&sem.queued, 0)

		node, ok := hm.get(&exec.pool, h)
		if ok {
			if v, vok := &node.data.(Semaphore_Handler_Node); vok {
				v.acquired = true
				enqueue_node(exec, node.first_child, h)
			}
		}
	} else {
		sem.current_active = max(0, sem.current_active - 1)
	}
}

node_get_debug_info :: proc(exec: ^Executor, h: Handle, buf: []byte) -> string {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return ""

	#partial switch &v in node.data {
	case Wait_Node:
		dur := eval_get(v.duration)
		return fmt.bprintf(buf, "%.2f/%.2f s", v.elapsed, dur)
	case Sequence_Node:
		total := 0
		curr_idx := 0
		curr := node.first_child
		for curr.idx != 0 {
			total += 1
			if curr == v.current_child do curr_idx = total
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return fmt.bprintf(buf, "%d/%d", curr_idx, total)
	case Select_Node:
		total := 0
		curr_idx := 0
		curr := node.first_child
		for curr.idx != 0 {
			total += 1
			if curr == v.current_child do curr_idx = total
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return fmt.bprintf(buf, "%d/%d", curr_idx, total)
	case Tween_Node:
		return fmt.bprintf(buf, "%.0f%%", (v.elapsed / v.resolved_duration) * 100.0)
	case Wait_Frames_Node:
		return fmt.bprintf(buf, "%d/%d frames", v.elapsed_frames, v.resolved_target)
	case Optional_Sequence_Node:
		total := 0
		curr_idx := 0
		curr := node.first_child
		for curr.idx != 0 {
			total += 1
			if curr == v.current_child do curr_idx = total
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return fmt.bprintf(buf, "%d/%d", curr_idx, total)
	case Sync_Node:
		total := 0
		curr := node.first_child
		for curr.idx != 0 {
			total += 1
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return fmt.bprintf(buf, "%d/%d", v.closed_count, total)
	case Wait_Forever_Node:
		return "Forever"
	case:
		// No special debug info
	}
	return ""
}

diagnostics_notify_destroyed :: proc(exec: ^Executor, node: ^Node, depth: int) {
	if exec.debugger == nil || !exec.debugger.enabled || node == nil do return

	db := exec.debugger

	info_buf: [128]byte
	info_str := node_get_debug_info(exec, node.handle, info_buf[:])

	f := Fading_Node {
		name      = node.name,
		user_name = node.user_name,
		status    = node.status,
		end_time  = exec.total_time,
		depth     = depth,
		info      = strings.clone(info_str, db.allocator),
	}

	append(&db.fading_nodes, f)
}

// API Helpers

_add_node :: proc(name: string, data: Node_Data, loc := #caller_location) -> Handle {
	assert(context.user_ptr != nil, "Executor not found in context.user_ptr!", loc = loc)
	exec := (^Executor)(context.user_ptr)

	h, _ := hm.add(&exec.pool, Node{ name = name, data = data, handle = {} })
	node, _ := hm.get(&exec.pool, h)
	node.handle = h
	node.start_time = exec.total_time
	return h
}

_link_children :: proc(parent: Handle, children: []Handle, loc := #caller_location) {
	if len(children) == 0 do return
	assert(context.user_ptr != nil, "Executor not found in context.user_ptr!", loc = loc)
	exec := (^Executor)(context.user_ptr)

	p_node, p_ok := hm.get(&exec.pool, parent)
	if !p_ok do return

	last_valid: ^Node = nil

	for h in children {
		c_node, c_ok := hm.get(&exec.pool, h)
		if !c_ok do continue

		c_node.parent = parent
		if last_valid == nil {
			p_node.first_child = h
		} else {
			last_valid.next_sibling = h
		}
		last_valid = c_node
	}
}

// API

seq :: proc(nodes: ..Handle) -> Handle {
	h := _add_node("Sequence", Sequence_Node{})
	_link_children(h, nodes)
	return h
}

select :: proc(nodes: ..Handle) -> Handle {
	h := _add_node("Select", Select_Node{})
	_link_children(h, nodes)
	return h
}

sync :: proc(nodes: ..Handle) -> Handle {
	h := _add_node("Sync", Sync_Node{})
	_link_children(h, nodes)
	return h
}

race :: proc(nodes: ..Handle) -> Handle {
	h := _add_node("Race", Race_Node{})
	_link_children(h, nodes)
	return h
}

wait_val :: proc(duration: f32) -> Handle {
	exec := (^Executor)(context.user_ptr)
	h := _add_node("Wait", Wait_Node{duration = {val = duration}})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

wait_ptr :: proc(duration: ^f32) -> Handle {
	exec := (^Executor)(context.user_ptr)
	h := _add_node("WaitPtr", Wait_Node{duration = {ptr = duration}})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

wait :: proc {wait_val, wait_ptr}

run_typed :: proc(callback: proc(payload: ^$T) -> bool, payload: ^T = nil) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc(payload: ^T) -> bool)(cb)((^T)(p))
	}
	return _add_node("Callback", Callback_Node{callback_ptr = rawptr(callback), payload = rawptr(payload), thunk = thunk})
}

run_nil :: proc(callback: proc() -> bool) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc() -> bool)(cb)()
	}
	return _add_node("Callback", Callback_Node{callback_ptr = rawptr(callback), thunk = thunk})
}

run :: proc {run_nil, run_typed}
check :: run

loop :: proc(child: Handle) -> Handle {
	exec := (^Executor)(context.user_ptr)
	h := _add_node("Loop", Loop_Node{})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	_link_children(h, {child})
	return h
}

tween_val :: proc(start, target, duration: f32, output: ^f32, ease: Ease_Proc = nil) -> Handle {
	exec := (^Executor)(context.user_ptr)
	h := _add_node("Tween", Tween_Node{start = {val = start}, target = {val = target}, duration = {val = duration}, output = output, ease = ease})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

tween_ptr :: proc(start_ptr: ^f32, target: f32, duration: f32, output: ^f32, ease: Ease_Proc = nil) -> Handle {
	exec := (^Executor)(context.user_ptr)
	h := _add_node("TweenPtr", Tween_Node{start = {ptr = start_ptr}, target = {val = target}, duration = {val = duration}, output = output, ease = ease})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

tween :: proc {tween_val, tween_ptr}

wait_until_typed :: proc(condition: proc(payload: ^$T) -> bool, payload: ^T = nil) -> Handle {
	exec := (^Executor)(context.user_ptr)
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc(payload: ^T) -> bool)(cb)((^T)(p))
	}
	h := _add_node("WaitUntil", Condition_Node{condition_ptr = rawptr(condition), payload = rawptr(payload), thunk = thunk})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

wait_until_nil :: proc(condition: proc() -> bool) -> Handle {
	exec := (^Executor)(context.user_ptr)
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc() -> bool)(cb)()
	}
	h := _add_node("WaitUntil", Condition_Node{condition_ptr = rawptr(condition), thunk = thunk})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

wait_until :: proc {wait_until_typed, wait_until_nil}

scope_typed :: proc(child: Handle, on_exit: proc(payload: ^$T, status: Status), payload: ^T = nil) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr, status: Status) {
		(proc(payload: ^T, status: Status))(cb)((^T)(p), status)
	}
	h := _add_node("Scope", Scope_Node{on_exit_ptr = rawptr(on_exit), payload = rawptr(payload), thunk = thunk})
	_link_children(h, {child})
	return h
}

scope_nil :: proc(child: Handle, on_exit: proc(status: Status)) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr, status: Status) {
		(proc(status: Status))(cb)(status)
	}
	h := _add_node("Scope", Scope_Node{on_exit_ptr = rawptr(on_exit), thunk = thunk})
	_link_children(h, {child})
	return h
}

scope :: proc {scope_typed, scope_nil}

not :: proc(child: Handle) -> Handle {
	h := _add_node("Not", Not_Node{})
	_link_children(h, {child})
	return h
}

catch :: proc(child: Handle) -> Handle {
	h := _add_node("Catch", Catch_Node{})
	_link_children(h, {child})
	return h
}

managed :: proc(child: Handle, payload: rawptr, allocator := context.allocator) -> Handle {
	h := _add_node("Managed", Managed_Node{payload = payload, allocator = allocator})
	_link_children(h, {child})
	return h
}

wait_frames :: proc(frames: int) -> Handle {
	exec := (^Executor)(context.user_ptr)
	h := _add_node("WaitFrames", Wait_Frames_Node{target_frames = {val = frames}})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

capture_return :: proc(child: Handle, output_ptr: ^bool) -> Handle {
	h := _add_node("CaptureReturn", Capture_Return_Node{output = output_ptr})
	_link_children(h, {child})
	return h
}

optional_seq :: proc(nodes: ..Handle) -> Handle {
	h := _add_node("OptionalSequence", Optional_Sequence_Node{})
	_link_children(h, nodes)
	return h
}

semaphore_scope :: proc(sem: ^Semaphore, child: Handle) -> Handle {
	h := _add_node("Semaphore", Semaphore_Handler_Node{sem = sem})
	_link_children(h, {child})
	return h
}

fork :: proc(child: Handle) -> Handle {
	h := _add_node("Fork", Fork_Node{})
	_link_children(h, {child})
	return h
}

wait_forever :: proc() -> Handle {
	return _add_node("WaitForever", Wait_Forever_Node{})
}

weak_typed :: proc(child: Handle, is_valid: proc(payload: ^$T) -> bool, payload: ^T = nil) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc(payload: ^T) -> bool)(cb)((^T)(p))
	}
	h := _add_node("Weak", Weak_Node{is_valid_ptr = rawptr(is_valid), payload = rawptr(payload), thunk = thunk})
	_link_children(h, {child})
	return h
}

weak_nil :: proc(child: Handle, is_valid: proc() -> bool) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc() -> bool)(cb)()
	}
	h := _add_node("Weak", Weak_Node{is_valid_ptr = rawptr(is_valid), thunk = thunk})
	_link_children(h, {child})
	return h
}

weak :: proc {weak_typed, weak_nil}

named :: proc(h: Handle, name: string) -> Handle {
	exec := (^Executor)(context.user_ptr)
	if h.idx != 0 {
		node, ok := hm.get(&exec.pool, h)
		if ok do node.user_name = name
	}
	return h
}
