# UVM Fundamentals — mapped onto this project

**19 August 2026.** Schedule rows 20–21 Aug. Companion to
`tb/uvm/uvm_hello.sv`, which is this document made runnable.

Read this, run the hello, then read it again. The four mechanisms below are
the whole of UVM's structure; everything after 22 August is filling them in.

---

## 1. Component or object?

The distinction that explains most of UVM's shape.

| | `uvm_component` | `uvm_object` |
|---|---|---|
| Lifetime | whole simulation | created and discarded |
| Hierarchy | yes — has a parent, has a full name | none |
| Phases | yes | **no** |
| Constructor | `new(string name, uvm_component parent)` | `new(string name)` |
| In this project | driver, monitor, sequencer, agent, env, scoreboard, coverage, test | `axi_transaction`, every sequence |

A transaction has no phases because it does not persist — it is data moving
through a structure, not part of the structure. If you ever find yourself
wanting a `build_phase` on a transaction, the design has gone wrong.

The constructor signatures are the tell. A component takes a parent because
that is what places it in the tree and makes `get_full_name()` meaningful —
which is what `config_db` path matching depends on (§4).

## 2. Phases

Phases exist so that every component agrees on *when* things happen without
any component knowing about the others.

| Phase | Function or task | Direction | Use it for |
|---|---|---|---|
| `build_phase` | function | **top-down** | create children, fetch config |
| `connect_phase` | function | **bottom-up** | connect ports and exports |
| `end_of_elaboration_phase` | function | bottom-up | inspect the built hierarchy |
| `start_of_simulation_phase` | function | bottom-up | print banners, final setup |
| `run_phase` | **task** | parallel | **the only phase that consumes time** |
| `extract` / `check` / `report` | function | bottom-up | end-of-test results |

**Why build is top-down.** A parent must exist before it can create its
children, and it must be able to place configuration where a child will look
for it *before* that child builds. `axi_base_test.build_phase` sets
`is_active` for `env.agent` and only then creates `env` — that ordering is
only legal because build is top-down.

**Why connect is bottom-up.** You cannot connect to something that does not
exist. By the time `connect_phase` runs, every component in the tree has been
built, so `agent.mon.ap.connect(sb.analysis_export)` is safe.

**Everything except `run_phase` is a function**, so it cannot consume time. A
`#10ns` in `build_phase` is a compile error, and that is deliberate: elaboration
happens at time zero.

### Objections

`run_phase` ends when the last objection is dropped. Nothing else stops it.

```systemverilog
phase.raise_objection(this, "running hello sequence");
seq.start(env.agent.sqr);
phase.drop_objection(this, "hello sequence done");
```

Forget the raise and the simulation ends at time zero with a passing report and
no traffic. This is the most common "my UVM test does nothing" cause, and it
produces no error — the run simply finishes. If a test prints its banner and
then exits, check objections first.

## 3. The hierarchy in this project

```
uvm_test_top  (axi_base_test)
└── env                      (axi_env)
    ├── agent                (axi_master_agent)
    │   ├── sqr              (uvm_sequencer #(axi_transaction))
    │   ├── drv              (axi_driver)
    │   └── mon              (axi_monitor)
    └── sb                   (axi_scoreboard)
```

`uvm_top.print_topology()` in `end_of_elaboration_phase` prints exactly this.
Run the hello and compare it against the README diagram — they should match,
because the hello was built from the diagram.

**The agent builds conditionally.** A passive agent creates only the monitor:
no driver, no sequencer. That is what the verification plan means by *"agent is
configurable active or passive, so it can be reused to observe a second port
later"* — the interconnect in September has more than one port worth watching.

## 4. `uvm_config_db`

The problem it solves: the driver needs the virtual interface, which only the
top-level module has. Passing it down through test → env → agent → driver by
constructor argument would mean every layer knows about something it does not
use.

```systemverilog
// producer — typically the top module, at time zero
uvm_config_db #(virtual axi4lite_if)::set(null, "*", "vif", intf);

// consumer — in the component's build_phase
if (!uvm_config_db #(virtual axi4lite_if)::get(this, "", "vif", vif))
    `uvm_fatal(get_type_name(), "no virtual interface in config_db")
```

Four things that go wrong, in order of how often:

1. **Type mismatch.** `set` and `get` must use the *same* parameter type. A
   `set` of `int` will not be found by a `get` of `uvm_active_passive_enum`.
   There is no warning — `get` simply returns 0.
2. **Timing.** The `set` must happen before the target component's
   `build_phase` runs. Top-down build order is what makes this work.
3. **Path.** The scope string is matched against the component's full name.
   `set(this, "env.agent", "is_active", ...)` targets exactly one component;
   `"*"` targets everything.
4. **Ignoring the return value.** `get` returns a bit. Always check it, and
   prefer `uvm_fatal` — a missing virtual interface produces a null-handle
   crash hundreds of nanoseconds later, with nothing pointing at the cause.

**Wildcards are convenient and dangerous.** `"*"` for the virtual interface is
normal, because everything wants the same one. `"*"` for `is_active` would make
every agent active, including one you deliberately made passive.

## 5. The factory

```systemverilog
drv = axi_driver::type_id::create("drv", this);   // not new()
```

`create()` asks the factory which type to build. `new()` hard-codes it. That
one difference is what lets a test change a component's type without editing
the component that instantiates it:

```systemverilog
set_type_override_by_type(axi_driver::get_type(), axi_driver_slow::get_type());
```

`axi_factory_test` in the hello does exactly this, and `axi_env` and
`axi_master_agent` are untouched. Run both tests and diff the logs.

**Why this matters here specifically.** The verification plan lists sixteen
tests. They share one environment. Every difference between them is either a
different sequence started in `run_phase` or a factory override — never a
separate copy of the environment. Sixteen environments would drift apart within
a fortnight.

The override must be registered **before** the overridden type is created,
which is why `axi_factory_test` calls `set_type_override_by_type` *before*
`super.build_phase(phase)`.

## 6. Sequence, sequencer, driver

The 21 August topic, previewed because the hello already contains it.

```
sequence                sequencer              driver
   |                        |                     |
   |-- start_item(it) ----->|                     |
   |                        |<-- get_next_item() -|
   |<---- (granted) --------|                     |
   |-- finish_item(it) ---->|-------- req ------->|
   |        BLOCKS          |                     | drive()
   |<-----------------------|<--- item_done() ----|
```

The sequence blocks inside `finish_item` until the driver calls `item_done()`.
That back-pressure is the point: a sequence cannot run ahead of the bus, so
stimulus generation is naturally paced by the DUT.

**Where this project diverges from the tutorials.** Almost every UVM example
drives one transaction to completion inside `drive()` before returning. This
driver must not: AW, W, B, AR and R are independent channels, and a driver that
locksteps them can never produce W-before-AW. From 23 August `drive()` hands
work to per-channel threads (`fork ... join_none`) rather than doing it inline.

`item_done()` timing then becomes a real design decision — return once the
transaction is *accepted* by the channel threads, or once it has fully
completed? That choice decides whether the driver can have more than one
transaction in flight, and the spec caps that at one read plus one write. It is
worth deciding deliberately on the 23rd rather than discovering it on the 27th.

## 7. What to be able to answer

1. Why is `build_phase` top-down and `connect_phase` bottom-up?
2. Why can't a transaction have phases?
3. A test prints its banner and immediately finishes with no traffic. First
   thing you check?
4. `uvm_config_db::get` returns 0 and the component crashes later on a null
   handle. Three plausible causes.
5. Why `type_id::create()` instead of `new()`?
6. Sixteen tests, one environment. What differs between two tests?
7. Why must a factory override be set before `super.build_phase()`?
8. Where does the sequence block, and why is that desirable?
9. Why can this project's driver not drive a transaction to completion inside
   `drive()`?
