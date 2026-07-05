Scriptname SNConsume_PlayerAlias extends ReferenceAlias
{Reports the player's consumption of potions, food, and raw ingredients to SkyrimNet
 as passive awareness events (same idiom as SeverActions' trade events). No forced NPC
 reaction -- the fact simply enters SkyrimNet's event stream so nearby NPCs may reference it.

 Batching uses a REAL-TIME timer that is timescale-independent:
   * The Papyrus VM halts while a menu pauses the game, so RegisterForSingleUpdate cannot tick
     inside the (paused) inventory/favorites menu. Everything chugged there buffers and flushes
     as ONE grouped event -- driven by OnMenuClose (immediate), or by the timer resuming ~a few
     seconds after close if OnMenuClose doesn't deliver.
   * While unpaused (e.g. SkyUI item hotkeys mid-combat), consumptions within GroupWindowSeconds
     of each other coalesce into one event.
   * Because the window is real seconds (not game-hours), behavior is IDENTICAL at any timescale
     -- including timescale 1, where a game-time window would have ballooned to ~72s.
 Duplicates collapse as "(xN)".}

; Real seconds to wait after the LAST consumption before flushing (unpaused path).
; The Papyrus VM freezes during paused menus, so this timer can't fire mid-menu regardless.
Float Property GroupWindowSeconds = 4.0 Auto

; How long (ms) a consumption stays in SkyrimNet scene context. Within this window the
; native reaction/thought system can act on it. The reaction cadence itself is a native
; SkyrimNet setting, not controlled here.
Int Property SceneTTLms = 60000 Auto

; DEBUG: when true, shows an on-screen + log line for every consumption. Off for normal play.
Bool Property DebugNotify = false Auto

; Verb buckets
Int Property VERB_DRANK    = 0 AutoReadOnly Hidden
Int Property VERB_ATE      = 1 AutoReadOnly Hidden
Int Property VERB_ATE_RAW  = 2 AutoReadOnly Hidden

String[] pendNames
Int[]    pendVerbs
Int      pendCount = 0

; --- Lifecycle: (re)register for the menus we early-flush on ---

Event OnInit()
    RegisterMenus()
    RegisterDecorators()
    RegisterConsumeSchemas()
EndEvent

Event OnPlayerLoadGame()
    RegisterMenus()
    RegisterDecorators()
    RegisterConsumeSchemas()
EndEvent

Function RegisterMenus()
    RegisterForMenu("InventoryMenu")
    RegisterForMenu("FavoritesMenu")
EndFunction

; SkyrimNet decorators must be re-registered every load (they don't survive a reload).
Function RegisterDecorators()
    SkyrimNetApi.RegisterDecorator("snpn_drunk", "SNConsume_PlayerAlias", "SNPN_Drunk")
    SkyrimNetApi.RegisterDecorator("snpn_holds_liquor", "SNConsume_PlayerAlias", "SNPN_HoldsLiquor")
EndFunction

; Register SkyrimNet event SCHEMAS for our consumption event types. This is the mechanism
; (the same one MTF uses for its "Magic Tattoo Change" entry) that surfaces each type as a
; first-class, friendly-named row in SkyrimNet Settings -> Events & Reactions -> Player
; Reactions -- so the player configures the response (thought/audible), probability and
; cooldown THERE, natively, with no hardcoded trigger in this script. Each schema uses a
; single passthrough {{text}} field so our plain sentence renders verbatim. Re-registered
; every load (idempotent; cheap).
Function RegisterConsumeSchemas()
    SNPN_RegSchema("player_ate_food",       "Player Ate Food")
    SNPN_RegSchema("player_drank_potion",   "Player Drank Potion")
    SNPN_RegSchema("player_ate_ingredient", "Player Ate Ingredient")
    SNPN_RegSchema("player_consumed",       "Player Consumed (Mixed)")
EndFunction

Function SNPN_RegSchema(String eventType, String displayName)
    String fields = "[{\"name\":\"text\",\"type\":0,\"required\":true,\"description\":\"Consumption summary sentence\"}]"
    String templates = "{\"recent_events\":\"{{text}}\",\"raw\":\"{{text}}\",\"compact\":\"{{text}}\",\"verbose\":\"{{text}}\"}"
    ; isEphemeral=true (scene-context only), defaultTTLMs=SceneTTLms, shortLivedEnabled=true, interrupt=false
    SkyrimNetApi.RegisterEventSchema(eventType, displayName, "Player consumption reported by SkyrimNet Player Needs.", fields, templates, true, SceneTTLms, true, false)
EndFunction

Event OnMenuClose(String menuName)
    ; Whatever was consumed inside the (paused) menu flushes as one batch on exit.
    Flush()
EndEvent

; --- Consume detection ---
; Consuming a potion/food/ingredient EQUIPS it, firing OnObjectEquipped exactly once per
; consume. This is far cleaner than OnItemRemoved, which (with survival/eating-animation mods
; present) fires 2+ times per consume AND also fires on drop/sell. Equipping only happens on
; USE, so there's no drop-vs-consume heuristic to get wrong and no phantom double-count.
; (This is the same hook Survival Mode's own food-poisoning script uses to detect eating.)

Event OnObjectEquipped(Form akBaseObject, ObjectReference akReference)
    if akBaseObject == None
        return
    endif

    Int verb = -1
    Potion asPotion = akBaseObject as Potion
    if asPotion
        if asPotion.IsPoison()
            return ; poisons are applied to weapons, not consumed
        elseif asPotion.IsFood()
            verb = VERB_ATE
        else
            verb = VERB_DRANK
        endif
    elseif (akBaseObject as Ingredient)
        verb = VERB_ATE_RAW
    else
        return ; not a consumable (weapon/armor/etc.) -- ignore
    endif

    String itemName = akBaseObject.GetName()
    if itemName == ""
        return ; unnamed / junk form
    endif

    ; --- DEBUG INSTRUMENTATION (toggle off via DebugNotify once verified) ---
    if DebugNotify
        String dbg = "SNC ate/drank: '" + itemName + "' verb=" + verb
        Debug.Notification(dbg)
        Debug.Trace(dbg)
    endif
    ; --- END DEBUG ---

    QueueItem(itemName, verb)
EndEvent

Function QueueItem(String itemName, Int verb)
    if pendNames.Length == 0
        pendNames = new String[128]
        pendVerbs = new Int[128]
        pendCount = 0
    endif
    if pendCount < 128
        pendNames[pendCount] = itemName
        pendVerbs[pendCount] = verb
        pendCount += 1
    endif
    ; Real-time timer: the VM is frozen during paused menus, so this can't fire mid-menu;
    ; menu chugging accumulates and flushes on menu close (or on timer resume after close).
    RegisterForSingleUpdate(GroupWindowSeconds)
EndFunction

Event OnUpdate()
    Flush()
EndEvent

Function Flush()
    if pendCount <= 0
        return
    endif

    ; Snapshot & reset first, so any consume during formatting starts a fresh batch.
    Int total = pendCount
    String[] names = pendNames
    Int[] verbs = pendVerbs
    pendNames = new String[128]
    pendVerbs = new Int[128]
    pendCount = 0

    String drinks = BuildBucket(names, verbs, total, VERB_DRANK)
    String foods  = BuildBucket(names, verbs, total, VERB_ATE)
    String raws   = BuildBucket(names, verbs, total, VERB_ATE_RAW)

    Actor player = Game.GetPlayer()
    String pname = player.GetDisplayName()
    String content = pname + " "
    Bool needSep = false

    if drinks != ""
        content += "drank " + drinks
        needSep = true
    endif
    if foods != ""
        if needSep
            content += "; "
        endif
        content += "ate " + foods
        needSep = true
    endif
    if raws != ""
        if needSep
            content += "; "
        endif
        content += "consumed " + raws
        needSep = true
    endif
    content += "."

    ; Specific event type when the batch is a single category; generic otherwise.
    String eventType = "player_consumed"
    if drinks != "" && foods == "" && raws == ""
        eventType = "player_drank_potion"
    elseif foods != "" && drinks == "" && raws == ""
        eventType = "player_ate_food"
    elseif raws != "" && drinks == "" && foods == ""
        eventType = "player_ate_ingredient"
    endif

    ; Scene-context (short-lived) TYPED event: this is what puts the consumption in front of
    ; SkyrimNet's NATIVE World Event Reactions / thought system. Because eventType has a
    ; registered schema, it shows up in the Player Reactions table, and whether a nearby NPC
    ; or the player reacts/thinks -- and how often -- is governed by the user's own settings
    ; there (no hardcoded chance/cooldown). Content is passed BOTH as the description and as
    ; the schema's {{text}} data field so it renders verbatim. The reused eventId keeps only
    ; the latest consumption in scene context (avoids clutter); SceneTTLms = how long it stays.
    String data = "{\"text\":\"" + SNPN_JsonEscape(content) + "\"}"
    SkyrimNetApi.RegisterShortLivedEvent("player_consume", eventType, content, data, SceneTTLms, player, None)

    ; Durable memory/history so an NPC can recall it later ("you're always chugging potions").
    ; Uses RegisterPersistentEvent (untyped, plain content) -- MTF's pattern -- so the durable
    ; record is never affected by the typed schema's template (which could otherwise render an
    ; empty history entry for a plain-content event).
    SkyrimNetApi.RegisterPersistentEvent(content, player, None)
EndFunction

; Returns a comma-separated list of items matching wantVerb, collapsing duplicates as
; "Name (xN)". Destructively blanks matched duplicate slots in names[] (scratch copy).
String Function BuildBucket(String[] names, Int[] verbs, Int total, Int wantVerb)
    String result = ""
    Int i = 0
    while i < total
        if verbs[i] == wantVerb && names[i] != ""
            String nm = names[i]
            Int c = 1
            Int j = i + 1
            while j < total
                if verbs[j] == wantVerb && names[j] == nm
                    c += 1
                    names[j] = "" ; mark consumed so it isn't listed again
                endif
                j += 1
            endWhile
            String piece = nm
            if c > 1
                piece = nm + " (x" + c + ")"
            endif
            if result == ""
                result = piece
            else
                result = result + ", " + piece
            endif
        endif
        i += 1
    endWhile
    return result
EndFunction

; =============================================================================
; DECORATOR: snpn_drunk(actorUUID) -> intoxication score (as string) for ANY actor
; -----------------------------------------------------------------------------
; Portable, cross-modlist drunk detection. Whichever supported survival/alcohol mod is
; installed drives the score; a plugin that isn't installed resolves to None via
; GetFormFromFile and is skipped, so this works unchanged on other modlists.
;
; The returned number lands on the prompt's (0173_snpn_intoxication) 25/50/75/100 tier
; scale: <25 sober, >=25 tipsy, >=50 drunk, >=75 very drunk, >=100 blind drunk.
;
; RESOLUTION when SEVERAL alcohol mods are installed at once: MORE DETAILED MOD WINS.
; The systems are probed MOST-GRANULAR -> LEAST-GRANULAR, and the FIRST one that is
; actually REPORTING intoxication (>0) is returned -- so a fine-grained reading (e.g.
; Requiem's exact 0-127 rank) always beats a coarser one (e.g. a binary "drunk"). Two
; further rules keep it honest:
;   * A more-detailed system that is installed but reads SOBER does NOT mask a coarser
;     system that reads DRUNK -- on a 0 reading we fall through and keep looking, only
;     settling on "sober" once every precise system has been asked. (So detail decides
;     the WINNER among systems that disagree on the level, without a sober high-detail
;     system hiding a genuinely-drunk low-detail one.)
;   * The unverified fuzzy fallback is used ONLY when NO precise system is installed, so
;     its guesses can never override or false-positive against a real, precise system.
;
; Granularity order (each returns the moment it reports >0):
;   1. Requiem  -- REQ_Storage_Alcohol faction rank, RAW 0-127 returned directly (finest).
;   2. CACO     -- CACO_AlcoholDrunkFaction "inebriation points", tiers 10/20/30/40/50.
;   3. Last Seed-- _Seed_AttributeDrunk global (0-120), tiers 20/40/60/80/100.
;   4. Alcoholic Lite Effects -- 5 staged magic effects Drunk_Effect1..5 (check high->low).
;   5. Conner's -- CRSurvival_AlcoholDoseValue global (drinks; limit 4, hangover 5) + buzzed.
;   6. SunHelm  -- single binary "Intoxicated" effect -> "drunk".
;   7. Starfrost -- keyword MAG_DrinkAlcoholFortify (Simonrim, needs Gourmet); binary -> "drunk".
;   8. Fallback -- unverified best-effort binary net, ONLY if none of 1-7 is installed.
; 5-stage mods map onto the 4 prompt tiers as {stage1->25, 2->50, 3->65, 4->80, 5->100}.
; Drugs (skooma/cannabis) are intentionally NOT counted here -- alcohol only.
; Only the Requiem path is live-tested (the others' FormIDs are verified from serialized
; ESPs but those mods aren't in this modlist).
; =============================================================================
String Function SNPN_Drunk(Actor akActor) Global
    if !akActor
        return "0"
    endif

    Bool precise = false ; any precise (non-fuzzy) alcohol system installed? gates the fallback.

    ; 1. Requiem (finest): RAW faction rank 0-127, returned directly against 25/50/75/100.
    Int rank = SNPN_FacRank(akActor, 0xAD382D, "Requiem.esp")
    if rank > -2 ; faction form exists => Requiem installed
        precise = true
        if rank > 0 ; in the faction with a live rank => report it (else fall through as sober)
            return rank as String
        endif
    endif

    ; 2. CACO: inebriation-point faction rank. Tiers 10/20/30/40/50.
    Int caco = SNPN_FacRank(akActor, 0x2BBAB6, "Complete Alchemy & Cooking Overhaul.esp")
    if caco > -2
        precise = true
        Int cs = SNPN_Bucket(caco, 10, 20, 30, 40, 50)
        if cs > 0
            return cs as String
        endif
    endif

    ; 3. Last Seed: _Seed_AttributeDrunk global holds the 0-120 drunk value.
    Float ls = SNPN_GlobVal(0x010830, "LastSeed.esp")
    if ls > -1.0
        precise = true
        Int lss = SNPN_Bucket(ls as Int, 20, 40, 60, 80, 100)
        if lss > 0
            return lss as String
        endif
    endif

    ; 4. Alcoholic Lite Effects: 5 staged magic effects; highest present wins.
    if SNPN_FormPresent(0x805, "Alcoholic Lite Effects.esp")
        precise = true
        if SNPN_ChkEff(akActor, 0x809, "Alcoholic Lite Effects.esp")
            return "100"
        elseif SNPN_ChkEff(akActor, 0x808, "Alcoholic Lite Effects.esp")
            return "80"
        elseif SNPN_ChkEff(akActor, 0x807, "Alcoholic Lite Effects.esp")
            return "65"
        elseif SNPN_ChkEff(akActor, 0x806, "Alcoholic Lite Effects.esp")
            return "50"
        elseif SNPN_ChkEff(akActor, 0x805, "Alcoholic Lite Effects.esp")
            return "25"
        endif
    endif

    ; 5. Conner's Survival: a dose counter global (drinks). Limit 4, hangover 5.
    Float cd = SNPN_GlobVal(0x056993, "Conner's Survival Mode.esp")
    if cd > -1.0
        precise = true
        Int d = cd as Int
        if d >= 5
            return "100"
        elseif d >= 4
            return "80"
        elseif d >= 2
            return "50"
        elseif d >= 1
            return "25"
        elseif SNPN_ChkEff(akActor, 0x042571, "Conner's Survival Mode.esp")
            return "50" ; buzzed effect still up though counter already ticked to 0
        endif
    endif

    ; 6. SunHelm: single binary "Intoxicated" effect.
    if SNPN_FormPresent(0x36D062, "SunHelmSurvival.esp")
        precise = true
        if SNPN_ChkEff(akActor, 0x36D062, "SunHelmSurvival.esp")
            return "60"
        endif
    endif

    ; 7. Starfrost (Simonrim): being "Drunk" = an active magic effect carrying keyword
    ;    MAG_DrinkAlcoholFortify (ADA149, injected into Update.esm by Starfrost; needs Gourmet's
    ;    alcohol). This is exactly the condition Starfrost's own "Drunk" ability tests, so the
    ;    keyword IS the mod's authoritative intoxication signal. Flat, single-tier (Starfrost's
    ;    alcohol is a lite +25 Warmth buff, ungraduated) -> "drunk". Absent Starfrost, Update.esm
    ;    has no such form so GetFormFromFile returns None and this is skipped.
    if SNPN_FormPresent(0xADA149, "Update.esm")
        precise = true
        if SNPN_ChkKw(akActor, 0xADA149, "Update.esm")
            return "50"
        endif
    endif

    ; 8. Every precise system was asked and none reported intoxication.
    if precise
        return "0" ; a real, precise system is installed and reads sober -- trust it.
    endif

    ; 9. Last-resort binary net (unverified FormID guesses for other/older alcohol mods),
    ;    reached ONLY when no precise system is installed so it can't override a real one.
    if SNPN_HasAnyAlcohol(akActor)
        return "60"
    endif
    return "0"
EndFunction

; =============================================================================
; DECORATOR: snpn_holds_liquor(actorUUID) -> "1" if alcohol impairment is SUPPRESSED
; -----------------------------------------------------------------------------
; Requiem-specific. Perks/traits that "remove the negative effects of alcohol" -- the
; Alchemy tree's Drunken Combat perk (ranks 1/2), Biggie Traits' "Addict", and BOOB --
; all grant a constant ability carrying keyword REQ_DisableAlcoholBlur (AD3B45:Requiem.esp).
; That keyword cancels the drunk vision blur and turns intoxication into a combat buff, but
; it does NOT reduce the REQ_Storage_Alcohol rank -- so such a character reads as HIGH rank
; (snpn_drunk stays high) yet is functionally UNIMPAIRED. Checking the keyword catches all
; three grantor paths at once. The prompt uses this to say "holds their liquor" (warm, bold,
; but steady and sharp) instead of describing stumbling/slurring impairment.
; On non-Requiem modlists the keyword form is None, so this simply returns "0".
; (CACO instead lowers the rank GAIN via its tolerance faction, so its raw number already
;  reflects tolerance -- no equivalent check is needed there.)
; =============================================================================
String Function SNPN_HoldsLiquor(Actor akActor) Global
    if !akActor
        return "0"
    endif
    Keyword kw = Game.GetFormFromFile(0xAD3B45, "Requiem.esp") as Keyword
    if kw && akActor.HasMagicEffectWithKeyword(kw)
        return "1"
    endif
    return "0"
EndFunction

; Unverified best-effort coverage for mods not precisely mapped above.
Bool Function SNPN_HasAnyAlcohol(Actor a) Global
    return SNPN_ChkEff(a, 0x12C5, "alcoholiceffect.esp") || SNPN_ChkEff(a, 0xD62, "alcoholiceffect.esp") \
        || SNPN_ChkEff(a, 0xD62, "ADER.esp") \
        || SNPN_ChkEff(a, 0x3D4BC, "Animated Inebriation.esp") || SNPN_ChkEff(a, 0xD63, "Animated Inebriation.esp") \
        || SNPN_ChkEff(a, 0xC4F1, "iNeed.esp") \
        || SNPN_ChkEff(a, 0x12CB, "RealisticNeedsandDiseases.esp") || SNPN_ChkEff(a, 0x491B, "RealisticNeedsandDiseases.esp") \
        || SNPN_ChkEff(a, 0x31FD5, "Immersive Needs.esp") \
        || SNPN_ChkEff(a, 0x5E5A, "SLDrunkRedux.esp") || SNPN_ChkEff(a, 0x8EEE, "SLDrunkRedux.esp")
EndFunction

; Faction rank of a form-by-file. Returns -2 if the faction form doesn't exist (mod not
; installed); otherwise the rank (which is -1 when the actor isn't in the faction = sober).
Int Function SNPN_FacRank(Actor a, Int formID, String plugin) Global
    Faction f = Game.GetFormFromFile(formID, plugin) as Faction
    if !f
        return -2
    endif
    return a.GetFactionRank(f)
EndFunction

; Value of a GlobalVariable-by-file. Returns -1.0 if the global doesn't exist (mod not
; installed). A real drunk-counter global reads 0.0 when sober, which is > -1.0 and so is
; correctly treated as "installed, sober" -> bucket 0.
Float Function SNPN_GlobVal(Int formID, String plugin) Global
    GlobalVariable g = Game.GetFormFromFile(formID, plugin) as GlobalVariable
    if !g
        return -1.0
    endif
    return g.GetValue()
EndFunction

; Buckets a raw drunk value against five ascending thresholds onto the prompt's tier scale
; {tipsy 25, drunk 50, drunk-mid 65, very drunk 80, blind 100}; below t1 = sober (0).
Int Function SNPN_Bucket(Int v, Int t1, Int t2, Int t3, Int t4, Int t5) Global
    if v >= t5
        return 100
    elseif v >= t4
        return 80
    elseif v >= t3
        return 65
    elseif v >= t2
        return 50
    elseif v >= t1
        return 25
    endif
    return 0
EndFunction

Bool Function SNPN_ChkEff(Actor a, Int formID, String plugin) Global
    MagicEffect e = Game.GetFormFromFile(formID, plugin) as MagicEffect
    if e && a.HasMagicEffect(e)
        return true
    endif
    return false
EndFunction

; True if a form-by-file EXISTS in the load order (mod installed), regardless of whether any
; effect is currently active. Lets the effect/keyword-based systems mark themselves "present"
; (so the fuzzy fallback stays disabled) even when the actor is installed-but-sober.
Bool Function SNPN_FormPresent(Int formID, String plugin) Global
    return Game.GetFormFromFile(formID, plugin) != None
EndFunction

; True if the actor has an active magic effect carrying keyword formID-by-file. Returns false
; (form None) when the plugin/keyword isn't present, so it's safe on modlists lacking the mod.
Bool Function SNPN_ChkKw(Actor a, Int formID, String plugin) Global
    Keyword k = Game.GetFormFromFile(formID, plugin) as Keyword
    if k && a.HasMagicEffectWithKeyword(k)
        return true
    endif
    return false
EndFunction

Bool Function SNPN_ChkSpell(Actor a, Int formID, String plugin) Global
    Spell s = Game.GetFormFromFile(formID, plugin) as Spell
    if s && a.HasSpell(s)
        return true
    endif
    return false
EndFunction

; Minimal JSON string escaper (backslash + double-quote) so our content can be embedded as a
; {"text":"..."} value for the schema's {{text}} template. Skyrim item/actor names practically
; never contain these, but we escape defensively to keep the data JSON valid.
String Function SNPN_JsonEscape(String s) Global
    Int n = StringUtil.GetLength(s)
    Int i = 0
    String out = ""
    while i < n
        String c = StringUtil.GetNthChar(s, i)
        if c == "\""
            out += "\\\""
        elseif c == "\\"
            out += "\\\\"
        else
            out += c
        endif
        i += 1
    endWhile
    return out
EndFunction
