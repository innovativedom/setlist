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
  learning_key = false,
  learning_midi_pc = false,
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
    if msg and msg.type == "program_change" then
      local pc = msg.val
      -- Learn mode: capture next PC for midi_pc field
      if state.learning_midi_pc then
        local slot = state.banks[state.current_bank][state.current_slot]
        if slot then
          slot.midi_pc = pc
          state.learning_midi_pc = false
          print("setlist: learned MIDI PC " .. pc)
        end
        mod.menu.redraw()
        return
      end
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
-- Keyboard listener — hook keyboard.event to capture keys even when menu is open
-- ---------------------------------------------------------------------------

-- Map HID key code (number) to our KEY_OPTIONS format. Skip modifiers.
local function hid_code_to_key_name(code)
  if not code then return nil end
  local codes = keyboard.codes
  if not codes then return tostring(code) end  -- fallback if codes table missing
  local name = codes[code]
  if not name then return nil end
  -- Skip modifier keys
  if name:find("SHIFT") or name:find("CTRL") or name:find("ALT") or name:find("META") then
    return nil
  end
  -- Normalize: F1 -> F1, Q -> q, SPACE -> SPACE, etc.
  if name:match("^F%d+$") then
    return name  -- F6, F7, etc.
  end
  if name:match("^%d$") then return name end  -- 1-9
  if name == "0" then return "0" end
  if name:match("^[A-Z]$") and #name == 1 then
    return name:lower()  -- Q -> q
  end
  if name == "SPACE" then return "SPACE" end
  if name == "ENTER" or name == "RETURN" then return "ENTER" end
  if name == "TAB" then return "TAB" end
  if name == "UP" or name == "ARROWUP" then return "UP" end
  if name == "DOWN" or name == "ARROWDOWN" then return "DOWN" end
  if name == "LEFT" or name == "ARROWLEFT" then return "LEFT" end
  if name == "RIGHT" or name == "ARROWRIGHT" then return "RIGHT" end
  return name
end

local norns_keyboard_event = nil

local function setup_keyboard()
  -- Hook keyboard.event (raw HID events) so we receive keys even when menu is open
  if not norns_keyboard_event then
    norns_keyboard_event = keyboard.event
  end
  keyboard.event = function(typ, code, val)
    -- Learn mode: capture keydown before anything else
    if state.learning_key and (val == 1 or val == 2) then
      local key_name = hid_code_to_key_name(code)
      if key_name then
        local slot = state.banks[state.current_bank][state.current_slot]
        if slot then
          slot.key = key_name
          state.learning_key = false
          print("setlist: learned key " .. key_name)
          mod.menu.redraw()
        end
        return  -- consume event
      end
    end
    -- Chain to default handler (which calls keyboard.code).
    -- If no original, invoke keyboard.code ourselves so scripts still receive events.
    if norns_keyboard_event then
      norns_keyboard_event(typ, code, val)
    elseif val == 1 or val == 2 then
      local name = hid_code_to_key_name(code)
      if name and keyboard.code then
        keyboard.code(name, val)
      end
    end
  end

  -- Also wrap keyboard.code for normal trigger firing
  local existing = keyboard.code
  keyboard.code = function(code, value)
    if value == 1 then
      for s = 1, NUM_SLOTS do
        local slot = state.banks[state.current_bank][s]
        if slot.trigger_type == "keyboard" and slot.key == tostring(code) then
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
local PAGE_BANK         = 1
local PAGE_SLOT         = 2
local PAGE_EDIT         = 3
local PAGE_SETTINGS     = 4
local PAGE_SCRIPT_BROWSE = 5

local menu_page = PAGE_BANK
local menu_pos = 1  -- position within current page
local edit_field = 1
local script_browse_pos = 1  -- position in script list when browsing

-- Build edit fields dynamically based on slot state (conditional visibility)
local function get_edit_fields(slot)
  local fields = {"script", "pset", "trigger_type"}
  if slot.trigger_type == "keyboard" then
    table.insert(fields, "key")
  elseif slot.trigger_type == "midi_pc" then
    table.insert(fields, "midi_pc")
  end
  table.insert(fields, "clock_mode")
  if slot.clock_mode == "internal" then
    table.insert(fields, "bpm")
  end
  table.insert(fields, "fire")  -- K3 on this field fires the slot
  return fields
end

local m = {}

m.key = function(n, z)
  if z ~= 1 then return end

  if n == 2 then
    -- K2: back
    if menu_page == PAGE_BANK then
      mod.menu.exit()
    elseif menu_page == PAGE_SLOT then
      menu_page = PAGE_BANK
      menu_pos = state.current_bank
    elseif menu_page == PAGE_EDIT then
      menu_page = PAGE_SLOT
      menu_pos = state.current_slot
      save_data()
    elseif menu_page == PAGE_SCRIPT_BROWSE then
      menu_page = PAGE_EDIT
    elseif menu_page == PAGE_SETTINGS then
      menu_page = PAGE_BANK
      save_data()
    end
    mod.menu.redraw()

  elseif n == 3 then
    -- K3: select / action
    if menu_page == PAGE_BANK then
      state.current_bank = menu_pos
      menu_page = PAGE_SLOT
      menu_pos = state.current_slot
    elseif menu_page == PAGE_SLOT then
      state.current_slot = menu_pos
      menu_page = PAGE_EDIT
      edit_field = 1
    elseif menu_page == PAGE_EDIT then
      local slot = state.banks[state.current_bank][state.current_slot]
      local fields = get_edit_fields(slot)
      local field = fields[edit_field]
      if field == "script" then
        -- K3 opens script browse
        local list = get_script_list()
        script_browse_pos = util.clamp(index_of(list, slot.script), 1, #list)
        menu_page = PAGE_SCRIPT_BROWSE
      elseif field == "key" then
        state.learning_key = true
        print("setlist: press a key to learn...")
      elseif field == "midi_pc" then
        state.learning_midi_pc = true
        print("setlist: send MIDI PC to learn...")
      elseif field == "fire" then
        fire_slot(state.current_bank, state.current_slot)
      end
    elseif menu_page == PAGE_SCRIPT_BROWSE then
      -- K3 select script
      local list = get_script_list()
      local slot = state.banks[state.current_bank][state.current_slot]
      slot.script = list[script_browse_pos]
      menu_page = PAGE_EDIT
    elseif menu_page == PAGE_SETTINGS then
      -- nothing on K3 for settings
    end
    mod.menu.redraw()
  end
end

m.enc = function(n, d)
  local slot = state.banks[state.current_bank][state.current_slot]

  if n == 2 then
    -- E2: scroll vertically through list on all pages
    if menu_page == PAGE_BANK then
      menu_pos = util.clamp(menu_pos + d, 1, NUM_BANKS)
    elseif menu_page == PAGE_SLOT then
      menu_pos = util.clamp(menu_pos + d, 1, NUM_SLOTS)
    elseif menu_page == PAGE_SCRIPT_BROWSE then
      local list = get_script_list()
      script_browse_pos = util.clamp(script_browse_pos + d, 1, #list)
    elseif menu_page == PAGE_EDIT then
      local fields = get_edit_fields(slot)
      edit_field = util.clamp(edit_field + d, 1, #fields)
    end

  elseif n == 3 then
    -- E3: change value of selected field (edit page, settings)
    if menu_page == PAGE_EDIT then
      local fields = get_edit_fields(slot)
      local field = fields[edit_field]

      if field == "pset" then
        slot.pset = util.clamp(slot.pset + d, 1, 99)
      elseif field == "bpm" then
        slot.bpm = util.clamp(slot.bpm + d, 1, 300)
      elseif field == "midi_pc" then
        slot.midi_pc = util.clamp(slot.midi_pc + d, 0, 127)
      elseif field == "trigger_type" then
        local idx = index_of(TRIGGER_TYPE_OPTIONS, slot.trigger_type)
        slot.trigger_type = TRIGGER_TYPE_OPTIONS[util.clamp(idx + d, 1, #TRIGGER_TYPE_OPTIONS)]
        edit_field = util.clamp(edit_field, 1, #get_edit_fields(slot))
      elseif field == "key" then
        local key_opts = KEY_OPTIONS
        if slot.key ~= "" and slot.key ~= "none" and index_of(KEY_OPTIONS, slot.key) == 1 then
          key_opts = {"none", slot.key}
          for _, k in ipairs(KEY_OPTIONS) do
            if k ~= "none" and k ~= slot.key then table.insert(key_opts, k) end
          end
        end
        local idx = index_of(key_opts, slot.key)
        slot.key = key_opts[util.clamp(idx + d, 1, #key_opts)]
      elseif field == "clock_mode" then
        local idx = index_of(CLOCK_OPTIONS, slot.clock_mode)
        slot.clock_mode = CLOCK_OPTIONS[util.clamp(idx + d, 1, #CLOCK_OPTIONS)]
        edit_field = util.clamp(edit_field, 1, #get_edit_fields(slot))
      elseif field == "script" then
        local list = get_script_list()
        local idx = index_of(list, slot.script)
        slot.script = list[util.clamp(idx + d, 1, #list)]
      end
      -- fire field is display-only, no E3 change

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
    screen.text("SETLIST  bank")
    screen.level(15)
    screen.move(2, 24)
    screen.text("> " .. menu_pos)

  elseif menu_page == PAGE_SLOT then
    screen.level(15)
    screen.move(2, 8)
    screen.text("bank " .. state.current_bank .. "  slots")
    local win_start = math.max(1, math.min(menu_pos - 3, NUM_SLOTS - 6))
    for i = 0, 6 do
      local s = win_start + i
      if s > NUM_SLOTS then break end
      local slot = state.banks[state.current_bank][s]
      local y = 16 + (i * 8)
      local label = s .. ": "
      if slot.script ~= "" then
        label = label .. get_script_name(slot.script)
      else
        label = label .. "---"
      end
      if slot.trigger_type == "keyboard" and slot.key ~= "none" then
        label = label .. " [" .. slot.key .. "]"
      elseif slot.trigger_type == "midi_pc" then
        label = label .. " [PC" .. slot.midi_pc .. "]"
      end
      if s == menu_pos then
        screen.level(15)
        screen.move(2, y)
        screen.text("> " .. label)
      else
        screen.level(4)
        screen.move(8, y)
        screen.text(label)
      end
    end

  elseif menu_page == PAGE_SCRIPT_BROWSE then
    screen.level(15)
    screen.move(2, 8)
    screen.text("select script")
    local list = get_script_list()
    local win_start = math.max(1, math.min(script_browse_pos - 3, #list - 6))
    for i = 0, 6 do
      local idx = win_start + i
      if idx > #list then break end
      local y = 16 + (i * 8)
      local label = idx == 1 and "(none)" or get_script_name(list[idx])
      if idx == script_browse_pos then
        screen.level(15)
        screen.move(2, y)
        screen.text("> " .. label)
      else
        screen.level(4)
        screen.move(8, y)
        screen.text(label)
      end
    end

  elseif menu_page == PAGE_EDIT then
    local slot = state.banks[state.current_bank][state.current_slot]
    local fields = get_edit_fields(slot)
    screen.level(15)
    screen.move(2, 8)
    screen.text("b" .. state.current_bank .. " s" .. state.current_slot .. "  edit")

    local field_names = {
      script = "script", pset = "pset", trigger_type = "trigger",
      key = "key", midi_pc = "midi pc", clock_mode = "clock", bpm = "bpm", fire = "fire"
    }
    local function field_label(field)
      if field == "script" then
        return slot.script ~= "" and get_script_name(slot.script) or "---"
      elseif field == "pset" then return tostring(slot.pset)
      elseif field == "trigger_type" then return slot.trigger_type
      elseif field == "key" then return slot.key
      elseif field == "midi_pc" then return tostring(slot.midi_pc)
      elseif field == "clock_mode" then return slot.clock_mode
      elseif field == "bpm" then return tostring(slot.bpm)
      elseif field == "fire" then return "[K3]"
      end
      return ""
    end

    for i, field in ipairs(fields) do
      local y = 8 + (i * 8)
      local label = field_label(field)
      if field == "key" and state.learning_key then
        label = "< learn... >"
      elseif field == "midi_pc" and state.learning_midi_pc then
        label = "< learn... >"
      end
      local name = field_names[field] or field
      if i == edit_field then
        screen.level(15)
        screen.move(2, y)
        screen.text("> " .. name .. ": " .. label)
      else
        screen.level(4)
        screen.move(8, y)
        screen.text(name .. ": " .. label)
      end
    end

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
