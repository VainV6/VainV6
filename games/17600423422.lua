-- Flee the Facility (2-beast variant) -- place 17600423422 (10 players).
--
-- Data model (confirmed from the place file):
--  * A player is a BEAST when player:GetAttribute("Beast") == true. This round has
--    TWO beasts. Survivors and beasts are standard Humanoid characters.
--  * Computers are Models named "ComputerTable" placed around the map. A finished
--    one gets a "ComputerFinishedHighlight" in the hacker's character.
--  * Hacking is a skill check driven by ReplicatedStorage.Challenge (RemoteEvent):
--    server -> client Challenge.OnClientEvent("Challenge", computer, spaceStart,
--    spaceEnd); the client shows PlayerGui.ComputerChallenge.Frame with a "Space"
--    target zone (Position.X.Scale = start, Size.X.Scale = width) and a "Marker"
--    that slides 0->1 over 2s. You WIN by firing
--    Challenge:FireServer(computer, "Challenge", markerX) with markerX inside the
--    zone. Autohack simply fires with the CENTRE of the zone -> perfect every time.

local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local collectionService = cloneref(game:GetService('CollectionService'))

local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer

local vain = shared.vain

-- ============================================================================
-- Shared helpers
-- ============================================================================

-- A player is a beast when their "Beast" attribute is true.
local function isBeast(plr)
	return plr and plr:GetAttribute('Beast') == true
end

-- Every beast player (there are two).
local function beastPlayers()
	local list = {}
	for _, plr in playersService:GetPlayers() do
		if isBeast(plr) then
			list[#list + 1] = plr
		end
	end
	return list
end

local function charParts(plr)
	local char = plr and plr.Character
	if not char then return nil, nil end
	return char, char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart
end

-- Every hackable computer in the map (Models named "ComputerTable").
local function computers()
	local list = {}
	for _, m in workspace:GetDescendants() do
		if m:IsA('Model') and m.Name == 'ComputerTable' then
			list[#list + 1] = m
		end
	end
	return list
end

-- ============================================================================
-- SLOW BEAST  -- pin every beast's WalkSpeed down (both beasts)
-- ============================================================================
run(function()
	local SlowBeast
	local Speed

	local function apply()
		for _, plr in beastPlayers() do
			if plr ~= lplr then
				local char = plr.Character
				local hum = char and char:FindFirstChildOfClass('Humanoid')
				if hum then
					hum.WalkSpeed = (Speed and Speed.Value) or 4
				end
			end
		end
	end

	SlowBeast = vain.Categories.Blatant:CreateModule({
		Name = 'Slow Beast',
		Tooltip = 'Forces every beast\'s walk speed down on your client (this version has two beasts).',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						pcall(apply)
						runService.Heartbeat:Wait()
					until not SlowBeast.Enabled
				end)
			end
		end,
	})
	Speed = SlowBeast:CreateSlider({
		Name = 'Beast Speed',
		Tooltip = 'Walk speed to force on the beasts (lower = slower).',
		Min = 0,
		Max = 16,
		Default = 4,
		Suffix = function(val) return 'studs/s' end,
	})
end)

-- ============================================================================
-- BEAST ESP  -- highlight both beasts through walls
-- ============================================================================
run(function()
	local BeastESP
	local Tracers
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
		return h
	end

	local function tick()
		local live = {}
		for _, plr in beastPlayers() do
			if plr ~= lplr and plr.Character then
				live[plr.Character] = true
				ensure(plr.Character)
			end
		end
		-- drop highlights for anyone no longer a beast / gone
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
	local ShowFinished, Highlights
	local gui
	local marks = {}   -- computer model -> { billboard, highlight }

	local function isFinished(m)
		-- a finished computer usually shows a green finished highlight / attribute
		return m:GetAttribute('Finished') == true
			or m:FindFirstChild('ComputerFinishedHighlight', true) ~= nil
	end

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
		for _, entry in pairs(marks) do
			pcall(function() if entry.bb then entry.bb:Destroy() end end)
			pcall(function() if entry.hl then entry.hl:Destroy() end end)
		end
		table.clear(marks)
		if gui then gui:Destroy() gui = nil end
	end

	local function markFor(m)
		local entry = marks[m]
		if entry and entry.bb and entry.bb.Parent then return entry end
		entry = entry or {}
		local part = m.PrimaryPart or m:FindFirstChildWhichIsA('BasePart')
		if not part then return end

		local bb = Instance.new('BillboardGui')
		bb.Name = 'VainComp'
		bb.Adornee = part
		bb.Size = UDim2.fromOffset(90, 22)
		bb.StudsOffset = Vector3.new(0, 2.5, 0)
		bb.AlwaysOnTop = true
		bb.MaxDistance = 1000
		bb.Parent = ensureGui()
		local label = Instance.new('TextLabel')
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 14
		label.TextStrokeTransparency = 0.4
		label.Parent = bb
		entry.bb = bb
		entry.label = label
		marks[m] = entry
		return entry
	end

	local function tick()
		local live = {}
		for _, m in computers() do
			local finished = isFinished(m)
			if finished and not (ShowFinished and ShowFinished.Enabled) then
				-- hide finished computers
			else
				live[m] = true
				local entry = markFor(m)
				if entry then
					local part = m.PrimaryPart or m:FindFirstChildWhichIsA('BasePart')
					local dist = part and lplr.Character and lplr.Character.PrimaryPart
						and math.floor((part.Position - lplr.Character.PrimaryPart.Position).Magnitude)
					entry.label.Text = (finished and 'Computer ✓' or 'Computer')
						.. (dist and (' [' .. dist .. ']') or '')
					entry.label.TextColor3 = finished and Color3.fromRGB(90, 235, 120)
						or Color3.fromRGB(120, 210, 255)
					-- optional through-wall highlight
					if Highlights and Highlights.Enabled then
						if not entry.hl or entry.hl.Parent ~= m then
							local hl = Instance.new('Highlight')
							hl.Name = 'VainCompHL'
							hl.FillTransparency = 0.7
							hl.OutlineTransparency = 0.2
							hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
							hl.Adornee = m
							hl.Parent = m
							entry.hl = hl
						end
						entry.hl.FillColor = finished and Color3.fromRGB(90, 235, 120)
							or Color3.fromRGB(120, 210, 255)
					elseif entry.hl then
						pcall(function() entry.hl:Destroy() end)
						entry.hl = nil
					end
				end
			end
		end
		-- drop marks for computers gone / now-hidden
		for m, entry in pairs(marks) do
			if not live[m] then
				pcall(function() if entry.bb then entry.bb:Destroy() end end)
				pcall(function() if entry.hl then entry.hl:Destroy() end end)
				marks[m] = nil
			end
		end
	end

	ComputerESP = vain.Categories.Render:CreateModule({
		Name = 'Computer ESP',
		Tooltip = 'Renders every computer in the map with a label (and distance), so you can find hacks fast.',
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
		Default = false,
	})
	Highlights = ComputerESP:CreateToggle({
		Name = 'Highlight',
		Tooltip = 'Add a through-wall highlight to each computer as well as the label.',
		Default = true,
	})
end)

-- ============================================================================
-- AUTOHACK  -- auto-complete the computer skill checks
-- ============================================================================
-- The server starts a challenge via Challenge.OnClientEvent("Challenge", computer,
-- spaceStart, spaceEnd). The win is Challenge:FireServer(computer, "Challenge",
-- markerX) with markerX inside [spaceStart, spaceEnd]. We answer with the CENTRE of
-- the zone the instant the challenge starts -> a perfect hack with no timing.
run(function()
	local AutoHack
	local Instant

	local Challenge = replicatedStorage:FindFirstChild('Challenge')

	-- Read the live target zone from the challenge GUI (set by StartChallenge).
	local function zoneCentre()
		local pg = lplr:FindFirstChild('PlayerGui')
		local cc = pg and pg:FindFirstChild('ComputerChallenge')
		local frame = cc and cc:FindFirstChild('Frame')
		local space = frame and frame:FindFirstChild('Space')
		if not space then return nil end
		local start = space.Position.X.Scale
		local width = space.Size.X.Scale
		return start + width / 2
	end

	local function solve(computer)
		if not Challenge then return end
		-- Prefer the zone centre from the GUI; fall back to 0.5 if not ready.
		local centre
		for _ = 1, 30 do
			centre = zoneCentre()
			if centre then break end
			runService.Heartbeat:Wait()
		end
		centre = centre or 0.5
		pcall(function()
			Challenge:FireServer(computer, 'Challenge', centre)
		end)
		-- close the challenge UI locally so it doesn't linger
		local pg = lplr:FindFirstChild('PlayerGui')
		local cc = pg and pg:FindFirstChild('ComputerChallenge')
		if cc then cc.Enabled = false end
	end

	AutoHack = vain.Categories.World:CreateModule({
		Name = 'Autohack',
		Tooltip = 'Automatically completes computer skill checks perfectly. Walk into a computer\'s trigger and it hacks itself.',
		Function = function(callback)
			if callback then
				Challenge = replicatedStorage:FindFirstChild('Challenge') or Challenge
				if Challenge then
					AutoHack:Clean(Challenge.OnClientEvent:Connect(function(kind, computer)
						if not AutoHack.Enabled then return end
						if kind == 'Challenge' and computer then
							-- single-press skill check: answer with the zone centre
							task.spawn(function() solve(computer) end)
						elseif kind == 'ContinuousChallenge' and computer then
							-- continuous check: keep feeding the zone centre until it ends
							task.spawn(function()
								local pg = lplr:FindFirstChild('PlayerGui')
								local cc = pg and pg:FindFirstChild('ComputerChallenge')
								local t0 = tick()
								while AutoHack.Enabled and cc and cc.Enabled and tick() - t0 < 10 do
									local centre = zoneCentre() or 0.5
									pcall(function() Challenge:FireServer(computer, 'ContinuousChallenge', centre) end)
									runService.Heartbeat:Wait()
								end
							end)
						end
					end))
				else
					vain:CreateNotification('Autohack', 'Challenge remote not found in this place.', 6, 'warning')
				end
			end
		end,
	})
	Instant = AutoHack:CreateToggle({
		Name = 'Instant',
		Tooltip = 'Answer the moment the skill check starts (leave on).',
		Default = true,
	})
end)
