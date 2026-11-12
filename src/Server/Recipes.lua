local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Items = require(ReplicatedStorage:WaitForChild("Inventory"):WaitForChild("InventoryShared")).Items

-- just append here, bad data asserts at boot
local definitions = {
	{
		id = "plank", name = "Planks",
		ingredients = { { id = "wood", count = 1 } },
		result = { id = "plank", count = 4 },
	},
	{
		id = "stick", name = "Sticks",
		ingredients = { { id = "plank", count = 1 } },
		result = { id = "stick", count = 4 },
	},
	{
		id = "stone_pickaxe", name = "Stone Pickaxe",
		ingredients = { { id = "wood", count = 10 }, { id = "stone", count = 5 } },
		result = { id = "stone_pickaxe", count = 1 },
	},
	{
		id = "iron_ingot", name = "Iron Ingot",
		ingredients = { { id = "iron_ore", count = 2 } },
		result = { id = "iron_ingot", count = 1 },
	},
	{
		id = "iron_pickaxe", name = "Iron Pickaxe",
		ingredients = { { id = "iron_ingot", count = 3 }, { id = "stick", count = 2 } },
		result = { id = "iron_pickaxe", count = 1 },
	},
}

local Recipes = {
	byId = {},    -- server side, has the summed `needs` map
	display = {}, -- what clients get
}

local function isPosInt(n)
	return type(n) == "number" and n >= 1 and n % 1 == 0
end

for _, def in definitions do
	assert(type(def.id) == "string" and not Recipes.byId[def.id], "dupe/invalid recipe id: " .. tostring(def.id))
	assert(Items[def.result.id] and isPosInt(def.result.count), "bad result in recipe " .. def.id)

	-- sum it up, same item listed twice shouldnt under-count
	local needs = {}
	for _, ing in def.ingredients do
		assert(Items[ing.id] and isPosInt(ing.count), "bad ingredient in recipe " .. def.id)
		needs[ing.id] = (needs[ing.id] or 0) + ing.count
	end

	def.needs = needs
	Recipes.byId[def.id] = def
	table.insert(Recipes.display, {
		id = def.id,
		name = def.name,
		ingredients = def.ingredients,
		result = def.result,
	})
end

return Recipes