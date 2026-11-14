const pad = (n: number, width = 2) => String(n).padStart(width, "0");

export function isoDate(year: number, month: number, day: number): string {
  return `${pad(year, 4)}-${pad(month)}-${pad(day)}`;
}

// Mirrors Ruby's `Date.today << months_back`: the day clamps to the target month's
// last day (2026-03-31 minus 1 month is 2026-02-28). Uses local date parts because
// the data holds naive Berlin times and DuckDB-WASM runs in UTC.
export function cutoffDate(today: Date, monthsBack: number | null): string | null {
  if (monthsBack === null || monthsBack === undefined) return null;
  const total = today.getFullYear() * 12 + today.getMonth() - monthsBack;
  const year = Math.floor(total / 12);
  const month = total - year * 12;
  const lastDay = new Date(year, month + 1, 0).getDate();
  return isoDate(year, month + 1, Math.min(today.getDate(), lastDay));
}
