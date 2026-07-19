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
						local delay = (Speed and (1 / math.max(Speed.Value, 0.1))) or 0.1
						task.wait(delay)
					until not module.Enabled
				end)
			end
		end,
	})
	Speed = module:CreateSlider({
		Name = 'Speed',
		Tooltip = 'How many steps per second to complete (higher = faster cooking).',
		Min = 1,
		Max = 30,
		Default = 15,
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
