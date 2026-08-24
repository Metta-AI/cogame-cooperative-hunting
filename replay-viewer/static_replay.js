(function () {
  'use strict';

  // Copied from Metta-AI/coworld-ctf replay-viewer/static_replay.js (the
  // paintbot shell: an OffscreenCanvas handed to a Dedicated Worker that owns
  // the wasm runtime and BroadcastCore). Renamed ctf_* -> ch_*, worker name
  // `cooperative-hunting-static-replay`, plus the two deltas the design note
  // requires and a transport (play/pause/speed/seek) the page drives.

  var failed = false;
  var scriptUrl = document.currentScript && document.currentScript.src;
  var workerUrl = new URL('./static_replay_worker.js', scriptUrl || location.href);

  // VIEWER -> HOST READINESS. An embedding page (the softmax.com theater, the
  // Observatory episode page) only sees this document's `load` event, which
  // fires long before the wasm module has compiled and the replay has come
  // back from S3. So the shell tells the parent what it is doing: `loading`
  // as soon as this script runs, `ready` once the renderer has drawn its
  // FIRST FRAME, `error` when the replay cannot be shown.
  function tell(type, message) {
    if (window.parent === window) return;
    var envelope = { src: 'coworld-replay', type: type };
    if (message) envelope.message = message;
    try { window.parent.postMessage(envelope, '*'); } catch (ignore) {}
  }
  tell('loading');

  function showFailure(error) {
    // First failure wins: an OOM abort reports once from the Worker (with the
    // stage note), then may also surface as an error event. Keep the specific
    // diagnostic instead of overwriting it with the generic one.
    if (failed) return;
    failed = true;
    console.error(error);
    var message = (error && error.message) || String(error);
    var status = document.getElementById('status');
    if (status) {
      status.textContent = 'Replay failed: ' + message;
      status.classList.add('show');
    }
    // DELTA (a): paintbot only writes #status. tools/ci/viewer_smoke.mjs
    // fails on this attribute, which is how a broken bundle goes red instead
    // of hanging silently until the timeout.
    document.documentElement.setAttribute('data-replay-error', message);
    tell('error', message);
  }

  function createCore(config) {
    var canvas = config.canvas;
    var worker = null;
    var started = false;
    var loaded = false;
    var advanceInFlight = false;
    var lastFrame = 0;
    var accumulator = 0;
    var baseFrameMs = 1000 / 24;
    var speed = 1;
    var playing = true;
    var tick = 0;
    var tickCount = 1;
    var viewport = { width: 1, height: 1, dpr: window.devicePixelRatio || 1 };
    var offscreen;

    if (!canvas || typeof canvas.transferControlToOffscreen !== 'function') {
      showFailure(new Error('This browser does not support OffscreenCanvas Workers'));
    } else {
      try {
        offscreen = canvas.transferControlToOffscreen();
      } catch (error) {
        showFailure(error);
      }
    }

    function readViewport() {
      var rect = canvas.getBoundingClientRect();
      viewport = {
        width: Math.max(1, rect.width || canvas.clientWidth || 1),
        height: Math.max(1, rect.height || canvas.clientHeight || 1),
        dpr: window.devicePixelRatio || 1
      };
      return viewport;
    }

    function postViewport() {
      readViewport();
      if (worker && started) {
        worker.postMessage({
          type: 'resize',
          width: viewport.width,
          height: viewport.height,
          dpr: viewport.dpr
        });
      }
    }

    function animate(now) {
      if (failed || !loaded || !worker) return;
      if (!lastFrame) lastFrame = now;
      var frameMs = baseFrameMs / Math.max(0.25, speed);
      accumulator = Math.min(accumulator + Math.min(now - lastFrame, 250), 250);
      lastFrame = now;
      if (playing && !advanceInFlight && accumulator >= frameMs) {
        var frames = Math.min(8, Math.floor(accumulator / frameMs));
        accumulator -= frames * frameMs;
        advanceInFlight = true;
        worker.postMessage({ type: 'advance', frames: frames });
      }
      requestAnimationFrame(animate);
    }

    function onWorkerMessage(event) {
      if (failed) return;
      var message = event.data || {};
      try {
        if (message.type === 'text') {
          if (config.onText) config.onText(message.text);
        } else if (message.type === 'status') {
          if (config.onStatus) config.onStatus(message.status);
        } else if (message.type === 'firstFrame') {
          if (config.onFirstFrame) config.onFirstFrame();
        } else if (message.type === 'loaded') {
          loaded = true;
          tickCount = message.tickCount || 1;
          document.documentElement.setAttribute('data-replay-loaded', 'true');
          // DELTA (b): `ready` is posted from INSIDE the loaded branch,
          // immediately after data-replay-loaded is set -- never on rAF at
          // the call site. Posting it early made softmax.com's embed sample
          // an unpainted shell (chorus 3c11c953, 2026-08-24), and
          // viewer_smoke.mjs accepts either signal so CI cannot catch the
          // wrong order.
          tell('ready');
          if (config.onLoaded) config.onLoaded(tickCount);
          requestAnimationFrame(animate);
        } else if (message.type === 'advanced') {
          advanceInFlight = false;
          if (typeof message.tick === 'number') {
            tick = message.tick;
            if (config.onTick) config.onTick(tick, tickCount);
          }
          if (message.ended && config.onEnd) config.onEnd();
        } else if (message.type === 'error') {
          showFailure(new Error(message.message || 'Replay Worker failed'));
          stop();
        }
      } catch (error) {
        showFailure(error);
      }
    }

    function start() {
      if (started || !offscreen || failed) return;
      started = true;
      var replayUrl = new URLSearchParams(location.search).get('replay');
      if (!replayUrl) {
        showFailure(new Error('Missing required replay URL'));
        return;
      }
      readViewport();
      if (config.onStatus) config.onStatus('connecting');
      try {
        worker = new Worker(workerUrl, { name: 'cooperative-hunting-static-replay' });
        worker.onmessage = onWorkerMessage;
        worker.onerror = function (event) {
          showFailure(new Error(event.message || 'Replay Worker crashed'));
          stop();
        };
        worker.onmessageerror = function () {
          showFailure(new Error('Replay Worker sent an unreadable message'));
          stop();
        };
        worker.postMessage({
          type: 'init',
          replayUrl: replayUrl,
          canvas: offscreen,
          width: viewport.width,
          height: viewport.height,
          dpr: viewport.dpr
        }, [offscreen]);
        document.documentElement.setAttribute('data-replay-worker', 'true');
      } catch (error) {
        showFailure(error);
      }
    }

    function stop() {
      if (!worker) return;
      worker.postMessage({ type: 'dispose' });
      worker.terminate();
      worker = null;
    }

    window.addEventListener('pagehide', stop, { once: true });

    return {
      start: start,
      stop: stop,
      seek: function (target) {
        if (!worker) return;
        worker.postMessage({ type: 'seek', tick: Math.max(0, target | 0) });
      },
      sendCommand: function (text) {
        if (worker) worker.postMessage({ type: 'command', text: text });
      },
      setPlaying: function (on) {
        playing = !!on;
        accumulator = 0;
      },
      isPlaying: function () { return playing; },
      setSpeed: function (value) { speed = Number(value) || 1; },
      getSpeed: function () { return speed; },
      getTick: function () { return tick; },
      getTickCount: function () { return tickCount; },
      setViewportFit: postViewport
    };
  }

  window.CooperativeHuntingStaticReplay = {
    createCore: createCore
  };
})();
