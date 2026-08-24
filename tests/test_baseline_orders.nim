## The bounded-orders / legality assertion on the scripted baselines.
##
## All eight baselines are driven against a scripted world for 2000 ticks.
## An order that is unbounded, ambiguous, or unpayable fails CI: the sim
## reads direction bits with priority up > down > left > right, so a mask
## with two directions set would be a silent, untestable ambiguity.

import std/[json, sequtils, unicode]
import bitworld/protocol
import cooperative_hunting/[sim, art, frames, baselines]

var failures = 0
proc check(label: string, condition: bool) =
  if not condition:
    echo "FAIL: ", label
    inc failures
  else:
    echo "ok: ", label

const DirectionBits = ButtonUp or ButtonDown or ButtonLeft or ButtonRight
const DefinedBits = DirectionBits or ButtonSelect or ButtonA or ButtonB

proc bitsSet(mask: uint8): int =
  var m = mask
  while m != 0:
    if (m and 1'u8) != 0: inc result
    m = m shr 1

type Report = object
  emitted: int
  maxDirectionBits: int
  illegalBits: bool
  overBudget: bool
  unpayable: bool
  everMoved: bool

proc driveWorld(variant: string, kinds: openArray[BaselineKind],
    ticks: int): seq[Report] =
  var config = defaultGameConfig()
  config.variant = variant
  config.numAgents = kinds.len
  config.seed = 5743127
  var sim = initSim(config)
  sim.art.buildSpriteCache()
  for slot in 0 ..< kinds.len:
    discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
  sim.ensureStats(kinds.len)
  sim.applyRolesPublic()

  var bots: seq[Bot] = @[]
  var states: seq[ViewerState] = @[]
  result = newSeq[Report](kinds.len)
  for slot, kind in kinds:
    bots.add(initBot(kind, slot))
    states.add(ViewerState())
  var masks = newSeq[uint8](kinds.len)

  for tick in 1 .. ticks:
    var inputs: seq[InputState] = @[]
    for slot in 0 ..< kinds.len:
      inputs.add(decodeInputMask(masks[slot]))
    let energyBefore = sim.players.mapIt(it.energy)
    let posBefore = sim.players.mapIt((it.tileX, it.tileY))
    sim.step(inputs)
    for slot in 0 ..< kinds.len:
      # A hunter that could not pay for a move must not have moved.
      if energyBefore[slot] < MoveEnergyCost and
          (sim.players[slot].tileX, sim.players[slot].tileY) !=
            posBefore[slot]:
        result[slot].unpayable = true
      if (sim.players[slot].tileX, sim.players[slot].tileY) != posBefore[slot]:
        result[slot].everMoved = true
    for slot in 0 ..< kinds.len:
      var nextState: ViewerState
      let frame = sim.buildPlayerFrame(slot, states[slot], nextState)
      states[slot] = nextState
      var blob = newString(frame.len)
      for i, b in frame:
        blob[i] = char(b)
      if not bots[slot].applySpritePacket(blob):
        result[slot].illegalBits = true    # a frame the bot could not parse
        continue
      inc bots[slot].frameTick
      # Exactly ONE decision per tick: the loop shape is the guarantee.
      let mask = bots[slot].decideMask()
      inc result[slot].emitted
      result[slot].maxDirectionBits =
        max(result[slot].maxDirectionBits, bitsSet(mask and DirectionBits))
      if (mask and not DefinedBits) != 0 or mask > 0x7f'u8:
        result[slot].illegalBits = true
      masks[slot] = mask
    if result.anyIt(it.emitted > tick):
      result[0].overBudget = true


block allEightLegal:
  const kinds = [bkRabbiteer, bkNearestHunter, bkStagHunter, bkMooseHunter,
                 bkElephantHunter, bkBigGameHunter, bkSidekick, bkModeler]
  let reports = driveWorld("staghunt", kinds, 2000)
  for slot, kind in kinds:
    let name = baselineName(kind)
    check(name & " emits at most one direction bit per mask",
      reports[slot].maxDirectionBits <= 1)
    check(name & " never sets an undefined bit and stays <= 0x7f",
      not reports[slot].illegalBits)
    check(name & " emits at most one mask per tick",
      reports[slot].emitted <= 2000)
    check(name & " never moves without paying for it",
      not reports[slot].unpayable)
    check(name & " actually plays (it moved at least once)",
      reports[slot].everMoved)

block everyVariantLegal:
  ## The same eight, in the three other variants, where their targets are ore
  ## nodes, level-bearing food and berry bushes rather than animals.
  const kinds = [bkBigGameHunter, bkSidekick, bkModeler, bkStagHunter,
                 bkRabbiteer, bkNearestHunter]
  for variant in ["coop-mining", "lbf", "predator-prey"]:
    let reports = driveWorld(variant, kinds, 600)
    var ok = true
    for report in reports:
      if report.maxDirectionBits > 1 or report.illegalBits or
          report.unpayable:
        ok = false
    check("every baseline order is legal in " & variant, ok)

block registrationBodies:
  ## Every 0x90 registration body a baseline seat sends must be <= 4096
  ## bytes, valid UTF-8 and valid JSON.
  for kind in BaselineKind:
    let body = $(%*{"kind": "scripted", "baseline": baselineName(kind)})
    check(baselineName(kind) & " registration is <= 4096 bytes",
      body.len <= MaxRegistrationBytes)
    check(baselineName(kind) & " registration is valid UTF-8",
      validateUtf8(body) == -1)
    var parsed = false
    try:
      discard parseJson(body)
      parsed = true
    except CatchableError:
      parsed = false
    check(baselineName(kind) & " registration is valid JSON", parsed)
  check("an unknown baseline name resolves to big_game_hunter",
    parseBaselineKind("nope") == bkBigGameHunter)
  check("every declared baseline name round-trips",
    (block:
      var ok = true
      for kind in BaselineKind:
        if parseBaselineKind(baselineName(kind)) != kind: ok = false
      ok))

if failures > 0:
  quit("test_baseline_orders: " & $failures & " failures", 1)
echo "test_baseline_orders: all checks passed"
