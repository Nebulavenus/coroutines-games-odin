package main

import "core:mem"

Status :: enum {
	None,
	Completed,
	Failed,
	Running,
	Suspended,
	Aborted,
}

Node :: struct {
	using base: ^Node_VTable,
	parent:     ^Node,
	status:     Status,
	name:       string,
}

Node_VTable :: struct {
	start:            proc(self: ^Node, exec: ^Executor) -> Status,
	update:           proc(self: ^Node, exec: ^Executor, dt: f32) -> Status,
	end:              proc(self: ^Node, exec: ^Executor, status: Status),
	on_child_stopped: proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status,
	destroy:          proc(self: ^Node, allocator: mem.Allocator),
}

Node_Exec_Info :: struct {
	node:   ^Node,
	parent: ^Node,
	status: Status,
}

Executor :: struct {
	active_nodes:      [dynamic]Node_Exec_Info,
	next_active_nodes: [dynamic]Node_Exec_Info,
	suspended_nodes:   [dynamic]Node_Exec_Info,
	step_count:        int,
	allocator:         mem.Allocator,
}

executor_init :: proc(exec: ^Executor, allocator := context.allocator) {
	exec.allocator = allocator
	exec.active_nodes = make([dynamic]Node_Exec_Info, allocator)
	exec.next_active_nodes = make([dynamic]Node_Exec_Info, allocator)
	exec.suspended_nodes = make([dynamic]Node_Exec_Info, allocator)
	exec.step_count = 0
}

executor_destroy :: proc(exec: ^Executor) {
	for info in exec.active_nodes {
		if info.parent == nil && info.node != nil {
			destroy_node(info.node, exec.allocator)
		}
	}
	for info in exec.next_active_nodes {
		if info.parent == nil && info.node != nil {
			destroy_node(info.node, exec.allocator)
		}
	}
	for info in exec.suspended_nodes {
		if info.parent == nil && info.node != nil {
			destroy_node(info.node, exec.allocator)
		}
	}
	delete(exec.active_nodes)
	delete(exec.next_active_nodes)
	delete(exec.suspended_nodes)
}

destroy_node :: proc(node: ^Node, allocator: mem.Allocator) {
	if node != nil {
		node.destroy(node, allocator)
	}
}

enqueue_node :: proc(exec: ^Executor, node: ^Node, parent: ^Node = nil) {
	node.parent = parent
	append(&exec.active_nodes, Node_Exec_Info{node = node, parent = parent, status = .None})
}

executor_step :: proc(exec: ^Executor, dt: f32) {
	for i := len(exec.suspended_nodes) - 1; i >= 0; i -= 1 {
		if exec.suspended_nodes[i].status == .Aborted {
			if exec.suspended_nodes[i].parent == nil {
				destroy_node(exec.suspended_nodes[i].node, exec.allocator)
			}
			unordered_remove(&exec.suspended_nodes, i)
		}
	}

	i := 0
	for i < len(exec.active_nodes) {
		info := exec.active_nodes[i]
		i += 1

		if info.status == .Aborted {
			if info.parent == nil {
				destroy_node(info.node, exec.allocator)
			}
			continue
		}

		if info.status == .None {
			info.status = info.node.start(info.node, exec)
			info.node.status = info.status

			if info.status == .Suspended {
				append(&exec.suspended_nodes, info)
				continue
			}
			if info.status == .Completed || info.status == .Failed {
				process_node_end(exec, &info, info.status)
				continue
			}
		}

		if info.status == .Running {
			info.status = info.node.update(info.node, exec, dt)
			info.node.status = info.status

			if info.status == .Suspended {
				append(&exec.suspended_nodes, info)
				continue
			}
			if info.status == .Completed || info.status == .Failed {
				process_node_end(exec, &info, info.status)
				continue
			}

			append(&exec.next_active_nodes, info)
		}

		if info.status == .Completed || info.status == .Failed {
			process_node_end(exec, &info, info.status)
			continue
		}
	}

	clear(&exec.active_nodes)
	for info in exec.next_active_nodes {
		append(&exec.active_nodes, info)
	}
	clear(&exec.next_active_nodes)
	exec.step_count += 1
}

process_node_end :: proc(exec: ^Executor, info: ^Node_Exec_Info, status: Status) {
	info.node.end(info.node, exec, status)
	info.node.status = status

	if info.parent != nil {
		parent_status := info.parent.on_child_stopped(info.parent, exec, status, info.node)

		for j := 0; j < len(exec.active_nodes); j += 1 {
			if exec.active_nodes[j].node == info.parent {
				exec.active_nodes[j].status = parent_status
			}
		}

		for j := len(exec.next_active_nodes) - 1; j >= 0; j -= 1 {
			if exec.next_active_nodes[j].node == info.parent {
				if parent_status != .Running {
					p := exec.next_active_nodes[j]
					p.status = parent_status
					append(&exec.active_nodes, p)
					unordered_remove(&exec.next_active_nodes, j)
				} else {
					exec.next_active_nodes[j].status = parent_status
				}
			}
		}

		for j := len(exec.suspended_nodes) - 1; j >= 0; j -= 1 {
			if exec.suspended_nodes[j].node == info.parent {
				if parent_status != .Suspended {
					p := exec.suspended_nodes[j]
					p.status = parent_status
					append(&exec.active_nodes, p)
					unordered_remove(&exec.suspended_nodes, j)
				} else {
					exec.suspended_nodes[j].status = parent_status
				}
			}
		}
	} else {
		destroy_node(info.node, exec.allocator)
	}
}

abort_node :: proc(exec: ^Executor, node: ^Node) {
	if node == nil do return
	node.end(node, exec, .Aborted)
	node.status = .Aborted

	for &info in exec.active_nodes {
		if info.node == node {
			info.status = .Aborted
		}
	}
	for &info in exec.next_active_nodes {
		if info.node == node {
			info.status = .Aborted
		}
	}
	for &info in exec.suspended_nodes {
		if info.node == node {
			info.status = .Aborted
		}
	}
}

Wait_Node :: struct {
	using node:        Node,
	duration, elapsed: f32,
}

wait_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		w := (^Wait_Node)(self); w.elapsed = 0; return w.duration <= 0 ? .Completed : .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		w := (^Wait_Node)(
			self,
		); w.elapsed += dt; return w.elapsed >= w.duration ? .Completed : .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {free(self, allocator)},
}

Sequence_Node :: struct {
	using node:  Node,
	children:    [dynamic]^Node,
	child_index: int,
}

seq_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		s := (^Sequence_Node)(self); if len(s.children) == 0 do return .Completed
		s.child_index = 0; enqueue_node(exec, s.children[s.child_index], s); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		s := (^Sequence_Node)(self); if status == .Aborted && s.child_index < len(s.children) {
			abort_node(exec, s.children[s.child_index])
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		s := (^Sequence_Node)(self); if status == .Failed do return .Failed
		s.child_index += 1; if s.child_index >= len(s.children) do return .Completed
		enqueue_node(exec, s.children[s.child_index], s); return .Suspended
	},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {
		s := (^Sequence_Node)(self); for c in s.children do destroy_node(c, allocator)
		delete(s.children); free(s, allocator)
	},
}

Select_Node :: struct {
	using node:  Node,
	children:    [dynamic]^Node,
	child_index: int,
}

select_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		s := (^Select_Node)(self); if len(s.children) == 0 do return .Completed
		s.child_index = 0; enqueue_node(exec, s.children[s.child_index], s); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		s := (^Select_Node)(self); if status == .Aborted && s.child_index < len(s.children) {
			abort_node(exec, s.children[s.child_index])
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		s := (^Select_Node)(self); if status == .Completed do return .Completed
		s.child_index += 1; if s.child_index >= len(s.children) do return .Failed
		enqueue_node(exec, s.children[s.child_index], s); return .Suspended
	},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {
		s := (^Select_Node)(self); for c in s.children do destroy_node(c, allocator)
		delete(s.children); free(s, allocator)
	},
}

Callback_Proc :: proc(data: rawptr) -> bool

Callback_Node :: struct {
	using node: Node,
	callback:   Callback_Proc,
	payload:    rawptr,
}

callback_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		c := (^Callback_Node)(self); return c.callback(c.payload) ? .Completed : .Failed
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Completed},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {free(self, allocator)},
}

Loop_Node :: struct {
	using node: Node,
	child:      ^Node,
	last_step:  int,
}

loop_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		l := (^Loop_Node)(self); l.last_step = -1; return .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		l := (^Loop_Node)(self)
		if exec.step_count != l.last_step {
			l.last_step = exec.step_count
			if l.child.status != .Running && l.child.status != .Suspended {
				enqueue_node(exec, l.child, l)
			}
		}
		return .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		l := (^Loop_Node)(self)
		if status == .Aborted &&
		   (l.child.status == .None ||
				   l.child.status == .Running ||
				   l.child.status == .Suspended) {
			abort_node(exec, l.child)
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		return status == .Failed ? .Completed : .Running
	},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {
		l := (^Loop_Node)(self); destroy_node(l.child, allocator); free(l, allocator)
	},
}

Race_Node :: struct {
	using node: Node,
	children:   [dynamic]^Node,
}

race_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		r := (^Race_Node)(self); if len(r.children) == 0 do return .Completed
		for c in r.children do enqueue_node(exec, c, r)
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		r := (^Race_Node)(self)
		if status == .Aborted {
			for c in r.children {
				if c.status == .None || c.status == .Running || c.status == .Suspended do abort_node(exec, c)
			}
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		r := (^Race_Node)(self)
		for other in r.children {
			if other != child &&
			   (other.status == .None || other.status == .Running || other.status == .Suspended) {
				abort_node(exec, other)
			}
		}
		return status
	},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {
		r := (^Race_Node)(self); for c in r.children do destroy_node(c, allocator)
		delete(r.children); free(r, allocator)
	},
}

Sync_Node :: struct {
	using node:   Node,
	children:     [dynamic]^Node,
	closed_count: int,
	end_status:   Status,
}

sync_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		s := (^Sync_Node)(self); if len(s.children) == 0 do return .Completed
		s.closed_count = 0; s.end_status = .Completed
		for c in s.children do enqueue_node(exec, c, s)
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		s := (^Sync_Node)(self)
		if status == .Aborted {
			for c in s.children {
				if c.status == .None || c.status == .Running || c.status == .Suspended do abort_node(exec, c)
			}
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		s := (^Sync_Node)(self)
		if status == .Failed do s.end_status = .Failed
		s.closed_count += 1
		if s.closed_count == len(s.children) {
			return s.end_status
		}
		return .Suspended
	},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {
		s := (^Sync_Node)(self); for c in s.children do destroy_node(c, allocator)
		delete(s.children); free(s, allocator)
	},
}

Tween_Node :: struct {
	using node:                               Node,
	start_val, target_val, duration, elapsed: f32,
	output:                                   ^f32,
}

tween_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		t := (^Tween_Node)(self); t.elapsed = 0; t.output^ = t.start_val
		return t.duration <= 0 ? .Completed : .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		t := (^Tween_Node)(self); t.elapsed += dt
		alpha := clamp(t.elapsed / t.duration, 0.0, 1.0)
		t.output^ = t.start_val + (t.target_val - t.start_val) * alpha
		return t.elapsed >= t.duration ? .Completed : .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {free(self, allocator)},
}

Condition_Node :: struct {
	using node: Node,
	condition:  proc(_: rawptr) -> bool,
	payload:    rawptr,
}

condition_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {return .Running},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		c := (^Condition_Node)(self); return c.condition(c.payload) ? .Completed : .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {free(self, allocator)},
}

Scope_Node :: struct {
	using node: Node,
	child:      ^Node,
	on_exit:    proc(data: rawptr, status: Status),
	payload:    rawptr,
}

scope_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		s := (^Scope_Node)(self); enqueue_node(exec, s.child, s); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		s := (^Scope_Node)(self); s.on_exit(s.payload, status)
		if status == .Aborted && (s.child.status == .Running || s.child.status == .Suspended) {
			abort_node(exec, s.child)
		}
	},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return status},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {
		s := (^Scope_Node)(self); destroy_node(s.child, allocator); free(s, allocator)
	},
}

Not_Node :: struct {
	using node: Node,
	child:      ^Node,
}

not_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		n := (^Not_Node)(self); enqueue_node(exec, n.child, n); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		n := (^Not_Node)(
			self,
		); if status == .Aborted && (n.child.status == .Running || n.child.status == .Suspended) {
			abort_node(exec, n.child)
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		if status == .Completed do return .Failed
		if status == .Failed do return .Completed
		return status
	},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {
		n := (^Not_Node)(self); destroy_node(n.child, allocator); free(n, allocator)
	},
}

Catch_Node :: struct {
	using node: Node,
	child:      ^Node,
}

catch_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		c := (^Catch_Node)(self); enqueue_node(exec, c.child, c); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		c := (^Catch_Node)(
			self,
		); if status == .Aborted && (c.child.status == .Running || c.child.status == .Suspended) {
			abort_node(exec, c.child)
		}
	},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Completed},
	destroy = proc(self: ^Node, allocator: mem.Allocator) {
		c := (^Catch_Node)(self); destroy_node(c.child, allocator); free(c, allocator)
	},
}

// api

seq :: proc(nodes: ..^Node, allocator := context.allocator) -> ^Node {
	node := new(Sequence_Node, allocator); node.base = &seq_vtable
	node.children = make([dynamic]^Node, allocator)
	for n in nodes do append(&node.children, n)
	node.name = "Sequence"; return node
}

select :: proc(nodes: ..^Node, allocator := context.allocator) -> ^Node {
	node := new(Select_Node, allocator); node.base = &select_vtable
	node.children = make([dynamic]^Node, allocator)
	for n in nodes do append(&node.children, n)
	node.name = "Select"; return node
}

sync :: proc(nodes: ..^Node, allocator := context.allocator) -> ^Node {
	node := new(Sync_Node, allocator); node.base = &sync_vtable
	node.children = make([dynamic]^Node, allocator)
	for n in nodes do append(&node.children, n)
	node.name = "Sync"; return node
}

race :: proc(nodes: ..^Node, allocator := context.allocator) -> ^Node {
	node := new(Race_Node, allocator); node.base = &race_vtable
	node.children = make([dynamic]^Node, allocator)
	for n in nodes do append(&node.children, n)
	node.name = "Race"; return node
}

wait :: proc(duration: f32, allocator := context.allocator) -> ^Node {
	node := new(Wait_Node, allocator); node.base = &wait_vtable; node.duration = duration
	node.name = "Wait"; return node
}

run :: proc(
	callback: Callback_Proc,
	payload: rawptr = nil,
	allocator := context.allocator,
) -> ^Node {
	node := new(Callback_Node, allocator); node.base = &callback_vtable
	node.callback = callback; node.payload = payload; node.name = "Callback"
	return node
}

loop :: proc(child: ^Node, allocator := context.allocator) -> ^Node {
	node := new(Loop_Node, allocator); node.base = &loop_vtable; node.child = child
	node.name = "Loop"; return node
}

tween :: proc(
	start, target, duration: f32,
	output: ^f32,
	allocator := context.allocator,
) -> ^Node {
	node := new(Tween_Node, allocator); node.base = &tween_vtable
	node.start_val =
		start; node.target_val = target; node.duration = duration; node.output = output
	node.name = "Tween"; return node
}

wait_until :: proc(
	condition: proc(_: rawptr) -> bool,
	payload: rawptr = nil,
	allocator := context.allocator,
) -> ^Node {
	node := new(Condition_Node, allocator); node.base = &condition_vtable
	node.condition = condition; node.payload = payload; node.name = "WaitUntil"
	return node
}

scope :: proc(
	child: ^Node,
	on_exit: proc(_: rawptr, _: Status),
	payload: rawptr = nil,
	allocator := context.allocator,
) -> ^Node {
	node := new(Scope_Node, allocator); node.base = &scope_vtable
	node.child = child; node.on_exit = on_exit; node.payload = payload
	node.name = "Scope"; return node
}

not :: proc(child: ^Node, allocator := context.allocator) -> ^Node {
	node := new(Not_Node, allocator); node.base = &not_vtable; node.child = child
	node.name = "Not"; return node
}

catch :: proc(child: ^Node, allocator := context.allocator) -> ^Node {
	node := new(Catch_Node, allocator); node.base = &catch_vtable; node.child = child
	node.name = "Catch"; return node
}

