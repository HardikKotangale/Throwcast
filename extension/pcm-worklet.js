// Gathers the tab's sound into 20 ms blocks of 16-bit stereo, the format the TV plays.
class Pcm extends AudioWorkletProcessor {
  constructor() {
    super();
    this.block = new Int16Array(960 * 2);
    this.filled = 0;
  }

  process([input]) {
    // A paused or quiet tab can give no input at all. It still sends silence, so the Mac doesn't take
    // the gap for a broken link and switch to the browser's sound, which would cut the audio.
    const left = input[0] ?? new Float32Array(128);
    const right = input[1] ?? left;
    for (let i = 0; i < left.length; i++) {
      this.block[this.filled * 2] = Math.max(-1, Math.min(1, left[i])) * 32767;
      this.block[this.filled * 2 + 1] = Math.max(-1, Math.min(1, right[i])) * 32767;
      if (++this.filled === 960) {
        this.port.postMessage(this.block.buffer, [this.block.buffer]);
        this.block = new Int16Array(960 * 2);
        this.filled = 0;
      }
    }
    return true;
  }
}

registerProcessor('pcm', Pcm);
