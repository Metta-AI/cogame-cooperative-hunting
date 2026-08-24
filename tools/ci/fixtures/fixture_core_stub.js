// Stands in for replay-viewer/static_replay.js -- and for nothing else.
//
// The worst-case renderer fixture loads the REAL client/replay_broadcast.html,
// the REAL starter chrome_common.js and the REAL game CSS; the one piece it
// replaces is the wasm transport, because the strings this fixture is about
// (a model's `say` line, the fallback line, the six hunter plates, the
// end-card standings) are DOM text drawn by the page itself, from the chrome
// label. Handing the page a label directly is how the fixture hands the real
// renderer a frame built to hurt.
//
// The board canvas is drawn by BroadcastCore inside an OffscreenCanvas in a
// Worker; ci.yml's other viewer_smoke step drives that path for real, against
// the replay docker-smoke produced.
(function () {
  'use strict';

  var playing = true;

  window.CooperativeHuntingStaticReplay = {
    createCore: function (options) {
      // The page hands createCore its callbacks and then drives everything
      // through them; capturing them IS the seam.
      window.__fixtureHooks = options || {};
      return {
        start: function () {},
        seek: function () {},
        setSpeed: function () {},
        setPlaying: function (value) { playing = !!value; },
        isPlaying: function () { return playing; },
        setViewportFit: function () {},
        sendCommand: function () {}
      };
    }
  };
})();
