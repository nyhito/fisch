--[[
    FischFright 3 - Haunted Ritual Auto v1.3 Mobile

    Fluxo observado no jogo:
      Frankenstein -> option 2 -> option 3 (Haunted Ritual)
      Bat Wing -> 7 Jack-o-Lantern offerings -> 3 pedestais de 50 Treats
      Detecta House XXX -> equipa Candy Bucket -> Knock
      Tenta acompanhar o alvo do GhostMinigame -> tenta sair usando uma vara

    Observacoes:
      * O auto do GhostMinigame e experimental porque o nome interno do alvo
        movel nao apareceu no log. O script procura o elemento que se move.
      * Cada ciclo consome os itens do Haunted Ritual e 150 Treats.
      * Toque no botao flutuante para ligar/desligar. Arraste para mover.
]]

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Backpack = Player:WaitForChild("Backpack")
local Env = getgenv()

-- Limpa versoes anteriores.
if Env.STOP_RITUAL_SCANNER then
    pcall(Env.STOP_RITUAL_SCANNER)
end

if Env.HAUNTED_AUTO_STOP then
    pcall(Env.HAUNTED_AUTO_STOP)
end

local CONFIG = {
    RITUAL_COOLDOWN = 610, -- 10 min + margem de sincronizacao
    HOUSE_NOTICE_TIMEOUT = 25,
    GHOST_START_TIMEOUT = 10,
    GHOST_MAX_TIME = 22,
    TELEPORT_HEIGHT = 3.5,
    AUTO_GHOST = true,
    AUTO_EXIT_WITH_ROD = true,
    USE_MIRROR_FALLBACK = true,
    PROMPT_SYNC_WAIT = 0.90,
    PROMPT_AFTER_WAIT = 0.75,
    FRANKENSTEIN_RETRIES = 4,
}

Env.HAUNTED_AUTO_CONFIG = CONFIG

local HOUSE_POSITIONS = {
    [293] = Vector3.new(-14809, 151, -9802),
    [506] = Vector3.new(-14754, 148, -9794),
    [167] = Vector3.new(-14891, 146, -9754),
    [374] = Vector3.new(-14861, 146, -9713),
    [111] = Vector3.new(-14821, 147, -9660),
    [632] = Vector3.new(-14806.3, 155.2, -9710.8),
    [745] = Vector3.new(-14702, 149, -9766),
    [429] = Vector3.new(-14725, 147, -9719),
    [891] = Vector3.new(-14630, 146, -9756),
    [477] = Vector3.new(-14532, 144, -9746),
    [666] = Vector3.new(-14627, 146, -9593),
    [979] = Vector3.new(-14699, 157, -9454),
    [813] = Vector3.new(-14998.5, 183.9, -9574.1),
    [249] = Vector3.new(-14716, 147, -9976),
    [358] = Vector3.new(-14717, 147, -10055),
    [467] = Vector3.new(-14823, 146, -10100),
}

local OFFERINGS = {
    "Sour Patch Salmon",
    "Jawbreaker Jellyfish",
    "Taffy Trout",
    "Bubblegum Blobfish",
    "Licorice Lamprey",
    "Candy Corn Pack",
    "Pop-Rock Pufferfish",
}

local Connections = {}
local Enabled = false
local Running = false
local Generation = 0
local WaitingForHouse = false
local DetectedHouse = nil
local LastRitualActivation = nil
local CurrentStatus = "Desligado"

local function Connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(Connections, connection)
    return connection
end

local function Log(message)
    print("[HAUNTED AUTO] " .. tostring(message))
end

local function GetCharacter()
    local character = Player.Character or Player.CharacterAdded:Wait()
    local root = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 10)
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return character, root, humanoid
end

local function IsCurrent(token)
    return Enabled and token == Generation
end

local function WaitCancelable(seconds, token)
    local finishAt = os.clock() + seconds

    while os.clock() < finishAt do
        if token and not IsCurrent(token) then
            return false
        end
        task.wait(math.min(0.1, finishAt - os.clock()))
    end

    return true
end

local function GetWorldPosition(object)
    local current = object

    while current and current ~= workspace do
        if current:IsA("BasePart") then
            return current.Position, current.CFrame
        end

        if current:IsA("Model") then
            local part = current.PrimaryPart
                or current:FindFirstChildWhichIsA("BasePart", true)
            if part then
                return part.Position, part.CFrame
            end
        end

        current = current.Parent
    end
end

local function TeleportTo(position)
    local character, root, humanoid = GetCharacter()
    if not character or not root then
        return false
    end

    if humanoid then
        humanoid.Sit = false
    end

    root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
    character:PivotTo(CFrame.new(position))
    return true
end

local function TeleportNearObject(object)
    local position, cframe = GetWorldPosition(object)
    if not position then
        return false
    end

    local offset = Vector3.new(0, CONFIG.TELEPORT_HEIGHT, 0)
    if cframe then
        offset = offset - cframe.LookVector * 2
    end

    return TeleportTo(position + offset)
end

local function FindPrompt(predicate, root)
    root = root or workspace

    for _, object in ipairs(root:GetDescendants()) do
        if object:IsA("ProximityPrompt") and predicate(object) then
            return object
        end
    end
end

local function FindPrompts(predicate, root)
    root = root or workspace
    local result = {}

    for _, object in ipairs(root:GetDescendants()) do
        if object:IsA("ProximityPrompt") and predicate(object) then
            table.insert(result, object)
        end
    end

    return result
end

local function FirePromptDirect(prompt)
    if not prompt or not prompt.Parent then
        return false
    end

    -- fireproximityprompt aciona o prompt diretamente e funciona no mobile
    -- sem depender do botao E ou da interface de toque do Roblox.
    if fireproximityprompt then
        local ok = pcall(function()
            fireproximityprompt(prompt, math.max(prompt.HoldDuration, 0))
        end)
        if ok then
            return true
        end
    end

    -- Segundo metodo direto para executores sem fireproximityprompt.
    local holdOk = pcall(function()
        prompt:InputHoldBegin()
        task.wait(math.max(prompt.HoldDuration, 0.05) + 0.05)
        prompt:InputHoldEnd()
    end)
    if holdOk then
        return true
    end

    -- Ultimo fallback. Alguns executores mobile aceitam a tecla virtual.
    return pcall(function()
        local key = prompt.KeyboardKeyCode
        if key == Enum.KeyCode.Unknown then
            key = Enum.KeyCode.E
        end
        VirtualInputManager:SendKeyEvent(true, key, false, game)
        task.wait(math.max(prompt.HoldDuration, 0.05) + 0.05)
        VirtualInputManager:SendKeyEvent(false, key, false, game)
    end)
end

local function TriggerPrompt(prompt, token)
    if not prompt or not prompt.Parent then
        return false
    end

    if token and not IsCurrent(token) then
        return false
    end

    if not TeleportNearObject(prompt) then
        return false
    end

    -- O servidor precisa receber a nova posicao antes do prompt. Sem esta
    -- pausa o prompt some no cliente, mas o servidor pode ignorar a acao.
    if not WaitCancelable(CONFIG.PROMPT_SYNC_WAIT, token) then
        return false
    end

    if not FirePromptDirect(prompt) then
        return false
    end

    return WaitCancelable(CONFIG.PROMPT_AFTER_WAIT, token)
end

local function IsGuiVisible(object)
    local current = object

    while current and current ~= game do
        if current:IsA("ScreenGui") and not current.Enabled then
            return false
        end
        if current:IsA("GuiObject") and not current.Visible then
            return false
        end
        current = current.Parent
    end

    return object and object.Parent ~= nil
end

local function ClickGui(button)
    if not button or not button.Parent or not IsGuiVisible(button) then
        return false
    end

    -- Aciona diretamente os sinais do botao quando o executor permite.
    -- Isso evita depender de mouse em aparelhos mobile.
    if firesignal then
        local activated = pcall(function()
            firesignal(button.MouseButton1Click)
        end)
        if activated then
            return true
        end
    end

    local center = button.AbsolutePosition + button.AbsoluteSize / 2

    local ok = pcall(function()
        VirtualInputManager:SendMouseMoveEvent(center.X, center.Y, game)
        VirtualInputManager:SendMouseButtonEvent(
            center.X,
            center.Y,
            0,
            true,
            game,
            0
        )
        task.wait(0.06)
        VirtualInputManager:SendMouseButtonEvent(
            center.X,
            center.Y,
            0,
            false,
            game,
            0
        )
    end)

    return ok
end

local function WaitForOption(number, timeout, token)
    local finishAt = os.clock() + timeout
    local optionName = tostring(number) .. "option"

    while os.clock() < finishAt do
        if token and not IsCurrent(token) then
            return nil
        end

        local options = PlayerGui:FindFirstChild("options")
        local safezone = options and options:FindFirstChild("safezone")
        local option = safezone and safezone:FindFirstChild(optionName)
        local button = option and option:FindFirstChild("button")

        if button and button:IsA("GuiButton") and IsGuiVisible(button) then
            return button
        end

        task.wait(0.1)
    end
end

local function FireConnections(signal, ...)
    if not getconnections then
        return false
    end

    local ok, connections = pcall(getconnections, signal)
    if not ok or type(connections) ~= "table" then
        return false
    end

    local fired = false
    local arguments = {...}

    for _, connection in ipairs(connections) do
        if connection.Enabled ~= false then
            local connectionOk = false

            if connection.Fire then
                connectionOk = pcall(function()
                    connection:Fire(table.unpack(arguments))
                end)
            elseif connection.Function then
                connectionOk = pcall(function()
                    connection.Function(table.unpack(arguments))
                end)
            end

            fired = connectionOk or fired
        end
    end

    return fired
end

local function FireEngineSignal(signal, ...)
    local arguments = {...}

    -- Prefere chamar as conexoes reais do Dialog quando o executor expoe
    -- getconnections. Assim nao aceitamos um firesignal vazio como sucesso.
    if FireConnections(signal, table.unpack(arguments)) then
        return true
    end

    if firesignal then
        local ok = pcall(function()
            firesignal(signal, table.unpack(arguments))
        end)
        if ok then
            return true
        end
    end

    return false
end

local function ClickPromptGuiForFrankenstein()
    local bestObject = nil
    local bestScore = 0

    for _, object in ipairs(PlayerGui:GetDescendants()) do
        if (object:IsA("TextLabel") or object:IsA("TextButton"))
            and IsGuiVisible(object) then
            local text = string.lower(object.Text or "")
            local score = 0

            if string.find(text, "frankenstein", 1, true) then
                score = score + 100
            end
            if string.find(text, "talk", 1, true) then
                score = score + 50
            end

            if score > bestScore then
                bestScore = score
                bestObject = object
            end
        end
    end

    if not bestObject then
        return false
    end

    local clickable = bestObject
    local current = bestObject

    for _ = 1, 5 do
        if current:IsA("GuiButton") then
            clickable = current
            break
        end
        if not current.Parent or not current.Parent:IsA("GuiObject") then
            break
        end
        current = current.Parent
        clickable = current
    end

    local center = clickable.AbsolutePosition + clickable.AbsoluteSize / 2
    local touched = pcall(function()
        VirtualInputManager:SendTouchEvent(0, 0, center.X, center.Y)
        task.wait(0.08)
        VirtualInputManager:SendTouchEvent(0, 2, center.X, center.Y)
    end)

    pcall(function()
        VirtualInputManager:SendMouseMoveEvent(center.X, center.Y, game)
        VirtualInputManager:SendMouseButtonEvent(
            center.X,
            center.Y,
            0,
            true,
            game,
            0
        )
        task.wait(0.08)
        VirtualInputManager:SendMouseButtonEvent(
            center.X,
            center.Y,
            0,
            false,
            game,
            0
        )
    end)

    return touched or true
end

local function PressPromptKey(prompt)
    local key = prompt.KeyboardKeyCode
    if key == Enum.KeyCode.Unknown then
        key = Enum.KeyCode.E
    end

    return pcall(function()
        VirtualInputManager:SendKeyEvent(true, key, false, game)
        task.wait(math.max(prompt.HoldDuration, 0.05) + 0.08)
        VirtualInputManager:SendKeyEvent(false, key, false, game)
    end)
end

local function TryFrankensteinMethod(prompt, label, callback, token, waitTime)
    if not IsCurrent(token) then
        return nil
    end

    SetStatus("Frankenstein: " .. label)
    Log("Tentando interação: " .. label)

    local ok, attempted = pcall(callback)
    if not ok then
        Log("Método falhou: " .. label .. " | " .. tostring(attempted))
    end

    return WaitForOption(2, waitTime or 2.5, token)
end

local function TriggerFrankensteinDialogue(prompt, token)
    local option2

    -- O Dialog do Fisch pode escutar diretamente prompt.Triggered.
    option2 = TryFrankensteinMethod(prompt, "sinal direto", function()
        return FireEngineSignal(prompt.Triggered, Player)
    end, token, 2.5)
    if option2 then
        return option2
    end

    -- Algumas versoes usam o evento central do ProximityPromptService.
    option2 = TryFrankensteinMethod(prompt, "sinal global", function()
        return FireEngineSignal(
            ProximityPromptService.PromptTriggered,
            prompt,
            Player
        )
    end, token, 2.5)
    if option2 then
        return option2
    end

    -- Tenta a funcao do executor sem parametros extras.
    option2 = TryFrankensteinMethod(prompt, "prompt direto", function()
        if not fireproximityprompt then
            return false
        end
        return pcall(function()
            fireproximityprompt(prompt)
        end)
    end, token, 3.5)
    if option2 then
        return option2
    end

    -- Alguns executores mobile exigem a assinatura com SkipHold=true.
    option2 = TryFrankensteinMethod(prompt, "prompt forçado", function()
        if not fireproximityprompt then
            return false
        end
        return pcall(function()
            fireproximityprompt(prompt, 0, true)
        end)
    end, token, 3.5)
    if option2 then
        return option2
    end

    -- Ultimos fallbacks: toca no GUI mobile, simula o hold e envia a tecla.
    option2 = TryFrankensteinMethod(prompt, "toque mobile", function()
        return ClickPromptGuiForFrankenstein()
    end, token, 2.5)
    if option2 then
        return option2
    end

    option2 = TryFrankensteinMethod(prompt, "hold direto", function()
        prompt:InputHoldBegin()
        task.wait(math.max(prompt.HoldDuration, 0.05) + 0.08)
        prompt:InputHoldEnd()
        return true
    end, token, 2.5)
    if option2 then
        return option2
    end

    return TryFrankensteinMethod(prompt, "entrada virtual", function()
        return PressPromptKey(prompt)
    end, token, 3)
end

local function GetRitualComponents()
    local world = workspace:FindFirstChild("world")
    local map = world and world:FindFirstChild("map")
    local event = map and map:FindFirstChild("Fischfright26")
    return event and event:FindFirstChild("RitualComponents")
end

local function WaitForOfferingPrompt(objectText, timeout, token)
    local finishAt = os.clock() + timeout

    while os.clock() < finishAt do
        if token and not IsCurrent(token) then
            return nil
        end

        local components = GetRitualComponents()
        if components then
            local prompt = FindPrompt(function(candidate)
                return candidate.Enabled
                    and string.lower(candidate.ObjectText)
                        == string.lower(objectText)
            end, components)

            if prompt then
                return prompt
            end
        end

        task.wait(0.15)
    end
end

-- Interface flutuante
local GuiParent = CoreGui
if gethui then
    pcall(function()
        GuiParent = gethui()
    end)
end

local oldGui = GuiParent:FindFirstChild("HauntedRitualAutoGui")
if oldGui then
    oldGui:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "HauntedRitualAutoGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent = GuiParent

local Panel = Instance.new("Frame")
Panel.Name = "Panel"
Panel.Size = UDim2.fromOffset(172, 80)
Panel.Position = UDim2.new(1, -192, 0.38, 0)
Panel.BackgroundColor3 = Color3.fromRGB(5, 5, 5)
Panel.BackgroundTransparency = 0.06
Panel.BorderSizePixel = 0
Panel.Active = true
Panel.Parent = ScreenGui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 10)
panelCorner.Parent = Panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(70, 70, 70)
panelStroke.Transparency = 0.15
panelStroke.Thickness = 1
panelStroke.Parent = Panel

local ToggleButton = Instance.new("TextButton")
ToggleButton.Name = "Toggle"
ToggleButton.Size = UDim2.fromOffset(164, 45)
ToggleButton.Position = UDim2.fromOffset(4, 4)
ToggleButton.BackgroundColor3 = Color3.fromRGB(13, 13, 13)
ToggleButton.TextColor3 = Color3.fromRGB(210, 210, 210)
ToggleButton.TextSize = 12
ToggleButton.TextWrapped = true
ToggleButton.Font = Enum.Font.GothamBold
ToggleButton.AutoButtonColor = false
ToggleButton.Active = true
ToggleButton.Parent = Panel

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = ToggleButton

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Transparency = 0.82
stroke.Thickness = 1
stroke.Parent = ToggleButton

local UnloadButton = Instance.new("TextButton")
UnloadButton.Name = "Unload"
UnloadButton.Size = UDim2.fromOffset(164, 23)
UnloadButton.Position = UDim2.fromOffset(4, 53)
UnloadButton.BackgroundColor3 = Color3.fromRGB(11, 11, 11)
UnloadButton.TextColor3 = Color3.fromRGB(225, 85, 85)
UnloadButton.Text = "UNLOAD"
UnloadButton.TextSize = 10
UnloadButton.Font = Enum.Font.GothamBold
UnloadButton.AutoButtonColor = true
UnloadButton.Parent = Panel

local unloadCorner = Instance.new("UICorner")
unloadCorner.CornerRadius = UDim.new(0, 6)
unloadCorner.Parent = UnloadButton

local function SetStatus(status)
    CurrentStatus = tostring(status)
    if ToggleButton and ToggleButton.Parent then
        ToggleButton.BackgroundColor3 = Color3.fromRGB(13, 13, 13)
        ToggleButton.TextColor3 = Enabled
            and Color3.fromRGB(80, 235, 135)
            or Color3.fromRGB(210, 210, 210)
        ToggleButton.Text = string.format(
            "HAUNTED: %s\n%s",
            Enabled and "ON" or "OFF",
            CurrentStatus
        )
    end
    Log(status)
end

local function ParseHouseMessage(rawText)
    if type(rawText) ~= "string" or rawText == "" then
        return
    end

    local plain = string.gsub(rawText, "<.->", "")
    local lower = string.lower(plain)

    if not string.find(lower, "house", 1, true)
        or not string.find(lower, "haunt", 1, true) then
        return
    end

    local number = string.match(lower, "house%s*#?%s*(%d+)")
    number = tonumber(number)

    if number and HOUSE_POSITIONS[number] then
        DetectedHouse = number
        SetStatus("Casa detectada: " .. number)
    end
end

local HookedText = setmetatable({}, {__mode = "k"})

local function HookTextObject(object)
    if HookedText[object] then
        return
    end

    if not object:IsA("TextLabel") and not object:IsA("TextButton") then
        return
    end

    HookedText[object] = true

    Connect(object:GetPropertyChangedSignal("Text"), function()
        if WaitingForHouse then
            ParseHouseMessage(object.Text)
        end
    end)
end

for _, object in ipairs(PlayerGui:GetDescendants()) do
    HookTextObject(object)
end

Connect(PlayerGui.DescendantAdded, HookTextObject)

pcall(function()
    Connect(TextChatService.MessageReceived, function(message)
        if WaitingForHouse then
            ParseHouseMessage(message.Text)
        end
    end)
end)

local function ScanExistingHouseText()
    for _, object in ipairs(PlayerGui:GetDescendants()) do
        if object:IsA("TextLabel") or object:IsA("TextButton") then
            ParseHouseMessage(object.Text)
            if DetectedHouse then
                return DetectedHouse
            end
        end
    end
end

local function IsGreen(color)
    local h, s, v = Color3.toHSV(color)
    return h >= 0.20 and h <= 0.48 and s >= 0.35 and v >= 0.35
end

local function ScoreHauntedHouse(model, houseNumber)
    local score = 0

    local function inspectAttributes(object)
        for name, value in pairs(object:GetAttributes()) do
            local lowerName = string.lower(tostring(name))
            if (string.find(lowerName, "haunt", 1, true)
                or string.find(lowerName, "active", 1, true))
                and value == true then
                score = score + 500
            end
        end
    end

    inspectAttributes(model)

    for _, object in ipairs(model:GetDescendants()) do
        inspectAttributes(object)

        local lowerName = string.lower(object.Name)

        if (string.find(lowerName, "haunt", 1, true)
            or string.find(lowerName, "ghost", 1, true)) then
            if not object:IsA("GuiObject") or IsGuiVisible(object) then
                score = score + 25
            end
        end

        if object:IsA("TextLabel") and object.Visible then
            local textNumber = tonumber(string.match(object.Text or "", "%d+"))
            if textNumber == houseNumber and IsGreen(object.TextColor3) then
                score = score + 150
            end
        elseif object:IsA("BasePart") then
            if IsGreen(object.Color)
                and (object.Material == Enum.Material.Neon
                    or string.find(lowerName, "glow", 1, true)
                    or string.find(lowerName, "light", 1, true)) then
                score = score + 8
            end
        elseif object:IsA("PointLight")
            or object:IsA("SpotLight")
            or object:IsA("SurfaceLight") then
            if object.Enabled and IsGreen(object.Color) then
                score = score + 8
            end
        elseif object:IsA("ParticleEmitter") then
            if object.Enabled then
                local keypoints = object.Color.Keypoints
                if #keypoints > 0 and IsGreen(keypoints[1].Value) then
                    score = score + 5
                end
            end
        end
    end

    return score
end

local function GetHousesFolder()
    local world = workspace:FindFirstChild("world")
    local map = world and world:FindFirstChild("map")
    local event = map and map:FindFirstChild("Fischfright26")
    return event and event:FindFirstChild("TrickOrTreat-Houses")
end

local function ScanLoadedHouses()
    local folder = GetHousesFolder()
    if not folder then
        return nil
    end

    local bestNumber = nil
    local bestScore = 0

    for number in pairs(HOUSE_POSITIONS) do
        local model = folder:FindFirstChild(tostring(number))
        if model then
            local score = ScoreHauntedHouse(model, number)
            if score > bestScore then
                bestScore = score
                bestNumber = number
            end
        end
    end

    if bestScore >= 40 then
        Log("Fallback visual escolheu casa " .. bestNumber .. " (score " .. bestScore .. ")")
        return bestNumber
    end
end

local function TourHousesForHaunt(token)
    SetStatus("Procurando brilho verde")

    local bestNumber = nil
    local bestScore = 0

    for number, position in pairs(HOUSE_POSITIONS) do
        if not IsCurrent(token) then
            return nil
        end

        TeleportTo(position + Vector3.new(0, 5, 4))
        WaitCancelable(0.30, token)

        local folder = GetHousesFolder()
        local model = folder and folder:FindFirstChild(tostring(number))
        if model then
            local score = ScoreHauntedHouse(model, number)
            if score > bestScore then
                bestScore = score
                bestNumber = number
            end
        end
    end

    if bestScore >= 40 then
        Log("Busca visual escolheu casa " .. bestNumber .. " (score " .. bestScore .. ")")
        return bestNumber
    end

    return nil
end

local function FindFrankensteinPrompt()
    return FindPrompt(function(prompt)
        return string.lower(prompt.ObjectText) == "frankenstein"
            and string.lower(prompt.ActionText) == "talk"
    end)
end

local function WaitForFrankensteinPrompt(timeout, token)
    local finishAt = os.clock() + timeout

    while os.clock() < finishAt do
        if not IsCurrent(token) then
            return nil
        end

        local prompt = FindFrankensteinPrompt()
        if prompt and prompt.Parent and prompt.Enabled then
            return prompt
        end

        task.wait(0.15)
    end
end

local function OpenFrankensteinDialogue(token)
    -- Se a caixa ja estiver aberta, nao toca novamente no NPC.
    local alreadyOpen = WaitForOption(2, 0.25, token)
    if alreadyOpen then
        return alreadyOpen
    end

    for attempt = 1, CONFIG.FRANKENSTEIN_RETRIES do
        if not IsCurrent(token) then
            return nil, "Cancelado"
        end

        SetStatus(string.format(
            "Falando com Frankenstein %d/%d",
            attempt,
            CONFIG.FRANKENSTEIN_RETRIES
        ))

        local _, _, humanoid = GetCharacter()
        if humanoid then
            humanoid:UnequipTools()
        end

        local prompt = WaitForFrankensteinPrompt(4, token)
        if not prompt then
            TeleportTo(Vector3.new(-15107.4, 151.6, -9620.4))
            WaitCancelable(1.0, token)
            prompt = WaitForFrankensteinPrompt(3, token)
        end

        if prompt then
            -- Posiciona, aguarda o servidor reconhecer o jogador e tenta
            -- todos os caminhos usados pelo Dialog do jogo.
            TeleportNearObject(prompt)
            WaitCancelable(CONFIG.PROMPT_SYNC_WAIT, token)

            local option2 = TriggerFrankensteinDialogue(prompt, token)
            if option2 then
                return option2
            end
        end

        -- Quando a tentativa e ignorada pelo servidor, o prompt pode sumir
        -- por um instante. Espera ele voltar antes de repetir.
        WaitCancelable(1.2, token)
    end

    return nil, "Diálogo do Frankenstein não abriu após as tentativas"
end

local function StartHauntedRitual(token)
    SetStatus("Indo ao Frankenstein")

    -- Se o ritual ja estiver ativo, pula completamente o dialogo.
    local activePrompt = WaitForOfferingPrompt("Wants Bat Wing", 0.25, token)
        or WaitForOfferingPrompt("Sour Patch Salmon", 0.25, token)
    if activePrompt then
        SetStatus("Ritual já ativo")
        return true
    end

    TeleportTo(Vector3.new(-15107.4, 151.6, -9620.4))
    WaitCancelable(1.0, token)

    local option2, dialogueReason = OpenFrankensteinDialogue(token)
    if not option2 then
        return false, dialogueReason or "Diálogo do Frankenstein não abriu"
    end

    SetStatus("Abrindo lista de rituais")
    ClickGui(option2)
    WaitCancelable(1.3, token)

    local option3 = WaitForOption(3, 8, token)
    if not option3 then
        return false, "Opção 3 do Haunted Ritual não apareceu"
    end

    ClickGui(option3)
    WaitCancelable(1.0, token)

    -- Confirma que o ritual realmente começou.
    local proof = WaitForOfferingPrompt("Wants Bat Wing", 8, token)
        or WaitForOfferingPrompt("Sour Patch Salmon", 2, token)

    if not proof then
        return false, "Ritual não iniciou (pode estar em cooldown)"
    end

    return true
end

local function PlaceOneOffering(objectText, label, token)
    SetStatus("Colocando " .. label)

    local prompt = WaitForOfferingPrompt(objectText, 7, token)
    if not prompt then
        return false, "Não achei prompt: " .. objectText
    end

    if not TriggerPrompt(prompt, token) then
        return false, "Falha ao acionar: " .. objectText
    end

    return true
end

local function PlaceAllOfferings(token)
    local ok, reason = PlaceOneOffering("Wants Bat Wing", "Bat Wing", token)
    if not ok then
        return false, reason
    end

    for _, offering in ipairs(OFFERINGS) do
        ok, reason = PlaceOneOffering(offering, offering, token)
        if not ok then
            return false, reason
        end
    end

    -- Treats somente depois de todas as oferendas, conforme observado.
    SetStatus("Conferindo pedestais de Treats")
    local components = GetRitualComponents()
    if not components then
        return false, "RitualComponents desapareceu"
    end

    local pedestals = FindPrompts(function(prompt)
        return prompt.Enabled
            and string.lower(prompt.ObjectText) == "treat pedestal"
            and string.find(string.lower(prompt.ActionText), "50", 1, true)
    end, components)

    if #pedestals < 3 then
        return false, "Só encontrei " .. #pedestals .. "/3 pedestais de Treats"
    end

    -- A mensagem com o número pode aparecer no mesmo instante do último
    -- pedestal. Começa a escutar antes para não perder esse aviso.
    WaitingForHouse = true
    DetectedHouse = nil

    table.sort(pedestals, function(a, b)
        local positionA = GetWorldPosition(a)
        local positionB = GetWorldPosition(b)
        if not positionA or not positionB then
            return a:GetFullName() < b:GetFullName()
        end
        if positionA.X == positionB.X then
            return positionA.Z < positionB.Z
        end
        return positionA.X < positionB.X
    end)

    for index = 1, 3 do
        SetStatus("Treat Pedestal " .. index .. "/3")
        if not TriggerPrompt(pedestals[index], token) then
            return false, "Falha no Treat Pedestal " .. index
        end
    end

    LastRitualActivation = os.clock()
    return true
end

local function WaitForHauntedHouse(token)
    WaitingForHouse = true
    SetStatus("Esperando número da casa")

    local finishAt = os.clock() + CONFIG.HOUSE_NOTICE_TIMEOUT

    while os.clock() < finishAt do
        if not IsCurrent(token) then
            WaitingForHouse = false
            return nil
        end

        ScanExistingHouseText()
        if DetectedHouse then
            WaitingForHouse = false
            return DetectedHouse
        end

        local visual = ScanLoadedHouses()
        if visual then
            WaitingForHouse = false
            DetectedHouse = visual
            return visual
        end

        task.wait(0.15)
    end

    local toured = TourHousesForHaunt(token)
    WaitingForHouse = false
    DetectedHouse = toured
    return toured
end

local function GetHouseDoorPrompt(number, token)
    local position = HOUSE_POSITIONS[number]
    if not position then
        return nil
    end

    TeleportTo(position + Vector3.new(0, 4, 3))

    local finishAt = os.clock() + 8
    while os.clock() < finishAt do
        if not IsCurrent(token) then
            return nil
        end

        local folder = GetHousesFolder()
        local house = folder and folder:FindFirstChild(tostring(number))
        local door = house and house:FindFirstChild("Door")

        if door then
            local prompt = FindPrompt(function(candidate)
                return candidate.Enabled
                    and string.lower(candidate.ActionText) == "knock"
                    and string.lower(candidate.ObjectText) == "door"
            end, door)

            if prompt then
                return prompt
            end
        end

        task.wait(0.15)
    end
end

local function FindToolByName(name)
    local character = Player.Character

    for _, container in ipairs({character, Backpack}) do
        if container then
            for _, object in ipairs(container:GetChildren()) do
                if object:IsA("Tool")
                    and string.lower(object.Name) == string.lower(name) then
                    return object
                end
            end
        end
    end
end

local function EquipTool(tool)
    if not tool then
        return false
    end

    local _, _, humanoid = GetCharacter()
    if not humanoid then
        return false
    end

    if tool.Parent ~= Player.Character then
        humanoid:EquipTool(tool)
        task.wait(0.25)
    end

    return tool.Parent == Player.Character
end

local function GetGhostGui()
    local gui = PlayerGui:FindFirstChild("GhostMinigame")
    if not gui or not IsGuiVisible(gui) then
        return nil
    end
    return gui
end

local function IsCandidateGhostObject(object)
    if not object:IsA("GuiObject") or not IsGuiVisible(object) then
        return false
    end

    local size = object.AbsoluteSize
    if size.X < 12 or size.Y < 12 or size.X > 420 or size.Y > 420 then
        return false
    end

    local lower = string.lower(object.Name)
    local blocked = {
        "hint", "label", "bar", "fill", "progress", "background",
        "container", "close", "stroke", "gradient", "timer"
    }

    for _, word in ipairs(blocked) do
        if string.find(lower, word, 1, true) then
            return false
        end
    end

    return object:IsA("ImageLabel")
        or object:IsA("ImageButton")
        or object:IsA("Frame")
end

local function FindMovingGhostTarget(gui, token)
    local positions = {}
    local candidates = {}

    for _, object in ipairs(gui:GetDescendants()) do
        if IsCandidateGhostObject(object) then
            positions[object] = object.AbsolutePosition + object.AbsoluteSize / 2
            table.insert(candidates, object)
        end
    end

    WaitCancelable(0.30, token)

    local best = nil
    local bestScore = -math.huge

    for _, object in ipairs(candidates) do
        if object.Parent and IsCandidateGhostObject(object) then
            local center = object.AbsolutePosition + object.AbsoluteSize / 2
            local movement = (center - positions[object]).Magnitude
            local lower = string.lower(object.Name)
            local score = movement

            if string.find(lower, "ghost", 1, true)
                or string.find(lower, "spirit", 1, true) then
                score = score + 200
            elseif string.find(lower, "target", 1, true) then
                score = score + 100
            end

            if score > bestScore and (movement > 0.5 or score >= 100) then
                bestScore = score
                best = object
            end
        end
    end

    return best
end

local function AutoGhostMinigame(gui, token)
    if not CONFIG.AUTO_GHOST then
        return false, "Auto Ghost desativado"
    end

    SetStatus("Procurando alvo do fantasma")
    local target = FindMovingGhostTarget(gui, token)

    if not target then
        return false, "Alvo móvel não identificado"
    end

    Log("Alvo do GhostMinigame: " .. target:GetFullName())
    SetStatus("Seguindo o fantasma")

    local pressed = false
    local lastX, lastY = 0, 0
    local finishAt = os.clock() + CONFIG.GHOST_MAX_TIME

    while os.clock() < finishAt and IsCurrent(token) and GetGhostGui() do
        if not target.Parent or not IsCandidateGhostObject(target) then
            target = FindMovingGhostTarget(gui, token)
            if not target then
                break
            end
        end

        local center = target.AbsolutePosition + target.AbsoluteSize / 2
        lastX, lastY = center.X, center.Y

        pcall(function()
            VirtualInputManager:SendMouseMoveEvent(lastX, lastY, game)
            if not pressed then
                VirtualInputManager:SendMouseButtonEvent(
                    lastX,
                    lastY,
                    0,
                    true,
                    game,
                    0
                )
                pressed = true
            end
        end)

        RunService.RenderStepped:Wait()
    end

    if pressed then
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(
                lastX,
                lastY,
                0,
                false,
                game,
                0
            )
        end)
    end

    if not GetGhostGui() then
        return true
    end

    return false, "Minigame continuou aberto"
end

local function FindPreferredRod()
    local preferred = {
        "Olympian Godbreaker",
        "Olympian",
        "MiguRod",
        "Migu Rod",
    }

    for _, name in ipairs(preferred) do
        local tool = FindToolByName(name)
        if tool then
            return tool
        end
    end

    for _, object in ipairs(Backpack:GetChildren()) do
        if object:IsA("Tool") then
            local lower = string.lower(object.Name)
            if string.find(lower, "rod", 1, true)
                or string.find(lower, "spinecaster", 1, true) then
                return object
            end
        end
    end
end

local function TryExitSpiritRealm(houseNumber, token)
    if not CONFIG.AUTO_EXIT_WITH_ROD then
        return false
    end

    SetStatus("Tentando sair com a vara")

    local rod = FindPreferredRod()
    if rod and EquipTool(rod) then
        local _, root = GetCharacter()
        local camera = workspace.CurrentCamera

        if root and camera then
            camera.CFrame = CFrame.lookAt(
                camera.CFrame.Position,
                root.Position - Vector3.new(0, 14, 0)
            )
        end

        local fishGui = PlayerGui:FindFirstChild("FishButtonMobile")
        local frame = fishGui and fishGui:FindFirstChild("Frame")
        local button = frame and frame:FindFirstChild("button")

        if button and button:IsA("GuiButton") and IsGuiVisible(button) then
            ClickGui(button)
        else
            pcall(function()
                rod:Activate()
            end)
        end

        WaitCancelable(1.4, token)

        local _, _, humanoid = GetCharacter()
        if humanoid then
            humanoid:UnequipTools()
        end
    end

    WaitCancelable(2.0, token)

    local _, root = GetCharacter()
    local outsidePosition = HOUSE_POSITIONS[houseNumber]
    local appearsOutside = root and outsidePosition
        and (root.Position - outsidePosition).Magnitude <= 140

    if appearsOutside then
        return true
    end

    if CONFIG.USE_MIRROR_FALLBACK then
        local mirror = FindToolByName("Magic Mirror")
        if mirror and EquipTool(mirror) then
            SetStatus("Usando Magic Mirror")
            pcall(function()
                mirror:Activate()
            end)
            WaitCancelable(1.5, token)
        end
    end

    return true
end

local function VisitHauntedHouse(number, token)
    SetStatus("Indo para House " .. number)

    local doorPrompt = GetHouseDoorPrompt(number, token)
    if not doorPrompt then
        return false, "Prompt Knock da House " .. number .. " não carregou"
    end

    local bucket = FindToolByName("Candy Bucket")
    if not bucket then
        return false, "Candy Bucket não encontrado"
    end

    SetStatus("Equipando Candy Bucket")
    if not EquipTool(bucket) then
        return false, "Não consegui equipar Candy Bucket"
    end

    WaitCancelable(0.35, token)
    SetStatus("Knock na House " .. number)
    TriggerPrompt(doorPrompt, token)

    local finishAt = os.clock() + CONFIG.GHOST_START_TIMEOUT
    local ghostGui = nil

    while os.clock() < finishAt do
        if not IsCurrent(token) then
            return false, "Cancelado"
        end

        ghostGui = GetGhostGui()
        if ghostGui then
            break
        end

        task.wait(0.1)
    end

    if not ghostGui then
        return false, "RNG expulsou: GhostMinigame não apareceu"
    end

    local won, ghostReason = AutoGhostMinigame(ghostGui, token)
    if not won then
        SetStatus("Ghost manual: " .. ghostReason)

        -- Da tempo para o jogador terminar manualmente.
        local manualFinish = os.clock() + 25
        while os.clock() < manualFinish and IsCurrent(token) and GetGhostGui() do
            task.wait(0.2)
        end
    end

    if GetGhostGui() then
        return false, "GhostMinigame não foi concluído"
    end

    WaitCancelable(1.0, token)
    TryExitSpiritRealm(number, token)
    return true
end

local function RunOneCycle(token)
    local started, reason = StartHauntedRitual(token)
    if not started then
        return false, reason, false
    end

    local placed
    placed, reason = PlaceAllOfferings(token)
    if not placed then
        return false, reason, false
    end

    local houseNumber = WaitForHauntedHouse(token)
    if not houseNumber then
        return false, "Não consegui identificar a casa assombrada", true
    end

    local visited
    visited, reason = VisitHauntedHouse(houseNumber, token)
    if not visited then
        return false, reason, true
    end

    return true, "Ciclo concluído", true
end

local function WaitForRitualCooldown(token)
    if not LastRitualActivation then
        return WaitCancelable(15, token)
    end

    while IsCurrent(token) do
        local elapsed = os.clock() - LastRitualActivation
        local remaining = math.ceil(CONFIG.RITUAL_COOLDOWN - elapsed)

        if remaining <= 0 then
            return true
        end

        local minutes = math.floor(remaining / 60)
        local seconds = remaining % 60
        SetStatus(string.format("Cooldown %02d:%02d", minutes, seconds))

        if not WaitCancelable(1, token) then
            return false
        end
    end

    return false
end

local function AutomationLoop(token)
    if Running then
        return
    end

    Running = true

    while IsCurrent(token) do
        local ok, success, reason, ritualActivated = pcall(RunOneCycle, token)

        if not ok then
            local errorMessage = success
            success = false
            reason = "Erro: " .. tostring(errorMessage)
            ritualActivated = false
        end

        if not IsCurrent(token) then
            break
        end

        SetStatus(success and reason or ("Falhou: " .. tostring(reason)))

        if ritualActivated then
            WaitForRitualCooldown(token)
        else
            -- Se nem ativou o ritual, tenta novamente sem esperar 10 minutos.
            WaitCancelable(15, token)
        end
    end

    Running = false
end

local function SetEnabled(state)
    state = state == true

    if Enabled == state then
        return
    end

    Enabled = state
    Generation = Generation + 1

    if Enabled then
        local token = Generation
        SetStatus("Iniciando")
        task.spawn(function()
            while Running and IsCurrent(token) do
                task.wait(0.1)
            end
            AutomationLoop(token)
        end)
    else
        WaitingForHouse = false
        SetStatus("Desligado")
    end
end

-- Botao: toque alterna; arrastar reposiciona.
local Dragging = false
local Moved = false
local DragStart = nil
local StartPosition = nil
local ActiveInput = nil

Connect(ToggleButton.InputBegan, function(input)
    local inputType = input.UserInputType
    if inputType ~= Enum.UserInputType.Touch
        and inputType ~= Enum.UserInputType.MouseButton1 then
        return
    end

    Dragging = true
    Moved = false
    DragStart = input.Position
    StartPosition = Panel.Position
    ActiveInput = input

    local endConnection
    endConnection = input.Changed:Connect(function()
        if input.UserInputState == Enum.UserInputState.End then
            Dragging = false
            if endConnection then
                endConnection:Disconnect()
            end
            if not Moved then
                SetEnabled(not Enabled)
            end
        end
    end)
end)

Connect(UserInputService.InputChanged, function(input)
    if not Dragging or not DragStart or not StartPosition then
        return
    end

    local isTouch = ActiveInput
        and ActiveInput.UserInputType == Enum.UserInputType.Touch
        and input == ActiveInput
    local isMouse = input.UserInputType == Enum.UserInputType.MouseMovement

    if not isTouch and not isMouse then
        return
    end

    local delta = input.Position - DragStart
    if delta.Magnitude >= 8 then
        Moved = true
    end

    Panel.Position = UDim2.new(
        StartPosition.X.Scale,
        StartPosition.X.Offset + delta.X,
        StartPosition.Y.Scale,
        StartPosition.Y.Offset + delta.Y
    )
end)

Env.HAUNTED_AUTO_ON = function()
    SetEnabled(true)
end

Env.HAUNTED_AUTO_OFF = function()
    SetEnabled(false)
end

Env.HAUNTED_AUTO_ONE_CYCLE = function()
    if Running then
        warn("[HAUNTED AUTO] Já existe um ciclo em andamento.")
        return
    end

    Enabled = true
    Generation = Generation + 1
    local token = Generation
    SetStatus("Ciclo único")

    task.spawn(function()
        Running = true
        local ok, success, reason = pcall(RunOneCycle, token)
        Running = false

        if not ok then
            SetStatus("Erro no ciclo único")
            warn(success)
        else
            SetStatus(success and reason or ("Falhou: " .. tostring(reason)))
        end

        Enabled = false
        Generation = Generation + 1
        SetStatus("Desligado")
    end)
end

Env.HAUNTED_AUTO_STOP = function()
    Enabled = false
    Generation = Generation + 1
    WaitingForHouse = false

    for _, connection in ipairs(Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    table.clear(Connections)

    if ScreenGui then
        ScreenGui:Destroy()
    end

    print("[HAUNTED AUTO] Script encerrado.")
end

Connect(UnloadButton.Activated, function()
    -- Interrompe imediatamente o ciclo, invalida o token atual e remove o GUI.
    if Env.HAUNTED_AUTO_STOP then
        Env.HAUNTED_AUTO_STOP()
    end
end)

SetStatus("Desligado")
Log("Carregado. Toque no botão flutuante para iniciar.")

