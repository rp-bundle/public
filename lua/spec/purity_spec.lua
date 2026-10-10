-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The core is pure Lua: no game APIs, no engine branches, no clock or file
-- access behind the platform's back, and no `require`. These read the source
-- rather than run it, so a stray call fails here even on a path no other test
-- takes. `undefined-global` in lua-language-server --check is the stronger
-- form of the same rule; this is the one that runs with busted.

local lfs = require("lfs")
local support = require("spec.support")

---Every Lua file under lua/core/, relative to the repository root.
---@return string[] files The files.
local function core_files()
  local out = {}
  local function walk(relative)
    for name in lfs.dir(support.path(relative)) do
      if name ~= "." and name ~= ".." then
        local path = relative .. "/" .. name
        local mode = lfs.attributes(support.path(path), "mode")
        if mode == "directory" then
          walk(path)
        elseif name:match("%.lua$") then
          out[#out + 1] = path
        end
      end
    end
  end
  walk("lua/core")
  table.sort(out)
  return out
end

-- Game globals from FiveM and Gmod, ox_lib's `lib` (J10: only the FiveM
-- adapter's `ox.lua` calls it), Derma, and the standard-library escape
-- hatches that would bypass the platform (its clock, its storage, its log).
local FORBIDDEN = {
  { "AddEventHandler", "AddEventHandler" },
  { "RegisterNetEvent", "RegisterNetEvent" },
  { "TriggerEvent", "Trigger*Event" },
  { "TriggerClientEvent", "TriggerClientEvent" },
  { "TriggerServerEvent", "TriggerServerEvent" },
  { "PerformHttpRequest", "PerformHttpRequest" },
  { "%f[%w_]HTTP%s*%(", "HTTP(" },
  { "%f[%w_]hook%.[%a_]", "hook." },
  { "%f[%w_]net%.[%a_]", "net." },
  { "%f[%w_]util%.[%a_]", "util." },
  { "%f[%w_]timer%.[%a_]", "timer." },
  { "%f[%w_]file%.[%a_]", "file." },
  { "%f[%w_]concommand%.[%a_]", "concommand." },
  -- Code only: the docs name ox_lib's calls in backticks.
  { "[^`/%w_.]lib%.[%a_]", "lib." },
  { "%f[%w_]vgui%.[%a_]", "vgui." },
  { "Citizen", "Citizen" },
  { "SetTimeout", "SetTimeout" },
  { "GetPlayerIdentifiers", "GetPlayerIdentifiers" },
  { "GetPlayerName", "GetPlayerName" },
  { "DropPlayer", "DropPlayer" },
  { "ResourceKvp", "*ResourceKvp" },
  { "IsDuplicityVersion", "IsDuplicityVersion" },
  { "%f[%w_]exports%s*[%.%[]", "exports" },
  { "%f[%w_]os%.[%a_]", "os." },
  { "%f[%w_]io%.[%a_]", "io." },
  { "%f[%w_]require%s*[%(\"']", "require" },
  { "%f[%w_]print%s*%(", "print(" },
  { "%f[%w_]coroutine%.[%a_]", "coroutine." },
  { "%f[%w_]setfenv", "setfenv" },
  { "%f[%w_]loadstring", "loadstring" },
}

-- A comparison against `engine` in either order, or against an engine name.
local ENGINE_BRANCHES = {
  "engine%s*[=~]=",
  "[=~]=%s*[%w_.]*engine%f[^%w_]",
  "[=~]=%s*[\"']fivem[\"']",
  "[=~]=%s*[\"']gmod[\"']",
  "[=~]=%s*[\"']mock[\"']",
}

-- Syntax outside the 5.1/5.4 common subset. The language server, set to
-- LuaJIT, refuses these too; this keeps the rule in the busted run.
local NOT_COMMON = {
  { "//", "integer division" },
  { "<const>", "<const>" },
  { "<close>", "<close>" },
  { "%f[%w_]goto%f[^%w_]", "goto" },
  { "table%.unpack", "table.unpack" },
  { "%f[%w_.]unpack%s*%(", "unpack" },
  { "%f[%w_]utf8%.", "utf8." },
  { "math%.type", "math.type" },
  { "[^%-<>~=]>>", ">>" },
  { "<<", "<<" },
}

describe("lua/core", function()
  local files = core_files()

  it("has files to check", function()
    assert.is_true(#files >= 9)
  end)

  for _, relative in ipairs(files) do
    describe(relative, function()
      local source = support.read(relative)

      it("references no game global and no escape hatch", function()
        for _, rule in ipairs(FORBIDDEN) do
          local at = source:find(rule[1])
          assert.is_nil(at, relative .. " mentions " .. rule[2])
        end
      end)

      it("never branches on engine", function()
        for _, pattern in ipairs(ENGINE_BRANCHES) do
          assert.is_nil(source:find(pattern), relative .. " compares against engine (" .. pattern .. ")")
        end
      end)

      -- lua-language-server's doc diagnostics check a signature once a
      -- function has a doc comment, and check globals and exported locals,
      -- but say nothing about a module-table function with no comment at
      -- all, which is most of the core. This closes that gap.
      it("documents every named function", function()
        local previous = ""
        local number = 0
        for line in (source .. "\n"):gmatch("([^\n]*)\n") do
          number = number + 1
          local named = line:find("^%s*function [%w_.:]+%s*%(")
            or line:find("^%s*local function [%w_]+%s*%(")
            or line:find("^[%w_]+%s*=%s*function%s*%(")
            or line:find("^%s*[%w_]+%.[%w_.]+%s*=%s*function%s*%(")
          if named then
            assert.truthy(previous:find("^%s*%-%-%-"), relative .. ":" .. number .. " has no doc comment: " .. line)
          end
          if line:find("%S") then
            previous = line
          end
        end
      end)

      it("stays in the Lua 5.1/5.4 common subset", function()
        -- Comments and strings may say `//` (a url), so only code is checked.
        local code = source:gsub("%-%-[^\n]*", ""):gsub('"[^"\n]*"', '""')
        for _, rule in ipairs(NOT_COMMON) do
          assert.is_nil(code:find(rule[1]), relative .. " uses " .. rule[2])
        end
      end)
    end)
  end

  it("declares every non-meta file in init.lua's load order", function()
    support.load_core()
    local declared = { ["lua/core/init.lua"] = true }
    for _, side in ipairs({ "server", "client" }) do
      for _, file in ipairs(rpf.files[side]) do
        declared["lua/core/" .. file] = true
      end
    end
    for _, relative in ipairs(files) do
      if not relative:find("^lua/core/meta/") then
        assert.is_true(declared[relative] == true, relative .. " is not in rpf.files")
      end
    end
  end)
end)
