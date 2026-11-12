local Shared = {}

Shared.SLOT_COUNT = 30
Shared.COLUMNS = 6

-- icon "" = tinted tile w/ initials, swap in rbxassetid when art exists
-- server re-reads maxStack from here, never trusts the client
Shared.Items = {
	wood          = { name = "Wood",          maxStack = 64, color = Color3.fromRGB(150, 104, 62),  icon = "" },
	plank         = { name = "Plank",         maxStack = 64, color = Color3.fromRGB(196, 150, 96),  icon = "" },
	stick         = { name = "Stick",         maxStack = 64, color = Color3.fromRGB(120, 82, 48),   icon = "" },
	stone         = { name = "Stone",         maxStack = 64, color = Color3.fromRGB(128, 132, 140), icon = "" },
	iron_ore      = { name = "Iron Ore",      maxStack = 32, color = Color3.fromRGB(176, 120, 104), icon = "" },
	iron_ingot    = { name = "Iron Ingot",    maxStack = 32, color = Color3.fromRGB(210, 214, 222), icon = "" },
	stone_pickaxe = { name = "Stone Pickaxe", maxStack = 1,  color = Color3.fromRGB(96, 150, 190),  icon = "" },
	iron_pickaxe  = { name = "Iron Pickaxe",  maxStack = 1,  color = Color3.fromRGB(90, 190, 170),  icon = "" },
}

return Shared