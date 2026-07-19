-- Flee the Facility (2-beast variant) -- place 17600423422 (10 players).
--
-- Data model (confirmed from the place file):
--  * A player is a BEAST when player:GetAttribute("Beast") == true. Two beasts.
--  * Computers are CollectionService-tagged "Computer". The hackable computer is
--    the tagged part's Parent, with attributes: Progress (0..100, >=100 = hacked),
--    Player (who is hacking), Dummy (tutorial dummy). GetTagged("Computer") lists
--    every trigger part.
--  * Hacking: press E on a computer -> Computer:InvokeServer(part, "Start")
--    (RemoteFunction) begins it; the server then drives skill checks via the
--    Challenge RemoteEvent: Challenge.OnClientEvent("Challenge", computer, start,
--    end). You WIN a check with Challenge:FireServer(computer, "Challenge", x)
--    where x is inside [start, end]. Repeat until Progress >= 100.
--  * The escape Hatch is a CollectionService-tagged "Hatch" instance that only
--    exists/opens when one survivor is left.

local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local collectionService = cloneref(game:GetService('CollectionService'))

local lplr = playersService.LocalPlayer

local vain = shared.vain

-- ============================================================================
-- Shared helpers
-- ============================================================================

local function isBeast(plr)
	return plr and plr:GetAttribute('Beast') == true
end

local function beastPlayers()
	local list = {}
	for _, plr in playersService:GetPlayers() do
		if isBeast(plr) then
			list[#list + 1] = plr
		end
	end
	return list
end

local function myRoot()
	local char = lplr.Character
	return char and (char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart)
end

-- Resolve a world position from an instance that may be a BasePart or a Model
-- (the "Computer" tag can be on either). Returns a Vector3 or nil.
local function positionOf(inst)
	if not inst then return nil end
	if inst:IsA('BasePart') then return inst.Position end
	if inst:IsA('Model') then
		local ok, cf = pcall(function() return inst:GetPivot() end)
		if ok and cf then return cf.Position end
		local p = inst.PrimaryPart or inst:FindFirstChildWhichIsA('BasePart')
		return p and p.Position
	end
	local p = inst:FindFirstChildWhichIsA('BasePart', true)
	return p and p.Position
end

-- A BasePart to adorn a billboard/highlight to.
local function partOf(inst)
	if not inst then return nil end
	if inst:IsA('BasePart') then return inst end
	if inst:IsA('Model') then return inst.PrimaryPart or inst:FindFirstChildWhichIsA('BasePart') end
	return inst:FindFirstChildWhichIsA('BasePart', true)
end

-- Every hackable computer. The Model is tagged "Computer" (holds Progress/Player/
-- Dummy attributes); its interaction trigger is a child part tagged "Trigger",
-- which is what Computer:InvokeServer("Start") expects. Skips tutorial dummies.
-- Returns { board = model, trigger = triggerPart, part = adornPart }.
local function computers()
	local list = {}
	local ok, taggedList = pcall(function() return collectionService:GetTagged('Computer') end)
	if not ok then return list end
	for _, board in taggedList do
		if not board:GetAttribute('Dummy') then
			-- the trigger the server wants is a descendant tagged "Trigger"
			local trigger
			for _, d in board:GetDescendants() do
				if d:IsA('BasePart') and d:HasTag('Trigger') then trigger = d break end
			end
			list[#list + 1] = {
				board = board,
				trigger = trigger,
				part = trigger or partOf(board),
			}
		end
	end
	return list
end

local function isHacked(board)
	return board and (board:GetAttribute('Progress') or 0) >= 100
end

-- ============================================================================
-- BEAST ESP  -- highlight both beasts through walls
-- ============================================================================
run(function()
	local BeastESP
	local highlights = {}

	local function clear()
		for _, h in pairs(highlights) do
			pcall(function() h:Destroy() end)
		end
		table.clear(highlights)
	end

	local function ensure(char)
		local h = highlights[char]
		if not h or h.Parent ~= char then
			h = Instance.new('Highlight')
			h.Name = 'VainBeastESP'
			h.FillColor = Color3.fromRGB(255, 45, 45)
			h.OutlineColor = Color3.fromRGB(255, 200, 200)
			h.FillTransparency = 0.55
			h.OutlineTransparency = 0
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Adornee = char
			h.Parent = char
			highlights[char] = h
		end
	end

	local function tick()
		local live = {}
		for _, plr in beastPlayers() do
			if plr ~= lplr and plr.Character then
				live[plr.Character] = true
				ensure(plr.Character)
			end
		end
		for char, h in pairs(highlights) do
			if not live[char] then
				pcall(function() h:Destroy() end)
				highlights[char] = nil
			end
		end
	end

	BeastESP = vain.Categories.Render:CreateModule({
		Name = 'Beast ESP',
		Tooltip = 'Highlights both beasts through walls so you always know where they are.',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						pcall(tick)
						task.wait(0.3)
					until not BeastESP.Enabled
					clear()
				end)
			else
				clear()
			end
		end,
	})
end)

-- ============================================================================
-- COMPUTER ESP  -- render every computer (billboard + optional highlight)
-- ============================================================================
run(function()
	local ComputerESP
	local ShowFinished, Highlights, GreenHacked
	local gui
	local marks = {}   -- board -> { bb, label, hl }

	local BLUE = Color3.fromRGB(120, 210, 255)
	local GREEN = Color3.fromRGB(90, 235, 120)

	local function ensureGui()
		if gui and gui.Parent then return gui end
		gui = Instance.new('ScreenGui')
		gui.Name = 'VainComputerESP'
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.Parent = gethui and gethui() or lplr:WaitForChild('PlayerGui')
		return gui
	end

	local function clear()
		for _, e in pairs(marks) do
			pcall(function() if e.bb then e.bb:Destroy() end end)
			pcall(function() if e.hl then e.hl:Destroy() end end)
		end
		table.clear(marks)
		if gui then gui:Destroy() gui = nil end
	end

	local function tick()
		local live = {}
		for _, c in computers() do
			local board, part = c.board, c.part
			local hacked = isHacked(board)
			if not part then
				-- no adornable part; skip
			elseif hacked and not (ShowFinished and ShowFinished.Enabled) then
				-- hidden
			else
				live[board] = true
				local col = hacked and (GreenHacked and GreenHacked.Enabled and GREEN or BLUE) or BLUE
				local e = marks[board]
				if not e or not e.bb or not e.bb.Parent then
					e = {}
					local bb = Instance.new('BillboardGui')
					bb.Adornee = part
					bb.Size = UDim2.fromOffset(96, 22)
					bb.StudsOffset = Vector3.new(0, 2.5, 0)
					bb.AlwaysOnTop = true
					bb.MaxDistance = 1200
					bb.Parent = ensureGui()
					local label = Instance.new('TextLabel')
					label.Size = UDim2.fromScale(1, 1)
					label.BackgroundTransparency = 1
					label.Font = Enum.Font.GothamBold
					label.TextSize = 14
					label.TextStrokeTransparency = 0.4
					label.Parent = bb
					e.bb, e.label = bb, label
					marks[board] = e
				end
				local prog = math.floor(board:GetAttribute('Progress') or 0)
				local mp = myRoot()
				local dist = mp and math.floor((part.Position - mp.Position).Magnitude)
				e.label.Text = (hacked and 'Computer ✓' or ('Computer ' .. prog .. '%'))
					.. (dist and (' [' .. dist .. ']') or '')
				e.label.TextColor3 = col

				if Highlights and Highlights.Enabled then
					if not e.hl or e.hl.Parent ~= board then
						local hl = Instance.new('Highlight')
						hl.Name = 'VainCompHL'
						hl.FillTransparency = 0.7
						hl.OutlineTransparency = 0.2
						hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
						hl.Adornee = board
						hl.Parent = board
						e.hl = hl
					end
					e.hl.FillColor = col
					e.hl.OutlineColor = col
				elseif e.hl then
					pcall(function() e.hl:Destroy() end)
					e.hl = nil
				end
			end
		end
		for board, e in pairs(marks) do
			if not live[board] then
				pcall(function() if e.bb then e.bb:Destroy() end end)
				pcall(function() if e.hl then e.hl:Destroy() end end)
				marks[board] = nil
			end
		end
	end

	ComputerESP = vain.Categories.Render:CreateModule({
		Name = 'Computer ESP',
		Tooltip = 'Renders every computer with its hack progress and distance, so you can find hacks fast.',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						pcall(tick)
						task.wait(0.4)
					until not ComputerESP.Enabled
					clear()
				end)
			else
				clear()
			end
		end,
	})
	ShowFinished = ComputerESP:CreateToggle({
		Name = 'Show Finished',
		Tooltip = 'Also show computers that are already hacked (marked ✓).',
		Default = true,
	})
	GreenHacked = ComputerESP:CreateToggle({
		Name = 'Green When Hacked',
		Tooltip = 'Colour already-hacked computers green instead of blue.',
		Default = true,
	})
	Highlights = ComputerESP:CreateToggle({
		Name = 'Highlight',
		Tooltip = 'Add a through-wall highlight to each computer as well as the label.',
		Default = true,
	})
end)

-- ============================================================================
-- HATCH ESP  -- highlight the escape hatch once it opens (1 survivor left)
-- ============================================================================
run(function()
	local HatchESP
	local gui
	local marks = {}

	local function hatchInstances()
		local ok, list = pcall(function() return collectionService:GetTagged('Hatch') end)
		return ok and list or {}
	end

	local function ensureGui()
		if gui and gui.Parent then return gui end
		gui = Instance.new('ScreenGui')
		gui.Name = 'VainHatchESP'
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.Parent = gethui and gethui() or lplr:WaitForChild('PlayerGui')
		return gui
	end

	local function clear()
		for _, e in pairs(marks) do
			pcall(function() if e.bb then e.bb:Destroy() end end)
			pcall(function() if e.hl then e.hl:Destroy() end end)
		end
		table.clear(marks)
		if gui then gui:Destroy() gui = nil end
	end

	local function partOf(inst)
		if inst:IsA('BasePart') then return inst end
		if inst:IsA('Model') then return inst.PrimaryPart or inst:FindFirstChildWhichIsA('BasePart') end
		return inst:FindFirstChildWhichIsA('BasePart', true)
	end

	local function tick()
		local live = {}
		for _, hatch in hatchInstances() do
			-- ignore a closed hatch (the game sets Closed on the parent)
			local closed = (hatch:IsA('Model') and hatch:GetAttribute('Closed'))
				or (hatch.Parent and hatch.Parent:GetAttribute('Closed'))
			local part = partOf(hatch)
			if part and not closed then
				live[hatch] = true
				local e = marks[hatch]
				if not e or not e.bb or not e.bb.Parent then
					e = {}
					local hl = Instance.new('Highlight')
					hl.Name = 'VainHatchHL'
					hl.FillColor = Color3.fromRGB(255, 215, 60)
					hl.OutlineColor = Color3.fromRGB(255, 245, 200)
					hl.FillTransparency = 0.4
					hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					hl.Adornee = hatch
					hl.Parent = hatch:IsA('Model') and hatch or part
					local bb = Instance.new('BillboardGui')
					bb.Adornee = part
					bb.Size = UDim2.fromOffset(90, 22)
					bb.StudsOffset = Vector3.new(0, 3, 0)
					bb.AlwaysOnTop = true
					bb.MaxDistance = 2000
					bb.Parent = ensureGui()
					local label = Instance.new('TextLabel')
					label.Size = UDim2.fromScale(1, 1)
					label.BackgroundTransparency = 1
					label.Font = Enum.Font.GothamBold
					label.TextSize = 15
					label.TextColor3 = Color3.fromRGB(255, 215, 60)
					label.TextStrokeTransparency = 0.4
					label.Parent = bb
					e.hl, e.bb, e.label = hl, bb, label
					marks[hatch] = e
				end
				local mp = myRoot()
				local dist = mp and math.floor((part.Position - mp.Position).Magnitude)
				e.label.Text = 'HATCH' .. (dist and (' [' .. dist .. ']') or '')
			end
		end
		for hatch, e in pairs(marks) do
			if not live[hatch] then
				pcall(function() if e.bb then e.bb:Destroy() end end)
				pcall(function() if e.hl then e.hl:Destroy() end end)
				marks[hatch] = nil
			end
		end
	end

	HatchESP = vain.Categories.Render:CreateModule({
		Name = 'Hatch ESP',
		Tooltip = 'Highlights the escape hatch (with distance) the moment it opens -- i.e. when one survivor is left.',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						pcall(tick)
						task.wait(0.3)
					until not HatchESP.Enabled
					clear()
				end)
			else
				clear()
			end
		end,
	})
end)

-- ============================================================================
-- BEAST NO SLOWDOWN  -- keep your speed up after swinging (when you're the beast)
-- ============================================================================
-- After a beast action the game (a LocalScript) pins LocalPlayer.Character.
-- Humanoid.WalkSpeed to 4 for ~1s ("back to normal speed"). Because that's your
-- OWN character, we can hold it back up. (Slowing OTHER players is not possible
-- client-side -- the server owns their characters -- so there's no "Slow Beast".)
run(function()
	local NoSlowdown
	local Speed

	local function tick()
		if not isBeast(lplr) then return end
		local char = lplr.Character
		local hum = char and char:FindFirstChildOfClass('Humanoid')
		if not hum then return end
		-- respect intentional freezes (Phaser sets WalkSpeed 0); only lift the
		-- post-swing slow (the low ~4 value).
		local target = (Speed and Speed.Value) or 16
		if hum.WalkSpeed < target and not lplr:GetAttribute('PhaserPause') then
			hum.WalkSpeed = target
		end
	end

	NoSlowdown = vain.Categories.Blatant:CreateModule({
		Name = 'Beast No Slowdown',
		Tooltip = 'When you are the beast, removes the ~1s walk-speed slow after each swing/action so you keep full speed.',
		Function = function(callback)
			if callback then
				NoSlowdown:Clean(runService.Heartbeat:Connect(tick))
			end
		end,
	})
	Speed = NoSlowdown:CreateSlider({
		Name = 'Hold Speed',
		Tooltip = 'Walk speed to hold when the game tries to slow you.',
		Min = 8,
		Max = 30,
		Default = 16,
		Suffix = function(val) return 'studs/s' end,
	})
end)

-- ============================================================================
-- AUTOHACK  -- press E for you when the marker hits the white zone
-- ============================================================================
-- You start a hack normally. The skill check shows a MARKER (rod line) that slides
-- across a bar; the white target band is the "Space" frame. The game fires
-- Challenge:FireServer(computer, "Challenge", Marker.Position.X.Scale) on press, so
-- the answer is the marker's LIVE position at the moment you fire. Rather than
-- fabricate a value, we watch the marker and fire the instant it's actually inside
-- the white band -- exactly like pressing E at the right time (just frame-perfect).
run(function()
	local AutoHack
	local Safety
	local Challenge = replicatedStorage:FindFirstChild('Challenge')   -- RemoteEvent

	local function challengeGui()
		local pg = lplr:FindFirstChild('PlayerGui')
		local cc = pg and pg:FindFirstChild('ComputerChallenge')
		local frame = cc and cc:FindFirstChild('Frame')
		return cc, frame
	end

	-- The white band [start, end] in X-scale, from the Space frame.
	local function whiteBand(frame)
		local space = frame and frame:FindFirstChild('Space')
		if not space then return nil end
		local s = space.Position.X.Scale
		return s, s + space.Size.X.Scale
	end

	local function markerX(frame)
		local marker = frame and frame:FindFirstChild('Marker')
		return marker and marker.Position.X.Scale
	end

	-- Wait for the sliding marker to enter the white band, then fire its real
	-- position. `kind` is "Challenge" (single) -- returns once fired or timed out.
	local function pressWhenInZone(computer, startArg, endArg)
		local t0 = tick()
		while AutoHack.Enabled and tick() - t0 < 3 do
			local cc, frame = challengeGui()
			if not (cc and cc.Enabled and frame) then
				-- GUI gone (finished/left) -> stop
				if tick() - t0 > 0.2 then return end
			else
				local lo, hi = whiteBand(frame)
				if not lo and type(startArg) == 'number' then lo, hi = startArg, endArg end
				local x = markerX(frame)
				if lo and hi and x then
					-- shrink the band slightly by the Safety margin so we fire safely
					-- inside it (not right on the edge).
					local margin = (hi - lo) * (Safety and Safety.Value or 0) / 100
					if x >= lo + margin and x <= hi - margin then
						pcall(function() Challenge:FireServer(computer, 'Challenge', x) end)
						return
					end
				end
			end
			runService.Heartbeat:Wait()
		end
	end

	AutoHack = vain.Categories.World:CreateModule({
		Name = 'Autohack',
		Tooltip = 'Presses E for you at the right moment: it fires the skill check the instant the moving marker enters the white band, so every hack lands without instant-answering.',
		Function = function(callback)
			if callback then
				Challenge = replicatedStorage:FindFirstChild('Challenge') or Challenge
				if not Challenge then
					vain:CreateNotification('Autohack', 'Challenge remote not found here.', 6, 'warning')
					return
				end
				AutoHack:Clean(Challenge.OnClientEvent:Connect(function(kind, computer, startArg, endArg)
					if not AutoHack.Enabled or not computer then return end
					if kind == 'Challenge' then
						task.spawn(function() pressWhenInZone(computer, startArg, endArg) end)
					elseif kind == 'ContinuousChallenge' then
						-- continuous: keep the marker's live position fed while it's in band
						task.spawn(function()
							local t0 = tick()
							while AutoHack.Enabled and tick() - t0 < 12 do
								local cc, frame = challengeGui()
								if not (cc and cc.Enabled and frame) then return end
								local lo, hi = whiteBand(frame)
								local x = markerX(frame)
								if lo and hi and x and x >= lo and x <= hi then
									pcall(function() Challenge:FireServer(computer, 'ContinuousChallenge', x) end)
								end
								runService.Heartbeat:Wait()
							end
						end)
					end
				end))
			end
		end,
	})
	Safety = AutoHack:CreateSlider({
		Name = 'Safety Margin',
		Tooltip = 'How far inside the white band to aim (% of band width). Higher = safer, waits for the marker to be more centred.',
		Min = 0,
		Max = 45,
		Default = 20,
		Suffix = function(val) return '%' end,
	})
end)
