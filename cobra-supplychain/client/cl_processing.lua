local QBCore = exports['qb-core']:GetCoreObject()

-- ── Active delivery entity tracking ──────────────────────────────────────────
-- Populated when a delivery starts, cleared when it ends normally.
-- Used to clean up orphaned vehicles if the resource stops mid-delivery.
local activeDeliveryEntities = {
    truck   = nil,
    trailer = nil,
    forklift = nil,
}

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    -- Best-effort cleanup — delete any vehicles we were responsible for
    for key, entity in pairs(activeDeliveryEntities) do
        if entity and DoesEntityExist(entity) then
            DeleteEntity(entity)
        end
        activeDeliveryEntities[key] = nil
    end
end)

-- ── Helper: QBCore progressbar ────────────────────────────────────────────────
local function ProgressBar(label, duration, animDict, animName, canCancel)
    return lib.progressBar({
        duration  = duration,
        label     = label,
        useWhileDead = false,
        canCancel = canCancel ~= false,
        disable   = { movement = true, car = true, combat = true },
        anim      = animDict and { dict = animDict, clip = animName } or nil,
    })
end

-- ── Restaurant Ordering Computer (qb-target) ─────────────────────────────────
Citizen.CreateThread(function()
    for id, restaurant in pairs(Config.Restaurants) do
        exports['qb-target']:AddBoxZone(
            "restaurant_computer_" .. id,
            restaurant.position,
            1.5, 1.5,
            {
                name      = "restaurant_computer_" .. id,
                heading   = restaurant.heading,
                debugPoly = false,
                minZ      = restaurant.position.z - 1.0,
                maxZ      = restaurant.position.z + 1.0,
            },
            {
                options = {
                    {
                        type        = "client",
                        event       = "restaurant:openOrderMenu",
                        icon        = 'fas fa-laptop',
                        label       = 'Order Ingredients',
                        restaurantId = id,
                        job         = restaurant.job,
                    }
                },
                distance = 2.5
            }
        )
    end
end)

-- ── Open Order Menu ───────────────────────────────────────────────────────────
RegisterNetEvent('restaurant:openOrderMenu')
AddEventHandler('restaurant:openOrderMenu', function(data)
    local PlayerData = QBCore.Functions.GetPlayerData()
    local PlayerJob  = PlayerData.job

    -- Job check: player must work at this restaurant
    -- Boss check uses grade.level >= 3 (adjust if your server uses a different boss grade)
    local restaurantId  = data.restaurantId
    local restaurantJob = Config.Restaurants[restaurantId] and Config.Restaurants[restaurantId].job

    if not PlayerJob or PlayerJob.name ~= restaurantJob then
        return lib.notify({
            title       = 'Access Denied',
            description = 'You do not work here.',
            type        = 'error',
            duration    = 5000
        })
    end

    if not restaurantId then return end

    local items = Config.Items[restaurantJob] or {}

    -- ── Cart: items queued before submitting ─────────────────────────────────
    -- cart[ingredient] = { name, price, quantity }
    local cart = {}

    local function cartTotal()
        local t = 0
        for _, v in pairs(cart) do t = t + v.price * v.quantity end
        return t
    end

    local function cartItemCount()
        local c = 0
        for _ in pairs(cart) do c = c + 1 end
        return c
    end

    local function cartBoxCount()
        local boxes = 0
        for _, v in pairs(cart) do
            boxes = boxes + math.ceil(v.quantity / 20)
        end
        return boxes
    end

    -- Build a sorted flat list of all orderable items
    local function buildItemList(query)
        local filtered = {}
        for ingredient, details in pairs(items) do
            local matchName = string.lower(details.name or ingredient)
            if not query or query == '' or string.find(matchName, string.lower(query), 1, true) then
                table.insert(filtered, { ingredient = ingredient, details = details })
            end
        end
        table.sort(filtered, function(a, b) return a.details.name < b.details.name end)
        return filtered
    end

    -- Forward declarations
    local createMenu, showCart

    showCart = function()
        if cartItemCount() == 0 then
            lib.notify({ title = 'Cart Empty', description = 'Add items before reviewing your order.', type = 'inform' })
            createMenu('')
            return
        end

        local options = {
            {
                title       = ('Submit Order  —  $%d  |  ~%d box(es)'):format(cartTotal(), cartBoxCount()),
                description = 'Charge society account and place the full order.',
                icon        = 'fas fa-check-circle',
                onSelect    = function()
                    -- Build cart list for server
                    local cartList = {}
                    for ingredient, v in pairs(cart) do
                        table.insert(cartList, { ingredient = ingredient, quantity = v.quantity })
                    end
                    TriggerServerEvent('restaurant:orderBatch', cartList, restaurantId)
                    cart = {}
                end
            },
            {
                title       = 'Clear Cart',
                description = 'Remove all items and start over.',
                icon        = 'fas fa-trash',
                onSelect    = function()
                    cart = {}
                    lib.notify({ title = 'Cart Cleared', description = 'All items removed.', type = 'inform' })
                    createMenu('')
                end
            },
            {
                title       = 'Back to Items',
                icon        = 'fas fa-arrow-left',
                onSelect    = function() createMenu('') end
            }
        }

        -- List cart contents
        for ingredient, v in pairs(cart) do
            local boxes = math.ceil(v.quantity / 20)
            table.insert(options, {
                title       = ('%s  ×%d'):format(v.name, v.quantity),
                description = ('$%d  |  %d box(es)  —  Click to remove'):format(v.price * v.quantity, boxes),
                icon        = 'fas fa-minus-circle',
                onSelect    = function()
                    cart[ingredient] = nil
                    lib.notify({ title = 'Removed', description = v.name .. ' removed from cart.', type = 'inform' })
                    showCart()
                end
            })
        end

        lib.registerContext({ id = 'order_cart_menu', title = ('Cart  (%d item(s))'):format(cartItemCount()), options = options })
        lib.showContext('order_cart_menu')
    end

    createMenu = function(searchQuery)
        local inCart = cartItemCount()
        local options = {
            {
                title       = 'View My Outstanding Orders',
                description = 'See pending and accepted orders for this business.',
                icon        = 'fas fa-receipt',
                onSelect    = function()
                    TriggerServerEvent('restaurant:getOutstandingOrders', restaurantId)
                end
            },
            {
                title       = 'View Stock',
                description = 'Check current restaurant stock levels.',
                icon        = 'fas fa-boxes-stacked',
                onSelect    = function()
                    TriggerServerEvent('restaurant:requestStock', restaurantId)
                end
            },
            {
                title       = 'Contribute Stock',
                description = 'Add items from your inventory directly into the business stock.',
                icon        = 'fas fa-hand-holding-box',
                onSelect    = function()
                    TriggerServerEvent('restaurant:getContributableItems', restaurantId)
                end
            },
            {
                title       = inCart > 0 and ('View Cart  (%d item(s))  —  $%d'):format(inCart, cartTotal()) or 'View Cart  (empty)',
                description = inCart > 0 and ('~%d box(es) to deliver'):format(cartBoxCount()) or 'No items added yet.',
                icon        = 'fas fa-shopping-cart',
                disabled    = inCart == 0,
                onSelect    = function() showCart() end
            },
            {
                title       = 'Search',
                description = 'Filter the item list by name.',
                icon        = 'fas fa-search',
                onSelect    = function()
                    local input = lib.inputDialog('Search Ingredients', {
                        { type = 'input', label = 'Ingredient name' }
                    })
                    createMenu(input and input[1] or '')
                end
            }
        }

        local list = buildItemList(searchQuery)

        if #list == 0 then
            table.insert(options, {
                title    = 'No items found',
                description = searchQuery ~= '' and ('No results for "%s"'):format(searchQuery) or 'No items configured.',
                icon     = 'fas fa-ban',
                disabled = true,
            })
        end

        for _, item in ipairs(list) do
            local ingredient = item.ingredient
            local details    = item.details
            local inCartQty  = cart[ingredient] and cart[ingredient].quantity or 0

            table.insert(options, {
                title       = details.name .. (inCartQty > 0 and ('  [in cart: %d]'):format(inCartQty) or ''),
                description = ('$%d per unit'):format(details.price),
                icon        = inCartQty > 0 and 'fas fa-cart-arrow-down' or 'fas fa-cart-plus',
                onSelect    = function()
                    local input = lib.inputDialog('Add to Order — ' .. details.name, {
                        { type = 'number', label = 'Quantity', placeholder = 'e.g. 40', min = 1, max = 500, required = true }
                    })
                    if not input or not input[1] then createMenu(searchQuery) return end
                    local quantity = tonumber(input[1])
                    if not quantity or quantity < 1 then
                        lib.notify({ title = 'Error', description = 'Invalid quantity.', type = 'error' })
                        createMenu(searchQuery)
                        return
                    end
                    -- Add/update cart
                    cart[ingredient] = { name = details.name, price = details.price, quantity = quantity }
                    local boxes = math.ceil(quantity / 20)
                    lib.notify({
                        title       = 'Added to Cart',
                        description = ('%dx %s  ($%d)  |  ~%d box(es)'):format(quantity, details.name, details.price * quantity, boxes),
                        type        = 'success'
                    })
                    createMenu(searchQuery)
                end
            })
        end

        lib.registerContext({ id = 'order_menu', title = 'Order Ingredients', options = options })
        lib.showContext('order_menu')
    end

    createMenu('')
end)

-- ── Outstanding Orders View (restaurant side) ─────────────────────────────────
-- Pending batches can be cancelled (society account refunded).
-- Accepted batches are in-transit — display only, cannot cancel.
RegisterNetEvent('restaurant:showOutstandingOrders')
AddEventHandler('restaurant:showOutstandingOrders', function(batches, restaurantId)
    if not batches or #batches == 0 then
        return lib.notify({ title = 'No Outstanding Orders', description = 'No pending or accepted orders for this business.', type = 'inform' })
    end

    local options = {}
    for _, batch in ipairs(batches) do
        local isPending   = batch.status == 'pending'
        local statusIcon  = isPending and 'fas fa-clock' or 'fas fa-truck'
        local statusLabel = isPending and 'Pending' or 'In Transit'
        local itemLines   = {}
        for _, item in ipairs(batch.items) do
            table.insert(itemLines, ('%dx %s'):format(item.quantity, item.name))
        end

        local batchSnap = batch
        table.insert(options, {
            title       = ('Order #%s  —  %s'):format(batch.batchId:sub(1, 8), statusLabel),
            description = table.concat(itemLines, ',  ') .. ('  |  $%d  |  ~%d box(es)'):format(batch.totalCost, batch.totalBoxes),
            icon        = statusIcon,
            disabled    = not isPending,  -- accepted/in-transit orders are read-only
            onSelect    = isPending and function()
                -- Confirm before cancelling
                local confirm = lib.alertDialog({
                    header  = 'Cancel Order?',
                    content = ('Cancel this order and refund $%d to the society account?\n\nItems: %s'):format(
                        batchSnap.totalCost, table.concat(itemLines, ', ')),
                    centered = true,
                    cancel   = true,
                })
                if confirm == 'confirm' then
                    TriggerServerEvent('restaurant:cancelBatch', batchSnap.batchId, restaurantId)
                end
            end or nil,
        })
    end

    -- Hint at the bottom for in-transit orders
    local hasAccepted = false
    for _, b in ipairs(batches) do if b.status ~= 'pending' then hasAccepted = true break end end
    if hasAccepted then
        table.insert(options, {
            title    = 'In-transit orders cannot be cancelled',
            icon     = 'fas fa-info-circle',
            disabled = true,
        })
    end

    lib.registerContext({ id = 'outstanding_orders_menu', title = 'Outstanding Orders', options = options })
    lib.showContext('outstanding_orders_menu')
end)


-- Receives items the player has in inventory that are valid for this restaurant.
-- contributable = { { ingredient, displayName, inInventory } }
RegisterNetEvent('restaurant:showContributeMenu')
AddEventHandler('restaurant:showContributeMenu', function(contributable, restaurantId)
    if not contributable or #contributable == 0 then
        return lib.notify({
            title       = 'Nothing to Contribute',
            description = 'You have no inventory items that this restaurant uses.',
            type        = 'inform'
        })
    end

    local options = {}
    for _, entry in ipairs(contributable) do
        local ing   = entry.ingredient
        local label = entry.displayName
        local have  = entry.inInventory

        table.insert(options, {
            title       = label,
            description = ('You have: %d'):format(have),
            icon        = 'fas fa-plus-circle',
            onSelect    = function()
                local input = lib.inputDialog('Contribute ' .. label, {
                    {
                        type        = 'number',
                        label       = ('Amount (max %d)'):format(have),
                        min         = 1,
                        max         = have,
                        required    = true
                    }
                })
                if not input or not input[1] then return end
                local amount = tonumber(input[1])
                if not amount or amount < 1 or amount > have then
                    return lib.notify({ title = 'Error', description = 'Invalid amount.', type = 'error' })
                end
                TriggerServerEvent('restaurant:contributeStock', restaurantId, ing, amount)
            end
        })
    end

    lib.registerContext({ id = 'contribute_stock_menu', title = 'Contribute to Stock', options = options })
    lib.showContext('contribute_stock_menu')
end)
RegisterNetEvent('restaurant:showResturantStock')
AddEventHandler('restaurant:showResturantStock', function(stock, restaurantId)
    local options = {}

    for ingredient, quantity in pairs(stock) do
        -- Use QBCore shared items for display label
        local itemInfo    = QBCore.Shared.Items[ingredient]
        local displayName = itemInfo and itemInfo.label or ingredient

        table.insert(options, {
            title       = displayName,
            description = ('In stock: %d units'):format(quantity),
            icon        = 'fas fa-box',
            onSelect    = function()
                local input = lib.inputDialog('Withdraw Stock', {
                    { type = 'number', label = 'Amount to withdraw', min = 1, max = quantity, required = true }
                })
                if not input or not input[1] then return end
                local amount = tonumber(input[1])
                if not amount or amount < 1 then
                    return lib.notify({ title = 'Error', description = 'Invalid amount.', type = 'error' })
                end
                TriggerServerEvent('restaurant:withdrawStock', restaurantId, ingredient, amount)
            end
        })
    end

    table.sort(options, function(a, b) return a.title < b.title end)

    if #options == 0 then
        return lib.notify({ title = 'No Stock', description = 'The restaurant has no stock.', type = 'inform' })
    end

    lib.registerContext({ id = 'restaurant_stock_menu', title = 'Restaurant Stock', options = options })
    lib.showContext('restaurant_stock_menu')
end)

-- ── Warehouse NPC & Target Zones ──────────────────────────────────────────────
Citizen.CreateThread(function()
    for index, warehouse in ipairs(Config.WarehousesLocation) do

        -- Spawn warehouse NPC first so we can target the entity directly
        local pedModel = GetHashKey(warehouse.pedhash)
        RequestModel(pedModel)
        while not HasModelLoaded(pedModel) do Wait(500) end

        local ped = CreatePed(4,
            pedModel,
            warehouse.position.x,
            warehouse.position.y,
            warehouse.position.z,
            warehouse.heading,
            false, true)
        SetEntityAsMissionEntity(ped, true, true)
        SetBlockingOfNonTemporaryEvents(ped, true)
        FreezeEntityPosition(ped, true)
        SetEntityInvincible(ped, true)
        SetModelAsNoLongerNeeded(pedModel)

        -- Target the ped entity directly — much more reliable than a box zone
        -- when the ped is standing at that exact position
        exports['qb-target']:AddTargetEntity(ped, {
            options = {
                {
                    type     = "client",
                    event    = "warehouse:openProcessingMenu",
                    icon     = 'fas fa-box',
                    label    = 'Process Orders',
                    whIndex  = index,
                }
            },
            distance = 2.5
        })

        -- Warehouse blip
        local blip = AddBlipForCoord(warehouse.position.x, warehouse.position.y, warehouse.position.z)
        SetBlipSprite(blip, 473)
        SetBlipDisplay(blip, 4)
        SetBlipScale(blip, 0.9)
        SetBlipColour(blip, 16)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString('Warehouse')
        EndTextCommandSetBlipName(blip)
    end
end)

-- ── Warehouse Processing Menu ─────────────────────────────────────────────────
RegisterNetEvent('warehouse:openProcessingMenu')
AddEventHandler('warehouse:openProcessingMenu', function(data)
    local whIndex = data and data.whIndex or 1
    lib.registerContext({
        id      = 'warehouse_main_menu',
        title   = 'Warehouse Menu',
        options = {
            {
                title       = 'View Warehouse Stock',
                description = 'See what is currently in the warehouse.',
                icon        = 'fas fa-warehouse',
                onSelect    = function()
                    TriggerServerEvent('warehouse:getStocks')
                end
            },
            {
                title       = 'View Pending Orders',
                description = 'See and action restaurant orders.',
                icon        = 'fas fa-clipboard-list',
                onSelect    = function()
                    TriggerServerEvent('warehouse:getPendingOrders', whIndex)
                end
            }
        }
    })
    lib.showContext('warehouse_main_menu')
end)

-- ── Show Pending Batches (warehouse side) ────────────────────────────────────
RegisterNetEvent('warehouse:showOrderDetails')
AddEventHandler('warehouse:showOrderDetails', function(batches, whIndex)
    if not batches or #batches == 0 then
        return lib.notify({ title = 'No Orders', description = 'There are no pending orders.', type = 'inform' })
    end

    local options = {}
    for _, batch in ipairs(batches) do
        local restaurantData = Config.Restaurants[batch.restaurantId]
        local restaurantName = restaurantData and restaurantData.name or 'Unknown Business'
        local itemLines = {}
        for _, item in ipairs(batch.items) do
            table.insert(itemLines, ('%dx %s'):format(item.quantity, item.name))
        end

        local batchSnap = batch
        table.insert(options, {
            title       = restaurantName .. '  —  ' .. #batch.items .. ' item(s)',
            description = table.concat(itemLines, ',  ') .. ('  |  $%d  |  ~%d box(es)'):format(batch.totalCost, batch.totalBoxes),
            icon        = 'fas fa-box-open',
            onSelect    = function()
                openBatchActionMenu(batchSnap, whIndex)
            end
        })
    end

    lib.registerContext({ id = 'warehouse_orders_menu', title = 'Pending Orders', options = options })
    lib.showContext('warehouse_orders_menu')
end)

-- ── Warehouse state change (only sent to players who were waiting) ────────────
RegisterNetEvent('warehouse:onStateChange')
AddEventHandler('warehouse:onStateChange', function(whIndex, state)
    if state == "loaded" then
        lib.notify({
            title       = 'Warehouse ' .. whIndex .. ' Free',
            description = 'The truck has left — you can now accept the next delivery.',
            type        = 'success',
            duration    = 6000
        })
    end
end)

-- ── Batch Action Menu (Accept / Deny) ─────────────────────────────────────────
function openBatchActionMenu(batch, whIndex)
    local itemLines = {}
    for _, item in ipairs(batch.items) do
        table.insert(itemLines, ('%dx %s'):format(item.quantity, item.name))
    end

    lib.registerContext({
        id      = 'warehouse_order_action',
        title   = 'Batch: ' .. #batch.items .. ' item(s)',
        options = {
            {
                title       = 'Accept Batch',
                description = 'Deliver what is in stock. Items with insufficient stock become a new order.',
                icon        = 'fas fa-check',
                onSelect    = function()
                    TriggerServerEvent('warehouse:acceptBatch', batch.batchId, batch.restaurantId, whIndex)
                end
            },
            {
                title       = 'Deny Batch',
                description = 'Return all items to pending.',
                icon        = 'fas fa-times',
                onSelect    = function()
                    TriggerServerEvent('warehouse:denyBatch', batch.batchId)
                end
            }
        }
    })
    lib.showContext('warehouse_order_action')
end

-- ── Show Warehouse Stock ──────────────────────────────────────────────────────
RegisterNetEvent('restaurant:showStockDetails')
AddEventHandler('restaurant:showStockDetails', function(stock)
    if not stock or next(stock) == nil then
        return lib.notify({ title = 'No Stock', description = 'The warehouse has no stock.', type = 'inform' })
    end

    local function buildMenu(query)
        local options = {
            {
                title       = 'Search',
                description = 'Search for a stock item',
                icon        = 'fas fa-search',
                onSelect    = function()
                    local input = lib.inputDialog('Search Stock', {
                        { type = 'input', label = 'Ingredient name' }
                    })
                    if input and input[1] then buildMenu(input[1]) end
                end
            }
        }

        for ingredient, quantity in pairs(stock) do
            if string.find(string.lower(ingredient), string.lower(query)) then
                -- qb-inventory item label
                local itemInfo    = QBCore.Shared.Items[ingredient]
                local displayName = itemInfo and itemInfo.label or ingredient

                table.insert(options, {
                    title       = displayName,
                    description = ('Available: %d'):format(quantity),
                    icon        = 'fas fa-cubes',
                })
            end
        end

        table.sort(options, function(a, b)
            if a.title == 'Search' then return true end
            if b.title == 'Search' then return false end
            return a.title < b.title
        end)

        lib.registerContext({ id = 'warehouse_stock_menu', title = 'Warehouse Stock', options = options })
        lib.showContext('warehouse_stock_menu')
    end

    buildMenu('')
end)

-- ── Spawn Truck & Trailer ─────────────────────────────────────────────────────
RegisterNetEvent('warehouse:spawnVehicles')
AddEventHandler('warehouse:spawnVehicles', function(restaurantId, orders, whIndex)
    local warehouseConfig = Config.Warehouses[whIndex or 1]
    if not warehouseConfig then
        return lib.notify({ title = 'Error', description = 'No warehouse available.', type = 'error' })
    end

    lib.alertDialog({
        header   = 'Welcome, Driver!',
        content  = 'You have a delivery to make.\nBack the truck into the marked zone to begin loading.',
        centered = true,
        cancel   = true
    })

    DoScreenFadeOut(2500)
    Citizen.Wait(2500)

    local playerPed = PlayerPedId()

    local truckHash   = GetHashKey(warehouseConfig.truck.model)
    local trailerHash = GetHashKey(warehouseConfig.trailer.model)

    RequestModel(truckHash)
    while not HasModelLoaded(truckHash) do Citizen.Wait(100) end
    RequestModel(trailerHash)
    while not HasModelLoaded(trailerHash) do Citizen.Wait(100) end

    -- Create as networked so all players see the vehicles
    local truck = CreateVehicle(truckHash,
        warehouseConfig.truck.position.x,
        warehouseConfig.truck.position.y,
        warehouseConfig.truck.position.z,
        warehouseConfig.truck.position.w, true, false)
    SetEntityAsMissionEntity(truck, true, true)

    local trailer = CreateVehicle(trailerHash,
        warehouseConfig.trailer.position.x,
        warehouseConfig.trailer.position.y,
        warehouseConfig.trailer.position.z,
        warehouseConfig.trailer.position.w, true, false)
    SetEntityAsMissionEntity(trailer, true, true)

    local truckPlate  = GetVehicleNumberPlateText(truck)
    local trailerPlate = GetVehicleNumberPlateText(trailer)
    TriggerEvent("vehiclekeys:client:SetOwner", truckPlate)
    TriggerEvent("vehiclekeys:client:SetOwner", trailerPlate)

    AttachVehicleToTrailer(truck, trailer, 50)
    DoScreenFadeIn(2500)

    -- Track entities locally (server-side tracking is handled inside acceptBatch)
    activeDeliveryEntities.truck   = truck
    activeDeliveryEntities.trailer = trailer

    local blip = AddBlipForCoord(
        warehouseConfig.deliveryMarker.position.x,
        warehouseConfig.deliveryMarker.position.y,
        warehouseConfig.deliveryMarker.position.z)
    SetBlipSprite(blip, 1)
    SetBlipDisplay(blip, 4)
    SetBlipScale(blip, 1.0)
    SetBlipColour(blip, 2)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString("Delivery Area")
    EndTextCommandSetBlipName(blip)

    lib.notify({
        title       = 'Vehicles Spawned',
        description = 'Truck and trailer ready! Drive to the marker and back into position.',
        type        = 'success',
        duration    = 8000
    })

    TaskWarpPedIntoVehicle(playerPed, truck, -1)

    Citizen.CreateThread(function()
        local notified   = false
        local checkTimer = 0
        while true do
            Citizen.Wait(0)

            DrawMarker(1,
                warehouseConfig.deliveryMarker.position.x,
                warehouseConfig.deliveryMarker.position.y,
                warehouseConfig.deliveryMarker.position.z,
                0,0,0, 0,0,0,
                warehouseConfig.deliveryMarker.radius,
                warehouseConfig.deliveryMarker.radius,
                1.0, 0,255,0,100, false,true,2,false,nil,nil,false)

            checkTimer = checkTimer + 1
            if checkTimer >= 30 then
                checkTimer = 0
                local trailerBack  = GetOffsetFromEntityInWorldCoords(trailer, 0.0, -5.0, 0.0)
                local distToMarker = Vdist(trailerBack, warehouseConfig.deliveryMarker.position)

                if distToMarker < warehouseConfig.deliveryMarker.radius and GetEntitySpeed(trailer) < 0.1 then
                    if not notified then
                        notified = true
                        if blip then RemoveBlip(blip) end
                        lib.notify({ title = 'In Position', description = 'Trailer parked. Starting forklift loading.', type = 'success' })
                        TriggerEvent('warehouse:loadingWithForklift',
                            warehouseConfig.trailer,
                            warehouseConfig.deliveryMarker,
                            truck, restaurantId, orders, trailer, whIndex)
                        return
                    end
                end
            end
        end
    end)
end)

-- ── Forklift Loading Phase ────────────────────────────────────────────────────
RegisterNetEvent('warehouse:loadingWithForklift')
AddEventHandler('warehouse:loadingWithForklift', function(trailerConfig, deliveryMarkerConfig, truck, restaurantId, orders, trailer, whIndex)
    lib.alertDialog({
        header   = 'Loading Time!',
        content  = 'Use the forklift to move pallets into the delivery zone.\nAll pallets must be loaded before you can proceed.',
        centered = true,
        cancel   = true
    })

    DoScreenFadeOut(2500)
    Citizen.Wait(2500)

    local playerPed = PlayerPedId()
    local playerPos = GetEntityCoords(playerPed)

    local warehouseConfig = Config.Warehouses[whIndex or 1]
    if not warehouseConfig then
        return lib.notify({ title = 'Error', description = 'No nearby warehouse found.', type = 'error' })
    end

    -- Spawn forklift as networked so all players see it
    RequestModel('forklift')
    while not HasModelLoaded('forklift') do Citizen.Wait(100) end

    local forklift = CreateVehicle('forklift',
        warehouseConfig.forkliftPosition.x,
        warehouseConfig.forkliftPosition.y,
        warehouseConfig.forkliftPosition.z,
        warehouseConfig.heading or 0.0, true, false)
    SetEntityAsMissionEntity(forklift, true, true)

    TaskWarpPedIntoVehicle(playerPed, forklift, -1)
    DoScreenFadeIn(2500)

    activeDeliveryEntities.forklift = forklift

    lib.notify({ title = 'Forklift Ready', description = 'Load the pallets onto the truck.', type = 'success' })

    -- Blips
    local forkliftBlip = AddBlipForCoord(warehouseConfig.forkliftPosition.x, warehouseConfig.forkliftPosition.y, warehouseConfig.forkliftPosition.z)
    SetBlipSprite(forkliftBlip, 2) SetBlipScale(forkliftBlip, 1.0) SetBlipColour(forkliftBlip, 1) SetBlipAsShortRange(forkliftBlip, true)
    BeginTextCommandSetBlipName("STRING") AddTextComponentString("Forklift Return") EndTextCommandSetBlipName(forkliftBlip)

    local truckBlip = AddBlipForCoord(deliveryMarkerConfig.position.x, deliveryMarkerConfig.position.y, deliveryMarkerConfig.position.z)
    SetBlipSprite(truckBlip, 1) SetBlipScale(truckBlip, 1.0) SetBlipColour(truckBlip, 3) SetBlipAsShortRange(truckBlip, true)
    BeginTextCommandSetBlipName("STRING") AddTextComponentString("Truck Location") EndTextCommandSetBlipName(truckBlip)

    -- Spawn pallets as LOCAL objects — only the driver interacts with them.
    -- Local (non-networked) objects delete instantly with DeleteObject, no ownership issues.
    -- pallets[i] = { entity = handle, blip = blipHandle }
    local pallets     = {}
    local palletModel = GetHashKey('prop_boxpile_06b')
    RequestModel(palletModel)
    while not HasModelLoaded(palletModel) do Citizen.Wait(100) end

    for idx, pos in ipairs(warehouseConfig.pallets) do
        -- false, false, false = not networked, not mission entity, dynamic physics
        local ent = CreateObject(palletModel, pos.x, pos.y, pos.z, false, false, true)
        if ent and ent ~= 0 then
            PlaceObjectOnGroundProperly(ent)
            local pb = AddBlipForCoord(pos.x, pos.y, pos.z)
            SetBlipSprite(pb, 1) SetBlipScale(pb, 0.7) SetBlipColour(pb, 4) SetBlipAsShortRange(pb, true)
            BeginTextCommandSetBlipName("STRING") AddTextComponentString("Pallet " .. idx) EndTextCommandSetBlipName(pb)
            table.insert(pallets, { entity = ent, blip = pb })
        end
    end

    SetModelAsNoLongerNeeded(palletModel)
    lib.notify({ title = 'Pallets Spawned', description = 'Use the forklift to carry each pallet into the green zone.', type = 'success' })

    local allLoaded  = false
    local textShown  = ''   -- track what textUI is currently showing so we only call show/hide when it changes

    local function setTextUI(msg)
        if textShown ~= msg then
            if msg == '' then
                lib.hideTextUI()
            else
                lib.showTextUI(msg)
            end
            textShown = msg
        end
    end

    Citizen.CreateThread(function()
        while true do
            Citizen.Wait(0)

            -- Draw zone markers every frame so they don't flicker
            DrawMarker(1,
                warehouseConfig.forkliftPosition.x, warehouseConfig.forkliftPosition.y, warehouseConfig.forkliftPosition.z - 1.0,
                0,0,0, 0,0,0, 2.0,2.0,1.0, 255,0,0,100, false,true,2,false,nil,nil,false)
            DrawMarker(1,
                deliveryMarkerConfig.position.x, deliveryMarkerConfig.position.y, deliveryMarkerConfig.position.z,
                0,0,0, 0,0,0,
                deliveryMarkerConfig.radius, deliveryMarkerConfig.radius, 1.0,
                0,255,0,100, false,true,2,false,nil,nil,false)

            local forkliftPos = GetEntityCoords(forklift)

            -- ── Phase 1: return forklift after all pallets loaded ─────────────
            if allLoaded then
                if #(forkliftPos - warehouseConfig.forkliftPosition) < 3.0 then
                    setTextUI('[E] Return Forklift')
                    if IsControlJustReleased(0, 38) then
                        setTextUI('')
                        local success = ProgressBar('Returning Forklift...', 5000,
                            'anim@scripted@heist@ig3_button_press@male@', 'button_press', false)
                        if success and DoesEntityExist(forklift) then
                            DeleteVehicle(forklift)
                            activeDeliveryEntities.forklift = nil
                            RemoveBlip(forkliftBlip)
                            RemoveBlip(truckBlip)
                            TriggerServerEvent('warehouse:truckLoaded', whIndex)
                            lib.notify({ title = 'Forklift Returned', description = 'Time to deliver! Warehouse is now free for the next driver.', type = 'success' })
                            TriggerEvent('warehouse:startDelivery', restaurantId, truck, orders, trailer, whIndex)
                            return
                        end
                    end
                else
                    setTextUI('')
                end

            -- ── Phase 2: load pallets ─────────────────────────────────────────
            else
                local palletInZone = false
                local distForkliftToZone = #(forkliftPos - deliveryMarkerConfig.position)

                for i = #pallets, 1, -1 do
                    local p = pallets[i]
                    if DoesEntityExist(p.entity) then
                        local palletPos          = GetEntityCoords(p.entity)
                        local distPalletToZone   = #(palletPos - deliveryMarkerConfig.position)

                        -- Pallet must be near the zone (on forks) and forklift must be in zone
                        if distPalletToZone < deliveryMarkerConfig.radius + 2.0 and distForkliftToZone < deliveryMarkerConfig.radius then
                            palletInZone = true
                            setTextUI('[E] Drop Off Pallet')
                            if IsControlJustReleased(0, 38) then
                                setTextUI('')
                                local success = ProgressBar('Loading Pallet...', 3000,
                                    'anim@scripted@heist@ig3_button_press@male@', 'button_press', false)
                                if success then
                                    if DoesEntityExist(p.entity) then DeleteObject(p.entity) end
                                    if p.blip then RemoveBlip(p.blip) end
                                    table.remove(pallets, i)

                                    if #pallets == 0 then
                                        allLoaded = true
                                        lib.notify({ title = 'All Pallets Loaded!', description = 'Return the forklift to the red zone.', type = 'success' })
                                    else
                                        lib.notify({ title = 'Pallet Loaded', description = ('%d pallet(s) remaining — go get the next one.'):format(#pallets), type = 'success' })
                                    end
                                end
                            end
                            break
                        end
                    end
                end

                if not palletInZone then setTextUI('') end
            end
        end
    end)
end)

-- ── Drive to Restaurant Delivery ──────────────────────────────────────────────
RegisterNetEvent('warehouse:startDelivery')
AddEventHandler('warehouse:startDelivery', function(restaurantId, truck, orders, trailer, whIndex)
    lib.alertDialog({
        header   = 'On Your Way!',
        content  = 'Head to the delivery location.\nCheck your GPS — park the truck, then carry boxes inside.',
        centered = true,
        cancel   = true
    })

    local deliveryPosition = Config.Restaurants[restaurantId].delivery
    SetNewWaypoint(deliveryPosition.x, deliveryPosition.y)

    local blip = AddBlipForCoord(deliveryPosition.x, deliveryPosition.y, deliveryPosition.z)
    SetBlipSprite(blip, 1) SetBlipScale(blip, 1.0) SetBlipColour(blip, 3) SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName("STRING") AddTextComponentString("Delivery Location") EndTextCommandSetBlipName(blip)

    lib.notify({ title = 'Delivery Started', description = 'Drive to the restaurant and park.', type = 'success' })

    Citizen.CreateThread(function()
        local checkTimer = 0
        while true do
            Citizen.Wait(0)

            local truckPos     = GetEntityCoords(truck)
            local distToTarget = #(truckPos - vector3(deliveryPosition.x, deliveryPosition.y, deliveryPosition.z))

            DrawMarker(1,
                deliveryPosition.x, deliveryPosition.y, deliveryPosition.z - 1.0,
                0,0,0, 0,0,0, 4.0,4.0,1.0,
                distToTarget < 10.0 and 255 or 0,
                distToTarget < 10.0 and 0   or 255,
                0, 150,
                false,true,2,false,nil,nil,false)

            checkTimer = checkTimer + 1
            if checkTimer >= 30 then
                checkTimer = 0
                if distToTarget < 10.0 then
                    RemoveBlip(blip)
                    TriggerEvent('warehouse:deliverBoxes', restaurantId, truck, orders, trailer, whIndex)
                    return
                end
            end
        end
    end)
end)

-- ── Box Delivery on Foot ──────────────────────────────────────────────────────
RegisterNetEvent('warehouse:deliverBoxes')
AddEventHandler('warehouse:deliverBoxes', function(restaurantId, truck, orders, trailer, whIndex)
    -- Calculate boxes needed: 1 box per 20 units per item (min 1 box per item)
    local maxBoxes = 0
    if orders and #orders > 0 then
        for _, order in ipairs(orders) do
            maxBoxes = maxBoxes + math.max(1, math.ceil(order.quantity / 20))
        end
    else
        maxBoxes = Config.maxBoxes  -- fallback
    end

    lib.alertDialog({
        header   = 'Almost Done!',
        content  = ('Carry %d box(es) from the trailer inside.\nLook for the green delivery zone.'):format(maxBoxes),
        centered = true,
        cancel   = true
    })

    local playerPed          = PlayerPedId()
    local deliveryFootPos    = Config.Restaurants[restaurantId].deliveryFoot
    local trailerCoords      = GetEntityCoords(trailer)
    local trailerHeading     = GetEntityHeading(trailer)

    local trailerBackPos = vector3(
        trailerCoords.x - math.sin(math.rad(trailerHeading)) * 5.0,
        trailerCoords.y + math.cos(math.rad(trailerHeading)) * 5.0,
        trailerCoords.z - 1.0
    )

    local boxCount = 0
    local hasBox   = false
    local boxProp  = nil
    local palletProp = nil

    lib.notify({ title = 'Deliver Boxes', description = 'Pick up boxes from the trailer and carry them inside.', type = 'success' })

    Citizen.CreateThread(function()
        -- Spawn pallet at back of trailer
        local palletModel = GetHashKey('prop_boxpile_06b')
        RequestModel(palletModel)
        while not HasModelLoaded(palletModel) do Citizen.Wait(0) end
        palletProp = CreateObject(palletModel, trailerBackPos.x, trailerBackPos.y, trailerBackPos.z, true, true, true)
        PlaceObjectOnGroundProperly(palletProp)

        while true do
            Citizen.Wait(0)

            local playerCoords = GetEntityCoords(playerPed)

            -- Draw markers
            DrawMarker(1, trailerBackPos.x,    trailerBackPos.y,    trailerBackPos.z - 1.0,
                0,0,0, 0,0,0, 0.8,0.8,1.0, 255,0,0,100, false,true,2,false,nil,nil,false)
            DrawMarker(1, deliveryFootPos.x, deliveryFootPos.y, deliveryFootPos.z - 0.1,
                0,0,0, 0,0,0, 0.8,0.8,1.0, 0,255,0,100, false,true,2,false,nil,nil,false)

            -- ── Pickup zone ──────────────────────────────────────────────────
            if #(playerCoords - trailerBackPos) < 2.0 then
                if not hasBox then
                    lib.showTextUI('[E] Pick Up Box', { position = 'left-center' })
                end

                if IsControlJustReleased(0, 38) and not hasBox then
                    lib.hideTextUI()

                    local success = ProgressBar('Unloading Box...', 3000, 'mini@repair', 'fixing_a_ped', false)
                    if success then
                        local boxModel = GetHashKey(Config.CarryBoxProp)
                        RequestModel(boxModel)
                        while not HasModelLoaded(boxModel) do Citizen.Wait(0) end

                        local coords = GetEntityCoords(playerPed)
                        boxProp = CreateObject(boxModel, coords.x, coords.y, coords.z, true, true, true)
                        AttachEntityToEntity(boxProp, playerPed, GetPedBoneIndex(playerPed, 60309),
                            0.1, 0.2, 0.25, -90.0, 0.0, 0.0, true, true, false, true, 1, true)
                        hasBox = true

                        local animDict = "anim@heists@box_carry@"
                        RequestAnimDict(animDict)
                        while not HasAnimDictLoaded(animDict) do Citizen.Wait(0) end
                        TaskPlayAnim(playerPed, animDict, "idle", 8.0, -8.0, -1, 50, 0, false, false, false)

                        lib.notify({ title = 'Box Picked Up', description = 'Walk to the delivery zone.', type = 'inform' })
                    end
                end
            elseif not hasBox then
                lib.hideTextUI()
            end

            -- ── Delivery zone ─────────────────────────────────────────────────
            if hasBox and #(playerCoords - deliveryFootPos) < 2.0 then
                lib.showTextUI('[E] Deliver Box')

                if IsControlJustReleased(0, 38) then
                    lib.hideTextUI()

                    local success = ProgressBar('Delivering Box...', 3000, 'mini@repair', 'fixing_a_ped', false)
                    if success then
                        if boxProp then DeleteObject(boxProp) boxProp = nil end
                        hasBox = false
                        ClearPedTasks(playerPed)
                        boxCount = boxCount + 1

                        if boxCount >= maxBoxes then
                            lib.notify({ title = 'All Boxes Delivered!', description = 'Return the truck to the warehouse.', type = 'success' })
                            if palletProp then DeleteObject(palletProp) palletProp = nil end
                            TriggerEvent('warehouse:returnTruck', truck, restaurantId, orders, whIndex)
                            return
                        else
                            lib.notify({
                                title       = 'Box Delivered',
                                description = ('%d / %d boxes done. Get the next one!'):format(boxCount, maxBoxes),
                                type        = 'success'
                            })
                        end
                    end
                end
            elseif hasBox then
                lib.hideTextUI()
            end
        end
    end)
end)

-- ── Return Truck to Warehouse ─────────────────────────────────────────────────
RegisterNetEvent('warehouse:returnTruck')
AddEventHandler('warehouse:returnTruck', function(truck, restaurantId, orders, whIndex)
    lib.alertDialog({
        header   = 'Almost Done!',
        content  = 'Drive the truck back to the warehouse.\nCheck your GPS for directions.',
        centered = true,
        cancel   = true
    })

    local wh             = Config.Warehouses[whIndex or 1]
    local playerPed      = PlayerPedId()
    local returnPosition = vector3(wh.truck.position.x, wh.truck.position.y, wh.truck.position.z)

    SetNewWaypoint(returnPosition.x, returnPosition.y)

    local blip = AddBlipForCoord(returnPosition.x, returnPosition.y, returnPosition.z)
    SetBlipSprite(blip, 1) SetBlipScale(blip, 1.0) SetBlipColour(blip, 3) SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName("STRING") AddTextComponentString("Truck Return Location") EndTextCommandSetBlipName(blip)

    Citizen.CreateThread(function()
        while true do
            Citizen.Wait(0)

            local playerPos = GetEntityCoords(playerPed)

            DrawMarker(1,
                returnPosition.x, returnPosition.y, returnPosition.z - 1.0,
                0,0,0, 0,0,0, 1.5,1.5,1.0, 0,255,255,100, false,true,2,false,nil,nil,false)

            if #(playerPos - returnPosition) < 2.0 and IsPedInVehicle(playerPed, truck, false) then
                lib.showTextUI('[E] Return Truck')

                if IsControlJustReleased(0, 38) then
                    lib.hideTextUI()

                    local success = ProgressBar('Returning Truck...', 3000,
                        'anim@scripted@heist@ig3_button_press@male@', 'button_press', false)

                    if success then
                        RemoveBlip(blip)
                        DeleteVehicle(truck)

                        -- Clear delivery tracking
                        activeDeliveryEntities.truck    = nil
                        activeDeliveryEntities.trailer  = nil
                        activeDeliveryEntities.forklift = nil
                        TriggerServerEvent('warehouse:clearDelivery')

                        lib.alertDialog({
                            header   = 'Job Complete!',
                            content  = 'Truck returned. Payment has been processed.',
                            centered = true,
                            cancel   = true
                        })

                        TriggerServerEvent('update:stock', restaurantId, orders)
                        return
                    end
                end
            else
                lib.hideTextUI()
            end
        end
    end)
end)
