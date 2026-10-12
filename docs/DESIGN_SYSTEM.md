# VoterLens — Design System Specification

## 1. Aesthetic Philosophy & Visual Identity

VoterLens adopts an **iOS-inspired, precision-engineered utility design system**. It prioritizes high information density, instant visual scannability, legibility of both Latin and Malayalam typography, and tactile operational clarity for field workers inspecting electoral rolls under outdoor and varying lighting conditions.

### Core Tenets:
1. **Utility First**: Clear borders, subtle drop shadows, and high contrast eliminate ambiguity.
2. **Harmonious Dark & Light Modes**: Tailored semantic surfaces (`surfaceLight`: `#FFFFFF`, `surfaceDark`: `#1C1C1E`) avoiding generic pitch blacks or oversaturated backgrounds.
3. **Restrained Color Language**: Color is reserved strictly for semantic state indications (field verification status, review flags, and primary interaction targets).
4. **Bilingual Typography Harmony**: English Latin text and Malayalam complex script characters render with uniform optical baseline alignment and proportional line heights.

---

## 2. Color Palette & Semantic Tokens

### Base & Surface Tokens

| Token | Light Mode Value | Dark Mode Value | Usage |
| :--- | :--- | :--- | :--- |
| `primary` | `#007AFF` | `#0A84FF` | Primary action buttons, active navigation, key highlights |
| `background` | `#F2F2F7` | `#000000` | Scaffold background |
| `surface` | `#FFFFFF` | `#1C1C1E` | Card containers, list items, dialog surfaces |
| `surfaceElevated` | `#F2F2F7` | `#2C2C2E` | Secondary containers, pills, inactive chips |
| `border` | `#E5E5EA` | `#38383A` | Card borders, search input outline |
| `divider` | `#E5E5EA` | `#2C2C2E` | Subtle dividers between grouped list rows |
| `textPrimary` | `#000000` | `#FFFFFF` | Voter names, titles, primary labels |
| `textSecondary` | `#8E8E93` | `#8E8E93` | House numbers, relative relations, metadata |
| `textTertiary` | `#C7C7CC` | `#48484A` | Disabled text, placeholder labels |

### Field Status Tokens

| Status Enum | Hex Color | Tinted Background | Semantic Meaning |
| :--- | :--- | :--- | :--- |
| `noIssue` | `#34C759` (Emerald) | `rgba(52, 199, 89, 0.12)` | Normal verified elector, resident confirmed |
| `away` | `#FF9500` (Amber) | `rgba(255, 149, 0, 0.12)` | Temporarily away from residence / locality |
| `abroad` | `#5AC8FA` (Sky Blue) | `rgba(90, 200, 250, 0.12)` | Non-resident Indian (NRI) / residing overseas |
| `reportedDeceased`| `#FF3B30` (Crimson) | `rgba(255, 59, 48, 0.12)` | Reported deceased; flagged for review |
| `unableToVerify` | `#FF9F0A` (Orange) | `rgba(255, 159, 10, 0.12)`| House locked, no response, relocated unknown |

### Review & Anomaly Tokens

| Token | Hex Color | Background Tint | Usage |
| :--- | :--- | :--- | :--- |
| `reviewNeedsReview` | `#FF453A` | `rgba(255, 69, 58, 0.12)` | Unresolved anomaly or conflicting observation |
| `reviewReviewed` | `#30D158` | `rgba(48, 209, 88, 0.12)` | Approved and verified by supervisor |
| `reviewNotReviewed`| `#8E8E93` | `rgba(142, 142, 147, 0.08)`| Standard unflagged statutory record |

---

## 3. Typography & Bilingual Script Support

Typography uses a system font stack that incorporates Malayalam unicode fonts (`Noto Sans Malayalam`, `Manjari`, `Gayathri`, and OS native Malayalam fonts) in the fallback chain:

```dart
static const List<String> fontFallbacks = [
  'Noto Sans Malayalam',
  'Manjari',
  'Gayathri',
  'sans-serif',
];
```

### Type Hierarchy:

| Style Name | Font Size | Weight | Line Height | Tracking |
| :--- | :--- | :--- | :--- | :--- |
| `Large Title` | 24 pt | Bold (700) | 1.25 | -0.5 px |
| `Headline` | 18 pt | Semi-Bold (600) | 1.30 | -0.3 px |
| `Body` | 15 pt | Regular (400) | 1.40 | 0.0 px |
| `Subheadline`| 13 pt | Medium (500) | 1.35 | 0.0 px |
| `Footnote` | 11 pt | Regular (400) | 1.30 | 0.2 px |
| `EPIC / Code`| 12 pt | Semi-Bold (600) | 1.20 | +0.8 px (Monospace) |

---

## 4. Spacing, Corner Radii & Elevation

- **Base Grid**: 4 pt increment system (`4`, `8`, `12`, `16`, `24`, `32`).
- **Corner Radii**:
  - Small Pills / Badges: `6 pt` - `8 pt`
  - Voter Photo Containers: `10 pt` squircle
  - Cards & Input Fields: `14 pt` rounded rectangle
  - Bottom Sheets: `20 pt` top rounded radius
- **Borders & Elevation**:
  - `0 elevation` paired with crisp `0.8 px` subtle outline borders (`borderLight` / `borderDark`).
  - Active elements feature a `1.5 px` border with `primary` accent tint.

---

## 5. UI Component Library

### `StatusBadge` & `ReviewBadge`
- Compact or full pill rendering.
- Displays appropriate vector glyph, capitalized status label, and color-matched container.
- Accessible color contrast exceeding WCAG AA standards (4.5:1).

### `VoterPhotoWidget`
- Strict 1:1 aspect ratio portrait viewer.
- Synchronous filesystem validation.
- Clean neutral fallback icon (`CupertinoIcons.person_fill`) on missing assets. Zero synthesized images.

### `VoterCard`
- High-density information layout:
  - Top row: Voter name (Malayalam / English) and serial badge (`#12`).
  - Middle row: Monospaced EPIC code, house number, age, and gender.
  - Bottom row: Status badge, review indicator, phone indicator, and disclosure chevron.

### `SearchBarWidget`
- Integrated 250ms debounce logic.
- Clear button when non-empty.
- Filter action button with badge indicator showing active filter count.
- Sort action sheet trigger.

### Bottom Sheets
- `FilterBottomSheet`: Multi-criteria filter controls (Gender, Part number, Field status, Review status, House number).
- `SortActionSheet`: Single-tap sorting selection (Serial, Name, House, Age, Part number, Ascending/Descending).
- `FieldStatusSheet`: Field observation recording form with status selectors, notes field, optional phone number, and warning notices.
