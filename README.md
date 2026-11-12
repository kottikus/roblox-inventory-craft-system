# Roblox Server-Authoritative Inventory & Crafting System

A production-grade, highly secure, and modular inventory and crafting system for Roblox Studio. Built with a strict **Server-Authoritative** architecture, delta-compression networking, and a fully code-generated modern UI.

> **⚠️ Important Architectural Note:** This system serves as an **advanced architectural example and a structural guideline** for writing clean, secure game code. To integrate this into your own project, you must adapt it to match your game's specific loop, item databases, and data structures.

---

## Key Features

- **Server-Authoritative & Anti-Exploit:** 
  - The client has zero authority over inventory state. Every action (move, split, drop, craft) is fully validated on the server before mutating data.
  - Employs a cloning transaction pattern (`cloneSlots`) to ensure operations either fully succeed or roll back safely, preventing duplication glitches (dupe exploits).
- **Optimized Delta-Compression Network Sync:** 
  - Instead of replicating the entire inventory table on every change, the server checks slot differences (`sameSlot`) and pushes compact incremental updates (`UpdateSlot`) with revision numbers (`rev`) to minimize network overhead.
- **Token-Bucket Rate Limiting:** 
  - Built-in rate-limiting mechanism (`RATE`, `BURST`) on the server remote invocation to protect against request spamming and DDoS attempts from exploiters.
- **Modular Crafting & World Drops:** 
  - Dynamic recipe parsing with automated aggregated ingredient checks.
  - Physical world drops utilizing `ProximityPrompt` and server-side network ownership assignment (`SetNetworkOwner(nil)`) with automatic cleanup via `Debris`.
- **Procedural Responsive UI:** 
  - Fully code-generated user interface with proportional grid math (`UIAspectRatioConstraint`, `UIGridLayout`), split-stack support (Right-Click), and smooth drag-and-drop mechanics.

---

## System Architecture & Structure

- **`InventoryShared.lua` (ReplicatedStorage):** Static item database definitions, stack limits, and configuration constants.
- **`Recipes.lua` (ServerScriptService):** Crafting recipes registry with boot-time validation to catch bad item configurations early.
- **`InventoryService.lua` (ServerScriptService):** Core server logic handling DataStore persistence, token-bucket validation, safe transactions, and world interactions.
- **`InventoryClient.lua` (StarterPlayerScripts):** Pure view layer handling drag-and-drop, UI rendering, and server remote triggers.
- **`InventoryBootstrap.server.lua` (ServerScriptService):** Lightweight entry point initializing the service.

---

## Installation & Setup

1. Place the **`Inventory`** folder containing `InventoryShared` inside `ReplicatedStorage`.
2. Place **`Recipes`** and **`InventoryService`** inside a folder in `ServerScriptService`.
3. Place **`InventoryBootstrap`** in `ServerScriptService`.
4. Place **`InventoryClient`** as a `LocalScript` inside `StarterPlayerScripts`.
