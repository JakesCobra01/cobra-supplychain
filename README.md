# 🐍 cobra_supplychain
### Made by Cobra Development

A comprehensive **Supply Chain & Restaurant Management** script for QBCore FiveM servers. This resource connects farmers, warehouse workers, and restaurant staff into a fully player-driven economy — from growing produce to delivering ingredients and serving customers.

---

## 📦 Features

- **Farmer → Warehouse selling** — Players sell farmed produce to the warehouse NPC, stocking the global warehouse inventory
- **Restaurant ordering system** — Restaurant staff use an in-game ordering computer to place ingredient orders from the warehouse, charged to the society account
- **Cart-based ordering** — Add multiple items to a cart before submitting, with live total cost and box count estimates
- **Warehouse worker flow** — Workers view pending orders, accept batches, load pallets with a forklift, drive a truck + trailer to the restaurant, and carry boxes inside on foot
- **Partial fulfillment** — If a warehouse is short on stock for an item, available items are delivered and the rest is backordered automatically
- **Restaurant cooking stations** — Staff use configured prep stations to craft food/drink items using stock, with animated progress bars synced to nearby players
- **Restaurant stash system** — Order trays and storage shelves registered via qs-inventory, accessible via qb-target
- **Clock-in / Clock-out** — Staff use a dedicated zone to toggle on/off duty
- **Stock management** — View, withdraw, or contribute stock directly from the ordering computer
- **jim-payments integration** — Cash registers use jim-payments for player billing
- **Society banking** — Orders are charged from and refunded to the job's society account (supports Renewed-Banking, qb-banking, fd_banking, okokBanking)
- **Driver pay** — Delivery drivers are automatically paid a configurable percentage of the order value on successful delivery
- **Disconnect protection** — If a driver disconnects mid-delivery, warehouse stock is refunded and orders are reset to pending
- **Blips** — Warehouse, business, and fruit buyer blips automatically added to the map

---

## 🔧 Dependencies

| Resource | Required |
|---|---|
| `qb-core` | ✅ Yes |
| `ox_lib` | ✅ Yes |
| `oxmysql` | ✅ Yes |
| `qb-target` | ✅ Yes |
| `qs-inventory` / `qb-inventory` | ✅ Yes |
| `jim-payments` | ✅ Yes |
| One of: `Renewed-Banking`, `qb-banking`, `fd_banking`, `okokBanking` | ✅ Yes (at least one) |

---

## 🗃️ Database Setup

Run the included SQL file **once** on your database before starting the resource:

```
run_me.sql
```

This creates three tables:

- `orders` — Tracks individual ingredient orders with status, batch grouping, and cost
- `stock` — Per-restaurant ingredient stock levels
- `warehouse_stock` — Global warehouse inventory fed by farmer sales

---

## 📁 File Structure

```
cobra_supplychain/
├── fxmanifest.lua
├── run_me.sql
├── configs/
│   ├── config_resturant.lua      # Business zones, registers, trays, chairs, cook stations
│   └── config_warehouse.lua      # Warehouse locations, truck/trailer, items, farmer NPC
├── client/
│   ├── cl_processing.lua         # Warehouse delivery flow (truck, forklift, box carry)
│   └── cl_resturant.lua          # Restaurant UI, cooking, clock-in, selling
└── server/
    ├── sv_processing.lua         # Order logic, banking, stock deduction, driver pay
    └── sv_resturant.lua          # Crafting, stash registration, anim sync
```

---

## ⚙️ Configuration

### `config_warehouse.lua`

```lua
Config.Core      = 'qbcore'    -- Framework
Config.Inventory = 'qb'        -- Inventory system
Config.Target    = 'qb'        -- Target system
Config.Notify    = 'ox'        -- ox_lib notifications
Config.Menu      = 'ox'        -- ox_lib context menus

Config.UsingVFishing = true    -- Set true if using v-Farming

Config.DriverPayPrec = 2.0     -- Driver pay as % of order total
Config.maxBoxes      = 3       -- Boxes to carry on foot delivery
Config.CarryBoxProp  = 'ng_proc_box_01a'
Config.InventoryMaxSlots = 41  -- Match your qs-inventory slot count
```

**Adding a new restaurant location:**
```lua
Config.Restaurants = {
    [1] = {
        name         = "Tequi-la-la",
        job          = "tequila",           -- QBCore job name
        position     = vector3(...),        -- Ordering computer position
        delivery     = vector3(...),        -- Truck parks here
        deliveryFoot = vector3(...),        -- Player walks boxes here
        heading      = 90.0
    },
}
```

**Adding orderable items per restaurant:**
```lua
Config.Items = {
    ["tequila"] = {
        ["water_bottle"] = { name = "Water Bottle", price = 10 },
        ["rum"]          = { name = "Rum",           price = 10 },
        -- add more items here
    },
}
```

**Adding farmable/sellable items:**
```lua
Config.ItemsFarming = {
    ['orange'] = { label = 'Orange', price = 4 },
    -- add more here
}
```

---

### `config_resturant.lua`

Defines per-business zones. Each entry under `Businesses.Businesses` is keyed by the QBCore job name.

**Key sections per business:**

| Section | Purpose |
|---|---|
| `clockin` | Box zone for toggling on/off duty |
| `registers` | Cash register interaction zones (jim-payments) |
| `trays` | Stash zones for order trays |
| `storage` | Stash shelf zones with slot/weight config |
| `CookLoco` | Cooking/prep station zones with recipe items |
| `chairs` | Seating zones for customers |
| `blip` | Map blip sprite, color, scale |

**Adding a cooking recipe:**
```lua
CookLoco = {
    {
        coords      = vector4(...),
        targetLabel = "Prepare Drinks",
        dimensions  = { width = 1.5, length = 0.6, height = 0.5 },
        items = {
            {
                item          = "water_bottle",
                amount        = 1,
                time          = 8000,           -- ms
                progressLabel = "Mixing Drink...",
                progressAnim  = { dict = "...", name = "..." },
                requiredItems = {
                    { item = "water_bottle", amount = 1 }
                },
                icon = "fas fa-cocktail"
            },
        }
    },
},
```

---

## 🚀 Installation

1. Copy the `cobra_supplychain` folder into your server's `resources` directory
2. Run `run_me.sql` on your database
3. Add `ensure cobra_supplychain` to your `server.cfg`
4. Configure `config_warehouse.lua` and `config_resturant.lua` to match your server's jobs, locations, and items
5. Ensure all items listed in `Config.Items` and `Config.ItemsFarming` exist in your `qb-inventory` items file
6. Restart the server

---

## 🔄 Player Workflows

### 🌾 Farmer
1. Farm produce using your farming script
2. Travel to the **Fruit Buyer NPC** (marked on the map)
3. Sell items directly — stock is added to the warehouse automatically

### 🏭 Warehouse Worker
1. Approach the **Warehouse NPC** and open the menu
2. View pending restaurant orders and accept a batch
3. Spawn a truck + trailer, back it into the loading zone
4. Use the **forklift** to move pallets into the green zone
5. Return the forklift, then drive the truck to the restaurant
6. Carry boxes on foot into the delivery zone
7. Return the truck to the warehouse to receive pay

### 🍽️ Restaurant Staff
1. Clock in at the **clock-in zone**
2. Use the **ordering computer** to browse and cart ingredients
3. Submit the order — cost is deducted from the society account
4. Monitor orders via *View My Outstanding Orders* (cancel if still pending)
5. Use **cook stations** to craft items from restaurant stock
6. Use **cash registers** (jim-payments) to charge customers

---

## 💡 Notes

- Warehouse delivery slots are locked while a driver is loading — other workers are queued and notified when the slot is free
- Orders reset to `pending` automatically if a driver disconnects or the resource restarts
- Warehouse stock is safely refunded in all failure scenarios
- Cooking animations are synced to nearby players via a server relay
- The farming sell NPC is separate from the warehouse NPCs and can be placed anywhere on the map

---

*cobra_supplychain — Cobra Development*
