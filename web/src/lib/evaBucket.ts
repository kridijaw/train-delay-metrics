const INT32_MAX = 2147483647;

// Mirrors COALESCE(TRY_CAST(eva AS INTEGER), 0) % 256 in web/scripts/sql/facts_all.sql for
// digit-only EVAs. parseInt would accept "12ab", where TRY_CAST gives NULL.
export function evaBucket(eva: string, bucketCount = 256): number {
  if (!/^\d+$/.test(eva)) return 0;
  const n = Number(eva);
  return n > INT32_MAX ? 0 : n % bucketCount;
}
