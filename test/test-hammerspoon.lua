-- test-hammerspoon.lua — load the Hammerspoon module against a stubbed API.
--
-- Hammerspoon only reports a Lua error when the offending line actually runs,
-- so a mistake like calling a `local` helper declared further down the file
-- stays invisible until a user presses the hotkey. This harness stubs the hs
-- API, loads the module, and calls the entry points, which turns that class of
-- bug into a test failure.
--
--   lua test/test-hammerspoon.lua

local pass, fail = 0, 0
local function ok(n) print("  ok   " .. n); pass = pass + 1 end
local function bad(n, d) print("  FAIL " .. n); print("       " .. tostring(d)); fail = fail + 1 end
local function check(n, cond, detail) if cond then ok(n) else bad(n, detail) end end

local executed, tasksMade = {}, {}

hs = {
    fs = { attributes = function(p)
        -- Pretend the CLI exists wherever it is looked for, and that the
        -- transcribing marker does not.
        if p:match("keybind%-whisper$") then return { mode = "file" } end
        return nil
    end },
    execute = function(cmd)
        executed[#executed + 1] = cmd
        -- Match on the unquoted form. Arguments are shell-quoted individually,
        -- so the command reads 'history' 'list' rather than "history list";
        -- comparing on the flattened text keeps this stub from breaking every
        -- time the quoting changes.
        local flat = cmd:gsub("'", "")
        if flat:match("history list") then
            return "   1  2026-10-02 11:00:00  the newest one\n"
                .. "   2  2026-10-02 10:59:00  the older one\n", true
        elseif flat:match("history show") then
            return "the newest one\n", true
        elseif flat:match("status") then
            return "keybind-whisper 1.0.0\n  state     /tmp/wl-test\n  recording no\n", true
        end
        return "", true
    end,
    alert = { show = function() return 1 end, closeSpecific = function() end },
    timer = {
        doEvery = function() return { stop = function() end } end,
        doAfter = function() return { stop = function() end } end,
    },
    pasteboard = {
        getContents = function() return "previous" end,
        setContents = function() end,
        changeCount = function() return 1 end,
    },
    eventtap = { keyStroke = function() end },
    menubar = { new = function()
        return { setTitle = function() end, setTooltip = function() end,
                 setMenu = function(_, fn) hs._menuBuilder = fn end }
    end },
    hotkey = { bind = function() return { delete = function() end } end },
    task = { new = function(bin, cb, args)
        tasksMade[#tasksMade + 1] = { bin = bin, args = args, cb = cb }
        return { start = function() end, terminate = function() end }
    end },
}

-- Resolve the module relative to this script, so the suite works from any
-- checkout location rather than assuming where the repository was cloned.
local here = arg[0]:match("^(.*)/[^/]+$") or "."
local M = dofile(here .. "/../hammerspoon/keybind-whisper.lua")

print("\nhammerspoon module")

-- History reading goes through the CLI, so a helper that is out of scope at
-- its call site surfaces here rather than at the user's hotkey.
local recent = M.recent(5)
check("recent() parses the CLI listing", #recent == 2, "#recent = " .. #recent)
check("recent() keeps newest first",
      recent[1] and recent[1].text == "the newest one", recent[1] and recent[1].text)
check("recent() captures the index",
      recent[1] and recent[1].index == 1, recent[1] and recent[1].index)
check("historyText() returns trimmed text",
      M.historyText(1) == "the newest one", M.historyText(1))

-- setup() wires the menu and resumes state; it must not raise.
local okSetup, err = pcall(function() M.setup({ menubar = true }) end)
check("setup() completes", okSetup, err)
check("menu builder is installed", type(hs._menuBuilder) == "function", type(hs._menuBuilder))

if type(hs._menuBuilder) == "function" then
    local okMenu, items = pcall(hs._menuBuilder)
    check("menu builds without error", okMenu, items)
    if okMenu then
        local titles = {}
        for _, it in ipairs(items) do titles[#titles + 1] = it.title end
        local joined = table.concat(titles, " | ")
        check("menu lists recent transcriptions",
              joined:match("the newest one") ~= nil, joined)
        check("menu offers a paste action",
              joined:match("Paste most recent") ~= nil, joined)
    end
end

-- Push-to-talk is the default: toggling must invoke `start`, not `dictate`.
tasksMade = {}
M.setup({ menubar = false, autoStop = nil })
M.toggle()
check("default toggle runs start",
      tasksMade[1] and tasksMade[1].args[1] == "start",
      tasksMade[1] and tasksMade[1].args[1])

-- With autoStop set it must switch to the blocking dictate flow and pass the
-- silence window through, since the two flows transcribe in different places.
tasksMade = {}
M.setup({ menubar = false, autoStop = 2 })
M.toggle()
check("autoStop toggle runs dictate",
      tasksMade[1] and tasksMade[1].args[1] == "dictate",
      tasksMade[1] and tasksMade[1].args[1])
check("autoStop passes the silence window",
      tasksMade[1] and tasksMade[1].args[2] == "--silence"
                   and tasksMade[1].args[3] == "2",
      tasksMade[1] and table.concat(tasksMade[1].args, " "))

-- A second press in autoStop mode must finish the in-flight dictate rather
-- than calling stop, which would race it for the same audio.
tasksMade = {}
M.toggle()
check("second autoStop press runs finish",
      tasksMade[1] and tasksMade[1].args[1] == "finish",
      tasksMade[1] and tasksMade[1].args[1])

-- Arguments reach the CLI through hs.execute, which runs a shell. Lua's %q
-- quotes for Lua source, not for a shell: it leaves $(...) and backticks
-- untouched, so a path containing either was executed. Assert the dangerous
-- forms arrive single-quoted instead.
executed = {}
M.setup({ menubar = false, bin = "/tmp/$(whoami)/keybind-whisper" })
M.recent(5)
local cmd = executed[#executed] or ""
check("a path with $( ) is single-quoted, not expanded",
      cmd:find("'/tmp/$(whoami)/keybind-whisper'", 1, true) ~= nil, cmd)

executed = {}
M.setup({ menubar = false, bin = "/tmp/it's here/keybind-whisper" })
M.recent(5)
cmd = executed[#executed] or ""
-- The POSIX idiom: close the quote, escape the quote, reopen it.
check("an embedded single quote is escaped",
      cmd:find([['/tmp/it'\''s here/keybind-whisper']], 1, true) ~= nil, cmd)

-- Indices are interpolated into the command, so they must be numbers.
executed = {}
M.setup({ menubar = false, bin = "/tmp/keybind-whisper" })
M.historyText("3; rm -rf ~")
cmd = executed[#executed] or ""
check("a non-numeric index is coerced, never passed through",
      cmd:find("rm -rf", 1, true) == nil and cmd:find("'1'", 1, true) ~= nil, cmd)

print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
