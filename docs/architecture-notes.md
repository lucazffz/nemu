# nemu Architecture Notes

## Current Architecture

Two threads, connected by three synchronization mechanisms:

- `render_mutex` — double-buffer swap for the pixel framebuffer
- `audio_chan` — 512-sample buffered channel for audio samples
- `log_mutex` — debug UI log buffer

All emulator components (CPU, PPU, APU, DMA) live in a single `Console` struct and execute together in `console_execute_clk_cycle` on a dedicated high-priority emulator thread.

---

## Bugs to Fix

**1. Frame pacing is accidental — `limit_frame_time` is dead code.**
The flag is set to `true` in `.Run` state but never read. The emulator runs at whatever speed the audio channel drain rate permits — timing is controlled entirely by backpressure from `chan.send` blocking when the 512-slot channel fills. If the audio callback stalls, the emulator hangs. If audio is silenced, it races to full CPU speed.

**2. Controller input polled from the wrong thread.**
`instruction_complete_cb` → `update_controller_input` calls `rl.IsKeyDown` / `rl.IsGamepadButtonDown` from the emulator thread. Raylib input functions must only be called from the main thread. This is a live race condition.

**3. Debug UI reads console state unsynchronized.**
`render_debug_ui` reads `g.emulator.console.cpu` and `g.emulator.console.ppu` while the emulator thread mutates them. The comment says "may cause data race but unsure if thats a problem" — it is a problem. Torn reads on multi-field structs produce incoherent debug values.

**4. `thread.terminate(th, 0)` hard-kills the emulator thread**, skipping all cleanup. Should signal the loop to exit cleanly and join.

**5. `frame_mutex` is declared but never used.** Dead field in global state.

**6. Pattern table rendering races with PPU state.** `ppu_pattern_table_palette_offset_to_buffer` is called from the UI thread while the emulator thread runs and mutates `ppu`.

---

## Recommendation 1: Keep the Two-Thread Model

The NES CPU, PPU, and APU are tightly coupled at the cycle level (PPU runs at 3× CPU clock, APU generates IRQs visible within the same cycle sequence, DMA halts the CPU). There is no safe way to run them on separate threads without synchronizing at every cycle boundary.

The correct thread boundary is exactly what exists:
- **Emulator thread**: all of `Console` (CPU, PPU, APU, DMA, cartridge). Nobody else touches it.
- **Main/UI thread**: Raylib window, ImGui debug UI, audio callback.

---

## Recommendation 2: Frame Pacing and Audio Timing

### The Core Problem: Two Clocks

The NES APU generates samples at a rate derived from the CPU clock (~1.789 MHz). The PC's audio hardware consumes samples at a fixed hardware rate (e.g. 44100 Hz). These are independent clocks and they will drift apart over time. Even a 0.01% difference compounds into audible glitches over a minute of play.

This is why time-based sleeping alone is insufficient — it controls frame rate but ignores the clock domain mismatch. After a few minutes, the audio buffer either:
- Slowly fills → increasing latency, then stutter when it overflows
- Slowly drains → crackling/silence when it underruns

### The Three Approaches

**Option A — Time-based sleep (simple, insufficient long-term):**
```odin
if frame_complete {
    elapsed := time.diff(frame_start, time.now())
    remaining := g.emulator.target_frame_time - elapsed
    if remaining > 0 do time.sleep(remaining)
    frame_start = time.now()
}
```
Ignores clock drift. Works for ~30 seconds, breaks subtly over longer play sessions. Audio artifacts are easy to hear.

**Option B — Audio backpressure (current approach, correct concept, fragile implementation):**
Block `chan.send` when the buffer is full, letting the audio callback set the pace. If the audio callback hiccups the emulator hangs. If audio is muted timing breaks entirely.

**Option C — Dynamic Rate Control (recommended):**
Use time-based pacing as the primary mechanism, but continuously monitor the audio buffer fill level and make tiny speed adjustments (~0.5–2%) to compensate for clock drift. This is what RetroArch, mesen, and other production emulators use.

```odin
target_speed = 1.0
fill_ratio = audio_buffer_fill / audio_buffer_capacity

if fill_ratio > 0.75 do target_speed = 0.998  // buffer filling, slow down slightly
if fill_ratio < 0.25 do target_speed = 1.002  // buffer draining, speed up slightly
```

### Recommendation

Keep audio as the master clock but implement it properly:

1. Replace `chan.Chan(f64)` with a **ring buffer** (~2048–4096 samples) with non-blocking writes
2. The emulator loop **checks fill level** each frame and adjusts sleep duration accordingly
3. If the buffer runs dry, the audio callback emits silence rather than blocking
4. If audio is disabled entirely, fall back to pure time-based sleep

This gives correct audio timing by construction, no hangs on audio callback stalls, and resilience to muting. For NES emulation specifically — where APU timing affects gameplay (games use audio IRQs for timing) — audio-driven with dynamic rate control is the right long-term architecture.

---

## Recommendation 3: Fix Controller Input — Atomic Button State

`Buttons` is a `bit_set` backed by a single byte — safe to use with atomics.

**In global state:**
```odin
controller1_buttons: intrinsics.Atomic_Type(u8),
controller2_buttons: intrinsics.Atomic_Type(u8),
```

**In the main loop (UI thread, once per frame):**
```odin
buttons_1, buttons_2 := gather_input()
intrinsics.atomic_store(&g.controller1_buttons, transmute(u8)buttons_1)
intrinsics.atomic_store(&g.controller2_buttons, transmute(u8)buttons_2)
```

**In the emulator thread (replacing `instruction_complete_cb → update_controller_input`):**
```odin
b1 := transmute(emu.Buttons)intrinsics.atomic_load(&g.controller1_buttons)
emu.controller_set_buttons(&g.emulator.console.controller1, b1)
```

Remove `update_controller_input` from `instruction_complete_cb`. Input latency becomes one video frame (16ms), matching actual NES hardware behavior.

---

## Recommendation 4: Snapshot Emulator State for Debug UI

Instead of the UI thread reaching into `g.emulator.console.cpu` and `.ppu` directly, fill a snapshot struct at the same point as the buffer swap (emulator thread):

```odin
debug_snapshot: struct {
    cpu:          emu.CPU,
    ppu_scanline: int,
    ppu_cycle:    int,
    // ... selected PPU fields, not the full struct
},
```

**In `frame_complete_cb` (emulator thread), piggybacked on the existing render_mutex lock:**
```odin
frame_complete_cb :: proc() {
    sync.mutex_lock(&g.view.render_mutex)
    temp := g.view.front_buffer
    g.view.front_buffer = g.view.back_buffer
    g.view.back_buffer = temp
    g.debug_snapshot.cpu = g.emulator.console.cpu   // copy by value
    g.debug_snapshot.ppu_scanline = g.emulator.console.ppu.scanline
    sync.mutex_unlock(&g.view.render_mutex)
}
```

Two mutex acquisitions unified into one, CPU/PPU race eliminated. Cost: one struct copy per frame, negligible.

For the pattern table debug view: only call `ppu_pattern_table_palette_offset_to_buffer` while the emulator is paused, or snapshot the CHR data similarly.

---

## Recommendation 5: Clean Thread Shutdown

Replace `thread.terminate(th, 0)` with cooperative shutdown:

```odin
// Emulator loop:
for !intrinsics.atomic_load(&g.should_exit) {
    // ... existing switch
}

// After main_loop() returns:
intrinsics.atomic_store(&g.should_exit, true)
thread.join(th)
shutdown()
```

`should_exit` already exists in global state — it just needs to be checked in the emulator loop and read/written atomically.

---

## Consolidated Synchronization Surface

After all changes, the full synchronization surface:

| What | Mechanism | Writer | Reader |
|------|-----------|--------|--------|
| Pixel framebuffer | `render_mutex` + pointer swap | Emulator thread | UI thread |
| CPU/PPU snapshot | Same `render_mutex` (piggybacked) | Emulator thread | UI thread |
| Audio samples | Ring buffer + atomic fill counter | Emulator thread | Audio callback |
| Controller buttons | Atomic `u8` ×2 | UI thread | Emulator thread |
| Log buffer | `log_mutex` | Both | UI thread |
| Shutdown signal | Atomic `bool` | UI thread | Emulator thread |

Remove `frame_mutex` (dead field).

---

## Structural Note on `main.odin`

At 1341 lines, the file contains everything: main loop, emulator loop, initialization, all debug views. Splitting by concern into separate files in the same package makes thread ownership immediately visible from file structure:

- `main.odin` — entry point, `initialize`, `shutdown`
- `emulator_loop.odin` — `emulator_loop`, `frame_complete_cb`, exec helpers
- `ui.odin` — `main_loop`, `render_debug_ui`, `init_debug_ui`
- `input.odin` — `update_controller_input`, gamepad handling

Same Odin package, no architecture change — just clarity on which thread owns which procedures.

---

## Critical Files

- `src/main.odin` — all fixes land here (1341 lines, contains everything)
- `src/emulator/console.odin` — `console_execute_clk_cycle`, completion callbacks
- `src/emulator/controller.odin` — `Buttons` bit_set, target of atomic input refactor
- `src/emulator/apu.odin` — `apu_query_sample`, current unintentional timing source
- `src/emulator/ppu.odin` — PPU struct fields read unsafely by debug UI
