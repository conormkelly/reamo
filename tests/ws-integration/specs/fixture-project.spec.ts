/**
 * Tests against the known test fixture project (test-fixtures/test-project-1.RPP).
 *
 * These tests assert specific values from the curated test project,
 * providing deterministic regression coverage for the state broadcast pipeline.
 *
 * REAPER must be running with test-project-1.RPP loaded.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { ReamoClient } from '../helpers/client.js';

// --- Expected fixture values ---

const EXPECTED_BPM = 140;
const EXPECTED_TIME_SIG = { numerator: 4, denominator: 4 };

const EXPECTED_TRACKS = [
  { name: 'Synth' },
  { name: 'Drums' },
];

const EXPECTED_MARKERS = [
  { name: 'M1', position: 3.43 },
  { name: 'M2', position: 10.29 },
];

const EXPECTED_REGIONS = [
  { name: 'Intro', start: 0 },
  { name: 'Verse1', start: 6.86 },
];

// --- Interfaces ---

interface TransportPayload {
  playState: number;
  position: number;
  bpm: number;
  timeSignature: { numerator: number; denominator: number };
}

interface MarkerEntry {
  id: number;
  name: string;
  position: number;
}

interface RegionEntry {
  id: number;
  name: string;
  start: number;
  end: number;
}

interface TrackSkeletonEntry {
  n: string;
  g: string;
}

// --- Tests ---

describe('Fixture: test-project-1', () => {
  const client = new ReamoClient();

  // Collect initial snapshot events once
  let transport: TransportPayload;
  let skeleton: { tracks: TrackSkeletonEntry[] };
  let markers: { markers: MarkerEntry[] };
  let regions: { regions: RegionEntry[] };

  beforeAll(async () => {
    // Register collectors before connect to catch initial snapshot
    const transportP = new Promise<TransportPayload>((resolve) => {
      client.onMessage((msg) => {
        if (msg.type === 'event' && (msg as any).event === 'transport') resolve((msg as any).payload);
      });
    });
    const skeletonP = new Promise<TrackSkeletonEntry[]>((resolve) => {
      client.onMessage((msg) => {
        if (msg.type === 'event' && (msg as any).event === 'trackSkeleton') resolve((msg as any).payload);
      });
    });
    const markersP = new Promise<MarkerEntry[]>((resolve) => {
      client.onMessage((msg) => {
        if (msg.type === 'event' && (msg as any).event === 'markers') resolve((msg as any).payload);
      });
    });
    const regionsP = new Promise<RegionEntry[]>((resolve) => {
      client.onMessage((msg) => {
        if (msg.type === 'event' && (msg as any).event === 'regions') resolve((msg as any).payload);
      });
    });

    await client.connect();

    // Wait for all initial snapshot events (5s timeout)
    const timeout = new Promise<never>((_, reject) =>
      setTimeout(() => reject(new Error('Timed out waiting for initial snapshot')), 5000),
    );

    [transport, skeleton, markers, regions] = await Promise.race([
      Promise.all([transportP, skeletonP, markersP, regionsP]),
      timeout.then(() => { throw new Error('timeout'); }),
    ]);
  });

  afterAll(() => {
    client.close();
  });

  describe('Transport state', () => {
    it('has correct BPM', () => {
      expect(transport.bpm).toBe(EXPECTED_BPM);
    });

    it('has correct time signature', () => {
      expect(transport.timeSignature.numerator).toBe(EXPECTED_TIME_SIG.numerator);
      expect(transport.timeSignature.denominator).toBe(EXPECTED_TIME_SIG.denominator);
    });
  });

  describe('Track skeleton', () => {
    it('has expected track count', () => {
      // Skeleton includes MASTER track, so user tracks start at index 1
      const userTracks = skeleton.tracks.filter((t) => t.g !== 'master');
      expect(userTracks.length).toBe(EXPECTED_TRACKS.length);
    });

    it('has expected track names in order', () => {
      const userTracks = skeleton.tracks.filter((t) => t.g !== 'master');
      for (let i = 0; i < EXPECTED_TRACKS.length; i++) {
        expect(userTracks[i].n).toBe(EXPECTED_TRACKS[i].name);
      }
    });
  });

  describe('Markers', () => {
    it('contains expected markers', () => {
      for (const expected of EXPECTED_MARKERS) {
        const found = markers.markers.find((m) => m.name === expected.name);
        expect(found, `Marker "${expected.name}" not found`).toBeDefined();
        expect(found!.position).toBeCloseTo(expected.position, 1);
      }
    });
  });

  describe('Regions', () => {
    it('contains expected regions', () => {
      for (const expected of EXPECTED_REGIONS) {
        const found = regions.regions.find((r) => r.name === expected.name);
        expect(found, `Region "${expected.name}" not found`).toBeDefined();
        expect(found!.start).toBeCloseTo(expected.start, 1);
      }
    });
  });

  describe('Track subscription', () => {
    it('returns correct track data', async () => {
      const resp = await client.sendCommand('track/subscribe', {
        range: { start: 0, end: 9 },
        includeMaster: true,
      });
      expect(resp.success).toBe(true);

      const data = await client.waitForEvent<{ total: number; tracks: any[] }>('tracks', { timeout: 3000 });

      const synth = data.tracks.find((t) => t.name === 'Synth');
      const drums = data.tracks.find((t) => t.name === 'Drums');

      expect(synth, 'Synth track not found in subscription').toBeDefined();
      expect(synth.volume).toBeCloseTo(0.204, 2);

      expect(drums, 'Drums track not found in subscription').toBeDefined();
      expect(drums.volume).toBeCloseTo(1.0, 2);

      await client.sendCommand('track/unsubscribe');
    });
  });
});
