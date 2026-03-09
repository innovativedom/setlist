-- setlist
-- v0.2.0
-- A live performance mod for norns.
-- Organizes scripts + PSETs into 16 banks of 16 slots.
-- Each slot can be triggered by a keyboard key or MIDI program change.

local mod = require 'core/mods'

-- ---------------------------------------------------------------------------
-- Constants (DATA_PATH/SAVE_FILE set in system_post_startup — _path not ready at mod load)
-- ---------------------------------------------------------------------------

local NUM_BANKS = 16
local NUM_SLOTS = 16
local DATA_PATH = nil
local SAVE_FILE = nil

-- Available keyboard trigger keys (F1-F4 are reserved by system, so F6-F12 + others)
local KEY_OPTIONS = {
  "none",
  "F6","F7","F8","F9","F10","F11","F12",
  "1","2","3","4","5","6","7","8","9","0",
  "q","w","e","r","t","y","u","i","o","p",
  "a","s","d","f","g","h","j","k","l",
  "z","x","c","v","b","n","m",
  "SPACE","ENTER","TAB",
  "UP","DOWN","LEFT","RIGHT"
}

local CLOCK_OPTIONS = {"internal", "external"}
local TRIGGER_TYPE_OPTIONS = {"none", "keyboard", "midi_pc"}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local state = {
  banks = {},           -- [bank][slot] = slot_data
  current_bank = 1,
  current_slot = 1,
  midi_device = 1,      -- which midi port to listen on for PC messages
  pending_pset = nil,   -- pset to load after script_post_init fires
  pending_bpm = nil,    -- bpm to set after script_post_init fires
  pending_clock = nil,  -- "internal" or "external"
}

-- Default slot structure
local function default_slot()
  return {
    script = "",          -- e.g. "code/awake/awake.lua"
    pset = 1,             -- PSET slot number (1-99)
    trigger_type = "none",-- "none", "keyboard", "midi_pc"
    key = "none",         -- keyboard key string e.g. "F6"
    midi_pc = 0,          -- MIDI program change value 0-127
    clock_mode = "internal", -- "internal" or "external"
    bpm = 120,            -- BPM if clock_mode == "internal"
  }
end

-- Build empty bank/slot structure
local function init_banks()
  for b = 1, NUM_BANKS do
    state.banks[b] = {}
    for s = 1, NUM_SLOTS do
      state.banks[b][s] = default_slot()
    end
  end
end

-- ---------------------------------------------------------------------------
-- Persistence — tab.save/tab.load (norns built-in, no extra requires)
-- ---------------------------------------------------------------------------

local function ensure_data_dir()
  if DATA_PATH and not util.file_exists(DATA_PATH) then
    util.make_dir(DATA_PATH)
  end
end

local function save_data()
  if not DATA_PATH then return end
  ensure_data_dir()
  local err = tab.save({
    banks = state.banks,
    current_bank = state.current_bank,
    current_slot = state.current_slot,
    midi_device = state.midi_device,
  }, SAVE_FILE)
  if not err or type(err) ~= "string" then
    print("setlist: saved -> " .. SAVE_FILE)
  else
    print("setlist: ERROR could not write " .. SAVE_FILE)
  end
end

local function load_data()
  if not SAVE_FILE then return end
  if not util.file_exists(SAVE_FILE) then
    print("setlist: no save file, using defaults")
    return
  end
  local decoded = tab.load(SAVE_FILE)
  if decoded and type(decoded) == "table" then
    if decoded.banks then
      for b = 1, NUM_BANKS do
        if decoded.banks[b] then
          for s = 1, NUM_SLOTS do
            if decoded.banks[b][s] then
              local slot = default_slot()
              for k, v in pairs(decoded.banks[b][s]) do slot[k] = v end
              state.banks[b][s] = slot
            end
          end
        end
      end
    end
    state.current_bank = decoded.current_bank or 1
    state.current_slot = decoded.current_slot or 1
    state.midi_device = decoded.midi_device or 1
    print("setlist: loaded from " .. SAVE_FILE)
  else
    print("setlist: ERROR parsing save file, using defaults")
  end
end

-- ---------------------------------------------------------------------------
-- Trigger Execution
-- ---------------------------------------------------------------------------

local function get_script_name(script_path)
  return script_path:match("([^/]+)/[^/]+%.lua$") or script_path
end

local function index_of(t, val)
  for i, v in ipairs(t) do
    if v == val then return i end
  end
  return 1
end

-- Build list of available scripts by scanning dust/code
local function get_script_list()
  local list = {""}
  local pattern = _path.code .. "*/*.lua"
  local found = norns.system_glob(pattern)
  if found then
    for _, p in ipairs(found) do
      -- Only include files where filename matches parent folder (e.g. awake/awake.lua)
      local folder, file = p:match("/([^/]+)/([^/]+)%.lua$")
      if folder and file and folder == file then
        table.insert(list, folder .. "/" .. folder .. ".lua")
      end
    end
  end
  return list
end

local function fire_slot(bank, slot_num)
  local slot = state.banks[bank][slot_num]
  if not slot or slot.script == "" then return end

  state.current_bank = bank
  state.current_slot = slot_num

  -- Check if same script is already running → fast PSET-only swap
  local current = norns.state.script or ""
  local target_base = slot.script:gsub("%.lua$", "")
  if current:find(target_base, 1, true) then
    print("setlist: same script — fast PSET swap to slot " .. slot.pset)
    params:read(slot.pset)
    params:bang()
    if slot.clock_mode == "internal" then
      params:set("clock_tempo", slot.bpm)
    end
    return
  end

  -- Full script load
  print(string.format("setlist: firing b%d s%d → %s (pset %d)",
    bank, slot_num, slot.script, slot.pset))
  state.pending_pset = slot.pset
  state.pending_bpm = slot.bpm
  state.pending_clock = slot.clock_mode

  -- Resolve path: accept both "awake/awake.lua" and "code/awake/awake.lua"
  local script_path = slot.script:gsub("^code/", "")
  local full = _path.code .. script_path
  if util.file_exists(full) then
    norns.script.load("code/" .. script_path)
  else
    print("setlist: ERROR script not found: " .. full)
    state.pending_pset = nil
    state.pending_bpm = nil
    state.pending_clock = nil
  end
end

-- ---------------------------------------------------------------------------
-- MIDI listener
-- ---------------------------------------------------------------------------

local midi_watcher = nil

local function setup_midi()
  if midi_watcher then
    midi_watcher.event = nil
    midi_watcher = nil
  end
  local ok, dev = pcall(midi.connect, state.midi_device)
  if not ok or not dev then
    print("setlist: could not connect to MIDI port " .. state.midi_device)
    return
  end
  midi_watcher = dev
  midi_watcher.event = function(data)
    local ok2, msg = pcall(midi.to_msg, data)
    if not ok2 then return end
    if msg.type == "program_change" then
      local pc = msg.val
      for s = 1, NUM_SLOTS do
        local slot = state.banks[state.current_bank][s]
        if slot.trigger_type == "midi_pc" and slot.midi_pc == pc then
          fire_slot(state.current_bank, s)
          return
        end
      end
      for b = 1, NUM_BANKS do
        for s = 1, NUM_SLOTS do
          local slot = state.banks[b][s]
          if slot.trigger_type == "midi_pc" and slot.midi_pc == pc then
            fire_slot(b, s)
            return
          end
        end
      end
    end
  end
  print("setlist: MIDI watcher on port " .. state.midi_device)
end

-- ---------------------------------------------------------------------------
-- Keyboard listener (injected via system_post_startup hook)
-- ---------------------------------------------------------------------------

-- Captures CURRENT handler at call time (not startup) so we properly re-chain
-- each time a new script overwrites keyboard.code (e.g. in script_post_init).
local function setup_keyboard()
  local existing = keyboard.code  -- capture CURRENT handler, not startup handler
  keyboard.code = function(code, value)
    if value == 1 then
      for s = 1, NUM_SLOTS do
        local slot = state.banks[state.current_bank][s]
        if slot.trigger_type == "keyboard" and slot.key == code then
          fire_slot(state.current_bank, s)
          return
        end
      end
    end
    if existing and existing ~= keyboard.code then
      existing(code, value)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

mod.hook.register("system_post_startup", "setlist_startup", function()
  DATA_PATH = _path.data .. "setlist/"
  SAVE_FILE = DATA_PATH .. "setlist.data"
  init_banks()
  load_data()
  setup_midi()
  setup_keyboard()
  print("setlist: mod active ✓")
end)

mod.hook.register("script_post_init", "setlist_post_init", function()
  setup_keyboard()
  setup_midi()

  if state.pending_pset then
    local pset_to_load = state.pending_pset
    local bpm_to_set = state.pending_bpm
    local clock_to_set = state.pending_clock
    state.pending_pset = nil
    state.pending_bpm = nil
    state.pending_clock = nil

    clock.run(function()
      clock.sleep(0.3)
      print("setlist: applying pset " .. pset_to_load)
      params:read(pset_to_load)
      params:bang()
      clock.sleep(0.1)
      if clock_to_set == "internal" then
        params:set("clock_source", 1)
        if bpm_to_set then
          params:set("clock_tempo", bpm_to_set)
          print("setlist: BPM → " .. bpm_to_set)
        end
      elseif clock_to_set == "external" then
        params:set("clock_source", 2)
        print("setlist: clock → external MIDI")
      end
    end)
  end
end)

mod.hook.register("system_pre_shutdown", "setlist_shutdown", function()
  save_data()
end)

-- ---------------------------------------------------------------------------
-- Menu UI
-- ---------------------------------------------------------------------------

-- Menu pages
local PAGE_BANK    = 1
local PAGE_SLOT    = 2
local PAGE_EDIT    = 3
local PAGE_SETTINGS = 4

local menu_page = PAGE_BANK
local menu_pos = 1  -- position within current page

-- Edit page fields
local EDIT_FIELDS = {
  "script", "pset", "trigger_type", "key", "midi_pc", "clock_mode", "bpm"
}
local edit_field = 1

local m = {}

m.key = function(n, z)
  if z ~= 1 then return end

  if n == 2 then
    if menu_page == PAGE_BANK then
      mod.menu.exit()
    elseif menu_page == PAGE_SLOT then
      menu_page = PAGE_BANK
    elseif menu_page == PAGE_EDIT then
      menu_page = PAGE_SLOT
      save_data()
    elseif menu_page == PAGE_SETTINGS then
      menu_page = PAGE_BANK
      save_data()
    end
    mod.menu.redraw()

  elseif n == 3 then
    if menu_page == PAGE_BANK then
      state.current_bank = menu_pos
      menu_page = PAGE_SLOT
      menu_pos = state.current_slot
      mod.menu.redraw()
    elseif menu_page == PAGE_SLOT then
      state.current_slot = menu_pos
      menu_page = PAGE_EDIT
      edit_field = 1
      mod.menu.redraw()
    elseif menu_page == PAGE_EDIT then
      -- K3 on edit: fire this slot immediately
      fire_slot(state.current_bank, state.current_slot)
    elseif menu_page == PAGE_SETTINGS then
      -- nothing on K3 for settings
    end
  end
end

m.enc = function(n, d)
  if n == 2 then
    -- Scroll through list items
    if menu_page == PAGE_BANK then
      menu_pos = util.clamp(menu_pos + d, 1, NUM_BANKS)
    elseif menu_page == PAGE_SLOT then
      menu_pos = util.clamp(menu_pos + d, 1, NUM_SLOTS)
    elseif menu_page == PAGE_EDIT then
      edit_field = util.clamp(edit_field + d, 1, #EDIT_FIELDS)
    elseif menu_page == PAGE_SETTINGS then
      -- scroll setting rows (just midi_device for now)
    end

  elseif n == 3 then
    -- Change value of selected item
    local slot = state.banks[state.current_bank][state.current_slot]

    if menu_page == PAGE_BANK then
      -- E3 on bank page: switch active bank without entering slot page
      state.current_bank = util.clamp(state.current_bank + d, 1, NUM_BANKS)
      menu_pos = state.current_bank

    elseif menu_page == PAGE_SLOT then
      -- E3 on slot page: fire the hovered slot
      local s = util.clamp(menu_pos + d, 1, NUM_SLOTS)
      menu_pos = s

    elseif menu_page == PAGE_EDIT then
      local field = EDIT_FIELDS[edit_field]

      if field == "pset" then
        slot.pset = util.clamp(slot.pset + d, 1, 99)
      elseif field == "bpm" then
        slot.bpm = util.clamp(slot.bpm + d, 1, 300)
      elseif field == "midi_pc" then
        slot.midi_pc = util.clamp(slot.midi_pc + d, 0, 127)
      elseif field == "trigger_type" then
        local idx = index_of(TRIGGER_TYPE_OPTIONS, slot.trigger_type)
        idx = util.clamp(idx + d, 1, #TRIGGER_TYPE_OPTIONS)
        slot.trigger_type = TRIGGER_TYPE_OPTIONS[idx]
      elseif field == "key" then
        local idx = index_of(KEY_OPTIONS, slot.key)
        idx = util.clamp(idx + d, 1, #KEY_OPTIONS)
        slot.key = KEY_OPTIONS[idx]
      elseif field == "clock_mode" then
        local idx = index_of(CLOCK_OPTIONS, slot.clock_mode)
        idx = util.clamp(idx + d, 1, #CLOCK_OPTIONS)
        slot.clock_mode = CLOCK_OPTIONS[idx]
      elseif field == "script" then
        local list = get_script_list()
        local idx = index_of(list, slot.script)
        slot.script = list[util.clamp(idx + d, 1, #list)]
      end

    elseif menu_page == PAGE_SETTINGS then
      state.midi_device = util.clamp(state.midi_device + d, 1, 4)
      setup_midi()
    end
  end

  mod.menu.redraw()
end

m.redraw = function()
  screen.clear()
  screen.aa(0)
  screen.font_size(8)

  if menu_page == PAGE_BANK then
    screen.level(15)
    screen.move(2, 8)
    screen.text("SETLIST  banks")
    for i = 1, math.min(NUM_BANKS, 7) do
      local b = i
      local y = 8 + (i * 8)
      if b == menu_pos then
        screen.level(15)
        screen.move(2, y)
        screen.text("> bank " .. b)
      else
        screen.level(4)
        screen.move(8, y)
        screen.text("bank " .. b)
      end
    end
    -- Show current active bank/slot at bottom
    screen.level(3)
    screen.move(2, 62)
    screen.text("active: b" .. state.current_bank .. " s" .. state.current_slot)

  elseif menu_page == PAGE_SLOT then
    screen.level(15)
    screen.move(2, 8)
    screen.text("bank " .. state.current_bank .. "  slots")
    for i = 1, math.min(NUM_SLOTS, 7) do
      local s = i
      local slot = state.banks[state.current_bank][s]
      local y = 8 + (i * 8)
      local label = s .. ": "
      if slot.script ~= "" then
        label = label .. get_script_name(slot.script)
        if slot.trigger_type == "keyboard" and slot.key ~= "none" then
          label = label .. " [" .. slot.key .. "]"
        elseif slot.trigger_type == "midi_pc" then
          label = label .. " [PC" .. slot.midi_pc .. "]"
        end
      else
        label = label .. "---"
      end
      if s == menu_pos then
        screen.level(15)
        screen.move(2, y)
        screen.text("> " .. label)
      else
        screen.level(4)
        screen.move(4, y)
        screen.text(label)
      end
    end

  elseif menu_page == PAGE_EDIT then
    local slot = state.banks[state.current_bank][state.current_slot]
    screen.level(15)
    screen.move(2, 8)
    screen.text("b" .. state.current_bank .. " s" .. state.current_slot .. "  edit")

    local fields_display = {
      {"script",       slot.script ~= "" and get_script_name(slot.script) or "---"},
      {"pset",         tostring(slot.pset)},
      {"trigger",      slot.trigger_type},
      {"key",          slot.key},
      {"midi pc",      tostring(slot.midi_pc)},
      {"clock",        slot.clock_mode},
      {"bpm",          tostring(slot.bpm)},
    }

    for i, fd in ipairs(fields_display) do
      local y = 8 + (i * 8)
      if i == edit_field then
        screen.level(15)
        screen.move(2, y)
        screen.text("> " .. fd[1] .. ": " .. fd[2])
      else
        screen.level(4)
        screen.move(4, y)
        screen.text(fd[1] .. ": " .. fd[2])
      end
    end

    screen.level(2)
    screen.move(2, 62)
    screen.text("K3: fire slot now")

  elseif menu_page == PAGE_SETTINGS then
    screen.level(15)
    screen.move(2, 8)
    screen.text("SETLIST  settings")
    screen.level(10)
    screen.move(4, 24)
    screen.text("midi port: " .. state.midi_device)
    screen.level(3)
    screen.move(4, 40)
    screen.text("(for PC triggers)")
    screen.level(3)
    screen.move(2, 62)
    screen.text("K2: back  E3: change")
  end

  screen.update()
end

m.init = function()
  menu_page = PAGE_BANK
  menu_pos = state.current_bank
end

m.deinit = function() end

mod.menu.register(mod.this_name, m)

-- ---------------------------------------------------------------------------
-- Public API (optional, for scripts that want to interact with setlist)
-- ---------------------------------------------------------------------------

local api = {}

api.fire = function(bank, slot)
  fire_slot(bank, slot)
end

api.get_state = function()
  return state
end

return api
