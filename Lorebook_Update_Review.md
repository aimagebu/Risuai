# Lorebook Update Review v2

**Date:** 2026-06-26
**Supersedes:** lorebook_export91.json (original)
**New file:** lorebook_export_v2.json (88 entries: 3 folders + 85 content)

---

## Changes Made

### Entry [20]: "stamina" (Stamina Drain & Recovery Rules)
**Audit Issue:** #3 (Stamina drain for non-physical actions)
**Change:** Expanded the "NEVER emit drain tag" section from a short comma-separated list to an explicit blocklist with 20+ specific activities. Added categories: social interaction, mental-only activities, standing/commanding. Added note that Lua enforcement script will REJECT invalid drain sources.
**Why:** LLM was emitting stamina drain tags for conversation, intimidation, and examining objects. The previous short list was insufficient -- LLMs need exhaustive blocklists (Pattern 3 from design patterns).

### Entry [2]: "Status Information -- Format & Rules"
**Audit Issue:** #21 (Clock format inconsistency)
**Change:** Added explicit CLOCK FORMAT RULE section specifying `HH:MMAM/PM` with no space before AM/PM. Includes correct and incorrect examples.
**Why:** LLM was outputting inconsistent clock formats (`6:30 AM` vs `6:30AM`) causing Lua parser failures.

### NEW Entry [30]: "Skill Foundation Phase -- Mandatory Rules"
**Audit Issue:** #4 (Skills awarded without Foundation Phase)
**Change:** Created new entry with HARD RULE that all new skills must go through Foundation Phase (0/100 to 100/100) before being granted. Includes NEVER-do blocklist, cap of 2 simultaneous Foundation skills, and exact tag formats.
**Why:** LLM was granting skills directly at Neophyte without the required Learning phase. Existing entry [26] describes Foundation as a principle but doesn't enforce it with MUST/NEVER language.

### Entry [38]: "Time Passage Rules"
**Audit Issue:** #9 (Portal travel assigned 30+ minutes)
**Change:** Added "Instant/Magical Travel" table with durations for teleportation (0-1 min), portal travel (1-5 min), divine transport (0-5 min). Added explicit NEVER rule against 30+ minute portal travel.
**Why:** LLM was assigning 30-minute travel time to portal/teleportation events, which should be near-instantaneous.

---

## Regex Render-Coverage Check (Section 4.7)

All 25 tag types found in lorebook entries are covered by matching regex patterns:
- Hero block, Hit cards, Unit cards, Weather Update
- All System card types (FAME CHANGE, SKILL PROGRESS, LEVEL UP, etc.)
- Skill Foundation, Synergy, Technique cards
- Popup cards (Buff/Debuff, Skill Activation)
- Generic System Card catch-all covers any remaining `<System: TYPE | ...>` patterns

**Gaps found: 0**

---

## Entry Count Verification

| Category | Count |
|----------|-------|
| Folders | 3 (SYSTEM, MONSTERS, eralith) |
| Content entries | 85 |
| **Total** | **88** |

Previous file had 87 entries (3 folders + 84 content).
New file has 88 entries (+1 new entry: "Skill Foundation Phase -- Mandatory Rules").
