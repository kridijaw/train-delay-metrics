const modules = import.meta.glob<string>("../../../sql/*.sql", { query: "?raw", import: "default", eager: true });

const files = new Map<string, string>(
  Object.entries(modules).map(([path, text]) => [path.replace(/^.*\//, "").replace(/\.sql$/, ""), text]),
);

export function load(...names: string[]): string {
  return names
    .map((name) => {
      const text = files.get(name);
      if (text === undefined) throw new Error(`unknown SQL file sql/${name}.sql`);
      return text;
    })
    .join("\n");
}

export function names(): string[] {
  return [...files.keys()].sort();
}
