--[[
	MHDZ — Anime Expeditions route scanner (show-only)

	Live readout of the best expedition route. It watches the expedition map
	from Dependencies.GameState, and whenever the map appears or regenerates it
	recomputes and displays:

	  Material <target>  - how much of the chosen material the best route yields
	  Node queue pattern - the best node sequence (checkpoint -> boss)

	It NEVER fires SetNodeQueue (selection is disabled).

	Hunt mode: set a "Desired amount" on the slider (0-200) and toggle Hunt ON.
	If the current map's best route is below that amount, MHDZ auto-restarts the
	match (Actions.GameRestart) to look for a better map. When a route reaches
	or exceeds the target it flashes and switches Hunt OFF. Config (material,
	amount, hunt, round) is re-injected by the MCP each round so a restart's
	rejoin does not lose it.

	"Restart Run" asks for an inline Yes/Cancel confirmation before restarting,
	to stop accidental clicks. LeftControl hides/shows the panel.
]]

-- =========================== SERVICES =====================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

-- =========================== REQUIRES =====================================
local FusionPackage = ReplicatedStorage:WaitForChild("FusionPackage")
local Fusion = require(FusionPackage:WaitForChild("Fusion"))
local Dependencies = require(FusionPackage.Dependencies)
local Actions = require(FusionPackage.Actions)
local Nodes = require(ReplicatedStorage:WaitForChild("Nodes"))
local peek = Fusion.peek

-- =========================== CONSTANTS ====================================
local DEFAULT_TARGET = "ExpeditionMaterial2"
local TARGETS = {
	"ExpeditionMaterial1", "ExpeditionMaterial2", "ExpeditionMaterial3",
	"ExpeditionCoin", "ExpeditionFuel", "EquipmentScrap", "Yen", "ExpeditionTome",
}
local POLL_INTERVAL = 0.5
local SLIDER_MIN, SLIDER_MAX = 0, 200
local DEFAULT_AMOUNT = 50

-- Forward-declared so the GUI handlers can reference them before they are
-- constructed below.
local stateLabel
local scanNow
local material, pattern, confirmRow, huntBtn

-- =========================== CORE =========================================
local function peekVal(v)
	if type(v) == "table" and v._EXTREMELY_DANGEROUS_usedAsValue then
		return peek(v)
	end
	return v
end

local function liveGrid()
	local gs = peekVal(Dependencies.GameState)
	return gs and peekVal(gs.GridNodes) or nil
end

-- A stable string that changes when the map regenerates, so we know when to
-- re-scan without recomputing the whole route every frame.
local function graphFingerprint()
	local grid = liveGrid()
	if not grid then return nil end

	local parts = {}
	for _, v in pairs(grid) do
		local nd = peekVal(v)
		if nd then
			local ts = {}
			local t = peekVal(nd.Targets)
			for _, tv in ipairs(t or {}) do
				local tn = peekVal(tv)
				if tn then
					ts[#ts + 1] = tostring(tn.X) .. "/" .. tostring(tn.Y)
				end
			end
			table.sort(ts)
			parts[#parts + 1] = tostring(nd.X) .. "," .. tostring(nd.Y) .. "[" .. table.concat(ts, ",") .. "]"
		end
	end

	table.sort(parts)
	return table.concat(parts, "|")
end

-- Build a directed graph from the expedition grid for one material target.
-- Returns { edges, lush, start, goal } or nil if the map is not loaded yet.
local function readGraph(target)
	local grid = liveGrid()
	if not grid then return nil end

	local coordToIdx = {}
	local edges, lush, start, goal = {}, {}, nil, nil
	local maxX = 0

	for k, v in pairs(grid) do
		local nd = peekVal(v)
		if nd then
			coordToIdx[tostring(nd.X) .. "," .. tostring(nd.Y)] = tostring(k)
		end
	end

	for k, v in pairs(grid) do
		local nd = peekVal(v)
		if nd then
			local kk = tostring(k)

			local tgt = {}
			local t = peekVal(nd.Targets)
			for _, tv in ipairs(t or {}) do
				local tn = peekVal(tv)
				if tn then
					local c = coordToIdx[tostring(tn.X) .. "," .. tostring(tn.Y)]
					if c and c ~= kk and table.find(tgt, c) == nil then
						tgt[#tgt + 1] = c
					end
				end
			end
			edges[kk] = tgt

			local s = 0
			local r = peekVal(nd.Rewards)
			for _, e in ipairs(r or {}) do
				if e and e.Asset == target then s = s + (e.Amount or 0) end
			end
			lush[kk] = s

			local x = nd.X
			if x and x > maxX then maxX = x; goal = kk end
			if x and x == 1 then start = kk end
		end
	end

	if not start or not goal then return nil end
	return { edges = edges, lush = lush, start = start, goal = goal }
end

-- Simple DFS that maximises total material collected along a path from
-- start -> goal, without revisiting nodes.
local function bestPath(graph)
	local best = { total = -1, path = {} }

	local function dfs(node, path, sum, seen)
		if #path > 60 then return end
		if node == graph.goal then
			if sum > best.total then
				best.total = sum
				best.path = table.clone(path)
			end
			return
		end

		seen[node] = true
		for _, nxt in ipairs(graph.edges[node] or {}) do
			if not seen[nxt] then
				path[#path + 1] = nxt
				dfs(nxt, path, sum + (graph.lush[nxt] or 0), seen)
				path[#path] = nil
			end
		end
		seen[node] = nil
	end

	dfs(graph.start, { graph.start }, graph.lush[graph.start] or 0, {})
	return best
end

-- Uses the game's own restart action so it behaves like the native button.
local function restartGame()
	local ok, res = pcall(function()
		Actions.GameRestart(true)
	end)
	return ok and res
end

-- =========================== STATE ========================================
-- Config is re-injected by the MCP each round so target/hunt/round survive a
-- restart's rejoin. Cleared straight after use.
local config = _G.MHDZ_Config or {}
local target = (type(config.material) == "string" and config.material) or DEFAULT_TARGET
local targetAmount = math.clamp(type(config.amount) == "number" and config.amount or DEFAULT_AMOUNT, SLIDER_MIN, SLIDER_MAX)
local huntEnabled = config.hunt == true
local round = type(config.round) == "number" and config.round or 1
local lastBest
_G.MHDZ_Config = nil

if _G.MHDZ then
	pcall(function() _G.MHDZ:Destroy() end)
	_G.MHDZ = nil
end

-- =========================== GUI ==========================================
local gui = Instance.new("ScreenGui")
gui.Name = "MHDZ"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromOffset(340, 300)
panel.Position = UDim2.fromOffset(12, 12)
panel.BackgroundColor3 = Color3.fromRGB(24, 25, 30)
panel.BackgroundTransparency = 0.06
panel.BorderSizePixel = 0
panel.Active = true
panel.Parent = gui
local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 10)
panelCorner.Parent = panel

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 28)
title.Position = UDim2.fromOffset(12, 6)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 17
title.Text = "MHDZ"
title.TextColor3 = Color3.fromRGB(235, 237, 245)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = panel

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "Close"
closeBtn.Size = UDim2.fromOffset(26, 26)
closeBtn.Position = UDim2.new(1, -34, 0, 6)
closeBtn.BackgroundColor3 = Color3.fromRGB(52, 54, 64)
closeBtn.BorderSizePixel = 0
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 15
closeBtn.Text = "x"
closeBtn.TextColor3 = Color3.fromRGB(200, 205, 220)
closeBtn.Parent = panel
local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 6)
closeCorner.Parent = closeBtn
closeBtn.MouseButton1Click:Connect(function() gui.Enabled = false end)

local function makeButton(y, text, opts)
	opts = opts or {}
	local b = Instance.new("TextButton")
	b.Size = opts.width or UDim2.new(1, -24, 0, opts.height or 32)
	b.Position = UDim2.fromOffset(opts.x or 12, y)
	b.BackgroundColor3 = Color3.fromRGB(45, 47, 56)
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 14
	b.Text = text
	b.TextColor3 = Color3.fromRGB(235, 237, 245)
	b.Parent = panel
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 7)
	c.Parent = b
	b.MouseEnter:Connect(function() b.BackgroundColor3 = Color3.fromRGB(58, 61, 72) end)
	b.MouseLeave:Connect(function() b.BackgroundColor3 = Color3.fromRGB(45, 47, 56) end)
	return b
end

local function makeValueLabel(y, height, title)
	local cap = Instance.new("TextLabel")
	cap.Size = UDim2.new(1, -24, 0, 16)
	cap.Position = UDim2.fromOffset(12, y)
	cap.BackgroundTransparency = 1
	cap.Font = Enum.Font.GothamBold
	cap.TextSize = 12
	cap.Text = title
	cap.TextColor3 = Color3.fromRGB(150, 158, 178)
	cap.TextXAlignment = Enum.TextXAlignment.Left
	cap.Parent = panel

	local val = Instance.new("TextLabel")
	val.Size = UDim2.new(1, -24, 0, height)
	val.Position = UDim2.fromOffset(12, y + 16)
	val.BackgroundTransparency = 1
	val.Font = Enum.Font.GothamMedium
	val.TextSize = 16
	val.Text = "-"
	val.TextColor3 = Color3.fromRGB(120, 220, 140)
	val.TextXAlignment = Enum.TextXAlignment.Left
	val.TextWrapped = true
	val.Parent = panel

	return { cap = cap, val = val }
end

-- Controls
local targetBtn = makeButton(36, "Target: " .. target)
targetBtn.MouseButton1Click:Connect(function()
	local idx = table.find(TARGETS, target) or 1
	target = TARGETS[(idx % #TARGETS) + 1]
	targetBtn.Text = "Target: " .. target
	scanNow()
end)

local restartBtn = makeButton(70, "Restart Run")

-- Inline confirmation so an accidental click cannot immediately restart.
confirmRow = Instance.new("Frame")
confirmRow.Name = "ConfirmRow"
confirmRow.Size = UDim2.new(1, -24, 0, 78)
confirmRow.Position = UDim2.fromOffset(12, 176)
confirmRow.BackgroundTransparency = 1
confirmRow.Visible = false
confirmRow.Parent = panel

local confirmLabel = Instance.new("TextLabel")
confirmLabel.Size = UDim2.new(1, 0, 0, 18)
confirmLabel.Position = UDim2.fromOffset(0, 0)
confirmLabel.BackgroundTransparency = 1
confirmLabel.Font = Enum.Font.GothamBold
confirmLabel.TextSize = 14
confirmLabel.Text = "Restart match?"
confirmLabel.TextColor3 = Color3.fromRGB(235, 237, 245)
confirmLabel.TextXAlignment = Enum.TextXAlignment.Left
confirmLabel.Parent = confirmRow

local function makeConfirmButton(xFrac, text, color)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0.5, -4, 0, 32)
	b.Position = UDim2.new(xFrac, 0, 0, 20)
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 14
	b.Text = text
	b.TextColor3 = Color3.fromRGB(235, 237, 245)
	b.Parent = confirmRow
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = b
	return b
end
local confirmYes = makeConfirmButton(0, "Yes", Color3.fromRGB(56, 122, 74))
local confirmNo = makeConfirmButton(0.5, "Cancel", Color3.fromRGB(120, 58, 58))

local function setLabelsVisible(v)
	material.cap.Visible = v
	material.val.Visible = v
	pattern.cap.Visible = v
	pattern.val.Visible = v
end

restartBtn.MouseButton1Click:Connect(function()
	if confirmRow.Visible then return end
	setLabelsVisible(false)
	confirmRow.Visible = true
end)

confirmYes.MouseButton1Click:Connect(function()
	confirmRow.Visible = false
	setLabelsVisible(true)
	stateLabel.Text = "State: restarting..."
	stateLabel.TextColor3 = Color3.fromRGB(235, 190, 90)
	local ok = restartGame()

	if ok then
		stateLabel.Text = "State: restart sent - re-run to re-scan"
		stateLabel.TextColor3 = Color3.fromRGB(120, 190, 235)
	else
		stateLabel.Text = "State: restart failed"
		stateLabel.TextColor3 = Color3.fromRGB(235, 120, 120)
	end
end)

confirmNo.MouseButton1Click:Connect(function()
	confirmRow.Visible = false
	setLabelsVisible(true)
end)

-- Desired-amount slider (0..200, step 1).
local sliderCaption = Instance.new("TextLabel")
sliderCaption.Size = UDim2.new(0.5, -8, 0, 14)
sliderCaption.Position = UDim2.fromOffset(12, 104)
sliderCaption.BackgroundTransparency = 1
sliderCaption.Font = Enum.Font.GothamBold
sliderCaption.TextSize = 12
sliderCaption.Text = "Desired amount"
sliderCaption.TextColor3 = Color3.fromRGB(150, 158, 178)
sliderCaption.TextXAlignment = Enum.TextXAlignment.Left
sliderCaption.Parent = panel

local sliderValueLabel = Instance.new("TextLabel")
sliderValueLabel.Size = UDim2.new(0.5, -8, 0, 14)
sliderValueLabel.Position = UDim2.new(0.5, 4, 0, 104)
sliderValueLabel.BackgroundTransparency = 1
sliderValueLabel.Font = Enum.Font.GothamBold
sliderValueLabel.TextSize = 12
sliderValueLabel.Text = "Desired: " .. tostring(targetAmount)
sliderValueLabel.TextColor3 = Color3.fromRGB(120, 220, 140)
sliderValueLabel.TextXAlignment = Enum.TextXAlignment.Right
sliderValueLabel.Parent = panel

local sliderTrack = Instance.new("Frame")
sliderTrack.Name = "SliderTrack"
sliderTrack.Size = UDim2.new(1, -24, 0, 6)
sliderTrack.Position = UDim2.fromOffset(12, 126)
sliderTrack.BackgroundColor3 = Color3.fromRGB(52, 54, 64)
sliderTrack.BorderSizePixel = 0
sliderTrack.Active = true
sliderTrack.Parent = panel
local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(1, 0)
trackCorner.Parent = sliderTrack
local trackFill = Instance.new("Frame")
trackFill.Size = UDim2.fromScale(0, 1)
trackFill.BackgroundColor3 = Color3.fromRGB(96, 168, 108)
trackFill.BorderSizePixel = 0
trackFill.Parent = sliderTrack

local thumb = Instance.new("Frame")
thumb.Name = "SliderThumb"
thumb.Size = UDim2.fromOffset(18, 18)
thumb.Position = UDim2.new(0, -9, 0, -6)
thumb.BackgroundColor3 = Color3.fromRGB(210, 215, 228)
thumb.BorderSizePixel = 0
thumb.Active = true
thumb.Parent = sliderTrack
local thumbCorner = Instance.new("UICorner")
thumbCorner.CornerRadius = UDim.new(1, 0)
thumbCorner.Parent = thumb

local draggingSlider = false

local function updateSliderUI()
	local frac = (targetAmount - SLIDER_MIN) / (SLIDER_MAX - SLIDER_MIN)
	thumb.Position = UDim2.new(frac, -9, 0, -6)
	trackFill.Size = UDim2.fromScale(frac, 1)
	sliderValueLabel.Text = "Desired: " .. tostring(targetAmount)
end

local function setSliderFromMouse(mouseX)
	local rel = (mouseX - sliderTrack.AbsolutePosition.X) / sliderTrack.AbsoluteSize.X
	rel = math.clamp(rel, 0, 1)
	targetAmount = math.floor(rel * (SLIDER_MAX - SLIDER_MIN) + 0.5) + SLIDER_MIN
	updateSliderUI()
end

thumb.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then draggingSlider = true end
end)
thumb.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then draggingSlider = false end
end)
sliderTrack.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		setSliderFromMouse(UIS:GetMouseLocation().X)
		draggingSlider = true
	end
end)
UIS.InputChanged:Connect(function(input)
	if draggingSlider and input.UserInputType == Enum.UserInputType.MouseMovement then
		setSliderFromMouse(UIS:GetMouseLocation().X)
	end
end)

updateSliderUI()

-- Hunt toggle + round counter.
huntBtn = makeButton(140, "Hunt: OFF", { width = UDim2.new(0.45, -4, 0, 30), height = 30 })
huntBtn.MouseButton1Click:Connect(function()
	huntEnabled = not huntEnabled
	huntBtn.Text = "Hunt: " .. (huntEnabled and "ON" or "OFF")
	if huntEnabled then
		stateLabel.Text = "State: hunting..."
		stateLabel.TextColor3 = Color3.fromRGB(235, 190, 90)
	end
end)

local roundLabel = Instance.new("TextLabel")
roundLabel.Size = UDim2.new(0.52, -6, 0, 30)
roundLabel.Position = UDim2.fromOffset(168, 140)
roundLabel.BackgroundTransparency = 1
roundLabel.Font = Enum.Font.Gotham
roundLabel.TextSize = 14
roundLabel.Text = "Round: " .. tostring(round)
roundLabel.TextColor3 = Color3.fromRGB(200, 205, 220)
roundLabel.TextXAlignment = Enum.TextXAlignment.Right
roundLabel.Parent = panel

-- Value readouts.
material, pattern = makeValueLabel(176, 24, ""), makeValueLabel(216, 24, "")
material.cap.Text = "ExpeditionMaterial2 amount (best route)"
pattern.cap.Text = "Node queue pattern"

stateLabel = Instance.new("TextLabel")
stateLabel.Size = UDim2.new(1, -24, 0, 20)
stateLabel.Position = UDim2.fromOffset(12, 258)
stateLabel.BackgroundTransparency = 1
stateLabel.Font = Enum.Font.Gotham
stateLabel.TextSize = 13
stateLabel.Text = "State: idle"
stateLabel.TextColor3 = Color3.fromRGB(200, 205, 220)
stateLabel.TextXAlignment = Enum.TextXAlignment.Left
stateLabel.Parent = panel

local function updateDisplay(total, path)
	if total < 0 then
		material.val.Text = "no route"
		material.val.TextColor3 = Color3.fromRGB(235, 120, 120)
		pattern.val.Text = "-"
	else
		material.val.Text = tostring(total)
		material.val.TextColor3 = Color3.fromRGB(120, 220, 140)
		pattern.val.Text = table.concat(path, ", ")
	end
end

scanNow = function()
	local g = readGraph(target)
	if not g then
		lastBest = nil
		stateLabel.Text = "State: no map yet - waiting..."
		stateLabel.TextColor3 = Color3.fromRGB(200, 205, 220)
		updateDisplay(-1, {})
		return
	end

	local best = bestPath(g)
	lastBest = best
	updateDisplay(best.total, best.path)

	if best.total < 0 then
		stateLabel.Text = "State: no reachable path to boss"
		stateLabel.TextColor3 = Color3.fromRGB(235, 120, 120)
	else
		stateLabel.Text = "State: live"
		stateLabel.TextColor3 = Color3.fromRGB(120, 220, 140)
	end
end

_G.MHDZ = gui

-- =========================== INPUT ========================================
-- Drag the panel by its title bar.
local dragging, dragStart, panelStart = false, nil, nil
title.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = true
		dragStart = input.Position
		panelStart = panel.Position
	end
end)
title.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
	end
end)
UIS.InputChanged:Connect(function(input)
	if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local delta = input.Position - dragStart
		panel.Position = UDim2.fromOffset(panelStart.X.Offset + delta.X, panelStart.Y.Offset + delta.Y)
	end
end)

-- LeftControl toggles the whole panel.
local hidden = false
UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.LeftControl then
		hidden = not hidden
		TweenService:Create(panel, TweenInfo.new(0.15), { Visible = not hidden }):Play()
	end
end)

-- =========================== LIVE LOOP ====================================
local lastFp
local settleCount = 0
local firedForFp = false
local reachedForFp = false
local restartCooldownUntil = 0

local function flashPanel()
	local c = TweenService:Create(panel, TweenInfo.new(0.35), { BackgroundColor3 = Color3.fromRGB(66, 130, 78) })
	c:Play()
	c.Completed:Once(function()
		TweenService:Create(panel, TweenInfo.new(0.5), { BackgroundColor3 = Color3.fromRGB(24, 25, 30) }):Play()
	end)
end

task.spawn(function()
	while true do
		task.wait(POLL_INTERVAL)

		local fp = graphFingerprint()
		if fp == nil then
			if lastFp then
				lastFp = nil
				settleCount = 0
				firedForFp = false
				reachedForFp = false
				stateLabel.Text = "State: no map yet - waiting..."
				stateLabel.TextColor3 = Color3.fromRGB(200, 205, 220)
				material.val.Text = "-"
				pattern.val.Text = "-"
			end
		elseif fp ~= lastFp then
			-- A new (or regenerated) map: re-scan it.
			lastFp = fp
			settleCount = 0
			firedForFp = false
			reachedForFp = false
			scanNow()
		else
			-- Map is stable. Drive the hunt.
			settleCount = settleCount + 1
			if huntEnabled and settleCount >= 2 and os.clock() >= restartCooldownUntil then
				if lastBest and lastBest.total >= targetAmount then
					-- Goal reached: stop hunting and alert.
					huntEnabled = false
					huntBtn.Text = "Hunt: OFF"
					reachedForFp = true
					stateLabel.Text = "State: TARGET REACHED (" .. lastBest.total .. " >= " .. targetAmount .. ")"
					stateLabel.TextColor3 = Color3.fromRGB(120, 220, 140)
					flashPanel()
				elseif lastBest and lastBest.total >= 0 and not reachedForFp and not firedForFp then
					-- Below target: auto-restart to look for a better map.
					firedForFp = true
					restartCooldownUntil = os.clock() + 4
					stateLabel.Text = "State: hunting (" .. lastBest.total .. "/" .. targetAmount .. ") - restarting round " .. round
					stateLabel.TextColor3 = Color3.fromRGB(235, 190, 90)
					restartGame()
				end
			end
		end
	end
end)

-- =========================== CLEANUP ======================================
if STATE then STATE.onCleanup(function()
	if gui then pcall(function() gui:Destroy() end) end
	if _G.MHDZ == gui then _G.MHDZ = nil end
	gui = nil
end) end