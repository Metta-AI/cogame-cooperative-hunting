## The broadcast chrome: the sprite-4090 label the viewer reads, and the
## page that reads it.

import std/[json, os, strutils, unicode]
import cooperative_hunting/[sim, art, frames, replay]

var failures = 0
proc check(label: string, condition: bool) =
  if not condition:
    echo "FAIL: ", label
    inc failures
  else:
    echo "ok: ", label

proc sampleSeats(): seq[ChromeSeat] =
  for slot in 0 ..< 6:
    result.add(ChromeSeat(
      slot: slot,
      alias: aliasForSlot(slot),
      name: "cooperative-hunting-pack-caller",
      kind: (if slot < 2: "prompt" else: "scripted"),
      color: slot,
      score: slot * 3,
      energy: 120 - slot,
      level: 1 + (slot mod 4),
      role: (if slot mod 2 == 0: "hunter" else: "forager"),
      dc: slot == 5
    ))

block labelShape:
  let label = buildChromeLabel(
    1080, 120, 2, 3, 960, "play", "staghunt", "",
    sampleSeats(),
    @[ChromeFeedLine(tick: 1078, kind: "catch",
      text: "Cog-A + Cog-C bring down a stag  +5 each")],
    @[ChromeBeat(tick: 210, kind: "round"),
      ChromeBeat(tick: 1078, kind: "bigcatch")],
    nil)
  check("the chrome label is valid UTF-8", validateUtf8(label) == -1)
  check("the chrome label is at most 4 KB", label.len <= MaxChromeLabelBytes)
  var node: JsonNode
  var ok = false
  try:
    node = parseJson(label)
    ok = true
  except CatchableError:
    ok = false
  check("the chrome label is valid JSON", ok)
  if ok:
    for key in ["tick", "rtick", "round", "rounds", "ticksPerRound", "phase",
        "variant", "reason", "seats", "feed", "beats", "final"]:
      check("the label carries " & key, node.hasKey(key))
    check("reason is null while the episode is live",
      node["reason"].kind == JNull)
    check("final is null while the episode is live",
      node["final"].kind == JNull)
    check("every seat carries what the page reads",
      (block:
        var good = true
        for seat in node["seats"]:
          for key in ["slot", "alias", "name", "kind", "color", "score",
              "energy", "level", "role", "dc"]:
            if not seat.hasKey(key): good = false
        good))
    check("the seat count survives", node["seats"].len == 6)
    check("beats ship complete on the frame", node["beats"].len == 2)

block onlyLegalBeatKinds:
  let label = buildChromeLabel(
    10, 10, 1, 3, 960, "play", "staghunt", "", sampleSeats(), @[],
    @[ChromeBeat(tick: 1, kind: "round"),
      ChromeBeat(tick: 2, kind: "bigcatch"),
      ChromeBeat(tick: 3, kind: "smallcatch"),
      ChromeBeat(tick: 4, kind: "tag"),
      ChromeBeat(tick: 5, kind: "end"),
      ChromeBeat(tick: 6, kind: "explosion")],
    nil)
  let node = parseJson(label)
  check("an undeclared beat kind is dropped", node["beats"].len == 5)
  check("only the five declared kinds survive",
    (block:
      var good = true
      for beat in node["beats"]:
        if beat["k"].getStr() notin LegalBeatKinds: good = false
      good))

block beatKindMapping:
  ## Every event the replay may carry maps to a declared beat kind or to
  ## nothing; nothing else is ever emitted.
  var emitted: seq[string] = @[]
  for name in EventVocabulary:
    for kind in ["rabbit", "boar", "stag", "moose", "elephant", "iron",
        "gold", "level 3 food"]:
      let beat = beatKindForEvent(name, %*{"kind": kind})
      if beat.len > 0 and beat notin emitted:
        emitted.add(beat)
  check("every emitted beat kind is declared",
    (block:
      var good = true
      for kind in emitted:
        if kind notin LegalBeatKinds:
          echo "  undeclared beat kind: ", kind
          good = false
      good))
  check("a big animal is a bigcatch",
    beatKindForEvent("catch", %*{"kind": "stag"}) == "bigcatch")
  check("a rabbit is a smallcatch",
    beatKindForEvent("catch", %*{"kind": "rabbit"}) == "smallcatch")
  check("gold is a bigcatch",
    beatKindForEvent("mine", %*{"kind": "gold"}) == "bigcatch")
  check("a tag is a tag", beatKindForEvent("tag", %*{}) == "tag")
  check("the episode end is an end beat",
    beatKindForEvent("episode_end", %*{}) == "end")

block oversizedLabelIsCapped:
  ## A pathological feed must not blow the 4 KB label: feed lines go first,
  ## then beats; the seats block and the clock are what the page cannot
  ## render without.
  var feed: seq[ChromeFeedLine] = @[]
  for i in 0 ..< 200:
    feed.add(ChromeFeedLine(tick: i, kind: "catch", text: repeat("x", 110)))
  var beats: seq[ChromeBeat] = @[]
  for i in 0 ..< 400:
    beats.add(ChromeBeat(tick: i, kind: "smallcatch"))
  let label = buildChromeLabel(1, 1, 1, 3, 960, "play", "staghunt", "",
    sampleSeats(), feed, beats, nil)
  check("an oversized label is capped at 4 KB",
    label.len <= MaxChromeLabelBytes)
  let node = parseJson(label)
  check("the capped label still carries the seats", node["seats"].len == 6)
  check("the capped label still carries the clock", node.hasKey("tick"))

block liveFrameCarriesTheLabel:
  ## The label really does ride as sprite 4090's label in the emitted frame.
  var config = defaultGameConfig()
  config.numAgents = 6
  var sim = initSim(config)
  sim.art.buildSpriteCache()
  for slot in 0 ..< 6:
    discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
  sim.ensureStats(6)
  sim.step(newSeq[InputState](6))
  let label = buildChromeLabel(sim.globalTick, sim.tickCount, 1, 3, 960,
    "play", "staghunt", "", sampleSeats(), @[], @[], nil)
  var state, nextState: ViewerState
  let frame = sim.buildGlobalFrame(label, state, nextState)
  var blob = newString(frame.len)
  for i, b in frame:
    blob[i] = char(b)
  check("the global frame carries the chrome label verbatim",
    label in blob)
  check("the chrome sprite id is the reserved 4090", ChromeSpriteId == 4090)

# ---------------------------------------------------------------------------
# The page: no game-block function may shadow a ChromeCommon alias.
# ---------------------------------------------------------------------------

const ChromeCommonAliases = [
  "$", "RED", "BLUE", "AMBER", "PAPER", "GREEN", "YELLOW", "TEAM_ORDER",
  "TEAM_COLOR", "WIRE", "SPEEDS", "FPS", "teamCol", "activeTeams", "teamOf",
  "otherTeam", "stripSeatSuffix", "teamPolicies", "teamName", "teamHeadline",
  "rosterName", "setName", "handicapInfo", "setHandicap", "perkIconsHtml",
  "teamPerkGroups", "renderTeamMeters", "esc", "fmt", "togglePov",
  "renderClock", "renderTransport", "ingestLullSpans", "renderLullSpans",
  "markBeat", "killMarkerTeam", "renderBeatMarkers", "captureTeam",
  "ingestBeats", "setVerdict", "ingestLeadSeries", "recordMomentum",
  "renderMomentum", "uiToggle", "getSpoilers", "setSpoilers"
]

block pageIsSound:
  let path = getCurrentDir() / "client" / "replay_broadcast.html"
  check("the broadcast page is in the repo", fileExists(path))
  if not fileExists(path):
    quit("test_chrome: the page is missing", 1)
  let page = readFile(path)

  # A hoisted `function markBeat` in the game block shadows the alias and the
  # beats render as unlabeled dead divs (tandem, 2026-08-23).
  var declared: seq[string] = @[]
  for line in page.splitLines():
    let text = line.strip()
    if not text.startsWith("function "):
      continue
    let rest = text["function ".len .. ^1]
    let paren = rest.find('(')
    if paren > 0:
      declared.add(rest[0 ..< paren].strip())
  check("the page declares functions at all", declared.len > 0)
  check("no game-block function shadows a ChromeCommon alias",
    (block:
      var good = true
      for name in declared:
        if name in ChromeCommonAliases:
          echo "  collides with a ChromeCommon alias: ", name
          good = false
      good))
  check("the beat builder is pushHuntBeat", "pushHuntBeat" in declared)

  # Every id chrome_common.js resolves by getElementById must exist.
  const RequiredIds = [
    "btn-loop", "btn-play", "btn-skip", "btn-spoilers", "clock",
    "clock-caption", "clock-time", "ffwd-chip", "ffwd-mini", "lulls",
    "momentum", "scrub", "scrub-fill", "scrub-head", "scrub-win",
    "speedchips", "tick-clock", "transport", "win-chip"
  ]
  for id in RequiredIds:
    check("the page keeps #" & id & " for chrome_common.js",
      ("id=\"" & id & "\"") in page)

  # The elements the design note removes must be gone from the markup.
  const RemovedIds = [
    "fpv", "fpv-canvas", "fpv-cap", "fpv-gear", "fpv-grip", "fpv-hp",
    "fpv-hud", "fpv-map", "fpv-map-canvas", "fpv-name", "lockerroom",
    "lk-art", "lk-bg", "lk-cap", "lk-sprites", "killfeed", "povBadge",
    "mmwarn", "viewpanel", "zoombar", "zoom-in", "zoom-out", "zoom-read",
    "zoom-slider", "minimap", "minimap-canvas"
  ]
  for id in RemovedIds:
    check("#" & id & " is removed", ("id=\"" & id & "\"") notin page)

  check("the feed replaces the kill feed", "id=\"feed\"" in page)
  check("the scorebug is present", "id=\"scorebug\"" in page)
  check("the endcard stops above the transport band",
    "#endcard { bottom: var(--band, 0px); }" in page)
  check("the game block is appended under a banner comment",
    "cooperative-hunting additions to the inherited coworld-ctf chrome" in page)
  check("every beat kind the game emits has CSS",
    (block:
      var good = true
      for kind in LegalBeatKinds:
        if (".beat-marker." & kind) notin page:
          echo "  no CSS for beat kind: ", kind
          good = false
      good))
  check("beats are clickable buttons, not divs",
    "createElement('button')" in page and "beat-marker" in page)
  check("the plate name has the 360 px flex rule",
    ".plate-name { flex: 1 1 auto; min-width: 3.2em;" in page)
  check("labels are hidden under 640 px",
    "@media (max-width: 640px)" in page)
  check("relayout sets --hudscale and --band on documentElement",
    "documentElement" in page and "'--hudscale'" in page and
    "'--band'" in page)
  check("every seek dismisses the endcard",
    "function seekTo" in page and "hideEndcard();" in page)
  check("the page loads the starter's chrome_common.js",
    "chrome_common.js" in page)
  check("the page has no zoom or minimap wiring left",
    "attachMinimap" notin page)

if failures > 0:
  quit("test_chrome: " & $failures & " failures", 1)
echo "test_chrome: all checks passed"
