local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Shared = require(ReplicatedStorage:WaitForChild("Inventory"):WaitForChild("InventoryShared"))
local Recipes = require(script.Parent.Recipes)

local Items, SLOT_COUNT = Shared.Items, Shared.SLOT_COUNT

local STORE_NAME = "PlayerInventory_v1"
local AUTOSAVE_INTERVAL = 120 -- sec
local LOAD_RETRIES = 3
local LOAD_RETRY_DELAY = 1.5  -- sec, times attempt number
local RATE, BURST = 10, 20    -- tokens/sec, bucket size
local MAX_INT = 1e6
local DROP_DISTANCE = 4       -- studs in front of player
local DROP_LIFETIME = 300     -- sec
local PICKUP_SIZE = 1.5
local PICKUP_RANGE = 8
local STARTER_ITEMS = {
	{ id = "wood", count = 30 },
	{ id = "stone", count = 15 },
	{ id = "iron_ore", count = 6 },
}

type Stack = { id: string, count: number, maxStack: number }

type Inventory = {
	slots: { [number]: Stack },
	rev: number,
	synced: boolean,
	dirty: boolean,
	canSave: boolean,
	saving: boolean,
	tokens: number,
	last: number,
}

local store = DataStoreService:GetDataStore(STORE_NAME)

local InventoryService = {}
local inventories: { [Player]: Inventory } = {}
local inflightSaves = 0

local remotes = Instance.new("Folder")
remotes.Name = "InventoryRemotes"

local actionRF = Instance.new("RemoteFunction")
actionRF.Name = "Action"
actionRF.Parent = remotes

local updateRE = Instance.new("RemoteEvent")
updateRE.Name = "Update"
updateRE.Parent = remotes

remotes.Parent = ReplicatedStorage

local function isInt(n)
	-- n == n kills NaN, upper bound kills inf
	return type(n) == "number" and n == n and n >= 1 and n <= MAX_INT and n % 1 == 0
end

local function validSlot(i)
	return isInt(i) and i <= SLOT_COUNT
end

local function newStack(id: string, count: number): Stack
	return { id = id, count = count, maxStack = Items[id].maxStack }
end

local function cloneSlots(slots)
	local copy = {}
	for i, s in slots do
		copy[i] = { id = s.id, count = s.count, maxStack = s.maxStack }
	end
	return copy
end

local function countOf(slots, id)
	local total = 0
	for _, s in slots do
		if s.id == id then
			total += s.count
		end
	end
	return total
end

-- returns whatever didnt fit
local function addToSlots(slots, id, count)
	-- fill partial stacks first
	for i = 1, SLOT_COUNT do
		local s = slots[i]
		if s and s.id == id and s.count < s.maxStack then
			local n = math.min(count, s.maxStack - s.count)
			s.count += n
			count -= n
			if count == 0 then return 0 end
		end
	end
	local maxStack = Items[id].maxStack
	for i = 1, SLOT_COUNT do
		if not slots[i] then
			local n = math.min(count, maxStack)
			slots[i] = newStack(id, n)
			count -= n
			if count == 0 then return 0 end
		end
	end
	return count
end

local function removeFromSlots(slots, id, count)
	for i = 1, SLOT_COUNT do
		local s = slots[i]
		if s and s.id == id then
			local n = math.min(count, s.count)
			s.count -= n
			count -= n
			if s.count == 0 then
				slots[i] = nil
			end
			if count == 0 then return true end
		end
	end
	return count == 0
end

local function sameSlot(a, b)
	if a == nil or b == nil then return a == b end
	return a.id == b.id and a.count == b.count
end

-- swap tables and only send slots that changed. nothing yields between clone
-- and commit so ops cant interleave
local function commit(player: Player, inv: Inventory, newSlots)
	local old = inv.slots
	inv.slots = newSlots
	inv.dirty = true
	inv.rev += 1

	if not inv.synced then return end
	for i = 1, SLOT_COUNT do
		local before, after = old[i], newSlots[i]
		if not sameSlot(before, after) then
			-- false not nil, nil gets lost in the remote args
			updateRE:FireClient(player, "UpdateSlot", i,
				after and { id = after.id, count = after.count, maxStack = after.maxStack } or false,
				inv.rev)
		end
	end
end

local dropFolder = Instance.new("Folder")
dropFolder.Name = "DroppedItems"
dropFolder.Parent = Workspace

local function spawnPickup(id: string, count: number, position: Vector3)
	local def = Items[id]
	local part = Instance.new("Part")
	part.Name = "Pickup_" .. id
	part.Size = Vector3.one * PICKUP_SIZE
	part.Color = def.color
	part.Material = Enum.Material.SmoothPlastic
	part.Position = position

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick up"
	prompt.ObjectText = ("%s x%d"):format(def.name, count)
	prompt.HoldDuration = 0.2
	prompt.MaxActivationDistance = PICKUP_RANGE
	prompt.Parent = part

	local remaining, claiming = count, false
	prompt.Triggered:Connect(function(plr)
		-- two ppl triggering same frame
		if claiming or not part.Parent then return end
		claiming = true
		local left = InventoryService.AddItem(plr, id, remaining)
		if left == 0 then
			part:Destroy()
			return
		end
		remaining = left -- bag full, rest stays on the ground
		prompt.ObjectText = ("%s x%d"):format(def.name, left)
		claiming = false
	end)

	part.Parent = dropFolder
	part:SetNetworkOwner(nil)
	Debris:AddItem(part, DROP_LIFETIME)
end

-- ops get (player, inv, ...) and return ok, reason
local ops = {}

function ops.Move(player, inv, from, to)
	if not (validSlot(from) and validSlot(to)) or from == to then
		return false, "bad_args"
	end
	local work = cloneSlots(inv.slots)
	local src, dst = work[from], work[to]
	if not src then return false, "empty_source" end

	if not dst then
		work[to], work[from] = src, nil
	elseif dst.id == src.id then
		-- overflow stays in the source slot
		local n = math.min(src.count, dst.maxStack - dst.count)
		if n <= 0 then return false, "target_full" end
		dst.count += n
		src.count -= n
		if src.count == 0 then work[from] = nil end
	else
		work[from], work[to] = dst, src
	end

	commit(player, inv, work)
	return true
end

function ops.Split(player, inv, slotIndex, targetIndex, amount)
	if not (validSlot(slotIndex) and validSlot(targetIndex)) or slotIndex == targetIndex then
		return false, "bad_args"
	end
	local work = cloneSlots(inv.slots)
	local src = work[slotIndex]
	if not src or src.count < 2 then return false, "cannot_split" end
	if work[targetIndex] then return false, "target_occupied" end

	if amount == nil then
		amount = src.count // 2
	elseif not isInt(amount) or amount >= src.count then
		return false, "bad_amount"
	end

	src.count -= amount
	work[targetIndex] = newStack(src.id, amount)
	commit(player, inv, work)
	return true
end

function ops.Drop(player, inv, slotIndex, amount)
	if not validSlot(slotIndex) then return false, "bad_args" end
	local src = inv.slots[slotIndex]
	if not src then return false, "empty_source" end

	if amount == nil then
		amount = src.count
	elseif not isInt(amount) or amount > src.count then
		return false, "bad_amount"
	end

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return false, "no_character" end

	local id = src.id
	local work = cloneSlots(inv.slots)
	work[slotIndex].count -= amount
	if work[slotIndex].count == 0 then work[slotIndex] = nil end
	commit(player, inv, work)

	spawnPickup(id, amount, root.Position + root.CFrame.LookVector * DROP_DISTANCE)
	return true
end

function ops.Craft(player, inv, recipeId)
	if type(recipeId) ~= "string" then return false, "bad_args" end
	local recipe = Recipes.byId[recipeId]
	if not recipe then return false, "unknown_recipe" end

	local work = cloneSlots(inv.slots)
	for id, need in recipe.needs do
		if countOf(work, id) < need then return false, "missing_resources" end
	end
	for id, need in recipe.needs do
		removeFromSlots(work, id, need)
	end
	-- result has to fit AFTER ingredients are gone, otherwise nothing commits
	if addToSlots(work, recipe.result.id, recipe.result.count) > 0 then
		return false, "no_space"
	end

	commit(player, inv, work)
	return true
end

local function allow(inv: Inventory): boolean
	local now = os.clock()
	inv.tokens = math.min(BURST, inv.tokens + (now - inv.last) * RATE)
	inv.last = now
	if inv.tokens < 1 then return false end
	inv.tokens -= 1
	return true
end

local function buildSnapshot(inv: Inventory)
	local list = {}
	for i = 1, SLOT_COUNT do
		local s = inv.slots[i]
		if s then
			list[#list + 1] = { slot = i, id = s.id, count = s.count, maxStack = s.maxStack }
		end
	end
	return { rev = inv.rev, slots = list, recipes = Recipes.display }
end

actionRF.OnServerInvoke = function(player, action, a, b, c)
	local inv = inventories[player]
	if not inv then return false, "not_ready" end
	if type(action) ~= "string" then return false, "bad_args" end
	if not allow(inv) then return false, "rate_limited" end

	if action == "Sync" then
		inv.synced = true
		return true, buildSnapshot(inv)
	end

	local op = ops[action]
	if not op then return false, "unknown_action" end
	return op(player, inv, a, b, c)
end

--- Adds items to a players bag. Returns how many did NOT fit.
function InventoryService.AddItem(player: Player, id: string, count: number): number
	local inv = inventories[player]
	if not inv or not Items[id] or not isInt(count) then return count end
	local work = cloneSlots(inv.slots)
	local left = addToSlots(work, id, count)
	if left < count then
		commit(player, inv, work)
	end
	return left
end

--- Removes items, all or nothing. False if they dont have enough.
function InventoryService.RemoveItem(player: Player, id: string, count: number): boolean
	local inv = inventories[player]
	if not inv or not Items[id] or not isInt(count) then return false end
	if countOf(inv.slots, id) < count then return false end
	local work = cloneSlots(inv.slots)
	removeFromSlots(work, id, count)
	commit(player, inv, work)
	return true
end

--- Total of an item across every slot.
function InventoryService.GetCount(player: Player, id: string): number
	local inv = inventories[player]
	return inv and countOf(inv.slots, id) or 0
end

local function keyFor(player: Player)
	return "inv_" .. player.UserId
end

local function sanitize(data)
	local slots = {}
	if type(data) ~= "table" then return slots end
	for _, e in data do
		if type(e) == "table" and validSlot(e.slot) and not slots[e.slot]
			and type(e.id) == "string" and Items[e.id] and isInt(e.count) then
			slots[e.slot] = newStack(e.id, math.min(e.count, Items[e.id].maxStack))
		end
	end
	return slots
end

local function save(player: Player, inv: Inventory)
	while inv.saving do task.wait() end
	if not inv.canSave or not inv.dirty then return end

	local payload = {}
	for i, s in inv.slots do
		payload[#payload + 1] = { slot = i, id = s.id, count = s.count }
	end

	inv.saving = true
	inv.dirty = false
	inflightSaves += 1
	local ok, err = pcall(store.UpdateAsync, store, keyFor(player), function()
		return payload
	end)
	inflightSaves -= 1
	inv.saving = false

	if not ok then
		inv.dirty = true -- next autosave tries again
		warn(("[Inventory] save failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

local function onPlayerAdded(player: Player)
	local data, ok
	for attempt = 1, LOAD_RETRIES do
		ok, data = pcall(store.GetAsync, store, keyFor(player))
		if ok then break end
		task.wait(attempt * LOAD_RETRY_DELAY)
	end
	if not player.Parent then return end

	local canSave = ok
	if not ok then
		-- studio w/o api access: play on starter data, never write back
		if not RunService:IsStudio() then
			player:Kick("Couldn't load your inventory. Please rejoin.")
			return
		end
		warn("[Inventory] DataStore unavailable, saving off for this session")
	end

	local slots
	if ok and data ~= nil then
		slots = sanitize(data)
	else
		slots = {}
		for _, item in STARTER_ITEMS do
			addToSlots(slots, item.id, item.count)
		end
	end

	inventories[player] = {
		slots = slots,
		rev = 0,
		synced = false,
		dirty = ok and data == nil, -- brand new player, save the starter kit
		canSave = canSave,
		saving = false,
		tokens = BURST,
		last = os.clock(),
	}
end

local function onPlayerRemoving(player: Player)
	local inv = inventories[player]
	inventories[player] = nil
	if inv then save(player, inv) end
end

--- Hooks players, autosave and BindToClose. Call once.
function InventoryService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for p, inv in inventories do
				task.spawn(save, p, inv)
			end
		end
	end)

	game:BindToClose(function()
		for p, inv in inventories do
			task.spawn(save, p, inv)
		end
		-- engine cuts us off at 30s anyway
		while inflightSaves > 0 do task.wait() end
	end)
end

return InventoryService