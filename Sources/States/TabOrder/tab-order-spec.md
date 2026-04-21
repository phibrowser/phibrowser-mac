## 1. Core Concepts

### 1.1 Opener

When tab B is opened from tab A (e.g. by clicking a link), **A is B's opener**. Denoted as `opener(B) = A`.

Opener is a **unidirectional parent-child relationship**: A opened B, but B did not necessarily open A.

### 1.2 Children

If `opener(B) = A` and `opener(C) = A`, then both B and C are A's **children**.

### 1.3 Sibling

If `opener(B) = A` and `opener(C) = A`, then B and C are **siblings**.

### 1.4 Descendant

All tabs reachable along the opener chain are called descendants.

```
A → B → C
A → D
```

- B, C, D are all descendants of A
- C is a descendant of B (and also of A)
- B and D are siblings (sharing opener A)
- C is not a sibling of D (C's opener is B, D's opener is A)

### 1.5 Visible Order

The tab arrangement order the user sees in the sidebar or TabStrip. References to "left", "right", and "neighbor" in this document all refer to positions in the visible order. In vertical layout, these correspond to "above" and "below".

### 1.6 Foreground Open vs Background Open

- **Foreground open**: The new tab immediately becomes the active (selected) tab after opening
- **Background open**: The new tab opens without switching; the currently selected tab remains unchanged

## 2. Insertion Position for New Tabs

### 2.1 Rules

| Priority | Scenario | Insertion Position |
|----------|----------|-------------------|
| 1 | Explicitly specified (e.g. moving back from pinned/bookmark, drag-drop target) | Specified position |
| 2 | Foreground link open | Immediately to the right of the opener |
| 3 | Background link open | After the opener's last visible descendant |
| 4 | Cmd+T / menu new tab | Appended to the end |
| 5 | Fallback | Appended to the end |

### 2.2 Examples

**Example 1: Foreground link open**

```
Initial order: A  B  C
Foreground open a link from A → creates A1

Result: A  A1  B  C
             ↑ A1 inserted to the right of A
```

**Example 2: Background link open**

```
Initial order: A  B  C
Background open A1 from A

Result: A  A1  B  C

Continue background opening A2 from A

Result: A  A1  A2  B  C
              ↑ A2 inserted after A's last descendant (A1)
```

**Example 3: Background open producing nested descendants**

```
Initial order: A  B  C
Background open A1 from A
Background open A1a from A1

Result: A  A1  A1a  B  C

Continue background opening A2 from A

Result: A  A1  A1a  A2  B  C
                    ↑ A2 inserted after A's last visible descendant (A1a)
```

**Example 4: Cmd+T**

```
Initial order: A  B  C
B is selected, press Cmd+T to open NTP

Result: A  B  C  NTP
                 ↑ NTP appended to the end
```

## 3. Tab Selection After Closing

### 3.1 Prerequisites

- Selection decision is only needed when closing the **currently selected normal tab**
- Closing a non-selected tab does not affect the current selection

### 3.2 Selection Priority

After closing the active tab, the next selected tab is determined by the following priority:

| Priority | Candidate | Description |
|----------|-----------|-------------|
| 1 | **Child** | A tab opened by the closed tab |
| 2 | **Sibling** | A tab sharing the same opener as the closed tab |
| 3 | **Opener** | The opener of the closed tab itself |
| 4 | **Right neighbor** | The tab to the right in visible order |
| 5 | **Left neighbor** | The tab to the left in visible order |

**Direction rule**: When looking for child and sibling candidates, prefer the **right side** of the closed tab first, then the left side.

### 3.3 Examples

**Example 1: Child takes priority**

```
Order: A  B  B1  C
Relationship: opener(B1) = B

Close B → select B1 (child priority)
```

**Example 2: No child, select sibling**

```
Order: A  B  C
Relationship: opener(B) = A, opener(C) = A

Close B → select C (right sibling preferred)
```

**Example 3: No child, no sibling, select opener**

```
Order: A  B  C
Relationship: opener(B) = A (C and B are unrelated)

Close B → select A (opener)
```

**Example 4: No opener relationship, select right neighbor**

```
Order: A  B  C
Relationship: none

Close B → select C (right neighbor)
```

**Example 5: Rightmost tab with no relationship, select left neighbor**

```
Order: A  B  C
Relationship: none

Close C → select B (left neighbor)
```

## 4. Opener Relationship Changes (Clear / Fix)

### 4.1 ForgetAllOpeners (Clear All Openers)

ForgetAllOpeners **clears the opener of every tab in the entire window**. There are three trigger paths:

#### Trigger Path 1: Foreground new tab creation

Triggered when a new tab is created in **foreground** mode and inherits an opener.

| Action | Triggered? | Reason |
|--------|-----------|--------|
| Foreground link open (Cmd+Click foreground, target=_blank foreground) | **Yes** | Foreground + inherits opener |
| Cmd+T | **Yes** | Foreground + typed new tab inherits opener |
| Background link open | **No** | Background does not trigger |

**Effect**: First clears all existing openers, then sets `opener(new tab) = current active tab`.

#### Trigger Path 2: Address-bar-type navigation

Triggered when the following types of navigation occur in a tab:

| Navigation Type | Description |
|----------------|-------------|
| URL typed in address bar | Manually entered by user |
| Bookmark click | Bookmark navigation |
| Search suggestion navigation | Address bar search suggestion |

**NTP tail exemption**: If the navigation occurs in an NTP (New Tab Page) at the **very end** of the tab list, and that NTP has only 1 history entry, the trigger is **suppressed**. This protects the opener relationship in the Cmd+T → type URL in address bar workflow.

#### Trigger Path 3: User gesture switches to a different task chain

Triggered when the user **manually clicks** to switch tabs, and the old active tab and the new active tab are not on the same opener chain.

Conditions (**all three must be met** to trigger):

```
Let old_tab = the active tab before switching
Let new_tab = the active tab after switching
Let old_opener = old_tab's opener
Let new_opener = new_tab's opener

Condition 1: new_opener ≠ old_opener     (the two tabs have different openers)
Condition 2: new_opener ≠ old_tab        (not switching from parent to child)
Condition 3: old_opener ≠ new_tab        (not switching from child back to parent)
```

**Intuition**: **Direct** parent-child switching within the same opener chain does not trigger; jumping outside the chain or cross-level switching does trigger.

**Evaluation examples**:

| Switch Path | old_opener | new_opener | Cond 1 | Cond 2 | Cond 3 | Triggered? |
|-------------|-----------|-----------|--------|--------|--------|------------|
| A → B (B's opener is A) | nil | A | ✓ | A≠A → **✗** | — | **No** (parent→child) |
| B → A (B's opener is A) | A | nil | ✓ | ✓ | A=A → **✗** | **No** (child→parent) |
| A → C (C and A are unrelated) | nil | nil | nil=nil → **✗** | — | — | **No** (same opener) |
| B → C (B's opener is A, C's opener is D) | A | D | ✓ | ✓ | ✓ | **Yes** |
| A → A21 (A21's opener is A2) | nil | A2 | ✓ | A2≠A → ✓ | nil≠A21 → ✓ | **Yes** (grandparent→grandchild, cross-level) |

> **Key point**: Direct parent↔child does not trigger, but grandparent↔grandchild does.

#### Full Examples

**Example 1: Foreground open clears openers**

```
Initial:
  Order: A  B  C  D
  Relationships: opener(B)=A, opener(C)=A, opener(D)=B

User presses Cmd+T on D to open NTP:
  → ForgetAllOpeners triggered
  → All openers cleared
  → New relationships: opener(NTP)=D (new tab uses D as opener), all other tabs have no opener

Now close NTP → select D (opener)
Close D → select right or left neighbor C (no opener relationships remain)
```

**Example 2: Background open tree + tab switching clearing openers affects insertion position**

```
Initial: A is active

1. A background opens A1, A background opens A2
   → Order: A  A1  A2
   → Relationships: opener(A1)=A, opener(A2)=A

2. Switch to A2 (parent→child, no trigger), A2 background opens A21
   → Order: A  A1  A2  A21
   → Relationships: opener(A1)=A, opener(A2)=A, opener(A21)=A2

---- The following two paths produce different results ----

Path a: Select A21 → switch back to A → A background opens A3
  ① A2→A21 (parent→child, no trigger)
  ② A21→A (A21's opener is A2, A is the grandparent → triggers ForgetAllOpeners!)
     → All openers cleared
  ③ Background open A3 from A: A has no descendants → A3 inserted to the right of A
     → Result: A  A3  A1  A2  A21

Path b: Don't select A21, switch directly from A2 back to A → A background opens A3
  ① A2→A (child→parent, no trigger)
     → Opener relationships intact
  ② Background open A3 from A: A's descendants are A1, A2, A21 → A3 inserted after A21
     → Result: A  A1  A2  A21  A3
```

The difference between path a and path b: switching from a grandchild (A21) back to a grandparent (A) clears all openers, but switching from a child (A2) back to a parent (A) does not.

### 4.2 ForgetOpener (Clear a Single Tab's Opener)

**Scenario**: An NTP created by Cmd+T has a special marker. When the user **switches away** to another tab, the NTP's opener is automatically cleared.

**Design intent**: The product semantics of Cmd+T is "quick lookup". If the user closes the NTP immediately, it should return to the opener; if the user has already switched away, it means they no longer need to go back, so the NTP's opener should be cleared.

**Example**:

```
Initial: Order A B C, A is active

1. Press Cmd+T → creates NTP, opener(NTP)=A
   Order: A B C NTP

2a. Close NTP immediately → opener(NTP)=A is valid → select A ✓

2b. Click B first (switch away), then close NTP
    → When switching to B, NTP's opener is cleared
    → When closing NTP, no opener → fallback to neighbor
```

### 4.3 FixOpeners (Fix Child Tab Openers When a Tab is Removed/Closed)

When a tab is **closed, moved away, or reordered by dragging**, its child tabs need to be fixed. The rule is **grandparent inheritance**: the child's opener is changed to the removed tab's opener.

**Example 1: Closing a middle node**

```
Initial relationships: A → B → C (opener(B)=A, opener(C)=B)

Close B:
  → FixOpeners: C's opener changed from B to A (grandparent inheritance)
  → New relationship: opener(C)=A
  → Select C (child priority hit)
```

**Example 2: Closing a root node**

```
Initial relationships: A → B, A → C (A has no opener)

Close A:
  → FixOpeners: B and C's opener changed from A to nil (A has no opener)
  → B and C become independent tabs
```

**Example 3: Drag reorder**

```
Initial order: A  B  C
Initial relationships: A → B → C

Drag B before A → order becomes B  A  C:
  → FixOpeners: C's opener changed from B to A (grandparent inheritance)
  → New relationships: opener(C)=A, opener(B)=A

Now close A:
  → FixOpeners: C and B's openers cleared (A has no opener)
  → Select C (child priority)

Then close C:
  → C has no child/sibling/opener → select neighbor
```

## 5. Pin / Bookmark Related

- Moving a tab from the normal area to **pinned or bookmark** is treated as a move, triggering FixOpeners
- Pinned / bookmark tabs are **not in** the visible normal tab list and do not participate in close-selection calculations

**Example**:

```
Initial relationships: A → B → C

Pin B to the pinned area:
  → FixOpeners: C's opener changed from B to A
  → B leaves the normal tab list
  → When closing C: opener(C)=A → select A
```
