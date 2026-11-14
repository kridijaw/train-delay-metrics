import { fold } from "./fold";

export interface StationEntry {
  eva: string;
  name: string;
  types: Record<string, number>;
}

const escapeRegExp = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export function stationMatcher(query: string): ((name: string) => boolean) | null {
  const folded = fold(query.trim());
  if (folded === "") return null;
  const pattern = new RegExp(folded.split("%").map(escapeRegExp).join("[\\s\\S]*"));
  return (name) => pattern.test(fold(name));
}

export function searchStations(stations: readonly StationEntry[], query: string): StationEntry[] {
  const matches = stationMatcher(query);
  return matches ? stations.filter((s) => matches(s.name)) : [];
}
