"""A delayed server sync must not turn clamped slider values into edits."""
from pathlib import Path
import unittest

from lupa.lua54 import LuaRuntime


class MenuRefresh(unittest.TestCase):
    def test_first_sync_preserves_server_value_when_bounds_clamp_the_slider(self):
        source = (Path(__file__).resolve().parents[1] / "lua/homigrad/bots/cl_bot_menu.lua").read_text(encoding="utf-8")
        start = source.index("row.OnValueChanged =", source.index('vgui.Create("DNumSlider"'))
        end = source.index("\n\t\tend\n\n\t\trow:Dock(TOP)", start)
        lua = LuaRuntime()
        lua.execute('''
            name = "hg_bot_director_max"
            bounds = { [name] = {1,64,"",12} }
            values = { [name] = 32 }
            writes = 0
            function SetValue(key,value) writes=writes+1; values[key]=value end
            row = { value = 0 }
            function row:SetMinMax(low,high)
                self.value=math.max(low,math.min(high,self.value))
                self:OnValueChanged(self.value)
            end
            function row:SetDecimals() end
            function row:SetValue(value) self.value=value; self:OnValueChanged(value) end
        ''')
        lua.execute(source[start:end])
        lua.execute('row:Refresh(); assert(writes==0); assert(values[name]==32); assert(row.value==32)')


if __name__ == "__main__":
    unittest.main()
