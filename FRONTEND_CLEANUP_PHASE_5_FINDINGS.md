# Phase 5 Findings: Component Organization

**Date:** 2025-01-25
**Phase:** 5 of Frontend Cleanup
**Status:** Analysis Complete

## Executive Summary

The frontend codebase has 16 loose files at `frontend/src/components/` root (~2,212 LOC). After analysis, I recommend:
- **Create 1 new folder** `Layout/` for 9 app chrome components
- **Move 1 file** to existing `Modal/` folder
- **Keep 5 files at root** (framework-level concerns with wide usage)
- Net result: Root reduces from 16 → 6 files (index.ts + 5 components)

---

## 1. Root-Level Inventory

| File | LOC | Purpose | Import Count | Proposed Location |
|------|-----|---------|--------------|-------------------|
| ReaperProvider.tsx | 46 | Context provider for REAPER connection | **55+** | **Keep at root** |
| ErrorBoundary.tsx | 69 | React error boundary wrapper | 4 | **Keep at root** |
| ViewLayout.tsx | 81 | Standard view layout wrapper | 8 | Layout/ |
| ViewHeader.tsx | 92 | View header with settings + connection | 8 | Layout/ |
| TabBar.tsx | 89 | Bottom tab navigation | 2 | Layout/ |
| SettingsMenu.tsx | 271 | Hamburger menu dropdown | 3 | Layout/ |
| OverflowMenu.tsx | 104 | Overflow menu (progressive disclosure) | 4 | Layout/ |
| ConnectionStatus.tsx | 214 | Network indicator + banner (2 exports) | 13 | **Keep at root** |
| NetworkStatsModal.tsx | 247 | Network stats modal (opened from ConnectionStatus) | 4 | Move with ConnectionStatus |
| PersistentTransport.tsx | 227 | Bottom transport bar | 10 | Layout/ (app chrome) |
| QuickActionsPanel.tsx | 276 | Quick actions bottom sheet | 2 | Layout/ (child of PersistentTransport) |
| MarkerNavigationPanel.tsx | 152 | Marker/region navigation panel | 2 | Layout/ (child of PersistentTransport) |
| ModalRoot.tsx | 87 | Centralized modal renderer | 4 | Modal/ |
| UpdateBanner.tsx | 35 | New version available banner | 3 | **Keep at root** |
| MemoryWarningBar.tsx | 163 | Memory usage warning banner | 3 | **Keep at root** |
| TextSizeControl.tsx | 60 | Font size +/- control | 3 | Layout/ (UI primitive) |
| index.ts | 24 | Barrel exports | N/A | Stays at root |

**Total: 16 files, ~2,212 LOC**

---

## 2. Existing Folder Structure

| Folder | File Count | Purpose |
|--------|------------|---------|
| Actions/ | 4 | Action buttons (TimeSignatureButton, UnselectAllTracks, etc.) |
| ContextRail/ | 4 | Context rail for side navigation (design in progress) |
| Instruments/ | 15 | Virtual instruments view components |
| Markers/ | 2 | Marker-related components (MarkerInfoBar) |
| Mixer/ | 21 | Mixer view components (strips, modals, FX browser) |
| Modal/ | 6 | Modal primitives (Modal, BottomSheet, etc.) |
| SecondaryPanel/ | 4 | Secondary panel components |
| SideRail/ | 2 | Side rail for navigation (design in progress) |
| Timeline/ | 29 | Timeline view components |
| Toast/ | 2 | Toast notification components |
| Toolbar/ | 9 | Toolbar and toolbar button components |
| Track/ | 13 | Track-level components (Fader, LevelMeter, etc.) |
| Transport/ | 5 | Transport controls (TransportBar, CircularTransportButton, etc.) |

**Total: 13 existing folders**

---

## 3. Proposed New Folders

### 3.1 Layout/ (NEW - 9 files, ~1,352 LOC)

**Purpose:** App chrome - the persistent UI shell around view content. Includes navigation, headers, and always-visible transport.

| File | LOC | Rationale |
|------|-----|-----------|
| ViewLayout.tsx | 81 | Standard layout wrapper used by all views |
| ViewHeader.tsx | 92 | View header component used by all views |
| TabBar.tsx | 89 | Bottom navigation tabs |
| SettingsMenu.tsx | 271 | Settings dropdown (child of ViewHeader) |
| OverflowMenu.tsx | 104 | Overflow menu (child of ViewHeader) |
| TextSizeControl.tsx | 60 | UI primitive currently only used by NotesView |
| PersistentTransport.tsx | 227 | Bottom transport bar - app chrome, not a transport feature component |
| QuickActionsPanel.tsx | 276 | Slide-up panel (child of PersistentTransport) |
| MarkerNavigationPanel.tsx | 152 | Slide-up panel (child of PersistentTransport) |

**Why group these:**
- ViewLayout, ViewHeader, TabBar, PersistentTransport form the app "shell"
- SettingsMenu and OverflowMenu are only used by ViewHeader
- QuickActionsPanel and MarkerNavigationPanel are only used by PersistentTransport
- All are app chrome, not feature components
- Note: `Transport/` folder contains reusable transport *primitives* (CircularTransportButton, RecordingActionsBar) - different concern

---

## 4. Files to Move to Existing Folders

### 4.1 Modal/ (add 1 file, ~87 LOC)

| File | LOC | Rationale |
|------|-----|-----------|
| ModalRoot.tsx | 87 | Centralized modal rendering - colocate with Modal primitives |

**Why move:**
- ModalRoot imports from `Modal/` (MarkerEditModal, etc.)
- Colocating it with other modal infrastructure makes sense

---

## 5. Files to Keep at Root

| File | LOC | Justification |
|------|-----|---------------|
| ReaperProvider.tsx | 46 | **55+ imports** - fundamental context used everywhere. Moving creates unwieldy imports. |
| ErrorBoundary.tsx | 69 | Framework-level error handling, used by App.tsx and main.tsx |
| ConnectionStatus.tsx | 214 | App-level network status, exported to App.tsx |
| NetworkStatsModal.tsx | 247 | Tightly coupled to ConnectionStatus (keep together) |
| UpdateBanner.tsx | 35 | App-level banner, simple and small |
| MemoryWarningBar.tsx | 163 | App-level banner, used by App.tsx |
| index.ts | 24 | Barrel export file |

**Root after cleanup: 6 files (~774 LOC)**
- Down from 16 files (~2,212 LOC)
- **10 files moved** (~1,438 LOC)

---

## 6. Import Impact Analysis

### High-Impact Files (most imports to update)

| File | Current Import Count | Files to Update |
|------|---------------------|-----------------|
| ReaperProvider.tsx | 55+ | **Keep at root** - too many imports |
| ViewLayout.tsx | 8 | All views (playlist, notes, actions, timeline, mixer, instruments, clock) |
| ViewHeader.tsx | 8 | All views |
| PersistentTransport.tsx | 10 | App.tsx, SideRail, hooks, store slices |

### Import Update Strategy

1. **Barrel exports handle it** - The main `components/index.ts` re-exports everything. As long as we update the barrel, most consumers won't need changes.

2. **Only direct imports need updating:**
   - PersistentTransport has direct imports from `./QuickActionsPanel` and `./MarkerNavigationPanel` - these become `./Transport/...`
   - ViewHeader has direct imports from `./SettingsMenu` and `./ConnectionStatus` - update to `./Layout/SettingsMenu`
   - ConnectionStatus has direct import from `./NetworkStatsModal` - stays together at root

---

## 7. Migration Plan

### Phase 5a: Create Layout/ folder

1. Create `frontend/src/components/Layout/`
2. Move files in order (lowest import count first):
   - TextSizeControl.tsx (3 imports)
   - TabBar.tsx (2 imports)
   - MarkerNavigationPanel.tsx (2 imports)
   - QuickActionsPanel.tsx (2 imports)
   - OverflowMenu.tsx (4 imports)
   - SettingsMenu.tsx (3 imports)
   - ViewLayout.tsx (8 imports)
   - ViewHeader.tsx (8 imports - update its imports to SettingsMenu)
   - PersistentTransport.tsx (10 imports - update its imports to QuickActionsPanel, MarkerNavigationPanel)
3. Create `Layout/index.ts` barrel export
4. Update `components/index.ts` to re-export from `Layout/`
5. Update direct imports in views (if any)

### Phase 5b: Move ModalRoot to Modal/

1. Move ModalRoot.tsx
2. Update `Modal/index.ts`
3. Update `components/index.ts`

---

## 8. Barrel Export Strategy

### New: Layout/index.ts
```typescript
export { ViewLayout, type ViewLayoutProps } from './ViewLayout';
export { ViewHeader, type ViewHeaderProps } from './ViewHeader';
export { TabBar, type TabBarProps } from './TabBar';
export { SettingsMenu, type SettingsMenuProps } from './SettingsMenu';
export { OverflowMenu, type OverflowMenuItem, type OverflowMenuProps } from './OverflowMenu';
export { TextSizeControl, type TextSizeControlProps } from './TextSizeControl';
export { PersistentTransport, type PersistentTransportProps } from './PersistentTransport';
export { QuickActionsPanel, type QuickActionsPanelProps } from './QuickActionsPanel';
export { MarkerNavigationPanel, type MarkerNavigationPanelProps } from './MarkerNavigationPanel';
```

### Update: Modal/index.ts
```typescript
// Add to existing exports:
export { ModalRoot } from './ModalRoot';
```

### Update: components/index.ts
```typescript
// Remove direct exports, add folder re-exports:
export * from './Layout';
// Transport, Modal already have export *
```

---

## 9. Open Questions

### 9.1 ConnectionStatus + NetworkStatsModal

**Question:** Should these move to a `Connection/` folder?

**Recommendation:** Keep at root for now.
- ConnectionStatus exports TWO components (ConnectionStatus, ConnectionBanner)
- Both are used directly by App.tsx
- NetworkStatsModal is only used by ConnectionStatus
- Creating a folder for 2 tightly-coupled files adds noise

### 9.2 TextSizeControl

**Question:** Is Layout/ the right home?

**Options:**
1. Layout/ - It's a UI primitive used in view headers (current recommendation)
2. New `UI/` or `Primitives/` folder - More accurate categorization
3. Keep at root - Only 60 LOC, single consumer

**Recommendation:** Move to Layout/ now. If we add more UI primitives later, extract to dedicated folder.

### 9.3 System Status Banners (UpdateBanner, MemoryWarningBar)

**Question:** Should these move to a `Status/` folder?

**Recommendation:** Keep at root.
- Both are app-level concerns imported only by App.tsx
- Small files (35 + 163 = 198 LOC)
- Creating a folder for 2 files that are only used in one place adds unnecessary indirection

---

## 10. Summary: Before vs After

### Before (Root-level)
```
components/
├── ConnectionStatus.tsx (214)
├── ErrorBoundary.tsx (69)
├── MarkerNavigationPanel.tsx (152)
├── MemoryWarningBar.tsx (163)
├── ModalRoot.tsx (87)
├── NetworkStatsModal.tsx (247)
├── OverflowMenu.tsx (104)
├── PersistentTransport.tsx (227)
├── QuickActionsPanel.tsx (276)
├── ReaperProvider.tsx (46)
├── SettingsMenu.tsx (271)
├── TabBar.tsx (89)
├── TextSizeControl.tsx (60)
├── UpdateBanner.tsx (35)
├── ViewHeader.tsx (92)
├── ViewLayout.tsx (81)
└── index.ts (24)
```
**16 files at root**

### After (Organized)
```
components/
├── Layout/                    (NEW - app chrome)
│   ├── ViewLayout.tsx
│   ├── ViewHeader.tsx
│   ├── TabBar.tsx
│   ├── SettingsMenu.tsx
│   ├── OverflowMenu.tsx
│   ├── TextSizeControl.tsx
│   ├── PersistentTransport.tsx
│   ├── QuickActionsPanel.tsx
│   ├── MarkerNavigationPanel.tsx
│   └── index.ts
├── Modal/                     (EXISTING - 1 file added)
│   ├── ...existing files...
│   └── ModalRoot.tsx
├── ConnectionStatus.tsx       (KEEP - app-level)
├── NetworkStatsModal.tsx      (KEEP - used by ConnectionStatus)
├── ErrorBoundary.tsx          (KEEP - framework-level)
├── ReaperProvider.tsx         (KEEP - 55+ imports)
├── UpdateBanner.tsx           (KEEP - app-level)
├── MemoryWarningBar.tsx       (KEEP - app-level)
└── index.ts
```
**6 files at root** (5 components + barrel export)

---

## Execution Ready

This plan is ready for user approval. Execution should follow the phased approach in Section 7.

**Estimated changes:**
- 10 files moved (9 to Layout/, 1 to Modal/)
- 1 new folder created (Layout/)
- 2 index.ts files updated (components/, Modal/)
- 1 new index.ts created (Layout/)
- ~3-5 files with direct import path updates (ViewHeader, PersistentTransport internal imports)
