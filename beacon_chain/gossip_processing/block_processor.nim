# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/math,
  stew/results,
  chronicles, chronos, metrics,
  ../spec/datatypes/[phase0, altair, merge],
  ../spec/[forks, signatures_batch],
  ../consensus_object_pools/[
    attestation_pool, block_clearance, blockchain_dag, block_quarantine,
    spec_cache],
  ./consensus_manager,
  ".."/[beacon_clock],
  ../sszdump,
  ../eth1/eth1_monitor

export sszdump, signatures_batch

import web3/engine_api_types

# Block Processor
# ------------------------------------------------------------------------------
# The block processor moves blocks from "Incoming" to "Consensus verified"

declareHistogram beacon_store_block_duration_seconds,
  "storeBlock() duration", buckets = [0.25, 0.5, 1, 2, 4, 8, Inf]

type
  BlockEntry* = object
    blck*: ForkedSignedBeaconBlock
    resfut*: Future[Result[void, BlockError]]
    queueTick*: Moment # Moment when block was enqueued
    validationDur*: Duration # Time it took to perform gossip validation

  BlockProcessor* = object
    ## This manages the processing of blocks from different sources
    ## Blocks and attestations are enqueued in a gossip-validated state
    ##
    ## from:
    ## - Gossip (when synced)
    ## - SyncManager (during sync)
    ## - RequestManager (missing ancestor blocks)
    ##
    ## are then consensus-verified and added to:
    ## - the blockchain DAG
    ## - database
    ## - attestation pool
    ## - fork choice
    ##
    ## The processor will also reinsert blocks from the quarantine, should a
    ## parent be found.

    # Config
    # ----------------------------------------------------------------
    dumpEnabled: bool
    dumpDirInvalid: string
    dumpDirIncoming: string

    # Producers
    # ----------------------------------------------------------------
    blockQueue*: AsyncQueue[BlockEntry] # Exported for "test_sync_manager"

    # Consumer
    # ----------------------------------------------------------------
    consensusManager: ref ConsensusManager
      ## Blockchain DAG, AttestationPool, Quarantine, and Eth1Manager
    getBeaconTime: GetBeaconTimeFn

    verifier: BatchVerifier

# Initialization
# ------------------------------------------------------------------------------

proc new*(T: type BlockProcessor,
          dumpEnabled: bool,
          dumpDirInvalid, dumpDirIncoming: string,
          rng: ref BrHmacDrbgContext, taskpool: TaskPoolPtr,
          consensusManager: ref ConsensusManager,
          getBeaconTime: GetBeaconTimeFn): ref BlockProcessor =
  (ref BlockProcessor)(
    dumpEnabled: dumpEnabled,
    dumpDirInvalid: dumpDirInvalid,
    dumpDirIncoming: dumpDirIncoming,
    blockQueue: newAsyncQueue[BlockEntry](),
    consensusManager: consensusManager,
    getBeaconTime: getBeaconTime,
    verifier: BatchVerifier(rng: rng, taskpool: taskpool)
  )

# Sync callbacks
# ------------------------------------------------------------------------------

proc hasBlocks*(self: BlockProcessor): bool =
  self.blockQueue.len() > 0

# Enqueue
# ------------------------------------------------------------------------------

proc addBlock*(
    self: var BlockProcessor, blck: ForkedSignedBeaconBlock,
    resfut: Future[Result[void, BlockError]] = nil,
    validationDur = Duration()) =
  ## Enqueue a Gossip-validated block for consensus verification
  # Backpressure:
  #   There is no backpressure here - producers must wait for `resfut` to
  #   constrain their own processing
  # Producers:
  # - Gossip (when synced)
  # - SyncManager (during sync)
  # - RequestManager (missing ancestor blocks)

  withBlck(blck):
    if blck.message.slot <= self.consensusManager.dag.finalizedHead.slot:
      # let backfill blocks skip the queue - these are always "fast" to process
      # because there are no state rewinds to deal with
      let res = self.consensusManager.dag.addBackfillBlock(blck)
      if resFut != nil:
        resFut.complete(res)
      return

  try:
    self.blockQueue.addLastNoWait(BlockEntry(
      blck: blck,
      resfut: resfut, queueTick: Moment.now(),
      validationDur: validationDur))
  except AsyncQueueFullError:
    raiseAssert "unbounded queue"

# Storage
# ------------------------------------------------------------------------------

proc dumpInvalidBlock*(
    self: BlockProcessor, signedBlock: ForkySignedBeaconBlock) =
  if self.dumpEnabled:
    dump(self.dumpDirInvalid, signedBlock)

proc dumpBlock*[T](
    self: BlockProcessor,
    signedBlock: ForkySignedBeaconBlock,
    res: Result[T, BlockError]) =
  if self.dumpEnabled and res.isErr:
    case res.error
    of BlockError.Invalid:
      self.dumpInvalidBlock(signedBlock)
    of BlockError.MissingParent:
      dump(self.dumpDirIncoming, signedBlock)
    else:
      discard

proc storeBlock*(
    self: var BlockProcessor,
    signedBlock: ForkySignedBeaconBlock,
    wallSlot: Slot, queueTick: Moment = Moment.now(),
    validationDur = Duration()): Result[BlockRef, BlockError] =
  let
    attestationPool = self.consensusManager.attestationPool
    startTick = Moment.now()
    dag = self.consensusManager.dag

  # The block is certainly not missing any more
  self.consensusManager.quarantine[].missing.del(signedBlock.root)

  # We'll also remove the block as an orphan: it's unlikely the parent is
  # missing if we get this far - should that be the case, the block will
  # be re-added later
  self.consensusManager.quarantine[].removeOrphan(signedBlock)

  type Trusted = typeof signedBlock.asTrusted()
  let blck = dag.addHeadBlock(self.verifier, signedBlock) do (
      blckRef: BlockRef, trustedBlock: Trusted, epochRef: EpochRef):
    # Callback add to fork choice if valid
    attestationPool[].addForkChoice(
      epochRef, blckRef, trustedBlock.message, wallSlot)

  self.dumpBlock(signedBlock, blck)

  # There can be a scenario where we receive a block we already received.
  # However this block was before the last finalized epoch and so its parent
  # was pruned from the ForkChoice.
  if blck.isErr():
    if blck.error() == BlockError.MissingParent:
      if not self.consensusManager.quarantine[].add(
          dag, ForkedSignedBeaconBlock.init(signedBlock)):
        debug "Block quarantine full",
          blockRoot = shortLog(signedBlock.root),
          blck = shortLog(signedBlock.message),
          signature = shortLog(signedBlock.signature)

    return blck

  let storeBlockTick = Moment.now()

  # Eagerly update head: the incoming block "should" get selected
  self.consensusManager[].updateHead(wallSlot)

  let
    updateHeadTick = Moment.now()
    queueDur = startTick - queueTick
    storeBlockDur = storeBlockTick - startTick
    updateHeadDur = updateHeadTick - storeBlockTick

  beacon_store_block_duration_seconds.observe(storeBlockDur.toFloatSeconds())

  debug "Block processed",
    localHeadSlot = self.consensusManager.dag.head.slot,
    blockSlot = blck.get().slot,
    validationDur, queueDur, storeBlockDur, updateHeadDur

  for quarantined in self.consensusManager.quarantine[].pop(blck.get().root):
    # Process the blocks that had the newly accepted block as parent
    self.addBlock(quarantined)

  blck

# Event Loop
# ------------------------------------------------------------------------------

proc processBlock(self: var BlockProcessor, entry: BlockEntry) =
  logScope:
    blockRoot = shortLog(entry.blck.root)

  let
    wallTime = self.getBeaconTime()
    (afterGenesis, wallSlot) = wallTime.toSlot()

  if not afterGenesis:
    error "Processing block before genesis, clock turned back?"
    quit 1

  let
     res = withBlck(entry.blck):
       self.storeBlock(blck, wallSlot, entry.queueTick, entry.validationDur)

  if entry.resfut != nil:
    entry.resfut.complete(
      if res.isOk(): Result[void, BlockError].ok()
      else: Result[void, BlockError].err(res.error()))

proc runQueueProcessingLoop*(self: ref BlockProcessor) {.async.} =
  while true:
    # Cooperative concurrency: one block per loop iteration - because
    # we run both networking and CPU-heavy things like block processing
    # on the same thread, we need to make sure that there is steady progress
    # on the networking side or we get long lockups that lead to timeouts.
    const
      # We cap waiting for an idle slot in case there's a lot of network traffic
      # taking up all CPU - we don't want to _completely_ stop processing blocks
      # in this case - doing so also allows us to benefit from more batching /
      # larger network reads when under load.
      idleTimeout = 10.milliseconds

    discard await idleAsync().withTimeout(idleTimeout)

    let
      blck = await self[].blocksQueue.popFirst()
      hasExecutionPayload = blck.blck.kind >= BeaconBlockFork.Merge
      executionPayloadStatus =
        if  hasExecutionPayload and
            # Allow local testnets to run without requiring an execution layer
            blck.blck.mergeData.message.body.execution_payload !=
              default(merge.ExecutionPayload):
          try:
            await newExecutionPayload(
              self.consensusManager.web3Provider,
              blck.blck.mergeData.message.body.execution_payload)
          except CatchableError as err:
            info "runQueueProcessingLoop: newExecutionPayload failed",
              err = err.msg
            "SYNCING"
        else:
          # Vacuously
          "VALID"

    # TODO enum
    doAssert executionPayloadStatus in ["INVALID", "SYNCING", "VALID"]

    info "FOO4",
      executionPayloadStatus

    # https://github.com/ethereum/execution-apis/blob/v1.0.0-alpha.5/src/engine/specification.md#specification
    # "Client software MUST discard the payload if it's deemed invalid."
    # TODO feed this back into gossip scoring
    if  executionPayloadStatus != "INVALID" and self[].processBlock(blck) and
        hasExecutionPayload:
      # TODO should never be fcUpdating with 0's
      let
        terminalBlockHash =
          default(Eth2Digest)
        headBlockRoot =
          if self.consensusManager.dag.head.executionBlockRoot != default(Eth2Digest):
            self.consensusManager.dag.head.executionBlockRoot
          else:
            terminalBlockHash
        finalizedBlockRoot =
          if self.consensusManager.dag.finalizedHead.blck.executionBlockRoot != default(Eth2Digest):
            self.consensusManager.dag.finalizedHead.blck.executionBlockRoot
          else:
            terminalBlockHash

      info "FOO14",
        headBlockRoot,
        finalizedBlockRoot,
        block_hash = blck.blck.mergeData.message.body.execution_payload.block_hash,
        parent_hash = blck.blck.mergeData.message.body.execution_payload.parent_hash,
        executionPayloadStatus

      if headBlockRoot != default(Eth2Digest):
        info "FOO15",
          headBlockRoot,
          finalizedBlockRoot

        try:
          discard await forkchoiceUpdated(
            self.consensusManager.web3Provider, headBlockRoot, finalizedBlockRoot)
        except CatchableError as err:
          # TODO log error
          discard
