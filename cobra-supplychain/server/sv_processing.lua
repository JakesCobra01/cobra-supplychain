local QBCore = exports['qb-core']:GetCoreObject()

-- ── Warehouse state lock ──────────────────────────────────────────────────────
-- States per warehouse index: "idle" | "loading" | "loaded"
local warehouseState = {}
for i = 1, #(Config and Config.Warehouses or {}) do
    warehouseState[i] = "idle"
end

-- Players waiting for a warehouse slot, keyed by whIndex → { [src] = true }
local waitingPlayers  = {}
-- Active deliveries keyed by player source
-- { batchId, orderIds[], restaurantId, whIndex, stockDeducted{} }
local activeDeliveries = {}

-- ── Banking helpers (module-level, not re-defined per call) ───────────────────
local function resourceRunning(name) return GetResourceState(name) == 'started' end

local function getBankingScript()
    if resourceRunning("Renewed-Banking") then return "Renewed-Banking"
    elseif resourceRunning("qb-banking")  then return "qb-banking"
    elseif resourceRunning("fd_banking")  then return "fd_banking"
    elseif resourceRunning("okokBanking") then return "okokBanking"
    end
    return nil
end

local function getSocietyBalance(script, job)
    if script == "Renewed-Banking" then return exports["Renewed-Banking"]:getAccountMoney(job) or 0
    elseif script == "qb-banking"  then return exports["qb-banking"]:GetAccountBalance(job)   or 0
    elseif script == "fd_banking"  then return exports["fd_banking"]:GetAccount(job)           or 0
    elseif script == "okokBanking" then return exports["okokBanking"]:GetAccount(job)          or 0
    end
    return 0
end

local function removeSocietyMoney(script, job, amount, reason)
    if script == "Renewed-Banking" then exports["Renewed-Banking"]:removeAccountMoney(job, amount)
    elseif script == "qb-banking"  then exports["qb-banking"]:RemoveMoney(job, amount, reason or "")
    elseif script == "fd_banking"  then exports["fd_banking"]:RemoveMoney(job, amount)
    elseif script == "okokBanking" then exports["okokBanking"]:RemoveMoney(job, amount)
    end
end

local function addSocietyMoney(script, job, amount, reason)
    if script == "Renewed-Banking" then exports["Renewed-Banking"]:addAccountMoney(job, amount)
    elseif script == "qb-banking"  then exports["qb-banking"]:AddMoney(job, amount, reason or "")
    elseif script == "fd_banking"  then exports["fd_banking"]:AddMoney(job, amount)
    elseif script == "okokBanking" then exports["okokBanking"]:AddMoney(job, amount)
    end
end

-- ── Notification helper ───────────────────────────────────────────────────────
local function Notify(src, title, description, ntype, duration)
    TriggerClientEvent('ox_lib:notify', src, {
        title       = title,
        description = description,
        type        = ntype    or 'inform',
        duration    = duration or 5000,
    })
end

-- ── Warehouse free notification helper ───────────────────────────────────────
local function flushWaitingPlayers(whIndex)
    if not waitingPlayers[whIndex] then return end
    for src in pairs(waitingPlayers[whIndex]) do
        TriggerClientEvent('warehouse:onStateChange', src, whIndex, "loaded")
    end
    waitingPlayers[whIndex] = {}
end

-- ── Truck loaded: deduct warehouse stock for all accepted orders in batch ─────
RegisterNetEvent('warehouse:truckLoaded', function(whIndex)
    local src      = source
    if warehouseState[whIndex] ~= "loading" then return end

    local delivery = activeDeliveries[src]
    if not delivery or not delivery.orderIds or #delivery.orderIds == 0 then return end

    local ph = string.rep('?,', #delivery.orderIds):sub(1, -2)
    MySQL.fetch(
        ('SELECT ingredient, quantity FROM orders WHERE id IN (%s) AND status = "accepted"'):format(ph),
        delivery.orderIds,
        function(results)
            if not results or #results == 0 then
                print('[cobra-supplychain] truckLoaded: no accepted orders found for batch.')
                return
            end

            -- Aggregate per ingredient (handles multiple rows of same ingredient)
            local deductions = {}
            for _, order in ipairs(results) do
                local ing = order.ingredient:lower()
                deductions[ing] = (deductions[ing] or 0) + (tonumber(order.quantity) or 0)
            end

            local queries = {}
            for ing, qty in pairs(deductions) do
                table.insert(queries, {
                    query  = 'UPDATE warehouse_stock SET quantity = quantity - ? WHERE ingredient = ? AND quantity >= ?',
                    values = { qty, ing, qty },
                })
            end

            MySQL.transaction(queries, function(ok)
                if not ok then
                    print('[cobra-supplychain] WARNING: Failed to deduct warehouse stock on truckLoaded.')
                    return
                end
                delivery.stockDeducted  = deductions
                warehouseState[whIndex] = "loaded"
                print(('[cobra-supplychain] Warehouse %d unlocked — %d ingredient(s) deducted.'):format(whIndex, #results))
                flushWaitingPlayers(whIndex)
            end)
        end
    )
end)

-- ── Clear delivery on successful truck return ─────────────────────────────────
RegisterNetEvent('warehouse:clearDelivery', function()
    local src      = source
    local delivery = activeDeliveries[src]
    if delivery and delivery.whIndex then
        warehouseState[delivery.whIndex] = "idle"
    end
    activeDeliveries[src] = nil
    for wi in pairs(waitingPlayers) do waitingPlayers[wi][src] = nil end
end)

-- ── Player disconnect mid-delivery ───────────────────────────────────────────
AddEventHandler('playerDropped', function(reason)
    local src      = source
    local delivery = activeDeliveries[src]
    if not delivery then return end

    -- Unlock warehouse if we were the active loader
    if delivery.whIndex and warehouseState[delivery.whIndex] == "loading" then
        warehouseState[delivery.whIndex] = "idle"
        flushWaitingPlayers(delivery.whIndex)
    end

    activeDeliveries[src] = nil
    for wi in pairs(waitingPlayers) do waitingPlayers[wi][src] = nil end

    -- Refund warehouse stock if truck had already left with goods
    if delivery.stockDeducted then
        for ing, qty in pairs(delivery.stockDeducted) do
            MySQL.execute('UPDATE warehouse_stock SET quantity = quantity + ? WHERE ingredient = ?', { qty, ing })
        end
        print(('[cobra-supplychain] Player %d dropped — warehouse stock refunded.'):format(src))
    end

    -- Reset accepted orders back to pending so another driver can pick them up
    if delivery.orderIds and #delivery.orderIds > 0 then
        local ph = string.rep('?,', #delivery.orderIds):sub(1, -2)
        MySQL.execute(
            ('UPDATE orders SET status = "pending" WHERE id IN (%s) AND status = "accepted"'):format(ph),
            delivery.orderIds,
            function(res)
                local n = type(res) == 'table' and (res.affectedRows or 0) or (res or 0)
                if n > 0 then
                    print(('[cobra-supplychain] Player %d dropped (%s) — reset %d order(s) to pending.'):format(src, reason, n))
                end
            end
        )
    end
end)

-- ── Restaurant: Place a batch order ──────────────────────────────────────────
-- cartItems = { { ingredient, quantity }, ... }
RegisterNetEvent('restaurant:orderBatch', function(cartItems, restaurantId)
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return Notify(src, 'Error', 'Player not found.', 'error') end
    if not cartItems or #cartItems == 0 then return Notify(src, 'Order Error', 'Cart is empty.', 'error') end

    local rJob = Config.Restaurants[restaurantId] and Config.Restaurants[restaurantId].job
    if not rJob then return Notify(src, 'Order Error', 'Invalid restaurant.', 'error') end

    -- Validate items and total cost
    local validated = {}
    local totalCost = 0
    for _, entry in ipairs(cartItems) do
        local qty      = tonumber(entry.quantity)
        local itemData = Config.Items[rJob] and Config.Items[rJob][entry.ingredient]
        if not qty or qty < 1 then
            return Notify(src, 'Order Error', ('Invalid quantity for %s.'):format(entry.ingredient), 'error')
        end
        if not itemData then
            return Notify(src, 'Order Error', ('Item not found: %s'):format(entry.ingredient), 'error')
        end
        local cost = itemData.price * qty
        totalCost  = totalCost + cost
        table.insert(validated, { ingredient = entry.ingredient, quantity = qty, cost = cost })
    end

    -- Check society funds
    local bankScript = getBankingScript()
    if not bankScript then return Notify(src, 'Error', 'No compatible banking script found.', 'error') end

    local balance = getSocietyBalance(bankScript, rJob)
    if balance < totalCost then
        return Notify(src, 'Insufficient Funds',
            ('Society account needs $%d but only has $%d.'):format(totalCost, balance), 'error')
    end

    removeSocietyMoney(bankScript, rJob, totalCost, "Restaurant ingredient order")

    -- Generate batch ID
    local batchId = ('%08x-%04x-%04x'):format(
        math.random(0, 0xffffffff), math.random(0, 0xffff), math.random(0, 0xffff))

    local queries = {}
    for _, v in ipairs(validated) do
        table.insert(queries, {
            query  = 'INSERT INTO orders (owner_id, ingredient, quantity, status, restaurant_id, total_cost, batch_id) VALUES (?, ?, ?, "pending", ?, ?, ?)',
            values = { src, v.ingredient, v.quantity, restaurantId, v.cost, batchId },
        })
    end

    MySQL.transaction(queries, function(ok)
        if ok then
            local boxes = 0
            for _, v in ipairs(validated) do boxes = boxes + math.max(1, math.ceil(v.quantity / 20)) end
            Notify(src, 'Order Submitted',
                ('%d item(s) ordered for $%d  |  ~%d box(es).'):format(#validated, totalCost, boxes), 'success')
        else
            -- Refund on DB failure
            addSocietyMoney(bankScript, rJob, totalCost, "Order refund - DB error")
            Notify(src, 'Order Error', 'Database error. Society account refunded.', 'error')
        end
    end)
end)

-- ── Restaurant: Outstanding orders (restaurant manager view) ─────────────────
RegisterNetEvent('restaurant:getOutstandingOrders', function(restaurantId)
    local src = source
    -- ORDER BY id only — batch_id column existence is guaranteed by the schema,
    -- but ordering by id is equally correct and avoids any migration edge cases.
    MySQL.fetch(
        'SELECT * FROM orders WHERE restaurant_id = ? AND status IN ("pending","accepted") ORDER BY id',
        { restaurantId },
        function(results)
            if not results or #results == 0 then
                TriggerClientEvent('restaurant:showOutstandingOrders', src, {}, restaurantId)
                return
            end

            local rJob = Config.Restaurants[restaurantId] and Config.Restaurants[restaurantId].job
            local batchMap, batchOrder = {}, {}

            for _, row in ipairs(results) do
                local bid      = row.batch_id or tostring(row.id)
                local qty      = tonumber(row.quantity)  or 0
                local cost     = tonumber(row.total_cost) or 0
                local itemData = rJob and Config.Items[rJob] and Config.Items[rJob][row.ingredient:lower()]
                local name     = itemData and itemData.name or row.ingredient

                if not batchMap[bid] then
                    batchMap[bid] = { batchId = bid, status = row.status, items = {}, totalCost = 0, totalBoxes = 0 }
                    table.insert(batchOrder, bid)
                end
                table.insert(batchMap[bid].items, { name = name, quantity = qty })
                batchMap[bid].totalCost  = batchMap[bid].totalCost  + cost
                batchMap[bid].totalBoxes = batchMap[bid].totalBoxes + math.max(1, math.ceil(qty / 20))
                if row.status == 'accepted' then batchMap[bid].status = 'accepted' end
            end

            local batches = {}
            for _, bid in ipairs(batchOrder) do table.insert(batches, batchMap[bid]) end
            TriggerClientEvent('restaurant:showOutstandingOrders', src, batches, restaurantId)
        end
    )
end)

-- ── Restaurant: Cancel a pending batch (refunds society) ─────────────────────
RegisterNetEvent('restaurant:cancelBatch', function(batchId, restaurantId)
    local src = source
    if not QBCore.Functions.GetPlayer(src) then return Notify(src, 'Error', 'Player not found.', 'error') end

    local rJob = Config.Restaurants[restaurantId] and Config.Restaurants[restaurantId].job
    if not rJob then return Notify(src, 'Error', 'Invalid restaurant.', 'error') end

    MySQL.fetch('SELECT id, total_cost, status FROM orders WHERE batch_id = ?', { batchId }, function(rows)
        if not rows or #rows == 0 then return Notify(src, 'Error', 'Batch not found.', 'error') end

        local totalRefund, pendingIds = 0, {}
        for _, row in ipairs(rows) do
            if row.status == 'accepted' then
                return Notify(src, 'Cannot Cancel', 'This order is already being delivered.', 'error')
            end
            totalRefund = totalRefund + (tonumber(row.total_cost) or 0)
            table.insert(pendingIds, row.id)
        end
        if #pendingIds == 0 then return Notify(src, 'Nothing to Cancel', 'No pending items in this batch.', 'inform') end

        local ph = string.rep('?,', #pendingIds):sub(1, -2)
        MySQL.execute(('DELETE FROM orders WHERE id IN (%s)'):format(ph), pendingIds, function(res)
            local deleted = type(res) == 'table' and (res.affectedRows or 0) or (res or 0)
            if deleted == 0 then return Notify(src, 'Error', 'Could not cancel order. Try again.', 'error') end

            if totalRefund > 0 then
                local bankScript = getBankingScript()
                if bankScript then addSocietyMoney(bankScript, rJob, totalRefund, "Order cancelled - refund") end
            end
            Notify(src, 'Order Cancelled',
                ('$%d refunded to %s society account.'):format(totalRefund, rJob), 'success')
        end)
    end)
end)

-- ── Delivery complete: update restaurant stock ────────────────────────────────
RegisterNetEvent('update:stock', function(restaurantId, orders)
    local src = source
    if not restaurantId then return Notify(src, 'Error', 'Invalid restaurant ID.', 'error') end

    local delivery = activeDeliveries[src]
    local orderIds = delivery and delivery.orderIds

    -- Fallback: rebuild from orders list the client passed
    if not orderIds or #orderIds == 0 then
        if orders and #orders > 0 then
            orderIds = {}
            for _, o in ipairs(orders) do if o.id then table.insert(orderIds, o.id) end end
        end
    end
    if not orderIds or #orderIds == 0 then
        return Notify(src, 'No Orders', 'No accepted orders found for this delivery.', 'inform')
    end

    local ph = string.rep('?,', #orderIds):sub(1, -2)
    MySQL.fetch(('SELECT * FROM orders WHERE id IN (%s) AND status = "accepted"'):format(ph), orderIds,
        function(dbOrders)
            if not dbOrders or #dbOrders == 0 then
                return Notify(src, 'No Orders', 'No accepted orders found.', 'inform')
            end

            local totalCost, queries = 0, {}
            for _, order in ipairs(dbOrders) do
                local ing = order.ingredient:lower()
                local qty = tonumber(order.quantity)
                if ing and qty then
                    totalCost = totalCost + (tonumber(order.total_cost) or 0)
                    table.insert(queries, {
                        query  = 'UPDATE orders SET status = "completed" WHERE id = ?',
                        values = { order.id },
                    })
                    table.insert(queries, {
                        query  = 'INSERT INTO stock (restaurant_id, ingredient, quantity) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE quantity = quantity + ?',
                        values = { restaurantId, ing, qty, qty },
                    })
                end
            end

            MySQL.transaction(queries, function(ok)
                if ok then
                    if activeDeliveries[src] then activeDeliveries[src].stockDeducted = nil end
                    Notify(src, 'Delivery Complete', ('Stock updated for %d item(s)!'):format(#dbOrders), 'success')
                    TriggerEvent('pay:driver', src, math.floor(totalCost * Config.DriverPayPrec))
                else
                    Notify(src, 'Error', 'Failed to update stock. Contact an admin.', 'error')
                end
            end)
        end
    )
end)

-- ── Pay driver ────────────────────────────────────────────────────────────────
RegisterNetEvent('pay:driver', function(driverId, amount)
    local player = QBCore.Functions.GetPlayer(driverId)
    if not player then return end
    player.Functions.AddMoney('bank', amount, "Delivery driver payment")
    Notify(driverId, 'Payment Received', ('You earned $%d for your delivery!'):format(amount), 'success')
end)

-- ── Warehouse: Get pending orders grouped into batches ────────────────────────
RegisterNetEvent('warehouse:getPendingOrders', function(whIndex)
    local src = source
    MySQL.fetch('SELECT * FROM orders WHERE status = "pending" ORDER BY id', {}, function(results)
        if not results then return Notify(src, 'Error', 'Could not retrieve orders.', 'error') end

        local batchMap, batchOrder, staleIds = {}, {}, {}

        for _, order in ipairs(results) do
            local rData = Config.Restaurants[order.restaurant_id]
            local rJob  = rData and rData.job
            if rJob and Config.Items[rJob] then
                local itemKey  = order.ingredient:lower()
                local itemData = Config.Items[rJob][itemKey]
                if itemData then
                    local bid = order.batch_id or tostring(order.id)
                    if not batchMap[bid] then
                        batchMap[bid] = {
                            batchId = bid, restaurantId = order.restaurant_id,
                            items = {}, orderIds = {}, totalCost = 0, totalBoxes = 0,
                        }
                        table.insert(batchOrder, bid)
                    end
                    local qty  = tonumber(order.quantity) or 0
                    local cost = tonumber(order.total_cost) or (itemData.price * qty)
                    table.insert(batchMap[bid].items,    { id = order.id, ingredient = itemKey, name = itemData.name, quantity = qty, cost = cost })
                    table.insert(batchMap[bid].orderIds, order.id)
                    batchMap[bid].totalCost  = batchMap[bid].totalCost  + cost
                    batchMap[bid].totalBoxes = batchMap[bid].totalBoxes + math.max(1, math.ceil(qty / 20))
                else
                    table.insert(staleIds, order.id)
                    print(('[cobra-supplychain] Purging stale order #%d: item "%s" not in config.'):format(order.id, order.ingredient))
                end
            end
        end

        -- Bulk-delete stale orders in one query
        if #staleIds > 0 then
            local ph = string.rep('?,', #staleIds):sub(1, -2)
            MySQL.execute(('DELETE FROM orders WHERE id IN (%s)'):format(ph), staleIds)
        end

        local batches = {}
        for _, bid in ipairs(batchOrder) do table.insert(batches, batchMap[bid]) end
        TriggerClientEvent('warehouse:showOrderDetails', src, batches, whIndex)
    end)
end)

-- ── Restaurant: Current stock levels ─────────────────────────────────────────
RegisterNetEvent('restaurant:requestStock', function(restaurantId)
    local src = source
    MySQL.fetch('SELECT * FROM stock WHERE restaurant_id = ?', { restaurantId }, function(results)
        local stock, zeroIds = {}, {}
        for _, item in ipairs(results or {}) do
            if (item.quantity or 0) <= 0 then
                table.insert(zeroIds, item.id)
            else
                stock[item.ingredient] = item.quantity
            end
        end
        -- Clean up empty rows in one batch query
        if #zeroIds > 0 then
            local ph = string.rep('?,', #zeroIds):sub(1, -2)
            MySQL.execute(('DELETE FROM stock WHERE id IN (%s)'):format(ph), zeroIds)
        end
        TriggerClientEvent('restaurant:showResturantStock', src, stock, restaurantId)
    end)
end)

-- ── Warehouse: Warehouse stock levels ────────────────────────────────────────
RegisterNetEvent('warehouse:getStocks', function()
    local src = source
    MySQL.fetch('SELECT ingredient, quantity FROM warehouse_stock', {}, function(results)
        local stock = {}
        for _, item in ipairs(results or {}) do stock[item.ingredient] = item.quantity end
        TriggerClientEvent('restaurant:showStockDetails', src, stock)
    end)
end)

-- ── Restaurant: Items player can contribute from their inventory ──────────────
RegisterNetEvent('restaurant:getContributableItems', function(restaurantId)
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return end

    local rJob     = Config.Restaurants[restaurantId] and Config.Restaurants[restaurantId].job
    local cfgItems = rJob and Config.Items[rJob]
    if not cfgItems then return Notify(src, 'Error', 'No items configured for this restaurant.', 'error') end

    local contributable = {}
    for ingredient, itemData in pairs(cfgItems) do
        local inv = player.Functions.GetItemByName(ingredient)
        if inv and (inv.amount or 0) > 0 then
            table.insert(contributable, { ingredient = ingredient, displayName = itemData.name, inInventory = inv.amount })
        end
    end
    table.sort(contributable, function(a, b) return a.displayName < b.displayName end)
    TriggerClientEvent('restaurant:showContributeMenu', src, contributable, restaurantId)
end)

-- ── Restaurant: Contribute stock from player inventory ───────────────────────
RegisterNetEvent('restaurant:contributeStock', function(restaurantId, ingredient, amount)
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return end

    ingredient      = ingredient:match("^%s*(.-)%s*$")
    local amountNum = tonumber(amount)
    if not amountNum or amountNum < 1 then return Notify(src, 'Error', 'Invalid amount.', 'error') end

    local rJob     = Config.Restaurants[restaurantId] and Config.Restaurants[restaurantId].job
    local itemData = rJob and Config.Items[rJob] and Config.Items[rJob][ingredient]
    if not itemData then return Notify(src, 'Error', 'That item is not used by this restaurant.', 'error') end

    local inv = player.Functions.GetItemByName(ingredient)
    if not inv or (inv.amount or 0) < amountNum then
        return Notify(src, 'Not Enough Items', ('You only have %d %s.'):format(inv and inv.amount or 0, itemData.name), 'error')
    end

    if not player.Functions.RemoveItem(ingredient, amountNum) then
        return Notify(src, 'Error', 'Could not remove items from your inventory.', 'error')
    end

    MySQL.execute(
        'INSERT INTO stock (restaurant_id, ingredient, quantity) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE quantity = quantity + ?',
        { restaurantId, ingredient, amountNum, amountNum },
        function(result)
            if result then
                Notify(src, 'Stock Contributed', ('Added %dx %s to restaurant stock.'):format(amountNum, itemData.name), 'success')
            else
                player.Functions.AddItem(ingredient, amountNum)
                Notify(src, 'Error', 'Database error. Items returned.', 'error')
            end
        end
    )
end)

-- ── Restaurant: Withdraw stock into player inventory ─────────────────────────
-- DB is updated FIRST — item is only given if the update succeeds.
RegisterNetEvent('restaurant:withdrawStock', function(restaurantId, ingredient, amount)
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return Notify(src, 'Error', 'Player not found.', 'error') end

    ingredient      = ingredient:match("^%s*(.-)%s*$")
    local amountNum = tonumber(amount)
    if not amountNum or amountNum <= 0 then return Notify(src, 'Error', 'Invalid withdrawal amount.', 'error') end

    local rJob     = Config.Restaurants[restaurantId] and Config.Restaurants[restaurantId].job
    local itemData = rJob and Config.Items[rJob] and Config.Items[rJob][ingredient]
    if not itemData then return Notify(src, 'Error', ('Item not found: %s'):format(ingredient), 'error') end

    -- Deduct from DB first — only give item if DB confirms the row was updated.
    -- The AND quantity >= ? guard prevents negative stock.
    MySQL.execute(
        'UPDATE stock SET quantity = quantity - ? WHERE restaurant_id = ? AND ingredient = ? AND quantity >= ?',
        { amountNum, restaurantId, ingredient, amountNum },
        function(res)
            local changed = type(res) == 'table' and (res.affectedRows or 0) or (res or 0)
            if changed > 0 then
                player.Functions.AddItem(ingredient, amountNum)
                Notify(src, 'Stock Withdrawn', ('Withdrew %dx %s.'):format(amountNum, itemData.name), 'success')
            else
                Notify(src, 'Not Enough Stock', 'The restaurant does not have that much in stock.', 'error')
            end
        end
    )
end)

-- ── Warehouse: Accept batch (partial fulfillment supported) ──────────────────
RegisterNetEvent('warehouse:acceptBatch', function(batchId, restaurantId, whIndex)
    local workerId = source
    local idx      = whIndex or 1

    if warehouseState[idx] == "loading" then
        if not waitingPlayers[idx] then waitingPlayers[idx] = {} end
        waitingPlayers[idx][workerId] = true
        return Notify(workerId, 'Warehouse Busy', 'Another driver is loading. You will be notified when free.', 'error')
    end

    MySQL.fetch('SELECT * FROM orders WHERE batch_id = ? AND status = "pending"', { batchId }, function(batchRows)
        if not batchRows or #batchRows == 0 then
            return Notify(workerId, 'Error', 'Batch not found or already accepted.', 'error')
        end

        local rJob = Config.Restaurants[restaurantId] and Config.Restaurants[restaurantId].job
        if not rJob then return Notify(workerId, 'Error', 'Invalid restaurant.', 'error') end

        -- Fetch warehouse stock for all ingredients in one query
        local ings = {}
        for _, row in ipairs(batchRows) do table.insert(ings, row.ingredient:lower()) end
        local ph = string.rep('?,', #ings):sub(1, -2)

        MySQL.fetch(('SELECT ingredient, quantity FROM warehouse_stock WHERE ingredient IN (%s)'):format(ph), ings,
            function(stockRows)
                local whStock = {}
                for _, s in ipairs(stockRows or {}) do whStock[s.ingredient] = s.quantity end

                local toAccept, toBackorder = {}, {}
                for _, row in ipairs(batchRows) do
                    local ing      = row.ingredient:lower()
                    local qty      = tonumber(row.quantity) or 0
                    local avail    = whStock[ing] or 0
                    local itemData = Config.Items[rJob] and Config.Items[rJob][ing]
                    local cost     = tonumber(row.total_cost) or (itemData and itemData.price * qty or 0)
                    if avail >= qty then
                        table.insert(toAccept,    { id = row.id, ingredient = ing, quantity = qty, cost = cost })
                    else
                        table.insert(toBackorder, { id = row.id, ingredient = ing, quantity = qty, cost = cost, available = avail })
                    end
                end

                if #toAccept == 0 then
                    return Notify(workerId, 'No Stock', 'None of the ordered items have sufficient warehouse stock.', 'error')
                end

                warehouseState[idx] = "loading"

                local acceptedOrders, queries = {}, {}
                for _, item in ipairs(toAccept) do
                    local itemData = Config.Items[rJob] and Config.Items[rJob][item.ingredient]
                    table.insert(acceptedOrders, {
                        id = item.id, ingredient = item.ingredient,
                        itemName = itemData and itemData.name or item.ingredient,
                        quantity = item.quantity, totalCost = item.cost, restaurantId = restaurantId,
                    })
                    table.insert(queries, { query = 'UPDATE orders SET status = "accepted" WHERE id = ?', values = { item.id } })
                end

                -- Backorders: reassign to a new batch_id so they stay pending
                if #toBackorder > 0 then
                    local newBatch = ('%08x-%04x-%04x'):format(
                        math.random(0, 0xffffffff), math.random(0, 0xffff), math.random(0, 0xffff))
                    for _, item in ipairs(toBackorder) do
                        table.insert(queries, { query = 'UPDATE orders SET batch_id = ? WHERE id = ?', values = { newBatch, item.id } })
                    end
                end

                MySQL.transaction(queries, function(ok)
                    if not ok then
                        warehouseState[idx] = "idle"
                        return Notify(workerId, 'Error', 'Database error. Please try again.', 'error')
                    end

                    local orderIds = {}
                    for _, o in ipairs(acceptedOrders) do table.insert(orderIds, o.id) end
                    activeDeliveries[workerId] = {
                        batchId = batchId, orderIds = orderIds,
                        restaurantId = restaurantId, whIndex = idx, stockDeducted = nil,
                    }

                    if #toBackorder > 0 then
                        local names = {}
                        for _, item in ipairs(toBackorder) do
                            local d = Config.Items[rJob] and Config.Items[rJob][item.ingredient]
                            table.insert(names, ('%s (need %d, have %d)'):format(
                                d and d.name or item.ingredient, item.quantity, item.available))
                        end
                        Notify(workerId, 'Partial Delivery',
                            ('Delivering %d item(s). Backorder: %s'):format(#toAccept, table.concat(names, ', ')),
                            'inform', 8000)
                    else
                        Notify(workerId, 'Batch Accepted', ('Delivering %d item(s).'):format(#toAccept), 'success')
                    end

                    TriggerClientEvent('warehouse:spawnVehicles', workerId, restaurantId, acceptedOrders, idx)
                end)
            end
        )
    end)
end)

-- ── Warehouse: Deny batch ─────────────────────────────────────────────────────
RegisterNetEvent('warehouse:denyBatch', function(batchId)
    local src = source
    MySQL.execute('UPDATE orders SET status = "pending" WHERE batch_id = ? AND status = "pending"', { batchId },
        function(res)
            local n = type(res) == 'table' and (res.affectedRows or 0) or (res or 0)
            if n > 0 then Notify(src, 'Batch Denied',  'All items returned to pending.', 'inform')
            else          Notify(src, 'Error',          'Could not deny batch.',           'error') end
        end
    )
end)

-- ── Resource restart: refund warehouse stock and reset all accepted orders ────
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    MySQL.fetch('SELECT ingredient, quantity FROM orders WHERE status = "accepted"', {}, function(results)
        if results and #results > 0 then
            for _, order in ipairs(results) do
                local ing = order.ingredient:lower()
                local qty = tonumber(order.quantity)
                if ing and qty then
                    MySQL.execute('UPDATE warehouse_stock SET quantity = quantity + ? WHERE ingredient = ?', { qty, ing })
                end
            end
            print(('[cobra-supplychain] Refunded warehouse stock for %d accepted order(s) on restart.'):format(#results))
        end
        MySQL.execute('UPDATE orders SET status = "pending" WHERE status = "accepted"', {}, function(res)
            local n = type(res) == 'table' and (res.affectedRows or 0) or (res or 0)
            if n > 0 then print(('[cobra-supplychain] Reset %d accepted order(s) to pending on restart.'):format(n)) end
        end)
    end)
end)

-- ── Farming: Return only items the player currently has ──────────────────────
RegisterNetEvent('farming:getSellabeItems', function()
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return end

    local sellable = {}
    for fruit, finfo in pairs(Config.ItemsFarming) do
        local inv = player.Functions.GetItemByName(fruit)
        local qty = inv and (inv.amount or inv.count or 0) or 0
        if qty > 0 then
            table.insert(sellable, { fruit = fruit, label = finfo.label, price = finfo.price, amount = qty })
        end
    end
    table.sort(sellable, function(a, b) return a.label < b.label end)
    TriggerClientEvent('farming:showSellMenu', src, sellable)
end)

-- ── Farming: Sell fruit/produce to warehouse ──────────────────────────────────
RegisterNetEvent('farming:sellFruit', function(fruit, amount)
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return end

    local finfo = Config.ItemsFarming[fruit]
    if not finfo then return Notify(src, 'Invalid Item', ("'%s' is not a sellable item."):format(fruit), 'error') end

    amount = tonumber(amount)
    if not amount or amount < 1 then return Notify(src, 'Invalid Amount', 'Enter a valid amount.', 'error') end

    local inv  = player.Functions.GetItemByName(fruit)
    local have = inv and (inv.amount or inv.count or 0) or 0
    if have < amount then
        return Notify(src, 'Insufficient Items', ("You only have %dx %s."):format(have, finfo.label), 'error')
    end

    player.Functions.RemoveItem(fruit, amount)
    player.Functions.AddMoney('cash', amount * finfo.price, ("Sold %s"):format(fruit))

    -- Upsert into warehouse stock using UNIQUE KEY on ingredient
    MySQL.execute(
        'INSERT INTO warehouse_stock (ingredient, quantity) VALUES (?, ?) ON DUPLICATE KEY UPDATE quantity = quantity + ?',
        { fruit, amount, amount }
    )

    Notify(src, 'Items Sold', ('Sold %dx %s for $%d.'):format(amount, finfo.label, amount * finfo.price), 'success', 6000)
end)

if Config.UsingVFishing then
    -- Legacy alias so external v-fishing scripts that fire this event still work
    RegisterServerEvent('farming:sellFruit')
end
