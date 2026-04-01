# FS25 Mod: Used Equipment Yards

Allows you to define custom vehicle sale yards that you can visit and buy used equipment from.
Players draw yard boundaries in-game using the construction menu's fence drawing tool;
equipment spawns and despawns dynamically within those areas via TTL and hourly spawn rolls.

**Author:** Ozz
**GitHub:** https://github.com/sprkem/FS25_UsedEquipmentYards

## Architecture

| Class | File | Role |
|---|---|---|
| `UsedEquipmentYards` | `src/main.lua` | Mod entry point, console commands, save hook, client item registry, pending resolution loop |
| `YardManager` | `src/YardManager.lua` | Server-only singleton; manages all yards, save/load, hour-changed hook |
| `UsedEquipmentYard` | `src/UsedEquipmentYard.lua` | Data class: bounds (AABB + polygon + anchor), name, id, inventory |
| `YardInventory` | `src/YardInventory.lua` | Per-yard spawn/despawn/refresh; item list; scatter placement; TTL; test drive fines |
| `PlaceableUsedEquipmentYard` | `src/PlaceableUsedEquipmentYard.lua` | Custom specialization: links placeable fence to YardManager |
| `PriceTagRenderer` | `src/PriceTagRenderer.lua` | Replaces vehicle license plates with "For Sale" price plates |
| `BarterState` | `src/BarterState.lua` | Per-farm per-yard daily barter chance tracking (all clients) |
| `YardConfigActivatable` | `src/YardConfigActivatable.lua` | "Configure Yard" prompt when inside yard bounds |
| `YardVehicleActivatable` | `src/YardVehicleActivatable.lua` | "Barter: [name]" prompt near yard vehicles |
| `YardConfigDialog` | `src/gui/YardConfigDialog.lua` | Config dialog: quality, dirtiness, category weights, brand weights |
| `BarterDialog` | `src/gui/BarterDialog.lua` | Barter dialog: vehicle info, specs, offer/buy/test-drive |

### Events

| Event | File | Direction | Purpose |
|---|---|---|---|
| `YardCreatedEvent` | `src/events/YardCreatedEvent.lua` | Server → Clients | Yard creation with polygon data |
| `YardRemovedEvent` | `src/events/YardRemovedEvent.lua` | Server → Clients | Yard deletion |
| `EquipmentPurchasedEvent` | `src/events/EquipmentPurchasedEvent.lua` | Client → Server → Broadcast | Purchase: deduct funds, transfer ownership, restore plate |
| `TestDriveEvent` | `src/events/TestDriveEvent.lua` | Client → Server → Broadcast | Start/return test drives |
| `VehicleItemSyncEvent` | `src/events/VehicleItemSyncEvent.lua` | Server → Clients | Sync item data (price, testDrive state, etc.) per vehicle |
| `InitialClientStateEvent` | `src/events/InitialClientStateEvent.lua` | Server → Joining Client | Full state: yards, barter state, all vehicle items |

### Multiplayer Architecture

- **Server-authoritative**: `YardManager`, `YardInventory`, vehicle spawning, purchases, test drives all run on server.
- **Client-side registry**: Remote clients receive lightweight item data via `VehicleItemSyncEvent` (broadcast after each spawn and in `InitialClientStateEvent`).
- **Deferred vehicle resolution**: During initial client state, vehicle network objects may not be resolved yet. Items are stored in `UsedEquipmentYards.pendingClientItems` and resolved in the `update(dt)` loop via `NetworkUtil.getObject(objectId)`. **Never send node objects in initial client state** — always send the object ID as an int and resolve later.
- **Client item registry**: `UsedEquipmentYards.clientItems[yardId][itemIndex]` stores item data on remote clients. `UsedEquipmentYards.clientVehicleActivatables[vehicle]` tracks activatables.
- **Event pattern**: Follow RedTape style — `local _mt`, `emptyNew()` passes `_mt` to `Event.new`, `run()` checks `connection:getIsServer()` (false = we are the server receiving from client), broadcasts a NEW event (not `self`).
- **SP broadcast**: `g_server:broadcastEvent()` does NOT loop back to the local client in SP. Do all server+client work in the server branch.

### Placement flow

1. Player opens construction menu → selects "Used Equipment Yard" (sheds category)
2. Player positions the building (electrical box i3d with collision for sell detection)
3. Husbandry brush asks "Customize fence?" → player draws fence boundary (rocks as posts)
4. `getCanCreateMeadow` triggers yard creation (fires in both Yes/No paths)
5. First fence vertex stored as `bounds.anchorX/anchorZ` — vehicles face away from it

### Placeable type definition

```xml
<type name="usedEquipmentYard" parent="placeable" className="Placeable"
      filename="$dataS/scripts/placeables/Placeable.lua">
    <specialization name="placement" />
    <specialization name="husbandryFence" />
    <specialization name="usedEquipmentYard" />
</type>
```

- Using `parent="placeable"` with explicit `className`/`filename` avoids the error where
  the engine tries to `source()` the parent's script relative to the mod directory.
- `parent="simplePlaceable"` causes `Can't load resource .../dataS/scripts/placeables/Placeable.lua`
  because `TypeManager:addType` calls `source(filename, customEnvironment)` with the inherited
  parent filename, and the engine resolves it relative to the mod first.
- The `placement` specialization MUST be included — it provides `startPlacementCheck` and other
  methods that `ConstructionBrushPlaceable` calls. Without it: `attempt to call missing method 'startPlacementCheck'`.

### Selling/demolishing the yard

- The construction mode sell brush uses **raycasting** against collision geometry.
- The building i3d (`box.i3d`) has a collision shape (`static="true"` with collision masks).
- `getOwnerFarmId`/`setOwnerFarmId` pass through to `superFunc` so the placing farm owns it.
- `getIsOnOwnedFarmland` returns `true` so selling works on unowned land.
- Clicking the electrical box in construction mode shows the sell option.
- Fence posts (rocks) resolve to the Fence object, not the placeable.

## Console Commands (dev mode only — `g_addCheatCommands`)

| Command | Description |
|---|---|
| `ueyListYards` | List all yards with bounds and item counts |
| `ueyRemoveYard <id>` | Delete a yard by id |
| `ueyResetInventory [id\|all]` | Reset inventory for one yard or all |

## Save File

Saved to `<savegameDirectory>/UsedEquipmentYards.xml` on each autosave/manual save.
Contains: yard definitions, inventory items (with TTL, numOwners, minPrice, testDrive state,
testDrivenByFarms), config (quality, dirtiness, categories, brands), and barter state.

## FS25 Conventions

This project follows FS25 modding conventions.
See `~/.claude/skills/fs25-modding/SKILL.md` for the full reference.

## Lessons Learned (FS25 engine behaviour)

### Placeable type with husbandry fence
- Our type uses `parent="placeable"` + `placement` + `PlaceableHusbandryFence` specializations.
- The husbandry brush (`ConstructionBrushHusbandry`) is set via `<brush><type>husbandry</type>`
  in the placeable XML. Without this, the fence customization dialog never appears.
- The fence template (`xml/YardFence.xml`) MUST be registered as a `<storeItem>` with
  `showInStore="true"` and a `<brush><type>newFence</type>` section.

### Fence customization timing
- `onPostFinalizePlacement` fires BEFORE the "Customize fence?" dialog. Do NOT create the
  yard or spawn vehicles there.
- `getCanCreateMeadow` is called by the brush in BOTH "Yes" and "No" paths. We use it as
  the trigger to create the yard. Return `false` (no meadow dialog).

### Navigation mesh stubs
- `PlaceableHusbandryFence` calls `deleteNavigationMeshPlacementCollision`,
  `createNavigationMeshPlacementCollision`, and `createNavigationMeshFromContour`.
  Register no-op stubs for these.

### Bypassing farmland ownership for fence posts
- Placeable overrides (`getIsOnOwnedFarmland`, `getIsOnFarmland`) only affect building placement.
- The fence brush has TWO separate land checks patched in `main.lua`:
  1. `ConstructionBrush:verifyAccess` — `canFarmAccessLand` check
  2. `ConstructionBrushNewFence:validateCurrentSegment` — `getIsOwnedByFarmAlongLine`
- Both patched via `Utils.overwrittenFunction`, guarded by `isYardFenceBrush()`.

### Vehicle spawn layout
- **Random scatter placement**: positions sampled within fence polygon's inset AABB,
  validated with point-in-polygon and radius-aware clearance checks.
- `VehicleLoadingData:setPosition(x, nil, z, terrainOffset)` / `setRotation` / `setIgnoreShopOffset(true)`
- Vehicle yaw: `math.atan2(dx, dz) + math.pi` (faces away from anchor point) ± 15° jitter.
- Sequential spawning; 50 attempts per vehicle; 8 consecutive failures = yard full.
- Test-driven vehicles' original positions are reserved in `rebuildPlacedPositions`.

### Vehicle spawning API
- `VehicleLoadingData.new()`, `:setStoreItem()`, `:setConfigurations()`,
  `:setPosition()`, `:setRotation()`, `:setIgnoreShopOffset(true)`,
  `:setPropertyState()`, `:setOwnerFarmId()`, `:load(callback, target, args)`.
- Callback: `function(loadedVehicles, loadState, args)`, check `VehicleLoadingState.OK`.
- Used look: `vehicle:addWearAmount()`, `vehicle:setDamageAmount()`, `vehicle:setOperatingTime(ms)`.

### License plate system
- `setLicensePlatesData(nil)` hides plates (sets visibility false, does NOT delete nodes).
- `setLicensePlatesData(data)` requires ALL fields: `variation`, `characters`, `colorIndex`, `placementIndex`.
  If ANY is nil, goes into hide-all branch.
- `getRandomLicensePlateData()` may return `placementIndex = NONE (0)` on some maps.
  Must override with vehicle's own `getLicensePlateDialogSettings()` return value, falling
  back to `PLACEMENT_OPTION.BOTH`. This is what the shop does.
- `updateData(variationIndex, position, characters)` advances string position for ALL
  non-static values including locked ones. Locked values use their fixed character but
  still consume a position. Pad the input string accordingly.
- Characters with `"_"` are hidden by the rendering system.
- Custom plates in `xml/licensePlatesSale.xml` and `i3d/licensePlates/` — two types
  (ELONGATED and SQUARISH) selected per vehicle mount's `preferedType`.

### Time tracking
- `g_messageCenter:subscribe(MessageType.HOUR_CHANGED, callback)` for hourly ticks.
- `g_messageCenter:subscribe(MessageType.DAY_CHANGED, callback)` for daily resets.
- `g_currentMission.environment.currentHour`, `.currentDay`, `.currentMonotonicDay`.
- Period: `.currentPeriod` (0–11), period 0 = March.

### Currency
- `g_i18n:getCurrencySymbol(true)` returns short symbol (€, £, $).
- `g_i18n.moneyUnit` stores `GS_MONEY_EURO`, `GS_MONEY_POUND`, or dollar (default).
- License plate fonts do NOT include £/$€ glyphs. Currency on plates requires baked
  textures or 3D geometry, not font rendering.

### GUI
- `fs25_settingsMultiTextOption` profile has bottom anchor — create `ueyMultiTextOption`
  extending it with `anchorTopLeft` for absolute positioning in custom dialogs.
- `ScrollingLayout` with `flowDirection="vertical"` clips and scrolls overflow content.
  Height must be smaller than total content height to trigger scrolling.
- Dynamic rows: define a hidden template in XML, clone it per entry in Lua via
  `template:clone()`. Access children by index (`row.elements[1]`, `row.elements[2]`).
  `getDescendantById` does NOT work on cloned elements.
- `GuiUtils.getNormalizedScreenValues({w, h})` takes a TABLE, returns a table. Use
  `unpack()` to pass to `setSize()`.
- `g_shopController:makeDisplayItem(storeItem, vehicle, configurations)` returns
  `{ attributeIconProfiles, attributeValues }`. Size each element:
  `element:setSize(textElement.size[1] + iconElement.size[1] + 0.0025, textElement.size[2])`.

### Store categories and brands
- `g_storeManager.categoryByName` — `{ name, title, image, type, orderId }` per category.
- `g_brandManager.indexToBrand[i]` — `{ name, title, image, index }` per brand.
- Store items: `si.categoryNames` (table of strings), `si.brandIndex` (int).

### Vehicle teleportation
- `vehicle:setAbsolutePosition(x, y, z, rx, ry, rz)` — for clean repositioning, bracket
  with `vehicle:removeFromPhysics()` before and `vehicle:addToPhysics()` after.

### Network / multiplayer
- `NetworkUtil.getObjectId(object)` returns an int ID. `NetworkUtil.getObject(id)` resolves it.
- **Never use `NetworkUtil.writeNodeObject` in initial client state** — the vehicle may not
  be resolved yet on the client. Write the object ID as an int, store as pending, resolve
  in the `update()` loop via `NetworkUtil.getObject()`.
- `FSBaseMission.sendInitialClientState` — append via `Utils.appendedFunction`. Called once
  per connecting client with `(self, connection, user, farm)`.
