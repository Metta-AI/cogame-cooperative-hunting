import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route every allocation through emscripten's malloc (the standard Nim
# emscripten setup). With Nim's bundled allocator a bad free silently poisons
# the freelists; dlmalloc traps loudly instead.
--define:useMalloc

# ENVIRONMENT includes worker because the shipped static bundle owns the WASM
# runtime in a Dedicated Worker, and node so the module can be smoke-run
# headless. ABORTING_MALLOC matters: with -d:useMalloc Nim never checks
# malloc for nil and wasm32 has no memory protection, so a failed allocation
# would otherwise write a seq header through the nil pointer into address 0.
#
# NO MODULARIZE, NO EXPORT_NAME. This is the paintbot pairing: the shell
# waits for Module.onRuntimeInitialized and the module publishes itself on
# the global `Module`. A babel-lineage factory call spliced onto these flags
# throws nothing, logs nothing and hangs on "Loading replay..." forever
# (cogame-lantern, 2026-08-23), so the two halves must never be mixed.
switch(
  "passL",
  (&"""
  -o {distDir / "cooperative_hunting_replay.js"}
  --preload-file {rootDir / "sprites"}@sprites
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s ABORTING_MALLOC=1
  -s FILESYSTEM=1
  -s ENVIRONMENT=web,worker,node
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_ch_load_replay,_ch_frame,_ch_seek,_ch_input,_ch_tick_count,_ch_packet_ptr,_ch_packet_len,_ch_mismatch_tick,_ch_error_ptr,_ch_error_len,_ch_stage_ptr,_ch_stage_len
  """).replace("\n", " ")
)
