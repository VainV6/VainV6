-- Restaurant Tycoon -- place 119048529960596.
--
-- Data model (confirmed from the place file):
--  * Every restaurant TASK (cook, serve, collect dishes, greet/seat customers,
--    take orders, collect bill) is a ProximityPrompt tagged "Interaction",
--    created by the Interactions module. The prompt's .ActionText is the task
--    label ("Cook", "Collect Dishes", "Greet Customers", "Serve Food", ...).
--  * Triggering a prompt -> Interactions:Interact -> fires the RemoteEvent
--    Interacted:FireServer(...) with a 0.5s client debounce between interactions.
--  * So automating anything = find the "Interaction"-tagged prompts, filter by
--    ActionText, and fire them (fireproximityprompt) on a loop. The speed slider
--    controls the loop interval (the ~0.5s server debounce is the real floor, but
--    firing faster still helps when several distinct prompts exist).

local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local runService = cloneref(game:GetService('RunService'))
local collectionService = cloneref(game:GetService('CollectionService'))

local vain = shared.vain

-- fireproximityprompt exists under several executor names; resolve once.
local fireprompt = fireproximityprompt
	or (getgenv and getgenv().fireproximityprompt)

-- ============================================================================
-- Shared: fire every interaction prompt matching one of the given ActionTexts.
-- ============================================================================
-- `wants` is a set of lowercased ActionText substrings to match. Returns the
-- number of prompts fired this pass.
local function fireInteractions(wants)
	if not fireprompt then return 0 end
	local fired = 0
	local ok, prompts = pcall(function() return collectionService:GetTagged('Interaction') end)
	if not ok then return 0 end
	for _, p in prompts do
		if p:IsA('ProximityPrompt') and p.Enabled then
			local text = string.lower(p.ActionText or '')
			local match = false
			for key in pairs(wants) do
				if text:find(key, 1, true) then match = true break end
			end
			if match then
				pcall(function() fireprompt(p, p.HoldDuration or 0) end)
				fired = fired + 1
			end
		end
	end
	return fired
end

-- Build a "wants" set from a list of substrings.
local function wantSet(...)
	local t = {}
	for _, s in { ... } do t[string.lower(s)] = true end
	return t
end

-- Standard toggle-module builder for a "fire these interactions on a loop" auto.
local function makeAuto(name, tooltip, wants, withSpeed)
	local module, Speed
	module = vain.Categories.World:CreateModule({
		Name = name,
		Tooltip = tooltip .. (fireprompt and '' or ' (needs a fireproximityprompt-capable executor)'),
		Function = function(callback)
			if callback then
				if not fireprompt then
					vain:CreateNotification(name, 'Your executor has no fireproximityprompt -- cannot auto-fire prompts.', 7, 'warning')
					return
				end
				task.spawn(function()
					repeat
						pcall(fireInteractions, wants)
						local delay = withSpeed and Speed and (1 / math.max(Speed.Value, 0.1)) or 0.4
						task.wait(delay)
					until not module.Enabled
				end)
			end
		end,
	})
	if withSpeed then
		Speed = module:CreateSlider({
			Name = 'Speed',
			Tooltip = 'How many times per second to fire (higher = faster). The server still debounces at ~0.5s, so very high values mostly help when multiple stations are active.',
			Min = 1,
			Max = 20,
			Default = 8,
			Suffix = function(val) return '/s' end,
		})
	end
	return module
end

-- ============================================================================
-- AUTO COOK  -- automatically complete cooking prompts (with speed slider)
-- ============================================================================
run(function()
	makeAuto(
		'Auto Cook',
		'Automatically completes cooking tasks for you (fires the Cook / Make Drinks prompts).',
		wantSet('cook', 'make drinks'),
		true   -- speed slider
	)
end)

-- ============================================================================
-- AUTO COLLECT DISHES  -- automatically collect finished dishes
-- ============================================================================
run(function()
	makeAuto(
		'Auto Collect Dishes',
		'Automatically collects dishes from tables (fires the Collect Dishes prompts).',
		wantSet('collect dishes'),
		false
	)
end)

-- ============================================================================
-- AUTO SEAT CUSTOMERS  -- automatically greet/seat waiting customers
-- ============================================================================
run(function()
	makeAuto(
		'Auto Seat Customers',
		'Automatically greets and seats waiting customers (fires the Greet Customers prompts).',
		wantSet('greet customers', 'seat'),
		false
	)
end)
