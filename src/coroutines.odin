package main

import "core:fmt"
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
	parent: ^Node,
	status: Status,
	name: string,
}

Node_VTable :: struct {
	start: proc(self: ^Node, exec: ^Executor) -> Status,
	update: proc(self: ^Node, exec: ^Executor, dt: f32) -> Status,
	end: proc(self: ^Node, exec: ^Executor, status: Status),
	on_child_stopped: proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status,
	destroy: proc(self: ^Node),
}

Node_Exec_Info :: struct {
	node: ^Node,
	parent: ^Node,
	status: Status,
}

Executor :: struct {
	active_nodes: [dynamic]Node_Exec_Info,
	suspended_nodes: [dynamic]Node_Exec_Info,
	step_count: int,
}

executor_init :: proc(exec: ^Executor) {
	exec.active_nodes = make([dynamic]Node_Exec_Info)
	exec.suspended_nodes = make([dynamic]Node_Exec_Info)
	exec.step_count = 0
}

executor_destroy :: proc(exec: ^Executor) {
	for info in exec.active_nodes {
		if info.parent == nil && info.node != nil {
			destroy_node(info.node)
		}
	}
	for info in exec.suspended_nodes {
		if info.parent == nil && info.node != nil {
			destroy_node(info.node)
		}
	}
	delete(exec.active_nodes)
	delete(exec.suspended_nodes)
}

destroy_node :: proc(node: ^Node) {
	if node != nil {
		node.destroy(node)
	}
}

enqueue_node :: proc(exec: ^Executor, node: ^Node, parent: ^Node = nil) {
	node.parent = parent
	append(&exec.active_nodes, Node_Exec_Info {
		node = node,
		parent = parent,
		status = .None,
	})
}

executor_step :: proc(exec: ^Executor, dt: f32) {
	// filter out completed or aborted suspended nodes
	for i := len(exec.suspended_nodes) - 1; i >= 0; i -= 1 {
		if exec.suspended_nodes[i].status == .Aborted {
			unordered_remove(&exec.suspended_nodes, i)
		}
	}

	// start of the frame active nodes
	initial_active_count := len(exec.active_nodes)
	for i := 0; i < initial_active_count; i += 1 {
		if len(exec.active_nodes) == 0 do break

		info := pop(&exec.active_nodes)

		if info.status == .Aborted {
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

		// update running node
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

		// requeue running node for next frame
		inject_at(&exec.active_nodes, 0, info)
	}
	exec.step_count += 1
}

process_node_end :: proc(exec: ^Executor, info: ^Node_Exec_Info, status: Status) {
	info.node.end(info.node, exec, status)

	if info.parent != nil {
		parent_status := info.parent.on_child_stopped(info.parent, exec, status, info.node)
		if parent_status != .Suspended {
			// find parent in active or suspended nodes, to propagate status
			for &active_info in exec.active_nodes {
				if active_info.node == info.parent {
					active_info.status = parent_status
				}
			}
			for &suspended_info in exec.suspended_nodes {
				if suspended_info.node == info.parent {
					suspended_info.status = parent_status
					// move parent back to active if it woke up
					if parent_status != .Suspended {
						append(&exec.active_nodes, suspended_info)
						suspended_info.status = .Aborted // lazy deletion
					}
				}
			}
		}
	} else {
		// root node completed, clean it up
		destroy_node(info.node)
	}
}

abort_node :: proc(exec: ^Executor, node: ^Node) {
	if node == nil do return

	node.end(node, exec, .Aborted)
	node.status = .Aborted

	// mark others
	for &info in exec.active_nodes {
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
	using node: Node,
	duration: f32,
	elapsed: f32,
}

wait_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		wait := (^Wait_Node)(self)
		wait.elapsed = 0.0
		return wait.duration <= 0.0 ? .Completed : .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		wait := (^Wait_Node)(self)
		wait.elapsed += dt
		return wait.elapsed >= wait.duration ? .Completed : .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		return .Failed
	},
	destroy = proc(self: ^Node) {
		free(self)
	},
}

new_wait_node :: proc(duration: f32) -> ^Node {
	node := new(Wait_Node)
	node.base = &wait_vtable
	node.duration = duration
	node.name = "Wait"
	return node
}

Sequence_Node :: struct {
	using node: Node,
	children: [dynamic]^Node,
	child_index: int,
}

seq_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		seq := (^Sequence_Node)(self)
		if len(seq.children) == 0 do return .Completed
		seq.child_index = 0
		enqueue_node(exec, seq.children[seq.child_index], seq)
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		return .Suspended
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		seq := (^Sequence_Node)(self)
		if status == .Aborted {
			// abort current active child branch
			if seq.child_index < len(seq.children) {
				abort_node(exec, seq.children[seq.child_index])
			}
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		seq := (^Sequence_Node)(self)
		if status == .Failed {
			return .Failed
		}
		seq.child_index += 1
		if seq.child_index >= len(seq.children) {
			return .Completed
		}
		enqueue_node(exec, seq.children[seq.child_index], seq)
		return .Suspended
	},
	destroy = proc(self: ^Node) {
		seq := (^Sequence_Node)(self)
		for child in seq.children {
			destroy_node(child)
		}
		delete(seq.children)
		free(seq)
	},
}

new_sequence_node :: proc(children: []^Node) -> ^Node {
	node := new(Sequence_Node)
	node.base = &seq_vtable
	node.children = make([dynamic]^Node)
	for child in children {
		append(&node.children, child)
	}
	node.name = "Sequence"
	return node
}

Race_Node :: struct {
	using node: Node,
	children: [dynamic]^Node,
}

race_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		race := (^Race_Node)(self)
		if len(race.children) == 0 do return .Completed
		// start all children in parallel
		for child in race.children {
			enqueue_node(exec, child, race)
		}
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		return .Suspended
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		race := (^Race_Node)(self)
		if status == .Aborted {
			for child in race.children {
				if child.status == .Running || child.status == .Suspended {
					abort_node(exec, child)
				}
			}
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		race := (^Race_Node)(self)
		// abort all other children that are still active, because this child already finished
		for other in race.children {
			if other != child && (other.status == .Running) || other.status == .Suspended {
				abort_node(exec, other)
			}
		}
		return status
	},
	destroy = proc(self: ^Node) {
		race := (^Race_Node)(self)
		for child in race.children {
			destroy_node(child)
		}
		delete(race.children)
		free(race)
	},
}

new_race_node :: proc(children: []^Node) -> ^Node {
	node := new(Race_Node)
	node.base = &race_vtable
	node.children = make([dynamic]^Node)
	for child in children {
		append(&node.children, child)
	}
	node.name = "Race"
	return node
}

Loop_Node :: struct {
	using node: Node,
	child: ^Node,
	last_step: int,
}

loop_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		loop := (^Loop_Node)(self)
		loop.last_step = -1
		return .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		loop := (^Loop_Node)(self)
		if exec.step_count != loop.last_step {
			loop.last_step = exec.step_count
			if loop.child.status != .Running && loop.child.status != .Suspended {
				enqueue_node(exec, loop.child, loop)
			}
		}
		return .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		loop := (^Loop_Node)(self)
		if status == .Aborted && (loop.child.status == .Running || loop.child.status == .Suspended) {
			abort_node(exec, loop.child)
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		if status == .Failed {
			return .Completed // break loop on failure
		}
		return .Running
	},
	destroy = proc(self: ^Node) {
		loop := (^Loop_Node)(self)
		destroy_node(loop.child)
		free(loop)
	},
}

new_loop_node :: proc(child: ^Node) -> ^Node {
	node := new(Loop_Node)
	node.base = &loop_vtable
	node.child = child
	node.name = "Loop"
	return node
}

// _WaitFor - events/signaling between parallel branches, one can pause execution until another triggers an event

Event :: struct {
	listeners: [dynamic]^Listener_Node,
}

Listener_Node :: struct {
	using node: Node,
	event: ^Event,
	exec: ^Executor,
}

event_init :: proc(event: ^Event) {
	event.listeners = make([dynamic]^Listener_Node)
}

event_destroy :: proc(event: ^Event) {
	delete(event.listeners)
}

event_broadcast :: proc(event: ^Event) {
	// signal all listeners
	for i := len(event.listeners) - 1; i >= 0; i -= 1 {
		listener := event.listeners[i]
		if listener.exec != nil {
			force_node_end(listener.exec, listener, .Completed)
		}
	}
	clear(&event.listeners)
}

listener_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		listener := (^Listener_Node)(self)
		listener.exec = exec
		append(&listener.event.listeners, listener)
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		return .Suspended
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		listener := (^Listener_Node)(self)
		if status == .Aborted {
			for i := 0; i < len(listener.event.listeners); i += 1 {
				if listener.event.listeners[i] == listener {
					unordered_remove(&listener.event.listeners, i)
					break
				}
			}
		}
		listener.exec = nil
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		return .Failed
	},
	destroy = proc(self: ^Node) {
		free(self)
	},
}

new_wait_for_event_node :: proc(event: ^Event) -> ^Node {
	node := new(Listener_Node)
	node.base = &listener_vtable
	node.event = event
	node.name = "WaitForEvent"
	return node
}

force_node_end :: proc(exec: ^Executor, node: ^Node, status: Status) {
	for &info in exec.suspended_nodes {
		if info.node == node {
			info.status = status
			// wake up, move back to active queue
			append(&exec.active_nodes, info)
			info.status = .Aborted // lazy deletion
			break
		}
	}
}

Callback_Proc :: proc(data: rawptr) -> bool

Callback_Node :: struct {
	using node: Node,
	callback: Callback_Proc,
	payload: rawptr,
}

callback_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		cb := (^Callback_Node)(self)
		ok := cb.callback(cb.payload)
		return ok ? .Completed : .Failed
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		return .Completed
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		return .Failed
	},
	destroy = proc(self: ^Node) {
		free(self)
	},
}

new_callback_node :: proc(callback: Callback_Proc, payload: rawptr = nil) -> ^Node {
	node := new(Callback_Node)
	node.base = &callback_vtable
	node.callback = callback
	node.payload = payload
	node.name = "Callback"
	return node
}

// Helpers

seq :: proc(nodes: ..^Node) -> ^Node {
	children_slice := make([]^Node, len(nodes))
	copy(children_slice, nodes)
	return new_sequence_node(children_slice)
}

race :: proc(nodes: ..^Node) -> ^Node {
	children_slice := make([]^Node, len(nodes))
	copy(children_slice, nodes)
	return new_race_node(children_slice)
}

wait :: proc(duration: f32) -> ^Node {
	return new_wait_node(duration)
}

run :: proc(callback: Callback_Proc, payload: rawptr = nil) -> ^Node {
	return new_callback_node(callback, payload)
}

loop :: proc(child: ^Node) -> ^Node {
	return new_loop_node(child)
}

wait_until :: proc(condition: proc(data: rawptr) -> bool, payload: rawptr = nil) -> ^Node {
	Condition_Node :: struct {
		using node: Node,
		condition: proc(rawptr) -> bool,
		payload: rawptr,
	}

	vt := new(Node_VTable)
	vt^ = Node_VTable {
		start = proc(self: ^Node, exec: ^Executor) -> Status { return .Running },
		update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
			node := (^Condition_Node)(self)
			return node.condition(node.payload) ? .Completed : .Running
		},
		end = proc(self: ^Node, exec: ^Executor, status: Status) {},
		on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status { return .Failed },
		destroy = proc(self: ^Node) {
			free(self.base)
			free(self)
		}
	}

	node := new(Condition_Node)
	node.condition = condition
	node.payload = payload
	node.name = "WaitUntil"
	return node
}
