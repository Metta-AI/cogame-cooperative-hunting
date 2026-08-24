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
  check("the chrome label is inside the label cap",
    label.len <= MaxChromeLabelBytes)
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

block manifestLengthEpisodeKeepsEveryBeat:
  ## `beats` ships COMPLETE on the first frame, and the trim loop drops the
  ## EARLIEST beats first -- so a cap that a full-length episode overruns
  ## costs the scrubber the opening of the hunt, silently. The longest
  ## shipped variant is 3 rounds x 960 ticks; the certification replay ran
  ## 0.042 beats/tick, so budget 150 beats here (more than the ~127 that
  ## rate implies), with every seat speaking at the rune cap on the same
  ## frame.
  var beats: seq[ChromeBeat] = @[]
  for i in 0 ..< 150:
    beats.add(ChromeBeat(tick: i * 19,
      kind: (if i mod 37 == 0: "bigcatch" else: "smallcatch")))
  var feed: seq[ChromeFeedLine] = @[]
  for slot in 0 ..< 6:
    feed.add(ChromeFeedLine(tick: 2870, kind: "say",
      text: "Cog-" & $chr(ord('A') + slot) & ": " &
        repeat("\u{72E9}", MaxSayRunes - 8)))
  let full = buildChromeLabel(2880, 960, 3, 3, 960, "play", "staghunt", "",
    sampleSeats(), feed, beats, nil)
  check("a full-length episode's label is inside the cap",
    full.len <= MaxChromeLabelBytes)
  let fullNode = parseJson(full)
  check("not one beat of a full-length episode is dropped",
    fullNode["beats"].len == beats.len)
  check("the first beat survives, so the scrubber keeps the opening",
    fullNode["beats"][0]["t"].getInt() == 0)
  check("every seat still speaks on that frame", fullNode["feed"].len == 6)

block oversizedLabelIsCapped:
  ## A pathological feed must not blow the label cap: feed lines go first,
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
  check("an oversized label is capped",
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

block worstCaseFixtureIsReachable:
  ## tools/ci/fixtures/worst_case_chrome.json is the frame ci.yml's
  ## worst-case renderer fixture hands the real page (acceptance checklist
  ## item 15). It is only worth rendering if it is a label buildChromeLabel
  ## could actually emit: the same keys, every string at the real cap, legal
  ## beat kinds, inside the label cap. A fixture whose strings quietly
  ## drift short leaves the gate passing while testing nothing.
  let path = getCurrentDir() / "tools" / "ci" / "fixtures" /
    "worst_case_chrome.json"
  check("the worst-case fixture frame is in the repo", fileExists(path))
  if fileExists(path):
    let fixture = parseJson(readFile(path))
    let real = parseJson(buildChromeLabel(
      2880, 960, 3, 3, 960, "play", "predator-prey", "", sampleSeats(),
      @[ChromeFeedLine(tick: 2870, kind: "say",
        text: "Cog-A: hold the north side until I say go")],
      @[ChromeBeat(tick: 40, kind: "round")],
      %*{"reason": "complete",
         "order": [{"alias": "Cog-A", "name": "pack-caller", "score": 12}]}))
    check("the fixture carries exactly the keys buildChromeLabel emits",
      (block:
        var good = true
        for key, value in real.pairs:
          if not fixture.hasKey(key):
            echo "  the fixture is missing ", key, " (", value.kind, ")"
            good = false
        for key, value in fixture.pairs:
          if not real.hasKey(key):
            echo "  the fixture carries an extra key: ", key,
              " (", value.kind, ")"
            good = false
        good))
    check("every fixture seat carries what a real seat carries",
      (block:
        var good = true
        for seat in fixture["seats"]:
          for key, value in real["seats"][0].pairs:
            if not seat.hasKey(key):
              echo "  a fixture seat is missing ", key, " (", value.kind, ")"
              good = false
        good))
    check("the fixture speaks on every seat at once",
      fixture["seats"].len == 6 and fixture["feed"].len == 6)
    check("every fixture remark is at the server's rune cap",
      (block:
        var good = true
        for line in fixture["feed"]:
          let runeCount = line["text"].getStr().runeLen
          if runeCount != MaxSayRunes:
            echo "  a fixture remark is ", runeCount, " runes, not ",
              MaxSayRunes
            good = false
        good))
    check("every fixture policy name is at the name cap",
      (block:
        var good = true
        for seat in fixture["seats"]:
          let runeCount = seat["name"].getStr().runeLen
          if runeCount != MaxNameRunes:
            echo "  a fixture name is ", runeCount, " runes, not ",
              MaxNameRunes
            good = false
        good))
    check("the fixture's feed kinds are the ones feedLineFor emits",
      (block:
        let kindsEmitted = [
          feedLineFor("plan", %*{"alias": "Cog-A", "say": "go north"}).kind,
          feedLineFor("fallback", %*{"alias": "Cog-F",
            "baseline": "big_game_hunter", "cause": "no_credentials"}).kind]
        var good = true
        for line in fixture["feed"]:
          if line["kind"].getStr() notin kindsEmitted:
            echo "  the fixture carries a kind the game never emits: ",
              line["kind"].getStr()
            good = false
        good))
    check("every fixture beat kind is one the page has CSS for",
      (block:
        var good = true
        for beat in fixture["beats"]:
          if beat["k"].getStr() notin LegalBeatKinds:
            echo "  illegal fixture beat kind: ", beat["k"].getStr()
            good = false
        good))
    # The strongest anti-drift check available: feed the fixture's own
    # contents back through buildChromeLabel. If the emitter trims a feed
    # line, drops a beat for the label cap or rune-caps a string, the frame
    # the fixture renders is not one this game can produce.
    var seats: seq[ChromeSeat] = @[]
    for seat in fixture["seats"]:
      seats.add(ChromeSeat(
        slot: seat["slot"].getInt(),
        alias: seat["alias"].getStr(),
        name: seat["name"].getStr(),
        kind: seat["kind"].getStr(),
        color: seat["color"].getInt(),
        score: seat["score"].getInt(),
        energy: seat["energy"].getInt(),
        level: seat["level"].getInt(),
        role: seat["role"].getStr(),
        dc: seat["dc"].getBool()))
    var feed: seq[ChromeFeedLine] = @[]
    for line in fixture["feed"]:
      feed.add(ChromeFeedLine(
        tick: line["t"].getInt(),
        kind: line["kind"].getStr(),
        text: line["text"].getStr()))
    var beats: seq[ChromeBeat] = @[]
    for beat in fixture["beats"]:
      beats.add(ChromeBeat(
        tick: beat["t"].getInt(), kind: beat["k"].getStr()))
    let emitted = buildChromeLabel(
      fixture["tick"].getInt(), fixture["rtick"].getInt(),
      fixture["round"].getInt(), fixture["rounds"].getInt(),
      fixture["ticksPerRound"].getInt(), fixture["phase"].getStr(),
      fixture["variant"].getStr(), "", seats, feed, beats, fixture["final"])
    check("the fixture fits the label cap, so it is reachable",
      emitted.len <= MaxChromeLabelBytes)
    check("the real emitter reproduces the fixture frame exactly",
      parseJson(emitted) == fixture)

if failures > 0:
  quit("test_chrome: " & $failures & " failures", 1)
echo "test_chrome: all checks passed"
