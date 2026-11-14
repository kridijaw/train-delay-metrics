import { WINDOW_OPTIONS, parseMonths, type WindowMonths } from "./urlState";

export const windowLabel = (m: WindowMonths) => (m === "all" ? "All data" : `${m} months`);

interface Props {
  months: WindowMonths;
  threshold: number;
  types: string[];
  exclude: string[];
  allTrains: boolean | null;
  canRun: boolean;
  busy: boolean;
  onMonths(months: WindowMonths): void;
  onThreshold(threshold: number): void;
  onExclude(exclude: string[]): void;
  onAllTrains(allTrains: boolean): void;
  onRun(): void;
}

// allTrains is null when the deployed data has no all-trains dataset.
export function Controls(props: Props) {
  const { months, threshold, types, exclude, allTrains, canRun, busy, onMonths, onThreshold, onExclude, onAllTrains, onRun } = props;
  const toggleType = (type: string, checked: boolean) =>
    onExclude(checked ? exclude.filter((t) => t !== type) : [...exclude, type]);

  return (
    <form
      class="controls"
      onSubmit={(e) => {
        e.preventDefault();
        onRun();
      }}
    >
      <label>
        Window
        <select value={String(months)} onChange={(e) => onMonths(parseMonths(e.currentTarget.value))}>
          {WINDOW_OPTIONS.map((m) => (
            <option key={m} value={String(m)}>
              {windowLabel(m)}
            </option>
          ))}
        </select>
      </label>
      <label>
        Delay threshold (min)
        <input
          type="number"
          min={0}
          step={1}
          value={threshold}
          onChange={(e) => {
            const n = Number(e.currentTarget.value);
            if (Number.isInteger(n) && n >= 0) onThreshold(n);
          }}
        />
      </label>
      {allTrains !== null && (
        <label class="toggle">
          <input
            type="checkbox"
            data-testid="all-trains"
            checked={allTrains}
            onChange={(e) => onAllTrains(e.currentTarget.checked)}
          />
          Include regional and S-Bahn trains
        </label>
      )}
      {types.length > 0 && (
        <fieldset class="types">
          <legend>Train types</legend>
          {types.map((t) => (
            <label key={t}>
              <input type="checkbox" checked={!exclude.includes(t)} onChange={(e) => toggleType(t, e.currentTarget.checked)} />
              {t}
            </label>
          ))}
        </fieldset>
      )}
      <button type="submit" disabled={!canRun}>
        {busy ? "Running..." : "Find trains"}
      </button>
    </form>
  );
}
