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

local function downloadFile(path, func)
	if not isfile(path) then
		downloader.Text = 'Downloading '.. path
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/VainV6/Vain/'..readfile('vain/profiles/commit.txt')..'/'..select(1, path:gsub('vain/', '')), true)
		end)
		if not suc or res == '404: Not Found' then
			error(res)
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
	local ok, res = pcall(function()
		return game:HttpGet('https://api.github.com/repos/VainV6/Vain/commits/main', true)
	end)
	if ok and res then
		local h = res:match('"sha":"([a-f0-9]+)"')
		if h and #h == 40 then
			commit = h
		end
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
