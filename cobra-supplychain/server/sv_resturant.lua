local QBCore = exports['qb-core']:GetCoreObject()

-- ── Synced animation broadcasts ───────────────────────────────────────────────
-- Relay play/stop anim events to all other clients so nearby players see the animation.
-- We exclude the sender (-1 would broadcast back to them too).

RegisterNetEvent('cobra-supplychain:broadcastPedAnim')
AddEventHandler('cobra-supplychain:broadcastPedAnim', function(netId, dict, name, duration)
    local src = source
    TriggerClientEvent('cobra-supplychain:playPedAnim', -1, netId, dict, name, duration)
end)

RegisterNetEvent('cobra-supplychain:broadcastStopAnim')
AddEventHandler('cobra-supplychain:broadcastStopAnim', function(netId)
    local src = source
    TriggerClientEvent('cobra-supplychain:stopPedAnim', -1, netId)
end)


-- Called before showing the CookLoco menu so the client knows what's in stock.
RegisterNetEvent('restaurant:getStockForCrafting', function(restaurantId, info)
    local src = source
    MySQL.fetch('SELECT ingredient, quantity FROM stock WHERE restaurant_id = ?', { restaurantId }, function(results)
        local stock = {}
        for _, row in ipairs(results or {}) do
            if row.quantity and row.quantity > 0 then
                stock[row.ingredient] = row.quantity
            end
        end
        TriggerClientEvent('restaurant:showCraftingMenu', src, info, stock)
    end)
end)

-- ── Inventory capacity helpers ────────────────────────────────────────────────
-- qs-inventory stores items in PlayerData.items keyed by slot index.
-- Each slot: { name, amount, weight, info, ... }
-- slot.weight is the total weight for that stack (item weight × amount), in grams.
-- Max weight comes from QBCore.Shared.MaxWeight (grams).
-- Max slots is the inventory size — qs-inventory default is 41.
-- We derive everything from PlayerData so no exports are needed.

local INVENTORY_MAX_SLOTS = Config.InventoryMaxSlots or 41  -- set in config_warehouse.lua

local function getInventoryCapacity(src)
    local player = QBCore.Functions.GetPlayer(src)
    if not player then
        return { maxWeight = 120000, curWeight = 0, freeWeight = 120000, maxSlots = INVENTORY_MAX_SLOTS, usedSlots = 0, freeSlots = INVENTORY_MAX_SLOTS }
    end

    -- QBCore.Shared.MaxWeight is in grams (e.g. 120000 = 120 kg)
    local maxWeight = (QBCore.Shared.MaxWeight) or 120000
    local curWeight = 0
    local usedSlots = 0

    local items = player.PlayerData.items
    if items then
        for _, slot in pairs(items) do
            if slot and slot.name then
                usedSlots = usedSlots + 1
                -- slot.weight is already the total stack weight in grams
                curWeight = curWeight + (slot.weight or 0)
            end
        end
    end

    return {
        maxWeight  = maxWeight,
        curWeight  = curWeight,
        freeWeight = maxWeight - curWeight,
        maxSlots   = INVENTORY_MAX_SLOTS,
        usedSlots  = usedSlots,
        freeSlots  = INVENTORY_MAX_SLOTS - usedSlots,
    }
end

-- ── Craft / Give Item ─────────────────────────────────────────────────────────
-- Per-iteration: checks restaurant stock, player weight & slots, deducts stock,
-- gives item to player, then fires cobra-supplychain:craftResult back to client.
-- result values: "success" | "full_weight" | "full_slots" | "no_stock" | "error"
RegisterServerEvent('cobra-supplychain:GiveItem', function(info)
    local src      = source
    local player   = QBCore.Functions.GetPlayer(src)
    local iteminfo = info.iteminfo
    local quantity = info.quantity or 1

    local function fail(result)
        TriggerClientEvent('cobra-supplychain:craftResult', src, result)
    end

    if not player then return fail('error') end

    if not iteminfo or not iteminfo.requiredItems or type(iteminfo.requiredItems) ~= "table" then
        return fail('error')
    end

    -- ── Resolve restaurant ────────────────────────────────────────────────────
    local restaurantJob = info.job
    if not restaurantJob then
        restaurantJob = player.PlayerData.job and player.PlayerData.job.name
    end
    local restaurantId = nil
    for id, restaurant in pairs(Config.Restaurants) do
        if restaurant.job == restaurantJob then restaurantId = id break end
    end
    if not restaurantId then return fail('error') end

    -- ── Inventory capacity check ──────────────────────────────────────────────
    local cap      = getInventoryCapacity(src)
    local itemData = QBCore.Shared.Items[iteminfo.item]
    local itemWeight = itemData and itemData.weight or 0  -- weight in grams

    if cap.freeSlots <= 0 then
        return fail('full_slots')
    end

    if itemWeight > 0 and cap.freeWeight < itemWeight then
        return fail('full_weight')
    end

    -- ── Restaurant stock check ────────────────────────────────────────────────
    local needed        = {}
    local ingredientList = {}
    for _, req in pairs(iteminfo.requiredItems) do
        local amt = req.amount * quantity
        if not needed[req.item] then
            needed[req.item] = 0
            table.insert(ingredientList, req.item)
        end
        needed[req.item] = needed[req.item] + amt
    end

    local placeholders = string.rep('?,', #ingredientList):sub(1, -2)
    local params = { restaurantId }
    for _, v in ipairs(ingredientList) do table.insert(params, v) end

    MySQL.fetch(
        ('SELECT ingredient, quantity FROM stock WHERE restaurant_id = ? AND ingredient IN (%s)'):format(placeholders),
        params,
        function(stockRows)
            local currentStock = {}
            for _, row in ipairs(stockRows or {}) do
                currentStock[row.ingredient] = row.quantity
            end

            -- Validate stock
            for ing, totalNeeded in pairs(needed) do
                local available = currentStock[ing] or 0
                if available < totalNeeded then
                    TriggerClientEvent('cobra-supplychain:craftResult', src, 'no_stock')
                    return
                end
            end

            -- Deduct stock atomically then give item
            local queries = {}
            for ing, totalNeeded in pairs(needed) do
                table.insert(queries, {
                    query  = 'UPDATE stock SET quantity = quantity - ? WHERE restaurant_id = ? AND ingredient = ?',
                    values = { totalNeeded, restaurantId, ing }
                })
            end

            MySQL.transaction(queries, function(ok)
                if not ok then
                    TriggerClientEvent('cobra-supplychain:craftResult', src, 'error')
                    return
                end

                -- Re-fetch player in case state changed during async DB call
                local freshPlayer = QBCore.Functions.GetPlayer(src)
                if not freshPlayer then
                    -- Refund stock — player disconnected
                    for ing, totalNeeded in pairs(needed) do
                        MySQL.execute('UPDATE stock SET quantity = quantity + ? WHERE restaurant_id = ? AND ingredient = ?',
                            { totalNeeded, restaurantId, ing })
                    end
                    return
                end

                -- Final weight/slot guard (state may have changed during DB round-trip)
                local capFinal = getInventoryCapacity(src)
                if capFinal.freeSlots <= 0 then
                    -- Refund stock, slots filled up mid-craft
                    for ing, totalNeeded in pairs(needed) do
                        MySQL.execute('UPDATE stock SET quantity = quantity + ? WHERE restaurant_id = ? AND ingredient = ?',
                            { totalNeeded, restaurantId, ing })
                    end
                    TriggerClientEvent('cobra-supplychain:craftResult', src, 'full_slots')
                    return
                end
                if itemWeight > 0 and capFinal.freeWeight < itemWeight then
                    -- Refund stock, weight filled up mid-craft
                    for ing, totalNeeded in pairs(needed) do
                        MySQL.execute('UPDATE stock SET quantity = quantity + ? WHERE restaurant_id = ? AND ingredient = ?',
                            { totalNeeded, restaurantId, ing })
                    end
                    TriggerClientEvent('cobra-supplychain:craftResult', src, 'full_weight')
                    return
                end

                freshPlayer.Functions.AddItem(iteminfo.item, quantity)
                TriggerClientEvent('cobra-supplychain:craftResult', src, 'success')
            end)
        end
    )
end)
-- qb-inventory stash registration uses exports['qb-inventory']:RegisterStash
-- Quasar Inventory (qs-inventory) uses the same API surface as qb-inventory
-- so this works for both.

Citizen.CreateThread(function()
    if not Businesses.Businesses or type(Businesses.Businesses) ~= "table" then
        print("[cobra-supplychain] ERROR: Businesses.Businesses is not a valid table.")
        return
    end

    for job, details in pairs(Businesses.Businesses) do
        -- Validate trays
        if not details.trays or type(details.trays) ~= "table" then
            print(("[cobra-supplychain] WARNING: 'trays' for job '%s' is not a valid table."):format(job))
            details.trays = {}
        end

        -- Validate storage
        if not details.storage or type(details.storage) ~= "table" then
            print(("[cobra-supplychain] WARNING: 'storage' for job '%s' is not a valid table."):format(job))
            details.storage = {}
        end

        -- Register tray stashes
        -- qs-inventory RegisterStash signature: (id, slots, weight) — no label parameter
        -- The ID is stored WITHOUT the "Stash_" prefix here; qs-inventory adds it internally
        -- when opened via the inventory:server:OpenInventory event.
        for trayIndex, _ in pairs(details.trays) do
            local stashId = ("order-tray-%s-%s"):format(job, trayIndex)
            exports['qs-inventory']:RegisterStash(stashId, 10, 50000)
        end

        -- Register storage stashes
        for storageIndex, storageDetails in pairs(details.storage) do
            local stashId = ("storage-%s-%s"):format(job, storageIndex)
            local slots   = storageDetails.inventory and storageDetails.inventory.slots  or 20
            local weight  = storageDetails.inventory and storageDetails.inventory.weight or 5000
            -- qs-inventory weight is in grams; config value is in KG so multiply by 1000
            exports['qs-inventory']:RegisterStash(stashId, slots, weight * 1000)
        end
    end
end)



