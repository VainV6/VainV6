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
	local built, screenGui, root, barFill, statusLabel, gradient
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
		screenGui = Instance.new('ScreenGui')
		screenGui.Name = 'VainLoadingScreen'
		screenGui.IgnoreGuiInset = true
		screenGui.DisplayOrder = 2147483647
		screenGui.ResetOnSpawn = false
		screenGui.Parent = gethui and gethui() or cloneref(game:GetService('CoreGui'))

		root = Instance.new('CanvasGroup')
		root.Name = 'Root'
		root.Size = UDim2.fromScale(1, 1)
		root.BackgroundTransparency = 1
		root.GroupTransparency = 1
		root.Parent = screenGui
		local bg = Instance.new('Frame')
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundColor3 = Color3.fromRGB(8, 8, 10)
		bg.BorderSizePixel = 0
		bg.Parent = root

		local container = Instance.new('Frame')
		container.AnchorPoint = Vector2.new(0.5, 0.5)
		container.Position = UDim2.fromScale(0.5, 0.5)
		container.Size = UDim2.fromOffset(420, 420)
		container.BackgroundTransparency = 1
		container.Parent = root

		-- soft glow rings behind the V
		local glowRings = {}
		for i = 1, 4 do
			local ring = Instance.new('Frame')
			ring.AnchorPoint = Vector2.new(0.5, 0.5)
			ring.Position = UDim2.fromScale(0.5, 0.42)
			ring.Size = UDim2.fromOffset(0, 0)
			ring.BackgroundColor3 = Color3.fromRGB(255, 106, 31)
			ring.BackgroundTransparency = 1
			ring.BorderSizePixel = 0
			ring.ZIndex = 1
			Instance.new('UICorner', ring).CornerRadius = UDim.new(1, 0)
			ring.Parent = container
			glowRings[i] = ring
		end

		local vLabel = Instance.new('TextLabel')
		vLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		vLabel.Position = UDim2.fromScale(0.5, 0.42)
		vLabel.Size = UDim2.fromOffset(40, 40)
		vLabel.BackgroundTransparency = 1
		vLabel.Text = 'V'
		vLabel.Font = Enum.Font.GothamBlack
		vLabel.TextScaled = true
		vLabel.TextColor3 = Color3.new(1, 1, 1)
		vLabel.TextTransparency = 1
		vLabel.ZIndex = 3
		vLabel.Parent = container
		gradient = Instance.new('UIGradient')
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, Color3.fromRGB(154, 61, 10)),
			ColorSequenceKeypoint.new(0.28, Color3.fromRGB(255, 106, 31)),
			ColorSequenceKeypoint.new(0.48, Color3.fromRGB(255, 196, 138)),
			ColorSequenceKeypoint.new(0.68, Color3.fromRGB(255, 106, 31)),
			ColorSequenceKeypoint.new(1.00, Color3.fromRGB(122, 47, 8)),
		})
		gradient.Rotation = 115
		gradient.Parent = vLabel

		local wordmark = Instance.new('TextLabel')
		wordmark.AnchorPoint = Vector2.new(0.5, 0.5)
		wordmark.Position = UDim2.new(0.5, 0, 0.72, 0)
		wordmark.Size = UDim2.fromOffset(200, 24)
		wordmark.BackgroundTransparency = 1
		wordmark.Font = Enum.Font.Gotham
		wordmark.Text = 'VAIN'
		wordmark.TextSize = 16
		wordmark.TextTransparency = 1
		wordmark.TextColor3 = Color3.new(1, 1, 1)
		wordmark.ZIndex = 3
		wordmark.Parent = container

		local barTrack = Instance.new('Frame')
		barTrack.AnchorPoint = Vector2.new(0.5, 0.5)
		barTrack.Position = UDim2.new(0.5, 0, 0.84, 0)
		barTrack.Size = UDim2.fromOffset(200, 3)
		barTrack.BackgroundColor3 = Color3.new(1, 1, 1)
		barTrack.BackgroundTransparency = 0.85
		barTrack.BorderSizePixel = 0
		barTrack.ZIndex = 3
		barTrack.Parent = container
		Instance.new('UICorner', barTrack).CornerRadius = UDim.new(1, 0)
		barFill = Instance.new('Frame')
		barFill.Size = UDim2.new(0, 0, 1, 0)
		barFill.BackgroundColor3 = Color3.fromRGB(255, 106, 31)
		barFill.BorderSizePixel = 0
		barFill.ZIndex = 4
		barFill.Parent = barTrack
		Instance.new('UICorner', barFill).CornerRadius = UDim.new(1, 0)

		-- status text UNDER the progress bar
		statusLabel = Instance.new('TextLabel')
		statusLabel.AnchorPoint = Vector2.new(0.5, 0)
		statusLabel.Position = UDim2.new(0.5, 0, 0.84, 14)
		statusLabel.Size = UDim2.fromOffset(460, 18)
		statusLabel.BackgroundTransparency = 1
		statusLabel.Font = Enum.Font.Gotham
		statusLabel.Text = ''
		statusLabel.TextSize = 12
		statusLabel.TextColor3 = Color3.fromRGB(160, 160, 160)
		statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
		statusLabel.ZIndex = 3
		statusLabel.Parent = container

		-- intro animation
		tween(root, 0.3, { GroupTransparency = 0 })
		tween(vLabel, 0.9, { Size = UDim2.fromOffset(240, 240), TextTransparency = 0 }, Enum.EasingStyle.Back)
		for i, ring in ipairs(glowRings) do
			task.delay(0.05 * i, function()
				tween(ring, 1.1, { Size = UDim2.fromOffset(150 + i * 55, 150 + i * 55), BackgroundTransparency = 0.88 + i * 0.02 }, Enum.EasingStyle.Sine)
			end)
		end
		task.delay(0.4, function()
			tween(wordmark, 0.6, { TextTransparency = 0 })
			tween(barTrack, 0.6, { BackgroundTransparency = 0.75 })
		end)
		-- shimmer sweep across the V
		task.spawn(function()
			while vLabel.Parent do
				gradient.Offset = Vector2.new(-1, 0)
				local t = TweenService:Create(gradient, TweenInfo.new(2.2, Enum.EasingStyle.Linear), { Offset = Vector2.new(1, 0) })
				t:Play()
				t.Completed:Wait()
			end
		end)
		-- smoothly chase the progress target every frame
		task.spawn(function()
			while screenGui.Parent and not finished do
				progressShown = progressShown + (progressTarget - progressShown) * 0.12
				barFill.Size = UDim2.new(math.clamp(progressShown, 0.03, 1), 0, 1, 0)
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

	vainLoading = {
		-- set the status line (also builds the screen on first call). `frac` (0..1)
		-- optionally advances the bar.
		status = function(text, frac)
			build()
			if statusLabel then statusLabel.Text = text or '' end
			if frac then progressTarget = math.max(progressTarget, math.clamp(frac, 0, 1)) end
		end,
		-- mark one download complete -> advance the estimated progress
		bump = function()
			build()
			dlDone = dlDone + 1
			recomputeTarget()
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
				tween(barFill, 0.3, { Size = UDim2.new(1, 0, 1, 0) })
				if statusLabel then statusLabel.Text = 'Done' end
				task.wait(0.45)
				tween(root, 0.6, { GroupTransparency = 1 })
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
		-- trim the ref: a stray newline/space turns "<sha>" into an invalid ref -> 400
		local commit = (readfile('vain/profiles/commit.txt') or ''):match('^%s*(.-)%s*$')
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
