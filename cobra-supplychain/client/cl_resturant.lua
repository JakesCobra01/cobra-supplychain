local QBCore = exports['qb-core']:GetCoreObject()

-- ── Craft result state (set by server response, polled by cook loop) ──────────
local _craftResultReceived = false
local _craftLastResult     = nil

RegisterNetEvent('cobra-supplychain:craftResult')
AddEventHandler('cobra-supplychain:craftResult', function(result)
    _craftLastResult     = result
    _craftResultReceived = true
end)

-- ── Synced animation helpers ──────────────────────────────────────────────────
-- Loads the dict properly before playing — QBCore's Progressbar skips this,
-- which is why anims were silently not playing.
local function playAnimLocal(ped, dict, name, duration, flags)
    flags = flags or 49
    if not HasAnimDictLoaded(dict) then
        RequestAnimDict(dict)
        local timeout = 0
        while not HasAnimDictLoaded(dict) and timeout < 100 do
            Citizen.Wait(10)
            timeout = timeout + 1
        end
    end
    if HasAnimDictLoaded(dict) then
        TaskPlayAnim(ped, dict, name, 8.0, -8.0, duration or -1, flags, 0, false, false, false)
    end
end

-- Plays anim locally and broadcasts to nearby players via server relay
local function playAnimSynced(dict, name, duration)
    local ped   = PlayerPedId()
    local netId = PedToNet(ped)
    playAnimLocal(ped, dict, name, duration, 49)
    TriggerServerEvent('cobra-supplychain:broadcastPedAnim', netId, dict, name, duration)
end

-- Stops anim locally and tells nearby players to stop it too
local function stopAnimSynced()
    local ped   = PlayerPedId()
    local netId = PedToNet(ped)
    ClearPedTasks(ped)
    TriggerServerEvent('cobra-supplychain:broadcastStopAnim', netId)
end

-- Receive anim broadcast from server — play on the remote ped
RegisterNetEvent('cobra-supplychain:playPedAnim')
AddEventHandler('cobra-supplychain:playPedAnim', function(netId, dict, name, duration)
    local ped = NetToPed(netId)
    if DoesEntityExist(ped) and ped ~= PlayerPedId() then
        playAnimLocal(ped, dict, name, duration, 49)
    end
end)

-- Receive stop broadcast from server — stop the remote ped's anim
RegisterNetEvent('cobra-supplychain:stopPedAnim')
AddEventHandler('cobra-supplychain:stopPedAnim', function(netId)
    local ped = NetToPed(netId)
    if DoesEntityExist(ped) and ped ~= PlayerPedId() then
        ClearPedTasks(ped)
    end
end)

-- ── Bartender animations (bar / drinks station) ───────────────────────────────
-- Cycles so repeated crafts look natural. Item config can override via progressAnim.
local BAR_ANIMATIONS = {
    { dict = 'anim@amb@casino_b@bj_table@dealer_idle@male_a', name = 'dealer_idle' },
    { dict = 'anim@heists@ornate_bank@hack',                  name = 'hack_loop'   },
    { dict = 'anim@mp_corona_idles@female@sit@idle_a',        name = 'idle_e'      },
    { dict = 'amb@world_human_drinking@beer@male@loop',        name = 'idle_c'      },
}
local _barAnimIdx = 0
local function nextBarAnim()
    _barAnimIdx = (_barAnimIdx % #BAR_ANIMATIONS) + 1
    return BAR_ANIMATIONS[_barAnimIdx].dict, BAR_ANIMATIONS[_barAnimIdx].name
end

-- ── Helper: progressbar (animation handled separately above) ──────────────────
-- Empty anim tables passed to QBCore — we manage anims ourselves so we can
-- load dicts properly and sync them to other players.
local function ProgressBar(label, duration, canCancel)
    local finished = nil
    QBCore.Functions.Progressbar(
        'cobra_craft_' .. math.random(1000, 9999),
        label,
        duration,
        canCancel ~= false,
        false,
        {
            disableMovement    = true,
            disableCarMovement = true,
            disableMouse       = false,
            disableCombat      = true,
        },
        {}, {}, {},
        function() finished = true  end,
        function() finished = false end
    )
    repeat Citizen.Wait(0) until finished ~= nil
    return finished
end

-- ── Helper: get item count from PlayerData (no client export needed) ──────────
local function GetPlayerItemCount(itemName)
    local items = QBCore.Functions.GetPlayerData().items
    if not items then return 0 end
    for _, item in pairs(items) do
        if item and item.name == itemName then
            return item.amount or 0
        end
    end
    return 0
end

-- ── Zones: registers, trays, storage, cookloco, chairs ───────────────────────
Citizen.CreateThread(function()
    for k, v in pairs(Businesses.Businesses) do
        local registers = v.registers
        local trays     = v.trays
        local storage   = v.storage
        local clockin   = v.clockin
        local CookLoco  = v.CookLoco
        local chairs    = v.chairs

        -- ── Registers ────────────────────────────────────────────────────────
        if registers then
            for a, d in pairs(registers) do
                if d then
                    exports['qb-target']:AddBoxZone(
                        "register-" .. k .. "-" .. a,
                        vector3(d.coords.x, d.coords.y, d.coords.z - 0.2),
                        0.5, 0.5,
                        {
                            name      = "register-" .. k .. "-" .. a,
                            heading   = d.coords.w,
                            debugPoly = false,
                            minZ      = d.coords.z - 0.25,
                            maxZ      = d.coords.z + 0.5,
                        },
                        {
                            options = {
                                {
                                    -- Job-restricted: only staff can open the register
                                    type        = "client",
                                    event       = "cobra-supplychain:ChargeCustomer",
                                    icon        = "fas fa-credit-card",
                                    label       = "Open Cash Register",
                                    registerJob = k,
                                    job         = k,   -- qb-target job restriction
                                },
                                {
                                    -- No restriction: anyone can view the menu
                                    type        = "client",
                                    event       = "cobra-supplychain:ShowMenu",
                                    icon        = "fas fa-book-open",
                                    label       = "View Menu",
                                    registerJob = k,
                                },
                            },
                            distance = 2.0
                        }
                    )

                    if d.Prop then
                        local prop = CreateObject(GetHashKey("prop_till_01"),
                            d.coords.x, d.coords.y, d.coords.z, false, false, false)
                        SetEntityHeading(prop, d.coords.w)
                        FreezeEntityPosition(prop, true)
                    end
                end
            end
        end

        -- ── Trays ─────────────────────────────────────────────────────────────
        if trays then
            for a, d in pairs(trays) do
                if d then
                    exports['qb-target']:AddBoxZone(
                        "tray-" .. k .. "-" .. a,
                        vector3(d.coords.x, d.coords.y, d.coords.z),
                        0.6, 0.6,
                        {
                            name      = "tray-" .. k .. "-" .. a,
                            heading   = d.coords.w,
                            debugPoly = false,
                            minZ      = d.coords.z - 0.5,
                            maxZ      = d.coords.z + 0.5,
                        },
                        {
                            options = {
                                {
                                    type    = "client",
                                    event   = "cobra-supplychain:OpenTray",
                                    icon    = "fas fa-basket-shopping",
                                    label   = "Open Tray",
                                    trayId  = a,
                                    trayJob = k,
                                },
                            },
                            distance = 2.0
                        }
                    )
                end
            end
        end

        -- ── Clock-in ──────────────────────────────────────────────────────────
        if clockin then
            exports['qb-target']:AddBoxZone(
                "clockin-" .. k,
                vector3(clockin.coords.x, clockin.coords.y, clockin.coords.z - 0.62),
                clockin.dimensions.length, clockin.dimensions.width,
                {
                    name      = "clockin-" .. k,
                    heading   = clockin.coords.w,
                    debugPoly = false,
                    minZ      = clockin.coords.z - clockin.dimensions.height,
                    maxZ      = clockin.coords.z + clockin.dimensions.height,
                },
                {
                    options = {
                        {
                            type  = "client",
                            event = "cobra-supplychain:ToggleClockIn",
                            icon  = "fas fa-clock",
                            label = "Clock In / Out",
                            job   = k,
                        },
                    },
                    distance = 2.0
                }
            )
        end

        -- ── Storage ───────────────────────────────────────────────────────────
        if storage then
            for a, d in pairs(storage) do
                if d then
                    local height = (d.dimensions and d.dimensions.height) or 1.0
                    local width  = (d.dimensions and d.dimensions.width)  or 1.5
                    local length = (d.dimensions and d.dimensions.length) or 0.6

                    exports['qb-target']:AddBoxZone(
                        "storage-" .. k .. "-" .. a,
                        vector3(d.coords.x, d.coords.y, d.coords.z - 0.62),
                        width, length,
                        {
                            name      = "storage-" .. k .. "-" .. a,
                            heading   = d.coords.w,
                            debugPoly = false,
                            minZ      = d.coords.z - height,
                            maxZ      = d.coords.z + height,
                        },
                        {
                            options = {
                                {
                                    type       = "client",
                                    event      = "cobra-supplychain:OpenStorage",
                                    icon       = "fas fa-dolly",
                                    label      = d.targetLabel or "Open Storage",
                                    storageJob = k,
                                    storageId  = a,
                                },
                            },
                            distance = 2.0
                        }
                    )
                end
            end
        end

        -- ── Cooking Stations ──────────────────────────────────────────────────
        if CookLoco then
            for a, d in pairs(CookLoco) do
                if d then
                    local height = (d.dimensions and d.dimensions.height) or 0.5
                    local length = (d.dimensions and d.dimensions.length) or 1.5
                    local width  = (d.dimensions and d.dimensions.width)  or 0.6

                    exports['qb-target']:AddBoxZone(
                        "CookLoco-" .. k .. "-" .. a,
                        vector3(d.coords.x, d.coords.y, d.coords.z - 0.52),
                        length, width,
                        {
                            name      = "CookLoco-" .. k .. "-" .. a,
                            heading   = d.coords.w,
                            debugPoly = false,
                            minZ      = d.coords.z - height,
                            maxZ      = d.coords.z + height,
                        },
                        {
                            options = {
                                {
                                    type  = "client",
                                    event = "cobra-supplychain:PrepareFood",
                                    icon  = "fas fa-utensils",
                                    label = d.targetLabel or "Prepare Food",
                                    job   = k,
                                    index = a,
                                },
                            },
                            distance = 2.0
                        }
                    )
                end
            end
        end

        -- ── Chairs ────────────────────────────────────────────────────────────
        -- Coords are passed as flat numbers (chairX/Y/Z/W) because qb-target
        -- can fail to serialise vector4 inside option args.
        if chairs then
            for a, chair in pairs(chairs) do
                if chair then
                    exports['qb-target']:AddBoxZone(
                        "chair-" .. k .. "-" .. a,
                        vector3(chair.coords.x, chair.coords.y, chair.coords.z - 0.65),
                        0.6, 0.6,
                        {
                            name      = "chair-" .. k .. "-" .. a,
                            heading   = chair.coords.w,
                            debugPoly = false,
                            minZ      = chair.coords.z - 0.25,
                            maxZ      = chair.coords.z + 0.25,
                        },
                        {
                            options = {
                                {
                                    type     = "client",
                                    event    = "cobra-supplychain:SitChair",
                                    icon     = "fas fa-couch",
                                    label    = "Sit Down",
                                    chairX   = chair.coords.x,
                                    chairY   = chair.coords.y,
                                    chairZ   = chair.coords.z,
                                    chairW   = chair.coords.w,
                                    chairJob = k,
                                },
                            },
                            distance = 2.5
                        }
                    )
                end
            end
        end
    end
end)

-- ── Business Blips ────────────────────────────────────────────────────────────
Citizen.CreateThread(function()
    for businessName, business in pairs(Businesses.Businesses) do
        if business.blip and business.clockin then
            local blip = AddBlipForCoord(
                business.clockin.coords.x,
                business.clockin.coords.y,
                business.clockin.coords.z)
            SetBlipSprite(blip, business.blip.sprite)
            SetBlipScale(blip, business.blip.scale)
            SetBlipColour(blip, business.blip.color)
            SetBlipAsShortRange(blip, true)
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentSubstringPlayerName(business.jobDisplay)
            EndTextCommandSetBlipName(blip)
        end
    end
end)

-- ── Register — jim-payments ───────────────────────────────────────────────────
-- jim-payments:client:Charge is the correct event from charge.lua.
-- data.job tells jim-payments which society account receives the payment.
-- data.img can be a URL for the menu header image; pass nil to use the job label.
-- outside = true means the charge came from outside the normal job zone (portable register).

RegisterNetEvent('cobra-supplychain:ChargeCustomer')
AddEventHandler('cobra-supplychain:ChargeCustomer', function(info)
    local job = info and info.registerJob
    TriggerEvent('jim-payments:client:Charge', { job = job, img = nil }, false)
end)

-- ── Open Tray Stash ───────────────────────────────────────────────────────────
RegisterNetEvent('cobra-supplychain:OpenTray')
AddEventHandler('cobra-supplychain:OpenTray', function(info)
    if type(info) ~= 'table' or not info.trayJob or not info.trayId then
        return lib.notify({ title = 'Error', description = 'Invalid tray data.', type = 'error' })
    end
    local stashId = ("order-tray-%s-%s"):format(info.trayJob, info.trayId)
    -- qs-inventory stash open: must use 'Stash_' prefix on the ID, and pass weight/slots
    TriggerServerEvent('inventory:server:OpenInventory', 'stash', 'Stash_' .. stashId, {
        maxweight = 50000,
        slots     = 10,
    })
    TriggerEvent('inventory:client:SetCurrentStash', 'Stash_' .. stashId)
end)

-- ── Open Storage Stash ────────────────────────────────────────────────────────
RegisterNetEvent('cobra-supplychain:OpenStorage')
AddEventHandler('cobra-supplychain:OpenStorage', function(info)
    if type(info) ~= 'table' or not info.storageJob or not info.storageId then
        return lib.notify({ title = 'Error', description = 'Invalid storage data.', type = 'error' })
    end
    local stashId   = ("storage-%s-%s"):format(info.storageJob, info.storageId)
    -- Pull slot/weight from config so the stash opens with the right capacity
    local business  = Businesses.Businesses[info.storageJob]
    local stashConf = business and business.storage and business.storage[info.storageId]
    local slots     = stashConf and stashConf.inventory and stashConf.inventory.slots  or 20
    local weight    = stashConf and stashConf.inventory and stashConf.inventory.weight or 5000
    TriggerServerEvent('inventory:server:OpenInventory', 'stash', 'Stash_' .. stashId, {
        maxweight = weight * 1000,
        slots     = slots,
    })
    TriggerEvent('inventory:client:SetCurrentStash', 'Stash_' .. stashId)
end)

-- ── Clock In / Out ────────────────────────────────────────────────────────────
-- QBCore:ToggleDuty already fires QBCore:Client:OnDutyUpdate which most scripts
-- (including OSP ambulance) hook into and display their own notification.
-- We do NOT add a second notification here to avoid the double message.
RegisterNetEvent('cobra-supplychain:ToggleClockIn')
AddEventHandler('cobra-supplychain:ToggleClockIn', function(info)
    local success = ProgressBar('Toggling Duty...', 3000,
        'amb@world_human_clipboard@male@idle_a', 'idle_a', false)
    if success then
        TriggerServerEvent('QBCore:ToggleDuty')
    end
end)

-- ── Prepare Food Menu ─────────────────────────────────────────────────────────
RegisterNetEvent('cobra-supplychain:PrepareFood')
AddEventHandler('cobra-supplychain:PrepareFood', function(info)
    if type(info) ~= 'table' or not info.job or not info.index then
        return lib.notify({ title = 'Error', description = 'Invalid prep station data.', type = 'error' })
    end

    local job      = info.job
    local CookLoco = Businesses.Businesses[job] and Businesses.Businesses[job].CookLoco[info.index]
    if not CookLoco then
        return lib.notify({ title = 'Invalid Station', description = 'Prep station not configured.', type = 'error' })
    end

    -- Find the restaurantId for this job
    local restaurantId = nil
    for id, restaurant in pairs(Config.Restaurants) do
        if restaurant.job == job then restaurantId = id break end
    end
    if not restaurantId then
        return lib.notify({ title = 'Error', description = 'Restaurant not found for this job.', type = 'error' })
    end

    -- Fetch current restaurant stock from server first, then build the menu
    TriggerServerEvent('restaurant:getStockForCrafting', restaurantId, info)
end)

-- ── Receive Stock and Build Crafting Menu ─────────────────────────────────────
RegisterNetEvent('restaurant:showCraftingMenu')
AddEventHandler('restaurant:showCraftingMenu', function(info, restaurantStock)
    local job      = info.job
    local index    = info.index
    local CookLoco = Businesses.Businesses[job] and Businesses.Businesses[job].CookLoco[index]
    if not CookLoco then return end

    local options = {}

    for _, item in pairs(CookLoco.items) do
        local hasStock     = true
        local requirements = "Requirements: "

        if item.requiredItems then
            for _, req in pairs(item.requiredItems) do
                local itemInfo        = QBCore.Shared.Items[req.item]
                local itemDisplayName = itemInfo and itemInfo.label or req.item
                local inStock         = restaurantStock[req.item] or 0
                requirements = requirements .. req.amount .. "x " .. itemDisplayName
                    .. " (stock: " .. inStock .. ")  "
                if inStock < req.amount then hasStock = false end
            end
        else
            requirements = "Requirements: None"
        end

        local itemInfo = QBCore.Shared.Items[item.item]
        local itemName = itemInfo and itemInfo.label or item.item

        table.insert(options, {
            title       = itemName,
            description = requirements,
            icon        = item.icon or 'fas fa-utensils',
            disabled    = not hasStock,
            event       = "cobra-supplychain:inputAmount",
            args        = { iteminfo = item, index = index, job = job }
        })
    end

    lib.registerContext({
        id      = 'food_preparation_menu',
        title   = 'Prepare Food',
        options = options,
        onExit  = function() ClearPedTasks(PlayerPedId()) end
    })
    lib.showContext('food_preparation_menu')
end)

-- ── Prepare Food: Quantity Input ──────────────────────────────────────────────
RegisterNetEvent('cobra-supplychain:inputAmount')
AddEventHandler('cobra-supplychain:inputAmount', function(info)
    local iteminfo = info.iteminfo

    local input = lib.inputDialog('Cooking', {
        {
            type        = 'number',
            label       = 'Food Quantity',
            description = 'How many would you like to make?',
            min         = 1,
            max         = 10,
            icon        = 'hashtag'
        }
    })

    if not input or not input[1] then
        ClearPedTasks(PlayerPedId())
        return
    end

    local quantity = tonumber(input[1])
    if not quantity or quantity < 1 then
        ClearPedTasks(PlayerPedId())
        return lib.notify({ title = 'Invalid Input', description = 'Enter a number between 1 and 10.', type = 'error' })
    end

    local hasAll     = true
    local reqDisplay = "Required: "

    if iteminfo.requiredItems then
        for _, req in pairs(iteminfo.requiredItems) do
            local totalNeeded     = req.amount * quantity
            local itemInfo        = QBCore.Shared.Items[req.item]
            local itemDisplayName = itemInfo and itemInfo.label or req.item
            reqDisplay            = reqDisplay .. totalNeeded .. "x " .. itemDisplayName .. "  "
        end
    end

    TriggerEvent('cobra-supplychain:CompletePreparingFood', {
        iteminfo = iteminfo,
        index    = info.index,
        job      = info.job,
        quantity = quantity
    })
end)

-- ── Prepare Food: Cook Loop ───────────────────────────────────────────────────
RegisterNetEvent('cobra-supplychain:CompletePreparingFood')
AddEventHandler('cobra-supplychain:CompletePreparingFood', function(info)
    local iteminfo   = info.iteminfo
    local index      = info.index
    local job        = info.job
    local quantity   = info.quantity
    local crafted    = 0
    local stopReason = nil

    -- Pick animation: item config takes priority, otherwise cycle bar anims
    local animDict, animName
    if iteminfo.progressAnim then
        animDict = iteminfo.progressAnim.dict
        animName = iteminfo.progressAnim.name
    else
        animDict, animName = nextBarAnim()
    end

    for i = 1, quantity do
        -- Reset shared result state before each server call
        _craftResultReceived = false
        _craftLastResult     = nil

        -- Start synced animation BEFORE progress bar (duration -1 = loop)
        playAnimSynced(animDict, animName, -1)

        local success = ProgressBar(
            iteminfo.progressLabel or 'Mixing Drink...',
            iteminfo.time or 5000,
            true  -- cancellable
        )

        -- Stop anim on self and all nearby players
        stopAnimSynced()

        if not success then
            stopReason = 'cancelled'
            break
        end

        -- Ask server to craft one item, result comes back via craftResult event
        TriggerServerEvent('cobra-supplychain:GiveItem', {
            iteminfo = iteminfo,
            quantity = 1,
            job      = job,
            index    = index,
        })

        -- Wait for server response (up to 5 seconds)
        local waited = 0
        while not _craftResultReceived and waited < 500 do
            Citizen.Wait(10)
            waited = waited + 1
        end

        if not _craftResultReceived then
            stopReason = 'error'
            lib.notify({ title = 'Craft Failed', description = 'Server did not respond. Crafting stopped.', type = 'error', duration = 6000 })
            break
        end

        if _craftLastResult == 'success' then
            crafted = crafted + 1
            Citizen.Wait(300)

        elseif _craftLastResult == 'full_weight' then
            stopReason = 'full_weight'
            lib.notify({ title = 'Too Heavy', description = 'Inventory weight limit reached. Crafting stopped.', type = 'error', duration = 6000 })
            break

        elseif _craftLastResult == 'full_slots' then
            stopReason = 'full_slots'
            lib.notify({ title = 'No Space', description = 'No free inventory slots. Crafting stopped.', type = 'error', duration = 6000 })
            break

        elseif _craftLastResult == 'no_stock' then
            stopReason = 'no_stock'
            lib.notify({ title = 'Out of Stock', description = 'Restaurant ran out of ingredients. Crafting stopped.', type = 'error', duration = 6000 })
            break

        else
            stopReason = 'error'
            lib.notify({ title = 'Craft Failed', description = 'Something went wrong. Crafting stopped.', type = 'error', duration = 6000 })
            break
        end
    end

    -- Summary notification
    if crafted > 0 then
        local itemInfo = QBCore.Shared.Items[iteminfo.item]
        local label    = itemInfo and itemInfo.label or iteminfo.item
        lib.notify({
            title       = 'Done',
            description = ('Crafted %dx %s and added to your inventory.'):format(crafted, label),
            type        = 'success',
            duration    = 5000
        })
    end

    -- Re-open prep menu unless player cancelled mid-craft
    if stopReason ~= 'cancelled' then
        Citizen.Wait(400)
        local restaurantId = nil
        for id, r in pairs(Config.Restaurants) do
            if r.job == job then restaurantId = id break end
        end
        if restaurantId then
            TriggerServerEvent('restaurant:getStockForCrafting', restaurantId, { job = job, index = index })
        end
    end
end)

-- ── Sit In Chair ──────────────────────────────────────────────────────────────
RegisterNetEvent('cobra-supplychain:SitChair')
AddEventHandler('cobra-supplychain:SitChair', function(info)
    local ped = PlayerPedId()

    -- Coords passed as flat numbers to survive qb-target arg serialisation
    local cx = tonumber(info.chairX)
    local cy = tonumber(info.chairY)
    local cz = tonumber(info.chairZ)
    local cw = tonumber(info.chairW) or 0.0

    if not cx or not cy or not cz then
        return lib.notify({ title = 'Error', description = 'Invalid chair coordinates.', type = 'error' })
    end

    local targetCoords = vector3(cx, cy, cz)

    if #(GetEntityCoords(ped) - targetCoords) > 3.0 then
        return lib.notify({ title = 'Too Far', description = 'You are too far from the chair.', type = 'error' })
    end

    local playersNearby = QBCore.Functions.GetPlayersFromCoords(targetCoords, 0.5)
    for _, player in ipairs(playersNearby) do
        if player ~= PlayerId() then
            return lib.notify({ title = 'Seat Taken', description = 'Someone is already sitting there.', type = 'error' })
        end
    end

    TaskGoStraightToCoord(ped, cx, cy, cz, 1.0, 2000, cw, 0.1)
    Citizen.Wait(1200)
    TaskStartScenarioAtPosition(ped, "PROP_HUMAN_SEAT_CHAIR_MP_PLAYER", cx, cy, cz, cw, 0, true, true)

    lib.notify({ title = 'Seated', description = 'Press any movement key to stand up.', type = 'success' })
end)

-- ── Show Business Menu Image ──────────────────────────────────────────────────
RegisterNetEvent('cobra-supplychain:ShowMenu')
AddEventHandler('cobra-supplychain:ShowMenu', function(info)
    if not info then return end

    local businessName = info.registerJob or info.storageJob or info.trayJob or info.CookLocoJob
    local business     = Businesses.Businesses[businessName]

    if not business or not business.menu then
        return lib.notify({ title = 'No Menu', description = 'Menu not configured for this business.', type = 'error' })
    end

    lib.alertDialog({
        header   = (business.jobDisplay or "Business") .. ' Menu',
        content  = '![](' .. business.menu .. ')',
        centered = true,
        cancel   = true,
        size     = 'xl',
        labels   = { confirm = 'OK' }
    })
end)

-- ── Seller Blip ───────────────────────────────────────────────────────────────
local SellerBlip

Citizen.CreateThread(function()
    if SellerBlip then RemoveBlip(SellerBlip) end
    SellerBlip = AddBlipForCoord(Config.SellerBlip.coords.x, Config.SellerBlip.coords.y, Config.SellerBlip.coords.z)
    SetBlipSprite(SellerBlip, Config.SellerBlip.blipSprite)
    SetBlipDisplay(SellerBlip, 4)
    SetBlipScale(SellerBlip, Config.SellerBlip.blipScale)
    SetBlipColour(SellerBlip, Config.SellerBlip.blipColor)
    SetBlipAsShortRange(SellerBlip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(Config.SellerBlip.label)
    EndTextCommandSetBlipName(SellerBlip)
end)

-- ── Seller Ped & Target ───────────────────────────────────────────────────────
Citizen.CreateThread(function()
    local pedModel = GetHashKey(Config.PedModel)
    RequestModel(pedModel)
    while not HasModelLoaded(pedModel) do Wait(500) end

    local ped = CreatePed(4,
        pedModel,
        Config.Location.coords.x, Config.Location.coords.y, Config.Location.coords.z,
        Config.Location.heading, false, true)
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetModelAsNoLongerNeeded(pedModel)

    exports['qb-target']:AddTargetEntity(ped, {
        options = {
            {
                type  = "client",
                event = "farming:openFruitMenu",
                icon  = "fas fa-shopping-basket",
                label = "Sell Items"
            },
        },
        distance = 2.0
    })
end)

-- ── Fruit Sell Menu ───────────────────────────────────────────────────────────
-- Items shown are filtered to what the player actually has in their inventory.
-- Server cross-checks PlayerData.items against Config.ItemsFarming and sends back
-- only items the player has, along with their current inventory count.
RegisterNetEvent('farming:openFruitMenu')
AddEventHandler('farming:openFruitMenu', function()
    TriggerServerEvent('farming:getSellabeItems')
end)

-- Receives filtered item list from server: { { fruit, label, price, amount } }
RegisterNetEvent('farming:showSellMenu')
AddEventHandler('farming:showSellMenu', function(sellable)
    if not sellable or #sellable == 0 then
        return lib.notify({
            title       = 'Nothing to Sell',
            description = 'You have no items in your inventory that the buyer wants.',
            type        = 'inform'
        })
    end

    local function createMenu(searchQuery)
        local options = {
            {
                title    = 'Search',
                icon     = 'fas fa-search',
                onSelect = function()
                    local input = lib.inputDialog('Search Items', { { type = 'input', label = 'Item name' } })
                    createMenu(input and input[1] or '')
                end
            }
        }

        local q = string.lower(searchQuery or '')
        for _, entry in ipairs(sellable) do
            if q == '' or string.find(string.lower(entry.label), q, 1, true) then
                local snap = entry
                table.insert(options, {
                    title       = snap.label,
                    description = ('$%d each  |  You have: %d'):format(snap.price, snap.amount),
                    icon        = 'fas fa-hand-holding-dollar',
                    onSelect    = function()
                        local dialog = lib.inputDialog('Sell ' .. snap.label, {
                            { type = 'number', label = ('Amount (max %d)'):format(snap.amount),
                              min = 1, max = snap.amount, default = snap.amount }
                        }, { allowCancel = true })

                        if not dialog or not dialog[1] then
                            return lib.notify({ title = 'Cancelled', description = 'Sale cancelled.', type = 'inform' })
                        end

                        local amount = tonumber(dialog[1])
                        if not amount or amount < 1 or amount > snap.amount then
                            return lib.notify({ title = 'Invalid Amount', description = 'Enter a valid amount.', type = 'error' })
                        end

                        local success = ProgressBar(
                            'Selling ' .. snap.label .. '...',
                            Config.SellProgress,
                            Config.SellingAnimDict,
                            Config.SellingAnimName,
                            false
                        )

                        if success then
                            TriggerServerEvent('farming:sellFruit', snap.fruit, amount)
                        end
                    end
                })
            end
        end

        table.sort(options, function(a, b)
            if a.title == 'Search' then return true end
            if b.title == 'Search' then return false end
            return a.title < b.title
        end)

        lib.registerContext({ id = 'farming_fruit_menu', title = 'Fruit Buyer', options = options })
        lib.showContext('farming_fruit_menu')
    end

    createMenu('')
end)
