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
