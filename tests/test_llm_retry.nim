## Exactly ONE retry, then the fallback -- driven end to end through the real
## transport.
##
## Checklist item 8 says the reply path "retries ONCE on a parse or transport
## failure, then falls back to the scripted move". `runPlanBatch`'s
## `for attempt in 0 .. 1` says so too, but reading a loop bound is not a
## test: nothing here ever drove the loop, so a second retry (a request
## storm against the sidecar's per-episode cap) or a missing one (a seat
## thrown away on one bad reply) would both have shipped green.
##
## The client's Bedrock endpoint comes from AWS_ENDPOINT_URL_BEDROCK_RUNTIME,
## so pointing it at a local stub is enough to drive the real code path --
## the real requestFor, the real curly batch, the real textOf, the real
## parsePlan -- with no seam added to the production client.

import std/[json, locks, net, os, strutils]
import mummy
import cooperative_hunting/[sim_types, llm]

var failures = 0
proc check(label: string, condition: bool) =
  if not condition:
    echo "FAIL: ", label
    inc failures
  else:
    echo "ok: ", label

const
  StubPort = 8477
  GoodTarget = "stag@13,17"
  BadTarget = "moose@99,99"     ## never in LEGAL TARGETS, so parsePlan raises

var
  stubLock: Lock
  stubCount = 0                 ## requests this scenario has served
  stubBodies: seq[string] = @[]
  stubAlwaysBad = false

initLock(stubLock)

proc replyText(target: string): string =
  $(%*{
    "content": [{
      "type": "text",
      "text": $(%*{
        "intent": "hunt", "target": target, "side": "N",
        "with": ["Cog-B"], "say": "north side", "note": "pair with B"})
    }],
    "stop_reason": "end_turn"
  })

proc stubHandler(request: Request) {.gcsafe.} =
  var attempt = 0
  var bad = false
  {.gcsafe.}:
    withLock stubLock:
      inc stubCount
      attempt = stubCount
      stubBodies.add(request.body)
      bad = stubAlwaysBad
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  # Attempt 1 answers with a target outside LEGAL TARGETS -- the failure the
  # design note names as the one that must trigger the single retry.
  request.respond(200, headers,
    replyText(if bad or attempt == 1: BadTarget else: GoodTarget))

let stubServer = newServer(stubHandler)

proc serveStub() {.thread.} =
  {.gcsafe.}:
    stubServer.serve(Port(StubPort), "127.0.0.1")

var stubThread: Thread[void]
createThread(stubThread, serveStub)

proc stubIsUp(): bool =
  ## mummy exposes no readiness signal, so ask the socket.
  try:
    let probe = newSocket()
    defer: probe.close()
    probe.connect("127.0.0.1", Port(StubPort), timeout = 250)
    true
  except CatchableError:
    false

proc waitForStub() =
  for _ in 0 ..< 200:
    if stubIsUp():
      return
    sleep(25)
  quit("test_llm_retry: the stub endpoint never came up", 1)

waitForStub()

proc resetStub(alwaysBad: bool) =
  withLock stubLock:
    stubCount = 0
    stubBodies.setLen(0)
    stubAlwaysBad = alwaysBad

putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:" & $StubPort)
putEnv("AWS_BEARER_TOKEN_BEDROCK", "stub-token")
putEnv("BEDROCK_MODEL", "stub-model")

var config = defaultGameConfig()
config.planTimeoutSeconds = 5   ## bounded: a wedged stub fails, never hangs
let client = newLlmClient(config)
let legal = @[@[GoodTarget, "none"]]
let aliases = @["Cog-A", "Cog-B"]
let requests = @[PlanRequest(slot: 0, system: "system", user: "observation")]

block oneRetryThenAPlan:
  ## An illegal target on the first attempt, a good one on the retry: the
  ## seat comes back with a real plan and the endpoint saw EXACTLY two
  ## requests.
  resetStub(alwaysBad = false)
  let replies = client.runPlanBatch(requests, legal, aliases, turn = 3)
  check("the seat comes back", replies.len == 1)
  check("the retried seat has a plan", replies[0].ok)
  check("the plan is the retry's answer", replies[0].plan.target == GoodTarget)
  check("the plan is attributed to the model", replies[0].plan.src == "llm")
  var served = 0
  var second = ""
  withLock stubLock:
    served = stubCount
    if stubBodies.len > 1:
      second = stubBodies[1]
  check("exactly one retry: two requests for one seat", served == 2)
  check("the retry carried the retry hint", RetryHint in second)
  check("the retry hint is not in the first request",
    (block:
      var first = ""
      withLock stubLock:
        if stubBodies.len > 0:
          first = stubBodies[0]
      RetryHint notin first))

block thenTheFallback:
  ## An illegal target on BOTH attempts: no third request, and the seat comes
  ## back with `ok == false` and the cause that routes it to the scripted
  ## baseline -- which is what pollPlanBatch records as a fallback.
  resetStub(alwaysBad = true)
  let replies = client.runPlanBatch(requests, legal, aliases, turn = 4)
  check("the seat still comes back", replies.len == 1)
  check("a seat that fails twice does not come back with a plan",
    not replies[0].ok)
  check("the cause is the illegal target",
    replies[0].cause == fcIllegalTarget)
  check("the recorded error is rune-capped and valid UTF-8",
    replies[0].error.len > 0 and replies[0].error.len <= MaxErrorRunes * 4)
  var served = 0
  withLock stubLock:
    served = stubCount
  check("the retry happens once, not twice: two requests, not three",
    served == 2)

stubServer.close()

if failures > 0:
  quit("test_llm_retry: " & $failures & " failures", 1)
echo "test_llm_retry: all checks passed"
