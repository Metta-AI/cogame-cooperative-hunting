import std/json
import cooperative_hunting
import cooperative_hunting/[sim, sim_types]

proc seatInfo(sim: SimServer, slot: int): JsonNode =
  let packet = sim.seatInfoPacket(slot)
  doAssert packet[0] == 0x92'u8
  let length = int(packet[1]) or (int(packet[2]) shl 8)
  doAssert packet.len == length + 3
  var body = newString(length)
  for index in 0 ..< length:
    body[index] = char(packet[index + 3])
  parseJson(body)

var config = defaultGameConfig()
config.variant = "predator-prey"
config.numAgents = 2
var world = initSim(config)
for slot in 0 ..< config.numAgents:
  discard world.addPlayer("p" & $slot, aliasForSlot(slot), slot)
world.applyRolesPublic()
world.players[0].tileX = 12
world.players[0].tileY = 12
world.players[1].tileX = 16
world.players[1].tileY = 12
world.tallGrass[tileIndex(16, 12)] = true

let hidden = world.seatInfo(0)
doAssert hidden["variant"].getStr() == "predator-prey"
doAssert hidden["role"].getStr() == "hunter"
doAssert hidden["round"].getInt() == 0
doAssert not world.visibleToSeat(0, 1)
for player in hidden["visible_players"]:
  doAssert player["object_id"].getInt() != PlayerObjectBase + 1

world.players[1].tileX = 14
world.tallGrass[tileIndex(14, 12)] = true
let revealed = world.seatInfo(0)
doAssert world.visibleToSeat(0, 1)
var found = false
for player in revealed["visible_players"]:
  if player["object_id"].getInt() == PlayerObjectBase + 1:
    doAssert player["role"].getStr() == "forager"
    found = true
doAssert found

echo "Cooperative Hunting seat information: hidden and revealed roles passed"
