/**
 * REAPER Response Parser
 * Parses tab-delimited responses from REAPER's HTTP server
 */

import type {
  ParsedResponse,
  TransportState,
  BeatPosition,
  Track,
  Send,
  Marker,
  Region,
  CommandState,
  ExtState,
  PlayState,
} from './types';

/**
 * Unescape special characters in REAPER response strings
 * REAPER encodes: \n -> \\n, \t -> \\t, \ -> \\
 */
export function simpleUnescape(value: string): string {
  return value
    .replace(/\\t/g, '\t')
    .replace(/\\n/g, '\n')
    .replace(/\\\\/g, '\\');
}

/**
 * Parse a single line of REAPER response
 */
function parseLine(line: string): ParsedResponse | null {
  const tokens = line.split('\t');
  if (tokens.length === 0 || !tokens[0]) return null;

  const command = tokens[0];

  switch (command) {
    case 'TRANSPORT': {
      if (tokens.length < 6) return null;
      const data: TransportState = {
        playState: parseInt(tokens[1], 10) as PlayState,
        positionSeconds: parseFloat(tokens[2]),
        isRepeat: tokens[3] !== '0',
        positionString: tokens[4],
        positionBeats: tokens[5],
      };
      return { type: 'TRANSPORT', data };
    }

    case 'BEATPOS': {
      if (tokens.length < 8) return null;
      const data: BeatPosition = {
        playState: parseInt(tokens[1], 10) as PlayState,
        positionSeconds: parseFloat(tokens[2]),
        fullBeatPosition: parseFloat(tokens[3]),
        measureCount: parseInt(tokens[4], 10),
        beatsInMeasure: parseFloat(tokens[5]),
        timeSignatureNumerator: parseInt(tokens[6], 10),
        timeSignatureDenominator: parseInt(tokens[7], 10),
      };
      return { type: 'BEATPOS', data };
    }

    case 'NTRACK': {
      if (tokens.length < 2) return null;
      return { type: 'NTRACK', count: parseInt(tokens[1], 10) };
    }

    case 'TRACK': {
      if (tokens.length < 13) return null;
      const data: Track = {
        index: parseInt(tokens[1], 10),
        name: simpleUnescape(tokens[2]),
        flags: parseInt(tokens[3], 10),
        volume: parseFloat(tokens[4]),
        pan: parseFloat(tokens[5]),
        lastMeterPeak: parseInt(tokens[6], 10),
        lastMeterPos: parseInt(tokens[7], 10),
        width: parseFloat(tokens[8]),
        panMode: parseInt(tokens[9], 10),
        sendCount: parseInt(tokens[10], 10),
        receiveCount: parseInt(tokens[11], 10),
        hwOutCount: parseInt(tokens[12], 10),
        color: tokens[13] ? parseInt(tokens[13], 10) : 0,
      };
      return { type: 'TRACK', data };
    }

    case 'SEND': {
      if (tokens.length < 7) return null;
      const data: Send = {
        trackIndex: parseInt(tokens[1], 10),
        sendIndex: parseInt(tokens[2], 10),
        flags: parseInt(tokens[3], 10),
        volume: parseFloat(tokens[4]),
        pan: parseFloat(tokens[5]),
        otherTrackIndex: parseInt(tokens[6], 10),
      };
      return { type: 'SEND', data };
    }

    case 'MARKER': {
      if (tokens.length < 4) return null;
      const data: Marker = {
        name: simpleUnescape(tokens[1]),
        id: parseInt(tokens[2], 10),
        position: parseFloat(tokens[3]),
        color: tokens[4] ? parseInt(tokens[4], 10) : undefined,
      };
      return { type: 'MARKER', data };
    }

    case 'REGION': {
      if (tokens.length < 5) return null;
      const data: Region = {
        name: simpleUnescape(tokens[1]),
        id: parseInt(tokens[2], 10),
        start: parseFloat(tokens[3]),
        end: parseFloat(tokens[4]),
        color: tokens[5] ? parseInt(tokens[5], 10) : undefined,
      };
      return { type: 'REGION', data };
    }

    case 'MARKER_LIST':
      return { type: 'MARKER_LIST' };

    case 'MARKER_LIST_END':
      return { type: 'MARKER_LIST_END' };

    case 'REGION_LIST':
      return { type: 'REGION_LIST' };

    case 'REGION_LIST_END':
      return { type: 'REGION_LIST_END' };

    case 'CMDSTATE': {
      if (tokens.length < 3) return null;
      const data: CommandState = {
        commandId: tokens[1].startsWith('_') ? tokens[1] : parseInt(tokens[1], 10),
        state: parseInt(tokens[2], 10),
      };
      return { type: 'CMDSTATE', data };
    }

    case 'EXTSTATE': {
      if (tokens.length < 4) return null;
      const data: ExtState = {
        section: simpleUnescape(tokens[1]),
        key: simpleUnescape(tokens[2]),
        value: simpleUnescape(tokens[3]),
      };
      return { type: 'EXTSTATE', data };
    }

    case 'PROJEXTSTATE': {
      if (tokens.length < 4) return null;
      const data: ExtState = {
        section: simpleUnescape(tokens[1]),
        key: simpleUnescape(tokens[2]),
        value: simpleUnescape(tokens[3]),
      };
      return { type: 'PROJEXTSTATE', data };
    }

    case 'GET/REPEAT': {
      if (tokens.length < 2) return null;
      return { type: 'GET/REPEAT', value: tokens[1] !== '0' };
    }

    default:
      // Handle GET/TRACK/x/... responses
      if (command.startsWith('GET/TRACK/')) {
        // These return the property value in the second token
        // For now, return as unknown - can be extended as needed
        return { type: 'UNKNOWN', raw: line };
      }
      return { type: 'UNKNOWN', raw: line };
  }
}

/**
 * Parse a full REAPER response (multiple lines)
 */
export function parseResponse(response: string): ParsedResponse[] {
  const lines = response.split('\n');
  const results: ParsedResponse[] = [];

  for (const line of lines) {
    if (!line.trim()) continue;
    const parsed = parseLine(line);
    if (parsed) {
      results.push(parsed);
    }
  }

  return results;
}

/**
 * Extract transport state from parsed responses
 */
export function extractTransport(responses: ParsedResponse[]): TransportState | null {
  for (const r of responses) {
    if (r.type === 'TRANSPORT') return r.data;
  }
  return null;
}

/**
 * Extract track count from parsed responses
 */
export function extractTrackCount(responses: ParsedResponse[]): number | null {
  for (const r of responses) {
    if (r.type === 'NTRACK') return r.count;
  }
  return null;
}

/**
 * Extract all tracks from parsed responses
 */
export function extractTracks(responses: ParsedResponse[]): Track[] {
  return responses
    .filter((r): r is { type: 'TRACK'; data: Track } => r.type === 'TRACK')
    .map((r) => r.data);
}

/**
 * Extract markers from parsed responses
 */
export function extractMarkers(responses: ParsedResponse[]): Marker[] {
  return responses
    .filter((r): r is { type: 'MARKER'; data: Marker } => r.type === 'MARKER')
    .map((r) => r.data);
}

/**
 * Extract regions from parsed responses
 */
export function extractRegions(responses: ParsedResponse[]): Region[] {
  return responses
    .filter((r): r is { type: 'REGION'; data: Region } => r.type === 'REGION')
    .map((r) => r.data);
}
