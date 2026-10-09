import { Buffer } from "node:buffer";
import { readFileSync } from "node:fs";

export type TapeFrame = {
  index: number;
  deltaMs: number;
  kind: number;
  payload: Buffer;
};

export function readTapeFrames(path: string): TapeFrame[] {
  const bytes = readFileSync(path);
  const magic = Buffer.from("FXTP\x01", "binary");
  if (!bytes.subarray(0, magic.length).equals(magic)) {
    throw new Error("invalid tape magic");
  }

  let offset = magic.length + 2 + 2 + 8;
  if (offset >= bytes.length) throw new Error("truncated tape header");
  const versionLen = bytes.readUInt8(offset);
  offset += 1 + versionLen;
  if (offset > bytes.length) throw new Error("truncated tape version");

  const frames: TapeFrame[] = [];
  let index = 0;
  while (offset < bytes.length) {
    if (offset + 9 > bytes.length) throw new Error(`truncated tape frame header at ${offset}`);
    const deltaMs = bytes.readInt32LE(offset);
    const kind = bytes.readUInt8(offset + 4);
    const len = bytes.readUInt32LE(offset + 5);
    const start = offset + 9;
    const end = start + len;
    if (end > bytes.length) throw new Error(`truncated tape frame payload at ${offset}`);
    frames.push({ index: ++index, deltaMs, kind, payload: bytes.subarray(start, end) });
    offset = end;
  }
  return frames;
}

export function stdoutFrames(path: string): TapeFrame[] {
  return readTapeFrames(path).filter((frame) => frame.kind === 1);
}

/**
 * Read a tape that its writer may still be appending to, retrying past a torn
 * tail until it parses.
 *
 * Use this only to capture position markers. A recording is complete once fx
 * exits, so assertions belong on a settled tape read with `readTapeFrames`:
 * polling a live one races the writer and reports a missing frame as a failure
 * when it has merely not landed yet.
 */
export async function readLiveTapeFrames(
  path: string,
  timeoutMs = 5_000,
): Promise<TapeFrame[]> {
  const startedAt = Date.now();
  for (;;) {
    try {
      return readTapeFrames(path);
    } catch (error) {
      if (Date.now() - startedAt >= timeoutMs) throw error;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }
}

export async function liveStdoutFrames(
  path: string,
  timeoutMs = 5_000,
): Promise<TapeFrame[]> {
  return (await readLiveTapeFrames(path, timeoutMs)).filter(
    (frame) => frame.kind === 1,
  );
}
