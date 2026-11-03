// Holds the cast tab's sound. Capturing a tab silences it on the Mac, so it plays on the TV alone while
// everything else on the Mac keeps its sound.
let running;

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
  const socket = new WebSocket('ws://127.0.0.1:47124');
  socket.binaryType = 'arraybuffer';
  pcm.port.onmessage = (event) => {
    if (socket.readyState === WebSocket.OPEN) socket.send(event.data);
  };
  running = { stream, context, socket };
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
}

function stop() {
  if (!running) return;
  running.stream.getTracks().forEach((track) => track.stop());
  running.context.close();
  running.socket.close();
  running = undefined;
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
