local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared = require(ReplicatedStorage:WaitForChild("Inventory"):WaitForChild("InventoryShared"))
local remotes = ReplicatedStorage:WaitForChild("InventoryRemotes")
local actionRF = remotes:WaitForChild("Action")
local updateRE = remotes:WaitForChild("Update")

local Items, SLOT_COUNT, COLUMNS = Shared.Items, Shared.SLOT_COUNT, Shared.COLUMNS
local ROWS = math.ceil(SLOT_COUNT / COLUMNS)
local TOGGLE_KEY = Enum.KeyCode.B

local GRID_PAD = 0.08 -- fraction of cell size
local CRAFT_DEBOUNCE = 0.15
local STATUS_TIME = 2.5
local SYNC_RETRY = 1
local DRAG_GHOST_SCALE = 0.9
local ROW_HEIGHT = 58

local Theme = {
	panel = Color3.fromRGB(24, 26, 32),
	inset = Color3.fromRGB(34, 37, 45),
	slot = Color3.fromRGB(46, 50, 61),
	stroke = Color3.fromRGB(70, 76, 92),
	text = Color3.fromRGB(235, 237, 242),
	subtext = Color3.fromRGB(160, 166, 180),
	good = Color3.fromRGB(64, 160, 96),
	disabled = Color3.fromRGB(70, 74, 86),
	bad = Color3.fromRGB(220, 96, 96),
}

local slots = {}   -- [i] = { id, count, maxStack }
local slotUIs = {} -- [i] = { Button, Icon, Label, Count, Dim }
local recipeRows = {}

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in props do o[k] = v end
	o.Parent = parent
	return o
end

local function corner(parent, scale)
	return new("UICorner", { CornerRadius = UDim.new(scale, 0) }, parent)
end

local gui = new("ScreenGui", {
	Name = "InventoryUI",
	ResetOnSpawn = false,
	IgnoreGuiInset = true, -- keeps gui coords = screen coords for hit testing
	DisplayOrder = 10,
}, playerGui)

local window = new("Frame", {
	Name = "Window",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.62, 0.72),
	BackgroundColor3 = Theme.panel,
	Visible = false,
}, gui)
corner(window, 0.025)
new("UIStroke", { Color = Theme.stroke, Thickness = 1.5 }, window)
new("UIAspectRatioConstraint", { AspectRatio = 1.75 }, window)
new("UISizeConstraint", { MinSize = Vector2.new(480, 274), MaxSize = Vector2.new(980, 560) }, window)

new("TextLabel", {
	Text = "Inventory", Font = Enum.Font.GothamBold, TextScaled = true,
	TextColor3 = Theme.text, TextXAlignment = Enum.TextXAlignment.Left,
	BackgroundTransparency = 1,
	Position = UDim2.fromScale(0.03, 0.025), Size = UDim2.fromScale(0.4, 0.075),
}, window)

local status = new("TextLabel", {
	Text = "", Font = Enum.Font.Gotham, TextScaled = true,
	TextColor3 = Theme.bad, TextXAlignment = Enum.TextXAlignment.Left,
	BackgroundTransparency = 1,
	Position = UDim2.fromScale(0.03, 0.935), Size = UDim2.fromScale(0.94, 0.045),
}, window)

local leftArea = new("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromScale(0.03, 0.12), Size = UDim2.fromScale(0.56, 0.8),
}, window)

-- square cells, same padding at any size
local wUnits = COLUMNS + (COLUMNS - 1) * GRID_PAD
local hUnits = ROWS + (ROWS - 1) * GRID_PAD

local grid = new("Frame", {
	Name = "Grid",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
}, leftArea)
new("UIAspectRatioConstraint", { AspectRatio = wUnits / hUnits }, grid)
new("UIGridLayout", {
	SortOrder = Enum.SortOrder.LayoutOrder,
	CellSize = UDim2.fromScale(1 / wUnits, 1 / hUnits),
	CellPadding = UDim2.fromScale(GRID_PAD / wUnits, GRID_PAD / hUnits),
	FillDirectionMaxCells = COLUMNS,
}, grid)

local rightArea = new("Frame", {
	BackgroundColor3 = Theme.inset,
	Position = UDim2.fromScale(0.62, 0.12), Size = UDim2.fromScale(0.35, 0.8),
}, window)
corner(rightArea, 0.03)

new("TextLabel", {
	Text = "Crafting", Font = Enum.Font.GothamBold, TextScaled = true,
	TextColor3 = Theme.text, BackgroundTransparency = 1,
	Position = UDim2.fromScale(0.05, 0.02), Size = UDim2.fromScale(0.9, 0.09),
}, rightArea)

local recipeList = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0,
	Position = UDim2.fromScale(0.03, 0.13), Size = UDim2.fromScale(0.94, 0.85),
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 4,
}, rightArea)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, recipeList)

local toggleBtn = new("TextButton", {
	Text = "Bag", Font = Enum.Font.GothamBold, TextSize = 16,
	TextColor3 = Theme.text, BackgroundColor3 = Theme.panel,
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -16),
	Size = UDim2.fromOffset(64, 40),
}, gui)
corner(toggleBtn, 0.2)

local statusToken = 0
local function notify(msg)
	statusToken += 1
	local mine = statusToken
	status.Text = msg
	task.delay(STATUS_TIME, function()
		if statusToken == mine then status.Text = "" end
	end)
end

local function makeSlot(i)
	local btn = new("TextButton", {
		Name = "Slot" .. i, LayoutOrder = i, Text = "", AutoButtonColor = false,
		BackgroundColor3 = Theme.slot,
	}, grid)
	btn:SetAttribute("SlotIndex", i)
	corner(btn, 0.12)
	new("UIStroke", { Color = Theme.stroke, Thickness = 1 }, btn)

	local icon = new("ImageLabel", {
		Name = "Icon", Visible = false,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.74, 0.74), ScaleType = Enum.ScaleType.Fit,
	}, btn)
	corner(icon, 0.15)

	local label = new("TextLabel", {
		Name = "Label", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
		TextScaled = true, Font = Enum.Font.GothamBold, TextColor3 = Color3.new(1, 1, 1),
		TextTransparency = 0.15,
	}, icon)
	new("UIPadding", {
		PaddingTop = UDim.new(0.25, 0), PaddingBottom = UDim.new(0.25, 0),
		PaddingLeft = UDim.new(0.15, 0), PaddingRight = UDim.new(0.15, 0),
	}, label)

	local count = new("TextLabel", {
		Name = "Count", Visible = false, BackgroundTransparency = 1, ZIndex = 2,
		AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(0.94, 0.94),
		Size = UDim2.fromScale(0.55, 0.27), TextScaled = true,
		Font = Enum.Font.GothamBold, TextColor3 = Theme.text,
		TextStrokeTransparency = 0.4, TextXAlignment = Enum.TextXAlignment.Right,
	}, btn)

	local dim = new("Frame", {
		Name = "Dim", Visible = false, ZIndex = 3, Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5,
	}, btn)
	corner(dim, 0.12)

	slotUIs[i] = { Button = btn, Icon = icon, Label = label, Count = count, Dim = dim }
	return btn
end

local function renderSlot(i)
	local ui, s = slotUIs[i], slots[i]
	if not ui then return end
	if not s or not Items[s.id] then
		ui.Icon.Visible = false
		ui.Count.Visible = false
		return
	end
	local def = Items[s.id]
	local noIcon = def.icon == ""
	ui.Icon.Visible = true
	ui.Icon.Image = def.icon
	ui.Icon.BackgroundColor3 = def.color
	ui.Icon.BackgroundTransparency = noIcon and 0 or 1
	ui.Label.Text = noIcon and def.name:sub(1, 2):upper() or ""
	ui.Count.Text = tostring(s.count)
	ui.Count.Visible = s.count > 1
end

local function refreshCraftable()
	local totals = {}
	for _, s in slots do
		totals[s.id] = (totals[s.id] or 0) + s.count
	end
	for _, row in recipeRows do
		local can = true
		for _, ing in row.recipe.ingredients do
			if (totals[ing.id] or 0) < ing.count then
				can = false
				break
			end
		end
		-- cosmetic, server checks again anyway
		row.button.BackgroundColor3 = can and Theme.good or Theme.disabled
	end
end

local refreshQueued = false
local function queueRefresh()
	if refreshQueued then return end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		refreshCraftable()
	end)
end

local function request(...)
	local args = table.pack(...)
	task.spawn(function()
		local ok, success, reason = pcall(function()
			return actionRF:InvokeServer(table.unpack(args, 1, args.n))
		end)
		if not ok or success == false then
			notify(("Action failed: %s"):format(tostring(ok and reason or "network")))
		end
	end)
end

local function buildRecipeRows(recipes)
	for i, recipe in recipes do
		local row = new("Frame", {
			LayoutOrder = i, Size = UDim2.new(1, -6, 0, ROW_HEIGHT),
			BackgroundColor3 = Theme.slot,
		}, recipeList)
		corner(row, 0.1)

		local parts = {}
		for _, ing in recipe.ingredients do
			local def = Items[ing.id]
			parts[#parts + 1] = ("%s x%d"):format(def and def.name or ing.id, ing.count)
		end

		new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromScale(0.04, 0.06),
			Size = UDim2.fromScale(0.6, 0.88), TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Center, TextWrapped = true,
			RichText = true, Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = Theme.subtext,
			Text = ("<font color=\"#EBEDF2\"><b>%s x%d</b></font>\n%s"):format(
				recipe.name, recipe.result.count, table.concat(parts, ", ")),
		}, row)

		local btn = new("TextButton", {
			Text = "Craft", Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.text,
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.97, 0.5),
			Size = UDim2.fromScale(0.28, 0.62), BackgroundColor3 = Theme.disabled,
		}, row)
		corner(btn, 0.2)

		local last = 0
		btn.Activated:Connect(function()
			-- stops double taps, server has its own bucket
			if os.clock() - last < CRAFT_DEBOUNCE then return end
			last = os.clock()
			request("Craft", recipe.id)
		end)

		recipeRows[#recipeRows + 1] = { recipe = recipe, button = btn }
	end
end

local drag -- { from, mode, amount, ghost, release }

local function toScreen(input)
	-- InputObject.Position skips the inset, our gui ignores it
	return Vector2.new(input.Position.X, input.Position.Y) + GuiService:GetGuiInset()
end

local function moveGhost(pos)
	drag.ghost.Position = UDim2.fromOffset(pos.X, pos.Y)
end

local function beginDrag(i, mode, release, x, y)
	local s = slots[i]
	if drag or not s or not window.Visible then return end
	if mode == "split" and s.count < 2 then return end

	local ui = slotUIs[i]
	local amount = mode == "split" and s.count // 2 or s.count

	local size = ui.Button.AbsoluteSize.X * DRAG_GHOST_SCALE
	local ghost = ui.Icon:Clone()
	ghost.Visible = true
	ghost.AnchorPoint = Vector2.new(0.5, 0.5)
	ghost.Size = UDim2.fromOffset(size, size)
	ghost.ZIndex = 50
	ghost.BackgroundTransparency += 0.15
	if amount > 1 then
		new("TextLabel", {
			BackgroundTransparency = 1, ZIndex = 51, AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1), Size = UDim2.fromScale(0.5, 0.3),
			TextScaled = true, Font = Enum.Font.GothamBold, TextColor3 = Theme.text,
			TextStrokeTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Right,
			Text = tostring(amount),
		}, ghost)
	end
	ghost.Parent = gui

	drag = { from = i, mode = mode, amount = amount, ghost = ghost, release = release }
	ui.Dim.Visible = true
	moveGhost(Vector2.new(x, y) + GuiService:GetGuiInset())
end

local function cancelDrag()
	if not drag then return end
	drag.ghost:Destroy()
	slotUIs[drag.from].Dim.Visible = false
	drag = nil
end

local function endDrag(pos)
	local d = drag
	cancelDrag()

	local target, overWindow
	for _, obj in playerGui:GetGuiObjectsAtPosition(pos.X, pos.Y) do
		local idx = obj:GetAttribute("SlotIndex")
		if idx then
			target = idx
			break
		end
		if obj == window then overWindow = true end
	end

	if target then
		if target ~= d.from then
			request(d.mode == "split" and "Split" or "Move", d.from, target, d.mode == "split" and d.amount or nil)
		end
	elseif not overWindow then
		request("Drop", d.from, d.amount)
	end
end

UserInputService.InputChanged:Connect(function(input)
	if not drag then return end
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
		moveGhost(toScreen(input))
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if drag and input.UserInputType == drag.release then
		endDrag(toScreen(input))
	end
end)

local synced, snapRev = false, 0
local pendingDeltas = {}

local function applyDelta(index, data, rev)
	if rev <= snapRev then return end -- snapshot already has it
	if type(index) ~= "number" or not slotUIs[index] then return end
	slots[index] = data or nil
	renderSlot(index)
	queueRefresh()
end

updateRE.OnClientEvent:Connect(function(kind, index, data, rev)
	if kind ~= "UpdateSlot" then return end
	if not synced then
		pendingDeltas[#pendingDeltas + 1] = { index, data, rev }
	else
		applyDelta(index, data, rev)
	end
end)

for i = 1, SLOT_COUNT do
	local btn = makeSlot(i)
	btn.MouseButton1Down:Connect(function(x, y)
		beginDrag(i, "move", Enum.UserInputType.MouseButton1, x, y)
	end)
	-- right drag = half stack
	btn.MouseButton2Down:Connect(function(x, y)
		beginDrag(i, "split", Enum.UserInputType.MouseButton2, x, y)
	end)
end

local function setVisible(v)
	window.Visible = v
	if not v then cancelDrag() end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == TOGGLE_KEY then
		setVisible(not window.Visible)
	end
end)
toggleBtn.Activated:Connect(function()
	setVisible(not window.Visible)
end)

task.spawn(function()
	local snap
	repeat
		local ok, success, data = pcall(function()
			return actionRF:InvokeServer("Sync")
		end)
		if ok and success then
			snap = data
		else
			task.wait(SYNC_RETRY) -- server still loading us
		end
	until snap

	snapRev = snap.rev
	for _, e in snap.slots do
		slots[e.slot] = { id = e.id, count = e.count, maxStack = e.maxStack }
	end
	for i = 1, SLOT_COUNT do renderSlot(i) end
	buildRecipeRows(snap.recipes)

	synced = true
	for _, d in pendingDeltas do applyDelta(d[1], d[2], d[3]) end
	table.clear(pendingDeltas)
	refreshCraftable()
end)