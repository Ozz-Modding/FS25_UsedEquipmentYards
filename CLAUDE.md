# FS25 Mod: Used Equipment Yards

Allows you to define custom vehicle sale yards that you can visit and buy used equipment from.
Players draw yard boundaries in-game using the construction menu's fence drawing tool;
equipment spawns and despawns dynamically within those areas on a per-period basis.

**Author:** Ozz
**GitHub:** https://github.com/sprkem/FS25_UsedEquipmentYards

## Architecture

| Class | File | Role |
|---|---|---|
| `UsedEquipmentYards` | `src/main.lua` | Mod entry point, console commands, save hook |
| `YardManager` | `src/YardManager.lua` | Server-only singleton; manages all yards, save/load |
| `UsedEquipmentYard` | `src/UsedEquipmentYard.lua` | Data class: bounds, name, id, inventory reference |
| `YardInventory` | `src/YardInventory.lua` | Per-yard spawn/despawn/refresh; item list |
| `PlaceableUsedEquipmentYard` | `src/PlaceableUsedEquipmentYard.lua` | Custom specialization: links placeable fence to YardManager |
| `YardCreatedEvent` | `src/events/YardCreatedEvent.lua` | Server -> clients on yard creation |
| `YardRemovedEvent` | `src/events/YardRemovedEvent.lua` | Server -> clients on yard deletion |
| `EquipmentPurchasedEvent` | `src/events/EquipmentPurchasedEvent.lua` | Client -> server purchase request; server broadcasts result |

### Placement flow

1. Player opens construction menu → selects "Used Equipment Yard" (landscaping > misc)
2. Player draws fence segments to define the yard boundary (standard newFence brush)
3. On finalization, `PlaceableUsedEquipmentYard:onPostFinalizePlacement` calculates
   the bounding box from the fence segment endpoints and creates a yard in `YardManager`
4. The placeable stores its `yardId`; on sell/demolish, the yard is removed

The placeable type `usedEquipmentYard` inherits from `newFence` (via `parent` in modDesc)
so it gets all standard fence behaviour. `newFence` already overrides `getIsOnFarmland`
to return `false`, so yards can be placed on any land regardless of ownership.

Server-authoritative: `YardManager` only exists on the server. State changes are propagated
to clients via network events.

## Console Commands (dev mode only — `g_addCheatCommands`)

| Command | Description |
|---|---|
| `ueyListYards` | List all yards with bounds and item counts |
| `ueyRemoveYard <id>` | Delete a yard by id |
| `ueyResetInventory [id\|all]` | Reset inventory for one yard or all |

## Key TODOs

### Verify FS25 APIs (before writing any implementation)
- **Money deduction** (`EquipmentPurchasedEvent:run`) — confirm the `g_farmManager` API for removing funds from a farm.
- **Vehicle loading/ownership** (`EquipmentPurchasedEvent:run`) — confirm `VehicleLoadingUtil.loadVehicle()` signature and how to assign ownership to a farm.

### Implement once APIs are verified
- **`YardInventory:generateItems()`** — vehicle pool config (e.g. `data/vehiclePool.xml`) and random selection.
- **`YardInventory:spawnItemNode()`** — place a vehicle node at a random position within the yard bounds.
- **`EquipmentPurchasedEvent:run()`** — deduct funds and transfer vehicle ownership.
- **Client-side yard registry** — `YardCreatedEvent` / `YardRemovedEvent` run stubs; implement once client needs are known.

## Save File

Saved to `<savegameDirectory>/UsedEquipmentYards.xml` on each autosave/manual save.
Contains all yard definitions and current inventory state.

## FS25 Conventions

This project follows FS25 modding conventions.
See `~/.claude/skills/fs25-modding/SKILL.md` for the full reference.

## Lessons Learned (FS25 engine behaviour)

### Placeable type with husbandry fence
- Our type uses `parent="simplePlaceable"` + `PlaceableHusbandryFence` specialization
  to get the cow-barn-style "place building then draw fence" flow.
- The husbandry brush (`ConstructionBrushHusbandry`) is set via `<brush><type>husbandry</type>`
  in the placeable XML. Without this, the fence customization dialog never appears.
- The fence template (`xml/YardFence.xml`) MUST be registered as a `<storeItem>` with
  `showInStore="true"` and a `<brush><type>newFence</type>` section. The husbandry brush
  looks up the fence's store item to create the `ConstructionBrushNewFence`. If `showInStore`
  is false, the brush data is nil and placement crashes.

### Fence customization timing
- `onPostFinalizePlacement` fires BEFORE the "Customize fence?" dialog. Do NOT create the
  yard or spawn vehicles there.
- `finishFenceCustomization` only fires if the player says "Yes" to customization.
- `getCanCreateMeadow` is called by the brush in BOTH "Yes" and "No" paths (from
  `onCustomizableFenceFinished`). We register this function and use it as our trigger
  to create the yard at exactly the right moment. Return `false` (no meadow dialog).

### Navigation mesh stubs
- `PlaceableHusbandryFence` calls `deleteNavigationMeshPlacementCollision`,
  `createNavigationMeshPlacementCollision`, and `createNavigationMeshFromContour` which
  come from husbandry specializations we don't include. Register no-op stubs for these.

### Bypassing farmland ownership for fence posts
- Our placeable overrides (`getIsOnOwnedFarmland`, `getIsOnFarmland`, `getOwnerFarmId`)
  only affect the initial building placement.
- The fence customization brush has TWO separate land checks that must be patched:
  1. `ConstructionBrush:verifyAccess` (parent class, line 85) — calls
     `g_currentMission.accessHandler:canFarmAccessLand`. Runs every frame in update.
  2. `ConstructionBrushNewFence:validateCurrentSegment` — calls
     `g_farmlandManager:getIsOwnedByFarmAlongLine`. Runs on segment validation.
- Both are patched in `main.lua` via `Utils.overwrittenFunction`, guarded by
  `isYardFenceBrush()` check so normal fences are unaffected.

### Default fence (preview square)
- The default fence is created in `createDefaultFence` override using `localToWorld`
  offsets from the root node. This ensures the preview moves with the placement cursor.
- `updateHusbandryFence` override recalculates corner positions each frame to keep
  preview segments aligned with the building position.
- Offsets are "in front of" placement point: `{-h, 0}, {h, 0}, {h, 2h}, {-h, 2h}`
  so the yard extends forward, not centred on the click point.

### Vehicle spawn layout
- Uses **random scatter placement**: positions are sampled randomly within the fence
  polygon's inset AABB, validated with point-in-polygon containment and radius-aware
  clearance checks against all existing vehicles.
- `VehicleLoadingData:setPosition` / `setRotation` / `setIgnoreShopOffset(true)` are
  used for direct world-space placement (no `setLoadingPlace` row system).
- Vehicle clearance = `max(width, length)/2 + VEHICLE_CLEARANCE_BUFFER (3m)`.
  Size comes from `StoreItemUtil.getSizeValues` for the specific vehicle + config.
- Yaw is a random cardinal direction (N/E/S/W) ± 30° jitter for an organic look.
- Vehicles spawn sequentially (one at a time); each callback triggers the next.
  If a vehicle can't find a position after 50 attempts, a different (potentially
  smaller) vehicle is tried. After n consecutive failures the yard is declared full.

### Vehicle spawning API
- `VehicleLoadingData.new()`, `:setStoreItem()`, `:setConfigurations()`,
  `:setLoadingPlace(places, usedPlaces)`, `:setPropertyState()`, `:setOwnerFarmId()`,
  `:load(callback, target, args)`.
- Callback signature: `function(loadedVehicles, loadState, args)`.
- `VehicleLoadingState.OK` indicates success.
- Used look: `vehicle:addWearAmount(0.1–0.4)`, `vehicle:setOperatingTime(ms)`.
- Random yaw jitter via `setRotation(rootNode, rx, ry + offset, rz)` for organic look.

### Period (month) tracking
- `g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, callback)` for monthly refresh.
- `g_currentMission.environment.currentPeriod` (0–11), `.currentYear`.
- Period 0 = March. Calendar month = `(period + 2) % 12 + 1`.
