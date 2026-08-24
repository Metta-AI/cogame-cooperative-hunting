version     = "0.1.0"
author      = "coworld-builder"
description = "Cooperative Hunting cogame: a BitWorld forest where rabbits go down alone but boars, stags, moose and elephants need coordinated encirclement, with coop-mining, level-based-foraging and predator-prey variants."
license     = "MIT"

srcDir = "src"
bin = @["cooperative_hunting", "cooperative_hunting_player"]

switch("threads", "on")
switch("mm", "orc")

requires "nim >= 2.2.4"
requires "bitworld >= 0.1.0"
requires "mummy >= 0.4.7"
requires "pixie"
requires "supersnappy >= 2.1.3"
requires "whisky >= 0.1.3"
requires "curly >= 1.1.1"
