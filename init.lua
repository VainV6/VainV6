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
	local built, screenGui, root, statusLabel, setRingProgress
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

		-- (V removed) -- centred VAIN wordmark + progress bar + status.
		-- Modern, sleek wordmark: medium-weight GothamBold (not the puffy GothamBlack),
		-- wide letter-spacing, a flat clean orange, and no heavy outline -- so it reads
		-- as a crisp modern wordmark rather than a chunky puffy logo.
		local wordmark = Instance.new('Frame')
		wordmark.AnchorPoint = Vector2.new(0.5, 0.5)
		wordmark.Position = UDim2.new(0.5, 0, 0.5, -40)
		wordmark.Size = UDim2.fromOffset(420, 84)
		wordmark.BackgroundTransparency = 1
		wordmark.ZIndex = 3
		wordmark.Parent = root
		local wmLayout = Instance.new('UIListLayout')
		wmLayout.FillDirection = Enum.FillDirection.Horizontal
		wmLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		wmLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		wmLayout.Padding = UDim.new(0, 14) -- wide, modern letter-spacing / tracking
		wmLayout.Parent = wordmark

		local titleCol = Color3.fromRGB(245, 150, 40) -- flat orange, matches the bar
		local letters = {}
		for i = 1, 4 do
			local ch = ('VAIN'):sub(i, i)
			local l = Instance.new('TextLabel')
			l.LayoutOrder = i
			l.AutomaticSize = Enum.AutomaticSize.X
			l.Size = UDim2.fromOffset(0, 84)
			l.BackgroundTransparency = 1
			l.Font = Enum.Font.GothamBold      -- medium weight, not puffy
			l.Text = ch
			l.TextSize = 66
			l.TextColor3 = titleCol
			l.TextTransparency = 1
			l.ZIndex = 3
			l.Parent = wordmark
			letters[i] = l
		end

		-- ── linear progress bar ───────────────────────────────────────────────
		-- Simple rounded track + a SOLID orange fill (no gradient / shimmer), with
		-- the percentage centred above it.
		local barW    = 320
		local barH    = 8
		local accent  = Color3.fromRGB(245, 150, 40)   -- orange fill
		local trackCol = Color3.fromRGB(210, 210, 214) -- light grey track

		local barTrack = Instance.new('Frame')
		barTrack.AnchorPoint = Vector2.new(0.5, 0.5)
		barTrack.Position = UDim2.new(0.5, 0, 0.5, 40)
		barTrack.Size = UDim2.fromOffset(barW, barH)
		barTrack.BackgroundColor3 = trackCol
		barTrack.BackgroundTransparency = 0.75
		barTrack.BorderSizePixel = 0
		barTrack.ClipsDescendants = true
		barTrack.ZIndex = 3
		barTrack.Parent = root
		Instance.new('UICorner', barTrack).CornerRadius = UDim.new(1, 0)

		local barFill = Instance.new('Frame')
		barFill.AnchorPoint = Vector2.new(0, 0.5)
		barFill.Position = UDim2.fromScale(0, 0.5)
		barFill.Size = UDim2.fromScale(0, 1)
		barFill.BackgroundColor3 = accent   -- solid orange, no gradient / shimmer
		barFill.BorderSizePixel = 0
		barFill.ZIndex = 4
		barFill.Parent = barTrack
		Instance.new('UICorner', barFill).CornerRadius = UDim.new(1, 0)

		-- percentage centred above the bar
		local ringPct = Instance.new('TextLabel')
		ringPct.AnchorPoint = Vector2.new(0.5, 0.5)
		ringPct.Position = UDim2.new(0.5, 0, 0.5, 18)
		ringPct.Size = UDim2.fromOffset(120, 22)
		ringPct.BackgroundTransparency = 1
		ringPct.Font = Enum.Font.GothamBold
		ringPct.Text = '0%'
		ringPct.TextSize = 16
		ringPct.TextColor3 = Color3.fromRGB(235, 235, 240)
		ringPct.TextTransparency = 1
		ringPct.ZIndex = 4
		ringPct.Parent = root

		local curFrac = 0
		setRingProgress = function(frac)
			curFrac = math.clamp(frac, 0, 1)
			tween(barFill, 0.25, { Size = UDim2.fromScale(curFrac, 1) })
			ringPct.Text = tostring(math.floor(curFrac * 100 + 0.5)) .. '%'
		end

		-- status text UNDER the bar (kept for API compatibility, hidden for now)
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

		-- intro animation: letters fade in with a subtle left-to-right stagger.
		for i, l in ipairs(letters) do
			task.delay(0.06 * (i - 1), function()
				tween(l, 0.5, { TextTransparency = 0 })
			end)
		end
		task.delay(0.35, function()
			tween(ringPct, 0.6, { TextTransparency = 0 })
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
