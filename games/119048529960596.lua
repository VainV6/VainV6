-- Restaurant Tycoon -- place 119048529960596.
--
-- Data model (confirmed from the place file):
--  * There are TWO prompt systems:
--    1) "Interaction"-tagged ProximityPrompts (Interactions module) drive the
--       kitchen/table tasks: Cook, Serve, CollectDishes, CollectBill. Triggering
--       one fires Interacted:FireServer(...); the handlers route by the
--       interaction's Key. Cooking also creates "Cook_*"-named prompts.
--    2) "CustomerInteractPrompt"-tagged prompts (one per customer, parented to the
--       customer's HumanoidRootPart) drive the CUSTOMER lifecycle: greet/seat,
--       take order, serve to table, collect bill. Firing a customer's prompt
--       performs whatever action their current state needs.
--  * Firing a prompt with nothing actionable is a harmless no-op, and there is a
--    ~0.5s server debounce on restaurant interactions.
--  * So: automate by firing the relevant prompts on a loop (fireproximityprompt).

local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local collectionService = cloneref(game:GetService('CollectionService'))

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

-- Also fire any workspace ProximityPrompt whose Name starts with a prefix (used
-- for the "Cook_*" cooking prompts that aren't Interaction-tagged).
local function fireNamed(prefixes)
	if not fireprompt then return 0 end
	local fired = 0
	for _, p in workspace:GetDescendants() do
		if p:IsA('ProximityPrompt') and p.Enabled then
			local n = p.Name or ''
			for _, pre in prefixes do
				if n:sub(1, #pre) == pre then
					pcall(function() fireprompt(p, p.HoldDuration or 0) end)
					fired = fired + 1
					break
				end
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
-- AUTO COOK  -- complete the actual cooking steps (ovens, fryers, everything)
-- ============================================================================
-- The real cooking minigame steps are "Cook_*"-named prompts (CookingPrompts) --
-- firing these completes the current dish on every station type (ovens, fryers,
-- grills, drinks). We deliberately do NOT fire the "Interaction"-tagged prompts:
-- the "Cook"-Key interaction prompt is what STARTS/queues a new dish, which is the
-- order-queuing behaviour we must avoid. Cook_* only advances what's already
-- cooking, so this never queues orders.
run(function()
	makeAuto(
		'Auto Cook',
		'Automatically completes the cooking steps for dishes already being cooked (ovens, fryers, grills, drinks). Does not queue new orders.',
		function()
			fireNamed({ 'Cook_' })
		end,
		true   -- speed slider
	)
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
