import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import {
  DATASET,
  DataLoader,
  coverage,
  fetchManifest,
  fetchStations,
  filesForCutoff,
  filesForQuery,
  type Dataset,
  type DatasetName,
  type Manifest,
} from "../data/loader";
import { createWasmDb, type WasmDb } from "../db/wasm";
import { cutoffDate } from "../lib/cutoff";
import type { StationEntry } from "../lib/stationSearch";
import { Attribution } from "./Attribution";
import { Controls, windowLabel } from "./Controls";
import { findGroups, groupDelays, monthsCovering } from "./journey";
import { JourneyGroups, type GroupView } from "./JourneyGroups";
import { StationPicker, emptyPicker, pickerFromEvas, type PickerValue } from "./StationPicker";
import { parseUrlState, serializeUrlState, type UrlState, type WindowMonths } from "./urlState";

type QueryState = "idle" | "loading" | "done" | "error";

interface Status {
  state: QueryState;
  message: string;
}

const MB = 1024 * 1024;
const mb = (bytes: number) => (bytes / MB).toFixed(1);

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

export function App() {
  const initial = useMemo(() => parseUrlState(window.location.search), []);
  const [manifest, setManifest] = useState<Manifest | null>(null);
  const [datasetName, setDatasetName] = useState<DatasetName>(initial.dataset);
  const [stations, setStations] = useState<StationEntry[] | null>(null);
  const [from, setFrom] = useState<PickerValue>(initial.from.length ? pickerFromEvas(initial.from) : emptyPicker());
  const [to, setTo] = useState<PickerValue>(initial.to.length ? pickerFromEvas(initial.to) : emptyPicker());
  const [months, setMonths] = useState<WindowMonths>(initial.months);
  const [threshold, setThreshold] = useState(initial.threshold);
  const [exclude, setExclude] = useState<string[]>(initial.exclude);
  const [status, setStatus] = useState<Status>({ state: "idle", message: "" });
  const [notice, setNotice] = useState<string | null>(null);
  const [groups, setGroups] = useState<GroupView[]>([]);
  const [shown, setShown] = useState<{ threshold: number; windowText: string }>({
    threshold: initial.threshold,
    windowText: windowLabel(initial.months),
  });

  const runId = useRef(0);
  const chain = useRef<Promise<void>>(Promise.resolve());
  const engine = useRef<Promise<{ db: WasmDb; loader: DataLoader }> | null>(null);
  const stationsCache = useRef(new Map<DatasetName, Promise<StationEntry[]>>());

  const ds = manifest?.datasets[datasetName] ?? null;
  const allTrains = datasetName === "all";

  const stationsByEva = useMemo(() => new Map((stations ?? []).map((s) => [s.eva, s])), [stations]);
  const range = ds ? coverage(ds.files) : null;

  const presentTypes = useMemo(() => {
    const seen = new Set<string>();
    for (const eva of [...from.selected, ...to.selected]) {
      for (const t of Object.keys(stationsByEva.get(eva)?.types ?? {})) if (t !== "") seen.add(t);
    }
    const order = ds?.types ?? [];
    return [...seen].sort((a, b) => (order.indexOf(a) - order.indexOf(b)) || (a < b ? -1 : 1));
  }, [from.selected, to.selected, stationsByEva, ds]);

  const getEngine = () => {
    if (!engine.current) {
      const started = createWasmDb().then((db) => ({ db, loader: new DataLoader(db) }));
      started.catch(() => {
        if (engine.current === started) engine.current = null;
      });
      engine.current = started;
    }
    return engine.current;
  };

  async function execute(id: number, dataset: Dataset, req: UrlState) {
    const stale = () => id !== runId.current;
    const today = new Date();
    const cover = coverage(dataset.files);
    const windowText = req.months === "all" ? "available data" : windowLabel(req.months);
    setShown({ threshold: req.threshold, windowText });
    setGroups([]);
    setNotice(null);

    const cutoff = req.months === "all" ? null : cutoffDate(today, req.months);
    if (filesForCutoff(dataset.files, cutoff).length === 0 || !cover) {
      setNotice(`No data in the last ${windowText}: data ends ${cover?.maxDate ?? "before this window"}.`);
      setStatus({ state: "done", message: "" });
      return;
    }
    const files = filesForQuery(dataset, cutoff, [...req.from, ...req.to]);
    if (files.length === 0) {
      setNotice(`No connecting trains in the last ${windowText}: data ends ${cover.maxDate}.`);
      setStatus({ state: "done", message: "" });
      return;
    }

    setStatus({ state: "loading", message: "Starting DuckDB..." });
    const { db, loader } = await getEngine();
    if (stale()) return;
    await loader.use(files, (p) => {
      if (!stale()) setStatus({ state: "loading", message: `Loading data ${mb(p.loadedBytes)} / ${mb(p.totalBytes)} MB` });
    });
    if (stale()) return;

    setStatus({ state: "loading", message: "Finding trains..." });
    const monthsBack = req.months === "all" ? null : req.months;
    const found = await findGroups(db, { from: req.from, to: req.to, monthsBack, exclude: req.exclude, today });
    if (stale()) return;
    if (found.length === 0) {
      setNotice(`No connecting trains in the last ${windowText}: data ends ${cover.maxDate}.`);
      setStatus({ state: "done", message: "" });
      return;
    }

    let views: GroupView[] = found.map((group) => ({ group, delays: null }));
    setGroups(views);
    const delayMonths = monthsBack ?? monthsCovering(today, cover.minDate);
    for (let i = 0; i < found.length; i++) {
      setStatus({ state: "loading", message: `Computing delays for group ${i + 1} of ${found.length}...` });
      const delays = await groupDelays(db, found[i], { thresholdMinutes: req.threshold, monthsBack: delayMonths, today });
      if (stale()) return;
      views = views.map((v, j) => (j === i ? { ...v, delays } : v));
      setGroups(views);
    }
    setStatus({ state: "done", message: "" });
  }

  function run(req: UrlState) {
    const dataset = manifest?.datasets[req.dataset];
    if (!dataset || req.from.length === 0 || req.to.length === 0) return;
    const id = ++runId.current;
    window.history.replaceState(null, "", serializeUrlState(req));
    setStatus({ state: "loading", message: "Starting..." });
    chain.current = chain.current
      .then(() => (id === runId.current ? execute(id, dataset, req) : undefined))
      .catch((e: unknown) => {
        console.warn(e);
        if (id === runId.current) setStatus({ state: "error", message: errorText(e) });
      });
  }

  const current = (): UrlState => ({ from: from.selected, to: to.selected, months, threshold, exclude, dataset: datasetName });

  useEffect(() => {
    fetchManifest()
      .then((m) => {
        if (!m.datasets[DATASET]) throw new Error(`manifest.json has no ${DATASET} dataset`);
        if (!m.datasets[datasetName]) setDatasetName(DATASET);
        setManifest(m);
      })
      .catch((e: unknown) => setStatus({ state: "error", message: `Could not load the data index: ${errorText(e)}` }));
  }, []);

  useEffect(() => {
    if (!ds) return;
    let live = true;
    setStations(null);
    let pending = stationsCache.current.get(datasetName);
    if (!pending) {
      pending = fetchStations(ds);
      pending.catch(() => stationsCache.current.delete(datasetName));
      stationsCache.current.set(datasetName, pending);
    }
    pending
      .then((list) => live && setStations(list))
      .catch((e: unknown) => live && setStatus({ state: "error", message: `Could not load the stations: ${errorText(e)}` }));
    return () => {
      live = false;
    };
  }, [ds, datasetName]);

  const autoRan = useRef(false);
  useEffect(() => {
    if (!manifest || autoRan.current) return;
    autoRan.current = true;
    const req = manifest.datasets[initial.dataset] ? initial : { ...initial, dataset: DATASET };
    if (req.from.length > 0 && req.to.length > 0) run(req);
  }, [manifest]);

  const busy = status.state === "loading";
  const noMatch = allTrains ? "No station matches." : "No long-distance station matches.";

  return (
    <>
      <header>
        <h1>Deutsche Bahn delay metrics</h1>
        <p class="lead">
          Pick where you start and where you go. The page finds the {allTrains ? "trains" : "long-distance trains"} that connect them and
          shows how often each one arrived late or was canceled. Every query runs in your browser.
        </p>
        {range && (
          <p class="coverage" data-testid="coverage">
            Data covers {range.minDate} to {range.maxDate}.
          </p>
        )}
      </header>
      <main>
        <div class="pickers">
          <StationPicker id="from" label="From" noMatch={noMatch} stations={stations} stationsByEva={stationsByEva} value={from} onChange={setFrom} />
          <StationPicker id="to" label="To" noMatch={noMatch} stations={stations} stationsByEva={stationsByEva} value={to} onChange={setTo} />
        </div>
        <Controls
          months={months}
          threshold={threshold}
          types={presentTypes}
          exclude={exclude}
          allTrains={manifest?.datasets.all ? allTrains : null}
          canRun={!!ds && from.selected.length > 0 && to.selected.length > 0}
          busy={busy}
          onMonths={setMonths}
          onThreshold={setThreshold}
          onExclude={setExclude}
          onAllTrains={(on) => setDatasetName(on ? "all" : DATASET)}
          onRun={() => run(current())}
        />
        <p class={`status status-${status.state}`} data-testid="query-status" data-state={status.state} role="status">
          {status.message}
        </p>
        {notice && (
          <p class="notice" data-testid="notice">
            {notice}
          </p>
        )}
        <JourneyGroups groups={groups} threshold={shown.threshold} windowText={shown.windowText} />
      </main>
      <Attribution allTrains={allTrains} />
    </>
  );
}
