--!nocheck
local cloneref = cloneref or function(ref) return ref end
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local delfile = delfile or function(file)
	writefile(file, '')
end

-- ── Vain loading screen ──────────────────────────────────────────────────────
-- A full animated loading screen (the "V" logo, glow rings, wordmark, progress
-- bar) shown ONLY while Vain is actually downloading files (a fresh install or an
-- update). The status text ("Downloading vain/assets/...") sits UNDER the bar.
-- It's lazily built on the first download so a fully-cached inject shows nothing.
-- Exposed via getgenv().vainLoading so main.lua (which does its own downloads and
-- the final finishLoading) can drive the bar and dismiss it -> then show What's New.
local vainLoading
do
	local TweenService = cloneref(game:GetService('TweenService'))
	local RunService   = cloneref(game:GetService('RunService'))
	local built, screenGui, root, statusLabel, gradient, setRingProgress
	local progressTarget, progressShown = 0, 0
	local finished = false

	local function tween(inst, time, props, style, dir)
		local t = TweenService:Create(inst,
			TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
		t:Play()
		return t
	end

	local function build()
		if built then return end
		built = true
		local guiParent
		pcall(function() if gethui then guiParent = gethui() end end)
		if not guiParent then pcall(function() guiParent = cloneref(game:GetService('CoreGui')) end) end
		screenGui = Instance.new('ScreenGui')
		screenGui.Name = 'VainLoadingScreen'
		screenGui.IgnoreGuiInset = true
		screenGui.DisplayOrder = 2147483647
		screenGui.ResetOnSpawn = false
		screenGui.Parent = guiParent

		-- Plain Frame root (NOT a CanvasGroup -- that renders to a downscaled texture
		-- which made everything look small/soft). We fade elements individually.
		root = Instance.new('Frame')
		root.Name = 'Root'
		root.Size = UDim2.fromScale(1, 1)
		root.BackgroundTransparency = 1
		root.Parent = screenGui
		local bg = Instance.new('Frame')
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundColor3 = Color3.fromRGB(8, 8, 10)
		bg.BackgroundTransparency = 0.35 -- semi-transparent dark tint over the game
		bg.BorderSizePixel = 0
		bg.Parent = root

		-- (V removed) -- centred VAIN wordmark + circular progress ring + status.
		-- soft glow copy of the wordmark BEHIND it (blurred look via a faint, slightly
		-- larger duplicate) so the text reads as if it's glowing.
		local wordmarkGlow = Instance.new('TextLabel')
		wordmarkGlow.AnchorPoint = Vector2.new(0.5, 0.5)
		wordmarkGlow.Position = UDim2.new(0.5, 0, 0.5, -60)
		wordmarkGlow.Size = UDim2.fromOffset(600, 110)
		wordmarkGlow.BackgroundTransparency = 1
		wordmarkGlow.Font = Enum.Font.GothamBold
		wordmarkGlow.Text = 'VAIN'
		wordmarkGlow.TextSize = 96
		wordmarkGlow.TextTransparency = 1
		wordmarkGlow.TextColor3 = Color3.fromRGB(255, 106, 31)
		wordmarkGlow.TextStrokeColor3 = Color3.fromRGB(255, 130, 40)
		wordmarkGlow.TextStrokeTransparency = 1
		wordmarkGlow.ZIndex = 2
		wordmarkGlow.Parent = root

		local wordmark = Instance.new('TextLabel')
		wordmark.AnchorPoint = Vector2.new(0.5, 0.5)
		wordmark.Position = UDim2.new(0.5, 0, 0.5, -60)
		wordmark.Size = UDim2.fromOffset(600, 100)
		wordmark.BackgroundTransparency = 1
		wordmark.Font = Enum.Font.GothamBold
		wordmark.Text = 'VAIN'
		wordmark.TextSize = 90
		wordmark.TextTransparency = 1
		wordmark.TextColor3 = Color3.new(1, 1, 1)
		wordmark.ZIndex = 3
		wordmark.Parent = root
		-- glowing orange stroke on the wordmark itself
		local wordmarkStroke = Instance.new('UIStroke')
		wordmarkStroke.Color = Color3.fromRGB(255, 120, 40)
		wordmarkStroke.Thickness = 2
		wordmarkStroke.Transparency = 1
		wordmarkStroke.Parent = wordmark
		-- orange metallic gradient on the wordmark (the V's old look)
		gradient = Instance.new('UIGradient')
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, Color3.fromRGB(154, 61, 10)),
			ColorSequenceKeypoint.new(0.28, Color3.fromRGB(255, 106, 31)),
			ColorSequenceKeypoint.new(0.48, Color3.fromRGB(255, 196, 138)),
			ColorSequenceKeypoint.new(0.68, Color3.fromRGB(255, 106, 31)),
			ColorSequenceKeypoint.new(1.00, Color3.fromRGB(122, 47, 8)),
		})
		gradient.Parent = wordmark

		-- ── circular progress ring ────────────────────────────────────────────
		-- Roblox has no native ring, so build one from two half-circle wedges that
		-- each rotate to reveal an orange arc. `setRingProgress(frac)` (0..1) drives
		-- the right half 0-180deg then the left half 180-360deg.
		local ringSize = 96
		local ringHolder = Instance.new('Frame')
		ringHolder.AnchorPoint = Vector2.new(0.5, 0.5)
		ringHolder.Position = UDim2.new(0.5, 0, 0.5, 42)
		ringHolder.Size = UDim2.fromOffset(ringSize, ringSize)
		ringHolder.BackgroundTransparency = 1
		ringHolder.ZIndex = 3
		ringHolder.Parent = root

		-- faint full track behind the arc
		local ringTrack = Instance.new('Frame')
		ringTrack.AnchorPoint = Vector2.new(0.5, 0.5)
		ringTrack.Position = UDim2.fromScale(0.5, 0.5)
		ringTrack.Size = UDim2.fromScale(1, 1)
		ringTrack.BackgroundColor3 = Color3.new(1, 1, 1)
		ringTrack.BackgroundTransparency = 0.88
		ringTrack.BorderSizePixel = 0
		ringTrack.ZIndex = 3
		ringTrack.Parent = ringHolder
		Instance.new('UICorner', ringTrack).CornerRadius = UDim.new(1, 0)

		-- Each side is a container clipping to one vertical half of the ring. Inside
		-- sits a full-ring-sized coloured DISC that only shows through its half. A
		-- child "cover" disc (bg-coloured) hides half of that disc, leaving a rotating
		-- semicircle; rotating the wrapper sweeps the exposed arc edge. Right half
		-- fills 0-50%, left half 50-100%.
		local function makeHalf(rightSide)
			local half = Instance.new('Frame')
			half.AnchorPoint = Vector2.new(0.5, 0.5)
			half.Position = UDim2.fromScale(rightSide and 0.75 or 0.25, 0.5)
			half.Size = UDim2.fromScale(0.5, 1)
			half.BackgroundTransparency = 1
			half.ClipsDescendants = true
			half.ZIndex = 4
			half.Parent = ringHolder
			-- wrapper spans the FULL ring (2x this half's width), centred on the ring
			-- centre, rotated to sweep. Anchored on the shared vertical centre line.
			local wrapper = Instance.new('Frame')
			wrapper.AnchorPoint = Vector2.new(rightSide and 0 or 1, 0.5)
			wrapper.Position = UDim2.fromScale(rightSide and 0 or 1, 0.5)
			wrapper.Size = UDim2.fromScale(2, 1)
			wrapper.BackgroundTransparency = 1
			wrapper.Rotation = 0
			wrapper.ZIndex = 4
			wrapper.Parent = half
			-- coloured full disc
			local disc = Instance.new('Frame')
			disc.AnchorPoint = Vector2.new(0.5, 0.5)
			disc.Position = UDim2.fromScale(0.5, 0.5)
			disc.Size = UDim2.fromScale(1, 1)
			disc.BackgroundColor3 = Color3.fromRGB(255, 106, 31)
			disc.BorderSizePixel = 0
			disc.ZIndex = 4
			disc.Parent = wrapper
			Instance.new('UICorner', disc).CornerRadius = UDim.new(1, 0)
			-- cover the far half of the disc so only the near semicircle shows
			local cover = Instance.new('Frame')
			cover.AnchorPoint = Vector2.new(rightSide and 1 or 0, 0.5)
			cover.Position = UDim2.fromScale(rightSide and 1 or 0, 0.5)
			cover.Size = UDim2.fromScale(0.5, 1)
			cover.BackgroundColor3 = Color3.fromRGB(8, 8, 10)
			cover.BackgroundTransparency = 1 -- transparent: clip on `half` already hides it
			cover.BorderSizePixel = 0
			cover.ZIndex = 5
			cover.Parent = wrapper
			return wrapper
		end
		local rightPivot = makeHalf(true)
		local leftPivot  = makeHalf(false)

		-- punch a hole so it reads as a ring, not a pie
		local ringHole = Instance.new('Frame')
		ringHole.AnchorPoint = Vector2.new(0.5, 0.5)
		ringHole.Position = UDim2.fromScale(0.5, 0.5)
		ringHole.Size = UDim2.fromScale(0.72, 0.72)
		ringHole.BackgroundColor3 = Color3.fromRGB(8, 8, 10)
		ringHole.BackgroundTransparency = 0.35 -- match the bg tint so the game shows through
		ringHole.BorderSizePixel = 0
		ringHole.ZIndex = 5
		ringHole.Parent = ringHolder
		Instance.new('UICorner', ringHole).CornerRadius = UDim.new(1, 0)

		-- percentage in the centre of the ring
		local ringPct = Instance.new('TextLabel')
		ringPct.AnchorPoint = Vector2.new(0.5, 0.5)
		ringPct.Position = UDim2.fromScale(0.5, 0.5)
		ringPct.Size = UDim2.fromScale(1, 1)
		ringPct.BackgroundTransparency = 1
		ringPct.Font = Enum.Font.GothamBold
		ringPct.Text = '0%'
		ringPct.TextSize = 20
		ringPct.TextColor3 = Color3.fromRGB(255, 160, 90)
		ringPct.TextTransparency = 1
		ringPct.ZIndex = 6
		ringPct.Parent = ringHolder

		-- drive the ring from a 0..1 fraction
		setRingProgress = function(frac)
			frac = math.clamp(frac, 0, 1)
			-- right half sweeps the first 50%, left half the second 50%
			rightPivot.Rotation = math.min(frac, 0.5) * 360
			leftPivot.Rotation  = math.max(frac - 0.5, 0) * 360
			ringPct.Text = tostring(math.floor(frac * 100 + 0.5)) .. '%'
		end

		-- status text UNDER the ring (kept for API compatibility, hidden for now)
		statusLabel = Instance.new('TextLabel')
		statusLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		statusLabel.Position = UDim2.new(0.5, 0, 0.5, 108)
		statusLabel.Size = UDim2.fromOffset(600, 20)
		statusLabel.BackgroundTransparency = 1
		statusLabel.Font = Enum.Font.Gotham
		statusLabel.Text = ''
		statusLabel.TextSize = 14
		statusLabel.TextColor3 = Color3.fromRGB(170, 170, 170)
		statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
		statusLabel.Visible = false -- status title hidden for now
		statusLabel.ZIndex = 3
		statusLabel.Parent = root

		-- intro animation: wordmark (+ glow) + ring fade in.
		tween(wordmark, 0.6, { TextTransparency = 0 })
		tween(wordmarkStroke, 0.6, { Transparency = 0.35 })
		tween(wordmarkGlow, 0.6, { TextTransparency = 0.55, TextStrokeTransparency = 0.4 })
		task.delay(0.25, function()
			tween(ringTrack, 0.6, { BackgroundTransparency = 0.82 })
			tween(ringPct, 0.6, { TextTransparency = 0 })
		end)
		-- gentle glow breathing on the wordmark
		task.spawn(function()
			while wordmark.Parent and not finished do
				tween(wordmarkStroke, 1.4, { Transparency = 0.15 }, Enum.EasingStyle.Sine)
				tween(wordmarkGlow, 1.4, { TextTransparency = 0.4 }, Enum.EasingStyle.Sine)
				task.wait(1.4)
				tween(wordmarkStroke, 1.4, { Transparency = 0.5 }, Enum.EasingStyle.Sine)
				tween(wordmarkGlow, 1.4, { TextTransparency = 0.65 }, Enum.EasingStyle.Sine)
				task.wait(1.4)
			end
		end)

		-- rising ember particles across the FULL screen width, floating up from the
		-- bottom and fading out.
		task.spawn(function()
			while screenGui.Parent and not finished do
				local size = math.random(4, 9)
				local p = Instance.new('Frame')
				p.AnchorPoint = Vector2.new(0.5, 0.5)
				p.Size = UDim2.fromOffset(size, size)
				-- spawn anywhere across the width, starting near/just below the bottom
				p.Position = UDim2.new(math.random() , 0, 1, math.random(0, 120))
				p.BackgroundColor3 = Color3.fromRGB(255, math.random(120, 190), 40)
				p.BackgroundTransparency = math.random(15, 45) / 100
				p.BorderSizePixel = 0
				p.ZIndex = 2
				Instance.new('UICorner', p).CornerRadius = UDim.new(1, 0)
				p.Parent = root
				local dur = math.random(30, 55) / 10 -- 3-5.5s to cross the screen
				tween(p, dur, {
					-- drift up past the top with a little horizontal sway
					Position = p.Position + UDim2.new((math.random(-6, 6)) / 100, 0, -(1.2 + math.random(0, 40) / 100), 0),
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(1, 1),
				}, Enum.EasingStyle.Linear)
				task.delay(dur, function() pcall(function() p:Destroy() end) end)
				task.wait(math.random(5, 14) / 100)
			end
		end)

		-- shimmer sweep across the VAIN wordmark
		task.spawn(function()
			while wordmark.Parent do
				gradient.Offset = Vector2.new(-1, 0)
				local t = TweenService:Create(gradient, TweenInfo.new(2.2, Enum.EasingStyle.Linear), { Offset = Vector2.new(1, 0) })
				t:Play()
				t.Completed:Wait()
			end
		end)
		-- smoothly chase the progress target every frame -> drive the ring
		task.spawn(function()
			while screenGui.Parent and not finished do
				progressShown = progressShown + (progressTarget - progressShown) * 0.12
				if setRingProgress then setRingProgress(math.clamp(progressShown, 0.02, 1)) end
				RunService.Heartbeat:Wait()
			end
		end)
	end

	-- Downloads are lazy so we can't know the exact total up front. Chase an
	-- ESTIMATE that grows if we exceed it, so the bar advances steadily and never
	-- sits stuck at 0 or slams to 100% early. Each completed download bumps it.
	local dlDone, dlEstimate = 0, 40
	local function recomputeTarget()
		if dlDone >= dlEstimate then dlEstimate = dlDone + 8 end
		progressTarget = math.max(progressTarget, math.min(dlDone / dlEstimate, 0.97))
	end

	-- The loading screen is PURELY cosmetic. Every entry point is fully pcall-
	-- wrapped so a UI/executor quirk can NEVER propagate out of a `downloader.Text`
	-- assignment and abort the download flow (which would leave modules missing).
	vainLoading = {
		-- set the status line (also builds the screen on first call). `frac` (0..1)
		-- optionally advances the bar.
		status = function(text, frac)
			pcall(function()
				build()
				if statusLabel then statusLabel.Text = text or '' end
				if frac then progressTarget = math.max(progressTarget, math.clamp(frac, 0, 1)) end
			end)
		end,
		-- mark one download complete -> advance the estimated progress
		bump = function()
			pcall(function()
				build()
				dlDone = dlDone + 1
				recomputeTarget()
			end)
		end,
		-- advance the bar without changing the status text
		progress = function(frac)
			if not built then return end
			progressTarget = math.max(progressTarget, math.clamp(frac, 0, 1))
		end,
		-- called once everything is loaded: fill the bar, fade out, run `after`.
		finish = function(after)
			if finished then if after then task.spawn(after) end return end
			finished = true
			if not built then if after then task.spawn(after) end return end
			task.spawn(function()
				if setRingProgress then setRingProgress(1) end
				if statusLabel then statusLabel.Text = 'Done' end
				task.wait(0.45)
				-- fade every element out (plain Frame root has no GroupTransparency)
				pcall(function()
					for _, d in ipairs(root:GetDescendants()) do
						if d:IsA('TextLabel') then
							tween(d, 0.6, { TextTransparency = 1 })
						elseif d:IsA('Frame') then
							tween(d, 0.6, { BackgroundTransparency = 1 })
						end
					end
					tween(root, 0.6, { BackgroundTransparency = 1 })
				end)
				task.wait(0.65)
				pcall(function() screenGui:Destroy() end)
				if after then task.spawn(after) end
			end)
		end,
		isActive = function() return built and not finished end,
	}
	if getgenv then getgenv().vainLoading = vainLoading end
end

-- legacy shim: a lot of code below just sets `downloader.Text`; route that through
-- the loading screen's status line (which builds the screen lazily).
local downloader = setmetatable({}, {
	__newindex = function(_, k, v)
		if k == 'Text' then vainLoading.status(v) end
	end,
	__index = function() return '' end,
})

-- GitHub raw serves error bodies as short plain text ("400: Invalid request",
-- "404: Not Found", "429: ..."). They must NEVER be cached as code -- doing so
-- writes e.g. "400: Invalid request" into entity.lua and every later inject dies
-- with [string "entitylibrary"]:2: ... got '400'. Reject any "NNN: ..." body.
local function isHttpError(res)
	return type(res) ~= 'string' or res == '' or res:match('^%s*%d%d%d:%s') ~= nil
end
local function downloadFile(path, func)
	-- self-heal: if a previous run cached an error body, drop it so we refetch
	if isfile(path) and path:find('%.lua') then
		local cached = readfile(path)
		if cached:match('^%s*%d%d%d:%s') or cached:match('^%-%-This watermark[^\n]*\n%s*%d%d%d:%s') then
			delfile(path)
		end
	end
	if not isfile(path) then
		downloader.Text = 'Downloading '.. path
		-- trim the ref: a stray newline/space turns "<sha>" into an invalid ref -> 400.
		-- readfile THROWS "file does not exist" on a missing commit.txt (it doesn't
		-- return nil), so guard it with pcall and fall back to the main ref.
		local ok, raw = pcall(readfile, 'vain/profiles/commit.txt')
		local commit = (ok and type(raw) == 'string' and raw or ''):match('^%s*(.-)%s*$')
		if commit == '' then commit = 'main' end
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/VainV6/Vain/'..commit..'/'..select(1, path:gsub('vain/', '')), true)
		end)
		if not suc or isHttpError(res) then
			error('Vain failed to download '..path..' (ref '..commit..'): '..tostring(res))
		end
		if path:find('.lua') then
			res = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vain updates.\n'..res
		end
		writefile(path, res)
		vainLoading.bump()
	end
	return (func or readfile)(path)
end

local function wipeFolder(path)
	if not isfolder(path) then return end
	for _, file in listfiles(path) do
		if file:find('init') then continue end
		if file:find('profile') then continue end
		if isfile(file) then
			delfile(file)
		elseif isfolder(file) then
			wipeFolder(file)
		end
	end
end

for _, folder in {'vain', 'vain/games', 'vain/profiles', 'vain/assets', 'vain/libraries', 'vain/guis'} do
	if not isfolder(folder) then
		downloader.Text = 'Creating '.. folder
		makefolder(folder)
	end
end

if not shared.VainDeveloper then
	local commit = 'main'

	-- Resolve the latest commit SHA. The REST API is rate limited to 60 req/hr
	-- per IP, so reinjecting often makes it fail and fall back to the 'main' ref,
	-- which is CDN-cached for minutes and serves stale code. The git info/refs
	-- endpoint is NOT API-rate-limited and returns the HEAD sha as plain text, so
	-- we try it as a fallback to keep downloads pinned to a real (fresh) sha.
	local function resolveSha()
		local ok, res = pcall(function()
			return game:HttpGet('https://api.github.com/repos/VainV6/Vain/commits/main', true)
		end)
		if ok and res then
			local h = res:match('"sha":"([a-f0-9]+)"')
			if h and #h == 40 then return h end
		end
		ok, res = pcall(function()
			return game:HttpGet('https://github.com/VainV6/Vain/info/refs?service=git-upload-pack', true)
		end)
		if ok and res then
			-- info/refs advertises the ref as "<pkt-len-hdr><40-hex-sha> refs/heads/main"
			-- where the 4-char pkt-line length header is glued onto the sha with no
			-- separator, so grab the hex run before the space and keep its last 40.
			local h = res:match('(%x+) refs/heads/main')
			if h and #h >= 40 then return h:sub(-40) end
		end
		return nil
	end

	local sha = resolveSha()
	if sha then
		commit = sha
	end
	if commit == 'main' or (isfile('vain/profiles/commit.txt') and readfile('vain/profiles/commit.txt') or '') ~= commit then
		if commit ~= 'main' and isfile('vain/profiles/commit.txt') then
			shared.updated = readfile('vain/profiles/commit.txt')
		end
		wipeFolder('vain')
		wipeFolder('vain/games')
		wipeFolder('vain/guis')
		wipeFolder('vain/libraries')
	end
	writefile('vain/profiles/commit.txt', commit)
end

downloader.Text = ''
return loadstring(downloadFile('vain/main.lua'), 'main')()
