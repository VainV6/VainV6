-- Restaurant Tycoon -- place 119048529960596.
--
-- Data model (confirmed from the place file):
--  * COOKING is a multi-step minigame. The player starts a dish; then the server
--    drives a SEQUENCE of input steps (Hold the Mouse, Click, Click Rapidly, ...)
--    via CookUpdated. Each step is completed by firing
--    ReplicatedStorage.Events.Cook.CookInputRequested:FireServer("CompleteTask",
--    kitchenModel, itemType), where kitchenModel/itemType come from the Cook system
--    (require PlayerScripts.Source.Systems.Cook -> :GetCurrentKitchenModel(),
--    .CurrentItemType, .IsCooking). Auto Cook spams CompleteTask WHILE IsCooking,
--    so it completes every step of a dish the PLAYER started -- it never starts or
--    queues a cook itself.
--  * CUSTOMERS use "CustomerInteractPrompt"-tagged prompts (one per customer, on
--    their HumanoidRootPart) for the whole lifecycle (greet/seat, take order, serve,
--    bill). Firing a customer's prompt performs the next action they need.
--  * Table tasks (CollectDishes/Serve/CollectBill) are "Interaction"-tagged prompts.
--  * ~0.5s server debounce on interactions; firing an idle prompt is a no-op.

local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local players = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local collectionService = cloneref(game:GetService('CollectionService'))

local lplr = players.LocalPlayer
local vain = shared.vain

local fireprompt = fireproximityprompt
	or (getgenv and getgenv().fireproximityprompt)

-- ============================================================================
-- Shared prompt-firing helpers
-- ============================================================================

-- Fire every enabled prompt carrying the given tag (optionally only those whose
-- Name matches one of `namePrefixes`). Returns the count fired.
local function fireTagged(tag, namePrefixes)
	if not fireprompt then return 0 end
	local ok, prompts = pcall(function() return collectionService:GetTagged(tag) end)
	if not ok then return 0 end
	local fired = 0
	for _, p in prompts do
		if p:IsA('ProximityPrompt') and p.Enabled then
			local pass = true
			if namePrefixes then
				pass = false
				local n = string.lower(p.Name or '')
				for _, pre in namePrefixes do
					if n:find(pre, 1, true) then pass = true break end
				end
			end
			if pass then
				pcall(function() fireprompt(p, p.HoldDuration or 0) end)
				fired = fired + 1
			end
		end
	end
	return fired
end

-- Fire ONLY the restaurant interactions whose task Key is in `keys` (a set). The
-- Interactions system stores every interaction's data (including .Key and .Prompt)
-- in Interactions.PromptData[tycoon][Id]; firing the specific prompts lets us do
-- e.g. collect-dishes/collect-bill WITHOUT touching the Cook/Serve prompts (firing
-- the Cook interaction is what starts/queues a new dish). Returns count fired.
local Interactions
local function fireInteractionKeys(keys)
	if not fireprompt then return 0 end
	if not Interactions then
		pcall(function()
			Interactions = require(lplr.PlayerScripts.Source.Systems.Restaurant.Interactions)
		end)
	end
	if not (Interactions and Interactions.PromptData) then return 0 end
	local fired = 0
	pcall(function()
		for _, byId in pairs(Interactions.PromptData) do
			for _, data in pairs(byId) do
				if type(data) == 'table' and keys[data.Key] then
					local p = data.Prompt
					if p and p:IsA('ProximityPrompt') and p.Enabled then
						pcall(function() fireprompt(p, p.HoldDuration or 0) end)
						fired = fired + 1
					end
				end
			end
		end
	end)
	return fired
end

-- ── Drive-thru ──────────────────────────────────────────────────────────────
-- The drive-thru is a SEPARATE task system (not the Interaction prompts). Cars
-- have a State (Entering/Ordering/Paying/WaitingForFood) in
-- DriveThru:GetStorage(tycoon).Cars (map carName -> { State, Model, Orders }).
--   Ordering        -> take order  (TaskCompleted{ Name=TakeDriveThruOrder })
--   Paying          -> collect bill (TaskCompleted{ Name=CollectDriveThruBill })
--   WaitingForFood  -> SERVE, which needs the held FoodModel, so we call the
--                      game's own ServeFood:CompleteForCar(tycoon, carModel)
--                      (it grabs/validates the food and fires the right payload).
local DriveThru, TaskCompleted, ServeFood
local function driveThruTycoon()
	local t = lplr:FindFirstChild('Tycoon')
	return t and t.Value
end
local function resolveDriveThru()
	if not DriveThru then
		pcall(function() DriveThru = require(lplr.PlayerScripts.Source.Systems.Restaurant.DriveThru) end)
	end
	if not TaskCompleted then
		pcall(function() TaskCompleted = replicatedStorage.Events.Restaurant.TaskCompleted end)
	end
	if not ServeFood then
		pcall(function() ServeFood = require(lplr.PlayerScripts.Source.Modules.Tasks.ServeFood) end)
	end
	return DriveThru ~= nil
end
-- Iterate { carName, car, carModel } for every car whose State == `state`.
local function forEachCar(state, fn)
	if not resolveDriveThru() then return 0 end
	local tycoon = driveThruTycoon()
	if not tycoon then return 0 end
	local n = 0
	pcall(function()
		local storage = DriveThru.GetStorage and DriveThru:GetStorage(tycoon)
		local cars = storage and storage.Cars
		if type(cars) ~= 'table' then return end
		for carName, car in pairs(cars) do
			if type(car) == 'table' and car.State == state then
				fn(tycoon, carName, car)
				n = n + 1
			end
		end
	end)
	return n
end
-- Simple TaskCompleted tasks (take order / collect bill).
local function fireDriveThru(taskName, state)
	return forEachCar(state, function(tycoon, carName)
		if TaskCompleted then
			pcall(function() TaskCompleted:FireServer({ Name = taskName, CarId = carName, Tycoon = tycoon }) end)
		end
	end)
end
-- Serve every WaitingForFood car via the game's own serve (handles FoodModel/grab).
local function serveDriveThru()
	return forEachCar('WaitingForFood', function(tycoon, _carName, car)
		local carModel = car.Model or car.CarModel
		if ServeFood and ServeFood.CompleteForCar and carModel then
			pcall(function() ServeFood:CompleteForCar(tycoon, carModel) end)
		end
	end)
end

-- Build a loop-toggle module. `worker` runs every tick; `withSpeed` adds a slider.
local function makeAuto(name, tooltip, worker, withSpeed)
	local module, Speed
	module = vain.Categories.World:CreateModule({
		Name = name,
		Tooltip = tooltip .. (fireprompt and '' or ' (needs a fireproximityprompt-capable executor)'),
		Function = function(callback)
			if callback then
				if not fireprompt then
					vain:CreateNotification(name, 'Your executor has no fireproximityprompt.', 7, 'warning')
					return
				end
				task.spawn(function()
					repeat
						pcall(worker)
						local delay = (withSpeed and Speed and (1 / math.max(Speed.Value, 0.1))) or 0.4
						task.wait(delay)
					until not module.Enabled
				end)
			end
		end,
	})
	if withSpeed then
		Speed = module:CreateSlider({
			Name = 'Speed',
			Tooltip = 'Fires per second (the server debounces at ~0.5s, so very high values mainly help when many stations are active).',
			Min = 1,
			Max = 20,
			Default = 8,
			Suffix = function(val) return '/s' end,
		})
	end
	return module
end

-- ============================================================================
-- AUTO COOK  -- auto-complete every step of the dish YOU'RE cooking
-- ============================================================================
-- Cooking a dish is a multi-step minigame (Hold the Mouse, Click, Click Rapidly,
-- ...). Each step completes by firing CookInputRequested:FireServer("CompleteTask",
-- kitchenModel, itemType). We read those from the Cook system and spam CompleteTask
-- ONLY while Cook.IsCooking -- i.e. a dish the player already started -- so it
-- auto-finishes every step of that dish and never starts/queues a cook itself.
run(function()
	local Cook, CookInputRequested, COMPLETE

	local function resolve()
		if not Cook then
			pcall(function()
				Cook = require(lplr.PlayerScripts.Source.Systems.Cook)
			end)
		end
		if not CookInputRequested then
			pcall(function()
				CookInputRequested = replicatedStorage.Events.Cook.CookInputRequested
			end)
		end
		if COMPLETE == nil then
			-- CookReplication.CompleteTask == "CompleteTask"
			COMPLETE = 'CompleteTask'
			pcall(function()
				COMPLETE = require(replicatedStorage.Source.Enums.Cook.CookReplication).CompleteTask or COMPLETE
			end)
		end
		return Cook and CookInputRequested
	end

	local module, Speed, AutoQueue

	local function completeStep()
		pcall(function()
			if Cook.IsCooking then
				local kitchen = Cook.CurrentKitchenModel or (Cook.GetCurrentKitchenModel and Cook:GetCurrentKitchenModel())
				local item = Cook.CurrentItemType
				if kitchen ~= nil and item ~= nil then
					CookInputRequested:FireServer(COMPLETE, kitchen, item)
				end
			end
		end)
	end

	module = vain.Categories.World:CreateModule({
		Name = 'Auto Cook',
		Tooltip = 'Auto-completes every step (Hold, Click, etc.) of a dish, on any station. With Auto Queue on it also starts new dishes from the queue by itself.',
		Function = function(callback)
			if callback then
				if not resolve() then
					vain:CreateNotification('Auto Cook', 'Could not hook the cooking system in this place.', 6, 'warning')
					return
				end
				task.spawn(function()
					repeat
						-- Re-check Enabled right before acting so a disable stops instantly.
						if module.Enabled then
							if Cook.IsCooking then
								-- mid-dish: complete the current step
								completeStep()
							elseif AutoQueue and AutoQueue.Enabled then
								-- idle: start/queue the next dish (fire the Cook interaction)
								fireInteractionKeys({ Cook = true })
							end
						end
						-- Floor the interval so we never fire faster than the cook UI
						-- (PlayerGui.Cooking) can render each step. Keep at least ~0.12s.
						local delay = (Speed and (1 / math.max(Speed.Value, 0.1))) or 0.12
						task.wait(math.max(delay, 0.12))
					until not module.Enabled
				end)
			end
		end,
	})
	AutoQueue = module:CreateToggle({
		Name = 'Auto Queue',
		Tooltip = 'Also automatically start new dishes from the cooking queue (not just complete the one you started).',
		Default = true,
	})
	Speed = module:CreateSlider({
		Name = 'Speed',
		Tooltip = 'How many steps per second to complete. Capped so the cooking UI stays visible (going faster hid it because the dish finished before the bar could render).',
		Min = 1,
		Max = 8,
		Default = 6,
		Suffix = function(val) return '/s' end,
	})
end)

-- ============================================================================
-- AUTO COLLECT DISHES  -- collect dirty dishes from tables only
-- ============================================================================
run(function()
	makeAuto(
		'Auto Collect Dishes',
		'Automatically collects dirty dishes from tables.',
		function()
			fireInteractionKeys({ CollectDishes = true })
		end,
		false
	)
end)

-- ============================================================================
-- AUTO COLLECT MONEY  -- collect bills (dine-in) and drive-thru payments
-- ============================================================================
-- Dine-in bills are the "CollectBill" Interaction; drive-thru payments are the
-- Paying-car Task.CollectDriveThruBill. Both are money collection.
run(function()
	makeAuto(
		'Auto Collect Money',
		'Automatically collects bills from tables and drive-thru payments.',
		function()
			fireInteractionKeys({ CollectBill = true })
			fireDriveThru('CollectDriveThruBill', 'Paying')
		end,
		false
	)
end)

-- ============================================================================
-- AUTO SEAT CUSTOMERS  -- greet and seat waiting customers
-- ============================================================================
run(function()
	makeAuto(
		'Auto Seat Customers',
		'Automatically greets and seats waiting customers.',
		function()
			fireTagged('CustomerInteractPrompt')
		end,
		false
	)
end)

-- ============================================================================
-- AUTO TAKE ORDERS  -- take dine-in and drive-thru orders
-- ============================================================================
-- Dine-in: the per-customer "CustomerInteractPrompt". Drive-thru: a car in the
-- Ordering state, taken via Task.TakeDriveThruOrder.
run(function()
	makeAuto(
		'Auto Take Orders',
		'Automatically takes seated customers\' orders and drive-thru orders.',
		function()
			fireTagged('CustomerInteractPrompt')
			fireDriveThru('TakeDriveThruOrder', 'Ordering')
		end,
		false
	)
end)

-- ============================================================================
-- AUTO SERVE CUSTOMERS  -- serve ready food to tables and drive-thru cars
-- ============================================================================
-- Dine-in: the "Serve" Interaction. Drive-thru: a car WaitingForFood, served via
-- Task.Serve. Neither touches Cook (which would queue dishes).
run(function()
	makeAuto(
		'Auto Serve Customers',
		'Automatically serves ready food to seated customers and drive-thru cars.',
		function()
			fireInteractionKeys({ Serve = true })
			serveDriveThru()
		end,
		false
	)
end)

-- ============================================================================
-- ANTI WAYPOINT GLITCH  -- clear the green direction arrow when it gets stuck
-- ============================================================================
-- The green arrow is a Waypoint (Systems.Waypoints): Create clones
-- ReplicatedStorage.Assets.Effects.DirectionBeam onto a part; Destroy removes it.
-- When a task ends abnormally the game sometimes fails to Destroy it, so the arrow
-- lingers. This clears stuck ones: while enabled it (1) tears down orphaned
-- DirectionBeam markers each pass, and (2) can force Waypoints:DestroyAll(). It
-- also does a full clear the moment you enable it, wiping any pre-existing glitch.
run(function()
	local AntiWaypoint, ForceAll
	local Waypoints

	local function resolveW()
		if not Waypoints then
			pcall(function() Waypoints = require(lplr.PlayerScripts.Source.Systems.Waypoints) end)
		end
		return Waypoints
	end

	-- The green arrow = a DirectionBeam (Beam) whose owning Part sits in the SHARED
	-- workspace.Temp folder. Temp also holds interaction-prompt parts, build
	-- previews, the world map, etc -- so we must NOT destroy arbitrary parts in it
	-- (that was deleting the interaction parts and breaking Auto Serve/Collect).
	-- The visible arrow IS the beam, so destroying the beam (and only a part that is
	-- unambiguously a waypoint marker) removes it without touching anything else.
	local function isWaypointPart(part)
		-- a waypoint marker part is a transparent anchored Part that ONLY contains a
		-- DirectionBeam + WaypointAttachment (nothing else lives on it).
		if not part:IsA('BasePart') then return false end
		local hasBeam, hasWpAtt, other = false, false, false
		for _, c in part:GetChildren() do
			if c:IsA('Beam') and c.Name == 'DirectionBeam' then hasBeam = true
			elseif c:IsA('Attachment') and c.Name == 'WaypointAttachment' then hasWpAtt = true
			else other = true end
		end
		return hasBeam and hasWpAtt and not other
	end

	local function sweepOrphans()
		local temp = workspace:FindFirstChild('Temp')
		if not temp then return end
		for _, d in temp:GetChildren() do
			-- destroy only parts that are clearly a waypoint marker
			if d:IsA('BasePart') and isWaypointPart(d) then
				pcall(function() d:Destroy() end)
			else
				-- or a stray DirectionBeam directly (kill just the beam, not its parent)
				local beam = d:IsA('Beam') and d.Name == 'DirectionBeam' and d
					or d:FindFirstChild('DirectionBeam')
				if beam then pcall(function() beam:Destroy() end) end
			end
		end
	end

	local function clearAll()
		-- Ask the game to tear down its tracked waypoints first (cleanest), then
		-- sweep any instances it left orphaned.
		resolveW()
		if Waypoints and Waypoints.DestroyAll then
			pcall(function() Waypoints:DestroyAll() end)
		end
		sweepOrphans()
	end

	AntiWaypoint = vain.Categories.World:CreateModule({
		Name = 'Anti Waypoint Glitch',
		Tooltip = 'Removes the green direction arrow (including stuck/glitched ones the game fails to clear). Clears any existing arrow the moment you enable it, then keeps the world clear -- note this also removes normal task arrows, which the auto modules don\'t need anyway.',
		Function = function(callback)
			if callback then
				clearAll()   -- one-shot: wipe any pre-existing glitched marker now
				task.spawn(function()
					repeat
						if ForceAll and ForceAll.Enabled then
							clearAll()
						else
							pcall(sweepOrphans)
						end
						task.wait(0.4)
					until not AntiWaypoint.Enabled
				end)
			end
		end,
	})
	ForceAll = AntiWaypoint:CreateToggle({
		Name = 'Force Clear All',
		Tooltip = 'Also destroy ALL waypoints (including valid ones) every pass, not just stray/orphaned markers. Use if a stuck arrow won\'t clear otherwise.',
		Default = false,
	})
end)

-- ============================================================================
-- AUTO HARVEST CROPS  -- harvest ready crops on your farming plot
-- ============================================================================
-- Crops have states (Empty/Growing/Completed/Locked). A "Completed" crop is
-- harvested via RequestHarvest:InvokeServer(cropName). We find ready crops and
-- harvest them on a loop.
run(function()
	local AutoHarvest
	local Farming, RequestHarvest

	local function resolve()
		if not RequestHarvest then
			pcall(function()
				RequestHarvest = replicatedStorage.Events.Farming.RequestHarvest
			end)
		end
		if not Farming then
			pcall(function()
				Farming = require(lplr.PlayerScripts.Source.Systems.Farming)
			end)
		end
		return RequestHarvest ~= nil
	end

	-- Harvest every crop reported "Completed". We read the plot's crops from the
	-- Farming system when available; else fall back to scanning tagged crops.
	local function harvestReady()
		if not RequestHarvest then return end
		-- Preferred: ask the Farming system for its crops + states.
		local handled = false
		pcall(function()
			if Farming and Farming.Plot and Farming.GetState then
				for _, crop in Farming.Plot:GetChildren() do
					local ok, state = pcall(function() return Farming:GetState(crop) end)
					if ok and tostring(state):lower():find('complet') then
						pcall(function() RequestHarvest:InvokeServer(crop.Name) end)
						handled = true
					end
				end
			end
		end)
		if handled then return end
		-- Fallback: any workspace model tagged/attributed as a completed crop.
		pcall(function()
			for _, m in workspace:GetDescendants() do
				local state = m:GetAttribute('CropState')
				if state and tostring(state):lower():find('complet') then
					pcall(function() RequestHarvest:InvokeServer(m.Name) end)
				end
			end
		end)
	end

	AutoHarvest = vain.Categories.World:CreateModule({
		Name = 'Auto Harvest Crops',
		Tooltip = 'Automatically harvests any crop that is ready on your farming plot.',
		Function = function(callback)
			if callback then
				if not resolve() then
					vain:CreateNotification('Auto Harvest', 'Farming system not found in this place.', 6, 'warning')
					return
				end
				task.spawn(function()
					repeat
						pcall(harvestReady)
						task.wait(1)
					until not AutoHarvest.Enabled
				end)
			end
		end,
	})
end)

-- ============================================================================
-- AUTO BOOST DISHES  -- buy the needed ingredients and boost every unboosted dish
-- ============================================================================
-- A dish is boosted with ingredients (eggs, flesh, ...) bought from plaza NPCs.
-- Flow (all confirmed remotes/data):
--   * dishes on the menu + which are boosted: GetBoostedFoodDictionary()
--   * a dish's required ingredients: FoodUtility:GetIngredients(foodKey)
--     -> { IngredientName = qty, ... }
--   * what you own: FoodMenu:GetIngredientOwnership() -> { IngredientName = count }
--   * buy: PurchaseIngredientRequested:FireServer(tycoon, ingredientName, amount)
--   * boost: BoostRequested:FireServer(tycoon, foodKey)
-- We only ever act on dishes that are NOT already boosted, so it never over-buys.
-- Data lives in PlayerData (Systems.PlayerData), read via
-- PlayerData:GetKey(DataStoreType.Restaurant, DataKey.X, ownerPlayer):
--   DataKey.Menu -> your dishes, DataKey.BoostedFoods -> boosted set,
--   DataKey.Ingredients -> owned ingredients. The tycoon obj is
--   LocalPlayer.Tycoon.Value (its .Player.Value is the owner). This is far more
--   robust than the UI-controller getters (which only populate when the menu is
--   open). Remotes: PurchaseIngredientRequested:FireServer(tycoon, ingredient,
--   amount); BoostRequested:FireServer(tycoon, foodKey).
run(function()
	local AutoBoost, Notify
	local FoodUtility, PlayerData
	local PurchaseIngredient, BoostRequested

	local function resolve()
		if PurchaseIngredient == nil then
			pcall(function() PurchaseIngredient = replicatedStorage.Events.Food.PurchaseIngredientRequested end)
		end
		if BoostRequested == nil then
			pcall(function() BoostRequested = replicatedStorage.Events.Food.BoostRequested end)
		end
		if FoodUtility == nil then
			pcall(function() FoodUtility = require(replicatedStorage.Source.Utility.Food.FoodUtility) end)
		end
		if PlayerData == nil then
			pcall(function() PlayerData = require(lplr.PlayerScripts.Source.Systems.PlayerData) end)
		end
		return PurchaseIngredient and BoostRequested and FoodUtility and PlayerData
	end

	-- The tycoon object (LocalPlayer.Tycoon.Value) + its owner Player value.
	local function tycoonAndOwner()
		local tyc = lplr:FindFirstChild('Tycoon')
		tyc = tyc and tyc.Value
		local owner
		pcall(function() owner = tyc and tyc.Player and tyc.Player.Value end)
		return tyc, owner
	end

	local function getData(dataKey, owner)
		local v
		pcall(function()
			v = PlayerData:GetKey(PlayerData.DataStoreType.Restaurant, PlayerData.DataKey[dataKey], owner)
		end)
		return v or {}
	end

	local function boostAll()
		local tycoon, owner = tycoonAndOwner()
		if not (tycoon and owner) then return 0, 'no tycoon (load your restaurant)' end

		local menu = getData('Menu', owner)          -- dish list
		local boosted = getData('BoostedFoods', owner)  -- { foodKey = true }
		local own = getData('Ingredients', owner)       -- { ingredient = count }

		-- Menu may be a { foodKey = data } map or an array of keys; handle both.
		local dishKeys = {}
		for k, v in pairs(menu) do
			if type(k) == 'string' then
				dishKeys[#dishKeys + 1] = k
			elseif type(v) == 'string' then
				dishKeys[#dishKeys + 1] = v
			end
		end

		local acted = 0
		for _, foodKey in dishKeys do
			if not AutoBoost.Enabled then break end
			if not boosted[foodKey] then
				local need = {}
				pcall(function() need = FoodUtility:GetIngredients(foodKey) or {} end)
				for ing, qty in pairs(need) do
					local have = tonumber(own[ing]) or 0
					local short = (tonumber(qty) or 0) - have
					if short > 0 then
						pcall(function() PurchaseIngredient:FireServer(tycoon, ing, short) end)
						own[ing] = have + short
						task.wait(0.15)
					end
				end
				pcall(function() BoostRequested:FireServer(tycoon, foodKey) end)
				boosted[foodKey] = true
				acted = acted + 1
				task.wait(0.25)
			end
		end
		return acted, (#dishKeys .. ' dishes on menu')
	end

	AutoBoost = vain.Categories.World:CreateModule({
		Name = 'Auto Boost Dishes',
		Tooltip = 'Buys the ingredients each UNBOOSTED dish needs (from the plaza shops) and boosts it. Skips already-boosted dishes, so it never over-buys. Load your restaurant first.',
		Function = function(callback)
			if callback then
				if not resolve() then
					vain:CreateNotification('Auto Boost', 'Boost/ingredient system not found here.', 6, 'warning')
					return
				end
				task.spawn(function()
					repeat
						local acted, info = boostAll()
						if Notify and Notify.Enabled then
							vain:CreateNotification('Auto Boost',
								(acted > 0 and ('Boosted ' .. acted .. ' dish(es). ') or 'Nothing to boost. ')
									.. tostring(info), 4)
						end
						task.wait(3)
					until not AutoBoost.Enabled
				end)
			end
		end,
	})
	Notify = AutoBoost:CreateToggle({
		Name = 'Notify',
		Tooltip = 'Show what it did each pass (how many dishes boosted / on menu). Useful to confirm it\'s working.',
		Default = true,
	})
end)

-- ============================================================================
-- AUTO QUEST  -- claim quest rewards and auto-pick a random dish reward
-- ============================================================================
-- Quests (Objectives) reward you on completion; often the reward is a choice of a
-- new dish to unlock. Flow (confirmed):
--   * claiming a completed quest triggers RewardRequested -> the game shows the
--     reward screen. We click the visible Claim/Collect reward buttons in the
--     objectives UI so the game supplies the correct reward id.
--   * dish rewards arrive as panels tagged "SelectRewardScreenPanel", each named
--     "Reward_<foodKey>" with a SelectButton that fires RewardChosen(foodKey).
--     We pick a RANDOM panel and fire RewardChosen:FireServer(foodKey).
run(function()
	local AutoQuest, PickDish
	local RewardChosen

	local function resolveQ()
		if not RewardChosen then
			pcall(function() RewardChosen = replicatedStorage.Events.Rewards.RewardChosen end)
		end
		return RewardChosen ~= nil
	end

	-- Trigger a GuiButton's click handlers. GUI signals can't be :Fire()'d, so use
	-- the executor's firesignal on the button's Activated/MouseButton1Click
	-- connections (works on all mainstream executors).
	local firesignal = firesignal or (getgenv and getgenv().firesignal)
	local getconns = getconnections or (getgenv and getgenv().getconnections)
	local function press(btn)
		if not (btn and btn:IsA('GuiButton')) then return end
		pcall(function()
			if firesignal then
				firesignal(btn.Activated)
				firesignal(btn.MouseButton1Click)
			elseif getconns then
				for _, sig in { btn.Activated, btn.MouseButton1Click } do
					for _, c in getconns(sig) do
						if c.Function then pcall(c.Function) end
					end
				end
			end
		end)
	end

	-- Click any visible quest claim / collect-reward button.
	local function claimQuests()
		local pg = lplr:FindFirstChild('PlayerGui')
		if not pg then return end
		for _, d in pg:GetDescendants() do
			if d:IsA('GuiButton') and d.Visible then
				local n = d.Name
				if n == 'ClaimButton' or n == 'CollectRewardButton' or n == 'RewardButton' then
					-- only if it's actually on-screen (an ancestor could be hidden)
					if d.AbsoluteSize.X > 0 then
						press(d)
					end
				end
			end
		end
	end

	-- If a dish reward-choice screen is up, pick a random dish.
	local function pickRandomDish()
		if not (PickDish and PickDish.Enabled) then return end
		local ok, panels = pcall(function() return collectionService:GetTagged('SelectRewardScreenPanel') end)
		if not ok or #panels == 0 then return end
		-- gather panels that are actually shown, then pick one at random
		local shown = {}
		for _, p in panels do
			if p.Parent and (not p:IsA('GuiObject') or p.Visible) then
				shown[#shown + 1] = p
			end
		end
		if #shown == 0 then return end
		local panel = shown[math.random(1, #shown)]
		-- Prefer the remote: fire RewardChosen with the food key from the panel name
		-- (most reliable -- no dependency on click hooks).
		local foodKey = tostring(panel.Name):match('^Reward_(.+)$')
		if foodKey and RewardChosen then
			pcall(function() RewardChosen:FireServer(foodKey) end)
			return
		end
		-- fallback: click the panel's SelectButton
		local sel = panel:FindFirstChild('SelectButton', true)
		if sel and sel:IsA('GuiButton') then press(sel) end
	end

	AutoQuest = vain.Categories.World:CreateModule({
		Name = 'Auto Quest',
		Tooltip = 'Automatically claims completed quest rewards. With "Pick Random Dish" on, it also auto-selects a random dish whenever a reward is a new-meal choice.',
		Function = function(callback)
			if callback then
				resolveQ()
				task.spawn(function()
					repeat
						pcall(claimQuests)
						pcall(pickRandomDish)
						task.wait(0.6)
					until not AutoQuest.Enabled
				end)
			end
		end,
	})
	PickDish = AutoQuest:CreateToggle({
		Name = 'Pick Random Dish',
		Tooltip = 'When a quest reward is a choice of a new dish, automatically pick one at random.',
		Default = true,
	})
end)
