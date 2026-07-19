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
						pcall(function()
							if Cook.IsCooking then
								local kitchen = Cook.CurrentKitchenModel or (Cook.GetCurrentKitchenModel and Cook:GetCurrentKitchenModel())
								local item = Cook.CurrentItemType
								if kitchen ~= nil and item ~= nil then
									CookInputRequested:FireServer(COMPLETE, kitchen, item)
								end
							end
						end)
						-- Floor the interval so we never fire faster than the cook UI
						-- (PlayerGui.Cooking) can render each step -- spamming completed
						-- the whole dish before the bar could show, so it looked
						-- suppressed. Keep at least ~0.12s between fires.
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
-- AUTO COLLECT DISHES  -- collect finished dishes from tables
-- ============================================================================
-- CollectDishes is an "Interaction"-tagged prompt. We fire the Interaction prompts;
-- one with nothing to collect is a no-op, so this cleanly collects whatever's ready.
run(function()
	makeAuto(
		'Auto Collect Dishes',
		'Automatically collects finished dishes from tables.',
		function()
			fireTagged('Interaction')
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
run(function()
	local AutoBoost
	local FoodUtility, FocusedTycoon
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
		if FocusedTycoon == nil then
			pcall(function() FocusedTycoon = require(lplr.PlayerScripts.Source.Systems.FocusedTycoon) end)
		end
		return PurchaseIngredient and BoostRequested and FoodUtility
	end

	-- Resolve the tycoon reference the remotes expect (the focused/owned tycoon).
	local function getTycoon()
		local t
		pcall(function()
			if FocusedTycoon then
				t = (FocusedTycoon.Get and FocusedTycoon:Get())
					or (FocusedTycoon.GetDefaultTycoon and FocusedTycoon:GetDefaultTycoon())
					or FocusedTycoon.Tycoon
			end
		end)
		return t
	end

	-- { foodKey = true } for dishes already boosted, via the food menu system.
	local function boostedDict()
		local dict = {}
		pcall(function()
			local FoodMenu = require(lplr.PlayerScripts.Source.Systems.FoodMenu)
			if FoodMenu and FoodMenu.GetBoostedFoodDictionary then
				dict = FoodMenu:GetBoostedFoodDictionary() or {}
			end
		end)
		return dict
	end

	-- { ingredient = count } you currently own.
	local function ownership()
		local own = {}
		pcall(function()
			local FoodMenu = require(lplr.PlayerScripts.Source.Systems.FoodMenu)
			if FoodMenu and FoodMenu.GetIngredientOwnership then
				own = FoodMenu:GetIngredientOwnership() or {}
			end
		end)
		return own
	end

	-- All dish food keys on your menu.
	local function menuDishes()
		local keys = {}
		pcall(function()
			local FoodMenu = require(lplr.PlayerScripts.Source.Systems.FoodMenu)
			local menu = FoodMenu and FoodMenu.GetMenu and FoodMenu:GetMenu()
			if type(menu) == 'table' then
				for k in pairs(menu) do keys[#keys + 1] = k end
			end
		end)
		return keys
	end

	local function boostAll()
		local tycoon = getTycoon()
		if not tycoon then return end
		local boosted = boostedDict()
		local own = ownership()
		for _, foodKey in menuDishes() do
			if not boosted[foodKey] and AutoBoost.Enabled then
				-- required ingredients for this dish
				local need = {}
				pcall(function() need = FoodUtility:GetIngredients(foodKey) or {} end)
				-- buy any we're short on
				for ing, qty in pairs(need) do
					local have = tonumber(own[ing]) or 0
					local short = (tonumber(qty) or 0) - have
					if short > 0 then
						pcall(function() PurchaseIngredient:FireServer(tycoon, ing, short) end)
						own[ing] = have + short   -- assume the buy succeeds this pass
						task.wait(0.15)
					end
				end
				-- boost the dish
				pcall(function() BoostRequested:FireServer(tycoon, foodKey) end)
				boosted[foodKey] = true
				task.wait(0.25)
			end
		end
	end

	AutoBoost = vain.Categories.World:CreateModule({
		Name = 'Auto Boost Dishes',
		Tooltip = 'Buys the ingredients each unboosted dish needs (from the plaza shops) and boosts it. Skips dishes that are already boosted, so it never over-buys.',
		Function = function(callback)
			if callback then
				if not resolve() then
					vain:CreateNotification('Auto Boost', 'Boost/ingredient system not found here.', 6, 'warning')
					return
				end
				task.spawn(function()
					repeat
						pcall(boostAll)
						task.wait(3)   -- re-scan for newly-added / still-unboosted dishes
					until not AutoBoost.Enabled
				end)
			end
		end,
	})
end)
