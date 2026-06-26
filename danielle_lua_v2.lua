-- Danielle Lua v2 (2026-06-26a) Phase 1a+1b+2a+2b+3
-- Validator + Calculator + Skill Tracker + Resource Enforcer
-- Turn snapshot: rerolls recalculate from same starting point
-- Regeneration detection: restores pre-response baseline on reroll
-- Phase 3: MP/HP/Stamina enforcement — corrects Hero block values in-place
-- OOC commands: /lua, /luareset, /luaday, /luaclear, /luaset

--------------------------------------------------------------------------------
-- CONFIG & LOOKUP TABLES
--------------------------------------------------------------------------------

local EXP_DENOMINATORS = {}
for i = 1, 9 do EXP_DENOMINATORS[i] = 1000 end
for i = 10, 19 do EXP_DENOMINATORS[i] = 2000 end
for i = 20, 29 do EXP_DENOMINATORS[i] = 3000 end
for i = 30, 39 do EXP_DENOMINATORS[i] = 4000 end
for i = 40, 50 do EXP_DENOMINATORS[i] = 5000 end

local DAYS_OF_WEEK = {"Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"}

local STORM_WEATHERS = {
    ["Blizzard"] = true,
    ["Thunderstorm"] = true,
    ["Ice Storm"] = true,
}

local SCHEMA_VERSION = 8

-- Allowed stamina drain sources (physical activities only)
local VALID_STAMINA_DRAIN_SOURCES = {
    ["swiftness"] = true,
    ["combat"] = true,
    ["mining"] = true,
    ["construction"] = true,
    ["smithing"] = true,
    ["sprinting"] = true,
    ["fleeing"] = true,
    ["chopping"] = true,
    ["gathering"] = true,
    ["crafting"] = true,
    ["cooking"] = true,
    ["training"] = true,
    ["forced march"] = true,
    ["heavy labor"] = true,
    ["moderate labor"] = true,
    ["light labor"] = true,
}

-- Non-physical sources that must NEVER drain stamina
local INVALID_STAMINA_DRAIN_SOURCES = {
    ["examining object"] = true,
    ["examining"] = true,
    ["issuing command"] = true,
    ["grand pronouncement"] = true,
    ["talking"] = true,
    ["conversation"] = true,
    ["intimidation"] = true,
    ["intimidating"] = true,
    ["walking"] = true,
    ["observation"] = true,
    ["watching"] = true,
    ["sitting"] = true,
    ["resting"] = true,
    ["sleeping"] = true,
    ["eating"] = true,
    ["bathing"] = true,
    ["meditation"] = true,
    ["reading"] = true,
    ["standing"] = true,
    ["declaring"] = true,
    ["speaking"] = true,
    ["commanding"] = true,
    ["pronouncement"] = true,
}

--------------------------------------------------------------------------------
-- UTILITY
--------------------------------------------------------------------------------

function deepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = deepCopy(v)
    end
    return copy
end

--------------------------------------------------------------------------------
-- STATE MANAGEMENT
--------------------------------------------------------------------------------

function buildDefaultState()
    return {
        campaign_day = 1,
        day_of_week = "Monday",
        season = "Autumn",
        clock_hour = 6,
        clock_minute = 0,
        in_game_hours_elapsed = 0,

        weather = "Clear",
        weather_last_change_hour = 0,
        weather_is_storm = false,

        level = 1,
        exp_current = 0,
        exp_denominator = 1000,
        fame = 0,

        bronze = 0,
        silver = 0,
        gold = 0,
        stellar = 0,

        hp_current = 100,
        hp_max = 100,
        mp_current = 100,
        mp_max = 100,
        stamina_current = 100,
        stamina_max = 100,
        resources_initialized = false,
        hero_name = "",

        companions = {},
        skills = {},

        last_output_hash = "",
        validation_log = {},

        exp_events_today = 0,
        fame_events_today = 0,
        last_campaign_day = 1,

        turn_snapshot = nil,

        schema_version = SCHEMA_VERSION
    }
end

function migrateState(state)
    local version = state.schema_version or 0

    if version < 1 then
        state.weather_last_change_hour = state.weather_last_change_hour or 0
        state.weather_is_storm = state.weather_is_storm or false
        state.in_game_hours_elapsed = state.in_game_hours_elapsed or 0
        state.exp_events_today = state.exp_events_today or 0
        state.fame_events_today = state.fame_events_today or 0
        state.last_campaign_day = state.last_campaign_day or 1
        state.companions = state.companions or {}
        state.validation_log = state.validation_log or {}
    end

    if version < 2 then
        state.fame = state.fame or 0
    end

    if version < 3 then
        state.skills = state.skills or {}
        state.turn_snapshot = state.turn_snapshot or nil
    end

    if version < 4 then
        -- no new fields; version bump for snapshot-on-first-turn fix
    end

    if version < 5 then
        -- no new fields; version bump for skill progress tracking
    end

    if version < 6 then
        state.last_user_msg_hash = state.last_user_msg_hash or nil
    end

    if version < 7 then
        state.hp_current = state.hp_current or 100
        state.hp_max = state.hp_max or 100
        state.mp_current = state.mp_current or 100
        state.mp_max = state.mp_max or 100
        state.stamina_current = state.stamina_current or 100
        state.stamina_max = state.stamina_max or 100
        state.resources_initialized = state.resources_initialized or false
        state.hero_name = state.hero_name or ""
    end

    if version < 8 then
        -- v8: stamina drain uses absolute values; recovery detection added
        -- No new state fields needed; behavior change only
    end

    state.schema_version = SCHEMA_VERSION
    return state
end

function loadState(accessKey)
    local state = getState(accessKey, "game_state")
    if state ~= nil and type(state) == "table" and state.schema_version then
        return migrateState(state)
    end
    return nil
end

function saveState(accessKey, state)
    setState(accessKey, "game_state", state)
    syncAllFlatVars(accessKey, state)
end

--------------------------------------------------------------------------------
-- FLAT VAR SYNC (for lorebook CBS {{getvar::X}})
--------------------------------------------------------------------------------

function syncAllFlatVars(accessKey, state)
    setChatVar(accessKey, "lua_level", tostring(state.level))
    setChatVar(accessKey, "lua_campaign_day", tostring(state.campaign_day))
    setChatVar(accessKey, "lua_season", state.season or "")
    setChatVar(accessKey, "lua_weather", state.weather or "")
    setChatVar(accessKey, "lua_bronze", tostring(state.bronze))
    setChatVar(accessKey, "lua_silver", tostring(state.silver))
    setChatVar(accessKey, "lua_gold", tostring(state.gold))
    setChatVar(accessKey, "lua_stellar", tostring(state.stellar))
    setChatVar(accessKey, "lua_exp_current", tostring(state.exp_current))
    setChatVar(accessKey, "lua_exp_denom", tostring(state.exp_denominator))
    setChatVar(accessKey, "lua_fame", tostring(state.fame))
    setChatVar(accessKey, "lua_hp_current", tostring(state.hp_current))
    setChatVar(accessKey, "lua_hp_max", tostring(state.hp_max))
    setChatVar(accessKey, "lua_mp_current", tostring(state.mp_current))
    setChatVar(accessKey, "lua_mp_max", tostring(state.mp_max))
    setChatVar(accessKey, "lua_stamina_current", tostring(state.stamina_current))
    setChatVar(accessKey, "lua_stamina_max", tostring(state.stamina_max))
    setChatVar(accessKey, "lua_clock", string.format("%02d:%02d", state.clock_hour, state.clock_minute))

    local skill_count = 0
    if state.skills then
        for _ in pairs(state.skills) do skill_count = skill_count + 1 end
    end
    setChatVar(accessKey, "lua_skill_count", tostring(skill_count))

    local last_error = ""
    if state.validation_log and #state.validation_log > 0 then
        last_error = state.validation_log[#state.validation_log].msg or ""
    end
    setChatVar(accessKey, "lua_last_error", last_error)
end

--------------------------------------------------------------------------------
-- TURN SNAPSHOT (reroll protection)
-- onStart saves a snapshot of all mutable state. Each onOutput call
-- restores from the snapshot before processing, so rerolls always
-- recalculate from the same starting point instead of accumulating.
--------------------------------------------------------------------------------

function createTurnSnapshot(state)
    local snapshot = {}
    for k, v in pairs(state) do
        if k ~= "turn_snapshot" and k ~= "last_output_hash"
           and k ~= "last_user_msg_hash" then
            snapshot[k] = deepCopy(v)
        end
    end
    return snapshot
end

function restoreFromSnapshot(state)
    if state.turn_snapshot == nil then return end
    local saved_hash = state.last_output_hash
    local saved_user_hash = state.last_user_msg_hash
    local saved_snapshot = state.turn_snapshot
    for k, v in pairs(saved_snapshot) do
        state[k] = deepCopy(v)
    end
    state.last_output_hash = saved_hash
    state.last_user_msg_hash = saved_user_hash
    state.turn_snapshot = saved_snapshot
end

--------------------------------------------------------------------------------
-- REROLL GUARD
--------------------------------------------------------------------------------

function computeHash(text)
    local hash = 5381
    local len = #text

    local sample
    if len <= 5000 then
        sample = text
    else
        sample = text:sub(1, 1500)
            .. text:sub(math.max(1, len - 2500), len)
            .. tostring(len)
    end

    for i = 1, #sample do
        hash = ((hash * 33) ~ string.byte(sample, i)) & 0xFFFFFFFF
    end

    return tostring(hash) .. ":" .. tostring(len)
end

--------------------------------------------------------------------------------
-- HERO BLOCK PARSER
--------------------------------------------------------------------------------

function extractField(block, pattern)
    local val = block:match(pattern)
    if val then return val:match("^%s*(.-)%s*$") end
    return nil
end

function extractFraction(block, pattern)
    local a, b = block:match(pattern)
    if a and b then
        return tonumber(a), tonumber(b)
    end
    return nil, nil
end

local VALID_RANKS = {
    ["Uninitiated"] = true,
    ["Neophyte"] = true,
    ["Apprentice"] = true,
    ["Practitioner"] = true,
    ["Savant"] = true,
    ["Archon"] = true,
    ["God-Touched"] = true,
    ["Novice"] = true,
    ["Adept"] = true,
    ["Expert"] = true,
    ["Master"] = true,
    ["Mythic"] = true,
    ["Learning"] = true,
}

local RANK_ORDER = {
    ["Uninitiated"] = 1,
    ["Neophyte"] = 2,
    ["Apprentice"] = 3,
    ["Practitioner"] = 4,
    ["Savant"] = 5,
    ["Archon"] = 6,
    ["God-Touched"] = 7,
    ["Novice"] = 2,
    ["Adept"] = 4,
    ["Expert"] = 5,
    ["Master"] = 6,
    ["Mythic"] = 7,
    ["Learning"] = 0,
}

function getNextRank(rank)
    if rank == nil then return nil end
    local current_order = RANK_ORDER[rank]
    if current_order == nil then return nil end
    for r, order in pairs(RANK_ORDER) do
        if order == current_order + 1 then
            return r
        end
    end
    return nil
end

function parseSkillsFromString(skill_str)
    if skill_str == nil or skill_str == "" then return {} end

    local skills = {}
    for entry in skill_str:gmatch("//(.-)//") do
        local trimmed = entry:match("^%s*(.-)%s*$")

        if trimmed:lower():match("^none") then
            -- skip
        else
            local name, rank, current, max_val

            -- Form A: "Name: +N STAT description. Rank (3/100)"
            -- First try to find rank + progress anywhere in the string
            name, rank, current, max_val =
                trimmed:match("^%s*(.-)%s*:%s*.*%s+([%a%-]+)%s*%((%d+)%s*/%s*(%d+)%)")
            if rank and not VALID_RANKS[rank] then
                name = nil
                rank = nil
                current = nil
                max_val = nil
            end

            -- Form A-strict: "Name: Rank (3/100)" (no extra text between colon and rank)
            if not name then
                name, rank, current, max_val =
                    trimmed:match("^%s*(.-)%s*:%s*([%a%-]+)%s*%((%d+)%s*/%s*(%d+)%)")

            -- Form B: "Name (Rank): description"
            if not name then
                name, rank = trimmed:match("^%s*(.-)%s*%(([%a%-]+)%)%s*:")
                if rank and not VALID_RANKS[rank] then
                    rank = nil
                    name = nil
                end
            end

            -- Form D: "Name — Rank: description" or "Name — Rank" (em-dash)
            if not name then
                local n, r = trimmed:match("^%s*(.-)%s*[%-—–]+%s*([%a%-]+)%s*:?")
                if n and r and VALID_RANKS[r] then
                    name = n
                    rank = r
                end
            end

            -- Form E: "Name: Status (Rank current/max)" — compound state
            if not name then
                local n, s, r, c, m = trimmed:match("^%s*(.-)%s*:%s*([%a%-]+)%s*%(([%a%-]+)%s+(%d+)%s*/%s*(%d+)%)")
                if n and c and m then
                    name = n
                    current = c
                    max_val = m
                    if r and VALID_RANKS[r] then
                        rank = r
                    elseif s and VALID_RANKS[s] then
                        rank = s
                    end
                end
            end

            -- Form F: last-resort rank extraction from anywhere in string
            if not name then
                local n = trimmed:match("^%s*([^:]+)")
                if n then
                    name = n
                    -- Try to find a valid rank word followed by (N/M)
                    local r, c, m = trimmed:match("([%a%-]+)%s*%((%d+)%s*/%s*(%d+)%)")
                    if r and VALID_RANKS[r] then
                        rank = r
                        current = c
                        max_val = m
                    end
                end
            end

            -- Form C: "Name: passive description" (no rank)
            if not name then
                name = trimmed:match("^%s*([^:]+)")
            end

            if name then
                name = name:match("^%s*(.-)%s*$")
                skills[name] = {
                    rank = rank,
                    progress = tonumber(current),
                    progress_max = tonumber(max_val)
                }
            end
        end
    end
    return skills
end

function parseHeroBlock(text)
    local block = text:match("<Hero:(.-)>")
    if not block then
        block = text:match("<Hero:([^>]*)>")
    end
    if not block then return nil end

    local hero = {}

    hero.name = extractField(block, "^%s*([^|]+)")
    hero.job = extractField(block, "Job:%s*([^|]+)")
    hero.level = tonumber(extractField(block, "Level:%s*(%d+)"))
    hero.fame = tonumber(extractField(block, "Fame:%s*(%d+)"))

    hero.bronze = tonumber(extractField(block, "Bronze:%s*(%-?%d+)"))
    hero.silver = tonumber(extractField(block, "Silver:%s*(%-?%d+)"))
    hero.gold = tonumber(extractField(block, "Gold:%s*(%-?%d+)"))
    hero.stellar = tonumber(extractField(block, "Stellar:%s*(%-?%d+)"))

    hero.location = extractField(block, "Location:%s*([^|]+)")
    hero.clock = extractField(block, "Clock:%s*([^|]+)")
    hero.time_of_day = extractField(block, "Time:%s*([^|]+)")
    hero.weather = extractField(block, "Weather:%s*([^|]+)")
    hero.day_of_week = extractField(block, "Day:%s*([^|]+)")
    hero.campaign_day = tonumber(extractField(block, "Campaign%s*Day:%s*(%d+)"))
    hero.season = extractField(block, "Season:%s*([^|]+)")

    hero.hp_percent = tonumber(extractField(block, "Health%s*Points%s*(%d+)%%"))
    hero.hp_current, hero.hp_max = extractFraction(block, "Health%s*Points%s*%d+%%:%s*(%d+)/(%d+)")
    hero.mp_percent = tonumber(extractField(block, "Magic%s*Points%s*(%d+)%%"))
    hero.mp_current, hero.mp_max = extractFraction(block, "Magic%s*Points%s*%d+%%:%s*(%d+)/(%d+)")
    hero.stamina_percent = tonumber(extractField(block, "Stamina%s*(%d+)%%"))
    hero.stamina_current, hero.stamina_max = extractFraction(block, "Stamina%s*%d+%%:%s*(%d+)/(%d+)")
    hero.exp_percent = tonumber(extractField(block, "Experience%s*Points%s*(%d+)%%"))
    hero.exp_current, hero.exp_denominator = extractFraction(block, "Experience%s*Points%s*%d+%%:%s*(%d+)/(%d+)")

    hero.str = tonumber(extractField(block, "Strength:%s*(%d+)"))
    hero.dex = tonumber(extractField(block, "Dexterity:%s*(%d+)"))
    hero.int = tonumber(extractField(block, "Intelligence:%s*(%d+)"))
    hero.vit = tonumber(extractField(block, "Vitality:%s*(%d+)"))
    hero.atk = tonumber(extractField(block, "Attack:%s*(%d+)"))
    hero.def = tonumber(extractField(block, "Defense:%s*(%d+)"))
    hero.mag = tonumber(extractField(block, "Magic:%s*(%d+)"))
    hero.foc = tonumber(extractField(block, "Focus:%s*(%d+)"))
    hero.luck = tonumber(extractField(block, "Luck:%s*(%d+)"))
    hero.cha = tonumber(extractField(block, "Charisma:%s*(%d+)"))

    hero.skills = parseSkillsFromString(
        extractField(block, "Skill:%s*([^|]+)") or
        extractField(block, "Skills:%s*([^|]+)")
    )

    return hero
end

--------------------------------------------------------------------------------
-- VALIDATION LOGGING
--------------------------------------------------------------------------------

function logValidation(state, message)
    if state.validation_log == nil then
        state.validation_log = {}
    end
    table.insert(state.validation_log, {
        msg = message
    })
    if #state.validation_log > 20 then
        table.remove(state.validation_log, 1)
    end
end

--------------------------------------------------------------------------------
-- PHASE 1 VALIDATORS
--------------------------------------------------------------------------------

function validateExpDenominator(state, hero)
    if hero.level == nil or hero.exp_denominator == nil then
        return
    end

    local expected = EXP_DENOMINATORS[hero.level]
    if expected == nil then
        expected = 5000
    end

    if hero.exp_denominator ~= expected then
        logValidation(state, string.format(
            "EXP denominator mismatch: Lv%d has %d, expected %d",
            hero.level, hero.exp_denominator, expected
        ))
    end

    if hero.exp_current and hero.exp_denominator and hero.exp_denominator > 0 then
        local calculated_percent = math.floor(hero.exp_current / hero.exp_denominator * 100)
        if hero.exp_percent and math.abs(calculated_percent - hero.exp_percent) > 2 then
            logValidation(state, string.format(
                "EXP%% mismatch: %d/%d = %d%%, got %d%%",
                hero.exp_current, hero.exp_denominator, calculated_percent, hero.exp_percent
            ))
        end
        if hero.exp_percent and hero.exp_percent >= 100 then
            logValidation(state, "EXP% >= 100 but no level-up occurred")
        end
    end
end

function validateCurrencyNonNegative(state, hero)
    local currencies = {
        {"Bronze", hero.bronze},
        {"Silver", hero.silver},
        {"Gold", hero.gold},
        {"Stellar", hero.stellar}
    }
    for _, entry in ipairs(currencies) do
        local name, value = entry[1], entry[2]
        if value ~= nil and value < 0 then
            logValidation(state, string.format("Currency %s is negative: %d", name, value))
        end
    end
end

function validateCampaignDay(state, hero)
    if hero.campaign_day == nil then
        return
    end

    local prev_day = state.campaign_day

    if hero.campaign_day < prev_day then
        logValidation(state, string.format(
            "Campaign Day decreased: was %d, now %d",
            prev_day, hero.campaign_day
        ))
    end

    if hero.campaign_day > prev_day + 1 then
        logValidation(state, string.format(
            "Campaign Day jumped >1: was %d, now %d",
            prev_day, hero.campaign_day
        ))
    end

    if hero.campaign_day > prev_day then
        state.last_campaign_day = state.campaign_day
        state.campaign_day = hero.campaign_day
        state.exp_events_today = 0
        state.fame_events_today = 0
    end

    local expected_season = dayToSeason(hero.campaign_day)
    if hero.season and expected_season and hero.season ~= expected_season then
        logValidation(state, string.format(
            "Season mismatch: Day %d should be %s, got %s",
            hero.campaign_day, expected_season, hero.season
        ))
    end
end

function dayToSeason(day)
    local d = ((day - 1) % 120) + 1
    if d <= 30 then return "Autumn"
    elseif d <= 60 then return "Winter"
    elseif d <= 90 then return "Spring"
    else return "Summer" end
end

function validateCompanionLevels(state, response)
    for name, level_str in response:gmatch("<Unit:%s*Party%s*|.-Name:%s*([^|]+)%s*|.-Level:%s*(%d+)") do
        local level = tonumber(level_str)
        local comp_name = name:match("^%s*(.-)%s*$")

        if comp_name and level then
            if state.companions[comp_name] == nil then
                state.companions[comp_name] = {
                    level = level,
                    exp_current = 0,
                    exp_denominator = EXP_DENOMINATORS[level] or 1000
                }
            else
                local prev = state.companions[comp_name].level
                if level < prev then
                    logValidation(state, string.format(
                        "Companion %s level decreased: %d -> %d", comp_name, prev, level
                    ))
                elseif level > prev + 1 then
                    logValidation(state, string.format(
                        "Companion %s level jumped >1: %d -> %d", comp_name, prev, level
                    ))
                end
                state.companions[comp_name].level = level
            end
        end
    end
end

function validateLevelConsistency(state, hero)
    if hero.level == nil then return end

    if state.level > 0 and hero.level < state.level then
        logValidation(state, string.format(
            "Level decreased: was %d, now %d",
            state.level, hero.level
        ))
    elseif hero.level > state.level + 1 then
        logValidation(state, string.format(
            "Level jumped >1: was %d, now %d",
            state.level, hero.level
        ))
    end

    state.level = hero.level
    state.exp_denominator = EXP_DENOMINATORS[hero.level] or 5000
end

--------------------------------------------------------------------------------
-- PHASE 2 CALCULATORS
--------------------------------------------------------------------------------

function parseClock(clock_str)
    if clock_str == nil then return nil, nil end
    local hour, minute, ampm = clock_str:match("(%d+):(%d+)%s*(%a+)")
    if hour == nil then return nil, nil end
    hour = tonumber(hour)
    minute = tonumber(minute)
    ampm = ampm:upper()
    if ampm == "PM" and hour < 12 then hour = hour + 12 end
    if ampm == "AM" and hour == 12 then hour = 0 end
    return hour, minute
end

function advanceTime(state, hero, prev_campaign_day)
    if hero.clock == nil then return end

    local new_hour, new_minute = parseClock(hero.clock)
    if new_hour == nil then return end

    local prev_total = state.clock_hour * 60 + state.clock_minute
    local new_total = new_hour * 60 + new_minute

    local day_diff = (hero.campaign_day or prev_campaign_day) - prev_campaign_day

    local elapsed_minutes
    if day_diff > 0 then
        elapsed_minutes = day_diff * 24 * 60 + (new_total - prev_total)
    elseif new_total >= prev_total then
        elapsed_minutes = new_total - prev_total
    else
        local backward_minutes = prev_total - new_total
        if backward_minutes <= 60 then
            logValidation(state, string.format(
                "Clock went backwards by %d min: %02d:%02d -> %02d:%02d (treating as 0)",
                backward_minutes,
                state.clock_hour, state.clock_minute, new_hour, new_minute
            ))
            elapsed_minutes = 0
        else
            elapsed_minutes = (24 * 60 - prev_total) + new_total
        end
    end

    if elapsed_minutes < 0 then
        logValidation(state, string.format(
            "Clock went backwards: %02d:%02d -> %02d:%02d (Day %d)",
            state.clock_hour, state.clock_minute, new_hour, new_minute,
            hero.campaign_day or prev_campaign_day
        ))
        elapsed_minutes = 0
    end

    -- Elapsed time cap: single-turn sanity guard (max 18 hrs unless multi-day)
    local MAX_SINGLE_TURN_MINUTES = 18 * 60
    if day_diff == 0 and elapsed_minutes > MAX_SINGLE_TURN_MINUTES then
        logValidation(state, string.format(
            "Elapsed time capped: calculated %d min (%.1f hrs) in one turn, capped to %d min (%.1f hrs)",
            elapsed_minutes, elapsed_minutes / 60,
            MAX_SINGLE_TURN_MINUTES, MAX_SINGLE_TURN_MINUTES / 60
        ))
        elapsed_minutes = MAX_SINGLE_TURN_MINUTES
    end

    state.in_game_hours_elapsed = state.in_game_hours_elapsed + (elapsed_minutes / 60)
    state.clock_hour = new_hour
    state.clock_minute = new_minute
end

function trackExpChanges(state, hero, prev_level, prev_exp)
    if hero.exp_current == nil or hero.level == nil then return end

    if hero.level > prev_level then
        state.exp_events_today = state.exp_events_today + 1
        if state.exp_events_today > 3 then
            logValidation(state, string.format(
                "EXP daily cap exceeded: %d events today (max 3) - level-up Lv%d->Lv%d",
                state.exp_events_today, prev_level, hero.level
            ))
        end
    elseif hero.exp_current > prev_exp and hero.level == prev_level then
        local gained = hero.exp_current - prev_exp
        state.exp_events_today = state.exp_events_today + 1

        if state.exp_events_today > 3 then
            logValidation(state, string.format(
                "EXP daily cap exceeded: %d events today (max 3). +%d EXP",
                state.exp_events_today, gained
            ))
        end
    elseif hero.exp_current < prev_exp and hero.level == prev_level then
        logValidation(state, string.format(
            "EXP decreased without level-up: %d -> %d",
            prev_exp, hero.exp_current
        ))
    end
end

function trackFameChanges(state, hero, prev_fame)
    if hero.fame == nil then return end

    if hero.fame > prev_fame then
        state.fame_events_today = state.fame_events_today + 1

        if state.fame_events_today > 1 then
            local gained = hero.fame - prev_fame
            logValidation(state, string.format(
                "Fame daily cap exceeded: %d events today (max 1). +%d Fame",
                state.fame_events_today, gained
            ))
        end
    elseif hero.fame < prev_fame then
        logValidation(state, string.format(
            "Fame decreased: %d -> %d",
            prev_fame, hero.fame
        ))
    end
end

function enforceWeatherReroll(state, hero)
    if hero.weather == nil then return end

    if hero.weather ~= state.weather then
        state.weather_last_change_hour = state.in_game_hours_elapsed
        state.weather_is_storm = STORM_WEATHERS[hero.weather] or false
        return
    end

    local hours_since_change = state.in_game_hours_elapsed - state.weather_last_change_hour
    local max_hours = state.weather_is_storm and 12 or 4

    if hours_since_change > max_hours then
        logValidation(state, string.format(
            "Weather stuck: '%s' unchanged for %.1f hrs (max %d). Reroll needed.",
            state.weather, hours_since_change, max_hours
        ))
    end
end

function trackSkillChanges(state, hero_skills)
    if state.skills == nil then
        state.skills = {}
    end

    for name, skill in pairs(hero_skills) do
        if state.skills[name] == nil then
            logValidation(state, string.format("NEW SKILL: %s%s",
                name,
                skill.rank and string.format(" (%s %d/%d)",
                    skill.rank, skill.progress or 0, skill.progress_max or 100)
                or " (Passive)"
            ))
            state.skills[name] = deepCopy(skill)
        else
            local prev = state.skills[name]

            -- Detect rank changes
            if skill.rank and prev.rank and skill.rank ~= prev.rank then
                local prev_order = RANK_ORDER[prev.rank]
                local new_order = RANK_ORDER[skill.rank]
                if prev_order and new_order and new_order > prev_order + 1 then
                    logValidation(state, string.format(
                        "SKILL RANK SKIPPED: %s jumped %s -> %s (skipped %d ranks)",
                        name, prev.rank, skill.rank, new_order - prev_order - 1
                    ))
                end
                logValidation(state, string.format("SKILL RANK UP: %s %s -> %s",
                    name, prev.rank, skill.rank
                ))
            end

            -- Track progress delta
            if skill.progress and prev.progress then
                local delta = skill.progress - prev.progress
                if delta > 0 then
                    logValidation(state, string.format(
                        "SKILL PROGRESS: %s (+%d)", name, delta
                    ))
                elseif delta < 0 and skill.rank == prev.rank then
                    logValidation(state, string.format(
                        "SKILL PROGRESS DECREASED: %s %d -> %d",
                        name, prev.progress, skill.progress
                    ))
                end
            end

            -- Detect progress overflow (should trigger rank-up)
            if skill.progress and skill.progress_max
               and skill.progress >= skill.progress_max
               and skill.rank and skill.rank == (prev.rank or skill.rank) then
                local next_rank = getNextRank(skill.rank)
                if next_rank then
                    logValidation(state, string.format(
                        "RANK UP EXPECTED: %s at %d/%d — should promote %s -> %s",
                        name, skill.progress, skill.progress_max,
                        skill.rank, next_rank
                    ))
                elseif skill.progress > skill.progress_max then
                    logValidation(state, string.format(
                        "SKILL OVERFLOW: %s at %d/%d — max rank, progress should cap",
                        name, skill.progress, skill.progress_max
                    ))
                end
            end

            state.skills[name] = deepCopy(skill)
        end
    end

    local to_remove = {}
    for name, _ in pairs(state.skills) do
        if hero_skills[name] == nil then
            logValidation(state, string.format("Skill removed from Hero block: %s", name))
            table.insert(to_remove, name)
        end
    end
    for _, name in ipairs(to_remove) do
        state.skills[name] = nil
    end
end

--------------------------------------------------------------------------------
-- PHASE 3: RESOURCE ENFORCEMENT
--------------------------------------------------------------------------------

function parseResourceTags(response, hero_name, state)
    local tags = {
        mp_drain = 0,
        mp_set_value = nil,
        hp_drain = 0,
        hp_heal = 0,
        stamina_drain = 0,
        stamina_drain_source = nil,
        stamina_recovery = nil,
        stamina_recovery_source = nil,
        level_up = false,
        has_combat = false,
        physical_skill_count = 0,
    }

    -- <System: MP DRAIN | Amount: N | ...>
    for amount in response:gmatch("<System:%s*MP%s+DRAIN%s*|%s*Amount:%s*(%d+)") do
        tags.mp_drain = tags.mp_drain + tonumber(amount)
    end

    -- <System: MP DRAINED | Current MP: N/M>
    local mp_cur = response:match("<System:%s*MP%s+DRAINED%s*|%s*Current%s+MP:%s*(%d+)/%d+")
    if mp_cur then
        tags.mp_set_value = tonumber(mp_cur)
    end

    -- <System: STAMINA DRAIN | Amount: N | Source: activity>
    for amount, source in response:gmatch("<System:%s*STAMINA%s+DRAIN%s*|%s*Amount:%s*(%d+)%s*|%s*Source:%s*([^>]*)") do
        tags.stamina_drain = tags.stamina_drain + tonumber(amount)
        tags.stamina_drain_source = source:match("^%s*(.-)%s*$")
    end
    -- Fallback: match without Source field
    if tags.stamina_drain == 0 then
        for amount in response:gmatch("<System:%s*STAMINA%s+DRAIN%s*|%s*Amount:%s*(%d+)") do
            tags.stamina_drain = tags.stamina_drain + tonumber(amount)
        end
    end

    -- Detect stamina recovery from rest/sleep/meal keywords
    local response_lower = response:lower()
    if response_lower:match("full%s+sleep") or response_lower:match("slept%s+through") or response_lower:match("wakes?%s+up%s+fully%s+rested") then
        tags.stamina_recovery = state.stamina_max - state.stamina_current
        tags.stamina_recovery_source = "full sleep"
    elseif response_lower:match("short%s+rest") or response_lower:match("rests?%s+for%s+an?%s+hour") or response_lower:match("takes?%s+a%s+break") then
        tags.stamina_recovery = math.floor(state.stamina_max * 0.40)
        tags.stamina_recovery_source = "short rest"
    elseif response_lower:match("eats?%s+a%s+meal") or response_lower:match("finishe[sd]%s+eating") or response_lower:match("enjoys?%s+a%s+meal") then
        tags.stamina_recovery = math.floor(state.stamina_max * 0.15)
        tags.stamina_recovery_source = "meal"
    elseif response_lower:match("catches?%s+h[ei][sr]%s+breath") or response_lower:match("sits?%s+down%s+to%s+rest") then
        tags.stamina_recovery = math.floor(state.stamina_max * 0.10)
        tags.stamina_recovery_source = "catching breath"
    end

    -- <Hit: Type | Target: name | Value: N | ...>
    for hit_type, target, value in response:gmatch("<Hit:%s*(%w+)%s*|%s*Target:%s*(.-)%s*|%s*Value:%s*(%d+)") do
        local t = target:match("^%s*(.-)%s*$")
        local v = tonumber(value)

        local is_hero = (t == hero_name) or (t == "<user>")
        if not is_hero and hero_name ~= "" then
            is_hero = t:lower() == hero_name:lower()
        end

        if is_hero then
            if hit_type == "Damage" or hit_type == "Critical" then
                tags.hp_drain = tags.hp_drain + v
                tags.has_combat = true
            elseif hit_type == "Heal" then
                tags.hp_heal = tags.hp_heal + v
            end
        else
            if hit_type == "Damage" or hit_type == "Critical"
               or hit_type == "Miss" or hit_type == "Block" then
                tags.has_combat = true
            end
        end
    end

    -- Combat detection via Unit tags
    if response:match("<Unit:%s*Enemy") or response:match("<Unit:%s*Boss") then
        tags.has_combat = true
    end

    -- Physical skill activation count (stamina drain source)
    for skill_type in response:gmatch("<Skill%s+Name:.-|%s*Type:%s*(%w+)") do
        if skill_type == "Physical" then
            tags.physical_skill_count = tags.physical_skill_count + 1
        end
    end

    -- Safety net: extract MP/Stamina cost from Skill Activation popup Cost field
    -- ONLY if no explicit <System: MP DRAIN> or <System: STAMINA DRAIN> tags found
    -- (prevents double-counting when LLM outputs both popup Cost AND drain tag)
    if tags.mp_drain == 0 then
        for cost_str in response:gmatch("<Skill%s+Name:.-|.-Cost:%s*(%d+)%s*MP") do
            local cost = tonumber(cost_str)
            if cost and cost > 0 then
                tags.mp_drain = tags.mp_drain + cost
            end
        end
        -- Also catch <System Popup: Skill Activation | ... | Cost: N MP> format
        for cost_str in response:gmatch("<System%s*Popup:%s*Skill%s+Activation.-Cost:%s*(%d+)%s*MP") do
            local cost = tonumber(cost_str)
            if cost and cost > 0 then
                tags.mp_drain = tags.mp_drain + cost
            end
        end
    end
    if tags.stamina_drain == 0 then
        for cost_str in response:gmatch("<Skill%s+Name:.-|.-Cost:%s*(%d+)%s*Stamina") do
            local cost = tonumber(cost_str)
            if cost and cost > 0 then
                tags.stamina_drain = tags.stamina_drain + cost
            end
        end
    end

    -- <System: LEVEL UP | ...>
    if response:match("<System:%s*LEVEL%s+UP") then
        tags.level_up = true
    end

    return tags
end

function replaceHeroResource(response, label, new_current, new_max)
    local new_percent = math.floor(new_current / new_max * 100)
    local pattern
    if label == "Health Points" then
        pattern = "(Health%s+Points%s+)%d+%%:%s*%d+/%d+"
    elseif label == "Magic Points" then
        pattern = "(Magic%s+Points%s+)%d+%%:%s*%d+/%d+"
    elseif label == "Stamina" then
        pattern = "(Stamina%s+)%d+%%:%s*%d+/%d+"
    else
        return response
    end

    return response:gsub(pattern, function(prefix)
        return prefix .. string.format("%d%%: %d/%d", new_percent, new_current, new_max)
    end, 1)
end

function enforceResources(state, hero, response, accessKey)
    local hero_name = hero.name or state.hero_name or ""
    if hero.name and hero.name ~= "" then state.hero_name = hero.name end

    -- Initialize resources from first Hero block seen
    if not state.resources_initialized then
        if hero.hp_current and hero.hp_max then
            state.hp_current = hero.hp_current
            state.hp_max = hero.hp_max
        end
        if hero.mp_current and hero.mp_max then
            state.mp_current = hero.mp_current
            state.mp_max = hero.mp_max
        end
        if hero.stamina_current and hero.stamina_max then
            state.stamina_current = hero.stamina_current
            state.stamina_max = hero.stamina_max
        end
        state.resources_initialized = true
        logValidation(state, string.format(
            "Resources initialized: HP %d/%d MP %d/%d Stam %d/%d",
            state.hp_current, state.hp_max,
            state.mp_current, state.mp_max,
            state.stamina_current, state.stamina_max
        ))
        return response
    end

    local tags = parseResourceTags(response, hero_name, state)

    -- Level up: accept new max from Hero block, full restore
    if tags.level_up then
        if hero.hp_max then state.hp_max = hero.hp_max end
        if hero.mp_max then state.mp_max = hero.mp_max end
        if hero.stamina_max then state.stamina_max = hero.stamina_max end
        state.hp_current = state.hp_max
        state.mp_current = state.mp_max
        state.stamina_current = state.stamina_max
        logValidation(state, string.format(
            "LEVEL UP: Resources restored to HP %d MP %d Stam %d",
            state.hp_max, state.mp_max, state.stamina_max
        ))
        return response
    end

    -- Accept max changes from Hero block (equipment, buffs, etc.)
    if hero.hp_max and hero.hp_max ~= state.hp_max then
        logValidation(state, string.format("HP max changed: %d -> %d", state.hp_max, hero.hp_max))
        state.hp_max = hero.hp_max
    end
    if hero.mp_max and hero.mp_max ~= state.mp_max then
        logValidation(state, string.format("MP max changed: %d -> %d", state.mp_max, hero.mp_max))
        state.mp_max = hero.mp_max
    end
    if hero.stamina_max and hero.stamina_max ~= state.stamina_max then
        logValidation(state, string.format("Stamina max changed: %d -> %d", state.stamina_max, hero.stamina_max))
        state.stamina_max = hero.stamina_max
    end

    -- Compute expected MP
    local has_mp_event = (tags.mp_drain > 0 or tags.mp_set_value ~= nil)
    local expected_mp
    if tags.mp_set_value then
        expected_mp = tags.mp_set_value
    elseif tags.mp_drain > 0 then
        expected_mp = state.mp_current - tags.mp_drain
    else
        expected_mp = state.mp_current
    end
    expected_mp = math.max(0, math.min(expected_mp, state.mp_max))

    -- Compute expected HP
    local has_hp_event = (tags.hp_drain > 0 or tags.hp_heal > 0)
    local expected_hp = state.hp_current - tags.hp_drain + tags.hp_heal
    expected_hp = math.max(0, math.min(expected_hp, state.hp_max))

    -- Validate stamina drain sources — reject non-physical drains
    local validated_stamina_drain = 0
    if tags.stamina_drain > 0 then
        local source_lower = (tags.stamina_drain_source or ""):lower()
        local is_invalid = false
        for invalid_src, _ in pairs(INVALID_STAMINA_DRAIN_SOURCES) do
            if source_lower:find(invalid_src, 1, true) then
                is_invalid = true
                break
            end
        end
        if is_invalid then
            logValidation(state, string.format(
                "STAMINA DRAIN REJECTED: %d from '%s' (non-physical activity)",
                tags.stamina_drain, tags.stamina_drain_source or "unknown"
            ))
        else
            validated_stamina_drain = tags.stamina_drain
        end
    end

    -- Compute expected Stamina using absolute values (matching lorebook)
    local has_stamina_event = (validated_stamina_drain > 0 or tags.has_combat
                               or tags.physical_skill_count > 0)
    local expected_stamina = state.stamina_current - validated_stamina_drain
    if tags.has_combat then
        local combat_drain = math.min(25, math.max(10, 15))
        expected_stamina = expected_stamina - combat_drain
    end
    if tags.physical_skill_count > 0 then
        local skill_drain = tags.physical_skill_count * math.min(8, math.max(3, 5))
        expected_stamina = expected_stamina - skill_drain
    end

    -- Detect stamina recovery events
    local recovery_amount = 0
    if tags.stamina_recovery then
        recovery_amount = tags.stamina_recovery
        has_stamina_event = true
        expected_stamina = expected_stamina + recovery_amount
        logValidation(state, string.format(
            "STAMINA RECOVERY: +%d (source: %s)",
            recovery_amount, tags.stamina_recovery_source or "rest"
        ))
    end

    expected_stamina = math.max(0, math.min(expected_stamina, state.stamina_max))

    local modified = false

    -- Enforce MP
    if hero.mp_current then
        if tags.mp_set_value then
            -- Explicit target value: enforce exactly
            if hero.mp_current ~= expected_mp then
                logValidation(state, string.format(
                    "MP ENFORCED (set): %d/%d -> %d/%d",
                    hero.mp_current, hero.mp_max or state.mp_max,
                    expected_mp, state.mp_max
                ))
                response = replaceHeroResource(response, "Magic Points", expected_mp, state.mp_max)
                modified = true
            end
        elseif tags.mp_drain > 0 then
            if hero.mp_current > expected_mp then
                -- LLM didn't apply drain: enforce
                logValidation(state, string.format(
                    "MP ENFORCED: %d/%d -> %d/%d (drain:%d)",
                    hero.mp_current, hero.mp_max or state.mp_max,
                    expected_mp, state.mp_max, tags.mp_drain
                ))
                response = replaceHeroResource(response, "Magic Points", expected_mp, state.mp_max)
                modified = true
            elseif hero.mp_current < expected_mp then
                -- LLM drained more than tagged: accept
                expected_mp = hero.mp_current
            end
        else
            -- No drain tags: accept hero value (recovery or untagged change)
            if hero.mp_current ~= state.mp_current then
                if hero.mp_current > state.mp_current then
                    logValidation(state, string.format(
                        "MP RESTORED: %d -> %d (accepted)", state.mp_current, hero.mp_current
                    ))
                end
                expected_mp = hero.mp_current
            end
        end
    end

    -- Enforce HP
    if hero.hp_current then
        if has_hp_event then
            if hero.hp_current > expected_hp then
                logValidation(state, string.format(
                    "HP ENFORCED: %d/%d -> %d/%d (dmg:%d heal:%d)",
                    hero.hp_current, hero.hp_max or state.hp_max,
                    expected_hp, state.hp_max, tags.hp_drain, tags.hp_heal
                ))
                response = replaceHeroResource(response, "Health Points", expected_hp, state.hp_max)
                modified = true
            elseif hero.hp_current < expected_hp then
                expected_hp = hero.hp_current
            end
        else
            if hero.hp_current ~= state.hp_current then
                if hero.hp_current > state.hp_current then
                    logValidation(state, string.format(
                        "HP RESTORED: %d -> %d (accepted)", state.hp_current, hero.hp_current
                    ))
                end
                expected_hp = hero.hp_current
            end
        end
    end

    -- Enforce Stamina
    if hero.stamina_current then
        if has_stamina_event then
            if hero.stamina_current > expected_stamina then
                logValidation(state, string.format(
                    "STAMINA ENFORCED: %d/%d -> %d/%d (drain:%d combat:%s phys:%d)",
                    hero.stamina_current, hero.stamina_max or state.stamina_max,
                    expected_stamina, state.stamina_max, tags.stamina_drain,
                    tags.has_combat and "yes" or "no", tags.physical_skill_count
                ))
                response = replaceHeroResource(response, "Stamina", expected_stamina, state.stamina_max)
                modified = true
            elseif hero.stamina_current < expected_stamina then
                expected_stamina = hero.stamina_current
            end
        else
            if hero.stamina_current ~= state.stamina_current then
                if hero.stamina_current > state.stamina_current then
                    logValidation(state, string.format(
                        "STAMINA RESTORED: %d -> %d (accepted)", state.stamina_current, hero.stamina_current
                    ))
                end
                expected_stamina = hero.stamina_current
            end
        end
    end

    -- Always validate displayed percentages (Issue #8)
    -- Correct any percentage display even when no drain/heal event occurred
    local function validatePercent(label, cur, mx)
        local correct_pct = math.floor(cur / mx * 100)
        local pat
        if label == "Health Points" then
            pat = "Health%s+Points%s+(%d+)%%:%s*%d+/%d+"
        elseif label == "Magic Points" then
            pat = "Magic%s+Points%s+(%d+)%%:%s*%d+/%d+"
        elseif label == "Stamina" then
            pat = "Stamina%s+(%d+)%%:%s*%d+/%d+"
        end
        if pat then
            local shown_pct = response:match(pat)
            if shown_pct and tonumber(shown_pct) ~= correct_pct then
                logValidation(state, string.format(
                    "%s PERCENT CORRECTED: %s%% -> %d%% (%d/%d)",
                    label:upper(), shown_pct, correct_pct, cur, mx
                ))
                response = replaceHeroResource(response, label, cur, mx)
                modified = true
            end
        end
    end
    validatePercent("Health Points", expected_hp, state.hp_max)
    validatePercent("Magic Points", expected_mp, state.mp_max)
    validatePercent("Stamina", expected_stamina, state.stamina_max)

    -- Update state
    state.hp_current = expected_hp
    state.mp_current = expected_mp
    state.stamina_current = expected_stamina

    -- Write modified response back to chat
    if modified then
        local chatLen = getChatLength(accessKey)
        for i = chatLen - 1, 0, -1 do
            local msg = getChat(accessKey, i)
            if msg and msg.role == "char" then
                setChat(accessKey, i, response)
                break
            end
        end
    end

    return response
end

--------------------------------------------------------------------------------
-- DEBUG DUMP
--------------------------------------------------------------------------------

function formatClock12(hour, minute)
    local h = hour % 12
    if h == 0 then h = 12 end
    local ampm = hour < 12 and "AM" or "PM"
    return string.format("%d:%02d%s", h, minute, ampm)
end

function dumpState(state)
    local lines = {}
    table.insert(lines, "=== LUA STATE DUMP (v" .. tostring(state.schema_version) .. ") ===")
    table.insert(lines, string.format("Level: %d | EXP: %d/%d | Fame: %d",
        state.level, state.exp_current, state.exp_denominator, state.fame or 0))
    table.insert(lines, string.format("Day: %d (%s) | Season: %s",
        state.campaign_day, state.day_of_week, state.season))
    table.insert(lines, string.format("Clock: %s | Elapsed: %.1f hrs",
        formatClock12(state.clock_hour, state.clock_minute),
        state.in_game_hours_elapsed))
    table.insert(lines, string.format("Weather: %s%s (%.1f hrs since change, max %d)",
        state.weather,
        state.weather_is_storm and " [STORM]" or "",
        state.in_game_hours_elapsed - state.weather_last_change_hour,
        state.weather_is_storm and 12 or 4))
    table.insert(lines, string.format("Currency: B:%d S:%d G:%d St:%d",
        state.bronze, state.silver, state.gold, state.stellar))
    table.insert(lines, string.format("HP: %d/%d | MP: %d/%d | Stamina: %d/%d%s",
        state.hp_current, state.hp_max,
        state.mp_current, state.mp_max,
        state.stamina_current, state.stamina_max,
        state.resources_initialized and "" or " [NOT INIT]"))
    table.insert(lines, string.format("Daily: EXP events %d/3 | Fame events %d/1",
        state.exp_events_today, state.fame_events_today))
    table.insert(lines, string.format("Hash: %s",
        tostring(state.last_output_hash):sub(1, 12)))

    if state.companions then
        local comp_count = 0
        for k, v in pairs(state.companions) do
            comp_count = comp_count + 1
            table.insert(lines, string.format("  Companion: %s Lv%d", k, v.level or 0))
        end
        if comp_count == 0 then
            table.insert(lines, "  Companions: none tracked")
        end
    end

    if state.skills then
        local skill_count = 0
        local skill_lines = {}
        for name, skill in pairs(state.skills) do
            skill_count = skill_count + 1
            if skill.rank then
                table.insert(skill_lines, string.format("  %s: %s %d/%d",
                    name, skill.rank, skill.progress or 0, skill.progress_max or 100))
            else
                table.insert(skill_lines, string.format("  %s (Passive)", name))
            end
        end
        table.insert(lines, string.format("Skills: %d tracked", skill_count))
        table.sort(skill_lines)
        for _, sl in ipairs(skill_lines) do
            table.insert(lines, sl)
        end
    else
        table.insert(lines, "Skills: none tracked")
    end

    if state.validation_log and #state.validation_log > 0 then
        table.insert(lines, "")
        table.insert(lines, "--- Last 5 validation entries ---")
        local start = math.max(1, #state.validation_log - 4)
        for i = start, #state.validation_log do
            table.insert(lines, string.format("  [%d] %s", i, state.validation_log[i].msg))
        end
    else
        table.insert(lines, "")
        table.insert(lines, "No validation errors recorded.")
    end

    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- DAY OF WEEK HELPER
--------------------------------------------------------------------------------

function advanceDayOfWeek(current)
    for i, d in ipairs(DAYS_OF_WEEK) do
        if d == current then
            return DAYS_OF_WEEK[(i % 7) + 1]
        end
    end
    return "Monday"
end

--------------------------------------------------------------------------------
-- HOOK: onStart (also handles OOC commands)
-- Saves a turn snapshot so that rerolls recalculate from the same
-- starting point. getUserLastMessage() returns the current input.
-- stopChat() is respected here, preventing the LLM call.
--------------------------------------------------------------------------------

function onStart(accessKey)
    local state = loadState(accessKey)
    if state == nil then
        state = buildDefaultState()
    end

    -- Read user message for regeneration detection
    local msg = getUserLastMessage(accessKey)
    local msg_hash = nil
    if msg and msg ~= "" then
        msg_hash = computeHash(msg)
    end

    -- REGENERATION DETECTION: If same user message AND we have an
    -- existing snapshot, restore from it first. This undoes the
    -- mutations from the discarded response so the new snapshot
    -- captures the correct pre-response baseline.
    if msg_hash and state.last_user_msg_hash == msg_hash
       and state.turn_snapshot then
        restoreFromSnapshot(state)
    end

    -- Save turn snapshot for reroll protection
    state.turn_snapshot = createTurnSnapshot(state)
    if msg_hash then
        state.last_user_msg_hash = msg_hash
    end
    saveState(accessKey, state)

    -- Check for OOC slash commands
    if msg == nil or msg == "" then return end

    local cmd = msg:match("^%s*/(%w+)")
    if cmd == nil then return end

    if cmd == "lua" or cmd == "debug" then
        local dump = dumpState(state)
        addChat(accessKey, "char", dump)
        stopChat(accessKey)

    elseif cmd == "luareset" then
        state = buildDefaultState()
        saveState(accessKey, state)
        addChat(accessKey, "char", "Lua state reset to defaults.")
        stopChat(accessKey)

    elseif cmd == "luaday" then
        state.last_campaign_day = state.campaign_day
        state.campaign_day = state.campaign_day + 1
        state.day_of_week = advanceDayOfWeek(state.day_of_week)
        state.season = dayToSeason(state.campaign_day)
        state.exp_events_today = 0
        state.fame_events_today = 0
        saveState(accessKey, state)
        addChat(accessKey, "char", string.format(
            "Advanced to Day %d (%s, %s).",
            state.campaign_day, state.day_of_week, state.season
        ))
        stopChat(accessKey)

    elseif cmd == "luaclear" then
        state.validation_log = {}
        saveState(accessKey, state)
        addChat(accessKey, "char", "Validation log cleared.")
        stopChat(accessKey)

    elseif cmd == "luaset" then
        local field, value = msg:match("/luaset%s+(%w+)%s+(.+)")
        if field and value then
            if field == "level" then
                local n = tonumber(value)
                if n then
                    state.level = n
                    state.exp_denominator = EXP_DENOMINATORS[n] or 5000
                end
            elseif field == "exp" then
                local n = tonumber(value)
                if n then state.exp_current = n end
            elseif field == "day" then
                local n = tonumber(value)
                if n then
                    state.campaign_day = n
                    state.season = dayToSeason(n)
                end
            elseif field == "bronze" then
                local n = tonumber(value)
                if n then state.bronze = n end
            elseif field == "silver" then
                local n = tonumber(value)
                if n then state.silver = n end
            elseif field == "gold" then
                local n = tonumber(value)
                if n then state.gold = n end
            elseif field == "stellar" then
                local n = tonumber(value)
                if n then state.stellar = n end
            elseif field == "weather" then
                state.weather = value
            elseif field == "fame" then
                local n = tonumber(value)
                if n then state.fame = n end
            elseif field == "clock" then
                local h, m = parseClock(value)
                if h then
                    state.clock_hour = h
                    state.clock_minute = m
                end
            elseif field == "hp" then
                local n = tonumber(value)
                if n then state.hp_current = n end
            elseif field == "mp" then
                local n = tonumber(value)
                if n then state.mp_current = n end
            elseif field == "stamina" then
                local n = tonumber(value)
                if n then state.stamina_current = n end
            elseif field == "hpmax" then
                local n = tonumber(value)
                if n then state.hp_max = n end
            elseif field == "mpmax" then
                local n = tonumber(value)
                if n then state.mp_max = n end
            elseif field == "staminamax" then
                local n = tonumber(value)
                if n then state.stamina_max = n end
            end
            saveState(accessKey, state)
            addChat(accessKey, "char", string.format("Set %s = %s", field, value))
            stopChat(accessKey)
        else
            addChat(accessKey, "char", "Usage: /luaset <field> <value>\nFields: level, exp, day, bronze, silver, gold, stellar, weather, fame, clock, hp, mp, stamina, hpmax, mpmax, staminamax")
            stopChat(accessKey)
        end
    end
end

--------------------------------------------------------------------------------
-- HOOK: onOutput (main pipeline)
--------------------------------------------------------------------------------

function onOutput(accessKey)
    local state = loadState(accessKey)
    if state == nil then
        state = buildDefaultState()
    end

    local response = getCharacterLastMessage(accessKey)
    if response == nil or response == "" then
        saveState(accessKey, state)
        return
    end

    -- REROLL GUARD (skip if exact same response fires twice)
    local responseHash = computeHash(response)
    if state.last_output_hash == responseHash then
        return
    end
    state.last_output_hash = responseHash

    -- CREATE IMPLICIT SNAPSHOT FOR FIRST TURN (greeting/pre-onStart)
    if state.turn_snapshot == nil then
        state.turn_snapshot = createTurnSnapshot(state)
    end

    -- RESTORE FROM TURN SNAPSHOT (undo previous reroll's mutations)
    restoreFromSnapshot(state)

    -- PARSE HERO BLOCK
    local hero = parseHeroBlock(response)
    if hero == nil then
        if response:match("^%s*<Target:") or
           response:match("^%s*=== LUA STATE") or
           response:match("^%s*Lua state") or
           response:match("^%s*Set %w+ =") then
            saveState(accessKey, state)
            return
        end
        logValidation(state, "Missing <Hero:> block in response")
        saveState(accessKey, state)
        return
    end

    -- Save pre-validation values for Phase 2 delta detection
    local prev_level = state.level
    local prev_exp = state.exp_current
    local prev_fame = state.fame or 0
    local prev_campaign_day = state.campaign_day

    -- PHASE 1: VALIDATE
    validateExpDenominator(state, hero)
    validateCurrencyNonNegative(state, hero)
    validateCampaignDay(state, hero)
    validateLevelConsistency(state, hero)
    validateCompanionLevels(state, response)

    -- PHASE 2: CALCULATE
    advanceTime(state, hero, prev_campaign_day)
    trackExpChanges(state, hero, prev_level, prev_exp)
    trackFameChanges(state, hero, prev_fame)
    enforceWeatherReroll(state, hero)
    trackSkillChanges(state, hero.skills or {})

    -- PHASE 3: ENFORCE RESOURCES
    response = enforceResources(state, hero, response, accessKey)

    -- Update tracked state from hero block
    if hero.exp_current then state.exp_current = hero.exp_current end
    if hero.bronze then state.bronze = hero.bronze end
    if hero.silver then state.silver = hero.silver end
    if hero.gold then state.gold = hero.gold end
    if hero.stellar then state.stellar = hero.stellar end
    if hero.weather then state.weather = hero.weather end
    if hero.season then state.season = hero.season end
    if hero.day_of_week then state.day_of_week = hero.day_of_week end
    if hero.fame then state.fame = hero.fame end

    -- SAVE STATE
    saveState(accessKey, state)
end

--------------------------------------------------------------------------------
-- HOOK: onInput (no-op -- commands moved to onStart)
--------------------------------------------------------------------------------

function onInput(accessKey)
    -- intentionally empty
end
