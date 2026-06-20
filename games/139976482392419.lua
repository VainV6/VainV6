-- Vain :: Rogue Realms (139976482392419)
-- Wave-based RPG roguelike. Enemies are character models (Humanoid + EnemyHitBox)
-- that spawn into workspace.Enemies. Weapons are Tools, each holding its own
-- ServerControl RemoteFunction (classic linked-gear pattern). Most combat routes
-- through that per-tool ServerControl, so modules that only fire the legitimate
-- attack faster are reliable; raw value edits (health/mana) are server-checked.

local run = function(func)
	local suc, err = pcall(func)
	if not suc then
		local vain = shared.vain
		if vain and vain.CreateNotification then
			vain:CreateNotification('Vain Rogue Realms', 'Failure executing function: ' .. tostring(err), 3)
		end
	end
end
local cloneref = cloneref or function(obj)
	return obj
end
local vapeEvents = setmetatable({}, {
	__index = function(self, index)
		self[index] = Instance.new('BindableEvent')
		return self[index]
	end
})

local playersService = cloneref(game:GetService('Players'))
local runService = cloneref(game:GetService('RunService'))
local inputService = cloneref(game:GetService('UserInputService'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local collectionService = cloneref(game:GetService('CollectionService'))
local tweenService = cloneref(game:GetService('TweenService'))

local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer
local vain = shared.vain
local entitylib = vain.Libraries.entity
local whitelist = vain.Libraries.whitelist
local prediction = vain.Libraries.prediction
local targetinfo = vain.Libraries.targetinfo
local sessioninfo = vain.Libraries.sessioninfo

-- CreateNotification(title, text, duration, type) - the GUI needs a numeric
-- duration (it builds a TweenInfo from it), so default one if not supplied.
local function notif(title, text, duration, kind)
	return vain:CreateNotification(title, text, duration or 4, kind)
end

-- ── Anti Hit bridge ───────────────────────────────────────────────────────────
-- Anti Hit replicates your root far away so enemies can't reach you. But your own
-- attacks also resolve against your replicated position, so they'd whiff too. This
-- shared bridge lets the attack code briefly run "from your real position": it
-- snaps the root back, runs the action, and the desync loop resumes next frame.
-- The Anti Hit module (defined later) registers its handlers here.
local antihit = {
	active = false,        -- is Anti Hit currently desyncing?
	getReal = nil,         -- () -> CFrame: where you really are
	restore = nil,         -- (CFrame) -> (): write the real CFrame to the root now
}

-- Run fn with your real position replicated (so server-side hit checks see you
-- where you actually are). No-op passthrough when Anti Hit is off.
local function withRealPosition(fn)
	if not (antihit.active and antihit.getReal and antihit.restore) then
		return fn()
	end
	local real = antihit.getReal()
	if real then antihit.restore(real) end
	local ok, res = pcall(fn)
	-- desync loop (Stepped) will push us back out next frame; nothing else to do
	if not ok then return nil end
	return res
end

-- ── Round state ───────────────────────────────────────────────────────────────
-- ReplicatedStorage.IsInShop is a BoolValue the whole game uses to gate combat:
-- false while a wave/round is active, true while you're safe in the between-round
-- shop. "In a round" therefore means IsInShop is present and false.
local function inRound()
	local flag = replicatedStorage:FindFirstChild('IsInShop')
	if not flag then return false end -- not loaded into a run yet -> treat as safe
	return flag.Value == false
end

local function inShop()
	local flag = replicatedStorage:FindFirstChild('IsInShop')
	return flag ~= nil and flag.Value == true
end

local function isFriend(plr, recolor)
	if plr and vain.Categories.Friends.Options['Use friends'].Enabled then
		local friend = table.find(vain.Categories.Friends.ListEnabled, plr.Name) and true
		if recolor then
			friend = friend and vain.Categories.Friends.Options['Recolor visuals'].Enabled
		end
		return friend
	end
	return nil
end

local function isTarget(plr)
	return plr and table.find(vain.Categories.Targets.ListEnabled, plr.Name) and true
end

-- ── Enemy helpers ─────────────────────────────────────────────────────────────
-- Live enemies are character models parented under workspace.Enemies. They carry
-- a Humanoid and an EnemyHitBox part; EnemyInfo (a BillboardGui) holds the name.
local function enemiesFolder()
	return workspace:FindFirstChild('Enemies')
end

local function isEnemyModel(model)
	if typeof(model) ~= 'Instance' or not model:IsA('Model') then return false end
	return model:FindFirstChild('EnemyHitBox') ~= nil or model:FindFirstChildOfClass('Humanoid') ~= nil
end

-- Bosses are NOT in workspace.Enemies - during a boss fight the game clones a
-- "<Name>BossFight" folder into workspace, and the boss character inside is a
-- Model with a Humanoid and a "Boss" child (its root is BeveledCube or
-- HumanoidRootPart). That's why Killaura/AutoFarm/Freeze ignored bosses: they
-- were never registered as entities. (Confirmed from the decompiled TargetService:
-- FindCurrentBossFight scans workspace for the *BossFight folder, and the boss
-- model is identified by its Boss child + Humanoid.)
local function isBossModel(model)
	if typeof(model) ~= 'Instance' or not model:IsA('Model') then return false end
	if not model:FindFirstChildOfClass('Humanoid') then return false end
	return model:FindFirstChild('Boss') ~= nil
		or model:GetAttribute('Boss') == true
		or model:FindFirstChild('BeveledCube') ~= nil
end

-- find the live boss character model inside a *BossFight folder
local function bossCharacterIn(folder)
	if not folder then return nil end
	if isBossModel(folder) then return folder end
	for _, d in folder:GetDescendants() do
		if d:IsA('Model') and isBossModel(d) then return d end
	end
	return nil
end

local function enemyName(model)
	local info = model:FindFirstChild('EnemyInfo', true)
	local nameLabel = info and info:FindFirstChild('EnemyName', true)
	if nameLabel and nameLabel:IsA('TextLabel') then
		return nameLabel.Text
	end
	return model.Name
end

-- ── Shop helpers ──────────────────────────────────────────────────────────────
-- Between rounds you're in workspace.Shop. Buyable items live under VisualGears /
-- VisualAccessories / VisualSacrifices; each item model holds a ProximityPrompt
-- (usually on a ShopFalseHandle) you trigger to buy, plus a Price and a name. The
-- layout is built at runtime, so we introspect each model defensively rather than
-- assuming fixed child paths.
local SHOP_CATEGORIES = {
	Gears = 'VisualGears',
	Accessories = 'VisualAccessories',
	Sacrifices = 'VisualSacrifices',
}

local function shopFolder()
	return workspace:FindFirstChild('Shop')
		or workspace:FindFirstChild('VisualShop')
		or workspace:FindFirstChild('ShopVisual')
end

-- current Tix (the spendable currency)
local function getTix()
	local stats = lplr:FindFirstChild('leaderstats')
	local tix = stats and stats:FindFirstChild('Tix')
	if tix then return tix.Value end
	local pv = lplr:FindFirstChild('PlayerValues')
	tix = pv and pv:FindFirstChild('Tix')
	return tix and tix.Value or 0
end

-- pull a numeric price out of an item model (a Price value, or digits in any
-- price-ish label text)
local function itemPrice(model)
	local p = model:FindFirstChild('Price', true)
	if p then
		if p:IsA('ValueBase') then return tonumber(p.Value) or 0 end
		if p:IsA('TextLabel') or p:IsA('TextButton') then
			local n = tostring(p.Text):gsub('%D', '')
			return tonumber(n) or 0
		end
	end
	-- fall back to the prompt's ObjectText / any label with a number
	for _, d in model:GetDescendants() do
		if (d:IsA('TextLabel') or d:IsA('TextButton')) and d.Text:lower():find('tix') then
			local n = tostring(d.Text):gsub('%D', '')
			if tonumber(n) then return tonumber(n) end
		end
	end
	return 0
end

-- best-effort display name for an item model
local function itemName(model)
	local n = model:GetAttribute('ItemName')
	if type(n) == 'string' and n ~= '' then return n end
	local info = model:FindFirstChild('ItemName', true) or model:FindFirstChild('Title', true)
	if info and (info:IsA('TextLabel') or info:IsA('TextButton')) and info.Text ~= '' then
		return info.Text
	end
	return model.Name
end

-- the ProximityPrompt used to purchase this item, if any
local function itemPrompt(model)
	return model:FindFirstChildWhichIsA('ProximityPrompt', true)
end

-- Strip Roblox RichText markup (the tooltip label isn't rich-text, so the raw
-- <font color="..."> tags would show literally) and decode common entities.
local function stripRich(s)
	s = tostring(s)
	s = s:gsub('<br%s*/?>', '\n')      -- line breaks -> newlines
	s = s:gsub('<[^>]->', '')          -- drop every other tag (font, b, i, ...)
	s = s:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&quot;', '"'):gsub('&apos;', "'"):gsub('&amp;', '&')
	return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- best-effort description text for an item, for the picker hover tooltip. Items
-- carry it as a Description / CurrentDescription (attribute, StringValue, or a
-- text label). Returns nil if none, so the tooltip just shows the name.
local function itemDescription(model)
	local d = model:GetAttribute('CurrentDescription') or model:GetAttribute('Description')
	if type(d) == 'string' and d ~= '' then return stripRich(d) end
	for _, name in {'CurrentDescription', 'Description'} do
		local c = model:FindFirstChild(name, true)
		if c then
			if c:IsA('ValueBase') and type(c.Value) == 'string' and c.Value ~= '' then return stripRich(c.Value) end
			if (c:IsA('TextLabel') or c:IsA('TextButton')) and c.Text ~= '' then return stripRich(c.Text) end
		end
	end
	return nil
end

-- best-effort image asset id for an item model, for the picker icons. Gears are
-- Tools (Tool.TextureId is the icon); accessories may not carry a flat image, in
-- which case we return nil and the option just renders text-only.
local function itemIcon(model)
	-- a Tool (gear) or a Tool nested inside the model
	local tool = model:IsA('Tool') and model or model:FindFirstChildWhichIsA('Tool', true)
	if tool and tool.TextureId and tool.TextureId ~= '' then
		return tool.TextureId
	end
	-- an explicit icon attribute some items set
	local attr = model:GetAttribute('Icon') or model:GetAttribute('Image') or model:GetAttribute('TextureId')
	if type(attr) == 'string' and attr ~= '' then return attr end
	-- any image-bearing GUI element
	for _, d in model:GetDescendants() do
		if (d:IsA('ImageLabel') or d:IsA('ImageButton')) and d.Image ~= '' then return d.Image end
	end
	-- a mesh texture or decal on the handle. Note: SpecialMesh has .TextureId,
	-- but MeshPart uses .TextureID (capital D) - reading the wrong one errors, so
	-- read each by its real property and pcall to be safe.
	for _, d in model:GetDescendants() do
		if d:IsA('SpecialMesh') then
			local ok, tex = pcall(function() return d.TextureId end)
			if ok and tex and tex ~= '' then return tex end
		elseif d:IsA('MeshPart') then
			local ok, tex = pcall(function() return d.TextureID end)
			if ok and tex and tex ~= '' then return tex end
		elseif d:IsA('Decal') and d.Texture ~= '' then
			return d.Texture
		end
	end
	return nil
end

-- The full item catalog lives in ReplicatedStorage (Gears / Accessories /
-- Sacrifices), separate from what's currently stocked in the shop. Listing the
-- catalog lets the picker show every buyable item, not just this round's offers.
local CATALOG_FOLDERS = {
	Gears = 'Gears',
	Accessories = 'Accessories',
	Sacrifices = 'Sacrifices',
}
-- iterate every catalog item, calling fn(model, category)
local function forEachCatalogItem(fn)
	for category, folderName in CATALOG_FOLDERS do
		local folder = replicatedStorage:FindFirstChild(folderName)
		if folder then
			for _, item in folder:GetChildren() do
				if item:IsA('Tool') or item:IsA('Accessory') or item:IsA('Model') then
					fn(item, category)
				end
			end
		end
	end
end

-- iterate buyable items, calling fn(item, category, prompt) for each. Any child
-- holding a ProximityPrompt is buyable - don't restrict by class, since shop items
-- can be Models, Tools, Accessories or bare parts depending on the item.
local function forEachShopItem(fn)
	-- The buyable items live in VisualGears / VisualAccessories / VisualSacrifices
	-- folders nested somewhere under the shop rig in workspace. A fixed path missed
	-- them, so find each folder wherever it is (recursive) and iterate its direct
	-- children -- each child (e.g. HealthPotion) is an item model with a
	-- ProximityPrompt you trigger to buy.
	local cats = {VisualGears = 'Gears', VisualAccessories = 'Accessories', VisualSacrifices = 'Sacrifices'}
	for folderName, category in cats do
		local folder = workspace:FindFirstChild(folderName, true)
		if folder then
			for _, item in folder:GetChildren() do
				local prompt = item:FindFirstChildWhichIsA('ProximityPrompt', true)
				if prompt then fn(item, category, prompt) end
			end
		end
	end
end

-- ── entitylib setup for NPC enemies ───────────────────────────────────────────
-- entitylib.start() only tracks players, so we register each enemy model as an
-- NPC entity ourselves and keep the workspace.Enemies folder watched.
run(function()
	entitylib.targetCheck = function(ent)
		if ent.TeamCheck then return ent:TeamCheck() end
		if ent.NPC then return true end -- enemies are always valid targets
		if isFriend(ent.Player) then return false end
		return ent.Player ~= lplr
	end

	entitylib.getUpdateConnections = function(ent)
		local hum = ent.Humanoid
		return {
			hum:GetPropertyChangedSignal('Health'),
			hum:GetPropertyChangedSignal('MaxHealth'),
			{
				Connect = function()
					ent.Friend = ent.Player and isFriend(ent.Player) or nil
					ent.Target = ent.Player and isTarget(ent.Player) or nil
					return {Disconnect = function() end}
				end
			}
		}
	end
end)
entitylib.start()

run(function()
	local function tryAddEnemy(model)
		if not isEnemyModel(model) then return end
		if entitylib.getEntity(model) then return end
		entitylib.addEntity(model, nil)
	end

	local function bindFolder(folder)
		if not folder then return end
		vain:Clean(folder.ChildAdded:Connect(tryAddEnemy))
		vain:Clean(folder.ChildRemoved:Connect(function(model)
			entitylib.removeEntity(model)
		end))
		for _, model in folder:GetChildren() do
			tryAddEnemy(model)
		end
	end

	-- bind the current folder and re-bind if it's replaced (world/map swap)
	bindFolder(enemiesFolder())

	-- ── Boss fights ────────────────────────────────────────────────────────────
	-- Bosses spawn in a "<Name>BossFight" folder cloned into workspace, not under
	-- Enemies. Register the boss character inside so all combat modules see it.
	local function registerBoss(fightFolder)
		task.spawn(function()
			-- the boss model may stream in a moment after the fight folder appears
			for _ = 1, 50 do
				local boss = bossCharacterIn(fightFolder)
				if boss then
					if not entitylib.getEntity(boss) then
						boss:SetAttribute('VainBoss', true)
						entitylib.addEntity(boss, nil)
					end
					-- clean up when the fight folder is removed
					vain:Clean(fightFolder.AncestryChanged:Connect(function(_, parent)
						if not parent then entitylib.removeEntity(boss) end
					end))
					return
				end
				task.wait(0.2)
			end
		end)
	end

	local function isBossFightFolder(inst)
		return inst and inst:IsA('Folder') and inst.Name:find('BossFight')
	end

	for _, child in workspace:GetChildren() do
		if isBossFightFolder(child) then registerBoss(child) end
	end

	vain:Clean(workspace.ChildAdded:Connect(function(child)
		if child.Name == 'Enemies' then
			bindFolder(child)
		elseif isBossFightFolder(child) then
			registerBoss(child)
		end
	end))
end)

-- ── Weapon helpers ────────────────────────────────────────────────────────────
-- Each weapon Tool carries its own ServerControl RemoteFunction. We don't know
-- the exact action signature without the live source, so combat modules try a
-- few classic gear conventions and otherwise fall back to firing Tool.Activated.
local function getEquippedTool()
	local char = lplr.Character
	if not char then return nil end
	return char:FindFirstChildOfClass('Tool')
end

-- Equip the best available weapon when our hands are empty: prefer a sword
-- (highest Damage attribute if several), otherwise just the first backpack tool
-- (slot 1). Lets an empty-handed AutoFarm swing actually land.
local function equipBestWeapon()
	local char = lplr.Character
	local hum = char and char:FindFirstChildOfClass('Humanoid')
	local backpack = lplr:FindFirstChild('Backpack')
	if not (char and hum and backpack) then return false end
	if char:FindFirstChildOfClass('Tool') then return true end
	local sword, swordDmg, first
	for _, t in backpack:GetChildren() do
		if t:IsA('Tool') then
			first = first or t
			if t.Name:lower():find('sword') then
				local dmg = t:GetAttribute('Damage') or t:GetAttribute('damage') or 0
				if not sword or dmg > swordDmg then sword, swordDmg = t, dmg end
			end
		end
	end
	local pick = sword or first
	if pick then
		pcall(function() hum:EquipTool(pick) end)
		return char:FindFirstChildOfClass('Tool') ~= nil
	end
	return false
end

local function getServerControl(tool)
	tool = tool or getEquippedTool()
	return tool and tool:FindFirstChild('ServerControl'), tool
end

-- Best-effort attack against an enemy entity using the equipped weapon. Returns
-- true if it managed to fire something. Pure-melee gears usually accept the
-- target's hitbox/character; we try those shapes, then fall back to Activated.
-- The gears are classic Kohl's-style tools: an attack is a MouseClick down then
-- up on the tool's ServerControl, with the aim point in MousePosition. (Verified
-- from the decompiled gear source: InvokeServer("MouseClick", {Down=..., ...,
-- MousePosition=Vector3}).) The server resolves the hit, so pointing MousePosition
-- at the enemy's hitbox is enough.
-- Kill attribution: when we swing at an enemy we stamp its model so the kill feed
-- can tell "we killed it" from enemies that died to something else. Keyed by the
-- enemy Character model, value = tick() of the last swing.
local lastAttacked = setmetatable({}, {__mode = 'k'})
local function markAttacked(ent)
	local key = ent and (ent.Character or ent.Model)
	if key then lastAttacked[key] = tick() end
end

local function attackEnemy(ent)
	local sc, tool = getServerControl()
	if not sc then
		if tool then
			markAttacked(ent)
			return pcall(function() tool:Activate() end)
		end
		return false
	end
	local hitbox = ent.Character and (ent.Character:FindFirstChild('EnemyHitBox') or ent.RootPart)
	local aim = hitbox and hitbox.Position or ent.RootPart.Position
	-- If Anti Hit is desyncing us, resolve the swing from our real position so the
	-- server sees us in range; otherwise the hit whiffs like everything else.
	markAttacked(ent)
	local ok = withRealPosition(function()
		sc:InvokeServer('MouseClick', {Down = true, MousePosition = aim})
		sc:InvokeServer('MouseClick', {Down = false, HeldTime = 0, MousePosition = aim})
		return true
	end)
	return ok and true or false
end

local function aliveLocal()
	return entitylib.isAlive and entitylib.character and entitylib.character.RootPart
end

-- Every workspace folder/model that looks like a drop container, matched by name
-- (case-insensitive) so we adapt to the game's folders -- EnemiesDrops, Tixes,
-- DropS, Hearts, ManaStars, etc. The old code only scanned EnemiesDrops + Tixes,
-- so hearts / mana stars (which live in other folders) were never collected.
local function collectibleFolders()
	local out = {}
	for _, child in workspace:GetChildren() do
		if child:IsA('Folder') or child:IsA('Model') then
			local n = child.Name:lower()
			if n:find('drop') or n:find('tix') or n:find('heart') or n:find('mana')
				or n:find('star') or n:find('loot') or n:find('pickup') or n:find('shield') then
				table.insert(out, child)
			end
		end
	end
	return out
end

-- ══════════════════════════════════════════════════════════════════════════════
--  ENEMY ESP
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local EnemyESP
	local ShowHealth, ShowName, BossOnly, MaxRange
	local highlights = {} -- [ent] = {Highlight, Billboard, Label}

	local function clear(ent)
		local h = highlights[ent]
		if h then
			pcall(function() h.Highlight:Destroy() end)
			pcall(function() h.Billboard:Destroy() end)
			highlights[ent] = nil
		end
	end

	local function clearAll()
		for ent in highlights do clear(ent) end
	end

	local function isBoss(ent)
		local n = (ent.Character and ent.Character.Name or '')
		return ent.Character and (ent.Character:FindFirstChild('Boss', true) ~= nil
			or ent.Character:GetAttribute('Boss') == true)
	end

	local function update()
		local myPos = aliveLocal() and entitylib.character.RootPart.Position
		local maxR = MaxRange and MaxRange.Value or 99999
		for ent in highlights do
			if not ent.Character or not ent.Character.Parent then clear(ent) end
		end
		for _, ent in entitylib.List do
			if ent.NPC and ent.Character and ent.Character.Parent then
				local inRange = (not myPos) or (ent.RootPart.Position - myPos).Magnitude <= maxR
				local pass = inRange and (not (BossOnly and BossOnly.Enabled) or isBoss(ent))
				if pass then
					local data = highlights[ent]
					if not data then
						local hl = Instance.new('Highlight')
						hl.Name = 'VainEnemy'
						hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
						hl.FillColor = isBoss(ent) and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(255, 140, 40)
						hl.OutlineColor = Color3.fromRGB(255, 220, 120)
						hl.FillTransparency = 0.55
						hl.Adornee = ent.Character
						hl.Parent = ent.Character

						local bb = Instance.new('BillboardGui')
						bb.Name = 'VainEnemyTag'
						bb.Size = UDim2.fromOffset(150, 30)
						bb.StudsOffset = Vector3.new(0, 3, 0)
						bb.AlwaysOnTop = true
						bb.Adornee = ent.Head or ent.RootPart
						bb.Parent = ent.Character
						local label = Instance.new('TextLabel')
						label.Size = UDim2.fromScale(1, 1)
						label.BackgroundTransparency = 1
						label.Font = Enum.Font.GothamBold
						label.TextSize = 13
						label.TextColor3 = Color3.fromRGB(255, 235, 200)
						label.TextStrokeTransparency = 0.4
						label.Parent = bb

						data = {Highlight = hl, Billboard = bb, Label = label}
						highlights[ent] = data
					end
					if data.Label then
						local parts = {}
						if not ShowName or ShowName.Enabled then table.insert(parts, enemyName(ent.Character)) end
						if (not ShowHealth or ShowHealth.Enabled) and ent.Humanoid then
							table.insert(parts, string.format('%d/%d', math.floor(ent.Health or ent.Humanoid.Health), math.floor(ent.MaxHealth or ent.Humanoid.MaxHealth)))
						end
						data.Label.Text = table.concat(parts, '  ')
					end
				else
					clear(ent)
				end
			end
		end
	end

	EnemyESP = vain.Categories.Render:CreateModule({
		Name = 'Enemy ESP',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						update()
						task.wait(0.2)
					until not EnemyESP.Enabled
					clearAll()
				end)
			else
				clearAll()
			end
		end,
		Tooltip = 'Highlights enemies with their name and health. Client-side render only.'
	})
	ShowName = EnemyESP:CreateToggle({Name = 'Show Name', Default = true})
	ShowHealth = EnemyESP:CreateToggle({Name = 'Show Health', Default = true})
	BossOnly = EnemyESP:CreateToggle({Name = 'Bosses Only'})
	MaxRange = EnemyESP:CreateSlider({Name = 'Max Range', Min = 50, Max = 2000, Default = 2000, Suffix = 'studs'})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  KILL AURA  (auto-attack enemies in range with your equipped weapon)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local KillAura
	local Range, Delay, MultiTarget, BossPriority

	local function pickTargets()
		if not aliveLocal() then return {} end
		local myPos = entitylib.character.RootPart.Position
		local range = Range and Range.Value or 30
		local found = {}
		for _, ent in entitylib.List do
			if ent.NPC and ent.Character and ent.Character.Parent and ent.Humanoid and ent.Humanoid.Health > 0 then
				local dist = (ent.RootPart.Position - myPos).Magnitude
				if dist <= range then
					table.insert(found, {ent = ent, dist = dist})
				end
			end
		end
		table.sort(found, function(a, b)
			if BossPriority and BossPriority.Enabled then
				local ab = a.ent.Character:FindFirstChild('Boss', true) ~= nil
				local bb = b.ent.Character:FindFirstChild('Boss', true) ~= nil
				if ab ~= bb then return ab end
			end
			return a.dist < b.dist
		end)
		return found
	end

	KillAura = vain.Categories.Combat:CreateModule({
		Name = 'KillAura',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local targets = pickTargets()
						local count = (MultiTarget and MultiTarget.Enabled) and #targets or math.min(1, #targets)
						for i = 1, count do
							local data = targets[i]
							if data then
								attackEnemy(data.ent)
								if targetinfo and targetinfo.Targets then
									targetinfo.Targets[data.ent] = tick() + 0.5
								end
							end
						end
						task.wait(Delay and Delay.Value or 0.15)
					until not KillAura.Enabled
				end)
			end
		end,
		Tooltip = 'Automatically attacks enemies in range with your equipped weapon.'
	})
	Range = KillAura:CreateSlider({Name = 'Range', Min = 5, Max = 100, Default = 30, Suffix = 'studs'})
	Delay = KillAura:CreateSlider({Name = 'Delay', Min = 0.05, Max = 1, Default = 0.15, Decimal = 100, Suffix = 's'})
	MultiTarget = KillAura:CreateToggle({Name = 'Multi Target'})
	BossPriority = KillAura:CreateToggle({Name = 'Boss Priority', Default = true})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO FARM  (face nearest enemy, attack, and auto-collect drops)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoFarm
	local Offset, Height, ReturnHome, CollectDrops, CollectHearts, CollectShields, CollectMana, DropRange, AutoEquip

	local function nearestEnemy()
		if not aliveLocal() then return nil end
		local myPos = entitylib.character.RootPart.Position
		local best, bestd = nil, math.huge
		for _, ent in entitylib.List do
			if ent.NPC and ent.Humanoid and ent.Humanoid.Health > 0 and ent.Character and ent.Character.Parent then
				local d = (ent.RootPart.Position - myPos).Magnitude
				if d < bestd then best, bestd = ent, d end
			end
		end
		return best
	end

	-- Loot drops land in TWO folders: workspace.EnemiesDrops (enemy loot) and
	-- workspace.Tixes (currency). Collection is server-side on touch, so we both
	-- teleport onto the drop AND fire the touch interest to make the pickup register.
	local DROP_FOLDERS = {'EnemiesDrops', 'Tixes'}

	local function dropPart(obj)
		return obj:IsA('BasePart') and obj or obj:FindFirstChildWhichIsA('BasePart', true)
	end

	-- classify a drop part by name (its own + its ancestor model) so we can filter.
	-- returns 'heart' | 'shield' | 'tix' | 'loot'
	local function dropKind(part)
		local name = part.Name:lower()
		local model = part:FindFirstAncestorWhichIsA('Model')
		if model then name = name .. ' ' .. model.Name:lower() end
		if name:find('heart') or name:find('health') or name:find('heal') then return 'heart' end
		if name:find('shield') then return 'shield' end
		if name:find('mana') or name:find('star') then return 'mana' end
		if name:find('tix') or part:IsDescendantOf(workspace:FindFirstChild('Tixes') or workspace) then return 'tix' end
		return 'loot'
	end

	-- force a touch between our root and the drop so the server's Touched pickup fires
	local function touchDrop(part)
		local root = entitylib.character.RootPart
		if not root then return end
		pcall(function()
			firetouchinterest(part, root, 0)
			firetouchinterest(part, root, 1)
			firetouchinterest(part, root, 0)
		end)
	end

	-- Collect every nearby enabled drop by teleporting onto each in turn.
	local function sweepDrops()
		if not aliveLocal() then return end
		-- run if ANY collect option is on (master loot, hearts, shields, or mana)
		local wantLoot = CollectDrops and CollectDrops.Enabled
		local wantHearts = CollectHearts and CollectHearts.Enabled
		local wantShields = CollectShields and CollectShields.Enabled
		local wantMana = CollectMana and CollectMana.Enabled
		if not (wantLoot or wantHearts or wantShields or wantMana) then return end

		local root = entitylib.character.RootPart
		local range = DropRange and DropRange.Value or 200
		-- snapshot first so we don't iterate folders that change as we collect
		local drops = {}
		for _, folder in collectibleFolders() do
			if folder then
				for _, obj in folder:GetDescendants() do
					if obj:IsA('BasePart') and (obj.Position - root.Position).Magnitude <= range then
						local kind = dropKind(obj)
						-- generic loot / tix follow the master toggle; hearts & shields
						-- have their own toggles so you can grab them even with loot off
						local take = (kind == 'heart' and wantHearts)
							or (kind == 'shield' and wantShields)
							or (kind == 'mana' and wantMana)
							or ((kind == 'tix' or kind == 'loot') and wantLoot)
						if take then table.insert(drops, obj) end
					end
				end
			end
		end
		for _, part in drops do
			if not AutoFarm.Enabled or not aliveLocal() then break end
			if part.Parent then
				pcall(function()
					entitylib.character.RootPart.CFrame = CFrame.new(part.Position + Vector3.new(0, 1, 0))
				end)
				touchDrop(part)
				task.wait(0.07)
			end
		end
	end

	-- Teleport our character right next to an enemy: a few studs in front of its
	-- hitbox (so we're in melee range and facing it), lifted slightly so we don't
	-- clip into the model.
	local function teleportTo(ent)
		if not aliveLocal() then return end
		local part = ent.Character and (ent.Character:FindFirstChild('EnemyHitBox') or ent.RootPart)
		if not part then return end
		local root = entitylib.character.RootPart
		local offset = Offset and Offset.Value or 4
		local height = Height and Height.Value or 0
		-- stand `offset` studs toward the enemy from a tiny pull-back, facing it
		local goal = part.Position + Vector3.new(0, height, 0)
		local from = root.Position
		local dir = (goal - from)
		if dir.Magnitude > 0.1 then
			goal = goal - dir.Unit * offset
		end
		pcall(function()
			root.CFrame = CFrame.lookAt(goal, part.Position)
		end)
	end

	AutoFarm = vain.Categories.Combat:CreateModule({
		Name = 'AutoFarm',
		Function = function(callback)
			if callback then
				local home = aliveLocal() and entitylib.character.RootPart.CFrame or nil
				task.spawn(function()
					repeat
						local ent = nearestEnemy()
						if ent and aliveLocal() then
							-- teleport to the enemy and beat on it until it dies or
							-- despawns, then loop to the next nearest -- so we sweep
							-- through every enemy on the map.
							repeat
								teleportTo(ent)
								-- equip a weapon first if we're empty-handed, else the swing whiffs
								if AutoEquip.Enabled and not getEquippedTool() then equipBestWeapon() end
								attackEnemy(ent)
								if targetinfo and targetinfo.Targets then
									targetinfo.Targets[ent] = tick() + 0.5
								end
								task.wait(0.12)
							until not AutoFarm.Enabled
								or not ent.Character
								or not ent.Character.Parent
								or not ent.Humanoid
								or ent.Humanoid.Health <= 0
								or not aliveLocal()
							-- enemy just died: grab any loot it dropped
							sweepDrops()
						else
							-- no enemies right now: collect leftover drops, then idle
							sweepDrops()
							task.wait(0.2)
						end
					until not AutoFarm.Enabled
					-- optionally return to where we started once disabled
					if ReturnHome and ReturnHome.Enabled and home and aliveLocal() then
						pcall(function() entitylib.character.RootPart.CFrame = home end)
					end
				end)
			end
		end,
		Tooltip = 'Teleports from enemy to enemy, attacking each until it dies -- sweeps the whole map. WARNING: teleporting is detectable; this is for games/servers where that is acceptable.'
	})
	Offset = AutoFarm:CreateSlider({Name = 'TP Distance', Min = 0, Max = 20, Default = 4, Suffix = 'studs', Tooltip = 'How far in front of the enemy to land.'})
	Height = AutoFarm:CreateSlider({Name = 'TP Height', Min = -10, Max = 20, Default = 0, Suffix = 'studs', Tooltip = 'Vertical offset so you do not clip into the enemy.'})
	CollectDrops = AutoFarm:CreateToggle({Name = 'Collect Drops', Default = true, Tooltip = 'After each kill, teleport onto nearby loot / Tix / Mana Stars (EnemiesDrops) and force-touch them so they collect. On by default so you do not need the separate Auto Collect (which would fight AutoFarm for teleports).'})
	CollectHearts = AutoFarm:CreateToggle({Name = 'Collect Hearts', Default = true, Tooltip = 'Also grab nearby heart / health pickups (works even if Collect Drops is off).'})
	CollectShields = AutoFarm:CreateToggle({Name = 'Collect Shields', Default = true, Tooltip = 'Also grab nearby shield pickups (works even if Collect Drops is off).'})
	CollectMana = AutoFarm:CreateToggle({Name = 'Collect Mana', Default = true, Tooltip = 'Also grab nearby Mana Star pickups (works even if Collect Drops is off).'})
	DropRange = AutoFarm:CreateSlider({Name = 'Drop Range', Min = 20, Max = 500, Default = 200, Suffix = 'studs', Tooltip = 'Only collect drops within this range of you.'})
	ReturnHome = AutoFarm:CreateToggle({Name = 'Return On Disable', Tooltip = 'Teleport back to your start position when AutoFarm is turned off.'})
	AutoEquip = AutoFarm:CreateToggle({Name = 'Auto Equip', Default = true, Tooltip = 'If your hands are empty when about to attack, equip the best sword (or slot 1) first so the swing lands.'})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  TIX MAGNET  (collect every Tix on the map from any distance, no teleport)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoCollect
	local Tix, Hearts, Mana, Shields, Loot, Range, Interval, ReturnPos

	-- Classify a drop part by its name (+ its ancestor model name).
	local function kindOf(part)
		local n = part.Name:lower()
		local m = part:FindFirstAncestorWhichIsA('Model')
		if m then n = n .. ' ' .. m.Name:lower() end
		if n:find('tix') then return 'tix' end
		if n:find('heart') or n:find('health') or n:find('heal') then return 'heart' end
		if n:find('mana') or n:find('star') then return 'mana' end
		if n:find('shield') then return 'shield' end
		return 'loot'
	end
	local function wants(kind)
		return (kind == 'tix' and Tix.Enabled)
			or (kind == 'heart' and Hearts.Enabled)
			or (kind == 'mana' and Mana.Enabled)
			or (kind == 'shield' and Shields.Enabled)
			or (kind == 'loot' and Loot.Enabled)
	end

	-- Drops collect on touch but the server validates proximity (a no-teleport
	-- magnet can't work here), so briefly teleport onto each wanted drop, fire its
	-- pickup touch, then snap back to where we started.
	local function sweep()
		if not aliveLocal() then return end
		local root = entitylib.character.RootPart
		local home = root.CFrame
		local range = Range and Range.Value or 2000
		local moved = false
		for _, folder in collectibleFolders() do
			for _, obj in folder:GetDescendants() do
				if obj:IsA('BasePart') and obj.Parent
					and (obj.Position - home.Position).Magnitude <= range
					and wants(kindOf(obj)) then
					pcall(function()
						root.CFrame = CFrame.new(obj.Position)
						firetouchinterest(obj, root, 0)
						firetouchinterest(obj, root, 1)
						firetouchinterest(obj, root, 0)
					end)
					moved = true
					task.wait() -- one frame so the server registers the touch
					if not AutoCollect.Enabled or not aliveLocal() then return end
				end
			end
		end
		if moved and ReturnPos.Enabled and aliveLocal() then
			pcall(function() entitylib.character.RootPart.CFrame = home end)
		end
	end

	AutoCollect = vain.Categories.Utility:CreateModule({
		Name = 'Auto Collect',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						sweep()
						task.wait(Interval and Interval.Value or 0.15)
					until not AutoCollect.Enabled
				end)
			end
		end,
		Tooltip = 'Collects drops (Tix / Hearts / Mana / Shields / loot) by briefly teleporting onto each and firing its pickup touch, then snapping back. Pickups are proximity-validated, so collecting from a distance without moving is not possible here. WARNING: teleporting is detectable.'
	})
	Tix = AutoCollect:CreateToggle({Name = 'Tix', Default = true, Tooltip = 'Collect Tix.'})
	Hearts = AutoCollect:CreateToggle({Name = 'Hearts', Default = true, Tooltip = 'Collect Heart / health drops.'})
	Mana = AutoCollect:CreateToggle({Name = 'Mana', Default = true, Tooltip = 'Collect Mana Stars.'})
	Shields = AutoCollect:CreateToggle({Name = 'Shields', Default = true, Tooltip = 'Collect Shield drops.'})
	Loot = AutoCollect:CreateToggle({Name = 'Other Loot', Default = false, Tooltip = 'Collect any other drop type.'})
	Range = AutoCollect:CreateSlider({Name = 'Range', Min = 20, Max = 2000, Default = 2000, Suffix = 'studs', Tooltip = 'Only collect drops within this range (2000 = effectively the whole map).'})
	ReturnPos = AutoCollect:CreateToggle({Name = 'Return', Default = true, Tooltip = 'Snap back to your start position after a sweep so you do not drift around the map.'})
	Interval = AutoCollect:CreateSlider({Name = 'Interval', Min = 0.05, Max = 2, Default = 0.15, Decimal = 100, Suffix = 'sec', Tooltip = 'How often to sweep for drops.'})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  BOW AIMBOT  (lead the nearest enemy when firing a bow/ranged weapon)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local BowAimbot
	local Range, ProjectileSpeed, Gravity

	local rayCheck = RaycastParams.new()
	rayCheck.FilterType = Enum.RaycastFilterType.Exclude

	local function bestTarget()
		if not aliveLocal() then return nil end
		local myPos = entitylib.character.RootPart.Position
		local range = Range and Range.Value or 250
		local best, bestd = nil, math.huge
		for _, ent in entitylib.List do
			if ent.NPC and ent.Humanoid and ent.Humanoid.Health > 0 and ent.Character and ent.Character.Parent then
				local d = (ent.RootPart.Position - myPos).Magnitude
				if d <= range and d < bestd then best, bestd = ent, d end
			end
		end
		return best
	end

	-- Compute the lead point: where to aim so a projectile of `speed` under
	-- `gravity` intercepts the best target, using the shared ballistic solver.
	local function computeAimPoint()
		local ent = bestTarget()
		if not ent or not aliveLocal() then return nil, nil end
		local part = ent.Character:FindFirstChild('EnemyHitBox') or ent.RootPart
		local origin = entitylib.character.RootPart.Position
		rayCheck.FilterDescendantsInstances = {lplr.Character, ent.Character, gameCamera}
		local speed = ProjectileSpeed and ProjectileSpeed.Value or 150
		local grav = Gravity and Gravity.Value or workspace.Gravity
		local vel = part.AssemblyLinearVelocity
		if not vel or vel.Magnitude < 0.01 then vel = part.Velocity end
		local calc = prediction.SolveTrajectory(origin, speed, grav, part.Position, vel, workspace.Gravity, ent.HipHeight, nil, rayCheck)
		return (calc or part.Position), ent
	end

	-- The gears fire with InvokeServer("MouseClick", {Down=false, HeldTime=...,
	-- MousePosition=Vector3}). We only need to overwrite that MousePosition with
	-- our computed lead point (verified from the decompiled bow source). As a
	-- fallback we also swap any loose Vector3/CFrame arg, in case a gear differs.
	local function rewriteArgs(aim, ...)
		local args = {...}
		local n = select('#', ...)
		local changed = false
		for i = 1, n do
			local v = args[i]
			local t = typeof(v)
			if t == 'table' and v.MousePosition ~= nil then
				v.MousePosition = aim
				changed = true
			elseif not changed and t == 'Vector3' then
				args[i] = aim
				changed = true
			elseif not changed and t == 'CFrame' then
				args[i] = CFrame.lookAt(v.Position, aim)
				changed = true
			end
		end
		return table.unpack(args, 1, n)
	end

	-- Is `self` the ServerControl RemoteFunction of the tool we have equipped?
	-- RemoteFunction.InvokeServer is one shared C function, so we hook it ONCE
	-- globally and only rewrite when the call belongs to our equipped weapon.
	local function isEquippedServerControl(self)
		if typeof(self) ~= 'Instance' or not self:IsA('RemoteFunction') or self.Name ~= 'ServerControl' then
			return false
		end
		local tool = self.Parent
		return tool and tool:IsA('Tool') and tool.Parent == lplr.Character
	end

	local original
	local function installHook()
		if original then return end
		original = hookfunction(Instance.new('RemoteFunction').InvokeServer, function(self, ...)
			if BowAimbot.Enabled and isEquippedServerControl(self) then
				local aim = computeAimPoint()
				if aim then
					return original(self, rewriteArgs(aim, ...))
				end
			end
			return original(self, ...)
		end)
	end

	BowAimbot = vain.Categories.Combat:CreateModule({
		Name = 'Bow Aimbot',
		Function = function(callback)
			-- The global InvokeServer hook stays installed (its body is gated on
			-- BowAimbot.Enabled), so toggling just flips the flag -- no re-hooking.
			if callback then
				installHook()
			end
		end,
		Tooltip = 'Silently redirects your bow/projectile shots to a lead point computed by the ballistic solver -- hooks the weapon ServerControl and rewrites the aim, no camera/cursor movement.'
	})
	Range = BowAimbot:CreateSlider({Name = 'Range', Min = 20, Max = 600, Default = 250, Suffix = 'studs'})
	ProjectileSpeed = BowAimbot:CreateSlider({Name = 'Projectile Speed', Min = 50, Max = 500, Default = 150})
	Gravity = BowAimbot:CreateSlider({Name = 'Projectile Gravity', Min = 0, Max = 400, Default = math.floor(workspace.Gravity), Tooltip = 'Gravity of the projectile arc. 0 = straight line (no drop).'})

	-- restore the global InvokeServer hook when Vain unloads
	vain:Clean(function()
		if original then
			pcall(restorefunction, Instance.new('RemoteFunction').InvokeServer)
			original = nil
		end
	end)
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  NO ATTACK COOLDOWN  (zero the local weapon's attack cooldown values)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local NoCooldown
	local originals = {} -- [ValueObject] = original number

	local function fields(tool)
		local out = {}
		for _, name in {'AttackCooldown', 'Cooldown', 'DamageCooldown'} do
			local v = tool:FindFirstChild(name, true)
			if v and (v:IsA('NumberValue') or v:IsA('IntValue')) then
				table.insert(out, v)
			end
		end
		return out
	end

	NoCooldown = vain.Categories.Combat:CreateModule({
		Name = 'No Attack Cooldown',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local tool = getEquippedTool()
						if tool then
							for _, v in fields(tool) do
								if originals[v] == nil then originals[v] = v.Value end
								if v.Value ~= 0 then v.Value = 0 end
							end
						end
						task.wait(0.1)
					until not NoCooldown.Enabled
				end)
			else
				for v, val in originals do
					pcall(function() v.Value = val end)
				end
				table.clear(originals)
			end
		end,
		Tooltip = 'Zeroes your equipped weapon cooldown values locally for faster attacks. Server may still rate-limit; client-side only.'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO ABILITY  (spam a class ability key via the gear KeyPress action)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	-- Verified from the gear source: abilities fire via
	--   ServerControl:InvokeServer("KeyPress", {Down = bool, Key = <key>})
	-- so we replay a down+up KeyPress for the chosen ability key on a cycle.
	local AutoAbility
	local AbilityKey, Delay

	local KEYS = {
		Q = Enum.KeyCode.Q, E = Enum.KeyCode.E, R = Enum.KeyCode.R, F = Enum.KeyCode.F,
		Z = Enum.KeyCode.Z, X = Enum.KeyCode.X, C = Enum.KeyCode.C, V = Enum.KeyCode.V,
	}

	AutoAbility = vain.Categories.Combat:CreateModule({
		Name = 'Auto Ability',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local sc = getServerControl()
						local key = AbilityKey and KEYS[AbilityKey.Value] or Enum.KeyCode.Q
						if sc and aliveLocal() then
							pcall(function()
								sc:InvokeServer('KeyPress', {Down = true, Key = key})
								sc:InvokeServer('KeyPress', {Down = false, Key = key})
							end)
						end
						task.wait(Delay and Delay.Value or 1)
					until not AutoAbility.Enabled
				end)
			end
		end,
		Tooltip = 'Repeatedly triggers your equipped weapon ability key (fires the gear KeyPress action). Pick the key your class ability is bound to.'
	})
	AbilityKey = AutoAbility:CreateDropdown({Name = 'Ability Key', List = {'Q', 'E', 'R', 'F', 'Z', 'X', 'C', 'V'}, Default = 'Q'})
	Delay = AutoAbility:CreateSlider({Name = 'Delay', Min = 0.1, Max = 10, Default = 1, Decimal = 10, Suffix = 's'})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO DASH  (spam dash off cooldown -- movement help for kiting)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoDash
	-- Dash is usually a keypress (the place has a DashButton). We replay the dash
	-- input on an interval. If the game binds dash to Q by default this triggers it.
	AutoDash = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Dash',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						if aliveLocal() then
							pcall(function()
								-- fire the common dash keybinds via the input pipeline
								for _, key in {Enum.KeyCode.Q, Enum.KeyCode.LeftControl} do
									game:GetService('VirtualInputManager'):SendKeyEvent(true, key, false, game)
									game:GetService('VirtualInputManager'):SendKeyEvent(false, key, false, game)
								end
							end)
						end
						task.wait(0.6)
					until not AutoDash.Enabled
				end)
			end
		end,
		Tooltip = 'Repeatedly triggers your dash to kite enemies. Uses the dash keybind (Q / Ctrl).'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  ANTI HIT  (position desync -- enemies can't land hits on you)
-- ══════════════════════════════════════════════════════════════════════════════
-- The enemy AI / damage scripts are server-authoritative and resolve hits against
-- your *replicated* HumanoidRootPart position (proximity Magnitude + a raycast LoS
-- to your root, as seen in the player-class proximity logic). Because your own
-- character is network-owned by the client, we can replicate the root to a far-off
-- point each physics step, then snap it back locally before render. The server sees
-- you 500+ studs away -> every proximity/LoS check fails -> no hits land, while you
-- keep playing normally where you actually are.
run(function()
	local AntiHit
	local Distance, Direction
	local stepConn, heartConn
	local offsetActive   -- true while the root is currently sitting at the far point

	local DIRS = {
		['Up'] = Vector3.new(0, 1, 0),
		['Down'] = Vector3.new(0, -1, 0),
		['Forward'] = Vector3.new(0, 0, -1),
		['Sideways'] = Vector3.new(1, 0, 0),
	}

	local function rootPart()
		return aliveLocal() and entitylib.character.RootPart or nil
	end

	-- Ordering is what makes this work AND keeps you mobile:
	--   Heartbeat (post-physics): teleport the root to the far point. It replicates
	--     to the server in the gap before the next frame -> server sees you far away.
	--   Stepped  (pre-physics):   pull the root back to where it really is, BEFORE
	--     the Humanoid simulates movement. So the entire physics step runs at your
	--     real position -> walking, jumping, camera all behave normally.
	-- The root only sits at the far point during the brief replication window, never
	-- during simulation, so you never go airborne and never freeze.
	local function offsetCF()
		local dirName = Direction and Direction.Value or 'Up'
		local dist = Distance and Distance.Value or 500
		return (DIRS[dirName] or DIRS['Up']) * dist
	end

	-- expose to the attack bridge so swings resolve from your real position
	local function setActive(on)
		antihit.active = on
		if on then
			antihit.getReal = function()
				local root = rootPart()
				if not root then return nil end
				-- offset is a pure translation, so subtract it to get the real spot
				return offsetActive and (root.CFrame - offsetCF()) or root.CFrame
			end
			antihit.restore = function(real)
				local root = rootPart()
				if root and real then
					root.CFrame = real
					offsetActive = false
				end
			end
		else
			antihit.getReal = nil
			antihit.restore = nil
		end
	end

	AntiHit = vain.Categories.Blatant:CreateModule({
		Name = 'Anti Hit',
		Function = function(callback)
			if callback then
				offsetActive = false
				setActive(true)

				-- pull back to real position before the physics step simulates movement
				stepConn = runService.Stepped:Connect(function()
					local root = rootPart()
					if not root then return end
					if offsetActive then
						root.CFrame = root.CFrame - offsetCF()
						offsetActive = false
					end
				end)

				-- after physics, push out to the far point so the server sees us there.
				-- Only desync while a round is active -- in the shop enemies can't hurt
				-- you, so staying synced there avoids needless desync (and lets you
				-- shop/move normally). When the round ends mid-offset, the next Stepped
				-- has already pulled us back, so we simply stop pushing out.
				heartConn = runService.Heartbeat:Connect(function()
					local root = rootPart()
					if not root or offsetActive then return end
					if not inRound() then return end
					root.CFrame = root.CFrame + offsetCF()
					offsetActive = true
				end)

				vain:Clean(stepConn)
				vain:Clean(heartConn)
			else
				if stepConn then stepConn:Disconnect() stepConn = nil end
				if heartConn then heartConn:Disconnect() heartConn = nil end
				-- make sure we don't leave the root stranded at the far point
				local root = rootPart()
				if root and offsetActive then
					pcall(function() root.CFrame = root.CFrame - offsetCF() end)
				end
				offsetActive = false
				setActive(false)
			end
		end,
		Tooltip = 'Desyncs your replicated position so enemies cannot reach/hit you, while you keep playing and attacking normally. Only active during a round (auto-pauses in the shop). If you get rubber-banded or flagged, lower the distance.'
	})

	Distance = AntiHit:CreateSlider({
		Name = 'Distance',
		Min = 100,
		Max = 1000,
		Default = 500,
		Suffix = 'studs',
		Tooltip = 'How far away the server thinks you are. Higher = safer from AoE, but more visible desync.'
	})

	Direction = AntiHit:CreateDropdown({
		Name = 'Direction',
		List = {'Up', 'Down', 'Forward', 'Sideways'},
		Default = 'Up',
		Tooltip = 'Which way to push your replicated position. Up keeps you above the map and out of melee range.'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  FREEZE ENEMIES  (network-ownership anchor -- enemies can't move)
-- ══════════════════════════════════════════════════════════════════════════════
-- Enemy NPCs are unanchored Humanoid models with no explicit SetNetworkOwner call,
-- so Roblox auto-assigns physics ownership of each one to the *nearest player*.
-- When you're close, YOUR client simulates that enemy's physics, and the server
-- replicates whatever you simulate. So anchoring the enemy's root (or zeroing its
-- velocity) on your client freezes it server-side -- the basis of the old Hit Boxes
-- side effect, done deliberately and cleanly here.
run(function()
	local FreezeEnemies
	local Range, Mode, BossOnly
	local conn
	local frozen = {}   -- [BasePart] = original Anchored, so we can restore

	local function isBoss(ent)
		local n = (ent.Character and enemyName(ent.Character) or ''):lower()
		return n:find('boss') ~= nil
	end

	local function freezePart(part)
		if not part then return end
		if Mode and Mode.Value == 'Velocity Lock' then
			-- keep it owned + pinned without anchoring (some hits need it unanchored)
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		else
			if frozen[part] == nil then frozen[part] = part.Anchored end
			part.Anchored = true
		end
	end

	local function thaw(part)
		if part and frozen[part] ~= nil then
			pcall(function() part.Anchored = frozen[part] end)
		end
		frozen[part] = nil
	end

	local function thawAll()
		for part in frozen do
			thaw(part)
		end
		table.clear(frozen)
	end

	FreezeEnemies = vain.Categories.Blatant:CreateModule({
		Name = 'Freeze Enemies',
		Function = function(callback)
			if callback then
				conn = runService.Heartbeat:Connect(function()
					if not aliveLocal() then return end
					local myPos = entitylib.character.RootPart.Position
					local range = Range and Range.Value or 80
					-- track which parts are in range this frame so we can thaw the rest
					local stillFrozen = {}
					for _, ent in entitylib.List do
						if ent.NPC and ent.RootPart and ent.Humanoid and ent.Humanoid.Health > 0 then
							if BossOnly and BossOnly.Enabled and not isBoss(ent) then continue end
							if (ent.RootPart.Position - myPos).Magnitude <= range then
								freezePart(ent.RootPart)
								stillFrozen[ent.RootPart] = true
							end
						end
					end
					-- thaw anything anchored last frame that's now out of range / dead
					if not (Mode and Mode.Value == 'Velocity Lock') then
						for part in frozen do
							if not stillFrozen[part] then thaw(part) end
						end
					end
				end)
				vain:Clean(conn)
			else
				if conn then conn:Disconnect() conn = nil end
				thawAll()
			end
		end,
		Tooltip = 'Pins nearby enemies in place by anchoring the ones your client owns. They stop chasing and attacking, so you can farm them freely.'
	})

	Range = FreezeEnemies:CreateSlider({
		Name = 'Range',
		Min = 20,
		Max = 300,
		Default = 80,
		Suffix = 'studs',
		Tooltip = 'Only freeze enemies within this distance (you must be near enough to own their physics).'
	})
	Mode = FreezeEnemies:CreateDropdown({
		Name = 'Mode',
		List = {'Anchor', 'Velocity Lock'},
		Default = 'Anchor',
		Tooltip = 'Anchor = fully pinned (most reliable). Velocity Lock = keeps them unanchored but stationary, in case a hitbox needs unanchored parts.'
	})
	BossOnly = FreezeEnemies:CreateToggle({
		Name = 'Bosses Only',
		Tooltip = 'Only freeze bosses (leave trash mobs free to be farmed normally).'
	})

	-- safety: restore anything we anchored if our character dies/respawns
	vain:Clean(entitylib.Events.EntityRemoved:Connect(function(ent)
		if ent.RootPart then thaw(ent.RootPart) end
	end))
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  ANTI AFK  (stay connected during long farms)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AntiAFK
	local conn
	AntiAFK = vain.Categories.Utility:CreateModule({
		Name = 'Anti AFK',
		Function = function(callback)
			if callback then
				conn = lplr.Idled:Connect(function()
					pcall(function()
						local vu = game:GetService('VirtualUser')
						vu:CaptureController()
						vu:ClickButton2(Vector2.new())
					end)
				end)
				vain:Clean(conn)
			elseif conn then
				conn:Disconnect()
				conn = nil
			end
		end,
		Tooltip = 'Prevents the 20-minute AFK kick so long auto-farms keep running.'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO BUY  (purchase shop items automatically, fully filtered)
-- ══════════════════════════════════════════════════════════════════════════════
-- On entering the shop, scan every buyable item and trigger its ProximityPrompt
-- for the ones that pass your filters (category, name whitelist, price cap, Tix
-- reserve), in your chosen price order, stopping when you can't afford more.
run(function()
	local AutoBuy
	local BuyEverything, BuyGears, BuyAccessories, BuySacrifices
	local Whitelist, ItemPicker, MaxPrice, Reserve, Order, BuyDelay
	local lastInShop = false
	local busy = false

	local catToggle = {}   -- filled after toggles exist

	-- Build a de-duplicated, sorted list of EVERY catalog item (from
	-- ReplicatedStorage), with icons, and push it into the Item Picker. This shows
	-- all buyable items regardless of what's stocked in the current shop; Auto Buy
	-- then purchases whitelisted items whenever they appear in the shop.
	local function refreshPicker(announce)
		if not ItemPicker then return end
		local seen, names, icons, descs = {}, {}, {}, {}
		forEachCatalogItem(function(item)
			local nm = item.Name
			if nm and nm ~= '' and not seen[nm] then
				seen[nm] = true
				table.insert(names, nm)
				local ok, ic = pcall(itemIcon, item)   -- never let one odd item abort the load
				if ok and ic then icons[nm] = ic end
				local okd, d = pcall(itemDescription, item)
				if okd and d then descs[nm] = d end
			end
		end)
		table.sort(names)
		if #names == 0 then
			ItemPicker:Change({'(item catalog not found)'}, {})
			if announce then notif('Auto Buy', 'Could not find the item catalog in ReplicatedStorage.') end
		else
			ItemPicker:Change(names, icons, descs)   -- args: names, per-item icons, per-item hover tooltips
			if announce then notif('Auto Buy', ('Loaded %d items.'):format(#names)) end
		end
	end

	-- build a lowercase lookup from the whitelist entries
	-- normalize a name for matching: lowercase, strip everything but a-z0-9 so
	-- "Bear Trap", "BearTrap" and "bear-trap" all compare equal
	local function norm(s)
		return tostring(s):lower():gsub('[^%a%d]', '')
	end

	local function whitelistSet()
		local set, any = {}, false
		local list = Whitelist and Whitelist.ListEnabled or {}
		for _, word in list do
			local w = norm(word)
			if w ~= '' then set[w] = true any = true end
		end
		return set, any
	end

	-- every identity string the shop item might expose, normalized
	local function itemNames(item)
		local out = {}
		local function add(s) if s and s ~= '' then out[#out + 1] = norm(s) end end
		add(item.Name)
		add(itemName(item))
		local tool = item:FindFirstChildWhichIsA('Tool', true)
		if tool then add(tool.Name) end
		local attr = item:GetAttribute('ItemName')
		if type(attr) == 'string' then add(attr) end
		return out
	end

	local function wanted(item, category)
		-- Buy Everything overrides all filters (still bound by Max Price / Reserve)
		if BuyEverything and BuyEverything.Enabled then return true end
		-- Explicit whitelist WINS over the category toggles: if you picked an item,
		-- buy it regardless of whether its category is enabled (that was the bug --
		-- a whitelisted accessory got rejected because the Accessories category was
		-- off). Match each entry against every identity the item exposes, both ways.
		local set, hasList = whitelistSet()
		if hasList then
			for _, nm in itemNames(item) do
				for w in set do
					if nm == w or nm:find(w, 1, true) or w:find(nm, 1, true) then
						return true
					end
				end
			end
			return false
		end
		-- No whitelist: fall back to the category toggles.
		local tog = catToggle[category]
		if tog and not tog.Enabled then return false end
		return true
	end

	local function runBuy()
		if busy then return end
		busy = true
		local ok = pcall(function()
			local cap = MaxPrice and MaxPrice.Value or 0          -- 0 = no per-item cap
			local reserve = Reserve and Reserve.Value or 0
			local order = Order and Order.Value or 'Cheapest first'

			-- collect eligible items with their prices
			local list = {}
			forEachShopItem(function(item, category, prompt)
				if wanted(item, category) then
					local price = itemPrice(item)
					if cap == 0 or price <= cap then
						table.insert(list, {item = item, prompt = prompt, price = price})
					end
				end
			end)

			-- order by price preference
			table.sort(list, function(a, b)
				if order == 'Expensive first' then return a.price > b.price end
				return a.price < b.price
			end)

			-- Where we stand in the shop; we snap back here after each buy so we
			-- don't drift around (the TP onto an item is what makes the buy land).
			local shopHome = aliveLocal() and entitylib.character.RootPart.CFrame or nil
			for _, entry in list do
				if not AutoBuy.Enabled or not inShop() then break end
				if getTix() - entry.price < reserve then
					-- can't afford while keeping the reserve; with cheapest-first this
					-- means nothing else fits either
					if order ~= 'Expensive first' then break end
				else
					-- TP onto the item so the prompt's server-side distance check
					-- passes (it won't trigger from across the shop), fire it, return.
					pcall(function()
						local p = entry.prompt.Parent
						local pos = p and (p:IsA('BasePart') and p.Position
							or p:IsA('Attachment') and p.WorldPosition)
							or (entry.item:IsA('Model') and entry.item:GetPivot().Position)
							or (entry.item:IsA('BasePart') and entry.item.Position)
						if pos and aliveLocal() then
							entitylib.character.RootPart.CFrame = CFrame.new(pos)
						end
					end)
					task.wait()
					-- Accessory prompts sit on the item Model (not a part), and the
					-- executor's fireproximityprompt no-ops on those while it works for
					-- weapons. The native InputHoldBegin/End -- exactly what pressing the
					-- prompt key does -- triggers both. Ungate Enabled / line of sight
					-- first (separate pcalls so a locked prop can't block the trigger).
					pcall(function() entry.prompt.Enabled = true end)
					pcall(function() entry.prompt.RequiresLineOfSight = false end)
					pcall(function()
						local prompt = entry.prompt
						prompt:InputHoldBegin()
						task.wait((prompt.HoldDuration or 0) + 0.05)
						prompt:InputHoldEnd()
					end)
					task.wait(BuyDelay and BuyDelay.Value or 0.3)
					if shopHome and aliveLocal() then
						pcall(function() entitylib.character.RootPart.CFrame = shopHome end)
					end
				end
			end
		end)
		busy = false
		return ok
	end

	AutoBuy = vain.Categories.Utility:CreateModule({
		Name = 'Auto Buy',
		Function = function(callback)
			if callback then
				lastInShop = inShop()
				-- populate the full item catalog now (it's always available), and
				-- buy immediately if we're already in the shop
				task.spawn(refreshPicker)
				if lastInShop then task.spawn(runBuy) end
				AutoBuy:Clean(runService.Heartbeat:Connect(function()
					local now = inShop()
					if now and not lastInShop then
						task.spawn(runBuy)   -- just entered the shop, buy what's stocked
					end
					lastInShop = now
				end))
			end
		end,
		Tooltip = 'Buys whitelisted/enabled-category items whenever they appear in the shop. The Item Picker lists every item in the game - tick the ones you want and Auto Buy grabs them as soon as they are stocked and affordable.'
	})

	BuyEverything = AutoBuy:CreateToggle({Name = 'Buy Everything', Tooltip = 'Buy every item in the shop, ignoring the category toggles and whitelist. Still respects Max Price and Keep Reserve.'})
	BuyGears = AutoBuy:CreateToggle({Name = 'Buy Gears', Default = true, Tooltip = 'Buy items from the Gears shelf.'})
	BuyAccessories = AutoBuy:CreateToggle({Name = 'Buy Accessories', Tooltip = 'Buy items from the Accessories shelf.'})
	BuySacrifices = AutoBuy:CreateToggle({Name = 'Buy Sacrifices', Tooltip = 'Buy items from the Sacrifices shelf.'})
	catToggle = {Gears = BuyGears, Accessories = BuyAccessories, Sacrifices = BuySacrifices}

	Whitelist = AutoBuy:CreateTextList({
		Name = 'Name Whitelist',
		Placeholder = 'item name',
		Tooltip = 'Item names to buy (one per entry, partial match, case-insensitive). Leave empty to buy everything in the enabled categories. Use the Item Picker below to fill this without typing.'
	})
	ItemPicker = AutoBuy:CreateDropdown({
		Name = 'Item Picker',
		List = {'(loading items...)'},
		Function = function(name, mouse)
			-- only react to actual clicks, and skip the placeholder entry
			if not mouse or not name or name:sub(1, 1) == '(' then return end
			if Whitelist then
				Whitelist:ChangeValue(name)   -- toggles the name in/out of the whitelist
				local present = table.find(Whitelist.ListEnabled, name) ~= nil
				notif('Auto Buy', (present and 'Added "%s" to whitelist.' or 'Removed "%s" from whitelist.'):format(name))
			end
		end,
		Tooltip = 'Every item in the game, with its icon. Click one to toggle it in the whitelist - Auto Buy will grab it whenever it shows up in the shop. No need to be in the shop.'
	})
	AutoBuy:CreateButton({
		Name = 'Refresh Items',
		Function = function()
			refreshPicker(true)
		end,
		Tooltip = 'Reload the full item catalog into the Item Picker.'
	})
	MaxPrice = AutoBuy:CreateSlider({
		Name = 'Max Price',
		Min = 0,
		Max = 5000,
		Default = 0,
		Suffix = 'Tix',
		Tooltip = 'Never buy a single item priced above this. 0 = no cap.'
	})
	Reserve = AutoBuy:CreateSlider({
		Name = 'Keep Reserve',
		Min = 0,
		Max = 5000,
		Default = 0,
		Suffix = 'Tix',
		Tooltip = 'Always keep at least this many Tix unspent.'
	})
	Order = AutoBuy:CreateDropdown({
		Name = 'Priority',
		List = {'Cheapest first', 'Expensive first'},
		Default = 'Cheapest first',
		Tooltip = 'When funds are limited: buy more cheap items, or fewer expensive ones first.'
	})
	BuyDelay = AutoBuy:CreateSlider({
		Name = 'Buy Delay',
		Min = 0.05,
		Max = 2,
		Default = 0.3,
		Decimal = 100,
		Suffix = 's',
		Tooltip = 'Delay between purchases (give the server time to register each buy).'
	})
	AutoBuy:CreateButton({
		Name = 'List Shop Items',
		Function = function()
			if not inShop() then
				notif('Auto Buy', 'Open the shop first, then press this.')
				return
			end
			local found = {}
			forEachShopItem(function(item, category)
				found[#found + 1] = ('%s [%s] %dt'):format(item.Name, category, itemPrice(item))
			end)
			if #found == 0 then
				notif('Auto Buy', 'No buyable shop items detected.')
			else
				notif('Auto Buy', table.concat(found, '\n'), 12)
			end
		end,
		Tooltip = 'While in the shop, list the exact name/category/price of each stocked item, so you can match the whitelist to what the shop really calls them.'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO READY  (click the ready button to start the next round)
-- ══════════════════════════════════════════════════════════════════════════════
-- The next wave starts when players ready up via the PlayersReady button in the
-- spawn zone (a part with a ClickDetector). Auto Ready fires that ClickDetector
-- as soon as you're in the shop so rounds start without manual input.
run(function()
	local AutoReady
	local ReadyDelay
	local lastInShop = false

	-- Readying up is NOT a clickable part - the "PlayersReady" instance is just a
	-- TextLabel. The real ready signal is the client firing RemoteEventStart with
	-- no arguments (confirmed from the decompiled shop UI: it does
	-- RemoteEventStart:FireServer() and waits on its OnClientEvent). So we fire
	-- that remote directly.
	-- Readying up is a ClickDetector on the "Ready" button in the shop zone -- NOT
	-- a remote (RemoteEventStart is an unrelated minigame, which is why firing it
	-- never worked). Find the ClickDetector whose part/ancestor is named like the
	-- ready button and click it with fireclickdetector. Only 12 ClickDetectors in
	-- the whole place, so the name match is reliable.
	local readyClick
	local function findReadyClick()
		if readyClick and readyClick.Parent then return readyClick end
		for _, d in workspace:GetDescendants() do
			if d:IsA('ClickDetector') then
				local hay, node = '', d
				for _ = 1, 4 do
					node = node.Parent
					if not node then break end
					hay = hay .. ' ' .. node.Name:lower()
				end
				if hay:find('startround') or hay:find('playersready') or hay:find('readyup') or hay:find('ready') then
					readyClick = d
					return d
				end
			end
		end
		return nil
	end

	local function pressReady()
		local d = findReadyClick()
		if not (d and fireclickdetector) then return false end
		-- ClickDetectors are distance-validated, so teleport onto the ready button
		-- (its part) before clicking, then snap back.
		local home, part = nil, d.Parent
		if part and part:IsA('BasePart') and aliveLocal() then
			home = entitylib.character.RootPart.CFrame
			pcall(function() entitylib.character.RootPart.CFrame = CFrame.new(part.Position) end)
			task.wait()
		end
		-- try the common signatures; the first that doesn't error wins
		local ok = pcall(fireclickdetector, d) or pcall(fireclickdetector, d, 0) or pcall(fireclickdetector, d, 50, 'MouseClick')
		if home and aliveLocal() then
			pcall(function() entitylib.character.RootPart.CFrame = home end)
		end
		return ok
	end

	AutoReady = vain.Categories.Utility:CreateModule({
		Name = 'Auto Ready',
		Function = function(callback)
			if callback then
				-- Diagnostics: surface exactly which dependency is missing.
				if not fireclickdetector then
					notif('Auto Ready', 'Your executor lacks fireclickdetector -- cannot click the Ready button.', 8, 'alert')
				elseif not findReadyClick() then
					notif('Auto Ready', 'Could not find the Ready ClickDetector (not in the shop yet?). It will keep looking.', 6, 'warning')
				elseif not replicatedStorage:FindFirstChild('IsInShop') then
					notif('Auto Ready', 'Shop flag (IsInShop) not found -- cannot detect the shop, so it will not auto-fire.', 8, 'warning')
				end
				lastInShop = inShop()
				local readiedThisShop = false
				local enteredAt = lastInShop and tick() or 0
				local lastTry = 0

				-- Keep trying to click Ready until it actually registers. The StartRound
				-- button streams in a moment after you (re-)enter the shop, so a single
				-- attempt on entry can miss; we retry until pressReady succeeds and only
				-- then mark this shop visit done. Respects the configured delay.
				local function tryReady()
					if readiedThisShop or not AutoReady.Enabled or not inShop() then return end
					if tick() - enteredAt < (ReadyDelay and ReadyDelay.Value or 0) then return end
					if tick() - lastTry < 0.4 then return end
					lastTry = tick()
					if pressReady() then readiedThisShop = true end
				end

				AutoReady:Clean(runService.Heartbeat:Connect(function()
					local now = inShop()
					if now ~= lastInShop then
						-- entered or left the shop: reset, and drop the cached button --
						-- it's recreated each shop visit, so a stale cache would mis-click.
						readiedThisShop = false
						readyClick = nil
						if now then enteredAt = tick() end
					end
					lastInShop = now
					if now then tryReady() end
				end))
			end
		end,
		Tooltip = 'Automatically readies up when you enter the shop to start the next round (TPs to and clicks the Ready button). Retries until it registers, every shop visit. Pairs with Auto Buy - raise the delay to let buys finish first.'
	})

	ReadyDelay = AutoReady:CreateSlider({
		Name = 'Delay',
		Min = 0,
		Max = 30,
		Default = 0,
		Suffix = 's',
		Tooltip = 'Seconds to wait in the shop before readying up. Raise this if you want Auto Buy / manual shopping to finish first.'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  KILL FEED  (on-screen feed when you kill an NPC)
-- ══════════════════════════════════════════════════════════════════════════════
-- Shows a small stacked feed in the corner each time an enemy you damaged dies.
-- We attribute the kill via the lastAttacked stamp set in attackEnemy: if the
-- enemy died (or was removed at <=0 HP) shortly after we swung at it, it's ours.
run(function()
	local KillFeed
	local OnlyMine, ShowBosses, FeedTime
	local gui, holder
	local total = 0

	local function ensureGui()
		if gui and gui.Parent then return end
		gui = Instance.new('ScreenGui')
		gui.Name = 'VainKillFeed'
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 9999
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		local parent = (gethui and gethui()) or (cloneref(game:GetService('CoreGui')))
		gui.Parent = parent

		holder = Instance.new('Frame')
		holder.Name = 'Holder'
		holder.BackgroundTransparency = 1
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.new(1, -16, 0.42, 0)
		holder.Size = UDim2.fromOffset(300, 400)
		holder.Parent = gui
		local layout = Instance.new('UIListLayout')
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding = UDim.new(0, 4)
		layout.Parent = holder
	end

	-- pull a vape GUI accent color if one is exposed, else a default
	local function accent()
		local ok, c = pcall(function() return vain.GUIColor and Color3.fromHSV(vain.GUIColor.Hue, vain.GUIColor.Sat, vain.GUIColor.Value) end)
		if ok and typeof(c) == 'Color3' then return c end
		return Color3.fromRGB(120, 220, 160)
	end

	-- RichText is on, so escape any markup characters in the enemy name
	local function escapeRich(s)
		s = tostring(s)
		s = s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
		return s
	end

	local function pushEntry(name, boss)
		ensureGui()
		total += 1
		name = escapeRich(name)

		local row = Instance.new('Frame')
		row.Name = 'Kill'
		row.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
		row.BackgroundTransparency = 0.25
		row.BorderSizePixel = 0
		row.Size = UDim2.fromOffset(10, 26)
		row.AutomaticSize = Enum.AutomaticSize.X
		row.LayoutOrder = -total   -- newest on top
		row.Parent = holder
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = row
		local stroke = Instance.new('UIStroke')
		stroke.Color = boss and Color3.fromRGB(255, 70, 70) or accent()
		stroke.Transparency = 0.2
		stroke.Thickness = 1
		stroke.Parent = row
		local pad = Instance.new('UIPadding')
		pad.PaddingLeft = UDim.new(0, 10)
		pad.PaddingRight = UDim.new(0, 10)
		pad.Parent = row

		local label = Instance.new('TextLabel')
		label.BackgroundTransparency = 1
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.fromOffset(0, 26)
		label.Font = Enum.Font.GothamMedium
		label.TextSize = 14
		label.TextColor3 = Color3.fromRGB(235, 235, 240)
		label.TextXAlignment = Enum.TextXAlignment.Right
		label.RichText = true
		local tint = boss and 'rgb(255,90,90)' or 'rgb(150,235,180)'
		label.Text = ('<font color="rgb(180,180,190)">Killed</font>  <font color="%s"><b>%s</b></font>%s')
			:format(tint, name, boss and '  <font color="rgb(255,140,60)">[BOSS]</font>' or '')
		label.Parent = row

		-- fade in
		row.BackgroundTransparency = 1
		label.TextTransparency = 1
		stroke.Transparency = 1
		tweenService:Create(row, TweenInfo.new(0.15), {BackgroundTransparency = 0.25}):Play()
		tweenService:Create(label, TweenInfo.new(0.15), {TextTransparency = 0}):Play()
		tweenService:Create(stroke, TweenInfo.new(0.15), {Transparency = 0.2}):Play()

		-- schedule fade out + cleanup
		local life = (FeedTime and FeedTime.Value) or 4
		task.delay(life, function()
			if not row.Parent then return end
			tweenService:Create(row, TweenInfo.new(0.4), {BackgroundTransparency = 1}):Play()
			tweenService:Create(label, TweenInfo.new(0.4), {TextTransparency = 1}):Play()
			tweenService:Create(stroke, TweenInfo.new(0.4), {Transparency = 1}):Play()
			task.wait(0.45)
			pcall(function() row:Destroy() end)
		end)
	end

	local function isBossEnt(ent)
		return ent.Character and (ent.Character:FindFirstChild('Boss', true) ~= nil
			or ent.Character:GetAttribute('Boss') == true)
	end

	local function onEnemyDead(ent)
		if not KillFeed.Enabled then return end
		if not (ent.NPC and ent.Character) then return end
		local boss = isBossEnt(ent)
		if ShowBosses and ShowBosses.Enabled and not boss then return end
		if OnlyMine and OnlyMine.Enabled then
			local t = lastAttacked[ent.Character]
			if not t or (tick() - t) > 4 then return end   -- not a recent kill of ours
		end
		pushEntry(ent.Character.Name, boss)
	end

	KillFeed = vain.Categories.Render:CreateModule({
		Name = 'Kill Feed',
		Function = function(callback)
			if callback then
				total = 0
				local counted = setmetatable({}, {__mode = 'k'})   -- guard one feed per enemy
				local function fire(ent)
					if ent.Character and counted[ent.Character] then return end
					if ent.Character then counted[ent.Character] = true end
					onEnemyDead(ent)
				end
				-- enemy removed from the folder at <=0 HP = a kill
				KillFeed:Clean(entitylib.Events.EntityRemoved:Connect(function(ent)
					if ent.Humanoid and ent.Humanoid.Health <= 0 then
						fire(ent)
					end
				end))
				-- also catch deaths where the model lingers a moment before removal
				local function hookDeath(ent)
					if ent.NPC and ent.Humanoid then
						local conn
						conn = ent.Humanoid.Died:Connect(function()
							fire(ent)
							if conn then conn:Disconnect() end
						end)
					end
				end
				KillFeed:Clean(entitylib.Events.EntityAdded:Connect(hookDeath))
				for _, ent in entitylib.List do hookDeath(ent) end
			else
				if gui then pcall(function() gui:Destroy() end) end
				gui, holder = nil, nil
			end
		end,
		Tooltip = 'Shows an on-screen feed each time you kill an NPC. Toggle "Only My Kills" to filter out enemies that died to allies or environment.'
	})

	OnlyMine = KillFeed:CreateToggle({
		Name = 'Only My Kills',
		Default = true,
		Tooltip = 'Only show enemies you damaged within the last few seconds (filters ally/AoE/environment kills).'
	})
	ShowBosses = KillFeed:CreateToggle({
		Name = 'Bosses Only',
		Tooltip = 'Only feed boss kills.'
	})
	FeedTime = KillFeed:CreateSlider({
		Name = 'Display Time',
		Min = 1,
		Max = 15,
		Default = 4,
		Suffix = 's',
		Tooltip = 'How long each kill entry stays on screen.'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  LOOT / SESSION TRACKER
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local kills = sessioninfo:AddItem('Enemies Killed', 0)
	local seen = {}

	-- Count enemies that disappear after dropping to 0 health while we're nearby.
	vain:Clean(entitylib.Events.EntityRemoved:Connect(function(ent)
		if ent.NPC and ent.Humanoid and ent.Humanoid.Health <= 0 then
			if aliveLocal() then
				kills:Increment(1)
			end
		end
	end))
end)

-- ── Remove universal modules that don't apply to this RPG ──────────────────────
run(function()
	for _, name in {'Reach', 'TriggerBot', 'HitBoxes', 'Killaura', 'MurderMystery', 'AntiFall'} do
		if vain.Modules[name] then
			vain:Remove(name)
		end
	end
end)

vain:Clean(function()
	for _, v in vapeEvents do
		pcall(function() v:Destroy() end)
	end
	table.clear(vapeEvents)
end)
