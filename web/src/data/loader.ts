import { createStopEventsView } from "../db/view";
import type { WasmDb } from "../db/wasm";
import { evaBucket } from "../lib/evaBucket";
import type { StationEntry } from "../lib/stationSearch";

export type DatasetName = "long-distance" | "all";
export const DATASET: DatasetName = "long-distance";
const DATA_URL = `${import.meta.env.BASE_URL}data/`;

export interface ManifestFile {
  path: string;
  quarter: string;
  min_date: string;
  max_date: string;
  rows: number;
  bytes: number;
  bucket?: number;
}

export interface Dataset {
  types: string[];
  stations: string;
  files: ManifestFile[];
  bucket_count?: number;
}

export interface Manifest {
  built_at: string;
  datasets: Record<string, Dataset>;
}

export interface Coverage {
  minDate: string;
  maxDate: string;
}

export interface LoadProgress {
  loadedBytes: number;
  totalBytes: number;
}

async function fetchJson<T>(path: string): Promise<T> {
  const res = await fetch(DATA_URL + path);
  if (!res.ok) throw new Error(`GET ${path}: HTTP ${res.status}`);
  return (await res.json()) as T;
}

export const fetchManifest = () => fetchJson<Manifest>("manifest.json");

export const fetchStations = (ds: Dataset) => fetchJson<StationEntry[]>(ds.stations);

export function coverage(files: readonly ManifestFile[]): Coverage | null {
  if (files.length === 0) return null;
  return {
    minDate: files.reduce((m, f) => (f.min_date < m ? f.min_date : m), files[0].min_date),
    maxDate: files.reduce((m, f) => (f.max_date > m ? f.max_date : m), files[0].max_date),
  };
}

// A null cutoff is the "All" window.
export function filesForCutoff(files: readonly ManifestFile[], cutoff: string | null): ManifestFile[] {
  return cutoff === null ? [...files] : files.filter((f) => f.max_date >= cutoff);
}

// A bucketed dataset also narrows to the buckets of `evas`: every shared query filters on eva IN (...).
export function filesForQuery(ds: Dataset, cutoff: string | null, evas: readonly string[]): ManifestFile[] {
  const files = filesForCutoff(ds.files, cutoff);
  if (ds.bucket_count === undefined) return files;
  const buckets = new Set(evas.map((eva) => evaBucket(eva, ds.bucket_count)));
  return files.filter((f) => f.bucket !== undefined && buckets.has(f.bucket));
}

async function fetchBytes(path: string, onChunk: (bytes: number) => void): Promise<Uint8Array> {
  const res = await fetch(DATA_URL + path);
  if (!res.ok || !res.body) throw new Error(`GET ${path}: HTTP ${res.status}`);
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    size += value.byteLength;
    onChunk(value.byteLength);
  }
  const out = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

export class DataLoader {
  private readonly loaded = new Set<string>();

  constructor(private readonly db: WasmDb) {}

  // Fetches and registers the files not loaded yet, then points stop_events at `files`.
  // Callers must not overlap calls: the view is shared.
  async use(files: readonly ManifestFile[], onProgress: (p: LoadProgress) => void): Promise<void> {
    const missing = files.filter((f) => !this.loaded.has(f.path));
    const progress: LoadProgress = { loadedBytes: 0, totalBytes: missing.reduce((n, f) => n + f.bytes, 0) };
    if (missing.length > 0) onProgress({ ...progress });

    await Promise.all(
      missing.map(async (f) => {
        const bytes = await fetchBytes(f.path, (n) => {
          progress.loadedBytes += n;
          onProgress({ ...progress });
        });
        await this.db.registerFileBuffer(f.path, bytes);
        this.loaded.add(f.path);
      }),
    );

    await createStopEventsView(
      this.db,
      files.map((f) => f.path),
    );
  }
}
