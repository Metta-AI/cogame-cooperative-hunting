## Reply handling: tolerant extraction, the enum coercions, the rune caps,
## the single retry on an illegal target, and -- the load-bearing one -- the
## no-credentials path making ZERO network calls.

import std/[json, strutils, unicode]
import cooperative_hunting/[sim, llm]

var failures = 0
proc check(label: string, condition: bool) =
  if not condition:
    echo "FAIL: ", label
    inc failures
  else:
    echo "ok: ", label

const Legal = @["stag@13,17", "rabbit@18,21", "none"]
const Aliases = @["Cog-A", "Cog-B", "Cog-C", "Cog-D", "Cog-E", "Cog-F"]

proc parseText(text: string): Plan =
  parsePlan(extractJsonObject(text), 7, Legal, Aliases)

block cleanJson:
  let plan = parseText("""{"intent":"hunt","target":"stag@13,17","side":"S",
    "with":["Cog-A"],"say":"north side","note":"pair with A"}""")
  check("a clean reply parses", plan.target == "stag@13,17")
  check("the intent survives", plan.intent == "hunt")
  check("the side survives", plan.side == "S")
  check("the ally list survives", plan.partners == @["Cog-A"])
  check("say survives", plan.say == "north side")
  check("note survives", plan.note == "pair with A")
  check("src is llm", plan.src == "llm")

block trailingProse:
  let plan = parseText(
    """{"intent":"assist","target":"none","side":"N"} -- I will help Cog-A.""")
  check("trailing prose is tolerated", plan.target == "none")
  check("the intent survives trailing prose", plan.intent == "assist")

block leadingProse:
  let plan = parseText(
    "Here is my plan:\n```json\n{\"intent\":\"flee\",\"target\":\"none\"}\n```")
  check("leading prose and a fence are tolerated", plan.intent == "flee")

block nestedBraces:
  let plan = parseText(
    """{"intent":"hunt","target":"none","note":"a } inside a string"}""")
  check("a brace inside a string does not end the object",
    plan.note == "a } inside a string")

block missingFieldsDefault:
  let plan = parseText("""{"target":"none"}""")
  check("a missing intent defaults to hunt", plan.intent == "hunt")
  check("a missing side defaults to any", plan.side == "any")
  check("a missing with is empty", plan.partners.len == 0)
  check("a missing say is empty", plan.say.len == 0)

block enumCoercion:
  let plan = parseText(
    """{"intent":"ponder","target":"none","side":"northwest"}""")
  check("an unknown intent becomes hunt", plan.intent == "hunt")
  check("an unknown side becomes any", plan.side == "any")

block allyFiltering:
  let plan = parseText(
    """{"target":"none","with":["Cog-A","nobody","Cog-B","Cog-C","Cog-D"]}""")
  check("non-alias entries are dropped", "nobody" notin plan.partners)
  check("the ally list is capped at three items",
    plan.partners.len <= MaxWithItems)

block illegalTarget:
  var raised = false
  try:
    discard parseText("""{"intent":"hunt","target":"dragon@1,1"}""")
  except CatchableError as error:
    raised = "LEGAL TARGETS" in error.msg
  check("a target outside LEGAL TARGETS is illegal", raised)

block retryContract:
  ## An unusable reply is retried EXACTLY once, with a hint that names the
  ## two things that went wrong most often; after that the seat falls back.
  check("the retry hint demands a leading brace",
    "beginning with {" in RetryHint)
  check("the retry hint names LEGAL TARGETS",
    "LEGAL TARGETS" in RetryHint)
  check("every fallback cause the design lists exists",
    (block:
      var seen: seq[string] = @[]
      for cause in FallbackCause:
        seen.add($cause)
      "timeout" in seen and "parse" in seen and "illegal_target" in seen and
        "rate_budget" in seen and "no_credentials" in seen))

block unparseable:
  var raised = false
  try:
    discard parseText("I would like to hunt the stag, please.")
  except CatchableError:
    raised = true
  check("a reply with no balanced object is rejected", raised)

block runeTruncation:
  ## Over-long free text is cut on a RUNE boundary and marked, never on a
  ## byte boundary.
  let longSay = repeat("\u{1F98C}", 400)
  let longNote = repeat("\u00e9", 500)
  let plan = parseText($(%*{
    "intent": "hunt", "target": "none", "say": longSay, "note": longNote
  }))
  check("say is capped at 120 runes", plan.say.runeLen <= MaxSayRunes)
  check("note is capped at 200 runes", plan.note.runeLen <= MaxNoteRunes)
  check("the truncated say is still valid UTF-8",
    validateUtf8(plan.say) == -1)
  check("the truncated note is still valid UTF-8",
    validateUtf8(plan.note) == -1)
  check("the truncation is marked", plan.say.endsWith("\u2026"))

block controlCharacters:
  let plan = parseText($(%*{
    "target": "none", "say": "line one\nline two\ttabbed"
  }))
  check("control characters are collapsed to spaces",
    '\n' notin plan.say and '\t' notin plan.say)

block noCredentialsMakesNoCalls:
  ## The load-bearing fallback: with no credentials the client marks itself
  ## disabled at startup and makes NO network calls at all, so offline
  ## certification still completes.
  let client = newDisabledLlmClient()
  check("a client with no credentials is disabled", client.disabled)
  var requests: seq[PlanRequest] = @[]
  var legal: seq[seq[string]] = @[]
  for slot in 0 ..< 6:
    requests.add(PlanRequest(slot: slot, system: "s", user: "u"))
    legal.add(Legal)
  let replies = client.runPlanBatch(requests, legal, Aliases, 1)
  check("every seat comes back", replies.len == 6)
  check("no request was issued", client.totalRequests == 0)
  check("every seat reports the no_credentials cause",
    (block:
      var ok = true
      for reply in replies:
        if reply.ok or reply.cause != fcNoCredentials: ok = false
      ok))

block rateBudget:
  ## The hard rolling budget is 28 requests per 60 s, retries included.
  let client = newDisabledLlmClient()
  check("a fresh budget admits a full six-seat turn",
    client.budgetAvailable(6))
  check("the budget refuses more than 28 at once",
    not client.budgetAvailable(RateBudgetRequests + 1))

block observationIsBounded:
  ## The observation is deterministic and bounded; every list has a cap.
  var config = defaultGameConfig()
  config.numAgents = 6
  var sim = initSim(config)
  for slot in 0 ..< 6:
    discard sim.addPlayer("p" & $slot, aliasForSlot(slot), slot)
  sim.ensureStats(6)
  for _ in 0 ..< 400:
    sim.step(newSeq[InputState](6))
  let prompt = repeat("strategy ", 400)
  let observation = sim.observationFor(0, 7, 25, Plan(), "a note", @[], prompt)
  check("the observation is deterministic",
    observation == sim.observationFor(0, 7, 25, Plan(), "a note", @[], prompt))
  check("the observation names the seat's own alias",
    sim.players[0].alias in observation)
  check("the observation ships LEGAL TARGETS",
    "LEGAL TARGETS:" in observation)
  check("the observation always offers `none` as a legal target",
    "none" in sim.legalTargets(0))
  check("the strategy block is rune-capped",
    observation.runeLen < 4000)
  let systemPrompt = systemPromptFor(prompt)
  check("the system prompt demands a leading brace",
    "MUST begin with the character {" in systemPrompt)
  check("the system prompt carries the schema",
    "\"intent\"" in systemPrompt)

if failures > 0:
  quit("test_llm_reply: " & $failures & " failures", 1)
echo "test_llm_reply: all checks passed"
