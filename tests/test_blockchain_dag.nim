# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronicles,
  unittest2,
  stew/assign2,
  eth/keys, taskpools,
  ../beacon_chain/spec/datatypes/base,
  ../beacon_chain/spec/[beaconstate, forks, helpers, signatures, state_transition],
  ../beacon_chain/[beacon_chain_db],
  ../beacon_chain/consensus_object_pools/[
    attestation_pool, blockchain_dag, block_quarantine, block_clearance],
  ./testutil, ./testdbutil, ./testblockutil

func `$`(x: BlockRef): string = shortLog(x)

const
  nilPhase0Callback = OnPhase0BlockAdded(nil)
  nilAltairCallback = OnAltairBlockAdded(nil)

proc pruneAtFinalization(dag: ChainDAGRef) =
  if dag.needStateCachesAndForkChoicePruning():
    dag.pruneStateCachesDAG()

suite "ChainDAG helpers":
  test "epochAncestor sanity" & preset():
    let
      s0 = BlockRef(bid: BlockId(slot: Slot(0)))
    var cur = s0
    for i in 1..SLOTS_PER_EPOCH * 2:
      cur = BlockRef(bid: BlockId(slot: Slot(i)), parent: cur)

    let ancestor = cur.epochAncestor(cur.slot.epoch)

    check:
      ancestor.epoch == cur.slot.epoch
      ancestor.blck != cur # should have selected a parent

      ancestor.blck.epochAncestor(cur.slot.epoch) == ancestor
      ancestor.blck.epochAncestor(ancestor.blck.slot.epoch) != ancestor

suite "Block pool processing" & preset():
  setup:
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      validatorMonitor = newClone(ValidatorMonitor.init())
      dag = init(ChainDAGRef, defaultRuntimeConfig, db, validatorMonitor, {})
      verifier = BatchVerifier(rng: keys.newRng(), taskpool: Taskpool.new())
      quarantine = Quarantine.init()
      state = newClone(dag.headState.data)
      cache = StateCache()
      info = ForkedEpochInfo()
      att0 = makeFullAttestations(state[], dag.tail.root, 0.Slot, cache)
      b1 = addTestBlock(state[], cache, attestations = att0).phase0Data
      b2 = addTestBlock(state[], cache).phase0Data
  test "getRef returns nil for missing blocks":
    check:
      dag.getRef(default Eth2Digest) == nil

  test "loading tail block works" & preset():
    let
      b0 = dag.get(dag.tail.root)

    check:
      b0.isSome()

  test "Simple block add&get" & preset():
    let
      b1Add = dag.addRawBlock(verifier, b1, nilPhase0Callback)
      b1Get = dag.get(b1.root)

    check:
      b1Get.isSome()
      b1Get.get().refs.root == b1.root
      b1Add[].root == b1Get.get().refs.root
      dag.heads.len == 1
      dag.heads[0] == b1Add[]

    let
      b2Add = dag.addRawBlock(verifier, b2, nilPhase0Callback)
      b2Get = dag.get(b2.root)
      er = dag.findEpochRef(b1Add[], b1Add[].slot.epoch)
      validators = getStateField(dag.headState.data, validators).lenu64()

    check:
      b2Get.isSome()
      b2Get.get().refs.root == b2.root
      b2Add[].root == b2Get.get().refs.root
      dag.heads.len == 1
      dag.heads[0] == b2Add[]
      not er.isNil
      # Same epoch - same epochRef
      er == dag.findEpochRef(b2Add[], b2Add[].slot.epoch)
      # Different epoch that was never processed
      dag.findEpochRef(b1Add[], b1Add[].slot.epoch + 1).isNil

      er.validatorKey(0'u64).isSome()
      er.validatorKey(validators - 1).isSome()
      er.validatorKey(validators).isNone()

    # Skip one slot to get a gap
    check:
      process_slots(
        defaultRuntimeConfig, state[], getStateField(state[], slot) + 1, cache,
        info, {})

    let
      b4 = addTestBlock(state[], cache).phase0Data
      b4Add = dag.addRawBlock(verifier, b4, nilPhase0Callback)

    check:
      b4Add[].parent == b2Add[]

    dag.updateHead(b4Add[], quarantine)
    dag.pruneAtFinalization()

    var blocks: array[3, BlockRef]

    check:
      dag.getBlockRange(Slot(0), 1, blocks.toOpenArray(0, 0)) == 0
      blocks[0..<1] == [dag.tail]

      dag.getBlockRange(Slot(0), 1, blocks.toOpenArray(0, 1)) == 0
      blocks[0..<2] == [dag.tail, b1Add[]]

      dag.getBlockRange(Slot(0), 2, blocks.toOpenArray(0, 1)) == 0
      blocks[0..<2] == [dag.tail, b2Add[]]

      dag.getBlockRange(Slot(0), 3, blocks.toOpenArray(0, 1)) == 1
      blocks[1..<2] == [dag.tail] # block 3 is missing!

      dag.getBlockRange(Slot(2), 2, blocks.toOpenArray(0, 1)) == 0
      blocks[0..<2] == [b2Add[], b4Add[]] # block 3 is missing!

      # large skip step
      dag.getBlockRange(Slot(0), uint64.high, blocks.toOpenArray(0, 2)) == 2
      blocks[2..2] == [dag.tail]

      # large skip step
      dag.getBlockRange(Slot(2), uint64.high, blocks.toOpenArray(0, 1)) == 1
      blocks[1..1] == [b2Add[]]

      # empty length
      dag.getBlockRange(Slot(2), 2, blocks.toOpenArray(0, -1)) == 0

      # No blocks in sight
      dag.getBlockRange(Slot(5), 1, blocks.toOpenArray(0, 1)) == 2

      # No blocks in sight
      dag.getBlockRange(Slot(uint64.high), 1, blocks.toOpenArray(0, 1)) == 2

      # No blocks in sight either due to gaps
      dag.getBlockRange(Slot(3), 2, blocks.toOpenArray(0, 1)) == 2
      blocks[2..<2].len == 0

  test "Adding the same block twice returns a Duplicate error" & preset():
    let
      b10 = dag.addRawBlock(verifier, b1, nilPhase0Callback)
      b11 = dag.addRawBlock(verifier, b1, nilPhase0Callback)

    check:
      b11.error == BlockError.Duplicate
      not b10[].isNil

  test "updateHead updates head and headState" & preset():
    let
      b1Add = dag.addRawBlock(verifier, b1, nilPhase0Callback)

    dag.updateHead(b1Add[], quarantine)
    dag.pruneAtFinalization()

    check:
      dag.head == b1Add[]
      getStateField(dag.headState.data, slot) == b1Add[].slot

  test "updateStateData sanity" & preset():
    let
      b1Add = dag.addRawBlock(verifier, b1, nilPhase0Callback)
      b2Add = dag.addRawBlock(verifier, b2, nilPhase0Callback)
      bs1 = BlockSlot(blck: b1Add[], slot: b1.message.slot)
      bs1_3 = b1Add[].atSlot(3.Slot)
      bs2_3 = b2Add[].atSlot(3.Slot)

    var tmpState = assignClone(dag.headState)

    # move to specific block
    var cache = StateCache()
    dag.updateStateData(tmpState[], bs1, false, cache)

    check:
      tmpState.blck == b1Add[]
      getStateField(tmpState.data, slot) == bs1.slot

    # Skip slots
    dag.updateStateData(tmpState[], bs1_3, false, cache) # skip slots

    check:
      tmpState.blck == b1Add[]
      getStateField(tmpState.data, slot) == bs1_3.slot

    # Move back slots, but not blocks
    dag.updateStateData(tmpState[], bs1_3.parent(), false, cache)
    check:
      tmpState.blck == b1Add[]
      getStateField(tmpState.data, slot) == bs1_3.parent().slot

    # Move to different block and slot
    dag.updateStateData(tmpState[], bs2_3, false, cache)
    check:
      tmpState.blck == b2Add[]
      getStateField(tmpState.data, slot) == bs2_3.slot

    # Move back slot and block
    dag.updateStateData(tmpState[], bs1, false, cache)
    check:
      tmpState.blck == b1Add[]
      getStateField(tmpState.data, slot) == bs1.slot

    # Move back to genesis
    dag.updateStateData(tmpState[], bs1.parent(), false, cache)
    check:
      tmpState.blck == b1Add[].parent
      getStateField(tmpState.data, slot) == bs1.parent.slot

suite "Block pool altair processing" & preset():
  setup:
    var
      cfg = defaultRuntimeConfig
    cfg.ALTAIR_FORK_EPOCH = Epoch(1)

    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      validatorMonitor = newClone(ValidatorMonitor.init())
      dag = init(ChainDAGRef, cfg, db, validatorMonitor, {})
      verifier = BatchVerifier(rng: keys.newRng(), taskpool: Taskpool.new())
      quarantine = Quarantine.init()
      state = newClone(dag.headState.data)
      cache = StateCache()
      info = ForkedEpochInfo()

    # Advance to altair
    check:
      process_slots(
        cfg, state[], cfg.ALTAIR_FORK_EPOCH.compute_start_slot_at_epoch(), cache,
        info, {})

      state[].kind == BeaconStateFork.Altair

    var
      b1 = addTestBlock(state[], cache).altairData
      att1 = makeFullAttestations(state[], b1.root, b1.message.slot, cache)
      b2 = addTestBlock(state[], cache, attestations = att1).altairData

  test "Invalid signatures" & preset():
    let badSignature = get_slot_signature(
      Fork(), Eth2Digest(), 42.Slot,
      MockPrivKeys[ValidatorIndex(0)]).toValidatorSig()

    check:
      dag.addRawBlock(verifier, b1, nilAltairCallback).isOk()

    block: # Main signature
      var b = b2
      b.signature = badSignature
      let
        bAdd = dag.addRawBlock(verifier, b, nilAltairCallback)
      check:
        bAdd.error() == BlockError.Invalid

    block: # Randao reveal
      var b = b2
      b.message.body.randao_reveal = badSignature
      let
        bAdd = dag.addRawBlock(verifier, b, nilAltairCallback)
      check:
        bAdd.error() == BlockError.Invalid

    block: # Attestations
      var b = b2
      b.message.body.attestations[0].signature = badSignature
      let
        bAdd = dag.addRawBlock(verifier, b, nilAltairCallback)
      check:
        bAdd.error() == BlockError.Invalid

    block: # SyncAggregate empty
      var b = b2
      b.message.body.sync_aggregate.sync_committee_signature = badSignature
      let
        bAdd = dag.addRawBlock(verifier, b, nilAltairCallback)
      check:
        bAdd.error() == BlockError.Invalid

    block: # SyncAggregate junk
      var b = b2
      b.message.body.sync_aggregate.sync_committee_signature = badSignature
      b.message.body.sync_aggregate.sync_committee_bits[0] = true

      let
        bAdd = dag.addRawBlock(verifier, b, nilAltairCallback)
      check:
        bAdd.error() == BlockError.Invalid

suite "chain DAG finalization tests" & preset():
  setup:
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      validatorMonitor = newClone(ValidatorMonitor.init())
      dag = init(ChainDAGRef, defaultRuntimeConfig, db, validatorMonitor, {})
      verifier = BatchVerifier(rng: keys.newRng(), taskpool: Taskpool.new())
      quarantine = Quarantine.init()
      cache = StateCache()
      info = ForkedEpochInfo()

  test "prune heads on finalization" & preset():
    # Create a fork that will not be taken
    var
      blck = makeTestBlock(dag.headState.data, cache).phase0Data
      tmpState = assignClone(dag.headState.data)
    check:
      process_slots(
        defaultRuntimeConfig, tmpState[],
        getStateField(tmpState[], slot) + (5 * SLOTS_PER_EPOCH).uint64,
        cache, info, {})

    let lateBlock = addTestBlock(tmpState[], cache).phase0Data
    block:
      let status = dag.addRawBlock(verifier, blck, nilPhase0Callback)
      check: status.isOk()

    assign(tmpState[], dag.headState.data)

    for i in 0 ..< (SLOTS_PER_EPOCH * 6):
      if i == 1:
        # There are 2 heads now because of the fork at slot 1
        check:
          dag.heads.len == 2

      blck = addTestBlock(
        tmpState[], cache,
        attestations = makeFullAttestations(
          tmpState[], dag.head.root, getStateField(tmpState[], slot), cache, {})).phase0Data
      let added = dag.addRawBlock(verifier, blck, nilPhase0Callback)
      check: added.isOk()
      dag.updateHead(added[], quarantine)
      dag.pruneAtFinalization()

    check:
      dag.heads.len() == 1
      dag.getBlockBySlot(0.Slot) == BlockSlot(blck: dag.genesis, slot: 0.Slot)
      dag.getBlockBySlot(dag.head.slot) == BlockSlot(
        blck: dag.head, slot: dag.head.slot.Slot)
      dag.getBlockBySlot(dag.head.slot + 1) == BlockSlot(
        blck: dag.head, slot: dag.head.slot.Slot + 1)

    check:
      dag.db.immutableValidators.len() == getStateField(dag.headState.data, validators).len()

    let
      finalER = dag.findEpochRef(dag.finalizedHead.blck, dag.finalizedHead.slot.epoch)

      # The EpochRef for the finalized block is needed for eth1 voting, so we
      # should never drop it!
    check:
      not finalER.isNil

    block:
      for er in dag.epochRefs:
        check: er == nil or er.epoch >= dag.finalizedHead.slot.epoch

    block:
      let tmpStateData = assignClone(dag.headState)

      # Check that cached data is available after updateStateData - since we
      # just processed the head the relevant epochrefs should not have been
      # evicted yet
      cache = StateCache()
      updateStateData(
        dag, tmpStateData[], dag.head.atSlot(dag.head.slot), false, cache)

      check:
        dag.head.slot.epoch in cache.shuffled_active_validator_indices
        (dag.head.slot.epoch - 1) in cache.shuffled_active_validator_indices

        dag.head.slot in cache.beacon_proposer_indices

    block:
      # The late block is a block whose parent was finalized long ago and thus
      # is no longer a viable head candidate
      let status = dag.addRawBlock(verifier, lateBlock, nilPhase0Callback)
      check: status.error == BlockError.UnviableFork

    block:
      let
        finalizedCheckpoint = dag.finalizedHead.stateCheckpoint
        headCheckpoint = dag.head.atSlot(dag.head.slot).stateCheckpoint
      check:
        db.getStateRoot(headCheckpoint.blck.root, headCheckpoint.slot).isSome
        db.getStateRoot(finalizedCheckpoint.blck.root, finalizedCheckpoint.slot).isSome

    let
      validatorMonitor2 = newClone(ValidatorMonitor.init())
      dag2 = init(ChainDAGRef, defaultRuntimeConfig, db, validatorMonitor2, {})

    # check that the state reloaded from database resembles what we had before
    check:
      dag2.tail.root == dag.tail.root
      dag2.head.root == dag.head.root
      dag2.finalizedHead.blck.root == dag.finalizedHead.blck.root
      dag2.finalizedHead.slot == dag.finalizedHead.slot
      getStateRoot(dag2.headState.data) == getStateRoot(dag.headState.data)

  test "orphaned epoch block" & preset():
    var prestate = (ref ForkedHashedBeaconState)(kind: BeaconStateFork.Phase0)
    for i in 0 ..< SLOTS_PER_EPOCH:
      if i == SLOTS_PER_EPOCH - 1:
        assign(prestate[], dag.headState.data)

      let blck = makeTestBlock(dag.headState.data, cache).phase0Data
      let added = dag.addRawBlock(verifier, blck, nilPhase0Callback)
      check: added.isOk()
      dag.updateHead(added[], quarantine)
      dag.pruneAtFinalization()

    check:
      dag.heads.len() == 1

    # The loop creates multiple branches, which StateCache isn't suitable for
    cache = StateCache()

    doAssert process_slots(
      defaultRuntimeConfig, prestate[], getStateField(prestate[], slot) + 1,
      cache, info, {})

    # create another block, orphaning the head
    let blck = makeTestBlock(prestate[], cache).phase0Data

    # Add block, but don't update head
    let added = dag.addRawBlock(verifier, blck, nilPhase0Callback)
    check: added.isOk()

    var
      validatorMonitor2 = newClone(ValidatorMonitor.init())
      dag2 = init(ChainDAGRef, defaultRuntimeConfig, db, validatorMonitor2, {})

    # check that we can apply the block after the orphaning
    let added2 = dag2.addRawBlock(verifier, blck, nilPhase0Callback)
    check: added2.isOk()

  test "init with gaps" & preset():
    for blck in makeTestBlocks(
        dag.headState.data, cache, int(SLOTS_PER_EPOCH * 6 - 2),
        true):
      let added = dag.addRawBlock(verifier, blck.phase0Data, nilPhase0Callback)
      check: added.isOk()
      dag.updateHead(added[], quarantine)
      dag.pruneAtFinalization()

    # Advance past epoch so that the epoch transition is gapped
    check:
      process_slots(
        defaultRuntimeConfig, dag.headState.data, Slot(SLOTS_PER_EPOCH * 6 + 2),
        cache, info, {})

    var blck = makeTestBlock(
      dag.headState.data, cache,
      attestations = makeFullAttestations(
        dag.headState.data, dag.head.root, getStateField(dag.headState.data, slot),
        cache, {})).phase0Data

    let added = dag.addRawBlock(verifier, blck, nilPhase0Callback)
    check: added.isOk()
    dag.updateHead(added[], quarantine)
    dag.pruneAtFinalization()

    block:
      # Check that we can rewind to every block from head to finalized
      var
        cur = dag.head
        tmpStateData = assignClone(dag.headState)
      while cur.slot >= dag.finalizedHead.slot:
        assign(tmpStateData[], dag.headState)
        dag.updateStateData(tmpStateData[], cur.atSlot(cur.slot), false, cache)
        check:
          dag.get(cur).data.phase0Data.message.state_root ==
            getStateRoot(tmpStateData[].data)
          getStateRoot(tmpStateData[].data) == hash_tree_root(
            tmpStateData[].data.phase0Data.data)
        cur = cur.parent

    let
      validatorMonitor2 = newClone(ValidatorMonitor.init())
      dag2 = init(ChainDAGRef, defaultRuntimeConfig, db, validatorMonitor2, {})

    # check that the state reloaded from database resembles what we had before
    check:
      dag2.tail.root == dag.tail.root
      dag2.head.root == dag.head.root
      dag2.finalizedHead.blck.root == dag.finalizedHead.blck.root
      dag2.finalizedHead.slot == dag.finalizedHead.slot
      getStateRoot(dag2.headState.data) == getStateRoot(dag.headState.data)

suite "Old database versions" & preset():
  setup:
    let
      genState = newClone(initialize_hashed_beacon_state_from_eth1(
        defaultRuntimeConfig,
        Eth2Digest(),
        0,
        makeInitialDeposits(SLOTS_PER_EPOCH.uint64, flags = {skipBlsValidation}),
        {skipBlsValidation}))
      genBlock = get_initial_beacon_block(genState[])
    var
      verifier = BatchVerifier(rng: keys.newRng(), taskpool: Taskpool.new())
      quarantine = Quarantine.init()

  test "pre-1.1.0":
    # only kvstore, no immutable validator keys

    let db = BeaconChainDB.new("", inMemory = true)

    # preInit a database to a v1.0.12 state
    db.putStateRoot(
      genState[].latest_block_root(), genState[].data.slot, genState[].root)
    db.putStateV0(genState[].root, genState[].data)

    db.putBlockV0(genBlock)
    db.putTailBlock(genBlock.root)
    db.putHeadBlock(genBlock.root)
    db.putGenesisBlock(genBlock.root)

    var
      validatorMonitor = newClone(ValidatorMonitor.init())
      dag = init(ChainDAGRef, defaultRuntimeConfig, db,validatorMonitor, {})
      state = newClone(dag.headState.data)
      cache = StateCache()
      att0 = makeFullAttestations(state[], dag.tail.root, 0.Slot, cache)
      b1 = addTestBlock(state[], cache, attestations = att0).phase0Data
      b1Add = dag.addRawBlock(verifier, b1, nilPhase0Callback)

    check:
      b1Add.isOk()

suite "Diverging hardforks":
  setup:
    var
      phase0RuntimeConfig = defaultRuntimeConfig
      altairRuntimeConfig = defaultRuntimeConfig

    phase0RuntimeConfig.ALTAIR_FORK_EPOCH = FAR_FUTURE_EPOCH
    altairRuntimeConfig.ALTAIR_FORK_EPOCH = 2.Epoch

    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      validatorMonitor = newClone(ValidatorMonitor.init())
      dag = init(ChainDAGRef, phase0RuntimeConfig, db, validatorMonitor, {})
      verifier = BatchVerifier(rng: keys.newRng(), taskpool: Taskpool.new())
      quarantine = newClone(Quarantine.init())
      cache = StateCache()
      info = ForkedEpochInfo()
      tmpState = assignClone(dag.headState.data)

  test "Tail block only in common":
    check:
      process_slots(
        phase0RuntimeConfig, tmpState[],
        getStateField(tmpState[], slot) + (3 * SLOTS_PER_EPOCH).uint64,
        cache, info, {})

    # Because the first block is after the Altair transition, the only block in
    # common is the tail block
    var
      b1 = addTestBlock(tmpState[], cache).phase0Data
      b1Add = dag.addRawBlock(verifier, b1, nilPhase0Callback)

    check b1Add.isOk()
    dag.updateHead(b1Add[], quarantine[])

    let validatorMonitorAltair = newClone(ValidatorMonitor.init())

    var dagAltair = init(
      ChainDAGRef, altairRuntimeConfig, db, validatorMonitorAltair, {})
    discard AttestationPool.init(dagAltair, quarantine)

  test "Non-tail block in common":
    check:
      process_slots(
        phase0RuntimeConfig, tmpState[],
        getStateField(tmpState[], slot) + SLOTS_PER_EPOCH.uint64,
        cache, info, {})

    # There's a block in the shared-correct phase0 hardfork, before epoch 2
    var
      b1 = addTestBlock(tmpState[], cache).phase0Data
      b1Add = dag.addRawBlock(verifier, b1, nilPhase0Callback)

    check:
      b1Add.isOk()
      process_slots(
        phase0RuntimeConfig, tmpState[],
        getStateField(tmpState[], slot) + (3 * SLOTS_PER_EPOCH).uint64,
        cache, info, {})

    var
      b2 = addTestBlock(tmpState[], cache).phase0Data
      b2Add = dag.addRawBlock(verifier, b2, nilPhase0Callback)

    check b2Add.isOk()
    dag.updateHead(b2Add[], quarantine[])

    let validatorMonitor = newClone(ValidatorMonitor.init())

    var dagAltair = init(
      ChainDAGRef, altairRuntimeConfig, db, validatorMonitor, {})
    discard AttestationPool.init(dagAltair, quarantine)
