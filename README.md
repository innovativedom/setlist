# setlist

A live performance mod for monome norns.

Organize your set into **16 banks × 16 slots**. Each slot stores a script,
PSET number, clock settings, and a trigger (keyboard key or MIDI program change).
Fire a slot and norns will load the script, recall the PSET, and configure the clock.

## Installation

In maiden's REPL:
`;install https://github.com/innovativedom/setlist`

Or copy the folder to `~/dust/code/setlist/`.

Then go to `SYSTEM > MODS`, enable **setlist**, and restart norns.

## Setup

Access the mod menu at `SYSTEM > MODS > setlist >`.

### Navigation

- **E2** — scroll through list
- **K3** — select / enter
- **K2** — back / exit

### Pages

**Bank page** — choose one of 16 banks
**Slot page** — view/select up to 16 slots in the current bank
**Edit page** — configure a slot:

| Field   | Description                                                   |
| ------- | ------------------------------------------------------------- |
| script  | The script to load (cycles through installed scripts)         |
| pset    | PSET slot number to recall (1–99)                             |
| trigger | `none`, `keyboard`, or `midi_pc`                              |
| key     | Keyboard key to trigger this slot (e.g. `F6`, `F7`, `1`, `q`) |
| midi pc | MIDI program change value (0–127)                             |
| clock   | `internal` or `external`                                      |
| bpm     | BPM to set when clock is internal                             |

**K3 on the edit page fires the slot immediately** — useful for testing.

### Settings page

Set which MIDI port to listen on for program change messages.

## Notes

- **F1–F4 are reserved** by norns system and cannot be used as triggers.
  Use F6–F12 or any letter/number key instead.
- Script switching takes several seconds (full engine reload). This is normal.
- PSETs are loaded 200ms after `init()` completes to ensure all params are registered.
- Clock source param IDs (`clock_source`, `clock_tempo`) match norns system defaults.
  If a script overrides these param IDs, clock settings may not apply.
- setlist saves its configuration to `~/dust/data/setlist/setlist.json` on shutdown
  and whenever you exit the edit page.
