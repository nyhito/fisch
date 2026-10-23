--[[
    FischFright 3 - Haunted Ritual Auto v1.6 Mobile (detector da mensagem)

    Fluxo observado no jogo:
      TP ao Frankenstein -> jogador escolhe Haunted Ritual manualmente
      Detecta nova instrucao visivel de preparacao na tela
      Busca cada prompt individualmente, aproximando-se dele quando necessario
      Bat Wing -> 7 Jack-o-Lantern offerings -> 3 pedestais de 50 Treats
      Detecta House XXX -> equipa Candy Bucket -> Knock
      Tenta acompanhar o alvo do GhostMinigame -> tenta sair usando uma vara

    Observacoes:
      * O auto do GhostMinigame e experimental porque o nome interno do alvo
        movel nao apareceu no log. O script procura o elemento que se move.
      * Cada ciclo consome os itens do Haunted Ritual e 150 Treats.
      * Toque no botao flutuante para ligar/desligar. Arraste para mover.
      * Fale com Frankenstein em cada ciclo; o script nao toca no dialogo.
      * A espera manual nao tem limite. OFF/UNLOAD cancelam a espera.
      * A frase exata ainda nao foi registrada: o detector reconhece instrucoes
        de preparacao em ingles/portugues e grava o texto recebido no LOG.
      * Oferendas precisam de confirmacao antes de passar aos Treats.
      * v1.6 localiza o controle do prompt e chama as conexoes de input/clique
        existentes. O LOG indica o metodo e a mudanca observada.
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
    MANUAL_RITUAL_POLL = 0.25,
    PREPARATION_MAX_AGE = 85,
    PROMPT_READY_TIMEOUT = 5,
    PROMPT_CONFIRM_TIMEOUT = 2.5,
    PROMPT_METHOD_BUDGET = 22,
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

local OFFERING_LOCATIONS = {
    ["bat wing"] = Vector3.new(-15127.9, 146.2, -9600.0),
    ["sour patch salmon"] = Vector3.new(-15125.4, 146.4, -9640.5),
    ["taffy trout"] = Vector3.new(-15136.5, 147.1, -9585.7),
    ["bubblegum blobfish"] = Vector3.new(-15102.6, 146.1, -9600.2),
    ["licorice lamprey"] = Vector3.new(-15110.6, 146.2, -9617.4),
    ["candy corn pack"] = Vector3.new(-15100.9, 146.5, -9613.9),
    ["pop-rock pufferfish"] = Vector3.new(-15098.1, 147.4, -9636.2),
}
-- Jawbreaker: posicao nao apareceu no log, portanto e localizado no mapa.
local TREAT_LOCATIONS = {
    Vector3.new(-15133.1, 145.5, -9604.1),
    Vector3.new(-15140.9, 145.5, -9612.6),
    Vector3.new(-15135.0, 145.5, -9622.9),
}
local Connections = {}
local DebugLines = {}
local TrackedText = setmetatable({}, {__mode = "k"})
local PreparationTextState = setmetatable({}, {__mode = "k"})
local WaitingForPreparation = nil
local PreparationEvidence = nil
local PreparedToken = nil
local Enabled = false
local Unloaded = false
local Running = false
local Generation = 0
local WaitingForHouse = false
local DetectedHouse = nil
local LastRitualActivation = nil
local CurrentStatus = "Desligado"
local LastTouchInput = nil
local PreferredPromptMethod = nil

local function Connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(Connections, connection)
    return connection
end

local function Log(message)
    local line = "[" .. os.date("%H:%M:%S") .. "] " .. tostring(message)
    table.insert(DebugLines, line)
    if #DebugLines > 180 then
        table.remove(DebugLines, 1)
    end
    print("[HAUNTED AUTO v1.6] " .. line)
end

Connect(UserInputService.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1 then
        LastTouchInput = input
    end
end)

local function NormalizeText(raw)
    local text = tostring(raw or ""):gsub("<.->", "")
    local accents = {
        ["á"] = "a", ["à"] = "a", ["ã"] = "a", ["â"] = "a",
        ["é"] = "e", ["ê"] = "e", ["í"] = "i",
        ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ú"] = "u", ["ç"] = "c",
        ["Á"] = "a", ["À"] = "a", ["Ã"] = "a", ["Â"] = "a",
        ["É"] = "e", ["Ê"] = "e", ["Í"] = "i",
        ["Ó"] = "o", ["Ô"] = "o", ["Õ"] = "o", ["Ú"] = "u", ["Ç"] = "c",
    }
    for accented, plain in pairs(accents) do
        text = text:gsub(accented, plain)
    end
    return text:lower():gsub("&nbsp;", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
end

local function PromptItemName(raw)
    return NormalizeText(raw):gsub("^wants%s+", ""):gsub("^quer%s+", "")
end

local function HasAny(text, words)
    for _, word in ipairs(words) do
        if text:find(word, 1, true) then
            return true
        end
    end
    return false
end

local function GetCharacter()
    local character = Player.Character or Player.CharacterAdded:Wait()
    local root = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 10)
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return character, root, humanoid
end

local function IsCurrent(token)
    return not Unloaded and Enabled and token == Generation
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

local function IsGuiVisible(object)
    local current = object

    while current and current ~= game do
        if (current:IsA("ScreenGui") or current:IsA("BillboardGui")
            or current:IsA("SurfaceGui")) and not current.Enabled then
            return false
        end
        if current:IsA("GuiObject") and not current.Visible then
            return false
        end
        current = current.Parent
    end

    return object and object.Parent ~= nil
end

-- Chama apenas conexoes reais ja ligadas pelo jogo ao controle/sinal.
-- Um pcall bem-sucedido nao e prova de que a oferenda foi aceita.
local function CallPromptConnections(signal, ...)
    if not signal then return false, 0 end
    local args = table.pack(...)
    local readable = false
    local fired = 0
    if type(getconnections) == "function" then
        local ok, connections = pcall(getconnections, signal)
        if ok and type(connections) == "table" then
            readable = true
            for _, connection in ipairs(connections) do
                local enabled, fn, fire
                pcall(function() enabled = connection.Enabled end)
                pcall(function() fn = connection.Function end)
                pcall(function() fire = connection.Fire end)
                if enabled ~= false then
                    local invoked, err
                    if type(fn) == "function" then
                        invoked, err = pcall(fn, table.unpack(args, 1, args.n))
                    elseif type(fire) == "function" then
                        invoked, err = pcall(function()
                            connection:Fire(table.unpack(args, 1, args.n))
                        end)
                    end
                    if invoked then
                        fired = fired + 1
                    elseif err then
                        Log("Callback retornou erro: " .. tostring(err))
                    end
                end
            end
        end
    end
    if fired > 0 then return true, fired end
    -- Uma lista vazia foi realmente inspecionada: nao inventa um listener.
    if readable then return false, 0 end
    if type(firesignal) == "function" then
        local ok = pcall(firesignal, signal, table.unpack(args, 1, args.n))
        return ok, ok and -1 or 0
    end
    return false, 0
end

local function SafeDescendants(root)
    local ok, descendants = pcall(function() return root:GetDescendants() end)
    return ok and descendants or {}
end

local function PromptGuiPathAllowed(object)
    local path = NormalizeText(object:GetFullName())
    return not HasAny(path, {
        ".backpack.", ".hotbar.", ".equipment.", ".quests.",
        "scrollingframe", ".options.", "hauntedritualautogui", "devconsole",
    })
end

local function FindPromptControls(prompt)
    local result, seen = {}, {}
    local function add(control)
        if seen[control] or not control:IsA("GuiObject") or not IsGuiVisible(control)
            or not PromptGuiPathAllowed(control) then return end
        if control:IsA("GuiButton") or control.Active then
            seen[control] = true
            table.insert(result, control)
        end
    end
    local function inspectContainer(container)
        if container:IsA("GuiObject") then add(container) end
        for _, child in ipairs(SafeDescendants(container)) do
            if child:IsA("GuiButton") or (child:IsA("GuiObject") and child.Active) then
                add(child)
            end
        end
    end
    local roots = {PlayerGui, CoreGui}
    if prompt.Parent then table.insert(roots, prompt.Parent) end
    local wanted = PromptItemName(prompt.ObjectText)
    for _, root in ipairs(roots) do
        for _, object in ipairs(SafeDescendants(root)) do
            if object:IsA("BillboardGui") and object.Enabled and object.Adornee
                and (object.Adornee == prompt.Parent or prompt:IsDescendantOf(object.Adornee)) then
                inspectContainer(object)
            elseif (object:IsA("TextLabel") or object:IsA("TextButton"))
                and wanted ~= "" and PromptItemName(object.Text) == wanted
                and IsGuiVisible(object) and PromptGuiPathAllowed(object) then
                local container = object
                -- O menor container local contendo o rotulo e um controle.
                -- Nao sobe ate o HUD inteiro procurando qualquer botao.
                for _ = 1, 4 do
                    if not container or not container:IsA("GuiObject") then break end
                    local size = container.AbsoluteSize
                    if size.X > 700 or size.Y > 380 then break end
                    local countBefore = #result
                    inspectContainer(container)
                    if #result > countBefore then break end
                    container = container.Parent
                end
            end
        end
    end
    -- Controles menores (botao da tecla) antes de containers grandes.
    table.sort(result, function(a, b)
        return a.AbsoluteSize.X * a.AbsoluteSize.Y < b.AbsoluteSize.X * b.AbsoluteSize.Y
    end)
    return result
end

local function CountInventoryItem(name)
    local total, found = 0, false
    local containers = {Backpack}
    if Player.Character then table.insert(containers, Player.Character) end
    for _, container in ipairs(containers) do
        for _, tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") and PromptItemName(tool.Name) == name then
                found = true
                local amount = 1
                local ok, attributes = pcall(function() return tool:GetAttributes() end)
                if ok then
                    for key, value in pairs(attributes) do
                        local lower = NormalizeText(key)
                        if type(value) == "number" and value >= 0
                            and (lower == "count" or lower == "amount"
                                or lower == "quantity" or lower == "stack") then
                            amount = value
                            break
                        end
                    end
                end
                total = total + amount
            end
        end
    end
    return found and total or nil
end

local function SnapshotPrompt(prompt)
    local item = PromptItemName(prompt.ObjectText)
    return {
        object = prompt.ObjectText,
        action = prompt.ActionText,
        item = item,
        count = CountInventoryItem(item),
    }
end

local function WaitForPromptChange(prompt, before, token)
    local deadline = os.clock() + CONFIG.PROMPT_CONFIRM_TIMEOUT
    local changedSince, changeReason
    while os.clock() < deadline and IsCurrent(token) do
        local reason
        local nowCount = before.count and CountInventoryItem(before.item) or nil
        if before.count and (nowCount or 0) < before.count then
            reason = "quantidade do item diminuiu"
        elseif not prompt.Parent then
            reason = "prompt removido"
        elseif prompt.ObjectText ~= before.object or prompt.ActionText ~= before.action then
            reason = "texto/acao do prompt mudou"
        elseif not prompt.Enabled then
            reason = "prompt permaneceu desativado"
        end
        if reason then
            if reason ~= changeReason then
                changeReason, changedSince = reason, os.clock()
            end
            local stableTime = reason == "prompt permaneceu desativado" and 1.25 or 0.35
            if os.clock() - changedSince >= stableTime then return true, reason end
        else
            changedSince, changeReason = nil, nil
        end
        if not WaitCancelable(0.1, token) then return false, "cancelado" end
    end
    return false, "nenhuma mudanca observada"
end

local function InvokePromptMethod(method, prompt, controls, token)
    if method:sub(1, 4) == "gui-" then
        for index, control in ipairs(controls) do
            if index > 6 or not IsCurrent(token) then break end
            if control.Parent and IsGuiVisible(control) then
                local invoked = false
                local count = 0
                if method == "gui-input" and LastTouchInput then
                    invoked, count = CallPromptConnections(control.InputBegan, LastTouchInput)
                    if invoked then
                        local held = WaitCancelable(math.max(prompt.HoldDuration, 0.05) + 0.12, token)
                        -- Libera mesmo em OFF/UNLOAD para nao deixar um hold preso.
                        CallPromptConnections(control.InputEnded, LastTouchInput)
                        if not held then return false end
                    end
                elseif method == "gui-down-up" and control:IsA("GuiButton") then
                    local center = control.AbsolutePosition + control.AbsoluteSize / 2
                    invoked, count = CallPromptConnections(control.MouseButton1Down, center.X, center.Y)
                    if invoked then
                        local held = WaitCancelable(math.max(prompt.HoldDuration, 0.05) + 0.12, token)
                        CallPromptConnections(control.MouseButton1Up, center.X, center.Y)
                        if not held then return false end
                    end
                elseif method == "gui-activated" and control:IsA("GuiButton") then
                    invoked, count = CallPromptConnections(control.Activated, LastTouchInput, 1)
                elseif method == "gui-click" and control:IsA("GuiButton") then
                    invoked, count = CallPromptConnections(control.MouseButton1Click)
                end
                if invoked then
                    Log("Controle: " .. control:GetFullName() .. " | " .. method .. " | callbacks=" .. count)
                    return true
                end
            end
        end
        return false
    elseif method == "prompt-triggered" then
        return CallPromptConnections(prompt.Triggered, Player)
    elseif method == "service-triggered" then
        return CallPromptConnections(ProximityPromptService.PromptTriggered, prompt, Player)
    elseif method == "engine-direct" and type(fireproximityprompt) == "function" then
        return pcall(fireproximityprompt, prompt)
    elseif method == "engine-hold" then
        return pcall(function()
            prompt:InputHoldBegin()
            WaitCancelable(math.max(prompt.HoldDuration, 0.05) + 0.12, token)
            prompt:InputHoldEnd()
        end)
    end
    return false
end

local function TriggerPrompt(prompt, token, verifyChange)
    if not prompt or not prompt.Parent or not IsCurrent(token) then return false end
    if not TeleportNearObject(prompt) then return false end
    if not WaitCancelable(CONFIG.PROMPT_SYNC_WAIT, token) then return false end
    local readyDeadline = os.clock() + CONFIG.PROMPT_READY_TIMEOUT
    while prompt.Parent and not prompt.Enabled and os.clock() < readyDeadline do
        if not WaitCancelable(0.1, token) then return false end
    end
    if not IsCurrent(token) or not prompt.Parent or not prompt.Enabled then return false end

    local controls = FindPromptControls(prompt)
    Log("Alvo: " .. prompt:GetFullName() .. " | objeto=" .. prompt.ObjectText
        .. " | acao=" .. prompt.ActionText .. " | controles=" .. #controls
        .. " | getconnections=" .. tostring(type(getconnections) == "function"))
    local methods = {
        "gui-input", "gui-down-up", "gui-activated", "gui-click",
        "prompt-triggered", "service-triggered", "engine-direct", "engine-hold",
    }
    if PreferredPromptMethod then
        for index, method in ipairs(methods) do
            if method == PreferredPromptMethod then
                table.remove(methods, index)
                table.insert(methods, 1, method)
                break
            end
        end
    end
    local before = SnapshotPrompt(prompt)
    local startedAt = os.clock()
    local attempts = {}
    for _, method in ipairs(methods) do
        if method:sub(1, 4) == "gui-" then
            for index, control in ipairs(controls) do
                if index > 6 then break end
                table.insert(attempts, {method = method, controls = {control}})
            end
        else
            table.insert(attempts, {method = method, controls = controls})
        end
    end
    for _, attempt in ipairs(attempts) do
        local method = attempt.method
        if not IsCurrent(token) then return false end
        if os.clock() - startedAt > CONFIG.PROMPT_METHOD_BUDGET then break end
        -- Nunca dispara outro metodo se a tentativa anterior ja mudou o alvo.
        if not prompt.Parent or not prompt.Enabled or prompt.ObjectText ~= before.object
            or prompt.ActionText ~= before.action then
            local accepted, reason = WaitForPromptChange(prompt, before, token)
            if accepted then Log("Confirmado: " .. reason); return true end
            return false
        end
        local ok, attempted = pcall(InvokePromptMethod, method, prompt, attempt.controls, token)
        if not ok then
            Log(method .. " retornou erro: " .. tostring(attempted))
        elseif attempted then
            Log("Metodo executado: " .. method .. " (aguardando efeito)")
            if not WaitCancelable(CONFIG.PROMPT_AFTER_WAIT, token) then return false end
            if not verifyChange then return true end
            local accepted, reason = WaitForPromptChange(prompt, before, token)
            if accepted then
                PreferredPromptMethod = method
                Log("Confirmado: " .. reason .. " | metodo=" .. method)
                return true
            end
            Log("Sem efeito confirmado: " .. method)
        end
    end
    Log("Nao consegui confirmar a interacao de " .. tostring(before.object))
    return false
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

local function GetRitualComponents()
    local world = workspace:FindFirstChild("world")
    local map = world and world:FindFirstChild("map")
    local event = map and map:FindFirstChild("Fischfright26")
    return event and event:FindFirstChild("RitualComponents")
end

local function WaitForOfferingPrompt(objectText, timeout, token)
    local deadline = os.clock() + timeout
    local wanted = PromptItemName(objectText)
    local triedPosition = false
    local visited = {}
    while os.clock() < deadline and IsCurrent(token) do
        local components = GetRitualComponents()
        if components then
            local prompt = FindPrompt(function(candidate)
                return PromptItemName(candidate.ObjectText) == wanted
            end, components)
            if prompt then
                -- Enabled pode depender da proximidade. TriggerPrompt aproxima
                -- primeiro e espera a habilitacao, sem modificar o prompt.
                return prompt
            end
        end

        local position = OFFERING_LOCATIONS[wanted]
        if position and not triedPosition then
            triedPosition = true
            TeleportTo(position + Vector3.new(0, 3, 2))
            if not WaitCancelable(CONFIG.PROMPT_SYNC_WAIT, token) then
                return nil
            end
        else
            -- Se o nome so for preenchido ao chegar perto, percorre apenas os
            -- prompts das lanternas/maos carregadas, nunca prompts de outros NPCs.
            local target
            local lanterns = components and components:FindFirstChild("Lanterns")
            local hands = components and components:FindFirstChild("Hands")
            local root = wanted == "bat wing" and hands or lanterns
            if root then
                target = FindPrompt(function(candidate)
                    return not visited[candidate]
                end, root)
            end
            if target then
                visited[target] = true
                TeleportNearObject(target)
                if not WaitCancelable(0.35, token) then
                    return nil
                end
            elseif not WaitCancelable(0.15, token) then
                return nil
            end
        end
    end
    return nil
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
UnloadButton.Size = UDim2.fromOffset(107, 23)
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

local LogButton = Instance.new("TextButton")
LogButton.Name = "CopyLog"
LogButton.Size = UDim2.fromOffset(53, 23)
LogButton.Position = UDim2.fromOffset(115, 53)
LogButton.BackgroundColor3 = Color3.fromRGB(11, 11, 11)
LogButton.TextColor3 = Color3.fromRGB(190, 190, 190)
LogButton.Text = "LOG"
LogButton.TextSize = 10
LogButton.Font = Enum.Font.GothamBold
LogButton.Parent = Panel
local logCorner = Instance.new("UICorner")
logCorner.CornerRadius = UDim.new(0, 6)
logCorner.Parent = LogButton

local function SetStatus(status)
    CurrentStatus = tostring(status)
    if ToggleButton and ToggleButton.Parent then
        ToggleButton.BackgroundColor3 = Color3.fromRGB(13, 13, 13)
        ToggleButton.TextColor3 = Enabled
            and Color3.fromRGB(80, 235, 135)
            or Color3.fromRGB(210, 210, 210)
        ToggleButton.Text = string.format(
            "HAUNTED v1.6: %s\n%s",
            Enabled and "ON" or "OFF",
            CurrentStatus
        )
    end
    Log(status)
end

-- Detecta a nova instrucao na tela. Nao aceita textos de templates/listas.
-- A frase exata do jogo ainda nao foi fornecida: as regras abaixo sao
-- heuristicas e o LOG registra texto + caminho para calibrar se necessario.
local function IsPreparationInstruction(raw, path, isBottom)
    local text = NormalizeText(raw)
    path = NormalizeText(path)
    if #text < 8 then
        return false
    end
    if HasAny(path, {
        ".options.", "scrollingframe", ".hotbar.", ".backpack.",
        ".equipment.", ".showroom.", ".serverbrowser.", ".quests.",
        "hauntedritualautogui",
    }) then
        return false
    end
    if HasAny(text, {
        "cooldown", "not enough", "don't have", "do not have", "cannot", "can't",
        "failed", "cancelled", "canceled", "expired", "ritual ended",
        "ritual completed", "reward:", "recompensa:",
        "nao pode", "nao possui", "nao tem", "falhou", "cancelado",
        "ritual encerrado", "ritual concluido", "tempo esgotado",
    }) then
        return false
    end
    if HasAny(text, {
        "hexing ritual", "scary relic ritual", "jack-o-moon ritual",
        "boglin ritual", "dutchman's blessing", "haunted cemetery ritual",
        "eldritch ritual", "omniscient ritual", "ghoul nessie ritual",
    }) then
        return false
    end
    local ritual = text:find("ritual", 1, true) ~= nil
    local action = HasAny(text, {
        "place", "placing", "offer", "light", "insert", "fill", "deposit",
        "coloque", "colocar", "ofereca", "oferecer", "acenda", "acender",
        "insira", "preencha", "deposite", "adicione",
    })
    local materials = HasAny(text, {
        "offering", "ingredient", "lantern", "pumpkin", "treat", "items",
        "skeletal hand", "skeleton hand", "bat wing",
        "oferenda", "ingrediente", "abobora", "doce", "itens",
    })
    local noticePath = HasAny(path, {"announc", "notif", "ritual", "objective", "instruction"})
    local hauntedStarted = (text:find("haunted ritual", 1, true)
        or text:find("ritual assombrado", 1, true))
        and HasAny(text, {"has begun", "has started", "begins", "started", "prepare", "iniciado", "comecou", "prepar"})
    if hauntedStarted and (noticePath or isBottom) then
        return true
    end
    return action and materials and (ritual or noticePath or isBottom)
end

local function ReadScreenText(object)
    if not object.Parent or not IsGuiVisible(object) then
        return object.Text or "", false, false
    end
    local size = object.AbsoluteSize
    local visible = size.X > 1 and size.Y > 1 and object.TextTransparency < 0.98
    local camera = workspace.CurrentCamera
    local bottom = camera and (object.AbsolutePosition.Y + size.Y / 2)
        >= camera.ViewportSize.Y * 0.42 or false
    local current = object.Parent
    while visible and current and current ~= PlayerGui do
        if current:IsA("CanvasGroup") and current.GroupTransparency >= 0.98 then
            visible = false
        end
        current = current.Parent
    end
    return object.Text or "", visible, bottom
end

local function CapturePreparation(raw, path, isBottom)
    local token = WaitingForPreparation
    if not token or not IsCurrent(token) or not IsPreparationInstruction(raw, path, isBottom) then
        return false
    end
    if not PreparationEvidence then
        PreparationEvidence = {token = token, at = os.clock(), text = raw, path = path}
        Log("PREPARO DETECTADO | " .. path .. " | " .. raw)
        SetStatus("Preparo detectado")
    end
    return true
end

local function ObservePreparationText(object)
    local token = WaitingForPreparation
    if not token or not IsCurrent(token) then
        return
    end
    local raw, visible, bottom = ReadScreenText(object)
    local previous = PreparationTextState[object]
    PreparationTextState[object] = {text = raw, visible = visible}
    local fresh = not previous or previous.text ~= raw or (visible and not previous.visible)
    if not fresh or not visible or raw == "" then
        return
    end
    local path = object:GetFullName()
    if CapturePreparation(raw, path, bottom) then
        return
    end
    local lower = NormalizeText(raw)
    if (bottom or HasAny(lower, {"ritual", "ingredient", "oferenda", "abobora"}))
        and not HasAny(NormalizeText(path), {".hotbar.", ".backpack.", "scrollingframe", ".options."})
        and lower:find("%a") then
        Log("UI visivel | " .. path .. " | " .. raw:sub(1, 350))
    end
end

local function ScanPreparationTexts()
    for object in pairs(TrackedText) do
        if object.Parent then
            ObservePreparationText(object)
        end
    end
end

local function ArmPreparationWatcher(token)
    PreparationEvidence = nil
    PreparedToken = nil
    PreparationTextState = setmetatable({}, {__mode = "k"})
    for object in pairs(TrackedText) do
        if object.Parent then
            local raw, visible = ReadScreenText(object)
            PreparationTextState[object] = {text = raw, visible = visible}
        end
    end
    WaitingForPreparation = token
    Log("Detector armado; aguardando uma NOVA instrucao visivel de preparacao.")
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

    if not object:IsA("TextLabel") and not object:IsA("TextButton")
        and not object:IsA("TextBox") then
        return
    end

    HookedText[object] = true
    TrackedText[object] = true

    Connect(object:GetPropertyChangedSignal("Text"), function()
        ObservePreparationText(object)
        if WaitingForHouse and IsGuiVisible(object) then
            ParseHouseMessage(object.Text)
        end
    end)
    Connect(object:GetPropertyChangedSignal("Visible"), function()
        ObservePreparationText(object)
    end)
    ObservePreparationText(object)
end

for _, object in ipairs(PlayerGui:GetDescendants()) do
    HookTextObject(object)
end

Connect(PlayerGui.DescendantAdded, HookTextObject)

pcall(function()
    Connect(TextChatService.MessageReceived, function(message)
        CapturePreparation(message.Text, "TextChatService.Notification", false)
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

local function StartHauntedRitual(token)
    if not IsCurrent(token) then
        return false, "Cancelado"
    end
    -- Arma antes do TP: nao perde notificacao durante a chegada/sincronizacao.
    ArmPreparationWatcher(token)
    SetStatus("Indo ao Frankenstein")
    local prompt = FindFrankensteinPrompt()
    local moved = prompt and TeleportNearObject(prompt)
    if not moved then
        moved = TeleportTo(Vector3.new(-15107.4, 151.6, -9620.4))
    end
    if not moved or not WaitCancelable(CONFIG.PROMPT_SYNC_WAIT, token) then
        WaitingForPreparation = nil
        return false, "Cancelado ou TP indisponivel"
    end
    local _, _, humanoid = GetCharacter()
    if not IsCurrent(token) then
        WaitingForPreparation = nil
        return false, "Cancelado"
    end
    if humanoid then
        humanoid:UnequipTools()
    end
    SetStatus("Inicie Haunted no NPC")
    Log("Fale manualmente, escolha Haunted Ritual e espere a mensagem de colocar os ingredientes.")
    while IsCurrent(token) do
        ScanPreparationTexts()
        local evidence = PreparationEvidence
        if evidence and evidence.token == token then
            WaitingForPreparation = nil
            PreparedToken = token
            Log("Prosseguindo pela mensagem: " .. evidence.text)
            return true
        end
        if not WaitCancelable(CONFIG.MANUAL_RITUAL_POLL, token) then
            break
        end
    end
    WaitingForPreparation = nil
    return false, "Cancelado"
end

local function PlaceOneOffering(objectText, label, token)
    SetStatus("Colocando " .. label)

    local prompt = WaitForOfferingPrompt(objectText, 12, token)
    if not prompt then
        return false, "Não achei prompt: " .. objectText
    end

    if not TriggerPrompt(prompt, token, true) then
        return false, "Sem confirmacao da oferenda: " .. objectText .. " (veja LOG)"
    end

    return true
end

local function FindTreatPedestals(token)
    local result, seen = {}, {}
    local function collect()
        local components = GetRitualComponents()
        if not components then return end
        for _, prompt in ipairs(FindPrompts(function(candidate)
            local action = NormalizeText(candidate.ActionText)
            return NormalizeText(candidate.ObjectText) == "treat pedestal"
                and tonumber(action:match("%d+")) == 50
        end, components)) do
            if not seen[prompt] then
                seen[prompt] = true
                table.insert(result, prompt)
            end
        end
    end
    collect()
    if #result < 3 then
        for _, position in ipairs(TREAT_LOCATIONS) do
            if not IsCurrent(token) then return {} end
            TeleportTo(position + Vector3.new(0, 3, 2))
            if not WaitCancelable(0.5, token) then return {} end
            collect()
            if #result >= 3 then break end
        end
    end
    return result
end

local function PlaceAllOfferings(token)
    if not IsCurrent(token) or PreparedToken ~= token or not PreparationEvidence
        or PreparationEvidence.token ~= token then
        return false, "Sem mensagem de preparacao confirmada"
    end
    if os.clock() - PreparationEvidence.at > CONFIG.PREPARATION_MAX_AGE then
        return false, "A mensagem de preparacao expirou; inicie novamente"
    end

    local ok, reason = PlaceOneOffering("Wants Bat Wing", "Bat Wing", token)
    if not ok then return false, reason end
    for _, offering in ipairs(OFFERINGS) do
        ok, reason = PlaceOneOffering(offering, offering, token)
        if not ok then return false, reason end
    end

    SetStatus("Conferindo os Treats")
    local pedestals = FindTreatPedestals(token)
    if not IsCurrent(token) then return false, "Cancelado" end
    if #pedestals ~= 3 then
        return false, "Encontrei " .. #pedestals .. "/3 pedestais de 50 Treats (veja LOG)"
    end

    WaitingForHouse = true
    DetectedHouse = nil
    table.sort(pedestals, function(a, b)
        local positionA = GetWorldPosition(a)
        local positionB = GetWorldPosition(b)
        if not positionA or not positionB then
            return a:GetFullName() < b:GetFullName()
        end
        if positionA.X == positionB.X then return positionA.Z < positionB.Z end
        return positionA.X < positionB.X
    end)

    for index, pedestal in ipairs(pedestals) do
        SetStatus("Treat Pedestal " .. index .. "/3")
        if not TriggerPrompt(pedestal, token, true) then
            WaitingForHouse = false
            return false, "Sem confirmacao no Treat Pedestal " .. index .. " (veja LOG)"
        end
    end
    PreparedToken = nil
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
    if not IsCurrent(token) or not CONFIG.AUTO_EXIT_WITH_ROD then
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

        if not WaitCancelable(1.4, token) then
            return false
        end

        local _, _, humanoid = GetCharacter()
        if humanoid then
            humanoid:UnequipTools()
        end
    end

    if not WaitCancelable(2.0, token) then
        return false
    end

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

    if not WaitCancelable(0.35, token) then
        return false, "Cancelado"
    end
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

    if not WaitCancelable(1.0, token) then
        return false, "Cancelado"
    end
    TryExitSpiritRealm(number, token)
    return true
end

local function RunOneCycle(token)
    if not IsCurrent(token) then
        return false, "Cancelado", false
    end
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
    if Unloaded then
        return
    end
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
        WaitingForPreparation = nil
        PreparedToken = nil
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
    if Unloaded then
        return
    end
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

        if Unloaded or token ~= Generation then
            return
        end

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
    Unloaded = true
    Enabled = false
    Generation = Generation + 1
    WaitingForHouse = false
    WaitingForPreparation = nil
    PreparedToken = nil

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

local function CopyDebugLog()
    local text = "HAUNTED AUTO v1.6\n" .. table.concat(DebugLines, "\n")
    if setclipboard then
        local ok = pcall(setclipboard, text)
        if ok then
            LogButton.Text = "COPIADO"
            task.delay(1.5, function()
                if not Unloaded and LogButton.Parent then LogButton.Text = "LOG" end
            end)
            return
        end
    end
    print(text)
    LogButton.Text = "CONSOLE"
end
Env.HAUNTED_AUTO_COPY_LOG = CopyDebugLog
Connect(LogButton.Activated, CopyDebugLog)

SetStatus("Desligado")
Log("v1.6: detector mantido; interacao por callbacks do controle. Veja LOG se um prompt falhar.")

