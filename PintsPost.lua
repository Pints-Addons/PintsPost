-- Pint's Postal: a better mailbox.
--   Contacts   - a book button by the To: box (your alts, recently mailed, friends, guild) and name autocomplete
--   Open All   - opens every mail of the kinds you choose (auction mail by type, other mail with money/items)
--   Select     - tick boxes on the inbox with Open / Return buttons (Shift-click a box: range, Ctrl-click: same sender)
--   Express    - Shift-click a mail: take everything  Ctrl-click: return it  Alt-click a bag item: attach it
--   Expiry     - an icon on each mail: will it come back to you or be deleted? Click it to do that now
--   Copy       - copy a mail's text;  Forward - send a mail (and its items) on to someone else
--   Quick Attach - buttons that attach all your cloth, leather, herbs, ore/bars, enchanting mats, elemental mats
--   Money subject - the subject fills in with the gold amount if you leave it blank
--   Trade block - trades and charter requests are turned away while the mailbox is open
--   Takings     - how much gold the mailbox gave you, printed when you close it
-- Settings: the gear button at the top right of the mailbox, or /post.
local ADDON = ...
-- coins drawn with the money icons (WoW Forever's own coin text came out as bare digits: 6s 64c showed as "664")
local GetCoinTextureString = function(v)
	v = math.floor((tonumber(v) or 0) + 0.5)
	local neg = v < 0; if neg then v = -v end
	local g, s, c = math.floor(v / 10000), math.floor(v / 100) % 100, v % 100
	local out = {}
	if g > 0 then out[#out + 1] = g .. "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t" end
	if s > 0 then out[#out + 1] = s .. "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t" end
	if c > 0 or #out == 0 then out[#out + 1] = c .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t" end
	return (neg and "-" or "") .. table.concat(out, " ")
end
-- Compatibility: WoW Forever runs on the modern game client, where these older functions moved or were renamed.
local IsAddOnLoaded = IsAddOnLoaded or (C_AddOns and C_AddOns.IsAddOnLoaded)

local PM = {}
_G.PintsPost = PM

local DEFAULTS = {
	contacts = true, autocomplete = true, autofill = false, useAlts = true, useRecent = true, useFriends = true, useGuild = true,
	openAll = true, select = true, express = true, expiry = true, copy = true, forward = true, quick = true,
	wire = true, tradeBlock = false, rake = true,
	keepFree = 1, speed = 0.5,
	f_cancelled = true, f_expired = true, f_outbid = true, f_success = true, f_won = true, f_other = true,
	recent = {}, alts = {}, quickTo = {},
}
local db
local function Print(msg) print("|cffd4a017Pint's Postal:|r " .. msg) end
local REALM, FACTION, ME
local function Key() return REALM .. "-" .. (FACTION or "?") end

---------------------------------------------------------------- bags
local function Container() return C_Container or _G end
local function NumSlots(bag) return (C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots)(bag) or 0 end
local function ItemAt(bag, slot)
	if C_Container and C_Container.GetContainerItemInfo then
		local i = C_Container.GetContainerItemInfo(bag, slot)
		if i then return i.itemID, i.hyperlink, i.isLocked, i.stackCount end
		return
	end
	local _, count, locked, _, _, _, link, _, _, id = GetContainerItemInfo(bag, slot)
	return id, link, locked, count
end
local function FreeSlots()
	local n = 0
	for bag = 0, 4 do
		local free, kind = (C_Container and C_Container.GetContainerNumFreeSlots or GetContainerNumFreeSlots)(bag)
		if free and (kind == 0 or kind == nil) then n = n + free end
	end
	return n
end
local function Pickup(bag, slot) (C_Container and C_Container.PickupContainerItem or PickupContainerItem)(bag, slot) end

-- attach one bag slot to the outgoing mail (first free attachment slot)
local function Attach(bag, slot)
	local max = ATTACHMENTS_MAX_SEND or 12
	for i = 1, max do
		if not GetSendMailItem(i) then
			ClearCursor()
			Pickup(bag, slot)
			ClickSendMailItemButton(i)
			ClearCursor()
			return true
		end
	end
	return false
end

---------------------------------------------------------------- mail API (looked up when used, in case the game moved it)
local function API(name)
	local f = _G[name] or (C_Mail and C_Mail[name])
	if not f and not PM["warned" .. name] then
		PM["warned" .. name] = true
		PM.Diagnose(name)
	end
	return f
end
-- list every mail-looking function the game has, and save it so it can be read after a /reload
function PM.Diagnose(missing)
	local have = {}
	for k, v in pairs(_G) do
		if type(k) == "string" and type(v) == "function" and (k:find("Inbox") or k:find("Mail")) and not k:find("^Pints") then have[#have + 1] = k end
	end
	for _, ns in ipairs({ "C_Mail", "C_MailInbox", "C_Inbox" }) do
		if type(_G[ns]) == "table" then for k in pairs(_G[ns]) do have[#have + 1] = ns .. "." .. k end end
	end
	table.sort(have)
	if db then db.apiDump = have end
	print("|cffd4a017Pint's Postal:|r " .. (missing and ("this game has no " .. missing .. ". ") or "") .. #have .. " mail functions found and saved - /reload once, then tell Claude.")
end
-- this game calls it GetInboxHeaderInfo (older ones GetInboxHeader); it may hand back a table instead of a list,
-- so both are turned into the classic order:
-- packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft, itemCount, wasRead, wasReturned, textCreated, canReply, isGM
local function Pick(t, ...) for _, k in ipairs({ ... }) do if t[k] ~= nil then return t[k] end end end
local function Header(i)
	local f = _G.GetInboxHeader or _G.GetInboxHeaderInfo or API("GetInboxHeader")
	if not f then return end
	local a, b, c, d, e, g, h, j, k, l, m, n, o = f(i)
	if type(a) ~= "table" then return a, b, c, d, e, g, h, j, k, l, m, n, o end
	local t = a
	if db and not db.headerKeys then local keys = {}; for key in pairs(t) do keys[#keys + 1] = key end; table.sort(keys); db.headerKeys = keys end
	return Pick(t, "packageIcon", "packageID"), Pick(t, "stationeryIcon", "stationeryID"), Pick(t, "sender", "senderName"),
		Pick(t, "subject"), Pick(t, "money", "moneyAmount") or 0, Pick(t, "CODAmount", "codAmount", "cod") or 0, Pick(t, "daysLeft"),
		Pick(t, "itemCount", "numItems", "hasItem") or 0, Pick(t, "wasRead"), Pick(t, "wasReturned"), Pick(t, "textCreated"),
		Pick(t, "canReply"), Pick(t, "isGM")
end
local function NumItems() local f = API("GetInboxNumItems"); if f then return f() end return 0, 0 end

---------------------------------------------------------------- mail kinds
local function SubjectPattern(fmt)
	if not fmt then return nil end
	return "^" .. fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
end
local AH
local function AHKinds()
	if AH then return AH end
	AH = {
		{ "cancelled", SubjectPattern(AUCTION_REMOVED_MAIL_SUBJECT) },
		{ "expired", SubjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT) },
		{ "outbid", SubjectPattern(AUCTION_OUTBID_MAIL_SUBJECT) },
		{ "success", SubjectPattern(AUCTION_SOLD_MAIL_SUBJECT) },
		{ "won", SubjectPattern(AUCTION_WON_MAIL_SUBJECT) },
	}
	return AH
end
-- what kind of mail is at an index: an auction kind, "other" (money or items from anyone else) or nil (nothing to take)
local function Kind(i)
	local _, _, _, subject, money, cod, _, itemCount = Header(i)
	if (cod or 0) > 0 then return nil end
	if (money or 0) == 0 and (itemCount or 0) == 0 then return nil end
	for _, k in ipairs(AHKinds()) do if k[2] and subject and subject:match(k[2]) then return k[1] end end
	return "other"
end

---------------------------------------------------------------- the opener (used by Open All and Select)
local queue, running, onDone = {}, false, nil
local ids = {}             -- queue index -> which mail it was (sender, subject, days left) when it was queued
-- A mail emptied of its money and items is deleted, and every mail after it moves up one place: the place we were
-- working on then holds the NEXT mail. Shift-clicking one mail kept going through all the ones after it. So each
-- place remembers which mail it was, and a different mail there means that one is done.
local function MailID(i)
	local _, _, sender, subject, _, _, days = Header(i)
	return (sender or "?") .. "\1" .. (subject or "?"), days
end
local function SameMail(i, want)
	if not want then return true end
	local k, days = MailID(i)
	return k == want[1] and math.abs((days or 0) - (want[2] or 0)) < 0.0005
end
local skippedFull = 0
local startMoney
local function Pop() ids[#queue] = nil; table.remove(queue) end
local function Stop(msg)
	running = false
	wipe(queue)
	if PM.openBtn then PM.openBtn:SetText("Open All") end
	if msg then Print(msg) end
	if onDone then local f = onDone; onDone = nil; f() end
end
local Step
local function Next() C_Timer.After(db.speed or 0.4, Step) end
function Step()
	if not running then return end
	if not (MailFrame and MailFrame:IsShown()) then Stop(); return end
	local i = queue[#queue]
	if not i then
		local taken = GetMoney() - (startMoney or GetMoney())
		local bits = {}
		if taken > 0 then bits[#bits + 1] = "collected " .. GetCoinTextureString(taken) end
		if skippedFull > 0 then bits[#bits + 1] = ("%d mail%s left - bags full (keeping %d free)"):format(skippedFull, skippedFull == 1 and "" or "s", db.keepFree) end
		local _, total = NumItems()
		local shown = NumItems()
		if total and total > shown then bits[#bits + 1] = ("%d more waiting - close and reopen the mailbox in a minute"):format(total - shown) end
		Stop("done" .. (#bits > 0 and (" - " .. table.concat(bits, ", ")) or "") .. ".")
		return
	end
	if i > NumItems() or not SameMail(i, ids[#queue]) then Pop(); return Step() end
	local _, _, _, _, money, cod, _, itemCount = Header(i)
	if (cod or 0) > 0 then Pop(); return Step() end
	if (money or 0) > 0 then TakeInboxMoney(i); return Next() end
	if (itemCount or 0) > 0 then
		if FreeSlots() <= (db.keepFree or 0) then skippedFull = skippedFull + 1; Pop(); return Step() end
		for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
			if GetInboxItem(i, a) then TakeInboxItem(i, a); return Next() end
		end
	end
	Pop()
	return Step()
end
-- open a set of mail indexes (highest first, so nothing shifts under us)
function PM.Open(list, done)
	if running then Stop("stopped."); return end
	wipe(queue)
	table.sort(list)
	wipe(ids)
	for _, i in ipairs(list) do queue[#queue + 1] = i; local k, d = MailID(i); ids[#queue] = { k, d } end
	if #queue == 0 then Print("nothing to open."); if done then done() end; return end
	running, skippedFull, startMoney, onDone = true, 0, GetMoney(), done
	if PM.openBtn then PM.openBtn:SetText("Stop") end
	Step()
end
function PM.OpenAll(all)
	local list = {}
	for i = 1, NumItems() do
		local k = Kind(i)
		if k and (all or db["f_" .. k]) then list[#list + 1] = i end
	end
	PM.Open(list)
end

---------------------------------------------------------------- contacts
local function RememberMe()
	db.alts[Key()] = db.alts[Key()] or {}
	-- WoW Forever names have a second name ("Pint Waterboy"); alts saved before that was known went in under the first
	-- name alone (so every "Pint" was one entry): clear those once so each character saves itself again in full
	if ME:find(" ") and not db.fullNames then
		db.fullNames = true
		for name in pairs(db.alts[Key()]) do if not name:find(" ") then db.alts[Key()][name] = nil end end
	end
	local _, cls = UnitClass("player")
	db.alts[Key()][ME] = { cls, UnitLevel("player") }
end
-- your alts on this realm and faction (ours, plus anyone Pint's Ledger knows)
local function Alts()
	local out, seen = {}, {}
	for name, v in pairs(db.alts[Key()] or {}) do if name ~= ME then out[#out + 1] = { name, v[1], v[2] }; seen[name] = true end end
	local L = _G.PintsLedgerDB
	if L and L.chars and L.chars[REALM] then
		for name, rec in pairs(L.chars[REALM]) do
			if name ~= ME and not seen[name] and (not rec.faction or rec.faction == FACTION) then out[#out + 1] = { name, rec.classFile, rec.level } end
		end
	end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	return out
end
local function Recent()
	local out = {}
	for _, r in ipairs(db.recent[Key()] or {}) do out[#out + 1] = { r } end
	return out
end
local function Friends()
	local out = {}
	local n = (C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetNumFriends()) or (GetNumFriends and GetNumFriends()) or 0
	for i = 1, n do
		local name, level, cls
		if C_FriendList and C_FriendList.GetFriendInfoByIndex then
			local info = C_FriendList.GetFriendInfoByIndex(i)
			if info then name, level, cls = info.name, info.level, info.className end
		else
			name, level, cls = GetFriendInfo(i)
		end
		if name then out[#out + 1] = { name, nil, level } end
	end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	return out
end
local function Guild()
	local out = {}
	if not IsInGuild() then return out end
	for i = 1, (GetNumGuildMembers() or 0) do
		local name, _, _, level, _, _, _, _, _, _, cls = GetGuildRosterInfo(i)
		if name then name = Ambiguate and Ambiguate(name, "none") or name:gsub("%-.*", ""); if name ~= ME then out[#out + 1] = { name, cls, level } end end
	end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	return out
end
local function AddRecent(name)
	if not name or name == "" then return end
	name = name:gsub("^%l", string.upper):gsub(" %l", string.upper)     -- "rain mon" -> "Rain Mon"
	local list = db.recent[Key()] or {}
	db.recent[Key()] = list
	for i = #list, 1, -1 do if list[i]:lower() == name:lower() then table.remove(list, i) end end
	table.insert(list, 1, name)
	while #list > 20 do table.remove(list) end
	db.last = db.last or {}
	db.last[Key()] = name
end

-- names to autocomplete from, best first
local function Candidates()
	local out = {}
	if db.useAlts then for _, e in ipairs(Alts()) do out[#out + 1] = e[1] end end
	if db.useRecent then for _, e in ipairs(Recent()) do out[#out + 1] = e[1] end end
	if db.useFriends then for _, e in ipairs(Friends()) do out[#out + 1] = e[1] end end
	if db.useGuild then for _, e in ipairs(Guild()) do out[#out + 1] = e[1] end end
	return out
end

local menu
local function ClassName(e)
	local c = e[2] and RAID_CLASS_COLORS[e[2]]
	local name = c and ("|c" .. (c.colorStr or "ffffffff") .. e[1] .. "|r") or e[1]
	if e[3] then name = name .. "  |cff888888" .. e[3] .. "|r" end
	return name
end
local PAGE = 30          -- names per page for long lists (guild, friends); the mouse wheel or the arrows move through
local function ShowMenu(anchor, page, start)
	start = math.max(1, start or 1)
	if not menu then
		menu = CreateFrame("Frame", "PintsPostContacts", UIParent, "BackdropTemplate")
		menu:SetFrameStrata("FULLSCREEN_DIALOG"); menu:SetClampedToScreen(true); menu:EnableMouse(true)
		menu:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
		menu:SetBackdropColor(0, 0, 0, 0.95)
		menu.items = {}
		menu:Hide()
		tinsert(UISpecialFrames, "PintsPostContacts")
	end
	local rows = {}
	local function head(t) rows[#rows + 1] = { head = t } end
	local function list(l, limit) for k, e in ipairs(l) do if limit and k > limit then rows[#rows + 1] = { more = true }; break end rows[#rows + 1] = { name = e[1], text = ClassName(e) } end end
	-- a long list a page at a time: "^" back a page, "v" on to the next
	local function paged(title, l)
		local n = #l
		if start > n then start = math.max(1, n - PAGE + 1) end
		local last = math.min(n, start + PAGE - 1)
		head(title .. (n > PAGE and ("  |cff888888" .. start .. "-" .. last .. " of " .. n .. "|r") or ""))
		if start > 1 then rows[#rows + 1] = { jump = math.max(1, start - PAGE), text = "   |cff66ccff^  previous|r" } end
		for k = start, last do local e = l[k]; rows[#rows + 1] = { name = e[1], text = ClassName(e) } end
		if last < n then rows[#rows + 1] = { jump = last + 1, text = "   |cff66ccffv  next (" .. (n - last) .. " more)|r" } end
		menu.paged = { page = page, start = start, n = n }
	end
	menu.paged = nil
	if page == "friends" then paged("Friends", Friends()); rows[#rows + 1] = { back = true }
	elseif page == "guild" then paged("Guild", Guild()); rows[#rows + 1] = { back = true }
	else
		head("Alts"); local a = Alts(); if #a == 0 then rows[#rows + 1] = { note = "log each alt on once" } else list(a) end
		head("Recently mailed"); local r = Recent(); if #r == 0 then rows[#rows + 1] = { note = "nobody yet" } else list(r, 20) end
		rows[#rows + 1] = { page = "friends", text = "Friends  >" }
		if IsInGuild() then rows[#rows + 1] = { page = "guild", text = "Guild  >" } end
	end
	for i, r in ipairs(rows) do
		local b = menu.items[i]
		if not b then
			b = CreateFrame("Button", nil, menu)
			b:SetSize(180, 16); b:SetPoint("TOPLEFT", 8, -6 - (i - 1) * 16)
			b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.text:SetPoint("LEFT", 4, 0)
			b.hl = b:CreateTexture(nil, "HIGHLIGHT"); b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 0.82, 0, 0.18)
			menu.items[i] = b
		end
		b.row = r
		if r.head then b.text:SetText("|cffffd100" .. r.head .. "|r"); b:EnableMouse(false)
		elseif r.note then b.text:SetText("   |cff888888" .. r.note .. "|r"); b:EnableMouse(false)
		elseif r.more then b.text:SetText("   |cff888888...|r"); b:EnableMouse(false)
		elseif r.back then b.text:SetText("<  Back"); b:EnableMouse(true)
		elseif r.jump then b.text:SetText(r.text); b:EnableMouse(true)
		else b.text:SetText(r.page and r.text or ("   " .. r.text)); b:EnableMouse(true) end
		b:SetScript("OnClick", function(self)
			local row = self.row
			if row.jump then ShowMenu(anchor, page, row.jump)
			elseif row.page then ShowMenu(anchor, row.page)
			elseif row.back then ShowMenu(anchor)
			elseif row.name then SendMailNameEditBox:SetText(row.name); SendMailNameEditBox:SetCursorPosition(#row.name); menu:Hide(); SendMailSubjectEditBox:SetFocus() end
		end)
		b:Show()
	end
	for i = #rows + 1, #menu.items do menu.items[i]:Hide() end
	menu:SetSize(196, #rows * 16 + 12)
	-- mouse wheel: scroll a long list a few names at a time
	menu:EnableMouseWheel(true)
	menu:SetScript("OnMouseWheel", function(self, d)
		local p = self.paged
		if not p or p.n <= PAGE then return end
		local s2 = math.max(1, math.min(p.n - PAGE + 1, p.start - d * 5))
		if s2 ~= p.start then ShowMenu(anchor, p.page, s2) end
	end)
	menu:ClearAllPoints(); menu:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 2, 0)
	menu:Show()
end

local completing = false
local typedLen = 0
local function Autocomplete(box, user)
	-- the box filled or cleared by the game or another add-on: start counting from there
	if not user and not completing then typedLen = #(box:GetText() or "") end
	if not user or completing or not db.autocomplete then return end
	local text = box:GetText()
	-- deleting (Backspace / Delete) never fills a name back in, so a wrong first letter can be rubbed out
	local shorter = #text <= typedLen
	typedLen = #text
	if shorter then return end
	if #text < 1 or box:GetCursorPosition() ~= #text then return end
	local low = text:lower()
	for _, name in ipairs(Candidates()) do
		if name:lower():sub(1, #low) == low and #name > #text then
			completing = true
			box:SetText(name)
			box:HighlightText(#text, #name)
			box:SetCursorPosition(#text)
			completing = false
			return
		end
	end
end

---------------------------------------------------------------- quick attach
local QUICK = {
	{ "cloth", "Cloth", "Interface\\Icons\\INV_Fabric_Linen_01", { 2589, 2592, 4306, 4338, 14047, 14256, 14342 }, { "Cloth" } },
	{ "leather", "Leather & hides", "Interface\\Icons\\INV_Misc_LeatherScrap_03", { 2318, 2319, 4234, 4304, 8170, 15407, 783, 4232, 4235, 8169, 8171, 17012, 2934, 15408, 15412, 15414, 15415, 15416, 15417, 15419, 15422, 15423 }, { "Leather", " Hide", "Scale" } },
	{ "herbs", "Herbs", "Interface\\Icons\\INV_Misc_Herb_10", { 2447, 765, 2449, 785, 2450, 2452, 3820, 2453, 3355, 3369, 3356, 3357, 3818, 3821, 3358, 3819, 4625, 8831, 8836, 8838, 8839, 8845, 8846, 13464, 13463, 13465, 13466, 13467, 13468, 8153 }, {} },
	{ "metal", "Ore, bars & stone", "Interface\\Icons\\INV_Ore_Copper_01", { 2770, 2771, 2772, 2775, 2776, 3858, 7911, 10620, 11370, 2840, 2841, 3576, 3575, 3577, 3859, 3860, 6037, 12359, 11371, 12655, 2835, 2836, 2838, 7912, 12365 }, { " Ore" } },
	{ "enchant", "Enchanting", "Interface\\Icons\\INV_Enchant_DustStrange", { 10940, 11083, 11137, 11176, 16204, 10938, 10939, 10998, 11082, 11134, 11135, 11174, 11175, 16202, 16203, 10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344, 20725 }, {} },
	{ "elemental", "Elemental", "Interface\\Icons\\INV_Elemental_Primal_Fire", { 7067, 7068, 7069, 7070, 7075, 7076, 7077, 7078, 7079, 7080, 7081, 7082, 12803, 12808, 7972, 12809 }, {} },
	-- fish: raw (to cook) and cooked, plus Fish Oil; by name too, for fish we don't list (WoW Forever's new ones)
	{ "fish", "Fish", "Interface\\Icons\\INV_Misc_Fish_02", { 6291, 6303, 6289, 6317, 6361, 6308, 6362, 8365, 6358, 6359, 4603, 13754, 13755, 13756,
		13758, 13759, 13760, 13888, 13889, 13893, 6522, 21071, 21153, 12238, 8959, 6290, 787, 4592, 4593, 4594, 5095, 6887, 8364, 13927, 13930,
		13932, 13933, 13934, 13935, 8957, 21072, 21217, 17058 },
		{ "Smallfish", "Mackerel", "Mud Snapper", "Catfish", "Rockscale Cod", "Albacore", "Yellowtail", "Head Trout", "Mightfish", "Sunscale Salmon",
		"Whitescale Salmon", "Nightfin Snapper", "Firefin Snapper", "Blackmouth", "Redgill", "Summer Bass", "Winter Squid", "Sagefish",
		"Halibut", "Grouper", "Loch Frenzy", "Deviate Fish" } },
}
local quickSet = {}
for _, q in ipairs(QUICK) do quickSet[q[1]] = {}; for _, id in ipairs(q[4]) do quickSet[q[1]][id] = true end end
local function Matches(q, id, link)
	if quickSet[q[1]][id] then return true end
	local name = link and link:match("%[(.-)%]")
	if not name then return false end
	for _, w in ipairs(q[5]) do if name:find(w, 1, true) then return true end end
	return false
end
function PM.QuickAttach(q)
	local n = 0
	for bag = 0, 4 do
		for slot = 1, NumSlots(bag) do
			local id, link, locked = ItemAt(bag, slot)
			if id and not locked and Matches(q, id, link) then
				if not Attach(bag, slot) then Print("the mail is full (12 items)."); return end
				n = n + 1
			end
		end
	end
	local to = db.quickTo[q[1]]
	if to and SendMailNameEditBox:GetText() == "" then SendMailNameEditBox:SetText(to) end
	if n == 0 then Print("no " .. q[2]:lower() .. " in your bags.") end
end

---------------------------------------------------------------- copy / forward
local copyBox
local function ShowCopy(text)
	if not copyBox then
		copyBox = CreateFrame("Frame", "PintsPostCopy", UIParent, "BasicFrameTemplateWithInset")
		copyBox:SetSize(420, 300); copyBox:SetPoint("CENTER"); copyBox:SetFrameStrata("DIALOG")
		copyBox:SetMovable(true); copyBox:EnableMouse(true); copyBox:RegisterForDrag("LeftButton")
		copyBox:SetScript("OnDragStart", copyBox.StartMoving); copyBox:SetScript("OnDragStop", copyBox.StopMovingOrSizing)
		local t = copyBox:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); t:SetPoint("TOP", 0, -5); t:SetText("Copy mail - Ctrl+C")
		local sf = CreateFrame("ScrollFrame", "PintsPostCopyScroll", copyBox, "UIPanelScrollFrameTemplate")
		sf:SetPoint("TOPLEFT", 14, -30); sf:SetPoint("BOTTOMRIGHT", -32, 12)
		local eb = CreateFrame("EditBox", nil, sf); eb:SetMultiLine(true); eb:SetFontObject("ChatFontNormal"); eb:SetWidth(360); eb:SetAutoFocus(false)
		eb:SetScript("OnEscapePressed", function() copyBox:Hide() end)
		sf:SetScrollChild(eb)
		copyBox.eb = eb
		tinsert(UISpecialFrames, "PintsPostCopy")
	end
	copyBox.eb:SetText(text); copyBox:Show(); copyBox.eb:SetFocus(); copyBox.eb:HighlightText()
end
local function MailText(i)
	local _, _, sender, subject, money = Header(i)
	local body = GetInboxText(i) or ""
	return sender or "?", subject or "", body, money or 0
end
function PM.Copy()
	local i = InboxFrame.openMailID; if not i then return end
	local sender, subject, body = MailText(i)
	ShowCopy(("From: %s\nSubject: %s\n\n%s"):format(sender, subject, body))
end
function PM.Forward()
	local i = InboxFrame.openMailID; if not i then return end
	local sender, subject, body = MailText(i)
	-- take the attachments first so they can go back out
	local links = {}
	for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
		local l = GetInboxItemLink and GetInboxItemLink(i, a)
		if l then links[#links + 1] = l end
	end
	if #links > FreeSlots() then Print("not enough bag space to forward the items."); return end
	for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do if GetInboxItem(i, a) then TakeInboxItem(i, a) end end
	C_Timer.After(#links > 0 and 1.2 or 0, function()
		if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end
		SendMailSubjectEditBox:SetText(("FW: %s"):format(subject))
		SendMailBodyEditBox:SetText(("---- Forwarded mail from %s ----\n%s"):format(sender, body))
		local want = {}
		for _, l in ipairs(links) do want[#want + 1] = l end
		for bag = 0, 4 do
			for slot = 1, NumSlots(bag) do
				local _, link, locked = ItemAt(bag, slot)
				for k, l in ipairs(want) do
					if link == l and not locked then Attach(bag, slot); table.remove(want, k); break end
				end
			end
		end
		SendMailNameEditBox:SetFocus()
		if #want > 0 then Print(#want .. " item(s) hadn't reached your bags yet - attach them by hand.") end
	end)
end

---------------------------------------------------------------- inbox decorations
local checks, selected = {}, {}
local lastChecked
-- hook a Blizzard function only if this game has it (WoW Forever's mailbox renamed or dropped some)
local function Hook(name, fn) if type(_G[name]) == "function" then hooksecurefunc(name, fn); return true end end
local function IndexOf(row) return ((InboxFrame.pageNum or 1) - 1) * (INBOXITEMS_TO_DISPLAY or 7) + row end
local function UpdateInbox()
	if not InboxFrame or not InboxFrame:IsVisible() then return end
	local num = NumItems()
	for row = 1, INBOXITEMS_TO_DISPLAY or 7 do
		local i = IndexOf(row)
		local item = _G["MailItem" .. row]
		local c = checks[row]
		if c then
			if db.select and i <= num then c:Show(); c:SetChecked(selected[i] and true or false); c.index = i else c:Hide() end
			c.num:SetText(i <= num and i or "")
		end
		local x = item and item.ppExpiry
		if x then
			if db.expiry and i <= num then
				local del = InboxItemCanDelete(i)
				x.icon:SetTexture(del and "Interface\\RaidFrame\\ReadyCheck-NotReady" or "Interface\\ChatFrame\\ChatFrameExpandArrow")
				if not del then x.icon:SetTexCoord(1, 0, 0, 1) else x.icon:SetTexCoord(0, 1, 0, 1) end
				x.index, x.del = i, del; x:Show()
			else x:Hide() end
		end
	end
	if PM.selBar then
		local n = 0; for _ in pairs(selected) do n = n + 1 end
		PM.selOpen:SetEnabled(n > 0); PM.selReturn:SetEnabled(n > 0)
		PM.selBar:SetShown(db.select)
	end
end
PM.UpdateInbox = UpdateInbox

local function BuildInbox()
	for row = 1, INBOXITEMS_TO_DISPLAY or 7 do
		local item = _G["MailItem" .. row]
		if item then
			-- tick box, bottom right of each mail row
			local c = CreateFrame("CheckButton", nil, item, "UICheckButtonTemplate")
			c:SetSize(18, 18); c:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", -2, 2)
			c.num = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); c.num:SetPoint("RIGHT", c, "LEFT", -1, 0)
			c:SetScript("OnClick", function(self)
				local i = self.index
				if IsControlKeyDown() then
					local _, _, who = Header(i)
					local on = not selected[i]
					for k = 1, NumItems() do local _, _, s = Header(k); if s == who then selected[k] = on or nil end end
				elseif IsShiftKeyDown() and lastChecked then
					for k = math.min(lastChecked, i), math.max(lastChecked, i) do selected[k] = true end
				else
					selected[i] = self:GetChecked() or nil
				end
				lastChecked = i
				UpdateInbox()
			end)
			c:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Select this mail")
				GameTooltip:AddLine("Shift-click: everything between this and the last box", 1, 1, 1); GameTooltip:AddLine("Ctrl-click: every mail from this sender", 1, 1, 1); GameTooltip:Show() end)
			c:SetScript("OnLeave", function() GameTooltip:Hide() end)
			checks[row] = c
			-- expiry icon: X = deleted when it runs out, arrow = goes back to the sender
			local x = CreateFrame("Button", nil, item)
			x:SetSize(14, 14)
			local exp = _G["MailItem" .. row .. "ExpireTime"]
			if exp then x:SetPoint("RIGHT", exp, "LEFT", -2, 0) else x:SetPoint("TOPRIGHT", item, "TOPRIGHT", -60, -4) end
			x.icon = x:CreateTexture(nil, "ARTWORK"); x.icon:SetAllPoints()
			x:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(self.del and "Deleted when it expires" or "Returned to the sender when it expires")
				GameTooltip:AddLine(self.del and "Click: delete it now" or "Click: return it now", 1, 1, 1)
				GameTooltip:Show()
			end)
			x:SetScript("OnLeave", function() GameTooltip:Hide() end)
			x:SetScript("OnClick", function(self)
				local i = self.index
				if self.del then
					local _, _, _, subject, money, _, _, items = Header(i)
					if (money or 0) > 0 or (items or 0) > 0 then
						Print("that mail still has money or items in it - take them first.")
					else DeleteInboxItem(i) end
				else
					ReturnInboxItem(i)
				end
			end)
			item.ppExpiry = x
			-- Express: Shift-click takes everything, Ctrl-click returns
			local btn = _G["MailItem" .. row .. "Button"]
			if btn and not btn.ppExpress then
				btn.ppExpress = true
				local old = btn:GetScript("OnClick")
				btn:SetScript("OnClick", function(self, ...)
					local i = IndexOf(row)
					if db.express and IsShiftKeyDown() then
						PM.Open({ i }); return
					elseif db.express and IsControlKeyDown() then
						ReturnInboxItem(i); return
					end
					if old then return old(self, ...) end
				end)
			end
		end
	end
	-- bottom buttons: Open All, Open ticked, Return ticked
	local open = CreateFrame("Button", nil, InboxFrame, "UIPanelButtonTemplate")
	-- Blizzard's own "Open All" button sits in the same spot; ours replaces it
	local blizz = _G.OpenAllMail
	if blizz then
		blizz:Hide(); blizz:SetAlpha(0); blizz:EnableMouse(false)
		hooksecurefunc(blizz, "Show", function(self) self:Hide() end)
	end
	-- our three buttons sit centred between the "Prev" and "Next" page buttons (named differently on WoW Forever)
	local function Pager(word)
		local g = _G["Inbox" .. word .. "PageButton"]; if g then return g end
		if InboxFrame[word .. "PageButton"] then return InboxFrame[word .. "PageButton"] end
		for k, v in pairs(InboxFrame) do
			if type(k) == "string" and k:find(word) and type(v) == "table" and v.GetObjectType and v:GetObjectType() == "Button" then return v end
		end
		for _, c in ipairs({ InboxFrame:GetChildren() }) do local n = c.GetName and c:GetName(); if n and n:find(word) then return c end end
	end
	local prevB, nextB = Pager("Prev"), Pager("Next")
	local row = CreateFrame("Frame", nil, InboxFrame); row:SetSize(170, 22)
	if prevB and nextB then
		row:SetPoint("LEFT", prevB, "RIGHT", 0, 0); row:SetPoint("RIGHT", nextB, "LEFT", 0, 0)
	else row:SetPoint("BOTTOM", MailFrame, "BOTTOM", 0, 40) end
	open:SetSize(62, 22)
	open:SetPoint("RIGHT", row, "CENTER", -26, 0)
	open:SetText("Open All"); open:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	open:SetScript("OnClick", function(_, b) if b == "RightButton" then PM.ToggleOptions() else PM.OpenAll(IsShiftKeyDown()) end end)
	open:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Open All")
		GameTooltip:AddLine("Opens the kinds of mail ticked in the settings.", 1, 1, 1, true); GameTooltip:AddLine("Shift-click: every mail, whatever the settings", 0.6, 0.8, 1); GameTooltip:AddLine("Right-click: settings", 0.6, 0.8, 1); GameTooltip:Show() end)
	open:SetScript("OnLeave", function() GameTooltip:Hide() end)
	PM.openBtn = open
	local bar = CreateFrame("Frame", nil, InboxFrame); bar:SetSize(106, 22); bar:SetPoint("LEFT", open, "RIGHT", 3, 0)
	PM.selBar = bar
	PM.selOpen = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate"); PM.selOpen:SetSize(48, 22); PM.selOpen:SetPoint("LEFT")
	PM.selOpen:SetText("Open")
	PM.selOpen:SetScript("OnClick", function()
		local list = {}; for i in pairs(selected) do list[#list + 1] = i end
		wipe(selected); PM.Open(list, UpdateInbox); UpdateInbox()
	end)
	PM.selReturn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate"); PM.selReturn:SetSize(55, 22); PM.selReturn:SetPoint("LEFT", PM.selOpen, "RIGHT", 3, 0)
	PM.selReturn:SetText("Return")
	for _, b in ipairs({ PM.selOpen, PM.selReturn }) do
		b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine(self:GetText() .. " the ticked mail"); GameTooltip:Show() end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	PM.selReturn:SetScript("OnClick", function()
		local list = {}; for i in pairs(selected) do list[#list + 1] = i end
		table.sort(list, function(a, b) return a > b end)
		wipe(selected)
		local k = 0
		local function go()
			k = k + 1
			local i = list[k]; if not i then UpdateInbox(); return end
			if InboxItemCanDelete and not InboxItemCanDelete(i) then ReturnInboxItem(i) end
			C_Timer.After(db.speed or 0.4, go)
		end
		go()
	end)
	if not Hook("InboxFrame_Update", UpdateInbox) then InboxFrame:HookScript("OnShow", UpdateInbox) end
end

---------------------------------------------------------------- send tab decorations
local function BuildSend()
	-- contacts book beside To:
	local book = CreateFrame("Button", nil, SendMailFrame)
	book:SetSize(22, 22); book:SetPoint("LEFT", SendMailNameEditBox, "RIGHT", 2, 0)
	book:SetNormalTexture("Interface\\Icons\\INV_Misc_Book_08")
	book:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	book:SetScript("OnClick", function(self) if menu and menu:IsShown() then menu:Hide() else ShowMenu(self) end end)
	book:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Contacts"); GameTooltip:AddLine("Your alts, people you've mailed, friends and guild", 1, 1, 1, true); GameTooltip:Show() end)
	book:SetScript("OnLeave", function() GameTooltip:Hide() end)
	PM.book = book
	-- the contacts list closes with the mailbox (WoW Forever doesn't always send the "mail closed" event)
	local function CloseMenu() if menu then menu:Hide() end end
	SendMailFrame:HookScript("OnHide", CloseMenu)
	MailFrame:HookScript("OnHide", CloseMenu)
	SendMailNameEditBox:HookScript("OnTextChanged", function(self, user) Autocomplete(self, user) end)
	-- quick attach column, outside the right edge of the mailbox
	PM.quick = {}
	for k, q in ipairs(QUICK) do
		local b = CreateFrame("Button", nil, SendMailFrame)
		b:SetSize(30, 30); b:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", -2, -60 - (k - 1) * 34)
		b:SetNormalTexture(q[3]); b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnClick", function(_, button)
			if button == "RightButton" then
				local name = SendMailNameEditBox:GetText()
				if name ~= "" then db.quickTo[q[1]] = name; Print(q[2] .. " will go to " .. name .. " by default.")
				else db.quickTo[q[1]] = nil; Print(q[2] .. ": no default recipient.") end
			else PM.QuickAttach(q) end
		end)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Attach all: " .. q[2])
			if db.quickTo[q[1]] then GameTooltip:AddLine("Goes to " .. db.quickTo[q[1]] .. " if To: is empty", 1, 1, 1) end
			GameTooltip:AddLine("Right-click: make the name in To: the default for this", 0.6, 0.8, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		PM.quick[k] = b
	end
	-- money subject: the amount goes into an empty subject as you type it (and back out if you clear the money)
	local auto
	-- the money typed in: the game's own reader where it has one, else the gold / silver / copper boxes themselves
	local function Typed()
		local m = SendMailMoney
		if not m then return 0 end
		if MoneyInputFrame_GetCopper then local ok, v = pcall(MoneyInputFrame_GetCopper, m); if ok and type(v) == "number" then return v end end
		if m.GetAmount then local ok, v = pcall(m.GetAmount, m); if ok and type(v) == "number" then return v end end
		local g, sv, c = 0, 0, 0
		local function Val(box) return box and tonumber(box:GetText() or "") or 0 end
		local n = m:GetName() or "SendMailMoney"
		g = Val(m.gold or m.GoldBox or _G[n .. "Gold"])
		sv = Val(m.silver or m.SilverBox or _G[n .. "Silver"])
		c = Val(m.copper or m.CopperBox or _G[n .. "Copper"])
		return g * 10000 + sv * 100 + c
	end
	local function MoneySubject()
		if not db.wire or not SendMailSubjectEditBox then return end
		local money = Typed()
		local subj = SendMailSubjectEditBox:GetText() or ""
		if money > 0 and (subj == "" or subj == auto) then
			local text
			if GetCoinText then text = GetCoinText(money, " ")
			else
				local g, sv, c = math.floor(money / 10000), math.floor(money / 100) % 100, money % 100
				local t = {}
				if g > 0 then t[#t + 1] = g .. " Gold" end
				if sv > 0 then t[#t + 1] = sv .. " Silver" end
				if c > 0 then t[#t + 1] = c .. " Copper" end
				text = table.concat(t, " ")
			end
			if subj ~= text then auto = text; SendMailSubjectEditBox:SetText(text) else auto = text end
		elseif money == 0 and auto and subj == auto then
			auto = nil; SendMailSubjectEditBox:SetText("")
		end
	end
	Hook("SendMailFrame_CanSend", MoneySubject)
	-- (WoW Forever doesn't always run the game's check as you type: watch the money boxes themselves too)
	local function Watch(f, depth)
		if not f or depth > 3 then return end
		if f.IsObjectType and f:IsObjectType("EditBox") and not f.ppMoneyHook then
			f.ppMoneyHook = true
			f:HookScript("OnTextChanged", function() C_Timer.After(0, MoneySubject) end)
		end
		if f.GetChildren then for _, c in ipairs({ f:GetChildren() }) do Watch(c, depth + 1) end end
	end
	Watch(SendMailMoney, 0)
	-- remember who you mail
	if not Hook("SendMail", function(name) AddRecent(name) end) and C_Mail and C_Mail.SendMail then
		hooksecurefunc(C_Mail, "SendMail", function(name) AddRecent(name) end)
	end
	SendMailFrame:HookScript("OnShow", function()
		if db.autofill and db.last and db.last[Key()] and SendMailNameEditBox:GetText() == "" then SendMailNameEditBox:SetText(db.last[Key()]) end
		PM.book:SetShown(db.contacts)
		for _, b in ipairs(PM.quick) do b:SetShown(db.quick) end
	end)
end

---------------------------------------------------------------- open-mail decorations (copy / forward)
local function BuildOpen()
	local copy = CreateFrame("Button", nil, OpenMailFrame, "UIPanelButtonTemplate")
	copy:SetSize(60, 20); copy:SetPoint("TOPRIGHT", OpenMailFrame, "TOPRIGHT", -40, -44); copy:SetText("Copy")
	copy:SetScript("OnClick", PM.Copy)
	local fw = CreateFrame("Button", nil, OpenMailFrame, "UIPanelButtonTemplate")
	fw:SetSize(70, 20); fw:SetPoint("RIGHT", copy, "LEFT", -4, 0); fw:SetText("Forward")
	fw:SetScript("OnClick", PM.Forward)
	fw:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Forward"); GameTooltip:AddLine("Takes any items into your bags and puts the text and items into a new mail.", 1, 1, 1, true); GameTooltip:Show() end)
	fw:SetScript("OnLeave", function() GameTooltip:Hide() end)
	OpenMailFrame:HookScript("OnShow", function() copy:SetShown(db.copy); fw:SetShown(db.copy) end)
end

---------------------------------------------------------------- Alt-click a bag item to attach it
hooksecurefunc("HandleModifiedItemClick", function(link)
	if not (db and db.express and IsAltKeyDown() and SendMailFrame and SendMailFrame:IsVisible() and link) then return end
	for bag = 0, 4 do
		for slot = 1, NumSlots(bag) do
			local _, l, locked = ItemAt(bag, slot)
			if l == link and not locked then Attach(bag, slot); return end
		end
	end
end)

---------------------------------------------------------------- settings
local opt
local function Check(parent, x, y, label, key, tip)
	local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate"); c:SetSize(22, 22); c:SetPoint("TOPLEFT", x, y)
	local t = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); t:SetPoint("LEFT", c, "RIGHT", 2, 0); t:SetText(label)
	c:SetScript("OnShow", function(self) self:SetChecked(db[key] and true or false) end)
	c:SetScript("OnClick", function(self) db[key] = self:GetChecked() and true or false; UpdateInbox() end)
	if tip then
		c:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine(label); GameTooltip:AddLine(tip, 1, 1, 1, true); GameTooltip:Show() end)
		c:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
end
local function Stepper(parent, x, y, label, key, lo, hi, inc, fmt)
	local t = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); t:SetPoint("TOPLEFT", x, y - 4); t:SetText(label)
	local v = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); v:SetPoint("TOPLEFT", x + 130, y - 4)
	local function show() v:SetText(fmt(db[key])) end
	local minus = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate"); minus:SetSize(22, 20); minus:SetPoint("TOPLEFT", x + 176, y); minus:SetText("-")
	local plus = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate"); plus:SetSize(22, 20); plus:SetPoint("LEFT", minus, "RIGHT", 2, 0); plus:SetText("+")
	minus:SetScript("OnClick", function() db[key] = math.max(lo, math.floor((db[key] - inc) * 100 + 0.5) / 100); show() end)
	plus:SetScript("OnClick", function() db[key] = math.min(hi, math.floor((db[key] + inc) * 100 + 0.5) / 100); show() end)
	parent:HookScript("OnShow", show)
end
function PM.ToggleOptions()
	if not opt then
		opt = CreateFrame("Frame", "PintsPostOptions", UIParent, "BasicFrameTemplateWithInset")
		opt:SetSize(540, 420); opt:SetPoint("CENTER"); opt:SetFrameStrata("DIALOG"); opt:SetClampedToScreen(true)
		opt:SetMovable(true); opt:EnableMouse(true); opt:RegisterForDrag("LeftButton")
		opt:SetScript("OnDragStart", opt.StartMoving); opt:SetScript("OnDragStop", opt.StopMovingOrSizing)
		tinsert(UISpecialFrames, "PintsPostOptions")
		local title = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); title:SetPoint("TOP", 0, -5); title:SetText("|cffd4a017Pint's|r Postal")
		local function head(x, y, s) local h = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal"); h:SetPoint("TOPLEFT", x, y); h:SetText(s) end
		local L, R = 18, 280
		head(L, -32, "Contacts")
		Check(opt, L, -50, "Contacts book by the To: box", "contacts")
		Check(opt, L, -72, "Autocomplete names", "autocomplete", "As you type a name, it finishes it from the lists ticked below.")
		Check(opt, L + 12, -94, "from alts", "useAlts"); Check(opt, L + 120, -94, "recently mailed", "useRecent")
		Check(opt, L + 12, -116, "from friends", "useFriends"); Check(opt, L + 120, -116, "guild", "useGuild")
		Check(opt, L, -138, "Fill in the last person you mailed", "autofill")
		head(L, -172, "Inbox")
		Check(opt, L, -190, "Tick boxes with Open / Return", "select")
		Check(opt, L, -212, "Shift / Ctrl / Alt-click shortcuts", "express", "Shift-click a mail: take everything. Ctrl-click a mail: return it. Alt-click an item in your bags: attach it to the mail you're writing.")
		Check(opt, L, -234, "Expiry icon (return or delete)", "expiry")
		Check(opt, L, -256, "Copy and Forward buttons", "copy")
		Check(opt, L, -278, "Report gold taken when you close it", "rake")
		Check(opt, L, -300, "Block trades while at the mailbox", "tradeBlock")
		head(L, -334, "Sending")
		Check(opt, L, -352, "Quick-attach buttons", "quick")
		Check(opt, L, -374, "Subject = gold amount if left blank", "wire")

		head(R, -32, "Open All opens")
		Check(opt, R, -50, "Auction cancelled", "f_cancelled"); Check(opt, R + 130, -50, "Auction expired", "f_expired")
		Check(opt, R, -72, "Outbid", "f_outbid"); Check(opt, R + 130, -72, "Auction sold", "f_success")
		Check(opt, R, -94, "Auction won", "f_won")
		Check(opt, R, -116, "Other mail with money or items", "f_other")
		local n = opt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); n:SetPoint("TOPLEFT", R + 4, -142); n:SetWidth(240); n:SetJustifyH("LEFT")
		n:SetText("Shift-click Open All to open everything. Mail asking for payment on delivery (COD) is never opened for you.")
		Stepper(opt, R, -186, "Bag slots to keep free", "keepFree", 0, 20, 1, function(v) return tostring(v) end)
		Stepper(opt, R, -212, "Seconds between mails", "speed", 0.2, 2, 0.1, function(v) return ("%.1f"):format(v) end)
		head(R, -250, "Postal")
		local off = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate"); off:SetSize(200, 22); off:SetPoint("TOPLEFT", R, -270)
		off:SetText("Switch Postal off"); off:SetScript("OnClick", function() PM.PostalOff() end)
		opt:HookScript("OnShow", function() off:SetShown(PM.PostalLoaded()) end)
		opt:Hide()
	end
	opt:SetShown(not opt:IsShown())
end

local function Loaded(a) if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(a) end return IsAddOnLoaded and IsAddOnLoaded(a) end
function PM.PostalLoaded() return Loaded("Postal") end
function PM.PostalOff()
	local off = (C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn
	pcall(off, "Postal")
	Print("Postal switched off - /reload to finish.")
end

SLASH_PINTSPOST1 = "/post"
SLASH_PINTSPOST2 = "/pintspost"
SlashCmdList.PINTSPOST = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "off-postal" then PM.PostalOff() elseif msg == "api" then PM.Diagnose() else PM.ToggleOptions() end
end

---------------------------------------------------------------- start-up and mailbox events
local built = false
local mailOpen, mailMoney = false, 0
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED"); ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("MAIL_SHOW"); ev:RegisterEvent("MAIL_CLOSED"); ev:RegisterEvent("MAIL_INBOX_UPDATE")
ev:RegisterEvent("TRADE_SHOW"); ev:RegisterEvent("PETITION_SHOW"); ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:SetScript("OnEvent", function(_, e, a1)
	if e == "ADDON_LOADED" and a1 == ADDON then
		PintsPostDB = PintsPostDB or {}
		db = PintsPostDB
		for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = (type(v) == "table") and {} or v end end
		-- trades at the mailbox are allowed by default now (switched off once for everyone; tick it again in settings)
		if not db.tradeV2 then db.tradeV2 = true; db.tradeBlock = false end
		PM.db = db
	elseif e == "PLAYER_LOGIN" then
		-- your full name: on WoW Forever that's first and second name ("Rain Mon"), which is what the To: box needs
		REALM, FACTION, ME = GetRealmName(), UnitFactionGroup("player"), (GetUnitName and GetUnitName("player", false)) or UnitName("player")
		RememberMe()
		if PM.PostalLoaded() then Print("Postal is on too - /post off-postal to switch it off, then /reload.") end
	elseif e == "PLAYER_LEVEL_UP" then RememberMe()
	elseif e == "MAIL_SHOW" then
		if not built then
			built = true
			-- each part on its own, so one that doesn't fit this game's mailbox doesn't take the others with it
			for _, part in ipairs({ { "inbox", BuildInbox }, { "send", BuildSend }, { "open mail", BuildOpen } }) do
				local ok, err = pcall(part[2])
				if not ok then Print("couldn't set up the " .. part[1] .. " part of the mailbox: " .. tostring(err)) end
			end
			-- settings gear, beside the mailbox's close button
			local gear = CreateFrame("Button", nil, MailFrame)
			local close = MailFrameCloseButton or MailFrame.CloseButton
			gear:SetSize(24, 24); gear:SetFrameLevel(MailFrame:GetFrameLevel() + 10)
			if close then gear:SetPoint("RIGHT", close, "LEFT", -4, 0) else gear:SetPoint("TOPRIGHT", MailFrame, "TOPRIGHT", -40, -2) end
			gear:SetNormalTexture("Interface\\Icons\\INV_Misc_Gear_01"); gear:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
			gear:SetScript("OnClick", PM.ToggleOptions)
			gear:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Pint's Postal settings"); GameTooltip:Show() end)
			gear:SetScript("OnLeave", function() GameTooltip:Hide() end)
		end
		mailOpen, mailMoney = true, GetMoney()
		wipe(selected)
		UpdateInbox()
	elseif e == "MAIL_INBOX_UPDATE" then
		UpdateInbox()
	elseif e == "MAIL_CLOSED" then
		if mailOpen then
			mailOpen = false
			if running then Stop() end
			local d = GetMoney() - mailMoney
			if db.rake and d > 0 then Print("collected " .. GetCoinTextureString(d) .. " from the mailbox.") end
		end
		if menu then menu:Hide() end
	elseif e == "TRADE_SHOW" then
		if mailOpen and db.tradeBlock then CancelTrade(); Print("turned away a trade - you're at the mailbox.") end
	elseif e == "PETITION_SHOW" then
		if mailOpen and db.tradeBlock and ClosePetition then ClosePetition(); Print("turned away a charter request - you're at the mailbox.") end
	end
end)
