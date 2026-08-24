## The replay bytes are a strict-UTF-8 JSON document that stands alone.
##
## `docker_smoke.sh` parses this file with SMOKE_REQUIRE_REPLAY_JSON=1 and the
## wasm module parses it in the browser, so a string truncated on a BYTE
## boundary mid-rune -- which still renders fine in a browser -- would fail
## both. Every recorded string goes through runeCap().

import std/[json, os, strutils, unicode]
import cooperative_hunting
import cooperative_hunting/[sim, art, frames, replay]

var failures = 0
proc check(label: string, condition: bool) =
  if not condition:
    echo "FAIL: ", label
    inc failures
  else:
    echo "ok: ", label

let dir = getTempDir() / "ch-replay-parse"
removeDir(dir)
var config = defaultGameConfig()
config.numAgents = 6
config.rounds = 2
config.ticksPerRound = 120
config.players = @["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
discard runEpisodeOffline(config,
  @["big_game_hunter", "big_game_hunter", "sidekick", "modeler",
    "stag_hunter", "rabbiteer"],
  dir / "results.json", dir / "replay.json")

let bytes = readFile(dir / "replay.json")

block strictUtf8:
  check("the replay is strict UTF-8", validateUtf8(bytes) == -1)
  var parsed = false
  try:
    discard parseJson(bytes)
    parsed = true
  except CatchableError as error:
    echo "  parse error: ", error.msg
  check("the replay parses as JSON", parsed)

let doc = parseJson(bytes)

block requiredKeys:
  for key in ["format", "version", "coworld", "variant", "generated_at",
      "seed", "config", "world", "seats", "rounds", "ticks", "results"]:
    check("the replay carries " & key, doc.hasKey(key))
  check("the format is the one the viewer expects",
    doc["format"].getStr() == "cooperative-hunting/1")
  check("the world carries a full tile string",
    doc["world"]["tiles"].getStr().len == 32 * 32)
  check("the config is expanded, not a delta",
    doc["config"].hasKey("planIntervalTicks") and
    doc["config"].hasKey("playBudgetSeconds"))

block seatsPopulated:
  for seat in doc["seats"]:
    check("seat " & $seat["slot"].getInt() & " has a real name",
      seat["name"].getStr().len > 0)
    check("seat " & $seat["slot"].getInt() & " has an alias",
      seat["alias"].getStr().startsWith("Cog-"))

block sayCapsAndNotePrivacy:
  ## `say` is broadcast, `note` is private and must never reach the replay.
  var sayCount = 0
  var noteFound = false
  var overLong = false
  for tick in doc["ticks"]:
    if not tick.hasKey("ev"):
      continue
    for event in tick["ev"]:
      if event.hasKey("note"):
        noteFound = true
      if event.hasKey("say"):
        inc sayCount
        if event["say"].getStr().runeLen > MaxSayRunes:
          overLong = true
  check("no note ever reaches the replay", not noteFound)
  check("every say is within its 120-rune cap", not overLong)
  discard sayCount

block runeBoundarySurvival:
  ## A say seeded with a MULTI-BYTE rune exactly at the cap boundary must
  ## survive as valid UTF-8 in the recorded bytes. Byte truncation here is
  ## what makes replay bytes fail a strict parser while still rendering.
  var sim = initSim(config)
  sim.art.buildSpriteCache()
  for slot in 0 ..< 6:
    discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
  sim.ensureStats(6)
  var writer = initReplayWriter(sim, @[])
  # 119 ASCII characters then a 4-byte rune, so the 120th rune sits exactly
  # on the cap and a byte cut would slice it.
  let raw = repeat("x", 119) & "\u{1F98C}" & "tail"
  let capped = runeCap(raw, MaxSayRunes)
  check("runeCap keeps exactly the cap in runes",
    capped.runeLen == MaxSayRunes)
  check("runeCap leaves valid UTF-8", validateUtf8(capped) == -1)
  check("runeCap did not slice the multi-byte rune",
    capped.endsWith("\u{1F98C}"))
  sim.logEvent("plan", %*{
    "alias": "Cog-A", "turn": 1, "intent": "hunt", "target": "none",
    "side": "any", "say": capped, "src": "llm"
  })
  writer.recordTick(sim, 1, "play", sim.pendingEvents)
  let text = writer.finish(%*{"reason": "complete"})
  check("a replay carrying a boundary rune is still strict UTF-8",
    validateUtf8(text) == -1)
  var reparsed: JsonNode
  var ok = false
  try:
    reparsed = parseJson(text)
    ok = true
  except CatchableError:
    ok = false
  check("a replay carrying a boundary rune still parses", ok)
  if ok:
    check("the boundary rune survived the round trip",
      reparsed["ticks"][0]["ev"][0]["say"].getStr() == capped)

block viewerReDerivesFrames:
  ## Re-feeding each tick through the replay renderer must yield a non-empty
  ## sprite packet -- the same buildGlobalFrame the live server uses.
  let parsedDoc = parseReplayDoc(bytes)
  check("the parsed document carries every tick",
    parsedDoc.ticks.len == doc["ticks"].len)
  var viewerSim = initSimFromDoc(parsedDoc)
  viewerSim.art.buildSpriteCache()
  var state: ViewerState
  var smallest = high(int)
  var probes = 0
  for index in countup(0, parsedDoc.ticks.high, 17):
    viewerSim.applyTick(parsedDoc, index)
    var nextState: ViewerState
    let label = buildChromeLabel(
      parsedDoc.ticks[index].tick, viewerSim.tickCount,
      parsedDoc.ticks[index].roundNo, parsedDoc.config.rounds,
      parsedDoc.config.ticksPerRound, parsedDoc.ticks[index].phase,
      parsedDoc.variant, "", @[], @[], @[], nil)
    let packet = viewerSim.buildGlobalFrame(label, state, nextState)
    state = nextState
    smallest = min(smallest, packet.len)
    inc probes
  check("every re-derived frame is a non-empty sprite packet",
    probes > 0 and smallest > 0)

block resultsBlock:
  let results = doc["results"]
  check("the replay's results carry the reason",
    results["reason"].getStr() in ["complete", "deadline", "no_players"])
  check("the replay's results carry one score per seat",
    results["scores"].len == config.numAgents)

if failures > 0:
  quit("test_replay_parse: " & $failures & " failures", 1)
echo "test_replay_parse: all checks passed"
