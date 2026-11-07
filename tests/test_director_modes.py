"""Logic regressions without GMod. Run: python -m unittest discover -s tests -v

Requires lupa (pip install lupa). Engine entities, timers and convars are mocked.
"""
from pathlib import Path
import unittest

from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / "lua/homigrad/bots"

SETUP = r'''
hg = { bots = { List = {} } }
FCVAR_ARCHIVE = 1
local clock = 0
function CurTime() return clock end
function SetClock(t) clock = t end
function IsValid(x) return type(x) == "table" and x.valid == true end
math.Clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
math.Rand = function(a, b) return (a+b)/2 end
local CV, changes = {}, {}
cvars = { AddChangeCallback = function(name, fn) changes[name] = fn end }
function CreateConVar(name, default)
    if CV[name] then return CV[name] end
    local cv = { value = tonumber(default) or default }
    function cv:GetInt() return math.floor(tonumber(self.value) or 0) end
    function cv:GetFloat() return tonumber(self.value) or 0 end
    function cv:GetString() return tostring(self.value) end
    function cv:GetBool() return self:GetFloat() ~= 0 end
    function cv:SetInt(value)
        local old = self.value
        self.value = value
        if changes[name] then changes[name](name, tostring(old), tostring(value)) end
    end
    CV[name] = cv
    return cv
end
function GetConVar(name) return CV[name] end
hook = { events = {} }
function hook.Add(event, name, fn)
    hook.events[event] = hook.events[event] or {}
    hook.events[event][name] = fn
end
function hook.Run(event, ...)
    for _, fn in pairs(hook.events[event] or {}) do
        local result = fn(...)
        if result ~= nil then return result end
    end
end
timer = { named = {}, pending = {} }
function timer.Create(name, delay, count, fn) timer.named[name] = fn end
function timer.Simple(delay, fn) table.insert(timer.pending, fn) end
function RunTimers()
    local pending = timer.pending
    timer.pending = {}
    for _, fn in ipairs(pending) do fn() end
end
concommand = { Add = function() end }
ents = { GetAll = function() return {} end, FindByClass = function() return {} end }
local humans = {}
player = { GetHumans = function() return humans end }
function Vector(x, y, z)
    local v = {x=x or 0, y=y or 0, z=z or 0}
    function v:DistToSqr(b) return (self.x-b.x)^2+(self.y-b.y)^2+(self.z-b.z)^2 end
    return v
end
function MakePlayer(bot, x)
    local p = { valid = true, living = true, IsHomigradBot = bot or nil, pos = Vector(x,0,0), hgBotFaction = "raider" }
    function p:IsPlayer() return true end
    function p:Alive() return self.living end
    function p:GetPos() return self.pos end
    function p:SetNWInt() end
    function p:SetNWString() end
    if bot then
        p.Bot = { Enabled = true, State = "idle", Memory = {} }
        hg.bots.List[p] = true
    else table.insert(humans, p) end
    return p
end
function Upvalue(fn, key, replacement)
    for i=1,100 do
        local name, value = debug.getupvalue(fn,i)
        if not name then break end
        if name == key then
            if replacement then debug.setupvalue(fn,i,replacement) end
            return value
        end
    end
    error("Missing upvalue " .. key)
end
'''


class DirectorModes(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime()
        self.lua.execute(SETUP)
        for name in ("sv_bot_director.lua", "sv_bot_director_modes.lua", "sv_bot_factions.lua", "sv_bot_squad.lua", "sh_bot_settings.lua"):
            self.lua.execute((ROOT / name).read_text(encoding="utf-8"))
        self.lua.execute('''
            human = MakePlayer(false, 0)
            a, b, c = MakePlayer(true, 100), MakePlayer(true, 200), MakePlayer(true, 300)
            hg.bots.Director.bots[a], hg.bots.Director.bots[b], hg.bots.Director.bots[c] = true, true, true
            function SetMode(n) GetConVar("hg_bot_director_mode"):SetInt(n); RunTimers() end
            function DamageResult(attacker, victim)
                local damage = { GetAttacker = function() return attacker end }
                return hook.events.EntityTakeDamage.HG_Bots_NoFriendlyFire(victim, damage)
            end
        ''')

    def test_survival_keeps_original_factions(self):
        self.lua.execute('''
            assert(hg.bots.DirectorMode() == 0)
            assert(hg.bots.DirectorFriendly(a, human) == nil)
            assert(hg.bots.SameFaction(a,b))
            assert(hg.bots.FactionHostile(b,a) == false)
        ''')

    def test_ffa_enemies_can_damage_each_other(self):
        self.lua.execute('''
            SetMode(2)
            assert(hg.bots.FactionHostile(b,a) == true)
            assert(hg.bots.FactionHostile(human,a) == true)
            assert(hg.bots.SameFaction(a,b) == false)
            assert(hg.bots.IsFriendly(a,b) == false)
            assert(DamageResult(a,b) == nil)
        ''')

    def test_ffa_works_with_factions_disabled(self):
        self.lua.execute('''
            SetMode(2)
            GetConVar("hg_bot_factions"):SetInt(0)
            assert(hg.bots.SameFaction(a,b) == false)
            assert(hg.bots.FactionHostile(b,a) == true)
            local targets = {}
            hg.bots.ExtraTargets(targets)
            assert(#targets == 3)
        ''')

    def test_ffa_does_not_coordinate_against_shared_target(self):
        self.lua.execute('''
            SetMode(2)
            for bot in pairs(hg.bots.List) do bot.Bot.Memory.Target = human end
            timer.named.HG_Bots_SquadRoles()
            for bot in pairs(hg.bots.List) do assert(bot.Bot.SquadRole == nil) end
        ''')

    def test_tdm_balances_teams_including_humans(self):
        self.lua.execute('''
            SetMode(1)
            local counts = {1,0}
            for bot in pairs(hg.bots.Director.bots) do
                local side = bot.hgBotDirectorTeam
                assert(side == 1 or side == 2)
                counts[side] = counts[side] + 1
                assert(hg.bots.FactionHostile(human,bot) == (side == 2))
            end
            assert(counts[1] == 2 and counts[2] == 2)
        ''')

    def test_tdm_allies_and_enemies_use_correct_damage_rules(self):
        self.lua.execute('''
            SetMode(1)
            a.hgBotDirectorTeam, b.hgBotDirectorTeam, c.hgBotDirectorTeam = 1,1,2
            assert(hg.bots.IsFriendly(a,b))
            assert(not hg.bots.IsFriendly(a,c))
            assert(hg.bots.FactionHostile(b,a) == false)
            assert(hg.bots.FactionHostile(c,a) == true)
            assert(DamageResult(a,b) == true)
            assert(DamageResult(a,c) == nil)
        ''')

    def test_mode_change_clears_stale_targets_and_squad_roles(self):
        self.lua.execute('''
            SetMode(2)
            a.Bot.Memory.Target, a.Bot.SquadRole = b, "support"
            SetMode(1)
            assert(a.Bot.Memory.Target == nil and a.Bot.SquadRole == nil)
            SetMode(0)
            assert(a.hgBotDirectorTeam == nil)
        ''')

    def test_tdm_squad_roles_do_not_mix_opposing_teams(self):
        self.lua.execute('''
            SetMode(1)
            a.hgBotDirectorTeam, b.hgBotDirectorTeam, c.hgBotDirectorTeam = 1,1,2
            local npc = { valid = true, GetPos = function() return Vector(1000,0,0) end }
            for bot in pairs(hg.bots.List) do bot.Bot.Memory.Target = npc end
            timer.named.HG_Bots_SquadRoles()
            assert(a.Bot.SquadRole ~= nil and b.Bot.SquadRole ~= nil)
            assert(c.Bot.SquadRole == nil)
        ''')

    def test_non_director_bots_keep_original_rules(self):
        self.lua.execute('''
            SetMode(2)
            local x, y = MakePlayer(true,400), MakePlayer(true,500)
            assert(hg.bots.DirectorFriendly(x,y) == nil)
            assert(hg.bots.SameFaction(x,y))
        ''')

    def test_deathmatch_does_not_enter_quiet_phase(self):
        self.lua.execute('''
            local tick = Upvalue(timer.named.HG_Bots_Director,"Tick")
            Upvalue(tick,"Pressure",function() return 0,1,0 end)
            Upvalue(tick,"SpawnOne",function() return true end)
            GetConVar("hg_bot_director"):SetInt(1)
            for _, mode in ipairs({1,2}) do
                SetMode(mode)
                SetClock(1000)
                tick()
                assert(hg.bots.Director.phase == "peak")
                SetClock(2000)
                tick()
                assert(hg.bots.Director.phase == "peak")
            end
        ''')

    def test_menu_mode_is_a_superadmin_choice(self):
        self.lua.execute('''
            local setting = hg.bots.SettingIndex.hg_bot_director_mode
            assert(setting.level == "superadmin")
            assert(#setting.choices == 3 and not setting.bool)
        ''')


if __name__ == "__main__":
    unittest.main()
