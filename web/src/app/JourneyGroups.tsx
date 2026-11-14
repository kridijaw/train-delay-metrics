import { groupTitle } from "../lib/format";
import type { JourneyGroup } from "../lib/groupByStops";
import type { GroupDelays } from "./journey";
import { ResultsTable } from "./ResultsTable";

export interface GroupView {
  group: JourneyGroup;
  delays: GroupDelays | null;
}

interface Props {
  groups: GroupView[];
  threshold: number;
  windowText: string;
}

export function JourneyGroups({ groups, threshold, windowText }: Props) {
  return (
    <div class="groups">
      {groups.map(({ group, delays }, i) => {
        const key = group.evas.join(",");
        return (
          <section class="group" key={key} data-testid="journey-group" data-group={key}>
            <h2>
              Group {i + 1}: {groupTitle(group)}
            </h2>
            <p class="trains">
              {group.trains.length} train{group.trains.length === 1 ? "" : "s"}: {group.trains.join(", ")}
            </p>
            {delays === null ? (
              <p class="hint">Computing delays...</p>
            ) : delays.rows.length === 0 ? (
              <p class="hint">No trips found in the last {windowText}.</p>
            ) : (
              <ResultsTable groupKey={key} delays={delays} threshold={threshold} />
            )}
          </section>
        );
      })}
    </div>
  );
}
