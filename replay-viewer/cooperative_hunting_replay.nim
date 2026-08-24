## The wasm replay module.
##
## Copied from `Metta-AI/coworld-ctf`'s `replay-viewer/ctf_replay.nim` and
## retargeted: `ctf_*` -> `ch_*`, our modules, our replay format. The fixed
## `stageNote` buffer is kept verbatim -- it is what survives an
## ABORTING_MALLOC failure and lets the page report what the runtime was
## doing when linear memory ran out.
##
## The pipeline: `ch_load_replay` parses the JSON document, then each
## `ch_frame` rebuilds that tick's `SimServer` state from `ticks[i]` and
## calls the SAME `buildGlobalFrame` the live server uses, so the hosted
## replay is drawn by the game's own code and its own PNG sprites.

import std/json
import cooperative_hunting/[sim, art, frames, replay]

var
  runtimeLoaded = false
  doc: ReplayDoc
  game: SimServer
  viewer: ViewerState
  packet: seq[uint8]
  lastError: string
  cursor = 0
  beats: seq[ChromeBeat]
  seenEvents = 0

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals. The bundle is linked with -s ABORTING_MALLOC=1 and
## this fixed buffer, stamped BEFORE each risky phase, stays readable from JS
## after the abort (aborting kills the call stack, not the linear memory).
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc chromeSeatsNow(): seq[ChromeSeat] =
  for i, seat in doc.seats:
    if i >= game.players.len:
      break
    let p = game.players[i]
    result.add(ChromeSeat(
      slot: seat.slot,
      alias: seat.alias,
      name: seat.name,
      kind: seat.kind,
      color: seat.color,
      score: p.score,
      energy: p.energy,
      level: seat.level,
      role: (if p.role == roleHunter: "hunter" else: "forager"),
      dc: p.disconnected
    ))

proc finalNodeNow(): JsonNode =
  ## The endcard payload, present only on the last tick.
  if cursor < doc.ticks.high:
    return nil
  let results = doc.raw{"results"}
  if results.isNil:
    return nil
  var order = newJArray()
  var indices: seq[int] = @[]
  for i in 0 ..< doc.seats.len:
    indices.add(i)
  let scores = results{"scores"}
  proc scoreOf(i: int): int =
    if not scores.isNil and scores.kind == JArray and i < scores.len:
      scores[i].getInt()
    else: 0
  for i in 0 ..< indices.high:
    for j in 0 ..< indices.high - i:
      if scoreOf(indices[j]) < scoreOf(indices[j + 1]):
        swap(indices[j], indices[j + 1])
  for i in indices:
    order.add(%*{
      "alias": doc.seats[i].alias,
      "name": doc.seats[i].name,
      "score": scoreOf(i)
    })
  %*{"reason": results{"reason"}.getStr("complete"), "order": order}

proc renderCurrent() =
  ## The chrome label carries the beats COMPLETE on the first frame and only
  ## the feed lines new since the previous frame, exactly as the live server
  ## emits them.
  var feed: seq[ChromeFeedLine] = @[]
  let frame = doc.ticks[cursor]
  if not frame.ev.isNil and frame.ev.kind == JArray:
    for event in frame.ev:
      let line = feedLineFor(event{"ev"}.getStr(), event)
      if line.text.len > 0:
        feed.add(ChromeFeedLine(tick: frame.tick, kind: line.kind,
          text: line.text))
  inc seenEvents
  let label = buildChromeLabel(
    frame.tick,
    game.tickCount,
    frame.roundNo,
    doc.config.rounds,
    doc.config.ticksPerRound,
    frame.phase,
    doc.variant,
    "",
    chromeSeatsNow(),
    feed,
    beats,
    finalNodeNow()
  )
  var nextViewer: ViewerState
  packet = game.buildGlobalFrame(label, viewer, nextViewer)
  viewer = nextViewer

proc chLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "ch_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    doc = parseReplayDoc(data.bytesFromPointer(int(length)))
    if doc.ticks.len == 0:
      raise newException(ValueError, "replay carries no ticks")
    stampStage("load sprites")
    game = initSimFromDoc(doc)
    game.art.buildSpriteCache()
    viewer = ViewerState()
    cursor = 0
    beats = @[]
    for beat in doc.allBeats():
      beats.add(ChromeBeat(tick: beat.tick, kind: beat.kind))
    runtimeLoaded = true
    frameStage = "advance replay (" & $doc.ticks.len & " ticks)"
    stampStage("render first frame")
    game.applyTick(doc, cursor)
    renderCurrent()
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc chSeek(index: cint): cint {.exportc: "ch_seek", cdecl.} =
  ## Seek to a frame INDEX (0 .. tick_count-1). The page's scrubber works in
  ## indices; the clock it prints comes from the chrome label.
  if not runtimeLoaded:
    return 0
  try:
    cursor = max(0, min(int(index), doc.ticks.high))
    game.applyTick(doc, cursor)
    renderCurrent()
    return 1
  except Exception as error:
    lastError = "seek: " & error.msg
    return -1

proc chFrame(): cint {.exportc: "ch_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    if cursor < doc.ticks.high:
      inc cursor
    game.applyTick(doc, cursor)
    renderCurrent()
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc chInput(data: ptr uint8, length: cint) {.exportc: "ch_input", cdecl.} =
  ## One-byte viewer commands from the page's chips. 'g' toggles tall grass
  ## between opaque and 40 % alpha so a spectator can see the ambush the
  ## hunter could not (the idea's grass-opacity toggle).
  if not runtimeLoaded or length <= 0:
    return
  let text = data.bytesFromPointer(int(length))
  for ch in text:
    if ch == 'g':
      game.grassDim = not game.grassDim
  try:
    renderCurrent()
  except Exception as error:
    lastError = "input: " & error.msg

proc chTickCount(): cint {.exportc: "ch_tick_count", cdecl.} =
  if runtimeLoaded: cint(doc.ticks.len) else: 0

proc chPacketPointer(): ptr uint8 {.exportc: "ch_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc chPacketLength(): cint {.exportc: "ch_packet_len", cdecl.} =
  cint(packet.len)

proc chMismatchTick(): cint {.exportc: "ch_mismatch_tick", cdecl.} =
  ## The replay is recorded state, not recorded inputs, so there is no hash
  ## to mismatch. Always -1; the shell's warning banner never shows.
  -1

proc chErrorPointer(): ptr uint8 {.exportc: "ch_error_ptr", cdecl.} =
  if lastError.len == 0: nil
  else: cast[ptr uint8](lastError[0].addr)

proc chErrorLength(): cint {.exportc: "ch_error_len", cdecl.} =
  cint(lastError.len)

proc chStagePointer(): ptr uint8 {.exportc: "ch_stage_ptr", cdecl.} =
  ## Unlike ch_error_*, this stays valid after an allocation-failure abort,
  ## so JS can report what the runtime was doing when it died.
  if stageNoteLen == 0: nil
  else: cast[ptr uint8](stageNote[0].addr)

proc chStageLength(): cint {.exportc: "ch_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it
  # returns, freeing the sprite cache and the parsed document while the wasm
  # module stays alive and JS keeps calling ch_frame. Unwinding main through
  # emscripten's live-runtime exit skips the destructor epilogue entirely.
  emscriptenExitWithLiveRuntime()
