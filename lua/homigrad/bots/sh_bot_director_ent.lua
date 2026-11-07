--[[
	Tarkov AI - AI director entity

	Spawnable from the Q menu (Entities -> Tarkov AI), or with the menu's
	"Place the AI director" button. While one exists the director runs
	(sv_bot_director.lua); removing it stops the spawning without touching
	the bots already in the world.

	Shared on purpose: an "anim" entity needs its class on the client as
	well, or every client that sees one prints "Error creating
	'ent_hg_director' (Make sure the file is AddCSLuaFile'd...)" and it
	never shows up in the Q menu.
]]

local ENT = {}

ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Tarkov AI Director"
ENT.Author = "hg.bots"
ENT.Category = "Tarkov AI"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.Model = "models/hunter/blocks/cube025x025x025.mdl"

function ENT:Initialize()
	if CLIENT then return end

	self:SetModel(self.Model)
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetUseType(SIMPLE_USE)
	self:DrawShadow(false)

	local phys = self:GetPhysicsObject()

	if IsValid(phys) then phys:Wake() end

	print("[hg.bots] director entity placed - the director is now running (hg_bot_director_status)")
end

function ENT:Use(activator)
	if CLIENT or not IsValid(activator) or not activator:IsPlayer() then return end
	activator:ConCommand("hg_bot_director_menu")
end

function ENT:OnRemove()
	if SERVER then print("[hg.bots] director entity removed") end
end

if CLIENT then
	function ENT:Draw()
		self:DrawModel()
	end
end

scripted_ents.Register(ENT, "ent_hg_director")
