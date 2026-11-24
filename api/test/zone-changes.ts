// What the runtime's own zone data says, read with `Intl` alone (task 174), so
// that tests of the calendar's time zone code do not check it against itself.
// Used by calendar-day.test.ts and calendar-time.test.ts.

const DAY = 86400;

const offsetFormats = new Map<string, Intl.DateTimeFormat>();

/** A zone's offset from UTC at an instant (Unix seconds), in seconds, to the minute. */
export function offsetIn(seconds: number, timeZone: string): number {
  let format = offsetFormats.get(timeZone);
  if (!format) offsetFormats.set(timeZone, (format = new Intl.DateTimeFormat("en-US", { timeZone, timeZoneName: "longOffset" })));
  // "GMT" for UTC itself, else "GMT+05:30" or "GMT-03".
  const name = format.formatToParts(new Date(seconds * 1000)).find((part) => part.type === "timeZoneName")?.value ?? "";
  const match = /^GMT(?:([+-])(\d\d)(?::(\d\d))?)?$/.exec(name);
  if (!match) throw new Error(`unexpected offset name ${name} for ${timeZone}`);
  if (!match[1]) return 0;
  const minutes = Number(match[2]) * 60 + Number(match[3] ?? 0);
  return (match[1] === "-" ? -minutes : minutes) * 60;
}

/** The wall clock (seconds, read as if UTC) a zone shows at an instant. */
export const wallIn = (seconds: number, timeZone: string) => seconds + offsetIn(seconds, timeZone);

/** One change of a zone's offset: the first instant of the new offset, and the offsets either side. */
export type OffsetChange = { at: number; before: number; after: number };

const changesFound = new Map<string, OffsetChange[]>();

/**
 * Every change of a zone's offset in a year, found by reading the offset once
 * a day and narrowing each change down to the second. (No zone changes twice
 * within a day.)
 */
export function offsetChanges(timeZone: string, year: number): OffsetChange[] {
  const cacheKey = `${timeZone} ${year}`;
  const cached = changesFound.get(cacheKey);
  if (cached) return cached;
  const changes: OffsetChange[] = [];
  const end = Date.UTC(year + 1, 0, 1) / 1000;
  let at = Date.UTC(year, 0, 1) / 1000;
  let offset = offsetIn(at, timeZone);
  while (at < end) {
    const next = Math.min(at + DAY, end);
    const nextOffset = offsetIn(next, timeZone);
    if (nextOffset !== offset) {
      let low = at;
      let high = next;
      while (high - low > 1) {
        const middle = Math.floor((low + high) / 2);
        if (offsetIn(middle, timeZone) === offset) low = middle;
        else high = middle;
      }
      changes.push({ at: high, before: offset, after: nextOffset });
    }
    at = next;
    offset = nextOffset;
  }
  changesFound.set(cacheKey, changes);
  return changes;
}
