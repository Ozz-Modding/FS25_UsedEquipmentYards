# FS25 Mod: Used Equipment Yards

Allows you to define custom vehicle sale yards that you can visit and buy used equipment from.
Players draw yard outlines in-game with the yard tool in the build menu (Buildings → Tools);
equipment is parked in rows within those areas and spawns/despawns via TTL and hourly spawn rolls.

**Author:** Ozz
**GitHub:** https://github.com/sprkem/FS25_UsedEquipmentYards

## Architecture

| Class | File | Role |
|---|---|---|
| `UsedEquipmentYards` | `src/main.lua` | Mod entry point, console commands, save hook, client item registry, pending resolution loop |
| `UeyUtils` | `src/UeyUtils.lua` | Defensive helpers (type checks, safe store-item spec loading) — used instead of `pcall`, which the mod does not use |
| `YardManager` | `src/YardManager.lua` | Server-only singleton; manages all yards, save/load, hour-changed hook |
| `UsedEquipmentYard` | `src/UsedEquipmentYard.lua` | Data class: bounds (AABB + polygon + anchor), name, id, inventory |
| `YardLayout` | `src/YardLayout.lua` | Pure geometry (no engine calls): rows/aisles inside a yard polygon, row depths from model sizes, slots. Unit tested |
| `YardZone` | `src/YardZone.lua` | Pure outline logic: polygon geometry, validation (`YardZone.validate`), and `YardZone.Editor` (draw / close / drag / insert / delete / undo). Unit tested |
| `UeyYardZoneBrush` | `src/brush/UeyYardZoneBrush.lua` | The yard tool in the build menu (a `ConstructionBrush`): input, Line3D/Marker3D drawing, live row preview, sends `YardZoneEvent`. Sourced by `addBrushType`, NOT in `extraSourceFiles` |
| `YardInventory` | `src/YardInventory.lua` | Per-yard spawn/despawn/refresh; item list; row placement via `YardLayout`; TTL; test drive fines |
| `PlaceableUsedEquipmentYard` | `src/PlaceableUsedEquipmentYard.lua` | LEGACY: the old box + fence placeable, kept only so old saves load; removed on load by `UsedEquipmentYards.removeLegacyPlaceables` (yard kept) |
| `PriceTagRenderer` | `src/PriceTagRenderer.lua` | Replaces vehicle license plates with "For Sale" price plates |
| `YardVisibility` | `src/YardVisibility.lua` | Client-local render culling of yard vehicles beyond a per-machine distance setting (modSettings XML) |
| `BarterState` | `src/BarterState.lua` | Per-farm per-yard daily barter chance tracking (all clients) |
| `YardConfigActivatable` | `src/YardConfigActivatable.lua` | "Configure Yard" prompt when inside yard bounds |
| `YardVehicleActivatable` | `src/YardVehicleActivatable.lua` | "Barter: [name]" prompt near yard vehicles |
| `YardConfigDialog` | `src/gui/YardConfigDialog.lua` | Config dialog: quality, dirtiness, category weights, brand weights |
| `YardConfigList` | `src/YardConfigList.lua` | Pure: equipment rows (the vehicle's configurations, shop filtering: no colours / single-option / dependent types; price + upgrade flag). Unit tested |
| `BarterDialog` | `src/gui/BarterDialog.lua` | Barter dialog: vehicle info, specs, equipment (configurations), offer/buy/test-drive |

### Events

| Event | File | Direction | Purpose |
|---|---|---|---|
| `YardCreatedEvent` | `src/events/YardCreatedEvent.lua` | Server → Clients | Yard creation with polygon data |
| `YardRemovedEvent` | `src/events/YardRemovedEvent.lua` | Server → Clients | Yard deletion |
| `YardUpdatedEvent` | `src/events/YardUpdatedEvent.lua` | Server → Clients | A yard's outline changed |
| `YardZoneEvent` | `src/events/YardZoneEvent.lua` | Client → Server | Yard tool request: create / update outline / delete. Server checks admin (`isConnectionAdmin`) and re-validates (`YardManager:applyZoneRequest`) |
| `EquipmentPurchasedEvent` | `src/events/EquipmentPurchasedEvent.lua` | Client → Server → Broadcast | Purchase: deduct funds, transfer ownership, restore plate |
| `TestDriveEvent` | `src/events/TestDriveEvent.lua` | Client → Server → Broadcast | Start/return test drives |
| `VehicleItemSyncEvent` | `src/events/VehicleItemSyncEvent.lua` | Server → Clients | Sync item data (price, testDrive state, etc.) per vehicle |
| `InitialClientStateEvent` | `src/events/InitialClientStateEvent.lua` | Server → Joining Client | Full state: yards, barter state, all vehicle items |

### Multiplayer Architecture

- **Server-authoritative**: `YardManager`, `YardInventory`, vehicle spawning, purchases, test drives all run on server.
- **Client-side registry**: Remote clients receive lightweight item data via `VehicleItemSyncEvent` (broadcast after each spawn and in `InitialClientStateEvent`).
- **Deferred vehicle resolution**: During initial client state, vehicle network objects may not be resolved yet. Items are stored in `UsedEquipmentYards.pendingClientItems` and resolved in the `update(dt)` loop via `NetworkUtil.getObject(objectId)`. **Never send node objects in initial client state** — always send the object ID as an int and resolve later.
- **Client item registry**: `UsedEquipmentYards.clientItems[yardId][vehicleObjectId]` stores item data on remote clients.
  All item-targeting events (purchase, test drive, hire purchase, item removed) identify the item by the
  vehicle's network object id — never by array index, which shifts on the server when items are removed.
  The server resolves it with `UsedEquipmentYards.findServerItem(yard, vehicleObjectId)`. `UsedEquipmentYards.clientVehicleActivatables[vehicle]` tracks activatables.
- **Event pattern**: Follow RedTape style — `local _mt`, `emptyNew()` passes `_mt` to `Event.new`, `run()` checks `connection:getIsServer()` (false = we are the server receiving from client), broadcasts a NEW event (not `self`).
- **SP broadcast**: `g_server:broadcastEvent()` does NOT loop back to the local client in SP. Do all server+client work in the server branch.

### The yard tool (placement flow)

Yards are not placeables any more. Two build-menu entries (Buildings → Tools) share one brush,
`UeyYardZoneBrush`, told apart by their brush parameter:

| Store item | Parameter | Does |
|---|---|---|
| `xml/YardZoneTool.xml` | `zone` | Draw a new yard; click an existing yard to reshape it |
| `xml/YardZoneRemoveTool.xml` | `remove` | Click a yard → confirm → removed (refused while sale zones link to it) |

- Drawing: left click adds corners (refused if too close or crossing the outline); clicking the first
  corner or right click closes it and creates the yard straight away (yards are free). An outline
  that isn't valid yet stays open to fix, then right click creates it. Editing (an existing yard, or
  that invalid one): drag a corner to move it, drag an edge to add a corner, middle click deletes the
  corner under the cursor, the fourth (undo) key undoes, right click applies, Esc discards. While closed the outline is validated and the rows are previewed live
  (`YardLayout` with the yard's config, or `DEFAULT_CONFIG` for a new yard) with area + vehicle count.
- The brush sends `YardZoneEvent` through `g_client:getServerConnection()` in every mode (SP too);
  the server re-checks admin and re-validates, then `createYard` / `updateYardPolygon` /
  `removeYard`. Reshaping calls `YardInventory:onBoundsChanged` (fresh layout; stock that no longer
  fits is cleared as if sold) and broadcasts `YardUpdatedEvent`.
- Only the host / admins can use it in MP (`UsedEquipmentYards.isAdminInMP`). Yards may be drawn on any
  land; they may not overlap each other.
- `bounds.anchorX/anchorZ` (first corner) is still written for stream/save compatibility but unused.

### Registering a custom construction brush (lessons)

- `g_constructionBrushTypeManager:addBrushType(typeName, className, absoluteFilename, modName)` from
  the mod's scripts at load time (main.lua file scope), before store items load. **In a mod's
  environment the manager is a wrapper (`mods.lua`) that prefixes both names with the mod name**, so
  the store XML must say `<type>FS25_UsedEquipmentYards.ueyYardZone</type>`; the class resolves as
  `_G["FS25_UsedEquipmentYards"].UeyYardZoneBrush`. The registry is reset on `unloadMapData`, so
  re-registering each savegame load is fine.
- `addBrushType` `source()`s the brush file itself — don't also list it in `extraSourceFiles`.
  Construction classes (`ConstructionBrush`, `Line3D`, `GuiTopDownCursor`) already exist then.
- The stock `ConstructionScreen` builds menu items from store items with a `brush` (category/tab) and
  passes `<parameters><parameter>` to `setParameters`. The store item must be a loadable placeable XML
  (`usedEquipmentYardTool` type: `placement` only) but is never placed.
- Input: `supportsPrimaryDragging` → `onButtonPrimary(isDown, isDrag, isUp)`; a gamepad/keyboard
  accept calls it with no arguments. Back/Esc calls `canCancel()` then `cancel()`. Button labels come
  from `getButton{Primary,Secondary,Tertiary,Fourth}Text` (nil hides) after `setInputTextDirty()`.
- `cursor:setMessage` / `setErrorMessage` render immediately — call them from `draw()`.
  `cursor:setTerrainOnly(true)` makes `getHitTerrainPosition` see through parked vehicles.
- `Line3D:visualizeLine(sx, sy, sz, ex, ey, ez, alignToTerrain, color)` (rounds to whole metres);
  `Marker3D` and `Line3D:setLineScale` are 1.25+ — guarded, with a cross fallback for handles.
- Decompiled construction sources: `../Reference/FS25_Lua/construction/` (rice field = polygon brush,
  `OrchardBoundaryEditor`), `../Reference/FS25_Lua/gui/ConstructionScreen.lua`, `mods.lua`.
- `UserManager:getIsConnectionMasterUser` never returns its result (base-game bug) — use
  `getUserByConnection(connection):getIsMasterUser()`.

### Old saves (legacy placeable)

- The old `usedEquipmentYard` placeable type (box + `husbandryFence`) and `xml/UsedEquipmentYard.xml` /
  `xml/YardFence.xml` stay registered but hidden (`showInStore=false`) so old saves load.
- 3 s after mission start the server deletes every such placeable with `keepYard = true`
  (`PlaceableUsedEquipmentYard:onDelete` then leaves the yard alone). The fence goes with it.
- Placeable type notes, if ever needed again: `parent="placeable"` with explicit
  `className`/`filename` (not `simplePlaceable`), and the `placement` spec is required.

## Tests

Unit tests live in `tests/`, in the same style as FS25_TheContractor. Run them with `test.bat`
(plain Lua 5.1 at `C:\Program Files (x86)\Lua\5.1\lua.exe`, or set `%LUA%`);
`test.bat tests\test_yardLayout.lua` runs one file. `package.bat` leaves `tests/` out of the zip.

- `tests/run.lua` — the runner. Each `tests/test_*.lua` file runs in its own process and stops at its
  first failure (no `pcall`, here too). A file is a list of `test("what it checks", function() ... end)`
  blocks using `assertEquals` / `assertNear` / `assertTrue`.
- `tests/stubs.lua` — fake FS25 globals. `stubs.install()` gives each test a fresh `world` with builders
  (`addStoreItem`, `addVehicle`, `obstacles`) and records (`moves`, `broadcasts`, `logs`), and
  `world:load("src/...")` loads the real source. Extend it when code under test needs another engine call.
  The stubs are our assumptions about the engine, not the engine: check them against
  `../Reference/FS25_Lua` (most complete) or `../Reference/gameSource`; in-game testing is still the real check.

**For all future development:** new logic gets tests in `tests/` and the whole suite is run before
reporting back. Put engine-free logic (geometry, maths, selection, parsing) in a pure module like
`YardLayout` so it can be tested directly; test engine-facing code through `stubs.lua`.
Tests are functional — assert state, keys and numbers, never player-facing text.

## Console Commands (dev mode only — `g_addCheatCommands`)

| Command | Description |
|---|---|
| `ueyListYards` | List all yards with bounds, item counts and row depths |
| `ueyRemoveYard <id>` | Delete a yard by id |
| `ueyResetInventory [id\|all]` | Reset inventory for one yard or all |

## Save File

Saved to `<savegameDirectory>/UsedEquipmentYards.xml` on each autosave/manual save.
Contains: yard definitions, inventory items (with TTL, numOwners, minPrice, testDrive state,
testDrivenByFarms, footprint position/size), config (quality, dirtiness, categories, brands,
aisleWidth), the row layout spec per yard (`inventory.layout`), and barter state.

## FS25 Conventions

This project follows FS25 modding conventions.
See `~/.claude/skills/fs25-modding/SKILL.md` for the full reference.

## Lessons Learned (FS25 engine behaviour)

### Husbandry fence (legacy placeable only)
- `PlaceableHusbandryFence` loads its fence from the XML path (not the store item), and needs no-op
  stubs for `deleteNavigationMeshPlacementCollision`, `createNavigationMeshPlacementCollision` and
  `createNavigationMeshFromContour` (still registered by the legacy spec).

### Vehicle spawn layout (rows)
- **Rows facing aisles** (`YardLayout`): the yard polygon is sliced into
  `row | aisle | row | back gap | row | aisle ...` along a row direction. Each candidate direction
  (every polygon edge and its perpendicular) is tried; the one with the most usable row length wins.
  Vehicles stand front-on to the aisle edge, a `lotGap` apart, filled from the start of each row.
- **Row depths come from the yard's models**: `YardInventory:getLayoutModels()` measures every
  store-pool entry (`StoreItemUtil.getSizeValues`, cached per xml in `YardInventory.sizeCache`) and
  `YardLayout.chooseBands` picks 1–3 depths (≥ 3 m apart) minimising wasted depth weighted by spawn
  weight × width. Rows are shared between depths by demand. Models no row can hold are excluded.
- **Slots**: a vehicle goes in the shallowest row that holds it (`findSlot`), sliding along when
  `overlapBox` (`isSlotClear`) finds something in the way. Spawning only rolls models that fit the
  free space right now (`freeSpace` / `fitsFreeSpace` as a pool filter).
- **Footprint vs root**: slots are footprint centres; the root goes at
  `YardLayout.rootFromCenter(footX, footZ, yaw, widthOffset, lengthOffset)`
  (offsets along the vehicle's local x and front, from `getSizeValues`).
- **Per item**: `slot = {row, u1, u2}`, `footX/footZ/spawnYaw`, `spawnWidth/Length`,
  `spawnWidthOffset/LengthOffset` (all but `slot` saved). Occupancy is derived from items
  (`getOccupied`); a slot is claimed (`assignSlot`) before the async load.
- **Rebuilds** (`ensureLayout`, server only): on load (`spawn`), after a config change (next
  `update` tick), on reset. A saved spec (`angle, vStart, rowDepths, aisleWidth`) is reused while
  the ideal depths stay within 1 m, so adding/removing a mod doesn't reshuffle a yard.
  `reconcileLayout` keeps vehicles that still sit in a row position, moves the rest (all out of
  physics first, then `setAbsolutePosition`, then back in), and evicts what doesn't fit: removed
  now if it stands where a moved vehicle goes, otherwise `ttlHours = 1` (gone at the next hour, as
  if sold). Test-driven vehicles get their return spot (`testDrive.orig*`) moved instead.
  During a repack, `overlapBox` ignores the vehicles being moved (`overlapIgnore` via
  `g_currentMission:getNodeObject`).
- `VehicleLoadingData:setPosition(x, nil, z, terrainOffset)` / `setRotation` / `setIgnoreShopOffset(true)`
- Config `aisleWidth` (dialog: 6–14 m) replaced the old `gridSpacing`.

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
- A `ScrollingLayout` with no profile is anchored bottom-left, so a negative `position` y is measured
  from the parent's bottom. Use `ueyScrollLayout` (top-left, transparent): `baseReference`-based
  profiles like `ueySection` draw a white background on a layout.
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
- `vehicle:setVisibility()` and `vehicle:removeFromPhysics()` are **local only** — never use them
  on the server to "hide" a vehicle in MP (clients keep seeing/entering it). Sold vehicles with no
  yard space are deleted and stored as data-only `pendingSoldItems`, re-spawned via
  `loadItemVehicle` when space opens (issue #33). Deletion/spawn sync natively.
- `FSBaseMission.sendInitialClientState` — append via `Utils.appendedFunction`. Called once
  per connecting client with `(self, connection, user, farm)`.
