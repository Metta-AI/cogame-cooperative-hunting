## Native transport evidence; no credentials or synthetic receipt identities.
import std/[base64, json, options, tables, unicode]
import curly
import ./decision_trajectory

proc modelAttempt*(identity, policy, model, url, body: string,
    response: Response, error: string, latency: int): DecisionAttempt =
  result = newDecisionAttempt(identity, policy, aoModel)
  result.model = some(model)
  let request = parseJson(body)
  result.prompt = %*[{"role": "system", "content": request["system"]},
    {"role": "user", "content": request["messages"][0]["content"]}]
  result.request = copy(request)
  result.decoder = %*{"max_tokens": request["max_tokens"]}
  for key in ["temperature", "top_p", "top_k", "output_config"]:
    if request.hasKey(key): result.decoder[key] = request[key]
  result.latencyMs = some(float(latency))
  if response.body.validateUtf8() == -1: result.rawResponse = %response.body
  result.responseBodyB64 = some(encode(response.body))
  result.responseComplete = some(error.len == 0)
  if response.code >= 100 and response.code <= 599: result.httpStatus = some(response.code)
  var received = initTable[string, string]()
  for (key, value) in response.headers: received[key] = value
  result.responseHeaders = some(received)
  if response.headers.contains("X-Softmax-Llm-Call-Id"):
    result.platformCallId = some(response.headers["X-Softmax-Llm-Call-Id"])
  for key in ["request-id", "x-request-id"]:
    if response.headers.contains(key):
      result.providerRequestId = some(response.headers[key])
      break
  if error.len > 0: result.rejectionReason = some(error)
  try:
    let payload = parseJson(response.body)
    if payload{"model"}.getStr().len > 0: result.model = some(payload["model"].getStr())
    if payload{"stop_reason"}.getStr().len > 0:
      result.stopReason = some(payload["stop_reason"].getStr())
      if payload["stop_reason"].getStr() in ["max_tokens", "refusal"]:
        result.rejectionReason = some("native response stopped: " & payload["stop_reason"].getStr())
    if payload.hasKey("usage"):
      if payload["usage"].hasKey("input_tokens"):
        result.inputTokens = some(payload["usage"]["input_tokens"].getInt())
      if payload["usage"].hasKey("output_tokens"):
        result.outputTokens = some(payload["usage"]["output_tokens"].getInt())
  except CatchableError: discard # Original bytes remain authoritative for malformed/error responses.

