local vain = shared.vain
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vain then
		vain:CreateNotification('Vain', 'Failed to load : ' .. err, 30, 'alert')
	end
	return res
end
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local delfile = delfile or function(file) pcall(writefile, file, '') end
local function downloadFile(path, func)
	if not isfile(path) then
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/VainV6/Vain/' .. readfile('vain/profiles/commit.txt') .. '/' .. select(1, path:gsub('vain/', '')), true)
		end)
		if not suc or res == '404: Not Found' then
			error(res)
		end
		if path:find('.lua') then
			res = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vain updates.\n' .. res
		end
		writefile(path, res)
	end
	return (func or readfile)(path)
end

vain.Place = 6872274481
-- This is a match-place redirect: load the full 6872274481 module file. Always go
-- through downloadFile (which caches) so it fetches the file when it's missing --
-- INCLUDING in VainDeveloper mode. The old code skipped the download entirely when
-- VainDeveloper was set and the file wasn't already cached, so dev/test loads got
-- ZERO match modules. Also self-heal a cached error body ("NNN: ...").
do
	local path = 'vain/games/' .. vain.Place .. '.lua'
	if isfile(path) then
		local cached = readfile(path)
		if cached == '' or cached:match('^%s*%d%d%d:%s') then
			pcall(delfile, path)
		end
	end
	loadstring(downloadFile(path), tostring(vain.Place))()
end
