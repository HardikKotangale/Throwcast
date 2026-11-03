// Holds the cast tab's sound. Capturing a tab silences it on the Mac, so it plays on the TV alone while
// everything else on the Mac keeps its sound.
let running;

// The Mac sleeping with the lid closed breaks the link and can pause audio, so both recover on their own.
function connect() {
  const socket = new WebSocket('ws://127.0.0.1:47124');
  socket.binaryType = 'arraybuffer';
  socket.onclose = () => {
    if (running?.socket === socket) setTimeout(() => running?.socket === socket && (running.socket = connect()), 1000);
  };
  return socket;
}

async function start(streamId) {
  stop();
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
    video: false,
  });
  const context = new AudioContext({ sampleRate: 48000 });
  await context.audioWorklet.addModule('pcm-worklet.js');
  const pcm = new AudioWorkletNode(context, 'pcm', { channelCount: 2, channelCountMode: 'explicit' });
  // Silent, but connected, so the browser keeps the graph running.
  const mute = new GainNode(context, { gain: 0 });
  context.createMediaStreamSource(stream).connect(pcm).connect(mute).connect(context.destination);
  context.onstatechange = () => {
    if (running?.context === context && context.state !== 'running' && context.state !== 'closed') context.resume().catch(() => {});
  };
  running = { stream, context };
  running.socket = connect();
  pcm.port.onmessage = (event) => {
    if (running?.socket.readyState === WebSocket.OPEN) running.socket.send(event.data);
  };
  // After a wake, a state change isn't always reported, so check now and then too.
  running.watch = setInterval(() => context.state === 'suspended' && context.resume().catch(() => {}), 2000);
  await new Promise((resolve, reject) => {
    running.socket.onopen = resolve;
    running.socket.onerror = reject;
  });
}

function stop() {
  if (!running) return;
  const { stream, context, socket, watch } = running;
  running = undefined;
  clearInterval(watch);
  stream.getTracks().forEach((track) => track.stop());
  context.close();
  socket.close();
}

chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message?.type === 'tabAudio') {
    start(message.streamId).then(() => respond(true), () => {
      stop();
      respond(false);
    });
    return true;
  }
  if (message?.type === 'tabAudioStop') stop();
  return false;
});
