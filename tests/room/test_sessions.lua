-- luacheck: globals TestRouteRoomSessions
local lu = require("luaunit")
local room = require("mods.room.session")
local coordinator = require("mods.room.coordinator")
local route = require("mods.route.session")
local bindings = require("mods.room.timeline.bindings")
local timeline = require("mods.room.timeline.session")

TestRouteRoomSessions = {}

local handlesBySession = setmetatable({}, { __mode = "k" })

function TestRouteRoomSessions.testRoomSessionsOwnTheirInnerTimelineState()
    local empty = {
        transactionsByOwner = {},
        timeline = { transactions = {}, dependencies = {}, obligations = {} },
    }
    local first = room.new(empty)
    local second = room.new(empty)
    lu.assertFalse(rawequal(first._timeline, second._timeline))
    room.dispose(first)
    lu.assertNotNil(second._timeline)
    lu.assertNil(first._timeline)
end

local function newSession(entry)
    for owner, transaction in pairs(entry.transactionsByOwner) do
        transaction.generationKey = transaction.generationKey or "test:" .. owner
    end
    local envelope = room.new(entry, assert(bindings.index(entry)))
    local port = envelope._timeline
    local handles = {}
    for owner, transaction in pairs(entry.transactionsByOwner) do
        handles[owner] = assert(timeline.resolve(port, bindings.resolve,
            { kind = "generation", generationKey = transaction.generationKey }))
    end
    handlesBySession[envelope] = handles
    return envelope
end

local function complete(session, owner)
    return room.complete(session, handlesBySession[session][owner])
end

local function occurrence()
    local optional, required, dependent = "optional", "required", "dependent"
    return {
        id = "one", gameName = "F_Test", transactionsByOwner = {
            [optional] = { owner = optional, window = { kind = "standard", phase = "beforeCombat" } },
            [required] = { owner = required, window = { kind = "standard", phase = "beforeCombat" } },
            [dependent] = { owner = dependent, window = { kind = "standard", phase = "beforeCombat" } },
        },
        timeline = {
            dependencies = { { owner = dependent, afterOwner = optional } },
            obligations = { { owner = required, checkpoint = "roomExit" } },
        },
        roomExitConformance = { facts = { { kind = "forfeit" } } },
        conformanceExpected = { forfeit = "inactive" },
    }
end

function TestRouteRoomSessions.testOptionalOwnerDoesNotBlockClosureButBlocksItsDependent()
    local session = newSession(occurrence())
    lu.assertTrue(room.openWindow(session, "roomEntered"))
    lu.assertNil(complete(session, "dependent"))
    lu.assertEquals(session.firstMismatch.checkpoint, "transaction-prerequisite")
    local closeable = newSession(occurrence())
    room.openWindow(closeable, "roomEntered")
    lu.assertTrue(complete(closeable, "required"))
    lu.assertTrue(room.close(closeable, function() return true end))
end

function TestRouteRoomSessions.testCompletedNativeBindingCanYieldToAReadySeaStarDuplicate()
    local entry = occurrence()
    entry.transactionsByOwner = {
        source = {
            owner = "source", generationKey = "test:source", gameName = "RoomMoneyDrop",
            window = { kind = "standard", phase = "beforeCombat" },
        },
        duplicate = {
            owner = "duplicate", generationKey = "test:duplicate", gameName = "RoomMoneyDrop",
            window = { kind = "standard", phase = "beforeCombat" },
        },
    }
    entry.timeline = {
        transactions = { entry.transactionsByOwner.source, entry.transactionsByOwner.duplicate },
        dependencies = { { owner = "duplicate", afterOwner = "source" } }, obligations = {},
    }
    local port = timeline.new(entry, assert(bindings.index(entry)))
    local source = assert(timeline.resolve(port, bindings.resolve, { kind = "generation", generationKey = "test:source" }))
    local native = { Name = "RoomMoneyDrop" }
    lu.assertTrue(timeline.open(port, "roomEntered"))
    lu.assertNotNil(timeline.bind(port, source, native))
    lu.assertTrue(timeline.complete(port, source))
    lu.assertTrue(timeline.releaseCompletedBinding(port, source, native))
    local duplicate = assert(timeline.claimReady(
        port, { kind = "directPickup", gameName = "RoomMoneyDrop" }, native,
        function(transaction, contact)
            return transaction.owner == "duplicate" and contact.gameName == transaction.gameName
        end))
    lu.assertNotNil(duplicate)
end

function TestRouteRoomSessions.testConformanceMismatchIsAtomicAndBlocking()
    local session = newSession(occurrence())
    lu.assertTrue(complete(session, "required"))
    lu.assertNil(room.close(session, function()
        return nil, {
            checkpoint = "room-exit-conformance:forfeit",
            expected = "inactive",
            observed = "consumed",
        }
    end))
    lu.assertFalse(session.closed)
    lu.assertEquals(session.firstMismatch.checkpoint, "room-exit-conformance:forfeit")
end

function TestRouteRoomSessions.testObligationAndDiagnosticRemainSeparate()
    local session = newSession(occurrence())
    lu.assertNil(room.checkpoint(session, "roomExit"))
    lu.assertEquals(session.firstMismatch.checkpoint, "obligation:roomExit")
    local routeState = route.new({ selectedOccurrenceIds = { "one" }, occurrencesById = { one = occurrence() } })
    lu.assertNotNil(route.enter(routeState, "one", "F_Test"))
    routeState.diagnostics[#routeState.diagnostics + 1] = { expected = "different", observed = "native" }
    lu.assertNil(routeState.firstMismatch)
end

function TestRouteRoomSessions.testTerminalPrefixIgnoresLaterRoomEntry()
    local state = route.new({ selectedOccurrenceIds = { "one" }, occurrencesById = { one = occurrence() } })
    lu.assertNotNil(route.enter(state, "one", "F_Test"))
    lu.assertTrue(route.exit(state))
    lu.assertTrue(route.enter(state, "unsupported", "H_Opening"))
end

function TestRouteRoomSessions.testBoundOwnerTypoMismatchesButDeclaredIncidentalDoesNot()
    local session = newSession(occurrence())
    lu.assertNil(complete(session, "requred"))
    lu.assertEquals(session.firstMismatch.checkpoint, "timeline-handle")
    local incidental = newSession(occurrence())
    lu.assertTrue(room.incidental(incidental))
    lu.assertNil(incidental.firstMismatch)
end

function TestRouteRoomSessions.testClosedRoomDisposesEveryPublicOperation()
    local session = newSession(occurrence())
    room.openWindow(session, "roomEntered")
    lu.assertTrue(complete(session, "required"))
    lu.assertTrue(room.close(session, function() return true end))
    lu.assertNil(room.openWindow(session, "afterCombat"))
    lu.assertNil(complete(session, "optional"))
    lu.assertNil(room.incidental(session))
    lu.assertNil(room.prove(session, "overview", true, true))
    lu.assertNil(room.checkpoint(session, "roomExit"))
end

function TestRouteRoomSessions.testEveryPublishedLifecycleWindowAndCheckpointIsUsable()
    local windows = {
        { kind = "standard", phase = "beforeCombat", open = "roomEntered" },
        { kind = "standard", phase = "afterCombat", open = "afterCombat" },
        { kind = "encounterEnd", phaseKey = "one", open = "encounterEnd:one" },
        { kind = "bossDefeated", phaseKey = "one", open = "bossDefeated:one" },
        { kind = "postOutgoing", open = "postOutgoing" },
    }
    for index, row in ipairs(windows) do
        local owner = "window-" .. index
        local entry = occurrence()
        entry.transactionsByOwner = { [owner] = { owner = owner, window = row } }
        entry.timeline = { dependencies = {}, obligations = {
            { owner = owner, checkpoint = "roomEntered" },
            { owner = owner, checkpoint = "outgoingGeneration" },
            { owner = owner, checkpoint = "exitUsable" },
            { owner = owner, checkpoint = "roomExit" },
        } }
        local session = newSession(entry)
        room.openWindow(session, row.open)
        lu.assertTrue(complete(session, owner))
        for _, checkpoint in ipairs({ "roomEntered", "outgoingGeneration", "exitUsable", "roomExit" }) do
            lu.assertTrue(room.checkpoint(session, checkpoint))
        end
    end
end

function TestRouteRoomSessions.testOutgoingGenerationDoesNotCloseTheAfterCombatWindow()
    local afterCombatOwner = "after-combat"
    local postOutgoingOwner = "post-outgoing"
    local entry = occurrence()
    entry.transactionsByOwner = {
        [afterCombatOwner] = {
            owner = afterCombatOwner,
            window = { kind = "standard", phase = "afterCombat" },
        },
        [postOutgoingOwner] = {
            owner = postOutgoingOwner,
            window = { kind = "postOutgoing" },
        },
    }
    entry.timeline = { dependencies = {}, obligations = {} }
    local session = newSession(entry)

    lu.assertTrue(room.openWindow(session, "afterCombat"))
    lu.assertTrue(room.openWindow(session, "postOutgoing"))
    lu.assertTrue(complete(session, afterCombatOwner))
    lu.assertTrue(complete(session, postOutgoingOwner))
end

function TestRouteRoomSessions.testSparseDependencyDoesNotCreateAnObligationOrOrderingForIndependentOwner()
    local entry = occurrence()
    entry.transactionsByOwner = {
        X = { owner = "X", window = { kind = "standard", phase = "beforeCombat" } },
        Y = { owner = "Y", window = { kind = "standard", phase = "beforeCombat" } },
        Z = { owner = "Z", window = { kind = "standard", phase = "beforeCombat" } },
    }
    entry.timeline = { dependencies = { { owner = "Y", afterOwner = "X" } }, obligations = {} }

    local rejected = newSession(entry)
    lu.assertNil(complete(rejected, "Y"))
    lu.assertEquals(rejected.firstMismatch.checkpoint, "transaction-prerequisite")

    for _, order in ipairs({ { "X", "Y", "Z" }, { "X", "Z", "Y" }, { "Z", "X", "Y" } }) do
        local session = newSession(entry)
        for _, owner in ipairs(order) do lu.assertTrue(complete(session, owner)) end
        lu.assertTrue(room.close(session, function() return true end))
    end
end

function TestRouteRoomSessions.testOptionalOwnerCanRemainIncompleteAndDeadlineOnlyBlocksItsCheckpoint()
    local entry = occurrence()
    entry.transactionsByOwner = {
        entry = { owner = "entry", window = { kind = "standard", phase = "beforeCombat" } },
        outgoing = { owner = "outgoing", window = { kind = "postOutgoing" } },
        usable = { owner = "usable", window = { kind = "postOutgoing" } },
        exit = { owner = "exit", window = { kind = "standard", phase = "afterCombat" } },
        optional = { owner = "optional", window = { kind = "standard", phase = "beforeCombat" } },
    }
    entry.timeline = { dependencies = {}, obligations = {
        { owner = "entry", checkpoint = "roomEntered" },
        { owner = "outgoing", checkpoint = "outgoingGeneration" },
        { owner = "usable", checkpoint = "exitUsable" },
        { owner = "exit", checkpoint = "roomExit" },
    } }

    local missing = newSession(entry)
    lu.assertNil(room.checkpoint(missing, "roomEntered"))
    lu.assertEquals(missing.firstMismatch.checkpoint, "obligation:roomEntered")

    local session = newSession(entry)
    lu.assertTrue(complete(session, "entry"))
    lu.assertTrue(room.checkpoint(session, "roomEntered"))
    lu.assertTrue(room.openWindow(session, "postOutgoing"))
    lu.assertTrue(complete(session, "outgoing"))
    lu.assertTrue(room.checkpoint(session, "outgoingGeneration"))
    lu.assertTrue(complete(session, "usable"))
    lu.assertTrue(room.checkpoint(session, "exitUsable"))
    lu.assertTrue(room.openWindow(session, "afterCombat"))
    lu.assertTrue(complete(session, "exit"))
    lu.assertTrue(room.close(session, function() return true end))
end

function TestRouteRoomSessions.testEachLaterDeadlinePassesEarlierCheckpointsBeforeItBlocks()
    local function sessionFor(owner, window, checkpoint)
        local entry = occurrence()
        entry.transactionsByOwner = { [owner] = { owner = owner, window = window } }
        entry.timeline = { dependencies = {}, obligations = { { owner = owner, checkpoint = checkpoint } } }
        return newSession(entry)
    end

    local outgoing = sessionFor("outgoing", { kind = "postOutgoing" }, "outgoingGeneration")
    lu.assertTrue(room.checkpoint(outgoing, "roomEntered"))
    lu.assertTrue(room.openWindow(outgoing, "postOutgoing"))
    lu.assertNil(room.checkpoint(outgoing, "outgoingGeneration"))
    lu.assertEquals(outgoing.firstMismatch.checkpoint, "obligation:outgoingGeneration")

    local usable = sessionFor("usable", { kind = "postOutgoing" }, "exitUsable")
    lu.assertTrue(room.checkpoint(usable, "roomEntered"))
    lu.assertTrue(room.openWindow(usable, "postOutgoing"))
    lu.assertTrue(room.checkpoint(usable, "outgoingGeneration"))
    lu.assertNil(room.checkpoint(usable, "exitUsable"))
    lu.assertEquals(usable.firstMismatch.checkpoint, "obligation:exitUsable")

    local exit = sessionFor("exit", { kind = "standard", phase = "afterCombat" }, "roomExit")
    lu.assertTrue(room.checkpoint(exit, "roomEntered"))
    lu.assertTrue(room.openWindow(exit, "postOutgoing"))
    lu.assertTrue(room.checkpoint(exit, "outgoingGeneration"))
    lu.assertTrue(room.checkpoint(exit, "exitUsable"))
    lu.assertTrue(room.openWindow(exit, "afterCombat"))
    lu.assertNil(room.close(exit, function() return true end))
    lu.assertEquals(exit.firstMismatch.checkpoint, "obligation:roomExit")
end

function TestRouteRoomSessions.testPhaseCapabilityIsTransientAndRoomCloseDisposesTimelineState()
    local entry = occurrence()
    entry.transactionsByOwner = {
        phase = { owner = "phase", window = { kind = "encounterEnd", phaseKey = "wave1" } },
        later = { owner = "later", window = { kind = "encounterEnd", phaseKey = "wave2" } },
    }
    entry.timeline = { dependencies = {}, obligations = {} }
    local session = newSession(entry)
    lu.assertTrue(room.openWindow(session, "encounterEnd:wave1"))
    lu.assertEquals(room.activePhase(session, "encounterEnd"), "wave1")
    lu.assertTrue(complete(session, "phase"))
    lu.assertTrue(room.openWindow(session, "encounterEnd:wave2"))
    lu.assertEquals(room.activePhase(session, "encounterEnd"), "wave2")
    lu.assertTrue(complete(session, "later"))
    lu.assertTrue(room.openWindow(session, "afterCombat"))
    lu.assertTrue(room.close(session, function() return true end))
end

function TestRouteRoomSessions.testDeclaredInteractionContactResolvesWithoutTransactionKindMatching()
    local entry = occurrence()
    entry.transactionsByOwner = {
        fountain = {
            owner = "fountain",
            interactionKey = "fountain",
            window = { kind = "postOutgoing" },
        },
    }
    entry.timeline = { dependencies = {}, obligations = {} }
    local session = room.new(entry, assert(bindings.index(entry)))
    local port = session._timeline
    local handle = assert(timeline.resolve(port, bindings.resolve,
        { kind = "interaction", interactionKey = "fountain" }))
    local nativeSource = {}
    local bound = assert(timeline.bind(port, handle, nativeSource))
    lu.assertTrue(room.openWindow(session, "postOutgoing"))
    lu.assertTrue(rawequal(timeline.bound(port, nativeSource), bound))
    lu.assertEquals(room.begin(session, bound).transaction.owner, "fountain")
    lu.assertTrue(room.complete(session, bound))
end

function TestRouteRoomSessions.testCompletedOwnerRetiresEveryHandleWithoutMismatch()
    local entry = occurrence()
    local transaction = entry.transactionsByOwner.required
    transaction.offerKey, transaction.generationKey = "required", "required"
    local session = room.new(entry, assert(bindings.index(entry)))
    local port = session._timeline
    local offer = assert(timeline.resolve(port, bindings.resolve, { kind = "offer", offerKey = "required" }))
    local generation = assert(timeline.resolve(port, bindings.resolve,
        { kind = "generation", generationKey = "required" }))
    lu.assertTrue(room.complete(session, offer))
    lu.assertTrue(room.complete(session, generation))
    lu.assertNil(room.begin(session, offer))
    lu.assertNil(room.begin(session, generation))
    lu.assertNil(session.firstMismatch)
end

function TestRouteRoomSessions.testExactHandleBindingHasOneNativeCarrier()
    local entry = occurrence()
    local transaction = entry.transactionsByOwner.required
    transaction.offerKey = "required"
    entry.transactionsByOwner.other = {
        owner = "other", offerKey = "other", window = { kind = "standard", phase = "beforeCombat" },
    }
    local port = timeline.new(entry, assert(bindings.index(entry)))
    local handle = assert(timeline.resolve(port, bindings.resolve, { kind = "offer", offerKey = "required" }))
    local first, second = {}, {}
    lu.assertTrue(rawequal(assert(timeline.bind(port, handle, first)), handle))
    lu.assertTrue(rawequal(assert(timeline.bind(port, handle, first)), handle))
    -- A Mystery action retains one handle across its box and provider native
    -- carriers; the native object reverse index must still reject crossing
    -- either carrier to another action.
    lu.assertTrue(rawequal(assert(timeline.bind(port, handle, second)), handle))
    local other = assert(timeline.resolve(port, bindings.resolve, { kind = "offer", offerKey = "other" }))
    lu.assertNil(timeline.bind(port, other, second))
    lu.assertEquals(port.firstMismatch.checkpoint, "timeline-binding")
end

function TestRouteRoomSessions.testAcceptedUnboundPickupClaimCompletesAndClosesObligation()
    local transaction = {
        owner = "pickup", kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            { role = "self", kind = "resource", gameName = "MaxHealthDrop", disposition = "normal" },
        },
    }
    local pickupOccurrence = {
        id = "pickup-room", gameName = "F_Test",
        overview = { encounterPhases = {}, requiredObjects = {}, additional = {} },
        transactionsByOwner = { pickup = transaction },
        timeline = {
            transactions = { transaction }, dependencies = {},
            obligations = { { owner = "pickup", checkpoint = "roomExit" } },
        },
        roomExitConformance = { facts = {} }, conformanceExpected = {},
    }
    local mismatches = {}
    local plan = { occurrencesById = { [pickupOccurrence.id] = pickupOccurrence } }
    local roomCoordinator = coordinator.new(plan, function(errorValue)
        mismatches[#mismatches + 1] = errorValue
    end)
    local state = { state = "synchronized", plan = plan, room = roomCoordinator }
    local active = assert(coordinator.enter(state, pickupOccurrence))
    local item = { Name = "MaxHealthDrop" }
    local handle, payload = coordinator.claimReady(state, active,
        { kind = "directPickup", gameName = item.Name }, item, function(node, contact)
            for _, role in ipairs(node.roles or {}) do
                if role.gameName == contact.gameName then return role end
            end
        end)
    lu.assertNotNil(handle)
    lu.assertEquals(payload.transaction.owner, "pickup")
    lu.assertNotNil(coordinator.begin(state, handle))
    lu.assertTrue(coordinator.complete(state, handle, true))
    lu.assertTrue(coordinator.close(state, {}, {}))
    lu.assertEquals(mismatches, {})
end

function TestRouteRoomSessions.testClaimedOwnerRejectsPreclaimHandleForBeginAndComplete()
    local entry = occurrence()
    local transaction = entry.transactionsByOwner.required
    transaction.offerKey = "required"
    transaction.roles = {
        { role = "self", gameName = "MaxHealthDrop", disposition = "normal" },
    }
    entry.timeline.transactions = { transaction }
    local port = timeline.new(entry, assert(bindings.index(entry)))
    local oldHandle = assert(timeline.resolve(port, bindings.resolve,
        { kind = "offer", offerKey = "required" }))
    local native = { Name = "MaxHealthDrop" }
    local claimedHandle = assert(timeline.claimReady(port,
        { kind = "directPickup", gameName = native.Name }, native, function(node, contact)
            for _, role in ipairs(node.roles or {}) do
                if role.gameName == contact.gameName then return role end
            end
        end))
    lu.assertFalse(rawequal(claimedHandle, oldHandle))
    lu.assertNotNil(timeline.begin(port, claimedHandle))
    lu.assertTrue(timeline.complete(port, claimedHandle, true))
    lu.assertNil(timeline.begin(port, oldHandle))
    lu.assertNil(timeline.complete(port, oldHandle, true))
    lu.assertEquals(port.firstMismatch.checkpoint, "timeline-claim")
end

function TestRouteRoomSessions.testOneNativeCarrierCannotBindTwoDistinctHandles()
    local entry = occurrence()
    local transaction = entry.transactionsByOwner.required
    transaction.offerKey = "required"
    transaction.roles = {
        { role = "first", lifecyclePoint = "created", gameName = "First" },
        { role = "second", lifecyclePoint = "created", gameName = "Second" },
    }
    local port = timeline.new(entry, assert(bindings.index(entry)))
    local source = assert(timeline.resolve(port, bindings.resolve, { kind = "offer", offerKey = "required" }))
    local first = assert(timeline.resolve(port, bindings.resolve,
        { kind = "materialized", gameName = "First" }, source))
    local second = assert(timeline.resolve(port, bindings.resolve,
        { kind = "materialized", gameName = "Second" }, source))
    local native = {}
    lu.assertTrue(timeline.bind(port, first, native) ~= nil)
    lu.assertNil(timeline.bind(port, second, native))
    lu.assertEquals(port.firstMismatch.checkpoint, "timeline-binding")
end

function TestRouteRoomSessions.testMaterializedDirectItemReusesItsPreboundHandle()
    local entry = occurrence()
    local transaction = entry.transactionsByOwner.required
    transaction.offerKey = "item"
    transaction.roles = { { role = "self", lifecyclePoint = "use", gameName = "GiftDrop" } }
    local port = timeline.new(entry, assert(bindings.index(entry)))
    local source = assert(timeline.resolve(port, bindings.resolve, { kind = "offer", offerKey = "item" }))
    local materialized = assert(timeline.resolve(port, bindings.resolve,
        { kind = "materialized", gameName = "GiftDrop" }, source))
    local item = {}
    lu.assertTrue(timeline.bind(port, materialized, item) ~= nil)
    local repeated = assert(timeline.resolve(port, bindings.resolve,
        { kind = "materialized", gameName = "GiftDrop" }, source))
    lu.assertTrue(rawequal(materialized, repeated))
    lu.assertTrue(timeline.bind(port, repeated, item) ~= nil)
    lu.assertTrue(rawequal(timeline.bound(port, item), materialized))
end

function TestRouteRoomSessions.testMultiRoleMysteryBoonBindsEachWorldCarrierToItsDeclaredRole()
    local entry = occurrence()
    local transaction = entry.transactionsByOwner.required
    transaction.offerKey = "Boon"
    transaction.roles = {
        { role = "box", lifecyclePoint = "purchase", gameName = "BlindBoxLoot" },
        { role = "hiddenSource", lifecyclePoint = "afterUnwrap", gameName = "HeraUpgrade" },
    }
    local port = timeline.new(entry, assert(bindings.index(entry)))
    local root = assert(timeline.resolve(port, bindings.resolve, { kind = "offer", offerKey = "Boon" }))
    local box = assert(timeline.resolve(port, bindings.resolve,
        { kind = "materialized", gameName = "BlindBoxLoot" }, root))
    local worldBox, loot = {}, {}
    lu.assertTrue(timeline.bind(port, box, worldBox) ~= nil)
    local repeatedBox = assert(timeline.resolve(port, bindings.resolve,
        { kind = "materialized", gameName = "BlindBoxLoot" }, root))
    lu.assertTrue(rawequal(box, repeatedBox))
    lu.assertTrue(timeline.bind(port, repeatedBox, worldBox) ~= nil)
    lu.assertTrue(rawequal(timeline.bound(port, worldBox), box))

    local source = assert(timeline.resolve(port, bindings.resolve,
        { kind = "materialized", gameName = "HeraUpgrade" }, box))
    lu.assertFalse(rawequal(source, box))
    lu.assertTrue(timeline.bind(port, source, loot) ~= nil)
    lu.assertTrue(rawequal(timeline.bound(port, loot), source))
end

function TestRouteRoomSessions.testBoundMysteryProviderAdvancesTheSameHandleToItsHiddenRole()
    local entry = occurrence()
    local transaction = entry.transactionsByOwner.required
    transaction.offerKey = "Boon"
    transaction.kind = "shopPurchase"
    transaction.roles = {
        { role = "box", lifecyclePoint = "purchase", kind = "consumable", gameName = "BlindBoxLoot" },
        {
            role = "hiddenSource", lifecyclePoint = "afterUnwrap", kind = "loot", gameName = "HeraUpgrade",
            traitOffer = { kind = "traits", giver = "Hera", options = {} },
        },
    }
    entry.timeline.transactions = { transaction }
    local port = timeline.new(entry, assert(bindings.index(entry)))
    local root = assert(timeline.resolve(port, bindings.resolve, { kind = "offer", offerKey = "Boon" }))
    local box = assert(timeline.resolve(port, bindings.resolve,
        { kind = "materialized", gameName = "BlindBoxLoot" }, root))
    local boxNative, providerNative = { Name = "BlindBoxLoot" }, { Name = "HeraUpgrade" }
    lu.assertTrue(timeline.bind(port, box, boxNative) ~= nil)
    lu.assertEquals(timeline.peek(port, box).detail, transaction.roles[1])
    lu.assertTrue(timeline.bind(port, box, providerNative) ~= nil)
    lu.assertTrue(rawequal(timeline.bound(port, providerNative), box))
    local providerPayload = assert(timeline.peek(port, box))
    lu.assertEquals(providerPayload.detail, transaction.roles[2])
    lu.assertEquals(providerPayload.detail.traitOffer.kind, "traits")
end

function TestRouteRoomSessions.testAmbiguousNativeRoleDoesNotAdvanceOrBind()
    local entry = occurrence()
    local transaction = entry.transactionsByOwner.required
    transaction.offerKey = "ambiguous"
    transaction.roles = {
        { role = "first", gameName = "Duplicate" },
        { role = "second", gameName = "Duplicate" },
    }
    local port = timeline.new(entry, assert(bindings.index(entry)))
    local handle = assert(timeline.resolve(port, bindings.resolve, { kind = "offer", offerKey = "ambiguous" }))
    local native = { Name = "Duplicate" }
    lu.assertNil(timeline.bind(port, handle, native))
    lu.assertEquals(port.firstMismatch.checkpoint, "timeline-binding")
    lu.assertNil(timeline.bound(port, native))
end

function TestRouteRoomSessions.testTimelinePortRejectsForeignAndFabricatedHandles()
    local entry = occurrence()
    for owner, transaction in pairs(entry.transactionsByOwner) do
        transaction.generationKey = "test:" .. owner
    end
    local left = timeline.new(entry, assert(bindings.index(entry)))
    local right = timeline.new(entry, assert(bindings.index(entry)))
    local foreign = assert(timeline.resolve(right, bindings.resolve,
        { kind = "generation", generationKey = "test:required" }))

    lu.assertNil(timeline.begin(left, foreign))
    lu.assertEquals(left.firstMismatch.checkpoint, "timeline-handle")

    local fresh = timeline.new(entry, assert(bindings.index(entry)))
    lu.assertNil(timeline.begin(fresh, {}))
    lu.assertEquals(fresh.firstMismatch.checkpoint, "timeline-handle")
end

function TestRouteRoomSessions.testMultiContactOwnerCompletesOnlyAtItsTerminalProof()
    local entry = occurrence()
    local transaction = {
        owner = "delivery", offerKey = "delivery", window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            { role = "source", lifecyclePoint = "created", gameName = "BlindBoxLoot" },
            { role = "terminal", lifecyclePoint = "unwrapped", gameName = "HeraUpgrade" },
        },
    }
    entry.transactionsByOwner = { delivery = transaction }
    entry.timeline = { dependencies = {}, obligations = { { owner = "delivery", checkpoint = "roomExit" } } }
    local session = room.new(entry, assert(bindings.index(entry)))
    local port = session._timeline
    local source = assert(timeline.resolve(port, bindings.resolve, { kind = "offer", offerKey = "delivery" }))
    local first = assert(timeline.resolve(port, bindings.resolve,
        { kind = "materialized", gameName = "BlindBoxLoot" }, source))
    local terminal = assert(timeline.resolve(port, bindings.resolve,
        { kind = "materialized", gameName = "HeraUpgrade" }, source))
    lu.assertFalse(rawequal(first, terminal))
    lu.assertNotNil(room.begin(session, first))
    lu.assertNotNil(room.begin(session, terminal))
    lu.assertTrue(room.complete(session, terminal))
    lu.assertTrue(room.close(session, function() return true end))
end

function TestRouteRoomSessions.testRouteRefusesOverlapThenAdvancesExactlyOnce()
    local first, second = occurrence(), occurrence()
    second.id, second.gameName = "two", "F_Next"
    local plan = { selectedOccurrenceIds = { "one", "two" }, occurrencesById = { one = first, two = second } }
    local state = route.new(plan)
    lu.assertNotNil(route.enter(state, "one", "F_Test"))
    lu.assertNil(route.enter(state, "two", "F_Next"))
    lu.assertEquals(state.index, 1)
end

function TestRouteRoomSessions.testRouteAdvancesAcrossSelectedOccurrences()
    local first, second = occurrence(), occurrence()
    second.id, second.gameName = "two", "F_Next"
    local plan = {
        selectedOccurrenceIds = { "one", "two" },
        occurrencesById = { one = first, two = second },
    }
    local state = route.new(plan)
    lu.assertNotNil(route.enter(state, "one", "F_Test"))
    lu.assertTrue(route.reportDestination(state, "two"))
    lu.assertTrue(route.exit(state))
    lu.assertEquals(state.index, 2)
    lu.assertNotNil(route.enter(state, "two", "F_Next"))
end

function TestRouteRoomSessions.testRouteRejectsAnUnpublishedDestination()
    local first, second = occurrence(), occurrence()
    second.id, second.gameName = "two", "F_Next"
    local state = route.new({
        selectedOccurrenceIds = { "one", "two" },
        occurrencesById = { one = first, two = second },
    })
    lu.assertNotNil(route.enter(state, "one", "F_Test"))
    lu.assertNil(route.reportDestination(state, "other"))
    lu.assertEquals(state.firstMismatch.checkpoint, "door-selection")
end
