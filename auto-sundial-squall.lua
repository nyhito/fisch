-- AUTO SUNDIAL v4 | sem GUI | pausa e retomada por ciclo
-- Clima: somente avisos novos do chat/tela e texto do indicador atual de clima.
-- Historico do chat e avisos que ja existiam ao executar NAO iniciam eventos.
-- F9 ou console do executor: procure [AutoSundial].
local CONFIG = {
    JanelaAvisos = 2.0, -- janela para o aviso chegar depois da virada
    Passo = 0.03,
    AvisoSemConfirmacao = 6,
    ToleranciaAntesDaVirada = 0.6,
    ValidadeAvisoNaTela = 4,
}
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Chat = game:GetService("TextChatService")
local RunService = game:GetService("RunService")
local player = assert(Players.LocalPlayer, "Execute no cliente.")
local playerGui = player:WaitForChild("PlayerGui")
local env = type(getgenv) == "function" and getgenv() or _G
local previous = env.AutoSundialSquall
if type(previous) == "table" and type(previous.Stop) == "function" then
    previous:Stop("substituido pela versao 4")
end
local ctrl = {Running = true, Paused = false, Status = "iniciando", Attempts = 0, Ignored = 0, Version = 4}
env.AutoSundialSquall = ctrl
local connections, records, candidates, messageIds, messageQueue = {}, {}, {}, {}, {}
local phase, phaseId, phaseAt, phaseWall = nil, 0, os.clock(), nil
local event, hud, pending, restorePending, cycleObject
local endedAt, recent = {}, {}
local attemptedPhase, busy, retryAt, lastScreenCheck = nil, false, 0, -math.huge
local scanScreen, syncPause
local function log(kind, text)
    local line = string.format("[AutoSundial][%s][%.2f] %s", kind, os.clock(), tostring(text))
    if kind == "ERRO" or kind == "SEM CONFIRMACAO" then warn(line) else print(line) end
end
local function plain(text)
    return tostring(text or ""):gsub("<[^>]*>", ""):gsub("&nbsp;", " ")
end
local function compact(text) return plain(text):lower():gsub("[^%a%d]", "") end
local function wallNow()
    local ok, now = pcall(function() return workspace:GetServerTimeNow() end)
    if ok and type(now) == "number" then return now end
    ok, now = pcall(function() return DateTime.now().UnixTimestampMillis / 1000 end)
    return ok and now or nil
end
local bootWall = wallNow()
local function restoreHeld()
    local fn = restorePending
    restorePending = nil
    if fn then pcall(fn) end
end
function ctrl:Stop(reason)
    if not self.Running then return end
    self.Running, self.Paused = false, false
    self.Status = reason or "parado manualmente"
    for connection in pairs(connections) do connection:Disconnect() end
    connections, records, candidates = {}, {}, {}
    restoreHeld()
    log("PAROU", self.Status)
end
local function watch(signal, fn, label)
    local ok, connection = pcall(function()
        return signal:Connect(function(...)
            if not ctrl.Running then return end
            local success, err = pcall(fn, ...)
            if not success then ctrl:Stop("falha em " .. label .. ": " .. tostring(err)) end
        end)
    end)
    if ok and connection then connections[connection] = true; return connection end
end
local targets = {
    tropicalsquall = "Tropical Squall", shimmeringtropicalsquall = "Tropical Squall",
    ragingsquall = "Raging Squall", tempestsquall = "Tempest Squall",
}
local starts = {hasdescended = true, hasbegun = true, hasstarted = true}
local finishes = {hasended = true, haspassed = true, hasdissipated = true,
    haslifted = true, hasfaded = true, isover = true}
local function classify(text, bannerTitle)
    local t = compact(text):gsub("^event", "")
    -- Frase inteira: mencoes, descricoes de itens e citacoes nao sao avisos.
    for stem, name in pairs(targets) do
        for _, prefix in ipairs({"", "a", "the"}) do
            local base = prefix .. stem
            if t:sub(1, #base) == base then
                local suffix = t:sub(#base + 1)
                if starts[suffix] then return "start", name end
                if finishes[suffix] then return "end", name end
            end
        end
    end
    -- Apenas banners novos conhecidos; "Tempest Squall" solto nao e inicio.
    if bannerTitle and (t == "shimmeringtropicalsquall" or t == "tropicalsquall" or t == "ragingsquall") then
        return "start", targets[t]
    end
end
local function activeName()
    if hud and (not endedAt[hud.Name] or hud.At > endedAt[hud.Name]) then return hud.Name end
    if event and event.Phase == phaseId then return event.Name end
end
syncPause = function()
    local name = activeName()
    local wasPaused, oldName = ctrl.Paused, ctrl.ActiveEvent
    ctrl.Paused, ctrl.ActiveEvent = name ~= nil, name
    if name then
        ctrl.Status = "pausado em " .. name .. "; monitores continuam ativos"
        if not wasPaused or oldName ~= name then
            restoreHeld()
            local source = hud and hud.Name == name and hud.Source or (event and event.Source) or "texto atual"
            log("PAUSA", name .. "; fonte=" .. source .. "; aguardando fim ou proxima virada")
        end
    elseif wasPaused then
        attemptedPhase, retryAt = nil, 0
        ctrl.Status = "retomando; janela de avisos do ciclo continua valendo"
        log("RETOMOU", "nenhum squall atual confirmado; sundial sera reavaliado automaticamente")
    end
end
local function receive(kind, name, source, text)
    local now = os.clock()
    local key = kind .. name
    if recent[key] and recent[key].Phase == phaseId and now - recent[key].At < 0.75 then return end
    recent[key] = {Phase = phaseId, At = now}
    if kind == "start" then
        endedAt[name] = nil
        event = {Name = name, Phase = phaseId, At = now, Source = source}
        ctrl.LastEvent = plain(text)
        log("DETECTADO", name .. " | " .. source .. " | " .. plain(text):sub(1, 160))
    else
        endedAt[name] = now
        if event and event.Name == name then event = nil end
        log("FIM", name .. " | " .. source)
    end
    syncPause()
end
local function diagnostic(text, source)
    if not pending then return end
    local t = compact(text)
    if t:find("sundial", 1, true) and (t:find("cooldown", 1, true)
        or t:find("cannot", 1, true) or t:find("already", 1, true)) then
        log("RECUSADO", source .. " | " .. plain(text):sub(1, 160))
    end
end
local function freshNative(message)
    -- Timestamp e MessageId sao usados quando a fonte os fornece.
    local ok, sourceId = pcall(function() return message.TextSource and message.TextSource.UserId end)
    if ok and type(sourceId) == "number" and sourceId > 0 then return false end
    local id
    ok, id = pcall(function() return message.MessageId end)
    if ok and type(id) == "string" and id ~= "" then
        if messageIds[id] then return false end
        messageIds[id] = true; messageQueue[#messageQueue + 1] = id
        if #messageQueue > 512 then messageIds[table.remove(messageQueue, 1)] = nil end
    end
    local stamp
    ok, stamp = pcall(function() return message.Timestamp.UnixTimestampMillis / 1000 end)
    if ok and type(stamp) == "number" then
        if bootWall and stamp < bootWall - 0.1 then return false end
        if phaseWall and stamp < phaseWall - CONFIG.ToleranciaAntesDaVirada then return false end
    end
    return true
end
local function ignoreOld()
    ctrl.Ignored = ctrl.Ignored + 1
    if ctrl.Ignored <= 5 then log("IGNORADO", "historico, mensagem repetida ou mensagem de jogador") end
end
local chatConnected = watch(Chat.MessageReceived, function(message)
    local kind, name = classify(message.Text, false)
    if not kind and not (pending and compact(message.Text):find("sundial", 1, true)) then return end
    if not freshNative(message) then ignoreOld(); return end
    if kind then receive(kind, name, "chat/events novo", message.Text) end
    diagnostic(message.Text, "chat/events")
end, "chat/events") ~= nil
local function legacyFolder(folder)
    local function bind(remote)
        if not remote:IsA("RemoteEvent") then return end
        if remote.Name ~= "OnNewSystemMessage" and remote.Name ~= "OnMessageDoneFiltering" then return end
        watch(remote.OnClientEvent, function(data)
            if type(data) == "table" and data.FromSpeaker and data.FromSpeaker ~= ""
                and data.MessageType ~= "System" then return end
            if type(data) == "table" then
                local stamp = tonumber(data.Time or data.Timestamp)
                if stamp and stamp > 100000000000 then stamp = stamp / 1000 end
                if stamp and bootWall and stamp < bootWall - 1 then ignoreOld(); return end
                if stamp and phaseWall and stamp < phaseWall - 1 then ignoreOld(); return end
            end
            local text = type(data) == "table" and (data.Message or data.Text) or data
            local kind, name = classify(text, false)
            if kind then receive(kind, name, "chat legado novo", text) end
            diagnostic(text, "chat legado")
        end, "chat legado")
    end
    for _, child in ipairs(folder:GetChildren()) do bind(child) end
    watch(folder.ChildAdded, bind, "novos canais legados")
end
local legacy = RS:FindFirstChild("DefaultChatSystemChatEvents")
if legacy then legacyFolder(legacy) end
watch(RS.ChildAdded, function(child)
    if child.Name == "DefaultChatSystemChatEvents" then legacyFolder(child) end
end, "chat legado futuro")
local function context(object)
    local isChat, banner, weather, excluded = false, false, false, false
    local node = object
    for _ = 1, 20 do
        if not node then break end
        local n = compact(node.Name)
        if n:find("chat", 1, true) then isChat = true end
        if n:find("notif", 1, true) or n:find("announce", 1, true)
            or n:find("banner", 1, true) or n:find("toast", 1, true) then banner = true end
        if n:find("weather", 1, true) or n:find("climate", 1, true) then weather = true end
        if n:find("devconsole", 1, true) or n:find("developerconsole", 1, true)
            or n:find("inventory", 1, true) or n:find("backpack", 1, true)
            or n:find("quest", 1, true) or n:find("bestiary", 1, true)
            or n:find("shop", 1, true) or n:find("editor", 1, true)
            or n:find("tooltip", 1, true) or n:find("history", 1, true)
            or n:find("eventlog", 1, true) or n:find("eventlist", 1, true) then excluded = true end
        node = node.Parent
    end
    return isChat, banner, weather and not banner, excluded
end
local function visible(object)
    local node = object
    while node do
        if node:IsA("GuiObject") and not node.Visible then return false end
        if node:IsA("ScreenGui") and not node.Enabled then return false end
        if node:IsA("CanvasGroup") and node.GroupTransparency >= 1 then return false end
        node = node.Parent
    end
    return object.Parent ~= nil and object.TextTransparency < 1
end
local otherWeather = {clear = true, rain = true, rainy = true, windy = true, foggy = true,
    stormy = true, storm = true, aurora = true, auroraborealis = true, eclipse = true,
    starfall = true, rainbow = true, tropicalsun = true, snow = true, blizzard = true,
    heatwave = true, sandstorm = true, duststorm = true, drought = true}
local function weatherText(text)
    local t = compact(text):gsub("^currentweather", ""):gsub("^weather", "")
    if targets[t] then return targets[t] end
    if otherWeather[t] then return false end
    return nil
end
local function candidate(object, record, changed)
    local isChat, banner, weather, excluded = context(object)
    if isChat or excluded then candidates[object] = nil; return end
    record.Banner, record.Weather = banner, weather
    local t = compact(object.Text)
    if changed then
        record.At = os.clock()
        record.Pending = t ~= "" -- lido UMA vez quando ficar visivel; nunca a cada ciclo
    end
    local relevant = weather or t:find("squall", 1, true)
        or (banner and (t == "tropical" or t == "raging" or t == "shimmeringtropical"))
    candidates[object] = relevant and record or nil
end
local function attachText(object, initial)
    if not ctrl.Running or records[object] then return end
    if not (object:IsA("TextLabel") or object:IsA("TextButton")) then return end
    local isChat, _, _, excluded = context(object)
    if isChat or excluded then return end -- historico renderizado do chat nunca e fonte
    local record = {Text = compact(object.Text), At = os.clock(), Pending = not initial,
        StatusAt = os.clock(), StatusKey = nil, Initial = initial}
    records[object] = record
    record.Connection = watch(object:GetPropertyChangedSignal("Text"), function()
        local nextText = compact(object.Text)
        if record.Text == nextText then return end
        record.Text = nextText
        candidate(object, record, true)
        if scanScreen then scanScreen() end
    end, "texto novo na tela")
    candidate(object, record, false)
end
scanScreen = function()
    local now, best, clearAt = os.clock(), nil, nil
    for object, record in pairs(candidates) do
        if not object.Parent then
            candidates[object] = nil
        else
            local shown = visible(object)
            local isChat, banner, weather, excluded = context(object)
            if not isChat and not excluded then
                if record.Pending and shown then
                    record.Pending = false
                    if now - record.At <= CONFIG.ValidadeAvisoNaTela then
                        local kind, name = classify(object.Text, banner)
                        if not kind and banner then
                            -- Banner composto: so em notificacoes, nunca em inventario/chat.
                            local parent = object.Parent
                            if parent then
                                local children = parent:GetDescendants()
                                if #children <= 20 then
                                    local parts = {}
                                    for _, child in ipairs(children) do
                                        if (child:IsA("TextLabel") or child:IsA("TextButton")) and visible(child) then
                                            parts[#parts + 1] = plain(child.Text)
                                        end
                                    end
                                    kind, name = classify(table.concat(parts, " "), true)
                                end
                            end
                        end
                        if kind then receive(kind, name, "aviso NOVO/" .. object:GetFullName(), object.Text) end
                    end
                end
                if weather then
                    local key = record.Text
                    if key ~= record.StatusKey then
                        record.StatusKey, record.StatusAt = key, now
                    end
                    local name
                    if shown then name = weatherText(object.Text) end
                    if type(name) == "string" and (not endedAt[name] or record.StatusAt > endedAt[name]) then
                        if not best or record.StatusAt > best.At then
                            best = {Name = name, At = record.StatusAt, Source = "indicador/" .. object:GetFullName()}
                        end
                    elseif name == false and record.StatusAt > (clearAt or -math.huge) then
                        clearAt = record.StatusAt
                    end
                end
            end
        end
    end
    if best then
        hud = best
    elseif hud and clearAt and clearAt > hud.At then
        log("FIM", hud.Name .. "; indicador atual passou a outro clima")
        hud = nil
    end
    if clearAt and event and clearAt > event.At + 0.05 then
        log("FIM", event.Name .. "; indicador atual passou a outro clima")
        event = nil
    end
    syncPause()
end
local function attachRoot(root, label)
    watch(root.DescendantAdded, function(object) attachText(object, false) end, label .. " novos textos")
    watch(root.DescendantRemoving, function(object)
        local record = records[object]
        if record and record.Connection then
            record.Connection:Disconnect(); connections[record.Connection] = nil
        end
        candidates[object], records[object] = nil, nil
    end, label .. " limpeza")
    for _, object in ipairs(root:GetDescendants()) do attachText(object, true) end
    log("MONITOR", label .. "; textos antigos ignorados, indicador atual separado")
end
attachRoot(playerGui, "PlayerGui/tela")
local coreOK = pcall(function() attachRoot(game:GetService("CoreGui"), "CoreGui") end)
if not coreOK then log("INFO", "CoreGui indisponivel; PlayerGui e API do chat continuam ativos") end
scanScreen()
log("MONITOR", "chat/events=" .. tostring(chatConnected) .. "; pausa automatica, sem desligar ao detectar squall")
local function findCycle()
    for _, root in pairs({RS:FindFirstChild("world") or RS:FindFirstChild("World"),
        workspace:FindFirstChild("world") or workspace:FindFirstChild("World")}) do
        local direct = root:FindFirstChild("cycle") or root:FindFirstChild("Cycle")
        if direct and direct:IsA("ValueBase") then return direct end
        for _, object in ipairs(root:GetDescendants()) do
            local n = compact(object.Name)
            if object:IsA("ValueBase") and (n == "cycle" or n == "daynight" or n == "timeofday") then
                local v = compact(object.Value)
                if v == "day" or v == "night" then return object end
            end
        end
    end
end
local function cycleChanged(value)
    local nextPhase = compact(value)
    if nextPhase ~= "day" and nextPhase ~= "night" then return end
    if nextPhase == phase then return end
    local now = os.clock()
    phase, phaseId, phaseAt, phaseWall = nextPhase, phaseId + 1, now, wallNow()
    hud = nil -- reconstroi a evidencia do indicador atual nesta virada
    if pending then
        log("CICLO OBSERVADO", "virou para " .. phase .. " apos tentativa " .. pending.Id .. "; origem da virada nao e verificavel")
        pending = nil
    end
    restoreHeld()
    -- Nao carrega aviso de um ciclo velho. Tolera aviso que chega imediatamente antes da replicacao do ciclo.
    if event then
        if now - event.At <= CONFIG.ToleranciaAntesDaVirada then event.Phase = phaseId
        else event = nil end
    end
    retryAt = 0
    ctrl.Cycle, ctrl.Status = phase, "reavaliando avisos da nova virada"
    log("CICLO", phase .. "; reavaliando por " .. CONFIG.JanelaAvisos .. " s; historico nao sera relido")
    scanScreen()
end
local function findTotem(character, backpack)
    for _, parent in pairs({character, backpack}) do
        for _, tool in ipairs(parent:GetChildren()) do
            if tool:IsA("Tool") and compact(tool.Name):match("^sundialtotem") then return tool end
        end
    end
end
local function restore(character, humanoid, oldTool, totem)
    if player.Character ~= character or not humanoid.Parent then return end
    local held = character:FindFirstChildOfClass("Tool")
    if held and held ~= totem then return end
    if oldTool and (oldTool.Parent == character or oldTool.Parent == player:FindFirstChildOfClass("Backpack")) then
        humanoid:EquipTool(oldTool)
    elseif held == totem then humanoid:UnequipTools() end
end
local function attempt(token)
    scanScreen()
    if not ctrl.Running or ctrl.Paused or phaseId ~= token or pending then return end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local backpack = player:FindFirstChildOfClass("Backpack")
    if not humanoid or humanoid.Health <= 0 or not backpack then retryAt = os.clock() + 1; return end
    local totem = findTotem(character, backpack)
    if not totem then
        retryAt = os.clock() + 2
        log("AGUARDANDO", "sem Sundial Totem; monitores continuam ativos")
        return
    end
    local oldTool = character:FindFirstChildOfClass("Tool")
    if oldTool == totem then oldTool = nil end
    restorePending = function() restore(character, humanoid, oldTool, totem) end
    if totem.Parent ~= character then humanoid:EquipTool(totem) end
    local equippedAt = os.clock()
    repeat
        task.wait(CONFIG.Passo)
        scanScreen()
        if not ctrl.Running or ctrl.Paused or phaseId ~= token then break end
    until os.clock() - phaseAt >= CONFIG.JanelaAvisos and os.clock() - equippedAt >= 0.12
    if not ctrl.Running or ctrl.Paused or phaseId ~= token then restoreHeld(); return end
    scanScreen() -- ultima verificacao antes do uso
    if ctrl.Paused or not ctrl.Running or not cycleObject or compact(cycleObject.Value) ~= phase then
        restoreHeld(); return
    end
    if player.Character ~= character or humanoid.Health <= 0 or totem.Parent ~= character or not totem.Enabled then
        restoreHeld(); retryAt = os.clock() + 0.25; return
    end
    ctrl.Attempts = ctrl.Attempts + 1
    attemptedPhase = token
    local request = {Id = ctrl.Attempts, At = os.clock(), Tool = totem, Character = character, Backpack = backpack}
    pending = request
    local ok, err = pcall(function() totem:Activate() end)
    if not ok then
        if pending == request then pending = nil end
        attemptedPhase, retryAt = nil, os.clock() + 1
        log("ERRO", "ativacao falhou: " .. tostring(err)); restoreHeld()
    else
        ctrl.Status = "tentativa enviada; aguardando virada"
        log("ENVIADO", "tentativa " .. ctrl.Attempts .. "; aguardando virada real do ciclo")
    end
end
watch(RunService.Heartbeat, function()
    local now = os.clock()
    if now - lastScreenCheck >= CONFIG.Passo then lastScreenCheck = now; scanScreen() end
    if not ctrl.Running then return end
    if pending then
        local tool = pending.Tool
        if not pending.Consumed and tool.Parent ~= pending.Character and tool.Parent ~= pending.Backpack then
            pending.Consumed = true
            log("CONSUMO OBSERVADO", "sundial saiu da mochila/personagem; aguardando ciclo")
        end
        if not pending.Warned and now - pending.At >= CONFIG.AvisoSemConfirmacao then
            pending.Warned = true
            log("SEM CONFIRMACAO", "ciclo nao virou; sigo monitorando, sem gastar outro no mesmo ciclo")
            restoreHeld()
        end
    end
    if phase and not ctrl.Paused and not pending and attemptedPhase ~= phaseId and not busy and now >= retryAt
        and now - phaseAt >= math.max(0, CONFIG.JanelaAvisos - 0.15) then
        busy = true
        local token = phaseId
        task.spawn(function()
            local ok, err = xpcall(function() attempt(token) end, debug.traceback)
            busy = false
            if not ok then ctrl:Stop("erro de execucao: " .. tostring(err)) end
        end)
    end
end, "controle continuo dos ciclos")
task.spawn(function()
    local started = os.clock()
    repeat
        cycleObject = findCycle()
        if cycleObject then break end
        task.wait(0.25)
    until not ctrl.Running or os.clock() - started >= 20
    if not ctrl.Running then return end
    if not cycleObject then ctrl:Stop("Day/Night nao encontrado; nenhum totem usado"); return end
    log("MONITOR", "Day/Night: " .. cycleObject:GetFullName())
    watch(cycleObject:GetPropertyChangedSignal("Value"), function() cycleChanged(cycleObject.Value) end, "Day/Night")
    cycleChanged(cycleObject.Value)
end)
-- Desligar de verdade: getgenv().AutoSundialSquall:Stop()
-- Diagnostico: print(getgenv().AutoSundialSquall.Status)
-- Se o jogo nao enviar aviso de fim nem mostrar indicador atual em texto,
-- o fim so pode ser reavaliado na proxima virada: ausencia de uma notificacao nao prova fim do clima.
