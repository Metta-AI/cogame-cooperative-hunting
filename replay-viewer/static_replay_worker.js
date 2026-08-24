'use strict';

// Copied from Metta-AI/coworld-ctf replay-viewer/static_replay_worker.js and
// renamed ctf_* -> ch_* in BOTH the Module._... calls AND the importScripts
// list -- the two are renamed together, never one side. The pairing with
// replay-viewer/config.nims is exact: NO MODULARIZE, NO EXPORT_NAME, so this
// worker waits for Module.onRuntimeInitialized rather than calling a factory
// (a mixture of the two throws nothing, logs nothing and hangs forever --
// cogame-lantern, 2026-08-23).

// broadcast_core.js is shared with the native Window client and its vendored
// Snappy module publishes through `window`. A classic Worker can provide that
// alias without introducing a second implementation or bundle step.
self.window = self;

var Module = {};
var runtimeReady = false;
var initMessage = null;
var runtimeLoaded = false;
var core = null;
var failed = false;
var disposed = false;
var tick = 0;
var tickCount = 1;
var atEnd = false;

function stageNote() {
  // The fixed progress buffer survives an ABORTING_MALLOC failure even though
  // the Emscripten call stack does not.
  try {
    var length = Module._ch_stage_len ? Module._ch_stage_len() : 0;
    if (!length) return '';
    var pointer = Module._ch_stage_ptr();
    return new TextDecoder().decode(
      Module.HEAPU8.slice(pointer, pointer + length));
  } catch (ignored) {
    return '';
  }
}

function runtimeError() {
  var length = Module._ch_error_len();
  if (!length) {
    var stage = stageNote();
    return stage
      ? 'Replay runtime failed while: ' + stage
      : 'Replay runtime rejected the replay';
  }
  var pointer = Module._ch_error_ptr();
  return new TextDecoder().decode(
    Module.HEAPU8.slice(pointer, pointer + length));
}

function reportFailure(error) {
  if (failed || disposed) return;
  failed = true;
  postMessage({
    type: 'error',
    message: error && error.message ? error.message : String(error),
    stage: stageNote()
  });
}

function copyIntoRuntime(bytes, callback) {
  var pointer = Module._malloc(bytes.length);
  try {
    Module.HEAPU8.set(bytes, pointer);
    return callback(pointer, bytes.length);
  } finally {
    Module._free(pointer);
  }
}

function ingestPacket() {
  var length = Module._ch_packet_len();
  if (!length) throw new Error('Replay runtime produced an empty frame');
  var pointer = Module._ch_packet_ptr();
  // BroadcastCore parses synchronously and copies any retained compressed
  // sprite bytes, so it can read the WASM heap view directly.
  core.ingest(Module.HEAPU8.subarray(pointer, pointer + length));
}

function createBroadcastCore(message) {
  core = self.BroadcastCore.create({
    canvas: message.canvas,
    websocket: false,
    playoutBuffer: false,
    viewportWidth: message.width,
    viewportHeight: message.height,
    devicePixelRatio: message.dpr,
    onText: function (text) {
      postMessage({ type: 'text', text: text });
    },
    onStatus: function (status) {
      postMessage({ type: 'status', status: status });
    },
    onFirstFrame: function () {
      postMessage({ type: 'firstFrame' });
    },
    onSendPacket: function () {}
  });
  core.start();
}

async function start() {
  if (!runtimeReady || !initMessage || runtimeLoaded || failed || disposed) return;
  var message = initMessage;
  initMessage = null;
  try {
    createBroadcastCore(message);
    var response = await fetch(message.replayUrl, {
      credentials: 'omit',
      mode: 'cors'
    });
    if (!response.ok) {
      throw new Error('Replay request returned HTTP ' + response.status);
    }
    var bytes = new Uint8Array(await response.arrayBuffer());
    if (!bytes.length) throw new Error('Replay response was empty');
    var loaded = copyIntoRuntime(bytes, function (pointer, length) {
      return Module._ch_load_replay(pointer, length);
    });
    if (!loaded) throw new Error(runtimeError());
    runtimeLoaded = true;
    tickCount = Module._ch_tick_count();
    ingestPacket();
    postMessage({ type: 'loaded', tickCount: tickCount });
  } catch (error) {
    reportFailure(error);
  }
}

function advance(frames) {
  if (!runtimeLoaded || failed || disposed) return;
  try {
    var count = Math.max(1, Math.min(8, Number(frames) || 1));
    var wasEnd = atEnd;
    for (var i = 0; i < count; i++) {
      if (Module._ch_frame() < 0) throw new Error(runtimeError());
      ingestPacket();
      if (tick + 1 >= tickCount) {
        atEnd = true;
      } else {
        tick += 1;
      }
    }
    postMessage({
      type: 'advanced',
      tick: tick,
      ended: atEnd && !wasEnd
    });
  } catch (error) {
    reportFailure(error);
  }
}

function seek(target) {
  if (!runtimeLoaded || failed || disposed) return;
  try {
    if (Module._ch_seek(target) < 0) throw new Error(runtimeError());
    ingestPacket();
    tick = Math.max(0, Math.min(tickCount - 1, target));
    atEnd = tick >= tickCount - 1;
    postMessage({ type: 'advanced', tick: tick, ended: false });
  } catch (error) {
    reportFailure(error);
  }
}

Module.locateFile = function (path) {
  return new URL(path, self.location.href).toString();
};
Module.onAbort = function (what) {
  var stage = stageNote();
  reportFailure(new Error('Replay runtime ran out of memory (' + what +
    ') - wasm32 is limited to 2 GB' +
    (stage ? '. Failed while: ' + stage : '')));
};
Module.onRuntimeInitialized = function () {
  runtimeReady = true;
  start();
};
self.Module = Module;

self.onmessage = function (event) {
  var message = event.data || {};
  try {
    if (message.type === 'init') {
      initMessage = message;
      start();
    } else if (message.type === 'advance') {
      advance(message.frames);
    } else if (message.type === 'seek') {
      seek(Number(message.tick) || 0);
    } else if (message.type === 'command') {
      if (runtimeLoaded && !failed && !disposed) {
        var text = String(message.text || '');
        var bytes = new TextEncoder().encode(text);
        copyIntoRuntime(bytes, function (pointer, length) {
          Module._ch_input(pointer, length);
          return 0;
        });
        ingestPacket();
      }
    } else if (message.type === 'resize' && core) {
      core.setViewportSize(message.width, message.height, message.dpr);
    } else if (message.type === 'dispose') {
      disposed = true;
      if (core) core.stop();
      close();
    }
  } catch (error) {
    reportFailure(error);
  }
};

importScripts('./broadcast_core.js', './cooperative_hunting_replay.js');
