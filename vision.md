# Vision

Where this homelab is going. `goals.md` holds the current priority queue; this file holds the direction the queue
serves. It changes rarely, and only when the owner changes direction.

## In one sentence

A small fleet of ordinary machines, described entirely in Nix, on which AI agents do most of the engineering work
around the clock while the owner sets direction and looks in when they want.

## Four parts

### 1. A platform, not a pile of hosts

- One modular NixOS configuration. A machine gets a role by turning on a module.
- Services run as plain systemd units and nspawn containers. No container orchestrator.
- A module is written so that someone else could switch it on: typed options, sensible defaults, assertions for
  the illegal combinations, a short example.

### 2. An agent runtime that can be trusted with long work

- Work is one queue with priorities and protection against starvation.
- Agents run in disposable sandboxes that hold no credentials.
- Agents stay visible and steerable: interactive panes the owner can watch and type into.
- A piece of work can stop for a review, a deploy or a power-off and continue on any host.
- Its lasting state is what is in git (plus the conversation history in the queue), never a directory copied
  between machines.
- Work whose outside effects are unknown is never replayed automatically.

### 3. A system that tells us whether it got better

- Every change ships behind a switch, with a comparable metric and a regression alert, and is judged on the
  running system. No dedicated benchmarks, no long test rituals.
- Alerts are few and each one says what to do.
- Agent runs are queryable: where time and money went, per merged change.

### 4. Local inference that earns its place

- The GPU host serves models that are useful to the fleet's own agents; the gateway routes between local and
  hosted models.
- Paddock's SSD-backed MoE expert streaming is the bet that a large model can run on modest hardware, done well
  enough to contribute upstream.

## Principles

- Open source and Nix-native first. Upstream modules before home-made services.
- Little custom code. What is custom should be explainable in a job interview.
- Ship small, replace the old thing, fix forward. Downtime is acceptable, data loss is not.
- Iterate, do not perfect. Only safety, or "does not fix the problem", blocks a change.
- The owner decides direction, money and anything physical. Everything else is the coordinator's to decide and do.
- DNS stays up, secrets are never printed or committed, history is never force-pushed.

## What done looks like

- A new host joins by importing a profile and enabling roles.
- The owner states a goal; the queue, the agents and the deploys carry it to the running system; the metrics show
  whether it helped.
- A session that waits a day for input costs nothing while it waits and continues where it left off.
- The pool module and the Paddock work are things others can use.
