// Port of TrainName.sort_key. Equal-length digit runs compare as strings, which
// matches numeric order without losing precision on long runs.
export type SortKeyPart = [0, string] | [1, number, string];

export function sortKey(name: string): SortKeyPart[] {
  return (String(name).match(/\d+|\D+/g) ?? []).map((part): SortKeyPart =>
    /^\d+$/.test(part) ? [1, part.length, part] : [0, part.toLowerCase()],
  );
}

const cmp = (a: string | number, b: string | number) => (a < b ? -1 : a > b ? 1 : 0);

function comparePart(a: SortKeyPart, b: SortKeyPart): number {
  if (a[0] !== b[0]) return a[0] - b[0];
  if (a[0] === 0) return cmp(a[1], b[1]);
  const bn = b as [1, number, string];
  return cmp(a[1], bn[1]) || cmp(a[2], bn[2]);
}

export function compareSortKeys(a: SortKeyPart[], b: SortKeyPart[]): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const c = comparePart(a[i], b[i]);
    if (c !== 0) return c;
  }
  return a.length - b.length;
}

export function compareTrainNames(a: string, b: string): number {
  return compareSortKeys(sortKey(a), sortKey(b));
}

export function sortTrainNames(names: readonly string[]): string[] {
  return [...names].sort(compareTrainNames);
}
