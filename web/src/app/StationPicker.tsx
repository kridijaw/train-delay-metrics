import type { StationEntry } from "../lib/stationSearch";
import { searchStations } from "../lib/stationSearch";

export const MAX_MATCHES = 40;

export interface PickerValue {
  query: string;
  candidates: string[];
  selected: string[];
  more: number;
}

export const emptyPicker = (): PickerValue => ({ query: "", candidates: [], selected: [], more: 0 });

export const pickerFromEvas = (evas: string[]): PickerValue => ({ query: "", candidates: evas, selected: evas, more: 0 });

// Every match starts checked, like passing all of find-stations' EVAs to find-trains.
export function pickerFromQuery(stations: readonly StationEntry[], query: string): PickerValue {
  const matches = searchStations(stations, query);
  const evas = matches.slice(0, MAX_MATCHES).map((s) => s.eva);
  return { query, candidates: evas, selected: evas, more: Math.max(matches.length - MAX_MATCHES, 0) };
}

const rides = (s: StationEntry) => Object.values(s.types).reduce((n, v) => n + v, 0);

const typesByRides = (s: StationEntry) =>
  Object.entries(s.types)
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .map(([t]) => t)
    .join(", ");

interface Props {
  id: string;
  label: string;
  stationsByEva: ReadonlyMap<string, StationEntry>;
  stations: readonly StationEntry[] | null;
  value: PickerValue;
  noMatch: string;
  onChange(value: PickerValue): void;
}

export function StationPicker({ id, label, stations, stationsByEva, value, noMatch, onChange }: Props) {
  const toggle = (eva: string, checked: boolean) => {
    const selected = checked ? [...value.selected, eva] : value.selected.filter((e) => e !== eva);
    onChange({ ...value, selected: value.candidates.filter((e) => selected.includes(e)) });
  };

  return (
    <fieldset class="picker" data-testid={`picker-${id}`}>
      <legend>{label}</legend>
      <input
        type="search"
        placeholder={stations ? "Station name, e.g. Berlin Hbf or K%ln" : "Loading stations..."}
        disabled={!stations}
        value={value.query}
        aria-label={`${label} station search`}
        onInput={(e) => stations && onChange(pickerFromQuery(stations, e.currentTarget.value))}
      />
      {value.query.trim() !== "" && value.candidates.length === 0 && <p class="hint">{noMatch}</p>}
      {value.candidates.length > 0 && (
        <ul class="matches">
          {value.candidates.map((eva) => {
            const s = stationsByEva.get(eva);
            return (
              <li key={eva}>
                <label>
                  <input
                    type="checkbox"
                    value={eva}
                    checked={value.selected.includes(eva)}
                    onChange={(e) => toggle(eva, e.currentTarget.checked)}
                  />
                  <span class="name">{s ? s.name : "Unknown station"}</span>
                  <code class="eva">{eva}</code>
                  {s && <span class="types">{typesByRides(s)}</span>}
                  {s && <span class="rides">{rides(s)} rides</span>}
                </label>
              </li>
            );
          })}
        </ul>
      )}
      {value.more > 0 && <p class="hint">{value.more} more matches, refine the search.</p>}
    </fieldset>
  );
}
