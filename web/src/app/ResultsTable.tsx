import { formatPercent } from "../lib/format";
import type { GroupDelays } from "./journey";

interface Props {
  groupKey: string;
  delays: GroupDelays;
  threshold: number;
}

export function ResultsTable({ groupKey, delays, threshold }: Props) {
  return (
    <table class="results">
      <thead>
        <tr>
          <th class="train">Train</th>
          <th>Trips</th>
          <th>Cancel</th>
          <th>Delay{threshold}+</th>
          <th>Prob%</th>
          <th>Prob%+C</th>
          <th title="Weekday and time (30 minutes either side) with the highest delay-or-cancel share">
            {delays.timeSource === "arr" ? "Arr" : "Dep"} Peak D+C
          </th>
        </tr>
      </thead>
      <tbody>
        {delays.rows.map((r) => (
          <tr
            key={r.trainName}
            data-testid="result-row"
            data-group={groupKey}
            data-train={r.trainName}
            data-trips={r.totalTrips}
            data-cancel={r.canceledTrips}
            data-delayed={r.delayedTrips}
            data-peak={r.peakCell}
          >
            <td class="train">{r.trainName}</td>
            <td>{r.totalTrips}</td>
            <td>{r.canceledTrips}</td>
            <td>{r.delayedTrips}</td>
            <td>{formatPercent(r.delayPercentage)}</td>
            <td>{formatPercent(r.delayOrCancelPercentage)}</td>
            <td class="peak" title={r.peakCell === "-" || !r.peak ? undefined : `${r.peak.disrupted} of ${r.peak.scheduled}`}>
              {r.peakCell}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
