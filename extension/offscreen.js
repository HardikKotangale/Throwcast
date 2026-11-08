import { captureTab, restartStream, sendTabState, setStreamVolume, startStream, stopStream, streamStats } from './stream.js';
// The page that captures a cast tab and streams it to the TV. The extension opens it for a cast and
// closes it when the cast ends.

// A DOMException can come with an empty message; say something either way.
const explain = (problem) => problem?.message || problem?.name || String(problem);

chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message?.type === 'streamCapture') {
    captureTab(message.streamId).then(() => respond({}), (problem) => respond({ error: `Chrome couldn’t capture this tab (${explain(problem)}). Press the extension’s button again.` }));
    return true;
  }
  if (message?.type === 'streamStart') {
    startStream(message, (reason) => chrome.runtime.sendMessage({ type: 'streamEnded', reason }).catch(() => {}))
      .then(() => respond({}), (problem) => respond({ error: explain(problem) }));
    return true;
  }
  if (message?.type === 'streamRestart') {
    restartStream(message.changes).then(() => respond({}), (problem) => respond({ error: explain(problem) }));
    return true;
  }
  if (message?.type === 'streamStop') stopStream();
  if (message?.type === 'streamVolume') setStreamVolume(message.volume);
  if (message?.type === 'streamTabState') sendTabState(message.state);
  if (message?.type === 'streamStats') {
    respond(streamStats());
    return false;
  }
  return false;
});
