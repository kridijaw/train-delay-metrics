import type { JourneyGroup } from "./groupByStops";
import { centerLabel, type PeakWindow } from "../queries/peakWindows";

// Same digits as C/Ruby `format("%.Nf")`: rounds the exact binary value, ties to even.
// Number#toFixed breaks exact ties upward, so 40.625 would print 40.63 instead of 40.62.
export function formatFixed(value: number, digits: number): string {
  if (!Number.isFinite(value) || Math.abs(value) >= 1e21) return String(value);
  const negative = value < 0 || Object.is(value, -0);
  const exact = Math.abs(value).toFixed(100);
  const point = exact.indexOf(".");
  const intPart = exact.slice(0, point);
  const frac = exact.slice(point + 1);
  const kept = intPart + frac.slice(0, digits);
  const rest = frac.slice(digits);

  const first = rest.charCodeAt(0) - 48;
  const beyondHalf = /[1-9]/.test(rest.slice(1));
  const lastKept = kept.charCodeAt(kept.length - 1) - 48;
  const roundUp = first > 5 || (first === 5 && (beyondHalf || lastKept % 2 === 1));

  let digitsOut = kept;
  if (roundUp) {
    const chars = digitsOut.split("");
    let i = chars.length - 1;
    while (i >= 0 && chars[i] === "9") chars[i--] = "0";
    if (i < 0) chars.unshift("1");
    else chars[i] = String(Number(chars[i]) + 1);
    digitsOut = chars.join("");
  }

  const whole = digitsOut.slice(0, digitsOut.length - digits).replace(/^0+(?=\d)/, "") || "0";
  const fraction = digits > 0 ? `.${digitsOut.slice(digitsOut.length - digits)}` : "";
  const text = whole + fraction;
  return negative && /[1-9]/.test(text) ? `-${text}` : text;
}

export const formatPercent = (value: number | null) => (value === null ? "-" : formatFixed(value, 2));

// CLI.format_peak_cell: "Sun 20:51  32%", or "-" without scheduled trips.
export function peakCell(peak: PeakWindow | undefined): string {
  if (!peak || peak.scheduled <= 0 || peak.percentage === null) return "-";
  return `${centerLabel(peak)} ${String(Math.round(peak.percentage)).padStart(3)}%`;
}

// CLI.format_group_title: "<from stations> -> <to stations not also in from>".
export function groupTitle(group: JourneyGroup): string {
  const label = (eva: string) => (group.stations[eva] ? `${group.stations[eva]} (${eva})` : eva);
  if (group.from.length === 0 && group.to.length === 0) return `EVAs ${group.evas.map(label).join(", ")}`;
  const fromPart = group.from.map(label).join(", ");
  const toPart = group.to
    .filter((e) => !group.from.includes(e))
    .map(label)
    .join(", ");
  if (fromPart === "") return toPart;
  if (toPart === "") return fromPart;
  return `${fromPart} -> ${toPart}`;
}
