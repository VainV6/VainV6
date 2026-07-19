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

	local module, Speed
	module = vain.Categories.World:CreateModule({
		Name = 'Auto Cook',
		Tooltip = 'Auto-completes every step (Hold, Click, etc.) of a dish YOU start cooking, on any station. It only runs while you are cooking -- it never starts or queues a dish.',
		Function = function(callback)
			if callback then
				if not resolve() then
					vain:CreateNotification('Auto Cook', 'Could not hook the cooking system in this place.', 6, 'warning')
					return
				end
				task.spawn(function()
					repeat
						-- Re-check Enabled right before firing (not just at loop bottom):
						-- completing the last step of a dish auto-advances the server to
						-- the next queued dish, so a stale fire after you toggle off would
						-- keep cooking the queue. Guarding here stops instantly.
						if module.Enabled then
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
						-- Floor the interval so we never fire faster than the cook UI
						-- (PlayerGui.Cooking) can render each step. Keep at least ~0.12s.
						local delay = (Speed and (1 / math.max(Speed.Value, 0.1))) or 0.12
						task.wait(math.max(delay, 0.12))
					until not module.Enabled
				end)
			end
		end,
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
-- AUTO COLLECT DISHES  -- collect finished dishes and bills (money) only
-- ============================================================================
-- Fires ONLY the CollectDishes + CollectBill interactions (by task Key), so it
-- collects dirty dishes and money but never touches the Cook/Serve prompts --
-- firing the Cook interaction is what was auto-queuing new dishes to cook.
run(function()
	makeAuto(
		'Auto Collect Dishes',
		'Automatically collects finished dishes and bills (money) from tables. Does not start cooking.',
		function()
			fireInteractionKeys({ CollectDishes = true, CollectBill = true })
		end,
		false
	)
end)

-- ============================================================================
-- AUTO SEAT CUSTOMERS  -- greet and seat waiting customers
-- ============================================================================
-- Customers are driven by their own "CustomerInteractPrompt" (one per customer).
-- Firing it performs the next action the customer needs -- greeting/seating a new
-- arrival is the first of those, so this seats waiting customers.
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
-- AUTO TAKE ORDERS  -- take seated customers' orders
-- ============================================================================
-- Same customer prompt system: once a customer is seated, firing their prompt
-- takes their order. (Seating and ordering share the per-customer prompt, so this
-- and Auto Seat both advance customers -- enable whichever stages you want.)
run(function()
	makeAuto(
		'Auto Take Orders',
		'Automatically takes seated customers\' orders.',
		function()
			fireTagged('CustomerInteractPrompt')
		end,
		false
	)
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
