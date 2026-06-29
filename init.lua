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

local downloader = Instance.new('TextLabel')
downloader.Size = UDim2.new(1, 0, 0, 40)
downloader.BackgroundTransparency = 1
downloader.TextStrokeTransparency = 0
downloader.TextSize = 20
downloader.TextColor3 = Color3.new(1, 1, 1)
downloader.Font = Enum.Font.Arial
downloader.Text = ''
downloader.Parent = Instance.new('ScreenGui', gethui and gethui() or cloneref(game:GetService('CoreGui')))

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
		downloader.Text = ''
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
