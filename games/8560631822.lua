local vain = shared.vain
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vain then 
		vain:CreateNotification('Vain', 'Failed to load : '..err, 30, 'alert') 
	end
	return res
end
local isfile = isfile or function(file)
	local suc, res = pcall(function() 
		return readfile(file) 
	end)
	return suc and res ~= nil and res ~= ''
end
local function downloadFile(path, func)
	if not isfile(path) then
		local suc, res = pcall(function() 
			return game:HttpGet('https://raw.githubusercontent.com/7GrandDadPGN/VapeV4ForRoblox/'..readfile('vain/profiles/commit.txt')..'/'..select(1, path:gsub('vain/', '')), true) 
		end)
		if not suc or res == '404: Not Found' then 
			error(res) 
		end
		if path:find('.lua') then 
			res = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vain updates.\n'..res 
		end
		writefile(path, res)
	end
	return (func or readfile)(path)
end

vain.Place = 6872274481
-- Match-place redirect -> load the full 6872274481 module file. Always go through
-- downloadFile so it fetches when missing (incl. dev mode), and self-heal a cached
-- error body. (The old code skipped the download in developer mode when the file
-- wasn't cached -> zero match modules.)
do
	local delfile = delfile or function(file) pcall(writefile, file, '') end
	local path = 'vain/games/'..vain.Place..'.lua'
	if isfile(path) then
		local cached = readfile(path)
		if cached == '' or cached:match('^%s*%d%d%d:%s') then
			pcall(delfile, path)
		end
	end
	loadstring(downloadFile(path), 'bedwars')()
end