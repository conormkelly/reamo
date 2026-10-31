/**
 * Mix Monitoring must play the samples REAPER sent, on both playback paths:
 * the AudioWorklet (secure contexts: HTTPS, localhost) and the
 * AudioBufferSourceNode scheduler (plain HTTP over the LAN).
 *
 * Frames are built in the server's wire format (extension/src/audio/stream.zig):
 *   [u8 type 0x01][u32 LE sequence][i16 LE interleaved stereo PCM]
 *
 * The worklet path runs the real processor from public/, loaded from the URL
 * the manager passes to addModule, behind a fake AudioWorkletNode.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { AudioStreamManager } from './AudioStreamManager';

const SAMPLE_RATE = 48000;
/** 10 ms at 48 kHz, as the server sends */
const PAIRS_PER_FRAME = 480;
const FRAME_COUNT = 10;

// =============================================================================
// Test signal
// =============================================================================

/** Distinct, non-repeating stereo samples so any misalignment changes values. */
function samplePair(n: number): [number, number] {
  const left = ((n * 37) % 20001) - 10000;
  const right = 15000 - ((n * 53) % 30001);
  return [left, right];
}

function serverFrame(sequence: number): ArrayBuffer {
  const buffer = new ArrayBuffer(5 + PAIRS_PER_FRAME * 4);
  const view = new DataView(buffer);
  view.setUint8(0, 0x01);
  view.setUint32(1, sequence, true);
  for (let i = 0; i < PAIRS_PER_FRAME; i++) {
    const [left, right] = samplePair(sequence * PAIRS_PER_FRAME + i);
    view.setInt16(5 + i * 4, left, true);
    view.setInt16(5 + i * 4 + 2, right, true);
  }
  return buffer;
}

function expectedChannels(pairCount: number): { left: number[]; right: number[] } {
  const left = new Float32Array(pairCount);
  const right = new Float32Array(pairCount);
  for (let n = 0; n < pairCount; n++) {
    const [l, r] = samplePair(n);
    left[n] = l / 32768;
    right[n] = r / 32768;
  }
  return { left: Array.from(left), right: Array.from(right) };
}

// =============================================================================
// Web Audio fakes
// =============================================================================

class FakeMessagePort {
  onmessage: ((event: { data: unknown }) => void) | null = null;
  peer: FakeMessagePort | null = null;
  postMessage(data: unknown): void {
    this.peer?.onmessage?.({ data });
  }
}

function portPair(): [FakeMessagePort, FakeMessagePort] {
  const a = new FakeMessagePort();
  const b = new FakeMessagePort();
  a.peer = b;
  b.peer = a;
  return [a, b];
}

interface Processor {
  process(inputs: Float32Array[][], outputs: Float32Array[][]): boolean;
}
type ProcessorClass = new (options?: unknown) => Processor;

/** Processors registered by worklet modules; survives the module cache across tests. */
const registeredProcessors = new Map<string, ProcessorClass>();
let portForNextProcessor: FakeMessagePort | null = null;

class FakeAudioWorkletProcessor {
  readonly port: FakeMessagePort;
  constructor() {
    this.port = portForNextProcessor!;
  }
}

class FakeAudioWorkletNode {
  readonly port: FakeMessagePort;
  readonly processor: Processor;
  constructor(_context: unknown, name: string, options?: unknown) {
    const [nodePort, processorPort] = portPair();
    this.port = nodePort;
    portForNextProcessor = processorPort;
    const Processor = registeredProcessors.get(name);
    if (!Processor) throw new Error(`no processor registered as "${name}"`);
    this.processor = new Processor(options);
    workletNodes.push(this);
  }
  connect(): void {}
  disconnect(): void {}
}

class FakeAudioBuffer {
  readonly length: number;
  readonly sampleRate: number;
  readonly duration: number;
  private readonly channels: Float32Array[];
  constructor(numberOfChannels: number, length: number, sampleRate: number) {
    this.length = length;
    this.sampleRate = sampleRate;
    this.duration = length / sampleRate;
    this.channels = Array.from({ length: numberOfChannels }, () => new Float32Array(length));
  }
  get numberOfChannels(): number {
    return this.channels.length;
  }
  getChannelData(channel: number): Float32Array {
    return this.channels[channel];
  }
  copyToChannel(source: Float32Array, channel: number, offset = 0): void {
    this.channels[channel].set(source, offset);
  }
}

/** Scripts served from the web root, keyed by their path relative to this file */
const publicScripts = import.meta.glob('../../public/*.js');

async function loadPublicScript(url: string): Promise<void> {
  const load = publicScripts[`../../public${url}`];
  if (!load) throw new Error(`no public script at ${url}`);
  await load();
}

let workletNodes: FakeAudioWorkletNode[] = [];
let scheduledBuffers: FakeAudioBuffer[] = [];

/** `moduleLoaded`, if given, holds addModule open until it resolves. */
function fakeAudioContextClass(withWorklet: boolean, moduleLoaded?: Promise<void>) {
  return class FakeAudioContext {
    readonly sampleRate: number;
    readonly state = 'running';
    readonly currentTime = 0;
    readonly destination = {};
    readonly audioWorklet?: { addModule(url: string): Promise<void> };

    constructor(options?: { sampleRate?: number }) {
      this.sampleRate = options?.sampleRate ?? SAMPLE_RATE;
      if (withWorklet) {
        this.audioWorklet = {
          addModule: async (url: string) => {
            await moduleLoaded;
            await loadPublicScript(url);
          },
        };
      }
    }
    resume(): Promise<void> {
      return Promise.resolve();
    }
    close(): Promise<void> {
      return Promise.resolve();
    }
    createBuffer(numberOfChannels: number, length: number, sampleRate: number): FakeAudioBuffer {
      return new FakeAudioBuffer(numberOfChannels, length, sampleRate);
    }
    createBufferSource() {
      const source = {
        buffer: null as FakeAudioBuffer | null,
        connect(): void {},
        start(): void {
          scheduledBuffers.push(source.buffer!);
        },
      };
      return source;
    }
  };
}

beforeEach(() => {
  workletNodes = [];
  scheduledBuffers = [];
  vi.stubGlobal('AudioWorkletProcessor', FakeAudioWorkletProcessor);
  vi.stubGlobal('AudioWorkletNode', FakeAudioWorkletNode);
  vi.stubGlobal('registerProcessor', (name: string, processor: ProcessorClass) => {
    registeredProcessors.set(name, processor);
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

// =============================================================================
// Tests
// =============================================================================

describe('AudioStreamManager plays server audio frames sample-exact', () => {
  it('AudioWorklet path (secure contexts) outputs the PCM samples the server sent', async () => {
    vi.stubGlobal('AudioContext', fakeAudioContextClass(true));
    const manager = new AudioStreamManager();
    await manager.start(SAMPLE_RATE);
    try {
      expect(workletNodes).toHaveLength(1);
      const { processor } = workletNodes[0];

      // 100 ms: enough to fill the worklet's jitter buffer and start playing
      for (let seq = 0; seq < FRAME_COUNT; seq++) {
        manager.handleAudioFrame(serverFrame(seq));
      }

      const quanta = 3;
      const left: number[] = [];
      const right: number[] = [];
      for (let q = 0; q < quanta; q++) {
        const output = [new Float32Array(128), new Float32Array(128)];
        processor.process([], [output]);
        left.push(...output[0]);
        right.push(...output[1]);
      }

      const expected = expectedChannels(quanta * 128);
      expect(left).toEqual(expected.left);
      expect(right).toEqual(expected.right);
    } finally {
      manager.stop();
    }
  });

  it('buffer-scheduling path (plain HTTP) schedules the PCM samples the server sent', async () => {
    vi.stubGlobal('AudioContext', fakeAudioContextClass(false));
    const manager = new AudioStreamManager();
    await manager.start(SAMPLE_RATE);
    try {
      expect(workletNodes).toHaveLength(0);

      for (let seq = 0; seq < FRAME_COUNT; seq++) {
        manager.handleAudioFrame(serverFrame(seq));
      }

      const left = scheduledBuffers.flatMap((buffer) => Array.from(buffer.getChannelData(0)));
      const right = scheduledBuffers.flatMap((buffer) => Array.from(buffer.getChannelData(1)));

      const expected = expectedChannels(FRAME_COUNT * PAIRS_PER_FRAME);
      expect(left).toEqual(expected.left);
      expect(right).toEqual(expected.right);
    } finally {
      manager.stop();
    }
  });

  it('drops frames that arrive while the AudioWorklet is still loading, instead of playing them through the fallback', async () => {
    let finishLoading!: () => void;
    const moduleLoaded = new Promise<void>((resolve) => {
      finishLoading = resolve;
    });
    vi.stubGlobal('AudioContext', fakeAudioContextClass(true, moduleLoaded));
    const manager = new AudioStreamManager();
    // The app creates the context in the tap handler, then wires frames in before start()
    manager.unlockAudio();
    const starting = manager.start(SAMPLE_RATE);
    try {
      for (let seq = 0; seq < FRAME_COUNT; seq++) {
        manager.handleAudioFrame(serverFrame(seq));
      }
      expect(scheduledBuffers).toHaveLength(0);

      finishLoading();
      await starting;
      expect(workletNodes).toHaveLength(1);
      expect(scheduledBuffers).toHaveLength(0);
    } finally {
      manager.stop();
    }
  });
});
