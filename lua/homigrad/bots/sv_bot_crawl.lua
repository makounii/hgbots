--[[
	Tarkov AI - Crawling

	Bots drag themselves along the floor the same way a player does it in
	Z-City, using the real ragdoll controls - nothing here moves a ragdoll
	by hand.

	How it works (lua/homigrad/fake/sv_control.lua):

	- IN_USE holds the "control" state: the torso is stabilized and the
	  arms are driven, instead of the body being a loose sack.
	- IN_SPEED (shift) reaches out with the LEFT hand: a short trace out of
	  the palm, and anything it touches gets welded to the hand
	  (ragdoll.ConsLH). IN_WALK (alt) does the same with the RIGHT hand
	  (ragdoll.ConsRH). Releasing the key drops the weld, and the same hand
	  can't grab again for 0.5 s (ragdoll.cooldownLH / cooldownRH).
	- With a hand welded, holding IN_FORWARD applies a force pulling the
	  TORSO toward where the head is facing (and pushing back on the hand):
	  that pull is the actual movement. Lying flat with palms on the floor,
	  alternating the two hands is a crawl.
	- The right hand refuses to grab while an hg firearm or a melee weapon
	  is held (`!(ishgweapon(wep) or wep.ismelee2)`), so a bot crawling
	  with a rifle in its hands crawls left-handed, which is slower. That's
	  the mechanic, not a limitation of this file.
	- It costs stamina per hand per tick and hurts a broken/dislocated arm,
	  so crawling is for when walking isn't an option, not a default.

	When bots crawl:
	- legs broken or dislocated (standing up just falls over again);
	- pinned under fire with cover to reach - crawling keeps the small
	  prone silhouette all the way there, instead of standing up into the
	  bullets (getting up is a slow, helpless animation);
	- deliberately prone (sv_bot_combat.lua's TryProne) and needing a
	  better spot;
	- down next to a live grenade with no time to stand.

	Crawling occupies both hands, so a crawling bot isn't shooting. It
	stops as soon as it arrives, loses the reason, or runs out of time -
	and the "downed" state then decides about getting up as usual.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}

local hg_bot_crawl        = CreateConVar("hg_bot_crawl",        "1",    {FCVAR_ARCHIVE}, "Bots can crawl on their belly in a Z-City ragdoll (hand-over-hand grabs)", 0, 1)
local hg_bot_crawl_cycle  = CreateConVar("hg_bot_crawl_cycle",  "0.65", {FCVAR_ARCHIVE}, "Seconds each hand holds its grab before the other one takes over (the mechanic needs 0.5 s between grabs of the same hand)", 0.3, 3)
local hg_bot_crawl_time   = CreateConVar("hg_bot_crawl_time",   "16",   {FCVAR_ARCHIVE}, "Max seconds of one crawl before the bot gives up on that destination", 2, 60)
local hg_bot_crawl_range  = CreateConVar("hg_bot_crawl_range",  "600",  {FCVAR_ARCHIVE}, "How far away a crawl destination (cover) may be", 100, 2000)
local hg_bot_crawl_arrive = CreateConVar("hg_bot_crawl_arrive", "60",   {FCVAR_ARCHIVE}, "How close to the destination counts as arrived", 16, 200)
local hg_bot_crawl_reach  = CreateConVar("hg_bot_crawl_reach",  "0.35", {FCVAR_ARCHIVE}, "Seconds the arm reaches out before the hand closes on the floor", 0.1, 2)
local hg_bot_crawl_freehands = CreateConVar("hg_bot_crawl_freehands", "1", {FCVAR_ARCHIVE}, "Put a rifle / melee weapon away while crawling. Z-City refuses a right-hand grab with one of those in the hands, so keeping it means crawling one-handed", 0, 1)

--\\ Driving a crawl
	function hg.bots.StopCrawl(data)
		data.CrawlDest = nil
		data.CrawlUntil = nil
		data.CrawlGrab = nil
		data.CrawlSwitch = nil
		data.CrawlStuckAt = nil
		data.CrawlLastPos = nil
		data.CrawlHand = nil
		data.CrawlPhase = nil
		data.CrawlSwapAt = nil
		data.CrawlPull = nil
		data.Attacking = false
		data.AttackingSecondary = false

		-- Took the weapon out of its hands for the crawl: give it back.
		if data.CrawlTookHands then
			data.CrawlTookHands = nil
			data.NextWeaponSwitch = 0

			local bot = data.Owner

			if IsValid(bot) and hg.bots.EquipBestWeapon then hg.bots.EquipBestWeapon(bot) end
		end
	end

	--- Puts the bot on its belly (if it isn't already) and starts crawling
	-- toward dest.
	function hg.bots.StartCrawl(bot, data, dest, timeout)
		if not hg_bot_crawl:GetBool() then return false end
		if not IsValid(bot) or not bot:Alive() or not dest then return false end

		local org = bot.organism

		if not org or not org.canmove or org.otrub then return false end

		-- Both arms gone: there is nothing to crawl with.
		if org.larmamputated and org.rarmamputated then return false end

		if not IsValid(bot.FakeRagdoll) then
			if not hg.Fake then return false end

			hg.Fake(bot)

			if not IsValid(bot.FakeRagdoll) then return false end
		end

		data.Owner = bot -- so StopCrawl can hand the weapon back
		data.CrawlDest = dest
		data.CrawlUntil = CurTime() + (timeout or hg_bot_crawl_time:GetFloat())
		data.CrawlGrab = nil
		data.CrawlHand = nil
		data.CrawlPhase = "reach"
		data.CrawlSwitch = CurTime() + hg_bot_crawl_reach:GetFloat()
		data.CrawlLastPos = bot:GetPos()
		data.CrawlStuckAt = CurTime()

		return true
	end

	--- Which way the body is pointing while it lies there: the line from
	-- the pelvis to the head, flattened. Crawling only works forwards, so
	-- the bot has to be lying roughly along its direction of travel before
	-- pulling is worth anything.
	local function BodyHeading(rag)
		local head = rag:LookupBone("ValveBiped.Bip01_Head1")
		local pelvis = rag:LookupBone("ValveBiped.Bip01_Pelvis")

		if not head or not pelvis then return nil end

		local hp = rag:GetPhysicsObjectNum(rag:TranslateBoneToPhysBone(head))
		local pp = rag:GetPhysicsObjectNum(rag:TranslateBoneToPhysBone(pelvis))

		if not IsValid(hp) or not IsValid(pp) then return nil end

		local dir = hp:GetPos() - pp:GetPos()

		dir.z = 0

		if dir:LengthSqr() < 1 then return nil end

		dir:Normalize()

		return dir
	end

	--- Which input extends an arm toward where the bot is looking, for the
	-- weapon currently held (fake/sv_control.lua):
	--   left  arm: IN_ATTACK with anything that isn't an hg firearm, or
	--              E / RMB with an hg firearm or an ismelee2 weapon;
	--   right arm: IN_ATTACK2, or E with an hg firearm / ismelee2 weapon.
	-- An arm is only driven while that hand is NOT already gripping, which
	-- is exactly the reach part of a crawl stroke.
	-- @return "attack" | "attack2" | "use"
	local function ReachKey(wep, hand)
		local hgWep = IsValid(wep) and (wep.ishgweapon or wep.ismelee2)

		if hgWep then return "use" end -- E is held all the time anyway

		return hand == "left" and "attack" or "attack2"
	end

	--- Can this hand grab at all right now? Z-City refuses a right-hand
	-- grab while an hg firearm or an ismelee2 weapon is held.
	local function HandUsable(wep, org, hand)
		if hand == "left" then return not org.larmamputated end

		if IsValid(wep) and (wep.ishgweapon or wep.ismelee2) then return false end

		return not org.rarmamputated
	end

	--- Per-tick driver. Called from the "downed" state's Think.
	--
	-- One stroke is: reach (arm driven out toward the look direction, hand
	-- open) -> grab (weld the palm to whatever it landed on) -> pull (the
	-- forward key drags the torso toward that hand) -> let go. The hands
	-- alternate, which is what makes it a crawl rather than one tug.
	-- @return true while it owns the bot's inputs this tick
	function hg.bots.CrawlTick(bot, data, now)
		local dest = data.CrawlDest

		if not dest then return false end

		local org = bot.organism

		if not IsValid(bot.FakeRagdoll) or not org or not org.canmove or org.otrub then
			hg.bots.StopCrawl(data)
			return false
		end

		if now > (data.CrawlUntil or 0) then
			hg.bots.StopCrawl(data)
			return false
		end

		local pos = bot:GetPos()

		if pos:Distance2D(dest) < hg_bot_crawl_arrive:GetFloat() then
			hg.bots.StopCrawl(data)
			return false
		end

		-- Getting nowhere (wedged against something, nothing to grab):
		-- stop rather than scrape at the floor for the full timeout.
		if not data.CrawlLastPos or pos:DistToSqr(data.CrawlLastPos) > 24 * 24 then
			data.CrawlLastPos = pos
			data.CrawlStuckAt = now
		elseif now - (data.CrawlStuckAt or now) > 4 then
			hg.bots.StopCrawl(data)
			return false
		end

		data.Reloading = false
		data.Running = false
		data.SlowWalk = false
		data.Crouching = false

		-- E: stabilize the torso and drive the arms.
		data.UseKey = true

		-- Free hands: a rifle or a bat in the hands blocks the right-hand
		-- grab outright, so a bot that isn't shooting anything right now
		-- puts it away for the crawl and takes it back afterwards (the
		-- weapon stays in the inventory - this is a holster, not a drop).
		local wep = bot:GetActiveWeapon()

		if hg_bot_crawl_freehands:GetBool() and IsValid(wep) and (wep.ishgweapon or wep.ismelee2)
			and not (wep.ReadyToThrow or wep.InThrowing)
		then
			local hands = bot:HasWeapon("weapon_hg_coolhands") and "weapon_hg_coolhands"
				or (bot:HasWeapon("weapon_hands_sh") and "weapon_hands_sh")

			if hands and now >= (data.CrawlSwapAt or 0) then
				data.CrawlSwapAt = now + 1
				data.CrawlTookHands = true
				data.NextWeaponSwitch = now + 3 -- keep EquipBestWeapon out of it

				bot:SelectWeapon(hands)
			end
		end

		-- Look where we're crawling, at floor level: the arms reach along
		-- the view, so a level-ish, slightly downward line is what puts the
		-- palms on the ground ahead instead of waving them in the air.
		local ahead = Vector(dest.x, dest.y, 0)
		local flat = ahead - Vector(pos.x, pos.y, 0)

		flat.z = 0

		if flat:LengthSqr() > 1 then
			flat:Normalize()
		else
			flat = bot:EyeAngles():Forward()
			flat.z = 0
			flat:Normalize()
		end

		data.LookPos = pos + flat * 90 + Vector(0, 0, 2)
		data.LookLock = true
		data.AimSpeed = 220

		-- The forward key is what turns a gripping hand into movement.
		data.MoveTarget = dest

		local leftOk = HandUsable(wep, org, "left")
		local rightOk = HandUsable(wep, org, "right")

		if not leftOk and not rightOk then
			hg.bots.StopCrawl(data)
			return false
		end

		data.CrawlHand = data.CrawlHand or (leftOk and "left" or "right")
		data.CrawlPhase = data.CrawlPhase or "reach"

		if now >= (data.CrawlSwitch or 0) then
			if data.CrawlPhase == "reach" then
				-- Arm is out: close the hand on whatever is under it.
				data.CrawlPhase = "pull"
				data.CrawlSwitch = now + hg_bot_crawl_cycle:GetFloat()
			else
				-- Let go and swap hands (a hand can't re-grab for 0.5 s).
				data.CrawlPhase = "reach"
				data.CrawlSwitch = now + hg_bot_crawl_reach:GetFloat()

				if data.CrawlHand == "left" and rightOk then
					data.CrawlHand = "right"
				elseif leftOk then
					data.CrawlHand = "left"
				else
					data.CrawlHand = "right"
				end
			end
		end

		local reach = ReachKey(bot:GetActiveWeapon(), data.CrawlHand)

		-- Lying across the direction of travel: one hand pulling toward the
		-- head still torques the body round, so keep stroking, but don't
		-- push forward until it's roughly lined up - that's what turns the
		-- bot into a crawlable position instead of dragging it sideways.
		local heading = BodyHeading(bot.FakeRagdoll)
		local aligned = not heading or heading:Dot(flat) > 0.35

		if data.CrawlPhase == "reach" then
			-- Hand open and arm driven out; no grab key yet.
			data.CrawlGrab = nil
			data.CrawlPull = false
			data.Attacking = (reach == "attack")
			data.AttackingSecondary = (reach == "attack2")
		else
			-- Palm down, grip, and pull the body onto it. The forward key
			-- IS the pull (fake/sv_control.lua) - without it a gripping
			-- hand just holds on.
			data.CrawlGrab = data.CrawlHand
			data.CrawlPull = aligned
			data.Attacking = false
			data.AttackingSecondary = false
		end

		return true
	end
--//

--\\ When to crawl
	local function LegsBroken(org)
		return (org.lleg == 1 or org.rleg == 1 or org.llegdislocation or org.rlegdislocation) and true or false
	end

	--- Somewhere better to be than here, reachable on our belly.
	local function CrawlDestination(bot, data, threatPos)
		local range = hg_bot_crawl_range:GetFloat()
		local cover = hg.bots.FindCoverPoint and hg.bots.FindCoverPoint(bot, threatPos, range)

		if cover then return cover end

		-- No cover: at least get off the spot they're shooting at.
		local pos = bot:GetPos()
		local away = pos - threatPos

		away.z = 0

		if away:LengthSqr() < 1 then return nil end

		away:Normalize()

		local dest = pos + away * 200

		if hg.bots.IsSegmentWalkable and not hg.bots.IsSegmentWalkable(pos, dest, bot) then return nil end

		return dest
	end

	--- Decides whether this bot should be crawling right now.
	function hg.bots.ConsiderCrawl(bot, data)
		if not hg_bot_crawl:GetBool() then return false end
		if data.CrawlDest then return false end
		if data.State == "heal" or data.Healing then return false end

		-- Mid dive away from a grenade: that's its own thing, let it land.
		if data.StayDownUntil and CurTime() < data.StayDownUntil then return false end

		local org = bot.organism

		if not org or not org.canmove or org.otrub then return false end

		local mem = data.Memory
		local now = CurTime()
		local legs = LegsBroken(org)
		local underFire = (mem.UnderFireUntil or 0) > now or (mem.Suppression or 0) > 0.35
		local down = IsValid(bot.FakeRagdoll)

		-- Standing and healthy: walking is strictly better.
		if not down and not legs then return false end

		-- A live grenade next to a downed bot: crawl away from it, there is
		-- no time to stand up.
		local nade = data.EvadeGrenade

		if down and IsValid(nade) then
			local away = CrawlDestination(bot, data, nade:GetPos())

			if away then return hg.bots.StartCrawl(bot, data, away, 4) end
		end

		-- Someone is in reach and we have something to hit them with:
		-- swinging from the floor (sv_bot_downed.lua's ground fight) beats
		-- turning our back and crawling away.
		if down then
			local wep = bot:GetActiveWeapon()
			local handy = IsValid(wep) and (wep.GetFists ~= nil or (hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep)))

			if handy and IsValid(mem.Target) and bot:GetPos():DistToSqr(mem.Target:GetPos()) < 120 * 120 then
				return false
			end

			-- A loaded gun and an enemy in the sights: shoot from where we
			-- lie (sv_bot_downed.lua) instead of crawling off.
			if hg.bots.DownedCanShoot and hg.bots.DownedCanShoot(bot, data) then return false end
		end

		if not (legs or underFire or data.Prone) then return false end

		local threatPos = mem.TargetPos or mem.UnderFireFrom

		if not threatPos then return false end

		-- Prone on purpose, shooting at someone we can see, nothing wrong
		-- with us: stay and shoot, don't wander off on our elbows.
		if data.Prone and not legs and not underFire then return false end

		local dest = CrawlDestination(bot, data, threatPos)

		if not dest then return false end

		return hg.bots.StartCrawl(bot, data, dest)
	end

	timer.Create("HG_Bots_Crawl", 1, 0, function()
		if not hg_bot_crawl:GetBool() then return end

		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot:Alive() and bot.Bot

			if data and data.Enabled then hg.bots.ConsiderCrawl(bot, data) end
		end
	end)

	hook.Add("HG_BotStateChanged", "HG_Bots_ClearCrawl", function(bot, oldState, newState)
		local data = bot.Bot

		if data and newState ~= "downed" then hg.bots.StopCrawl(data) end
	end)
--//
